import AppKit
import SwiftUI

struct AppSettings: View {
    var storageController = ConnectionStorageController.shared
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("restoreWorkspace") private var restoreWorkspace = true
    @AppStorage(SSHInteractionView.rightClickPreference) private var sshRightClickAction = "menu"
    @AppStorage("reconnectRDPAfterWake") private var reconnectRDPAfterWake = false
    @AppStorage("experimentalRDP") private var experimentalRDP = false
    var body: some View {
        ScrollView {
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
                    Toggle("Automatically reconnect RDP after Mac wakes", isOn: $reconnectRDPAfterWake)
                    Text(
                        "RDP disconnects when the Mac sleeps. Reconnect after waking using this session’s sign-in details. Off by default."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Toggle("Experimental RDP features", isOn: $experimentalRDP)
                    Text(
                        "Enables GFX/H.264, immediate input wakeups, dirty-region updates and diagnostic metrics. Off by default. Applies when connecting or reconnecting."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                ConnectionStorageSettings(controller: storageController)
                FormSection(title: "About") {
                    FormRow(label: "Version") {
                        let version =
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                            ?? "Unknown"
                        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
                        Text("\(version) (Build \(build))")
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }.padding(20)
        }.controlSize(.regular).frame(width: 520, height: 700)
            .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
    }
}
