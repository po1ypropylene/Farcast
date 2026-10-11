import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SFTPView: View {
    @ObservedObject var controller: SFTPController
    var connected: Bool
    @State private var localSelection = Set<String>()
    @State private var remoteSelection = Set<String>()
    @State private var path = ""
    @State private var nameRequest: FileNameRequest?
    @State private var deleteRequest: FileDeleteRequest?
    @State private var moveDestination: Bool?
    @AppStorage("sftpDiskAccessExplained") private var diskAccessExplained = false
    @State private var showDiskAccess = false
    @State private var chooseFolderAfterSetup = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                localPane.frame(minWidth: 230)
                remotePane.frame(minWidth: 230)
            }
            Divider()
            HStack(spacing: 12) {
                if controller.busy {
                    if let progress = controller.progress {
                        ProgressView(value: progress).frame(width: 100)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(controller.message).lineLimit(1)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let speed = controller.transferSpeed {
                        Text(
                            "\(ByteCountFormatter.string(fromByteCount: Int64(min(speed, Double(Int64.max / 2))), countStyle: .file))/s"
                        )
                        .monospacedDigit().help("Average speed for the current file")
                    }
                }
                if controller.busy {
                    Button("Cancel") { controller.cancel() }
                        .disabled(controller.cancelling)
                        .help("Stops file work and keeps the SSH connection open.")
                }
                Text("Ask before overwriting files").foregroundStyle(.secondary)
            }.font(.callout).padding(10).background(.bar)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .onAppear {
            path = controller.remotePath
            if diskAccessExplained { controller.prepareLocalAccess() } else { showDiskAccess = true }
            if connected { controller.showFiles() }
        }
        .sheet(
            isPresented: $showDiskAccess,
            onDismiss: {
                diskAccessExplained = true
                if chooseFolderAfterSetup { controller.prepareLocalAccess() }
            }
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Prepare file access", systemImage: "folder.badge.gearshape").font(.title2.weight(.semibold))
                Text(
                    "Enable Farcast in System Settings → Privacy & Security → Full Disk Access to transfer files in protected folders. macOS may ask you to restart Farcast after enabling it."
                )
                Text(
                    "After returning, click Local Mac to choose your Home folder or another local folder to allow file transfers. Farcast remembers Home access. You can also enable Full Disk Access later from the Local Mac panel."
                )
                .foregroundStyle(.secondary)
                HStack {
                    Button("Choose Folder") {
                        chooseFolderAfterSetup = true
                        showDiskAccess = false
                    }
                    Spacer()
                    PrimaryActionButton(title: "Open System Settings") {
                        openDiskAccessSettings()
                        showDiskAccess = false
                    }
                }
            }.padding(24).frame(width: 540)
        }
        .onChange(of: connected) { _, ready in if ready { controller.showFiles() } }
        .onChange(of: controller.remotePath) { _, value in
            path = value
            remoteSelection = []
        }
        .onChange(of: controller.busy) { _, busy in
            if !busy { path = controller.remotePath }
        }
        .onChange(of: controller.localURL) { _, _ in localSelection = [] }
        .onChange(of: controller.localFiles) { _, files in localSelection.formIntersection(files.map(\.id)) }
        .onChange(of: controller.remoteFiles) { _, files in remoteSelection.formIntersection(files.map(\.id)) }
        .sheet(item: $nameRequest) { request in
            FileNameSheet(request: request) { name in
                if let file = request.file {
                    controller.rename(file, local: request.local, name: name)
                } else {
                    controller.newFolder(local: request.local, name: name)
                }
            }
        }
        .confirmationDialog(
            "\(deleteRequest?.local == true ? "Move to Trash" : "Permanently delete") selected items?",
            isPresented: Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } }),
            titleVisibility: .visible
        ) {
            if let request = deleteRequest {
                Button(request.local ? "Move to Trash" : "Delete permanently", role: .destructive) {
                    controller.delete(request.files, local: request.local)
                    deleteRequest = nil
                }
            }
            Button("Cancel", role: .cancel) { deleteRequest = nil }
        } message: {
            Text(
                deleteRequest?.local == true
                    ? "Selected folders include all their contents."
                    : "Selected server folders and all their contents will be removed. This cannot be undone.")
        }
        .confirmationDialog(
            "Move \(controller.bufferedCount) items here?",
            isPresented: Binding(get: { moveDestination != nil }, set: { if !$0 { moveDestination = nil } }),
            titleVisibility: .visible
        ) {
            if let local = moveDestination {
                Button("Move items") {
                    controller.paste(local: local)
                    moveDestination = nil
                }
            }
            Button("Cancel", role: .cancel) { moveDestination = nil }
        } message: {
            Text("Moves remove items from their original folder. Transfers ask before overwriting destination files.")
        }
        .alert(
            "A file named “\(controller.conflict?.name ?? "")” already exists.",
            isPresented: Binding(get: { controller.conflict != nil }, set: { _ in })
        ) {
            Button("Stop Transfer", role: .cancel) { controller.resolveConflict(overwrite: false) }
            Button("Overwrite", role: .destructive) { controller.resolveConflict(overwrite: true) }
            Button("Overwrite All", role: .destructive) { controller.resolveConflict(overwrite: true, all: true) }
        } message: {
            Text(
                "Replace this file, replace all conflicting files in the remaining transfer, or stop the entire transfer. Completed files stay completed."
            )
        }
        .alert(
            "File transfer",
            isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })
        ) {
            Button("OK") { controller.error = nil }
        } message: {
            Text(controller.error ?? "")
        }
    }

    private var localPane: some View {
        VStack(spacing: 0) {
            Button {
                controller.chooseLocalFolder()
            } label: {
                Label("Local Mac", systemImage: "laptopcomputer").font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(controller.busy)
                .help("Choose a local folder")
                .accessibilityHint("Opens the local folder picker")
                .padding(10)
            HStack {
                IconActionButton(title: "Parent local folder", symbol: "arrow.up") {
                    controller.localParent()
                }
                .disabled(controller.busy || !controller.canGoLocalUp).help("Parent local folder")
                Text(controller.localURL?.path ?? "Choose a folder to grant access").lineLimit(1).truncationMode(
                    .middle
                )
                .textSelection(.enabled)
                Spacer(minLength: 0)
                IconActionButton(title: "Refresh local files", symbol: "arrow.clockwise") {
                    controller.refreshLocal()
                }
                .disabled(controller.busy || controller.localURL == nil).help("Refresh local files")
            }.font(.callout).padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            fileList(controller.localFiles, selection: $localSelection, local: true)
                .overlay {
                    if controller.needsLocalAccess {
                        ContentUnavailableView(
                            "Allow access to Home", systemImage: "folder",
                            description: Text("Allow access to the folder you want to transfer files from or into."))
                    }
                }
            Divider()
            HStack {
                Button("Upload →") {
                    controller.transfer(selected(controller.localFiles, ids: localSelection), upload: true)
                }.disabled(!canTransfer(controller.localFiles, selection: localSelection))
                Button("Paste") { paste(local: true) }.disabled(!controller.canPaste(local: true))
                Spacer()
                IconActionButton(title: "Full Disk Access settings", symbol: "lock.shield") {
                    openDiskAccessSettings()
                }
                Text(
                    localSelection.isEmpty ? "\(controller.localFiles.count) items" : "\(localSelection.count) selected"
                ).foregroundStyle(.secondary)
            }.font(.callout).padding(10)
        }
    }
    private var remotePane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Server", systemImage: "externaldrive.connected.to.line.below").font(.headline)
                Spacer()
                Text("SFTP over SSH").font(.callout).foregroundStyle(.secondary)
            }.frame(minHeight: 24).padding(10)
            HStack {
                IconActionButton(title: "Parent server folder", symbol: "arrow.up") {
                    controller.remoteParent()
                }
                .disabled(!connected || controller.busy || controller.remotePath == "/").help("Parent server folder")
                TextField("Server folder", text: $path).frame(minHeight: 24).onSubmit {
                    controller.refreshRemote(path: path)
                }
                .disabled(!connected || controller.busy)
                IconActionButton(title: "Open server folder", symbol: "arrow.right") {
                    controller.refreshRemote(path: path)
                }
                .disabled(!connected || controller.busy).help("Open server folder")
                IconActionButton(title: "Refresh server files", symbol: "arrow.clockwise") {
                    controller.refreshRemote()
                }
                .disabled(!connected || controller.busy).help("Refresh server files")
            }.font(.callout).padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            fileList(controller.remoteFiles, selection: $remoteSelection, local: false)
            Divider()
            HStack {
                Button("← Download") {
                    controller.transfer(selected(controller.remoteFiles, ids: remoteSelection), upload: false)
                }.disabled(!canTransfer(controller.remoteFiles, selection: remoteSelection))
                Button("Paste") { paste(local: false) }.disabled(!controller.canPaste(local: false))
                Spacer()
                Text(remoteSelection.isEmpty ? "Double-click to open" : "\(remoteSelection.count) selected")
                    .foregroundStyle(.secondary)
            }.font(.callout).padding(10)
        }
    }
    private func openDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        if !NSWorkspace.shared.open(url) {
            controller.error = "Open System Settings → Privacy & Security → Full Disk Access and enable Farcast."
        }
    }
    private func selected(_ files: [TransferFile], ids: Set<String>) -> [TransferFile] {
        files.filter { ids.contains($0.id) }
    }
    private func canTransfer(_ files: [TransferFile], selection: Set<String>) -> Bool {
        let items = selected(files, ids: selection)
        return connected && !controller.busy && !controller.needsLocalAccess && controller.localURL != nil
            && !items.isEmpty
            && items.allSatisfy(\.transferable)
    }
    private func paste(local: Bool) {
        if controller.pasteMovesItems { moveDestination = local } else { controller.paste(local: local) }
    }
    private func fileList(_ files: [TransferFile], selection: Binding<Set<String>>, local: Bool) -> some View {
        List(selection: selection) {
            ForEach(files) { file in
                HStack {
                    Label(file.name, systemImage: file.directory ? "folder.fill" : file.regular ? "doc" : "link")
                        .lineLimit(1)
                    Spacer()
                    Text(file.sizeLabel).font(.callout).foregroundStyle(.secondary)
                }.frame(minHeight: 24).tag(file.id).contentShape(Rectangle())
                    .itemProvider {
                        guard !controller.busy, file.transferable else { return nil }
                        let items =
                            selection.wrappedValue.contains(file.id)
                            ? selected(files, ids: selection.wrappedValue) : [file]
                        return controller.dragProvider(items, local: local)
                    }
                    .onDrop(of: [SFTPController.dragType, UTType.fileURL.identifier], isTargeted: nil) { providers in
                        guard file.directory else { return false }
                        return controller.acceptDrop(providers, local: local, folder: file.name)
                    }
            }
            .onInsert(of: [SFTPController.dragType, UTType.fileURL.identifier]) { _, providers in
                _ = controller.acceptDrop(providers, local: local)
            }
        }.listStyle(.inset)
            .onDrop(of: [SFTPController.dragType, UTType.fileURL.identifier], isTargeted: nil) { providers in
                controller.acceptDrop(providers, local: local)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let items = selected(files, ids: ids)
                let available = !controller.busy && (local ? !controller.needsLocalAccess : connected)
                if !items.isEmpty {
                    Button(local ? "Open" : items.first?.directory == true ? "Open folder" : "Open local copy…") {
                        if let file = items.first { controller.open(file, local: local) }
                    }.disabled(!available || items.count != 1 || items.first?.transferable != true)
                    if local {
                        Button("Reveal in Finder") { controller.reveal(items) }.disabled(controller.busy)
                    }
                    Button(local ? "Upload to server" : "Download to local folder") {
                        controller.transfer(items, upload: local)
                    }.disabled(!canTransfer(files, selection: ids))
                    Divider()
                    Button("Rename…") {
                        if let file = items.first { nameRequest = FileNameRequest(local: local, file: file) }
                    }.disabled(!available || items.count != 1)
                    Button("Cut") { controller.copy(items, local: local, cut: true) }
                        .disabled(!available || !items.allSatisfy(\.transferable))
                    Button("Copy") { controller.copy(items, local: local, cut: false) }
                        .disabled(!available || !items.allSatisfy(\.transferable))
                    Button(items.count == 1 ? "Copy Path" : "Copy Paths") { controller.copyPaths(items, local: local) }
                    Divider()
                }
                Button("Paste into this folder") { paste(local: local) }.disabled(!controller.canPaste(local: local))
                Button("New Folder…") { nameRequest = FileNameRequest(local: local, file: nil) }
                    .disabled(!available || (local && controller.localURL == nil))
                Button("Select All") { selection.wrappedValue = Set(files.map(\.id)) }.disabled(files.isEmpty)
                Button("Refresh") { if local { controller.refreshLocal() } else { controller.refreshRemote() } }
                    .disabled(!available)
                if !items.isEmpty {
                    Divider()
                    Button(local ? "Move to Trash…" : "Delete…", role: .destructive) {
                        deleteRequest = FileDeleteRequest(local: local, files: items)
                    }.disabled(!available || !items.allSatisfy(\.transferable))
                }
            } primaryAction: { ids in
                let items = selected(files, ids: ids)
                if items.count == 1, let file = items.first { controller.open(file, local: local) }
            }
    }
}

private struct FileNameRequest: Identifiable {
    let id = UUID()
    let local: Bool
    let file: TransferFile?
}
private struct FileDeleteRequest {
    let local: Bool
    let files: [TransferFile]
}
private struct FileNameSheet: View {
    let request: FileNameRequest
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    init(request: FileNameRequest, submit: @escaping (String) -> Void) {
        self.request = request
        self.submit = submit
        _name = State(initialValue: request.file?.name ?? "New Folder")
    }
    private var valid: Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.file == nil ? "New Folder" : "Rename item").font(.headline)
            TextField("Name", text: $name).onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.file == nil ? "Create" : "Rename") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.buttonStyle(.bordered).controlSize(.regular).padding(24).frame(width: 420)
    }
    private func save() {
        guard valid else { return }
        submit(name)
        dismiss()
    }
}
