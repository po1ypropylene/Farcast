import AppKit
import SwiftData
import SwiftUI

private struct TunnelEditRequest: Identifiable {
    let id = UUID()
    let rule: SSHForwardingRule
    let existing: Bool
    let saved: Bool
}

struct SSHForwardingView: View {
    @Environment(\.modelContext) private var context
    @Query private var connections: [SavedConnection]
    @ObservedObject var controller: SSHForwardingController
    let connected: Bool
    var profileID: UUID?
    var server = ""
    var editSaved: (() -> Void)?
    @State private var editing: TunnelEditRequest?
    @State private var removing: SSHForwardingRule?
    @State private var error: String?
    private var savedConnection: SavedConnection? { connections.first { $0.id == profileID } }
    private func hasSavedID(_ rule: SSHForwardingRule) -> Bool {
        savedConnection.map { ConnectionDraft($0).forwardingRules.contains { $0.id == rule.id } } ?? false
    }
    private func isSaved(_ rule: SSHForwardingRule) -> Bool {
        savedConnection.map { ConnectionDraft($0).forwardingRules.contains(rule) } ?? false
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.rules.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No tunnels").font(.headline)
                            Text("Forward traffic through this SSH session.").font(.callout).foregroundStyle(
                                ConnectionFormLayout.captionColor)
                            PrimaryActionButton(title: "Add Tunnel…") { add() }.disabled(!connected)
                            if savedConnection != nil, let editSaved {
                                Button("Edit saved tunnels…", action: editSaved)
                            }
                        }.frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 48))
                    } else {
                        HStack {
                            Text("Live tunnels").font(.headline)
                            Spacer()
                            if savedConnection != nil, let editSaved {
                                Button("Edit saved tunnels…", action: editSaved)
                            }
                            Button("Add Tunnel…") { add() }.disabled(!connected || controller.rules.count >= 16)
                        }
                        ForEach(controller.rules) { rule in card(rule) }
                    }
                }.frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(ConnectionFormLayout.inset)
            }
        }.buttonStyle(.bordered).controlSize(.regular)
            .sheet(item: $editing) { request in
                LiveTunnelEditor(
                    rule: request.rule, server: server, saved: request.saved,
                    canSave: savedConnection != nil, existing: request.existing,
                    activeConnections: controller.statuses[request.rule.id]?.connections ?? 0,
                    startInitially: !request.existing || controller.statuses[request.rule.id]?.running == true
                ) { rule, save, start in
                    try apply(rule, save: save, start: start)
                }
            }
            .confirmationDialog(
                "Remove tunnel?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible
            ) {
                if let rule = removing {
                    if hasSavedID(rule) {
                        Button("Remove from Session and Connection", role: .destructive) { remove(rule, saved: true) }
                    }
                    Button("Remove from This Session", role: .destructive) { remove(rule, saved: false) }
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: {
                Text("This stops the tunnel and closes its active connections.")
            }
            .alert(
                "Tunnel could not be changed",
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }
    private func add() { editing = TunnelEditRequest(rule: .newRule(), existing: false, saved: savedConnection != nil) }
    private func card(_ rule: SSHForwardingRule) -> some View {
        let status = controller.statuses[rule.id] ?? SSHForwardingStatus()
        let endpoint = rule.endpoint(rule.bindAddress, port: status.port > 0 ? status.port : rule.bindPort)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(rule.kind.title).font(.headline)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(status.title).font(.callout)
                }.accessibilityElement(children: .combine)
                Button(status.running ? "Stop" : "Start") {
                    if status.running { controller.stop(rule) } else { controller.start(rule) }
                }.disabled(!connected || ["starting", "stopping"].contains(status.state))
                    .help(status.running ? "Stop this tunnel and close its connections" : "Start this tunnel")
                Menu {
                    Button("Edit…") { editing = TunnelEditRequest(rule: rule, existing: true, saved: isSaved(rule)) }
                    Button("Duplicate…") {
                        var duplicate = rule
                        duplicate.id = UUID()
                        duplicate.bindPort = 0
                        editing = TunnelEditRequest(rule: duplicate, existing: false, saved: savedConnection != nil)
                    }.disabled(controller.rules.count >= 16)
                    Button("Remove…", role: .destructive) { removing = rule }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).fixedSize().help("Tunnel actions").accessibilityLabel(
                    "Actions for \(rule.kind.title)"
                )
                .disabled(!connected || status.state == "stopping")
            }
            HStack(spacing: 6) {
                Text("\(rule.kind == .remote ? "Server" : "This Mac"): \(endpoint)").textSelection(.enabled)
                if status.state == "listening" {
                    IconActionButton(
                        title: rule.kind == .socks ? "Copy SOCKS5 proxy URL" : "Copy listener address",
                        symbol: "doc.on.doc"
                    ) {
                        let value = rule.kind == .socks ? "socks5://\(endpoint)" : endpoint
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                    if rule.kind == .socks {
                        IconActionButton(title: "Copy host and port", symbol: "number") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(endpoint, forType: .string)
                        }
                    }
                }
            }
            Text(rule.pathSummary(server: server)).font(.callout).foregroundStyle(ConnectionFormLayout.captionColor)
                .textSelection(.enabled)
            Text(
                isSaved(rule)
                    ? "Saved to this connection"
                    : hasSavedID(rule) ? "Session override; saved tunnel unchanged" : "This session only"
            ).font(.callout).foregroundStyle(
                .secondary)
            if status.state == "listening" { Text("\(status.connections) active connections").font(.callout) }
            if rule.kind == .socks {
                Text("No password. Any app on this Mac can use this proxy.").font(.callout).foregroundStyle(
                    ConnectionFormLayout.captionColor)
            }
            if rule.exposesListener {
                Label(
                    "Other devices on the server’s network can connect to this port.",
                    systemImage: "exclamationmark.triangle"
                ).font(.callout).foregroundStyle(.orange)
            }
            if rule.kind == .remote {
                Text("The server must allow remote listeners.").font(.callout).foregroundStyle(
                    ConnectionFormLayout.captionColor)
            }
            if !status.message.isEmpty {
                Text(status.message).font(.callout).foregroundStyle(status.state == "failed" ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    private func persist(_ rule: SSHForwardingRule, removing: Bool) throws {
        guard let savedConnection else { return }
        var draft = ConnectionDraft(savedConnection)
        guard !draft.forwardingRulesUnavailable else { throw TunnelEditError.invalid }
        draft.forwardingRules.removeAll { $0.id == rule.id }
        if !removing { draft.forwardingRules.append(rule) }
        guard draft.forwardingRules.count <= 16 else { throw TunnelEditError.limit }
        let old = savedConnection.sshForwardingRules
        savedConnection.sshForwardingRules = try JSONEncoder().encode(draft.forwardingRules)
        do { try context.save() } catch {
            savedConnection.sshForwardingRules = old
            throw error
        }
    }
    private func change(
        _ rule: SSHForwardingRule, save: Bool, removing: Bool,
        liveAction: () throws -> Void
    ) throws {
        // A storage failure must not start a tunnel requested as saved.
        let old = savedConnection?.sshForwardingRules
        if save { try persist(rule, removing: removing) }
        do { try liveAction() } catch {
            if save, let savedConnection {
                savedConnection.sshForwardingRules = old
                try context.save()
            }
            throw error
        }
    }
    private func apply(_ rule: SSHForwardingRule, save: Bool, start: Bool) throws {
        try change(rule, save: save, removing: false) { try controller.apply(rule, start: start) }
    }
    private func remove(_ rule: SSHForwardingRule, saved: Bool) {
        defer { removing = nil }
        do { try change(rule, save: saved, removing: true) { try controller.remove(rule) } } catch {
            self.error = error.localizedDescription
        }
    }

}

private struct LiveTunnelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: SSHForwardingRule
    let server: String
    @State var saved: Bool
    let canSave: Bool
    let existing: Bool
    let activeConnections: Int
    let startInitially: Bool
    let apply: (SSHForwardingRule, Bool, Bool) throws -> Void
    @State private var submitted = false
    @State private var visited: Set<SSHForwardingField> = []
    @State private var startNow = true
    @State private var confirm = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing ? "Edit live tunnel" : "Add Tunnel").font(.title3.weight(.semibold))
            ScrollView {
                SSHForwardingRuleEditor(rule: $rule, server: server, submitted: submitted, visited: $visited)
                Picker("Keep tunnel", selection: $saved) {
                    Text("Save to this connection").tag(true).disabled(!canSave)
                    Text("This session only").tag(false)
                }.disabled(!canSave).accessibilityLabel("Where to keep this tunnel")
                Toggle("Start now", isOn: $startNow)
                Text("Applies now to this session. Saved settings are also used on the next connection.")
                    .font(.callout).foregroundStyle(ConnectionFormLayout.captionColor)
            }
            Divider()
            HStack {
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else if submitted && rule.validationMessage != nil {
                    Text("Check the highlighted fields.").font(.callout).foregroundStyle(
                        ConnectionFormLayout.captionColor)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    submitted = true
                    guard rule.validationMessage == nil else { return }
                    if activeConnections > 0 { confirm = true } else { commit() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540, height: 480).textFieldStyle(.roundedBorder).buttonStyle(.bordered)
            .onAppear { startNow = startInitially }
            .confirmationDialog("Apply tunnel changes?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Apply Changes", role: .destructive) { commit() }
            } message: {
                Text(
                    "This closes the tunnel’s \(activeConnections) active connections before applying the new settings."
                )
            }
    }
    private func commit() {
        do {
            try apply(rule, saved, startNow)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
