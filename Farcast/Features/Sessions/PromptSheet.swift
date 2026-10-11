import SwiftUI

struct PromptSheet: View {
    @ObservedObject var workspace: Workspace
    let prompt: SessionPrompt
    @State private var response = ""
    @State private var remember = true
    @State private var credential = ConnectionCredential()
    @State private var error: String?
    private var session: RemoteSession? { workspace.sessions.first { $0.id == prompt.sessionID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: prompt.kind == .trust ? "checkmark.shield" : "key.fill").font(.title).foregroundStyle(
                    prompt.previousFingerprint == nil ? Color.accentColor : Color.orange)
                VStack(alignment: .leading) {
                    Text(prompt.title).font(.title3.bold())
                    Text(session?.profile.host ?? "Server").foregroundStyle(.secondary)
                }
            }
            Text(prompt.details).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if prompt.kind == .trust {
                if let previous = prompt.previousFingerprint {
                    Text(
                        "The saved identity differs from the server’s current identity. Verify the change with your administrator before continuing."
                    ).foregroundStyle(.orange)
                    fingerprint("Previously trusted", value: previous)
                } else {
                    Text(
                        "Compare this fingerprint with one supplied by your administrator before trusting this server."
                    ).foregroundStyle(.secondary)
                }
                if let current = prompt.fingerprint { fingerprint("Presented fingerprint", value: current) }
                Toggle("Remember this identity", isOn: $remember)
            } else if prompt.kind == .interactive {
                if prompt.echo {
                    TextField("Response", text: $response)
                } else {
                    SecureField("Response", text: $response)
                }
            } else {
                if session?.profile.authentication == .privateKey {
                    HStack {
                        Text(credential.keyName ?? "Choose a private key")
                        Spacer()
                        Button("Choose Key…") { importKey() }
                    }
                    SecureField("Key passphrase", text: $credential.password)
                } else {
                    SecureField("Password", text: $credential.password)
                }
                if session?.persistent == true {
                    Toggle("Save credentials on this Mac", isOn: $remember)
                    Text("Uses Keychain when available; otherwise owner-only local files, which are not encrypted.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack {
                Text("Authentication expires after two minutes.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { workspace.answer(prompt, value: nil) }.keyboardShortcut(.cancelAction)
                PrimaryActionButton(title: prompt.kind == .trust ? "Trust & Connect" : "Continue") { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }.buttonStyle(.bordered).controlSize(.regular).padding(26).frame(width: 660).textFieldStyle(
            .roundedBorder)
    }
    private func fingerprint(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
            .quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    private func importKey() {
        do {
            if let key = try PrivateKeyPicker.pick() {
                credential.privateKey = key.data
                credential.keyName = key.name
            }
        } catch { self.error = error.localizedDescription }
    }
    private func submit() {
        if prompt.kind == .trust {
            workspace.answer(prompt, value: "trusted", remember: remember)
        } else if prompt.kind == .interactive {
            workspace.answer(prompt, value: response)
        } else {
            if session?.profile.authentication == .privateKey && credential.privateKey == nil {
                error = "Choose a private key first."
                return
            }
            do {
                if remember && session?.persistent == true { try workspace.saveCredentials(credential, for: prompt) }
                let data = try JSONEncoder().encode(credential)
                workspace.answer(prompt, value: String(decoding: data, as: UTF8.self))
            } catch { self.error = error.localizedDescription }
        }
    }
}
