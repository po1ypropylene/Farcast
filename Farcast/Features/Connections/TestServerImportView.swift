import SwiftData
import SwiftUI

struct TestServerImportRequest: Identifiable {
    let id = UUID()
    let document: TestServerDocument
}

struct TestServerImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: Workspace
    let document: TestServerDocument
    @State private var rememberPasswords = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import test servers").font(.title2.weight(.semibold))
            Text(
                "Enabled entries become saved connections in Test Servers. Existing connection IDs are skipped. No connections start automatically."
            )
            .foregroundStyle(.secondary)
            List(document.enabledServers) { entry in
                HStack {
                    ConnectionProtocolIcon(kind: entry.protocolName)
                    Text(entry.draft.name)
                    Spacer()
                    Text(entry.protocolName.rawValue).foregroundStyle(.secondary)
                }
            }.frame(height: 200)
            Toggle("Save supplied passwords on this Mac", isOn: $rememberPasswords)
            Text(
                "Saved passwords use Keychain when available; otherwise owner-only local files, which are not encrypted. Passwords are never saved in the connection database. Server trust is checked when you connect. Private keys can be added later in Edit Connection."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                PrimaryActionButton(title: "Import") { importServers() }
                    .disabled(document.enabledServers.isEmpty)
            }
        }.buttonStyle(.bordered).controlSize(.regular).padding(24).frame(width: 600)
    }

    private func importServers() {
        do {
            let additions = try TestServerImporter.insert(document, into: context)
            var failures = 0
            if rememberPasswords {
                for entry in additions {
                    guard let password = entry.password, !password.isEmpty else { continue }
                    do { try CredentialStore.save(ConnectionCredential(password: password), for: entry.id) } catch {
                        failures += 1
                    }
                }
            }
            dismiss()
            if failures > 0 {
                workspace.error =
                    "Profiles were imported, but some passwords could not be saved on this Mac. Enter them when connecting or in Edit Connection."
            }
        } catch {
            dismiss()
            workspace.error = "The test-server profiles could not be saved. The import was rolled back."
        }
    }
}
