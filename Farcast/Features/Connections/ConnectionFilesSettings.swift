import SwiftUI

struct ConnectionFilesSettings: View {
    @Binding var settings: FileTransferSettings
    @Binding var localPath: String
    var controller: SFTPController?
    @State private var extra = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FILE TRANSFER").font(.caption.bold())
            Picker("Transfer method", selection: $settings.method) {
                ForEach(FileTransferSettings.Method.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("Automatic uses rsync over this SSH connection when available and falls back to SFTP.")
                .foregroundStyle(.secondary)
            Toggle("Compress data during rsync transfers", isOn: $settings.compress)
            Text("Compression helps on slow links and text-heavy files.").foregroundStyle(.secondary)
            Divider()
            Text("CAPABILITIES").font(.caption.bold())
            if let controller {
                RsyncCapabilities(controller: controller)
            } else {
                Text("Checked when you connect").foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced") {
                Grid(alignment: .leading) {
                    GridRow {
                        Text("Local rsync (this Mac)")
                        TextField("Automatic", text: $localPath)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            if panel.runModal() == .OK, let url = panel.url { localPath = url.path }
                        }
                    }
                    GridRow {
                        Text("Remote rsync path")
                        TextField(
                            "Automatic",
                            text: Binding(
                                get: { settings.remoteRsyncPath ?? "" },
                                set: { settings.remoteRsyncPath = $0.isEmpty ? nil : $0 }))
                    }
                    GridRow {
                        Text("Extra options")
                        TextField("Optional", text: $extra)
                    }
                }.padding(.top, 8)
                Text(settings.validationMessage ?? "Options: --checksum, --whole-file, --sparse, --bwlimit=NUMBER")
                    .font(.caption)
            }
        }.onAppear { extra = settings.extraRsyncArgs.joined(separator: " ") }
            .onChange(of: extra) { _, text in
                settings.extraRsyncArgs = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            }
    }
}
