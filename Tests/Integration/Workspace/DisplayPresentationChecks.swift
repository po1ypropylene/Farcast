import AppKit
import CoreVideo
import MetalKit

@main struct DisplayPresentationChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let desktop = RDPDesktopView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        desktop.inputEnabled = true
        desktop.usesTextKeySymbols = true
        let center = CGPoint(x: 400, y: 300)
        precondition(desktop.cursor(at: center) === NSCursor.arrow)
        desktop.serverDrawsCursor = true
        let embeddedCursor = desktop.cursor(at: center)
        precondition(embeddedCursor !== NSCursor.arrow)
        let bitmap = NSBitmapImageRep(data: embeddedCursor.image.tiffRepresentation!)!
        precondition(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0)
        desktop.inputEnabled = false
        precondition(desktop.cursor(at: center) === NSCursor.arrow)
        desktop.inputEnabled = true
        desktop.setDesktopSize(CGSize(width: 800, height: 400))
        precondition(desktop.cursor(at: CGPoint(x: 400, y: 20)) === NSCursor.arrow)
        precondition(desktop.cursor(at: center) === embeddedCursor)
        desktop.setDesktopSize(CGSize(width: 800, height: 600))
        print("PASS embedded server cursor is transparent only inside the enabled desktop, excluding letterboxes")
        var pointer: CGPoint?
        desktop.sendPointer = { _, x, y in pointer = CGPoint(x: x, y: y) }
        // Off-screen, owned native windows avoid taking over the user's displays.
        let screens: [RDPDisplayScreen] = [
            .init(id: 1, frame: CGRect(x: -30000, y: -30000, width: 800, height: 600), backingScale: 2),
            .init(id: 2, frame: CGRect(x: -30800, y: -30000, width: 800, height: 600), backingScale: 1),
        ]
        let layout = try RDPDisplayLayout(screens: screens, retina: true)
        let presentation = RDPFullScreenPresentation(desktop: desktop, screens: screens, layout: layout)
        var exited = false
        presentation.onExit = { _ in exited = true }
        presentation.show()
        precondition(presentation.surfaces.allSatisfy { $0.usesTextKeySymbols && $0.serverDrawsCursor })
        precondition(presentation.surfaces.allSatisfy { $0.cursor(at: center) === embeddedCursor })
        presentation.setInputEnabled(false)
        precondition(presentation.surfaces.allSatisfy { $0.cursor(at: center) === NSCursor.arrow })
        presentation.setInputEnabled(true)
        print("PASS full-screen surfaces inherit embedded-cursor policy and restore the arrow when disabled")
        precondition(presentation.windows.count == 2 && presentation.surfaces.count == 2 && desktop.renderingSuspended)
        let primary = presentation.surfaces[0]
        let left = presentation.surfaces[1]
        let cursorEvent = NSEvent.enterExitEvent(
            with: .cursorUpdate, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: presentation.windows[0].windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)!
        primary.resetCursorRects()
        primary.cursorUpdate(with: cursorEvent)
        precondition(NSCursor.current === embeddedCursor)
        primary.inputEnabled = false
        primary.cursorUpdate(with: cursorEvent)
        precondition(NSCursor.current === NSCursor.arrow)
        primary.inputEnabled = true
        print("PASS native cursor-update events select transparency and restore the arrow after disconnect")
        precondition(primary.mailbox === desktop.mailbox && left.mailbox === desktop.mailbox)
        precondition(primary.sourceRect == CGRect(x: 800, y: 0, width: 1600, height: 1200))
        precondition(left.sourceRect == CGRect(x: 0, y: 300, width: 800, height: 600))
        print("PASS full-screen targets share one bounded mailbox, with distinct mixed-DPI source regions")
        var pixels = Data(count: 2400 * 1200 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let raw = bytes.bindMemory(to: UInt8.self)
            for y in 0..<1200 {
                for x in 0..<2400 {
                    let offset = (y * 2400 + x) * 4
                    raw[offset] = UInt8(x % 256)
                    raw[offset + 1] = UInt8(y % 256)
                    raw[offset + 2] = 96
                    raw[offset + 3] = 255
                }
            }
        }
        desktop.submit(pixels, width: 2400, height: 1200, stride: 2400 * 4)
        primary.draw(in: primary)
        left.draw(in: left)
        precondition(primary.texture?.width == 1600 && primary.texture?.height == 1200)
        precondition(left.texture?.width == 800 && left.texture?.height == 600)
        var first = [UInt8](repeating: 0, count: 4)
        first.withUnsafeMutableBytes {
            primary.texture!.getBytes(
                $0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        precondition(first == [32, 0, 96, 255])
        first.withUnsafeMutableBytes {
            left.texture!.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        precondition(first == [0, 44, 96, 255])
        print("PASS production Metal upload crops marked framebuffer pixels without duplicating full-desktop textures")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        precondition(presentation.surfaces.allSatisfy { $0.renderingSuspended && $0.texture == nil })
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        precondition(presentation.surfaces.allSatisfy { !$0.renderingSuspended })
        primary.draw(in: primary)
        left.draw(in: left)
        precondition(primary.texture?.width == 1600 && left.texture?.width == 800)
        print("PASS inactive full-screen surfaces retire GPU textures and resume from the shared latest frame")
        for (index, surface) in presentation.surfaces.enumerated() {
            let window = presentation.windows[index]
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 400, y: 300), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 0, pressure: 0)!
            surface.mouseMoved(with: event)
            precondition(pointer == CGPoint(x: index == 0 ? 1600 : 400, y: 600))
        }
        let sourceWindow = presentation.windows[0]
        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: -400, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: sourceWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        primary.mouseDragged(with: drag)
        precondition(pointer == CGPoint(x: 400, y: 600))
        var releases = 0
        primary.sendPointer = { flags, _, _ in if flags == 0x1000 { releases += 1 } }
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 400, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: sourceWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        primary.mouseDown(with: down)
        primary.releaseInput()
        primary.releaseInput()
        precondition(releases == 1)
        print("PASS cross-monitor drag routing and focus-loss release keep remote mouse buttons balanced")
        left.setFrameSize(CGSize(width: 1000, height: 600))
        pointer = nil
        let padding = NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 20, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: presentation.windows[1].windowNumber, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0)!
        left.mouseMoved(with: padding)
        precondition(pointer == nil)
        print("PASS production input inverts monitor crop, Retina density and Y orientation, and rejects letterboxing")
        // A reconfigured frame must never be uploaded using the previous crop transform.
        desktop.submit(Data(count: 800 * 600 * 4), width: 800, height: 600, stride: 800 * 4)
        primary.draw(in: primary)
        precondition(primary.texture == nil)
        pointer = nil
        primary.sendPointer = { _, x, y in pointer = CGPoint(x: x, y: y) }
        primary.mouseMoved(with: padding)
        precondition(pointer == nil)
        let windows = presentation.windows
        presentation.exit()
        precondition(
            exited && presentation.windows.isEmpty && presentation.surfaces.isEmpty && !desktop.renderingSuspended)
        precondition(windows.allSatisfy { !$0.isVisible })
        presentation.exit(notify: false)
        print("PASS obsolete frame rejection and idempotent full-screen teardown leave the session surface reusable")
        // Exercise the actual IOSurface import and its transition back to TCP
        // snapshots, including same-size frames (which must allocate a writable texture).
        let surface = RDPDesktopView(frame: .zero)
        var video: CVPixelBuffer?
        precondition(
            CVPixelBufferCreate(
                nil, 640, 480, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                &video) == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(video!, [])
        let base = CVPixelBufferGetBaseAddress(video!)!.assumingMemoryBound(to: UInt8.self)
        base[0] = 31
        base[1] = 101
        base[2] = 201
        base[3] = 255
        CVPixelBufferUnlockBaseAddress(video!, [])
        surface.serverDrawsCursor = true
        surface.inputEnabled = true
        surface.setFrameSize(CGSize(width: 640, height: 480))
        surface.submit(video!)
        precondition(surface.mailbox.snapshot()!.1.pixels.isEmpty)
        surface.draw(in: surface)
        first.withUnsafeMutableBytes {
            surface.texture!.getBytes(
                $0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        precondition(first == [31, 101, 201, 255] && surface.uploadedBytes == 0)
        video = nil
        surface.suspendRendering(true)
        surface.suspendRendering(false)
        surface.draw(in: surface)
        precondition(surface.texture?.width == 640)
        surface.submit(Data(repeating: 77, count: 640 * 480 * 4), width: 640, height: 480, stride: 640 * 4)
        surface.draw(in: surface)
        first.withUnsafeMutableBytes {
            surface.texture!.getBytes(
                $0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        precondition(first == [77, 77, 77, 77] && surface.uploadedBytes == 640 * 480 * 4)
        precondition(surface.cursor(at: CGPoint(x: 320, y: 240)) === embeddedCursor)
        print(
            "PASS retained Adaptive IOSurface maps to Metal without CPU upload, resumes and falls back to TCP with one cursor"
        )
        surface.sourceRect = CGRect(x: 0, y: 0, width: 640, height: 480)
        let device = surface.device!
        let commandQueue = device.makeCommandQueue()!
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 640, height: 480, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .shared
        let output = device.makeTexture(descriptor: targetDescriptor)!
        for fullRange in [true, false] {
            for matrix in [
                kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                kCVImageBufferYCbCrMatrix_ITU_R_2020,
            ] {
                var nv12: CVPixelBuffer?
                precondition(
                    CVPixelBufferCreate(
                        nil, 640, 480,
                        fullRange
                            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
                            as CFDictionary,
                        &nv12) == kCVReturnSuccess)
                let pixelBuffer = nv12!
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                memset(
                    CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), fullRange ? 128 : 126,
                    CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * 480)
                let uv = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
                let chromaSize = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * 240
                for offset in stride(from: 0, to: chromaSize, by: 2) {
                    uv[offset] = 80
                    uv[offset + 1] = 180
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                let uploaded = surface.uploadedBytes
                surface.submit(pixelBuffer)
                surface.draw(in: surface)
                precondition(surface.texture!.pixelFormat == .r8Unorm && surface.uploadedBytes == uploaded)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = output
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let command = commandQueue.makeCommandBuffer()!
                let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                surface.encodeImage(encoder, size: CGSize(width: 640, height: 480))
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                precondition(command.status == .completed)
                first.withUnsafeMutableBytes {
                    output.getBytes(
                        $0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(320, 240, 1, 1), mipmapLevel: 0)
                }
                let kr: Double =
                    CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
                    ? 0.299 : CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) ? 0.2627 : 0.2126
                let kb: Double =
                    CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
                    ? 0.114 : CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) ? 0.0593 : 0.0722
                let y = fullRange ? 128.0 : (126.0 - 16) * 255 / 219
                let u = (80.0 - 128) * (fullRange ? 1 : 255.0 / 224)
                let v = (180.0 - 128) * (fullRange ? 1 : 255.0 / 224)
                let rgb = [
                    y + 2 * (1 - kb) * u,
                    y - 2 * kb * (1 - kb) / (1 - kr - kb) * u - 2 * kr * (1 - kr) / (1 - kr - kb) * v,
                    y + 2 * (1 - kr) * v,
                ]
                for index in 0..<3 { precondition(abs(Double(first[index]) - min(255, max(0, rgb[index]))) <= 2) }
            }
        }
        print("PASS production Metal YCbCr shader preserves BT.601/709/2020 SDR colors in full and video ranges")
        let changed = RDPFullScreenPresentation(desktop: desktop, screens: screens, layout: layout)
        var reason: String?
        changed.onExit = { reason = $0 }
        changed.show()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        precondition(
            changed.windows.isEmpty && reason?.lowercased().contains("reconnect") == true && !desktop.renderingSuspended
        )
        print("PASS topology change returns to the existing surface with an explicit reconnect notice")

    }
}
