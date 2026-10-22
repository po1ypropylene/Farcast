import SwiftUI

struct SessionInspector: View {
    @AppStorage("experimentalRDP") private var experimentalRDP = false
    @ObservedObject var session: RemoteSession
    @Binding var isPinned: Bool
    @Binding var isPresented: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connection details").font(.headline)
                Spacer()
                Button {
                    isPinned.toggle()
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                }
                .help(isPinned ? "Unpin connection details" : "Pin connection details and resize session")
                .accessibilityLabel(isPinned ? "Unpin connection details" : "Pin connection details")
                .accessibilityValue(isPinned ? "Pinned" : "Overlay")
                IconActionButton(title: "Close connection details", symbol: "xmark") {
                    isPresented = false
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LabeledContent("Status") {
                        Text(session.state.title).foregroundStyle(session.state.color)
                    }
                    Text(session.message).font(.callout).textSelection(.enabled)
                    if let connectedAt = session.connectedAt {
                        LabeledContent("Connected", value: connectedAt.formatted(date: .omitted, time: .standard))
                    }
                    if !session.latestFailure.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Latest failure", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            Text(session.latestFailure).textSelection(.enabled)
                        }.font(.callout)
                    }
                    LabeledContent("Protocol", value: session.profile.kind.rawValue)
                    LabeledContent("Host", value: session.profile.host)
                    LabeledContent("Port", value: String(session.profile.port))
                    LabeledContent("User", value: session.profile.username)
                    if !session.profile.domain.isEmpty { LabeledContent("Domain", value: session.profile.domain) }
                    if session.profile.wireGuardID != nil {
                        SessionVPNStatus(session: session).font(.callout)
                    } else {
                        LabeledContent("Transport", value: "Direct")
                    }
                    if session.profile.kind != .ssh {
                        Divider()
                        Text("Desktop").font(.headline)
                        if !session.initialResolution.isEmpty {
                            LabeledContent("Initial request", value: session.initialResolution)
                        }
                        if let size = session.observedDesktopSize {
                            LabeledContent("Server resolution", value: RemoteSession.resolution(size))
                        }
                        LabeledContent("Presentation", value: session.fullScreenPresented ? "Full screen" : "Window")
                        if session.profile.kind == .rdp {
                            LabeledContent(
                                "Resize with window", value: session.profile.dynamicResolution ? "On" : "Off")
                            LabeledContent("Retina", value: session.profile.retinaDisplay ? "On" : "Off")
                            if experimentalRDP && session.experimentalRDPEnabled {
                                LabeledContent("Graphics", value: session.graphicsPath)
                                if let desktop = session.desktop {
                                    DesktopPerformanceDetails(
                                        desktop: desktop, protocolStatistics: { session.rdpPerformanceStatistics })
                                }
                            }
                            LabeledContent("Clipboard", value: session.profile.clipboard ? "On" : "Off")
                            LabeledContent("Audio", value: session.profile.audioPlayback ? "On" : "Off")
                            LabeledContent("Shared folders", value: String(session.profile.redirectedFolders.count))
                        }
                        if !session.displayMessage.isEmpty {
                            Text(session.displayMessage).font(.callout).textSelection(.enabled)
                        }
                    }
                    if !session.remoteTitle.isEmpty {
                        Text(session.remoteTitle).font(.callout).foregroundStyle(.secondary)
                    }
                    if !session.profile.notes.isEmpty {
                        Divider()
                        Text(session.profile.notes).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Activity").font(.headline)
                    ForEach(session.logs) { log in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(log.time.formatted(date: .omitted, time: .standard)).font(.callout).foregroundStyle(
                                .secondary)
                            Text(log.message).font(.callout).textSelection(.enabled)
                        }
                    }
                    Text("Passwords and terminal contents are not recorded here.").font(.callout).foregroundStyle(
                        .secondary)
                }.padding(20)
            }
        }.background(.background)
    }
}

private struct DesktopPerformanceDetails: View {
    let desktop: RDPDesktopView
    let protocolStatistics: () -> [String: NSNumber]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let metrics = desktop.presentationMetrics
            let intervals = metrics.intervals.sorted()
            VStack(alignment: .leading, spacing: 4) {
                Text("Experimental presentation metrics").font(.callout)
                if desktop.window?.occlusionState.contains(.visible) == true, !intervals.isEmpty {
                    let p50 = intervals[(intervals.count - 1) / 2]
                    let p95 = intervals[Int(Double(intervals.count - 1) * 0.95)]
                    let p99 = intervals[Int(Double(intervals.count - 1) * 0.99)]
                    Text(String(format: "Frame interval p50 / p95 / p99: %.1f / %.1f / %.1f ms", p50, p95, p99))
                } else {
                    Text("No visible presentation samples")
                }
                let statistics = protocolStatistics()
                ForEach(["workerAge", "pduAge", "paintAge"], id: \.self) { key in
                    let label =
                        key == "workerAge" ? "Worker progress" : key == "pduAge" ? "Received PDU" : "Decoded paint"
                    if let age = statistics[key]?.doubleValue, age >= 0 {
                        Text(String(format: "%@: %.1f s ago", label, age))
                    }
                }
                if let delay = statistics["inputQueueMS"]?.doubleValue, delay >= 0 {
                    Text(String(format: "Latest input queue delay: %.2f ms", delay))
                }
                Text("Activity ages do not establish remote-path health.")
                Text("Distinct presented updates: \(metrics.count)")
                Text(String(format: "GPU texture writes: %.1f MiB", Double(desktop.uploadedBytes) / 1_048_576))
                Text("Frame intervals include idle time; these are not input-to-visual latency measurements.")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
