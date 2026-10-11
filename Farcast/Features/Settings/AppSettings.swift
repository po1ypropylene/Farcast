import AppKit
import SwiftData
import SwiftUI

struct AppSettings: View {
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("restoreWorkspace") private var restoreWorkspace = true
    @AppStorage(SSHInteractionView.rightClickPreference) private var sshRightClickAction = "menu"
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("System")
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
            }
            Toggle("Restore session tabs at launch", isOn: $restoreWorkspace)
            Picker("SSH terminal right-click", selection: $sshRightClickAction) {
                Text("Show context menu").tag("menu")
                Text("Copy or paste automatically").tag("automatic")
            }
            Text(
                "Automatic mode copies selected text or the clicked output line, and pastes text on the active cursor line. Files are ignored. Cut is unavailable for remote terminal text. Shift–right-click uses local actions in mouse-aware terminal apps."
            ).font(.callout).foregroundStyle(.secondary)
            Text(
                "Restored tabs stay disconnected until you reconnect. Credentials use Keychain when available, with an owner-only local file fallback for development builds. Local files are not encrypted."
            ).font(
                .callout
            ).foregroundStyle(.secondary)
            LabeledContent("Protocols", value: "SSH · RDP")
            LabeledContent(
                "Version",
                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
        }.formStyle(.grouped).controlSize(.regular).frame(width: 480, height: 420).padding(16)
    }
}
