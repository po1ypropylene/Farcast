import AppKit
import SwiftUI

struct AppSettings: View {
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("restoreWorkspace") private var restoreWorkspace = true
    @AppStorage(SSHInteractionView.rightClickPreference) private var sshRightClickAction = "menu"
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
            FormSection(title: "Security") {
                Label(
                    "Credentials use Keychain when available, with owner-only local files for development builds. Local files are not encrypted.",
                    systemImage: "lock"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            FormSection(title: "About") {
                FormRow(label: "Protocols") { Text("SSH · SFTP · RDP · VNC").foregroundStyle(.secondary) }
                FormRow(label: "Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }.controlSize(.regular).padding(20).frame(width: 460).fixedSize(horizontal: false, vertical: true)
            .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
    }
}
