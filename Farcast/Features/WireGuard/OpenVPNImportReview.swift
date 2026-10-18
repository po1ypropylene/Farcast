import AppKit
import SwiftUI

struct OpenVPNImportReview: View {
    @Environment(\.dismiss) private var dismiss
    @State var document: OpenVPNImportDocument
    let filename: String
    let onImport: (OpenVPNImport) -> Void
    @State private var error: String?

    private var result: Result<OpenVPNImport, Error> { Result { try document.assemble() } }
    private var problem: String? {
        if case .failure(let error) = result {
            return (error as? OpenVPNError)?.errorDescription ?? OpenVPNError.invalidImport.errorDescription
        }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import OpenVPN Configuration").font(.title2)
            Text(filename).foregroundStyle(.secondary).lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if document.isTAP {
                        Label(OpenVPNError.tapUnsupported.localizedDescription, systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                        Link(
                            "NETGEAR TUN export instructions",
                            destination: URL(
                                string:
                                    "https://kb.netgear.com/31489/How-do-I-use-VPN-on-my-Orbi-system-with-my-iOS-device"
                            )!)
                    } else {
                        ForEach(document.requiredFiles) { role in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(role.label)
                                    Text(document.files[role] == nil ? "Select the referenced file" : "Included")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(document.files[role] == nil ? "Choose…" : "Replace…") { choose(role) }
                                    .accessibilityLabel("Choose \(role.label)")
                            }
                        }
                        if document.requiredFiles.isEmpty {
                            Text("Certificates and keys are included in the configuration.")
                        }
                        if document.needsLegacyCompression {
                            Toggle("Allow legacy incoming LZO compression", isOn: $document.allowLegacyCompression)
                            Text(
                                "Only enable this for a server that requires it. Outgoing data stays uncompressed; disabling compression on the server is preferable."
                            )
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let problem {
                            Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(
                        "Files are combined in memory. Scripts are never run. Import updates this draft; Save stores it with your credentials. It does not connect."
                    )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error { Text(error).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    if case .success(let value) = result {
                        onImport(value)
                        dismiss()
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }.padding(20).frame(width: 560, height: 460).buttonStyle(.bordered).controlSize(.regular)
    }
    private func choose(_ role: OpenVPNFileRole) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(role.label)"
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            document.files[role] = try OpenVPNBundleReader.readFile(url)
            error = nil
        } catch { self.error = OpenVPNError.invalidCompanion.localizedDescription }
    }
}
