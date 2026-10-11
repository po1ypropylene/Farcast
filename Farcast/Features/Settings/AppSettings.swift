import AppKit
import SwiftData
import SwiftUI

struct AppSettings: View {
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("restoreWorkspace") private var restoreWorkspace = true
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("System")
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
            }
            Toggle("Restore session tabs at launch", isOn: $restoreWorkspace)
            Text(
                "Restored tabs stay disconnected until you reconnect. Credentials use Keychain when available, with an owner-only local file fallback for development builds. Local files are not encrypted."
            ).font(
                .callout
            ).foregroundStyle(.secondary)
            LabeledContent("Protocols", value: "SSH · RDP")
            LabeledContent(
                "Version",
                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
        }.formStyle(.grouped).controlSize(.regular).frame(width: 480, height: 280).padding(16)
    }
}
