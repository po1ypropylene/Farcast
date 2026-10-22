import AppKit
import MetalKit

// Owned pixels only: isolates presentation scheduling from RDP decode/network cost.
@main struct PresentationLoadChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let desktop = RDPDesktopView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        let window = NSWindow(
            contentRect: desktop.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = RDPViewport(desktop: desktop)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        app.activate()
        defer { window.close() }
        func settle(_ seconds: TimeInterval) {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            }
        }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Owned desktop performance measurement")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        settle(1)
        print("Presentation window unoccluded: \(window.occlusionState.contains(.visible))")
        let pixels = Data(repeating: 73, count: 3840 * 2160 * 4)
        let producer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "presentation-load"))
        producer.schedule(deadline: .now(), repeating: .milliseconds(4))
        producer.setEventHandler {
            desktop.submit(pixels, width: 3840, height: 2160, stride: 3840 * 4)
        }
        var last = ProcessInfo.processInfo.systemUptime
        var gaps: [Double] = []
        let heartbeat = Timer(timeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                gaps.append(now - last)
                last = now
            }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        var cpuStart = timespec()
        var cpuEnd = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpuStart)
        producer.resume()
        settle(3)
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpuEnd)
        producer.cancel()
        heartbeat.invalidate()
        settle(0.2)
        precondition(desktop.texture?.width == 3840, "Load must upload actual 4K pixels")
        gaps.sort()
        let p95 = gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))] * 1000
        let maximum = (gaps.last ?? 0) * 1000
        let cpuMS =
            Double(cpuEnd.tv_sec - cpuStart.tv_sec) * 1000
            + Double(cpuEnd.tv_nsec - cpuStart.tv_nsec) / 1_000_000
        print(String(format: "CPU time during load: %.1fms", cpuMS))
        print(
            String(
                format: "4K presentation at 250 publications/s: heartbeat samples=%d p95=%.1fms max=%.1fms", gaps.count,
                p95, maximum))
        // Final publication must converge after overload; no forced draw is used.
        desktop.submit(Data(repeating: 91, count: pixels.count), width: 3840, height: 2160, stride: 3840 * 4)
        settle(0.3)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            desktop.texture?.getBytes(
                $0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        precondition(pixel[0] == 91, "Latest frame must converge after overload")
        let metrics = desktop.presentationMetrics
        let intervals = metrics.intervals.sorted()
        if window.occlusionState.contains(.visible), window.isKeyWindow, !intervals.isEmpty {
            func percentile(_ fraction: Double) -> Double {
                intervals[min(intervals.count - 1, Int(Double(intervals.count - 1) * fraction))]
            }
            print(
                String(
                    format: "Distinct presented updates=%llu frame interval p50=%.2f p95=%.2f p99=%.2fms",
                    metrics.count, percentile(0.5), percentile(0.95), percentile(0.99)))
        } else {
            print(
                "INVALID displayed-FPS measurement: no unoccluded key-window presentation samples; upload-load result only"
            )
        }
        print("PASS 4K presentation overload converges to final frame")
    }
}
