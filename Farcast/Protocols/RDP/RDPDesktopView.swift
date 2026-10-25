import AppKit
import CoreVideo
import IOKit.hidsystem
import MetalKit
import SwiftUI
import os.signpost

struct DesktopFrame {
    var pixels: Data
    let width: Int
    let height: Int
    let stride: Int
    var pixelBuffer: CVPixelBuffer? = nil
}
final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: DesktopFrame?
    private var sequence: UInt64 = 0
    private var damage: [(UInt64, CGRect)] = []
    private var notificationPending = false
    @MainActor private var views: [WeakDesktop] = []
    @MainActor private final class WeakDesktop {
        weak var value: RDPDesktopView?
        init(_ value: RDPDesktopView) { self.value = value }
    }
    @MainActor func observe(_ view: RDPDesktopView) {
        views.removeAll { $0.value == nil }
        views.append(WeakDesktop(view))
    }
    @MainActor private func publish() {
        lock.lock()
        notificationPending = false
        lock.unlock()
        views.removeAll { $0.value == nil }
        for view in views { view.value?.drawLatestFrame() }
    }
    func put(_ next: DesktopFrame) {
        lock.lock()
        frame = next
        sequence &+= 1
        damage = [(sequence, CGRect(x: 0, y: 0, width: next.width, height: next.height))]
        let schedule = !notificationPending
        notificationPending = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.publish() } }
    }
    // Canonical framebuffer is lock-owned. Data's copy-on-write preserves any
    // immutable snapshots retained by renderers while patches accumulate.
    func patch(_ pixels: Data, desktopWidth: Int, desktopHeight: Int, rect: CGRect) {
        let x = Int(rect.minX)
        let y = Int(rect.minY)
        let w = Int(rect.width)
        let h = Int(rect.height)
        guard desktopWidth > 0, desktopHeight > 0,
            desktopWidth <= RDPDisplayLimits.dimension, desktopHeight <= RDPDisplayLimits.dimension,
            desktopWidth * desktopHeight <= RDPDisplayLimits.pixels,
            x >= 0, y >= 0, w > 0, h > 0, x + w <= desktopWidth, y + h <= desktopHeight,
            pixels.count == w * h * 4
        else { return }
        lock.lock()
        if frame?.width != desktopWidth || frame?.height != desktopHeight || frame?.pixelBuffer != nil {
            guard x == 0, y == 0, w == desktopWidth, h == desktopHeight else {
                lock.unlock()
                return
            }
            frame = DesktopFrame(
                pixels: Data(count: desktopWidth * desktopHeight * 4),
                width: desktopWidth, height: desktopHeight, stride: desktopWidth * 4)
            damage.removeAll()
        }
        let stride = frame!.stride
        pixels.withUnsafeBytes { source in
            frame!.pixels.withUnsafeMutableBytes { destination in
                for row in 0..<h {
                    destination.baseAddress!.advanced(by: (y + row) * stride + x * 4)
                        .copyMemory(from: source.baseAddress!.advanced(by: row * w * 4), byteCount: w * 4)
                }
            }
        }
        sequence &+= 1
        damage.append((sequence, rect))
        if damage.count > 64 { damage.removeFirst(damage.count - 64) }
        let schedule = !notificationPending
        notificationPending = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.publish() } }
    }
    func update(after previous: UInt64?) -> (UInt64, DesktopFrame, CGRect)? {
        lock.lock()
        defer { lock.unlock() }
        guard let frame else { return nil }
        let full = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        guard let previous, previous < sequence,
            let first = damage.first, previous >= first.0 - 1
        else { return (sequence, frame, full) }
        let region = damage.filter { $0.0 > previous }.reduce(CGRect.null) { $0.union($1.1) }
        return (sequence, frame, region.width * region.height > full.width * full.height / 2 ? full : region)
    }
    func snapshot() -> (UInt64, DesktopFrame)? {
        lock.lock()
        defer { lock.unlock() }
        return frame.map { (sequence, $0) }
    }
    func take() -> DesktopFrame? {
        lock.lock()
        defer { lock.unlock() }
        let result = frame
        frame = nil
        return result
    }
}

