import Foundation

/// One compact elapsed-time format for session status and sidebar help.
enum SessionUptime {
    static func string(since: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
        return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
    }
}
