import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import FarcastCore

final class ScreenshotImageTests: XCTestCase {
    func testPaddedBGRXEncodingPreservesPixelsAndDPI() throws {
        let width = 8
        let height = 6
        let stride = 40
        var bytes = Data(repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                bytes[offset] = UInt8(x * 13)
                bytes[offset + 1] = UInt8(y * 29)
                bytes[offset + 2] = UInt8(90 + x)
            }
        }
        let image = try XCTUnwrap(ScreenshotImage.desktopImage(bytes, width: width, height: height, stride: stride))
        XCTAssertEqual(image.alphaInfo, .noneSkipFirst)
        for scale in [CGFloat(1), 2] {
            for format in ScreenshotFormat.allCases {
                let data = try ScreenshotImage(image: image, scale: scale).encode(as: format)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, width)
                XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, height)
                for property in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                    XCTAssertEqual(
                        try XCTUnwrap(properties[property as String] as? Double), Double(72 * scale),
                        accuracy: 0.1)
                }
                guard format == .png else { continue }
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB)
                XCTAssertTrue([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo))
                let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
                let context = try XCTUnwrap(
                    CGContext(
                        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                        space: color, bitmapInfo: image.bitmapInfo.rawValue))
                context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
                let pixels = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * stride + x * 4
                        XCTAssertEqual(
                            Array(UnsafeBufferPointer(start: pixels + offset, count: 3)),
                            Array(bytes[offset..<(offset + 3)]))
                    }
                }
            }
        }
    }

    func testCropMapsTopLeftAndIncludesFractionalEdgePixels() {
        let displayed = CGRect(x: 15, y: 24, width: 150, height: 90)
        let source = CGRect(x: 200, y: 100, width: 100, height: 60)
        let visible = CGRect(x: 17, y: 82, width: 40, height: 50)
        XCTAssertEqual(
            ScreenshotImage.pixelCrop(visible: visible, displayed: displayed, source: source),
            CGRect(x: 201, y: 100, width: 27, height: 22))
        XCTAssertEqual(
            ScreenshotImage.pixelCrop(
                visible: displayed.insetBy(dx: -20, dy: -20),
                displayed: displayed, source: source), source)
    }

    func testNamesAreSanitizedAndWritesNeverReplaceExistingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 0)
        let name = ScreenshotImage.filename(connection: "  My /: Mac\u{0000}  ", date: date)
        XCTAssertTrue(name.hasPrefix("My Mac "))
        XCTAssertTrue(ScreenshotImage.filename(connection: "/:", date: date).hasPrefix("Farcast "))
        XCTAssertEqual(
            ScreenshotImage.filename(connection: String(repeating: "a", count: 100), date: date)
                .prefix(while: { $0 == "a" }).count, 80)
        let initial = Data([1, 2, 3])
        let first = try ScreenshotImage.save(initial, in: folder, name: name, format: .jpeg)
        for index in 2...10 {
            let next = try ScreenshotImage.save(Data([UInt8(index)]), in: folder, name: name, format: .jpeg)
            XCTAssertEqual(next.lastPathComponent, "\(name) \(index).jpg")
        }
        XCTAssertEqual(try Data(contentsOf: first), initial)
    }
    func testConcurrentCapturesPublishDistinctFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        DispatchQueue.concurrentPerform(iterations: 10) { index in
            do {
                _ = try ScreenshotImage.save(Data([UInt8(index)]), in: folder, name: "Farcast", format: .png)
            } catch {
                XCTFail("Could not write a distinct screenshot: \(error)")
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let values = try files.map { try Data(contentsOf: $0) }
        XCTAssertEqual(files.count, 10)
        XCTAssertEqual(Set(values), Set((0..<10).map { Data([UInt8($0)]) }))
    }

}
