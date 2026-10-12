import AppKit
import SwiftData
import SwiftUI

struct WireGuardLibrary: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedWireGuard.name) private var profiles: [SavedWireGuard]
    @State private var selectedID: UUID?
    @State private var draftID = UUID()
    @State private var name = ""
    @State private var configuration = WireGuardConfiguration()
    @State private var privateKey = ""
    @State private var presharedKey = ""
    @State private var error: String?
    @State private var deleting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("WireGuard Connections", systemImage: "network.badge.shield.half.filled").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                VStack {
                    List(selection: $selectedID) {
                        ForEach(profiles) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        Button("New", systemImage: "plus") { reset() }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
                            .disabled(selectedID == nil)
                    }.padding()
                }.frame(width: 210)
                Divider()
                Form {
                    Section("Profile") {
                        TextField("Name", text: $name)
                        Button("Import WireGuard .conf…") { importConfiguration() }
                        Text(
                            "One peer per profile. Import reads the selected file; it does not run scripts or change macOS networking. ListenPort is managed automatically."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    Section("Interface") {
                        TextField("Addresses", text: $configuration.addresses, prompt: Text("10.0.0.2/32"))
                        SecureField("Private key", text: $privateKey)
                        TextField("DNS servers", text: $configuration.dns, prompt: Text("Optional, IP addresses"))
                        TextField("MTU", value: $configuration.mtu, format: .number.grouping(.never))
                    }
                    Section("Peer") {
                        TextField("Public key", text: $configuration.publicKey)
                        SecureField("Preshared key", text: $presharedKey, prompt: Text("Optional"))
                        TextField("Endpoint", text: $configuration.endpoint, prompt: Text("vpn.example.com:51820"))
                        TextField("Allowed IPs", text: $configuration.allowedIPs, prompt: Text("10.0.0.0/24"))
                        TextField(
                            "Keepalive (seconds)", value: $configuration.keepalive, format: .number.grouping(.never))
                        Text(
                            "DNS servers inside Allowed IPs use WireGuard; other configured DNS servers use this Mac’s normal network. Leave DNS empty when the server uses an IP address. Active sessions share this profile’s tunnel. Disconnect them before applying changes to tunnel settings or keys."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    Section {
                        Text(
                            "Keys use Keychain when available, otherwise owner-only files on this Mac. Local files are not encrypted. Keys are excluded from the connection library."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
            Divider()
            HStack {
                Text(error ?? validation ?? "Select this profile under Connect via in the connection editor.")
                    .font(.callout).foregroundStyle(error == nil ? Color.secondary : .red)
                Spacer()
                PrimaryActionButton(title: "Save") { save() }.disabled(validation != nil)
            }.padding(18)
        }.buttonStyle(.bordered).controlSize(.regular).frame(width: 920, height: 720)
            .onChange(of: selectedID) { _, id in if let id { load(id) } }
            .confirmationDialog("Delete this WireGuard connection?", isPresented: $deleting) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text(
                    "Connection profiles that use it will refuse to connect until you choose another WireGuard connection or explicitly select Direct. Active sessions continue until disconnected."
                )
            }
    }
    private var validation: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a profile name." }
        if let problem = configuration.validationMessage { return problem }
        if !WireGuardConfiguration.validKey(privateKey) { return "Enter a 32-byte base64 private key." }
        if !presharedKey.isEmpty && !WireGuardConfiguration.validKey(presharedKey) {
            return "Enter a valid preshared key or leave it empty."
        }
        return nil
    }
    private func reset() {
        selectedID = nil
        draftID = UUID()
        name = ""
        configuration = WireGuardConfiguration()
        privateKey = ""
        presharedKey = ""
        error = nil
    }
    private func load(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        do {
            let metadata = try profile.configuration()
            let credential = try CredentialStore.load(id)
            draftID = id
            name = profile.name
            configuration = metadata
            privateKey = credential?.wireGuardPrivateKey ?? ""
            presharedKey = credential?.wireGuardPresharedKey ?? ""
            error = nil
        } catch { self.error = "Could not load this WireGuard profile or its keys." }
    }
    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Import WireGuard Configuration"
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65_536 else {
                throw WireGuardError.invalidImport
            }
            let imported = try WireGuardImport.parse(Data(contentsOf: url))
            configuration = imported.configuration
            privateKey = imported.privateKey
            presharedKey = imported.presharedKey
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            error = nil
        } catch { self.error = WireGuardError.invalidImport.localizedDescription }
    }
    private func save() {
        guard validation == nil else {
            error = validation
            return
        }
        do {
            let metadata = try JSONEncoder().encode(configuration)
            let secret = ConnectionCredential(wireGuardPrivateKey: privateKey, wireGuardPresharedKey: presharedKey)
            try CredentialStore.save(secret, for: draftID)
            if let existing = profiles.first(where: { $0.id == draftID }) {
                existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                existing.configurationData = metadata
            } else {
                context.insert(
                    try SavedWireGuard(
                        id: draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        configuration: configuration))
            }
            try context.save()
            selectedID = draftID
            error = nil
        } catch { self.error = "Could not save this WireGuard profile. Check local storage and key access." }
    }
    private func delete() {
        guard let id = selectedID, let profile = profiles.first(where: { $0.id == id }) else { return }
        do {
            try CredentialStore.delete(id)
            context.delete(profile)
            try context.save()
            // Retain dangling IDs deliberately: deletion must never select direct networking.
            reset()
        } catch { self.error = "Could not delete this WireGuard profile." }
    }
}
