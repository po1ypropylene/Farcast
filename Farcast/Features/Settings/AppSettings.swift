import AppKit
import SwiftUI

struct AppSettings: View {
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("restoreWorkspace") private var restoreWorkspace = true
    @AppStorage(SSHInteractionView.rightClickPreference) private var sshRightClickAction = "menu"
    @AppStorage("experimentalRDP") private var experimentalRDP = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormSection(title: "General") {
                FormRow(label: "Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }.labelsHidden()
                }
                Toggle("Restore session tabs at launch", isOn: $restoreWorkspace)
                Text("Restored tabs stay disconnected until you reconnect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            FormSection(title: "Terminal") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("SSH terminal right-click", selection: $sshRightClickAction) {
                        Text("Show context menu").tag("menu")
                        Text("Copy or paste automatically").tag("automatic")
                    }
                    if sshRightClickAction == "automatic" {
                        Text(
                            "Copies selected text or the clicked output line; pastes on the active cursor line. Files are ignored. Cut is unavailable."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Shift–right-click uses local actions in mouse-aware terminal apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            FormSection(title: "Remote Desktop") {
                Toggle("Experimental RDP features", isOn: $experimentalRDP)
                Text(
                    "Enables GFX/H.264, immediate input wakeups, dirty-region updates and diagnostic metrics. Off by default. Applies when connecting or reconnecting."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            FormSection(title: "About") {
                FormRow(label: "Version") {
                    let version =
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
                    Text("\(version) (Build \(build))")
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }.controlSize(.regular).padding(20).frame(width: 460).fixedSize(horizontal: false, vertical: true)
            .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
    }
}
