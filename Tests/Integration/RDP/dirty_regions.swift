import AppKit
import MetalKit

@main struct DirtyRegionChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let mailbox = FrameMailbox()
        let w = 80
        let h = 60
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        mailbox.patch(Data(repeating: 10, count: w * h * 4), desktopWidth: w, desktopHeight: h, rect: full)
        let first = mailbox.snapshot()!
        mailbox.patch(
            Data(repeating: 20, count: 4 * 3 * 4), desktopWidth: w, desktopHeight: h,
            rect: CGRect(x: 2, y: 3, width: 4, height: 3))
        mailbox.patch(
            Data(repeating: 30, count: 2 * 2 * 4), desktopWidth: w, desktopHeight: h,
            rect: CGRect(x: 20, y: 10, width: 2, height: 2))
        precondition(first.1.pixels.allSatisfy { $0 == 10 }, "Retained snapshots must remain immutable")
        let merged = mailbox.update(after: first.0)!
        precondition(merged.2 == CGRect(x: 2, y: 3, width: 20, height: 9), "Dropped generations must union all damage")
        let desktop = RDPDesktopView(frame: full, mailbox: mailbox)
        let window = NSWindow(contentRect: full, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = desktop
        func bytes(_ view: RDPDesktopView) -> Data {
            let texture = view.texture!
            var result = Data(count: texture.width * texture.height * 4)
            result.withUnsafeMutableBytes {
                texture.getBytes(
                    $0.baseAddress!, bytesPerRow: texture.width * 4,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            return result
        }
        desktop.draw(in: desktop)
        precondition(bytes(desktop) == merged.1.pixels)
        let uploaded = desktop.uploadedBytes
        mailbox.patch(
            Data(repeating: 40, count: 2 * 2 * 4), desktopWidth: w, desktopHeight: h,
            rect: CGRect(x: 5, y: 5, width: 2, height: 2))
        desktop.draw(in: desktop)
        precondition(bytes(desktop) == mailbox.snapshot()!.1.pixels)
        if CommandLine.arguments.count == 1 {
            precondition(desktop.uploadedBytes - uploaded == 16, "A small update must upload only damaged pixels")
        }
        // A second, cropped surface starts later, then skips enough updates to
        // exhaust history. Canonical pixels still permit an exact full fallback.
        let crop = RDPDesktopView(frame: full, mailbox: mailbox)
        crop.sourceRect = CGRect(x: 10, y: 5, width: 30, height: 20)
        for i in 0..<100 {
            mailbox.patch(
                Data(repeating: UInt8(i), count: 4), desktopWidth: w, desktopHeight: h,
                rect: CGRect(x: i % w, y: i % h, width: 1, height: 1))
        }
        precondition(mailbox.update(after: merged.0)!.2 == full, "A lagging surface must get a full fallback")
        crop.draw(in: crop)
        let latest = mailbox.snapshot()!.1.pixels
        var expected = Data()
        for y in 5..<25 { expected.append(latest.subdata(in: (y * w + 10) * 4..<(y * w + 40) * 4)) }
        precondition(bytes(crop) == expected, "Cropped surfaces must converge independently")
        desktop.suspendRendering(true)
        mailbox.patch(Data(repeating: 77, count: w * h * 4), desktopWidth: w, desktopHeight: h, rect: full)
        desktop.suspendRendering(false)
        desktop.draw(in: desktop)
        precondition(bytes(desktop) == mailbox.snapshot()!.1.pixels, "Resume must force a full upload")
        mailbox.patch(
            Data(repeating: 88, count: 20 * 16 * 4), desktopWidth: 20, desktopHeight: 16,
            rect: CGRect(x: 0, y: 0, width: 20, height: 16))
        desktop.draw(in: desktop)
        precondition(bytes(desktop) == Data(repeating: 88, count: 20 * 16 * 4), "Resize must replace old pixels")
        print(
            "PASS dirty patches preserve immutable snapshots, dropped generations, independent crops, resume and resize with exact pixels"
        )
    }
}
