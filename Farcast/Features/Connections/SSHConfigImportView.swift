import SwiftData
import SwiftUI

struct SSHConfigImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var connections: [SavedConnection]
    @Query private var folders: [ConnectionFolder]
    let document: SSHConfigImport
    let reportError: (String) -> Void
    @State private var selected = Set<UUID>()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import SSH Config").font(.title2.weight(.semibold))
            Text(
                "Import host aliases, addresses, usernames and ports. Keys, passwords, trust decisions and other SSH options are not imported. Include files and Match blocks are skipped; hosts requiring ProxyJump or ProxyCommand are omitted. Review imported profiles before connecting."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if document.entries.isEmpty {
                ContentUnavailableView(
                    "No importable hosts", systemImage: "terminal",
                    description: Text("Choose a config with literal Host aliases that connect directly."))
            } else {
                List(document.entries) { entry in
                    Toggle(
                        isOn: Binding(
                            get: { selected.contains(entry.id) },
                            set: {
                                if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) }
                            })
                    ) {
                        VStack(alignment: .leading) {
                            Text(entry.alias)
                            Text(
                                "\(entry.username.isEmpty ? "" : entry.username + "@")\(entry.host):\(String(entry.port))"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.checkbox)
                }.frame(minHeight: 180)
            }
            HStack {
                Text("\(selected.count) selected").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import") { importEntries() }.buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 540).onAppear { selected = Set(document.entries.map(\.id)) }
    }
    private func importEntries() {
        do {
            let folder =
                folders.first { $0.name == "SSH Config" && $0.parentID == nil }
                ?? ConnectionFolder(name: "SSH Config", order: folders.count)
            if folder.modelContext == nil { context.insert(folder) }
            for entry in document.entries where selected.contains(entry.id) {
                guard
                    !connections.contains(where: {
                        $0.kind == .ssh && $0.host == entry.host && $0.port == entry.port
                            && $0.username == entry.username
                    })
                else { continue }
                var draft = ConnectionDraft()
                draft.name = entry.alias
                draft.host = entry.host
                draft.username = entry.username
                draft.port = entry.port
                draft.folderID = folder.id
                context.insert(SavedConnection(draft: draft))
            }
            try context.save()
            dismiss()
        } catch { reportError("SSH configuration metadata could not be saved.") }
    }
}
