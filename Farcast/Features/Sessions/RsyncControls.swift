import SwiftData
import SwiftUI

struct RsyncCapabilities: View {
    @ObservedObject var controller: SFTPController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("This Mac", controller.localRsync)
            row("Server", controller.remoteRsync)
            Button("Re-check") { controller.recheck() }.disabled(controller.settings.method == .sftpOnly)
        }
    }
    @ViewBuilder private func row(_ label: String, _ result: RsyncDiscovery.Result?) -> some View {
        HStack {
            Text(label).frame(width: 68, alignment: .leading)
            if let result {
                if let install = result.installs.first {
                    Text("\(install.openRsync ? "openrsync" : "rsync") \(install.version)").fixedSize()
                    Menu {
                        ForEach(result.installs, id: \.path) { item in Text("\(item.version)  \(item.path)") }
                        ForEach(result.notes, id: \.self) { Text($0) }
                    } label: {
                        Image(systemName: "info.circle")
                    }.menuStyle(.borderlessButton).fixedSize()
                    Text(install.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(
                        install.path)
                } else {
                    Text(result.notes.first ?? "rsync unavailable").foregroundStyle(.secondary)
                }
            } else if controller.detecting {
                ProgressView().controlSize(.small)
            } else {
                Text("Checked when you connect").foregroundStyle(.secondary)
            }
        }
    }
}

struct RsyncControls: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [SavedConnection]
    @ObservedObject var controller: SFTPController
    let profileID: UUID?
    @State private var expanded = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            buttons(icons: false)
            buttons(icons: true)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Transfer method", selection: binding(\.method)) {
                    ForEach(FileTransferSettings.Method.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.radioGroup)
                Divider()
                RsyncCapabilities(controller: controller)
            }.padding().frame(width: 410)
        }
        .onChange(of: profiles.first { $0.id == profileID }?.sshFileTransfer) {
            if let profile = profiles.first(where: { $0.id == profileID }) {
                controller.settings = profile.fileTransfer
            }
        }
    }
    private func buttons(icons: Bool) -> some View {
        HStack {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 3) {
                    Label(controller.engineTitle, systemImage: "arrow.left.arrow.right")
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }.help("Transfer method")
            Toggle(isOn: binding(\.compress)) { Label("Compress", systemImage: "doc.zipper") }
                .toggleStyle(.button)
                .disabled(controller.settings.method == .sftpOnly || !controller.rsyncAvailable)
                .help(
                    controller.engineTitle == "rsync"
                        ? "Compress data in transit. Applies to the next transfer. Best for text files or slow links."
                        : "Compression applies to rsync transfers only")
        }.labelStyle(CompactTransferLabels(icons: icons))
    }
    private func binding<T>(_ key: WritableKeyPath<FileTransferSettings, T>) -> Binding<T> {
        Binding(
            get: { controller.settings[keyPath: key] },
            set: { value in
                var current = controller.settings
                current[keyPath: key] = value
                if let profile = profiles.first(where: { $0.id == profileID }) {
                    let previous = profile.sshFileTransfer
                    profile.fileTransfer = current
                    do { try context.save() } catch {
                        profile.sshFileTransfer = previous
                        controller.error = "Could not save transfer settings."
                        return
                    }
                }
                controller.settings = current
            })
    }
}
private struct CompactTransferLabels: LabelStyle {
    let icons: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.icon
            if !icons { configuration.title }
        }
    }
}
