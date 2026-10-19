import SwiftUI

struct SessionInspector: View {
    @ObservedObject var session: RemoteSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connection details").font(.headline)
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
                        LabeledContent("Resize with window", value: session.profile.dynamicResolution ? "On" : "Off")
                        LabeledContent("Retina", value: session.profile.retinaDisplay ? "On" : "Off")
                        LabeledContent("Clipboard", value: session.profile.clipboard ? "On" : "Off")
                        LabeledContent("Audio", value: session.profile.audioPlayback ? "On" : "Off")
                        LabeledContent("Shared folders", value: String(session.profile.redirectedFolders.count))
                    }
                    if !session.displayMessage.isEmpty {
                        Text(session.displayMessage).font(.callout).textSelection(.enabled)
                    }
                }
                if !session.remoteTitle.isEmpty { Text(session.remoteTitle).font(.callout).foregroundStyle(.secondary) }
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
        }.background(.background)
    }
}