final class RDPDesktopView: MTKView, MTKViewDelegate, NSTextInputClient {
    nonisolated let mailbox: FrameMailbox
    var sourceRect: CGRect?
    var expectedDesktopSize: CGSize?
    var retinaDisplay = false
    var exitFullScreen: (() -> Void)?
    var routePointer: ((NSEvent) -> CGPoint?)?
    private var lastPointerPoint: CGPoint?
    private var pressedMouseButtons = Set<Int>()
    private var renderedSequence: UInt64?
    private var uploadedSequence: UInt64?
    private var renderInFlight = false
    private var redrawPending = false
    private var presentationLink: CADisplayLink?
    private var presentationRequested = false
    // CADisplayLink retains its target. The proxy must not retain this view.
    private final class DisplayTarget: NSObject {
        weak var view: RDPDesktopView?
        init(_ view: RDPDesktopView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) {
            guard let view else {
                link.invalidate()
                return
            }
            view.presentLatestFrame(link)
        }
    }
    private let forceFullUploads = ProcessInfo.processInfo.environment["FARCAST_FULL_UPLOAD"] == "1"
    private let performanceLog = OSLog(subsystem: "com.peterpo.farcast", category: "DesktopPerformance")
    private(set) var uploadedBytes: UInt64 = 0
    private(set) var presentedFrames: UInt64 = 0
    private var lastPresentedSequence: UInt64?
    private var presentedTimes: [Double] = []
    private var presentationEpoch: UInt64 = 0
    var presentationMetrics: (count: UInt64, intervals: [Double]) {
        (presentedFrames, zip(presentedTimes.dropFirst(), presentedTimes).map { ($0 - $1) * 1000 })
    }
    private(set) var renderingSuspended = false
    func suspendRendering(_ suspended: Bool) {
        renderingSuspended = suspended
        if suspended {
            presentedTimes.removeAll()
            presentationEpoch &+= 1
            presentationLink?.isPaused = true
            presentationRequested = false
            redrawPending = false
            texture = nil
            surfaceTexture = nil
            surfaceBuffer = nil
            chromaSurfaceTexture = nil
            chromaTexture = nil
            renderedSequence = nil
        } else {
            drawLatestFrame()
        }
    }
    // Use a view-bound link, recreated on every window transfer. MTKView's
    // automatic loop remains disabled: its old window link can stop on full-screen exit.
    func drawLatestFrame() {
        guard !renderingSuspended, let window, window.isVisible else { return }
        presentationRequested = true
        // Occluded windows have no display callbacks. Keep the canonical texture
        // current for snapshots and owned offscreen consumers without presenting.
        guard window.occlusionState.contains(.visible) else {
            draw()
            return
        }
        if presentationLink == nil {
            let link = displayLink(target: DisplayTarget(self), selector: #selector(DisplayTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            presentationLink = link
        }
        presentationLink?.isPaused = false
    }
    private func presentLatestFrame(_ link: CADisplayLink) {
        guard presentationRequested, !renderingSuspended, window?.isVisible == true else {
            link.isPaused = true
            return
        }
        presentationRequested = false
        // draw() owns MTKView's drawable lifecycle. Only the latest mailbox
        // generation is uploaded; one command buffer remains in flight per view.
        draw()
        if !presentationRequested { link.isPaused = true }
    }
    var sendKey: ((Int, Bool, Bool) -> Void)?
    var keySymbolForEvent: ((UInt16, String) -> UInt32?)?
    var sendKeySymbol: ((UInt32, Bool) -> Void)?
    private var pressedSymbols: [UInt16: UInt32] = [:]
    var sendText: ((String) -> Void)?
    // RFB requires the produced keysym (A/!) instead of an unshifted scan-code
    // mapping (a/1). RDP retains its physical-key fast path.
    var usesTextKeySymbols = false
    var typeClipboard: (() -> Void)?
    var sendUnicode: ((Int, Bool) -> Void)?
    var synchronizeCapsLock: ((Bool) -> Void)?
    var preparePaste: (() -> Void)?
    var sendPointer: ((Int, Int, Int) -> Void)?
    var resizeRemote: ((Int, Int, Int) -> Void)?
    var inputEnabled = false {
        willSet { if !newValue { releaseInput() } }
    }
    var displayMode = RDPDisplayMode.fit
    weak var viewport: RDPViewport?
    private var initialSizeReady: ((CGSize) -> Void)?
    private var initialSizeTask: DispatchWorkItem?
    private var settleInitialSize = false
    private var lastViewportSize: CGSize?
    private var lastViewportBackingScale: CGFloat?
    private(set) var initialDesktopScale = 100
    func inheritViewportGeometry(from desktop: RDPDesktopView) {
        lastViewportSize = desktop.lastViewportSize
        lastViewportBackingScale = desktop.lastViewportBackingScale
    }
    func setDesktopSize(_ size: CGSize) {
        frameSize = size
        viewport?.layoutDesktop()
        refreshCursor()
    }
    func adoptDesktopSize(_ size: CGSize) {
        expectedDesktopSize = size
        if texture?.width != Int(size.width) || texture?.height != Int(size.height) {
            texture = nil
            surfaceTexture = nil
            surfaceBuffer = nil
            chromaSurfaceTexture = nil
            chromaTexture = nil
            renderedSequence = nil
        }
        setDesktopSize(size)
    }
    func withInitialSize(
        width: Int, height: Int, matchWindow: Bool? = nil, settle: Bool = false,
        completion: @escaping (CGSize) -> Void
    ) {
        initialSizeTask?.cancel()
        initialSizeReady = nil
        settleInitialSize = settle
        if !(matchWindow ?? (displayMode == .matchWindow)) {
            completion(CGSize(width: width, height: height))
        } else {
            initialSizeReady = completion
            if settle, window == nil, let lastViewportSize {
                // A background reconnect has no mounted surface. Retain its last
                // actual viewport rather than waiting for the tab to be selected.
                completeInitialSize(lastViewportSize)
            } else {
                viewport?.prepareInitialSize()
            }
        }
    }
    func cancelPendingDisplayWork() {
        initialSizeReady = nil
        initialSizeTask?.cancel()
        resizeTask?.cancel()
    }
    var awaitsInitialSize: Bool { initialSizeReady != nil }
    func viewportDidLayout(_ size: CGSize) {
        if size.width > 0, size.height > 0, let window {
            lastViewportSize = size
            lastViewportBackingScale = window.backingScaleFactor
        }
        guard size.width > 0, size.height > 0, initialSizeReady != nil else { return }
        guard settleInitialSize else {
            completeInitialSize(size)
            return
        }
        // Negotiate the final window geometry rather than a preset followed by
        // a Display Control resize. Wait for attachment and quiet layout first.
        initialSizeTask?.cancel()
        // Switching tabs during this wait must still allow connection to finish.
        guard let target = window != nil ? size : lastViewportSize else { return }
        let task = DispatchWorkItem { [weak self] in
            self?.completeInitialSize(target)
        }
        initialSizeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
    }
    private func completeInitialSize(_ size: CGSize) {
        guard let completion = initialSizeReady else { return }
        if !settleInitialSize {
            initialSizeReady = nil
            let scale = retinaDisplay ? window?.backingScaleFactor ?? 1 : 1
            let initial = CGSize(
                width: min(
                    8192, max(200, retinaDisplay ? floor(size.width * scale / 2) * 2 : size.width.rounded(.down))),
                height: min(8192, max(200, floor(size.height * scale))))
            setDesktopSize(initial)
            completion(initial)
            return
        }
        let factor = window?.backingScaleFactor ?? lastViewportBackingScale ?? 1
        let backing =
            window != nil
            ? convertToBacking(CGRect(origin: .zero, size: size)).size
            : CGSize(width: size.width * factor, height: size.height * factor)
        let request = RDPResizeRequest(
            points: size, backing: backing, backingScale: factor, retina: retinaDisplay)
        guard let request else { return }
        initialSizeReady = nil
        initialSizeTask = nil
        initialDesktopScale = request.scale
        setDesktopSize(request.size)
        completion(request.size)
    }
    var desktopSize: CGSize { frameSize }
    private(set) var texture: MTLTexture?
    private var surfaceTexture: CVMetalTexture?
    private var chromaSurfaceTexture: CVMetalTexture?
    private var chromaTexture: MTLTexture?
    private var videoConversion = [SIMD4<Float>](repeating: .zero, count: 3)
    private var surfaceBuffer: CVPixelBuffer?
    private var textureCache: CVMetalTextureCache?
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var frameSize = CGSize(width: 1440, height: 900)
    private var resizeTask: DispatchWorkItem?
    private var remoteCursor = NSCursor.arrow
    private var cursorImage: CGImage?
    private var cursorHotSpot = CGPoint.zero
    private var pressedKeys: [UInt16: (Int, Bool)] = [:]
    private var modifierKeys: [UInt16: (Int, Bool)] = [:]
    private var interpretingEvent: NSEvent?
    private var suppressCommand = false
    private var capsLock: Bool?
    private var marked = NSAttributedString(string: "")
    private var tracking: NSTrackingArea?
    private var scrollRemainder = 0.0
    // Apple virtual key codes mapped to RDP set-1 scan codes. Printable input also supports Unicode/IME.
    private static let scanCodes: [UInt16: (Int, Bool)] = [
        0: (0x1E, false), 1: (0x1F, false), 2: (0x20, false), 3: (0x21, false), 4: (0x23, false), 5: (0x22, false),
        6: (0x2C, false), 7: (0x2D, false), 8: (0x2E, false), 9: (0x2F, false), 11: (0x30, false), 12: (0x10, false),
        13: (0x11, false), 14: (0x12, false), 15: (0x13, false), 16: (0x15, false), 17: (0x14, false),
        18: (0x02, false), 19: (0x03, false), 20: (0x04, false), 21: (0x05, false), 22: (0x07, false),
        23: (0x06, false), 24: (0x0D, false), 25: (0x0A, false), 26: (0x08, false), 27: (0x0C, false),
        28: (0x09, false), 29: (0x0B, false), 30: (0x1B, false), 31: (0x18, false), 32: (0x16, false),
        33: (0x1A, false), 34: (0x17, false), 35: (0x19, false), 36: (0x1C, false), 37: (0x26, false),
        38: (0x24, false), 39: (0x28, false), 40: (0x25, false), 41: (0x27, false), 42: (0x2B, false),
        43: (0x33, false), 44: (0x35, false), 45: (0x31, false), 46: (0x32, false), 47: (0x34, false),
        48: (0x0F, false), 49: (0x39, false), 50: (0x29, false), 51: (0x0E, false), 53: (0x01, false),
        10: (0x56, false), 65: (0x53, false), 67: (0x37, false), 69: (0x4E, false), 75: (0x35, true), 76: (0x1C, true),
        78: (0x4A, false),
        81: (0x0D, false), 82: (0x52, false), 83: (0x4F, false), 84: (0x50, false), 85: (0x51, false),
        86: (0x4B, false), 87: (0x4C, false), 88: (0x4D, false), 89: (0x47, false), 91: (0x48, false),
        92: (0x49, false),
        96: (0x3F, false), 97: (0x40, false), 98: (0x41, false), 99: (0x3D, false), 100: (0x42, false),
        101: (0x43, false), 103: (0x57, false), 109: (0x44, false), 111: (0x58, false), 114: (0x52, true),
        115: (0x47, true), 116: (0x49, true), 117: (0x53, true), 118: (0x3E, false), 119: (0x4F, true),
        120: (0x3C, false), 121: (0x51, true), 122: (0x3B, false), 123: (0x4B, true), 124: (0x4D, true),
        125: (0x50, true), 126: (0x48, true),
    ]
    init(frame: NSRect, mailbox: FrameMailbox = FrameMailbox()) {
        self.mailbox = mailbox
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.035, green: 0.045, blue: 0.065, alpha: 1)
        // Render on mailbox publication and native display invalidation. Do not
        // rely on MTKView's window-bound periodic display link across reparenting.
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        if let device {
            queue = device.makeCommandQueue()
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
            let shader = """
                #include <metal_stdlib>
                using namespace metal;
                struct Output { float4 position [[position]]; float2 uv; };
                vertex Output vertexMain(uint i [[vertex_id]]) {
                    const float2 positions[] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
                    const float2 coords[] = {float2(0,1),float2(1,1),float2(0,0),float2(1,0)};
                    return {float4(positions[i],0,1),coords[i]};
                }
                fragment float4 fragmentMain(Output in [[stage_in]], texture2d<float> image [[texture(0)]],
                    texture2d<float> chroma [[texture(1)]], constant float4 *conversion [[buffer(0)]],
                    constant uint &isYUV [[buffer(1)]]) {
                    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
                    if (isYUV) {
                        float4 yuv = float4(image.sample(linearSampler,in.uv).r,
                            chroma.sample(linearSampler,in.uv).rg, 1);
                        return float4(dot(conversion[0], yuv), dot(conversion[1], yuv),
                            dot(conversion[2], yuv), 1);
                    }
                    return float4(image.sample(linearSampler,in.uv).rgb,1);
                }
                """
            do {
                let library = try device.makeLibrary(source: shader, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
                descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
                descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch { NSLog("Farcast desktop renderer could not initialize: %@", error.localizedDescription) }
        }
        mailbox.observe(self)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        releaseInput()
        return super.resignFirstResponder()
    }
    nonisolated func submit(_ data: Data, width: Int, height: Int, stride: Int) {
        guard width > 0, height > 0, width <= RDPDisplayLimits.dimension, height <= RDPDisplayLimits.dimension,
            width * height <= RDPDisplayLimits.pixels, stride >= width * 4, stride <= RDPDisplayLimits.dimension * 4,
            data.count >= stride * height
        else { return }
        mailbox.put(DesktopFrame(pixels: data, width: width, height: height, stride: stride))
    }
    nonisolated func submit(_ buffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard width > 0, height > 0, width <= 3840, height <= 2160,
            format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else { return }
        mailbox.put(
            DesktopFrame(
                pixels: Data(), width: width, height: height,
                stride: CVPixelBufferGetBytesPerRow(buffer), pixelBuffer: buffer))
    }
    nonisolated static func yuvConversion(_ buffer: CVPixelBuffer) -> [SIMD4<Float>] {
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
        let kr: Float
        let kb: Float
        if let matrix, CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            kr = 0.299
            kb = 0.114
        } else if let matrix, CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            kr = 0.2627
            kb = 0.0593
        } else {
            // The negotiated SDR HD stream uses BT.709 when VUI omits a matrix.
            kr = 0.2126
            kb = 0.0722
        }
        let fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let yScale: Float = fullRange ? 1 : 255 / 219
        let cScale: Float = fullRange ? 1 : 255 / 224
        let yOffset: Float = fullRange ? 0 : 16 / 255
        let center: Float = 128 / 255
        let r = 2 * (1 - kr) * cScale
        let b = 2 * (1 - kb) * cScale
        let gU = -2 * kb * (1 - kb) / (1 - kr - kb) * cScale
        let gV = -2 * kr * (1 - kr) / (1 - kr - kb) * cScale
        return [
            SIMD4(yScale, 0, r, -yOffset * yScale - center * r),
            SIMD4(yScale, gU, gV, -yOffset * yScale - center * (gU + gV)),
            SIMD4(yScale, b, 0, -yOffset * yScale - center * b),
        ]
    }
    func draw(in view: MTKView) {
        guard !renderingSuspended else { return }
        // Never overwrite a shared texture while the GPU reads it, or wait on
        // GPU work on the main actor. Keep only the mailbox's newest update.
        guard !renderInFlight else {
            redrawPending = true
            return
        }
        if let (sequence, frame, damage) = mailbox.update(after: renderedSequence),
            sequence != renderedSequence, let device
        {
            let region = sourceRect ?? CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            guard region.minX >= 0, region.minY >= 0, region.maxX <= CGFloat(frame.width),
                region.maxY <= CGFloat(frame.height), region.width > 0, region.height > 0,
                expectedDesktopSize == nil || expectedDesktopSize == CGSize(width: frame.width, height: frame.height)
            else {
                texture = nil
                return
            }
            let width = Int(region.width)
            let height = Int(region.height)
            if let pixelBuffer = frame.pixelBuffer {
                // Apple Adaptive is a single display. Import its IOSurface into
                // Metal; the mailbox and GPU completion retain the backing pool buffer.
                guard region == CGRect(x: 0, y: 0, width: frame.width, height: frame.height),
                    let textureCache
                else { return }
                let isYUV = CVPixelBufferIsPlanar(pixelBuffer)
                var imported: CVMetalTexture?
                guard
                    CVMetalTextureCacheCreateTextureFromImage(
                        nil, textureCache, pixelBuffer, nil,
                        isYUV ? .r8Unorm : .bgra8Unorm, width, height, 0, &imported) == kCVReturnSuccess,
                    let imported, let mapped = CVMetalTextureGetTexture(imported)
                else { return }
                var chroma: CVMetalTexture?
                if isYUV {
                    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
                        CVMetalTextureCacheCreateTextureFromImage(
                            nil, textureCache, pixelBuffer, nil,
                            .rg8Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1, &chroma) == kCVReturnSuccess,
                        let chroma, CVMetalTextureGetTexture(chroma) != nil
                    else { return }
                    videoConversion = Self.yuvConversion(pixelBuffer)
                }
                surfaceTexture = imported
                chromaSurfaceTexture = chroma
                chromaTexture = chroma.flatMap { CVMetalTextureGetTexture($0) }
                surfaceBuffer = pixelBuffer
                texture = mapped
                uploadedSequence = sequence
                setDesktopSize(CGSize(width: width, height: height))
            } else {
                let fullUpload = surfaceTexture != nil || texture?.width != width || texture?.height != height
                surfaceTexture = nil
                surfaceBuffer = nil
                chromaSurfaceTexture = nil
                chromaTexture = nil
                if fullUpload {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                    descriptor.usage = .shaderRead
                    descriptor.storageMode = .shared
                    texture = device.makeTexture(descriptor: descriptor)
                    setDesktopSize(CGSize(width: width, height: height))
                }
                let upload =
                    (fullUpload || forceFullUploads)
                    ? region : damage.intersection(region)
                if !upload.isNull && !upload.isEmpty {
                    let signpost = OSSignpostID(log: performanceLog)
                    os_signpost(.begin, log: performanceLog, name: "TextureUpload", signpostID: signpost)
                    frame.pixels.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress {
                            texture?.replace(
                                region: MTLRegionMake2D(
                                    Int(upload.minX - region.minX), Int(upload.minY - region.minY),
                                    Int(upload.width), Int(upload.height)), mipmapLevel: 0,
                                withBytes: base.advanced(by: Int(upload.minY) * frame.stride + Int(upload.minX) * 4),
                                bytesPerRow: frame.stride)
                        }
                    }
                    uploadedSequence = sequence
                    uploadedBytes &+= UInt64(upload.width * upload.height * 4)
                    os_signpost(.end, log: performanceLog, name: "TextureUpload", signpostID: signpost)
                }
            }
            renderedSequence = sequence
        }
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return }
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
            let buffer = queue?.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encodeImage(encoder, size: drawableSize)
        encoder.endEncoding()
        renderInFlight = true
        let retainedSurface = surfaceTexture
        let retainedPixels = surfaceBuffer
        let retainedChroma = chromaSurfaceTexture
        buffer.addCompletedHandler { [weak self, retainedSurface, retainedPixels, retainedChroma] _ in
            withExtendedLifetime((retainedSurface, retainedPixels, retainedChroma)) {}
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.renderInFlight = false
                if self.redrawPending {
                    self.redrawPending = false
                    self.drawLatestFrame()
                }
            }
        }
        let sequence = uploadedSequence
        let epoch = presentationEpoch
        drawable.addPresentedHandler { [weak self] presented in
            let time = presented.presentedTime
            DispatchQueue.main.async { [weak self] in
                guard let self, let sequence, time > 0, self.presentationEpoch == epoch, !self.renderingSuspended,
                    self.window?.occlusionState.contains(.visible) == true,
                    self.lastPresentedSequence.map({ sequence > $0 }) ?? true
                else { return }
                self.lastPresentedSequence = sequence
                self.presentedFrames &+= 1
                self.presentedTimes.append(time)
                if self.presentedTimes.count > 512 { self.presentedTimes.removeFirst() }
                os_signpost(.event, log: self.performanceLog, name: "FramePresented")
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }
    func encodeImage(_ encoder: MTLRenderCommandEncoder, size: CGSize) {
        if let pipeline, let texture {
            let rect = displayRect(in: size)
            encoder.setViewport(
                MTLViewport(
                    originX: rect.minX, originY: rect.minY, width: rect.width, height: rect.height, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(chromaTexture ?? texture, index: 1)
            encoder.setFragmentBytes(videoConversion, length: MemoryLayout<SIMD4<Float>>.stride * 3, index: 0)
            var isYUV: UInt32 = chromaTexture == nil ? 0 : 1
            encoder.setFragmentBytes(&isYUV, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }
    func displayRect(in size: CGSize) -> CGRect {
        let factor =
            displayMode == .fit
            ? min(size.width / frameSize.width, size.height / frameSize.height)
            : size.width / max(1, bounds.width) / (retinaDisplay ? window?.backingScaleFactor ?? 1 : 1)
        let width = frameSize.width * factor
        let height = frameSize.height * factor
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawableSize = convertToBacking(bounds).size
        viewport?.layoutDesktop()
        refreshCursor()
        requestResize()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestResize() }
    func requestResize() {
        resizeTask?.cancel()
        guard displayMode == .fit, !inLiveResize, !renderingSuspended else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.inputEnabled, !self.inLiveResize, !self.renderingSuspended, self.window != nil else {
                return
            }
            let factor = self.window?.backingScaleFactor ?? 1
            let points = self.viewport?.contentView.bounds.size ?? self.bounds.size
            let backing = self.convertToBacking(CGRect(origin: .zero, size: points)).size
            guard
                let request = RDPResizeRequest(
                    points: points, backing: backing, backingScale: factor, retina: self.retinaDisplay)
            else { return }
            self.resizeRemote?(request.width, request.height, request.scale)
        }
        resizeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        requestResize()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        releaseDrawables()
        presentationLink?.invalidate()
        presentationLink = nil
        presentationRequested = false
        presentedTimes.removeAll()
        presentationEpoch &+= 1
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        releaseInput()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(inputFocusLost), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowVisibilityChanged), name: NSWindow.didChangeOcclusionStateNotification,
                object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(inputFocusLost), name: NSApplication.didResignActiveNotification, object: nil)
        }
        requestResize()
        DispatchQueue.main.async { [weak self] in self?.drawLatestFrame() }
    }
    @objc private func windowVisibilityChanged(_ notification: Notification) {
        presentedTimes.removeAll()
        presentationEpoch &+= 1
        drawLatestFrame()
    }
    @objc private func inputFocusLost(_ notification: Notification) { releaseInput() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshCursor()
        requestResize()
    }
    private func refreshCursor() {
        guard let image = cursorImage else { return }
        let rect = displayRect(in: bounds.size)
        guard rect.width > 0, rect.height > 0 else { return }
        let xScale = rect.width / max(1, frameSize.width)
        let yScale = rect.height / max(1, frameSize.height)
        remoteCursor = NSCursor(
            image: NSImage(
                cgImage: image,
                size: NSSize(width: CGFloat(image.width) * xScale, height: CGFloat(image.height) * yScale)),
            hotSpot: NSPoint(x: cursorHotSpot.x * xScale, y: cursorHotSpot.y * yScale))
        window?.invalidateCursorRects(for: self)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self,
            userInfo: nil)
        addTrackingArea(tracking!)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: remoteCursor) }
    override func cursorUpdate(with event: NSEvent) { remoteCursor.set() }
    func setRemoteCursor(_ data: Data, width: Int, height: Int, hotX: Int, hotY: Int) {
        guard width > 0, height > 0, width <= 512, height <= 512 else {
            cursorImage = nil
            remoteCursor = .arrow
            window?.invalidateCursorRects(for: self)
            return
        }
        guard data.count == width * height * 4, let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(
                    .byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else { return }
        cursorImage = image
        cursorHotSpot = CGPoint(x: hotX, y: hotY)
        refreshCursor()
    }

    private func pointer(_ event: NSEvent, flags: Int) {
        guard inputEnabled else { return }
        reconcileModifiers(event.modifierFlags)
        if let expectedDesktopSize, let (_, frame) = mailbox.snapshot(),
            expectedDesktopSize != CGSize(width: frame.width, height: frame.height)
        {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let rect = displayRect(in: bounds.size)
        let source = sourceRect ?? CGRect(origin: .zero, size: frameSize)
        let transform = RDPDisplayTransform(source: source, destination: rect)
        let release = flags & 0x8000 == 0 && flags & 0x7000 != 0
        var mapped = transform.remotePoint(local: point, viewHeight: bounds.height)
        if mapped == nil
            && (release || [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type))
        {
            mapped = routePointer?(event)
        }
        if mapped == nil && release { mapped = lastPointerPoint }
        guard let mapped else { return }
        lastPointerPoint = mapped
        let button = flags & 0x7000
        if flags & 0x8000 != 0 && button != 0 { pressedMouseButtons.insert(button) }
        if release { pressedMouseButtons.remove(button) }
        sendPointer?(flags, Int(mapped.x), Int(mapped.y))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointer(event, flags: 0x9000)
    }
    override func mouseUp(with event: NSEvent) { pointer(event, flags: 0x1000) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointer(event, flags: 0xA000)
    }
    override func rightMouseUp(with event: NSEvent) { pointer(event, flags: 0x2000) }
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointer(event, flags: 0xC000)
    }
    override func otherMouseUp(with event: NSEvent) { pointer(event, flags: 0x4000) }
    override func mouseMoved(with event: NSEvent) { pointer(event, flags: 0x0800) }
    override func mouseDragged(with event: NSEvent) { pointer(event, flags: 0x0800) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, flags: 0x0800) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event, flags: 0x0800) }
    override func scrollWheel(with event: NSEvent) {
        if displayMode != .fit, event.modifierFlags.contains(.option) {
            viewport?.scrollWheel(with: event)
            return
        }
        scrollRemainder += Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 3 : 120)
        let delta = min(240, max(-240, Int(scrollRemainder)))
        if abs(delta) < 8 { return }
        scrollRemainder -= Double(delta)
        pointer(event, flags: 0x0200 | (delta < 0 ? 0x0100 | (256 - min(255, abs(delta))) : min(255, delta)))
    }
    override func keyDown(with event: NSEvent) {
        guard inputEnabled else { return }
        reconcileModifiers(event.modifierFlags)
        if event.keyCode == 9, event.modifierFlags.contains(.control) { preparePaste?() }
        let shortcut = !event.modifierFlags.intersection([.control, .option, .command]).isEmpty
        if !shortcut
            && (hasMarkedText() || Self.printableKeys[event.keyCode] != nil
                || event.characters?.unicodeScalars.contains(where: {
                    $0.value >= 32 && $0.value != 127 && $0.value < 0xF700
                }) == true)
        {
            interpretingEvent = event
            defer { interpretingEvent = nil }
            interpretKeyEvents([event])
            return
        }
        sendPhysicalKey(event)
    }
    private func sendPhysicalKey(_ event: NSEvent) {
        let symbol =
            usesTextKeySymbols ? keySymbolForEvent?(event.keyCode, event.charactersIgnoringModifiers ?? "") : nil
        if let previous = pressedSymbols[event.keyCode], previous != symbol {
            sendKeySymbol?(previous, false)
            pressedSymbols.removeValue(forKey: event.keyCode)
        }
        if let symbol {
            if let previous = pressedKeys.removeValue(forKey: event.keyCode) { sendKey?(previous.0, false, previous.1) }
            sendKeySymbol?(symbol, true)
            pressedSymbols[event.keyCode] = symbol
            return
        }
        if let code = Self.scanCodes[event.keyCode] {
            sendKey?(code.0, true, code.1)
            pressedKeys[event.keyCode] = code
        }
    }
    override func keyUp(with event: NSEvent) {
        guard inputEnabled else { return }
        reconcileModifiers(event.modifierFlags)
        if let symbol = pressedSymbols.removeValue(forKey: event.keyCode) { sendKeySymbol?(symbol, false) }
        if let code = pressedKeys.removeValue(forKey: event.keyCode) { sendKey?(code.0, false, code.1) }
    }
    override func flagsChanged(with event: NSEvent) {
        guard inputEnabled else { return }
        reconcileModifiers(event.modifierFlags, changedKey: event.keyCode)
    }
    private static let modifiers: [(UInt16, Int, Bool, NSEvent.ModifierFlags, Int32)] = [
        (56, 0x2A, false, .shift, NX_DEVICELSHIFTKEYMASK),
        (60, 0x36, false, .shift, NX_DEVICERSHIFTKEYMASK),
        (59, 0x1D, false, .control, NX_DEVICELCTLKEYMASK),
        (62, 0x1D, true, .control, NX_DEVICERCTLKEYMASK),
        (58, 0x38, false, .option, NX_DEVICELALTKEYMASK),
        (61, 0x38, true, .option, NX_DEVICERALTKEYMASK),
        (55, 0x5B, true, .command, NX_DEVICELCMDKEYMASK),
        (54, 0x5C, true, .command, NX_DEVICERCMDKEYMASK),
    ]
    private func reconcileModifiers(_ flags: NSEvent.ModifierFlags, changedKey: UInt16? = nil) {
        if !flags.contains(.command) { suppressCommand = false }
        let caps = flags.contains(.capsLock)
        if capsLock != caps {
            if let synchronizeCapsLock {
                synchronizeCapsLock(caps)
            } else if capsLock != nil || caps {
                sendKey?(0x3A, true, false)
                sendKey?(0x3A, false, false)
            }
            capsLock = caps
        }
        for (key, scan, extended, flag, mask) in Self.modifiers {
            let familyMask = Self.modifiers.filter { $0.3 == flag }.reduce(0) { $0 | $1.4 }
            let hasSides = flags.rawValue & UInt(familyMask) != 0
            // Hardware events identify each side. Events without device bits retain
            // known sides, choosing the changed (or left) key only on first entry.
            let known = Self.modifiers.contains { $0.3 == flag && modifierKeys[$0.0] != nil }
            let preferred =
                Self.modifiers.first { $0.3 == flag && $0.0 == changedKey }?.0
                ?? Self.modifiers.first { $0.3 == flag }?.0
            let fallback =
                modifierKeys[key] != nil || (!known && key == preferred)
            let down =
                flags.contains(flag) && (hasSides ? flags.rawValue & UInt(mask) != 0 : fallback)
                && !(flag == .command && suppressCommand)
            if down == (modifierKeys[key] != nil) { continue }
            sendKey?(scan, down, extended)
            if down { modifierKeys[key] = (scan, extended) } else { modifierKeys.removeValue(forKey: key) }
        }
    }
    // US physical keys are used only when AppKit commits exactly their expected
    // character. Other layouts, dead keys and IME commits retain Unicode input.
    private static let printableKeys: [UInt16: String] = [
        0: "aA", 1: "sS", 2: "dD", 3: "fF", 4: "hH", 5: "gG", 6: "zZ", 7: "xX", 8: "cC", 9: "vV",
        11: "bB", 12: "qQ", 13: "wW", 14: "eE", 15: "rR", 16: "yY", 17: "tT", 18: "1!", 19: "2@",
        20: "3#", 21: "4$", 22: "6^", 23: "5%", 24: "=+", 25: "9(", 26: "7&", 27: "-_", 28: "8*",
        29: "0)", 30: "]}", 31: "oO", 32: "uU", 33: "[{", 34: "iI", 35: "pP", 37: "lL", 38: "jJ",
        39: "'\"", 40: "kK", 41: ";:", 42: "\\|", 43: ",<", 44: "/?", 45: "nN", 46: "mM", 47: ".>", 49: "  ", 50: "`~",
    ]
    func releaseInput() {
        if let point = lastPointerPoint {
            for button in pressedMouseButtons { sendPointer?(button, Int(point.x), Int(point.y)) }
        }
        pressedMouseButtons.removeAll()
        for symbol in pressedSymbols.values { sendKeySymbol?(symbol, false) }
        pressedSymbols.removeAll()
        for code in pressedKeys.values { sendKey?(code.0, false, code.1) }
        for code in modifierKeys.values { sendKey?(code.0, false, code.1) }
        pressedKeys.removeAll()
        modifierKeys.removeAll()
        if synchronizeCapsLock != nil { capsLock = nil }
        inputContext?.discardMarkedText()
        unmarkText()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard inputEnabled, window?.firstResponder === self else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let editingShortcut = modifiers == .command && [UInt16(8), 9, 7, 0].contains(event.keyCode)
        let appShortcut =
            event.modifierFlags.contains(.command)
            && (["w", "q", "n", "f"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
                || Self.menuContainsShortcut(NSApp.mainMenu, event: event))
        if editingShortcut || appShortcut { suppressCommand = true }
        reconcileModifiers(event.modifierFlags)
        if modifiers == [.command, .control], event.charactersIgnoringModifiers?.lowercased() == "f",
            let exitFullScreen
        {
            releaseInput()
            exitFullScreen()
            return true
        }
        if modifiers == .command, event.keyCode == 9, let typeClipboard {
            releaseInput()
            typeClipboard()
            return true
        }
        if modifiers == .command, [UInt16(8), 9, 7, 0].contains(event.keyCode),
            let code = Self.scanCodes[event.keyCode]
        {
            // macOS editing shortcuts become Windows Control shortcuts.
            if event.keyCode == 9 { preparePaste?() }
            sendKey?(0x1D, true, false)
            sendKey?(code.0, true, code.1)
            sendKey?(code.0, false, code.1)
            sendKey?(0x1D, false, false)
            return true
        }
        // Keep application shortcuts available. Other shortcuts are sent when the desktop has focus.
        if appShortcut {
            releaseInput()
            suppressCommand = true
            return false
        }
        guard window?.firstResponder === self else { return false }
        keyDown(with: event)
        // AppKit may omit keyUp for Command equivalents. Balance the physical
        // nonmodifier now; repeated equivalents still produce repeated taps.
        if modifiers.contains(.command), let symbol = pressedSymbols.removeValue(forKey: event.keyCode) {
            sendKeySymbol?(symbol, false)
        }
        if modifiers.contains(.command), let code = pressedKeys.removeValue(forKey: event.keyCode) {
            sendKey?(code.0, false, code.1)
        }
        return true
    }
    private static func menuContainsShortcut(_ menu: NSMenu?, event: NSEvent) -> Bool {
        guard let menu else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        for item in menu.items {
            if menuContainsShortcut(item.submenu, event: event) { return true }
            guard !item.keyEquivalent.isEmpty else { continue }
            var expected = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
            if item.keyEquivalent.lowercased() != item.keyEquivalent { expected.insert(.shift) }
            if expected == modifiers,
                item.keyEquivalent.lowercased() == event.charactersIgnoringModifiers?.lowercased()
            {
                return true
            }
        }
        return false
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard inputEnabled else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !usesTextKeySymbols, let event = interpretingEvent, !hasMarkedText(),
            let pair = Self.printableKeys[event.keyCode]
        {
            let characters = Array(pair)
            let letter = characters[0].isLetter
            let shifted = event.modifierFlags.contains(.shift) != (letter && event.modifierFlags.contains(.capsLock))
            if text == String(characters[shifted ? 1 : 0]) {
                sendPhysicalKey(event)
                return
            }
        }
        if let sendText {
            sendText(text)
            marked = NSAttributedString(string: "")
            return
        }
        for unit in text.utf16 {
            sendUnicode?(Int(unit), true)
            sendUnicode?(Int(unit), false)
        }
        marked = NSAttributedString(string: "")
    }
    override func doCommand(by selector: Selector) {
        if let event = interpretingEvent { sendPhysicalKey(event) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}
/// The Metal surface remains session-owned; the scroll view only clips and positions it.
final class RDPViewport: NSScrollView {
    let desktop: RDPDesktopView
    private var layingOut = false
    private var resizeViewportSize: CGSize?
    private var resizeBackingScale: CGFloat?
    private weak var resizeWindow: NSWindow?
    init(desktop: RDPDesktopView) {
        self.desktop = desktop
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.065, alpha: 1)
        scrollerStyle = .overlay
        hasHorizontalScroller = desktop.displayMode != .fit
        hasVerticalScroller = desktop.displayMode != .fit
        autohidesScrollers = true
        documentView = desktop
        desktop.viewport = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizeViewportSize = nil
        resizeBackingScale = nil
        resizeWindow = nil
        layoutDesktop()
    }
    override func layout() {
        super.layout()
        layoutDesktop()
    }
    func prepareInitialSize() {
        hasHorizontalScroller = false
        hasVerticalScroller = false
        tile()
        layoutDesktop()
    }
    func layoutDesktop() {
        guard desktop.viewport === self, !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        if desktop.awaitsInitialSize || desktop.displayMode == .fit {
            hasHorizontalScroller = false
            hasVerticalScroller = false
        }
        tile()
        let available = contentView.bounds.size
        guard available.width > 0, available.height > 0 else { return }
        desktop.viewportDidLayout(available)
        let size =
            desktop.displayMode == .fit
            ? available
            : CGSize(
                width: max(
                    available.width,
                    desktop.desktopSize.width / (desktop.retinaDisplay ? desktop.window?.backingScaleFactor ?? 1 : 1)),
                height: max(
                    available.height,
                    desktop.desktopSize.height / (desktop.retinaDisplay ? desktop.window?.backingScaleFactor ?? 1 : 1)))
        if desktop.frame.size != size { desktop.setFrameSize(size) }
        hasHorizontalScroller = desktop.displayMode != .fit
        hasVerticalScroller = desktop.displayMode != .fit
        tile()
        // Begin at the remote desktop's upper-left corner.
        if !initializedScroll {
            contentView.scroll(to: NSPoint(x: 0, y: max(0, size.height - available.height)))
            reflectScrolledClipView(contentView)
            initializedScroll = true
        }
        // Reparenting can finish after Metal's move/size callbacks. Publish the
        // destination viewport even if the surface already has the fitted size.
        if let window, desktop.window === window,
            resizeWindow !== window || resizeViewportSize != available
                || resizeBackingScale != window.backingScaleFactor
        {
            resizeWindow = window
            resizeViewportSize = available
            resizeBackingScale = window.backingScaleFactor
            desktop.requestResize()
        }
    }
    private var initializedScroll = false
}
struct DesktopSurface: NSViewRepresentable {
    let view: RDPDesktopView
    func makeNSView(context: Context) -> RDPViewport { RDPViewport(desktop: view) }
    func updateNSView(_ nsView: RDPViewport, context: Context) { nsView.layoutDesktop() }
}
