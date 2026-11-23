import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotFormat: String, CaseIterable, Sendable {
    case png, jpeg

    var fileExtension: String { self == .png ? "png" : "jpg" }
    var contentType: UTType { self == .png ? .png : .jpeg }
}

enum ScreenshotImageError: LocalizedError {
    case encoding, nameCollision, unavailable

    var errorDescription: String? {
        switch self {
        case .encoding: return String(localized: "Couldn’t create the image.")
        case .nameCollision: return String(localized: "Couldn’t find an unused screenshot filename.")
        case .unavailable: return String(localized: "Nothing to capture yet.")
        }
    }
}

struct ScreenshotImage: Sendable {
    let image: CGImage
    let scale: CGFloat

    static func desktopImage(
        _ pixels: Data, width: Int, height: Int, stride: Int, crop: CGRect? = nil
    ) -> CGImage? {
        guard width > 0, height > 0, stride / 4 >= width, pixels.count / stride >= height else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let region = crop?.integral.intersection(full) ?? full
        guard !region.isEmpty else { return nil }
        let outputWidth = Int(region.width)
        let outputHeight = Int(region.height)
        let outputStride = region == full ? stride : outputWidth * 4
        let storage: Data
        if region == full {
            storage = pixels
        } else {
            var rows = Data(count: outputStride * outputHeight)
            rows.withUnsafeMutableBytes { target in
                pixels.withUnsafeBytes { source in
                    let offset = Int(region.minY) * stride + Int(region.minX) * 4
                    for row in 0..<outputHeight {
                        target.baseAddress!.advanced(by: row * outputStride).copyMemory(
                            from: source.baseAddress!.advanced(by: offset + row * stride), byteCount: outputStride)
                    }
                }
            }
            storage = rows
        }
        guard let provider = CGDataProvider(data: storage as CFData),
            let color = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: outputWidth, height: outputHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: outputStride, space: color,
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func pixelCrop(visible: CGRect, displayed: CGRect, source: CGRect) -> CGRect {
        let overlap = visible.intersection(displayed)
        guard !overlap.isEmpty else { return .null }
        let x = source.width / displayed.width
        let y = source.height / displayed.height
        let mapped = CGRect(
            x: source.minX + (overlap.minX - displayed.minX) * x,
            y: source.minY + (displayed.maxY - overlap.maxY) * y,
            width: overlap.width * x, height: overlap.height * y
        )
        return mapped.integral.intersection(source)
    }

    func encode(as format: ScreenshotFormat) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, format.contentType.identifier as CFString, 1, nil)
        else { throw ScreenshotImageError.encoding }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotImageError.encoding }
        return data as Data
    }

    static func filename(connection: String, date: Date) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        let clean = connection.components(separatedBy: forbidden).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = String(clean.prefix(80)).trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return "\(name.isEmpty ? "Farcast" : name) \(formatter.string(from: date))"
    }

    static func save(_ data: Data, in folder: URL, name: String, format: ScreenshotFormat) throws -> URL {
        for index in 1...100 {
            let suffix = index == 1 ? "" : " \(index)"
            let url = folder.appendingPathComponent(name + suffix).appendingPathExtension(format.fileExtension)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw ScreenshotImageError.nameCollision
    }
}
