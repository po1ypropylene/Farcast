import CoreGraphics
import Foundation

enum RDPDisplayLimits {
    static let dimension = 16384
    static let pixels = 64 * 1024 * 1024
}

/// AppKit points and backing density are inputs, never remote coordinates.
struct RDPDisplayScreen: Equatable {
    let id: UInt32
    let frame: CGRect
    let backingScale: Double
    var physicalSize = CGSize.zero
    var orientation = 0
}

struct RDPDisplayMonitor: Equatable {
    let screenID: UInt32
    let rect: CGRect
    let primary: Bool
    let desktopScale: Int
    let physicalSize: CGSize
    let orientation: Int
}

enum RDPDisplayLayoutError: LocalizedError {
    case invalid
    var errorDescription: String? {
        "This display arrangement cannot be used for RDP. Use touching, non-overlapping displays with a combined size up to 16384 pixels per side and 64 Mi pixels, or turn off Retina or multiple monitors."
    }
}

struct RDPDisplayLayout: Equatable {
    let monitors: [RDPDisplayMonitor]
    let bounds: CGRect

    /// Present an already negotiated single desktop without requesting a new size.
    init(screen: RDPDisplayScreen, desktopSize: CGSize, desktopScale: Int) throws {
        guard desktopSize.width.isFinite, desktopSize.height.isFinite,
            (200...8192).contains(desktopSize.width), (200...8192).contains(desktopSize.height)
        else { throw RDPDisplayLayoutError.invalid }
        bounds = CGRect(origin: .zero, size: desktopSize)
        monitors = [
            RDPDisplayMonitor(
                screenID: screen.id, rect: bounds, primary: true, desktopScale: desktopScale,
                physicalSize: screen.physicalSize, orientation: screen.orientation)
        ]
    }

    init(screens: [RDPDisplayScreen], retina: Bool) throws {
        guard (1...16).contains(screens.count), Set(screens.map(\.id)).count == screens.count,
            screens.allSatisfy({
                $0.frame.minX.isFinite && $0.frame.minY.isFinite && $0.frame.width.isFinite
                    && $0.frame.height.isFinite && $0.frame.width >= 200 && $0.frame.height >= 200
                    && $0.frame.width <= 8192 && $0.frame.height <= 8192
                    && $0.backingScale.isFinite && (1...5).contains($0.backingScale)
            })
        else { throw RDPDisplayLayoutError.invalid }
        let primary = screens[0].frame
        let local = screens.map {
            CGRect(
                x: $0.frame.minX - primary.minX, y: primary.maxY - $0.frame.maxY,
                width: $0.frame.width, height: $0.frame.height)
        }
        let scales = screens.map { retina ? $0.backingScale : 1 }
        let sizes = zip(local, scales).map { rect, scale in
            CGSize(width: floor(rect.width * scale / 2) * 2, height: floor(rect.height * scale))
        }
        guard sizes.allSatisfy({ (200...8192).contains($0.width) && (200...8192).contains($0.height) })
        else { throw RDPDisplayLayoutError.invalid }
        // Link shared edges after scaling each screen. Scaling global origins separately
        // would overlap a 1× neighbor with a 2× primary. Anchor at the shared edge midpoint.
        var remote: [Int: CGRect] = [0: CGRect(origin: .zero, size: sizes[0])]
        while remote.count < screens.count {
            var progress = false
            for candidate in screens.indices where remote[candidate] == nil {
                for source in screens.indices {
                    guard let placed = remote[source],
                        let origin = Self.link(
                            source: local[source], target: local[candidate], placed: placed,
                            size: sizes[candidate], sourceScale: scales[source], targetScale: scales[candidate])
                    else { continue }
                    remote[candidate] = CGRect(origin: origin, size: sizes[candidate])
                    progress = true
                    break
                }
            }
            if !progress { throw RDPDisplayLayoutError.invalid }
        }
        let rects = screens.indices.map { remote[$0]! }
        var union = CGRect.null
        for (index, rect) in rects.enumerated() {
            guard rect.minX.isFinite && rect.minY.isFinite,
                abs(rect.minX) <= CGFloat(RDPDisplayLimits.dimension)
                    && abs(rect.minY) <= CGFloat(RDPDisplayLimits.dimension)
            else { throw RDPDisplayLayoutError.invalid }
            for previous in rects.prefix(index) {
                let overlap = previous.intersection(rect)
                if !overlap.isNull && overlap.width > 0 && overlap.height > 0 {
                    throw RDPDisplayLayoutError.invalid
                }
            }
            union = union.union(rect)
        }
        guard union.width <= CGFloat(RDPDisplayLimits.dimension) && union.height <= CGFloat(RDPDisplayLimits.dimension),
            union.width * union.height <= CGFloat(RDPDisplayLimits.pixels)
        else { throw RDPDisplayLayoutError.invalid }
        monitors = screens.indices.map {
            RDPDisplayMonitor(
                screenID: screens[$0].id, rect: rects[$0], primary: $0 == 0,
                desktopScale: Int((scales[$0] * 100).rounded()),
                physicalSize: screens[$0].physicalSize, orientation: screens[$0].orientation)
        }
        bounds = union
    }

    func sourceRect(for monitor: RDPDisplayMonitor) -> CGRect {
        monitor.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    }

    private static func link(
        source: CGRect, target: CGRect, placed: CGRect, size: CGSize,
        sourceScale: Double, targetScale: Double
    ) -> CGPoint? {
        let verticalMin = max(source.minY, target.minY)
        let verticalMax = min(source.maxY, target.maxY)
        if verticalMin <= verticalMax {
            let anchor = (verticalMin + verticalMax) / 2
            let y =
                (placed.minY + (anchor - source.minY) * sourceScale
                - (anchor - target.minY) * targetScale).rounded()
            if abs(target.minX - source.maxX) < 0.5 { return CGPoint(x: placed.maxX, y: y) }
            if abs(target.maxX - source.minX) < 0.5 { return CGPoint(x: placed.minX - size.width, y: y) }
        }
        let horizontalMin = max(source.minX, target.minX)
        let horizontalMax = min(source.maxX, target.maxX)
        if horizontalMin <= horizontalMax {
            let anchor = (horizontalMin + horizontalMax) / 2
            let x =
                (placed.minX + (anchor - source.minX) * sourceScale
                - (anchor - target.minX) * targetScale).rounded()
            if abs(target.minY - source.maxY) < 0.5 { return CGPoint(x: x, y: placed.maxY) }
            if abs(target.maxY - source.minY) < 0.5 { return CGPoint(x: x, y: placed.minY - size.height) }
        }
        return nil
    }
}

/// One transform drives Metal placement and its inverse drives input/cursor geometry.
struct RDPDisplayTransform {
    let source: CGRect
    let destination: CGRect
    func remotePoint(local: CGPoint, viewHeight: CGFloat) -> CGPoint? {
        let point = CGPoint(x: local.x, y: viewHeight - local.y)
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0,
            point.x >= destination.minX, point.x <= destination.maxX,
            point.y >= destination.minY, point.y <= destination.maxY
        else { return nil }
        return CGPoint(
            x: source.minX
                + min(source.width - 1, max(0, (point.x - destination.minX) * source.width / destination.width)),
            y: source.minY
                + min(source.height - 1, max(0, (point.y - destination.minY) * source.height / destination.height)))
    }
}
