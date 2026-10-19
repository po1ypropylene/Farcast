import AppKit

@MainActor enum ShowcaseDesktop {
    static func frame(kind: RemoteProtocol, username: String) -> DesktopFrame {
        let width = 1440
        let height = 900
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor, radius: CGFloat = 0) {
                color.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: CGFloat(height) - y - h, width: w, height: h),
                    xRadius: radius, yRadius: radius
                ).fill()
            }
            func text(
                _ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 16,
                _ color: NSColor = .white, bold: Bool = false
            ) {
                (value as NSString).draw(
                    at: NSPoint(x: x, y: CGFloat(height) - y - size * 1.3),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                        .foregroundColor: color,
                    ])
            }
            let blue = NSColor(red: 0.12, green: 0.25, blue: 0.46, alpha: 1)
            let ink = NSColor(calibratedWhite: 0.16, alpha: 1)
            let muted = NSColor(calibratedWhite: 0.44, alpha: 1)
            let pale = NSColor(calibratedWhite: 0.96, alpha: 1)
            let rdp = kind == .rdp
            rect(0, 0, 1440, 900, blue)
            // Original geometric wallpaper and ordinary text, without third-party artwork.
            rect(1050, 80, 490, 490, NSColor(red: 0.15, green: 0.32, blue: 0.55, alpha: 1), radius: 245)
            rect(1130, 150, 330, 330, blue, radius: 165)
            rect(0, 0, 1440, 32, NSColor(calibratedWhite: 0.08, alpha: 0.95))
            text(rdp ? "Activities     Research Workspace" : "Applications     Places     Terminal", 22, 7, 13)
            text("Mon 19 Oct     09:41", 1220, 7, 13)
            for (index, label) in ["Home", "Projects", "Reports"].enumerated() {
                let y = CGFloat(85 + index * 100)
                rect(35, y, 42, 34, NSColor(red: 0.92, green: 0.71, blue: 0.33, alpha: 1), radius: 5)
                text(label, 28, y + 42, 14)
            }
            rect(150, 88, 1110, 690, .white, radius: 12)
            rect(150, 88, 1110, 45, pale, radius: 12)
            text(
                rdp ? "Central City · Research Dashboard" : "Picture News · Editorial Workspace", 175, 100, 17, ink,
                bold: true)
            text("−     □     ×", 1155, 100, 17, muted)
            rect(150, 133, 200, 645, NSColor(calibratedWhite: 0.94, alpha: 1))
            text("WORKSPACE", 174, 162, 12, muted, bold: true)
            for (index, label) in ["Overview", "Projects", "Documents", "Team", "Activity", "Settings"].enumerated() {
                let y = CGFloat(204 + index * 47)
                if index == 0 {
                    rect(162, y - 7, 175, 37, NSColor(red: 0.84, green: 0.9, blue: 0.99, alpha: 1), radius: 6)
                }
                text(label, 181, y, 16, index == 0 ? blue : muted, bold: index == 0)
            }
            text("Signed in as", 174, 702, 12, muted)
            text(username, 174, 726, 13, ink)
            text(rdp ? "Research overview" : "Newsroom overview", 386, 167, 30, ink, bold: true)
            text("Everything is up to date. Your team is ready for the day.", 386, 214, 16, muted)
            for (index, item) in [("Active projects", "12"), ("Services online", "24"), ("Tasks completed", "148")]
                .enumerated()
            {
                let x = CGFloat(386 + index * 280)
                rect(x, 265, 254, 116, pale, radius: 9)
                text(item.0, x + 20, 282, 14, muted)
                text(item.1, x + 20, 313, 34, ink, bold: true)
            }
            text("Recent activity", 386, 418, 21, ink, bold: true)
            text("PROJECT / DOCUMENT", 386, 467, 12, muted, bold: true)
            text("STATUS", 945, 467, 12, muted, bold: true)
            text("UPDATED", 1095, 467, 12, muted, bold: true)
            let rows =
                rdp
                ? [
                    "Sensor network · calibration complete", "Forensics report · analysis reviewed",
                    "Archive sync · all records current", "Infrastructure · weekly health check",
                ]
                : [
                    "Morning edition · ready for review", "Central City report · copy approved",
                    "Photography archive · catalog updated", "Editorial calendar · assignments confirmed",
                ]
            for (index, label) in rows.enumerated() {
                let y = CGFloat(511 + index * 54)
                rect(386, y + 37, 815, 1, pale)
                text(label, 386, y, 16, ink)
                rect(935, y - 3, 103, 28, NSColor(red: 0.87, green: 0.96, blue: 0.9, alpha: 1), radius: 14)
                text("Complete", 951, y + 2, 13, NSColor(red: 0.12, green: 0.42, blue: 0.27, alpha: 1))
                text("09:\(41 - index * 7)", 1095, y, 14, muted)
            }
            rect(0, 850, 1440, 50, NSColor(calibratedWhite: 0.1, alpha: 0.94))
            text("Workspace      Files      Terminal      Browser", 450, 867, 15)
            text("09:41", 1340, 867, 15)
            NSGraphicsContext.restoreGraphicsState()
        }
        return DesktopFrame(pixels: pixels, width: width, height: height, stride: width * 4)
    }
}
