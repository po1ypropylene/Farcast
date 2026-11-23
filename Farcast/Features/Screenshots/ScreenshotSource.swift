import AppKit
import CoreImage
import CoreVideo
import SwiftTerm

enum ScreenshotSource: @unchecked Sendable {
    case image(ScreenshotImage)
    case desktop(Data, stride: Int, size: CGSize, crop: CGRect, scale: CGFloat)
    case video(CVPixelBuffer, crop: CGRect, scale: CGFloat)

    func render() throws -> ScreenshotImage {
        switch self {
        case .image(let image): return image
        case .desktop(let data, let stride, let size, let crop, let scale):
            guard
                let image = ScreenshotImage.desktopImage(
                    data, width: Int(size.width), height: Int(size.height), stride: stride, crop: crop)
            else { throw ScreenshotImageError.encoding }
            return ScreenshotImage(image: image, scale: scale)
        case .video(let buffer, let crop, let scale):
            let source = CIImage(cvPixelBuffer: buffer)
            let color =
                CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let area = CGRect(x: crop.minX, y: source.extent.height - crop.maxY, width: crop.width, height: crop.height)
            guard let image = Self.videoContext.createCGImage(source, from: area, format: .RGBX8, colorSpace: color)
            else { throw ScreenshotImageError.encoding }
            return ScreenshotImage(image: image, scale: scale)
        }
    }

    private static let videoContext = CIContext(options: [.cacheIntermediates: false])
}

extension RDPDesktopView {
    func screenshotRegion(for frame: DesktopFrame) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let source = sourceRect?.intersection(full) ?? full
        let displayed = displayRect(in: bounds.size)
        let visible = window != nil && !visibleRect.isEmpty ? visibleRect : previousScreenshotViewport ?? bounds
        return ScreenshotImage.pixelCrop(visible: visible, displayed: displayed, source: source)
    }

    func screenshot(entireDesktop: Bool) throws -> ScreenshotSource {
        guard let (_, frame) = mailbox.snapshot() else { throw ScreenshotImageError.unavailable }
        let full = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let crop = entireDesktop ? full : screenshotRegion(for: frame)
        guard !crop.isEmpty else { throw ScreenshotImageError.unavailable }
        let scale = retinaDisplay ? window?.backingScaleFactor ?? previousScreenshotScale ?? 1 : 1
        if let buffer = screenshotVideoFrame ?? frame.pixelBuffer,
            CVPixelBufferGetWidth(buffer) == frame.width, CVPixelBufferGetHeight(buffer) == frame.height
        {
            return .video(buffer, crop: crop, scale: scale)
        }
        guard !frame.pixels.isEmpty else { throw ScreenshotImageError.unavailable }
        return .desktop(frame.pixels, stride: frame.stride, size: full.size, crop: crop, scale: scale)
    }
}

extension TerminalController {
    func screenshot() throws -> ScreenshotSource {
        let rect = view.bounds
        let scale = view.window?.backingScaleFactor ?? view.screenshotBackingScale
        guard rect.width > 0, rect.height > 0 else { throw ScreenshotImageError.unavailable }
        let background = view.nativeBackgroundColor.cgColor
        guard
            let context = CGContext(
                data: nil, width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenshotImageError.encoding }

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        // SwiftTerm refreshes its AppKit snapshot on a size update, even at the
        // existing size. Hidden terminal tabs do not receive display-link ticks.
        if view.window?.occlusionState.contains(.visible) != true {
            view.setFrameSize(view.frame.size)
        }
        // Drawing the content explicitly also works when a background tab has no drawable window.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.draw(rect)
        NSGraphicsContext.restoreGraphicsState()
        for child in view.subviews where !child.isHidden {
            guard let layer = child.layer else { continue }
            context.saveGState()
            context.translateBy(x: child.frame.minX, y: child.frame.minY)
            (layer.presentation() ?? layer).render(in: context)
            context.restoreGState()
        }
        context.setBlendMode(.destinationOver)
        context.setFillColor(background)
        context.fill(rect)
        guard let image = context.makeImage() else { throw ScreenshotImageError.encoding }
        return .image(ScreenshotImage(image: image, scale: scale))
    }
}
