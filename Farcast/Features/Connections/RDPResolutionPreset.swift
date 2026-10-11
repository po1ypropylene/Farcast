import Foundation

/// Editor shortcuts for the existing stored pixel dimensions; no display-mode changes.
struct RDPResolutionPreset: Identifiable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var title: String { "\(width) × \(height)" }
    static let all: [Self] = [
        .init(width: 640, height: 480),
        .init(width: 800, height: 600),
        .init(width: 1024, height: 600),
        .init(width: 1024, height: 768),
        .init(width: 1152, height: 864),
        .init(width: 1280, height: 720),
        .init(width: 1280, height: 800),
        .init(width: 1280, height: 960),
        .init(width: 1280, height: 1024),
        .init(width: 1366, height: 768),
        .init(width: 1400, height: 1050),
        .init(width: 1440, height: 900),
        .init(width: 1600, height: 900),
        .init(width: 1600, height: 1000),
        .init(width: 1600, height: 1200),
        .init(width: 1680, height: 1050),
        .init(width: 1920, height: 1080),
        .init(width: 1920, height: 1200),
        .init(width: 2048, height: 1152),
        .init(width: 2048, height: 1536),
        .init(width: 2560, height: 1080),
        .init(width: 2560, height: 1440),
        .init(width: 2880, height: 1800),
        .init(width: 3440, height: 1440),
        .init(width: 3840, height: 2160),
    ]
    static func matching(width: Int, height: Int) -> Self? {
        all.first { $0.width == width && $0.height == height }
    }
}
