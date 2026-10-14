import AppKit
import SwiftUI

struct SSHForwardingEditor: View {
    @Binding var rules: [SSHForwardingRule]
    @Binding var unavailable: Bool
    var server = ""
    var submitted = false
    @Binding var visibleIssues: Set<UUID>
    @Binding var visitedFields: [UUID: Set<SSHForwardingField>]
    var focusRequest: UUID?
    var liveController: SSHForwardingController?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved tunnels").font(.headline)
            Text("Used on the next connection. Change live tunnels in the session’s Tunnels view.")
                .font(.callout).foregroundStyle(.secondary)
            if unavailable {
                Text("Saved tunnels could not be read. Reset them to continue.").font(.callout).foregroundStyle(.red)
                Button("Reset unavailable tunnels") {
                    rules = []
                    unavailable = false
                }
            }
            if rules.isEmpty && !unavailable {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2)
                    Text("No tunnels").font(.headline)
                    Text("Forward traffic through this SSH connection.").font(.callout).foregroundStyle(.secondary)
                    Button("Add Tunnel…") { rules.append(.newRule()) }
                }.frame(maxWidth: .infinity).padding(.vertical, 32)
            }
            ForEach($rules) { $rule in
                SSHForwardingRuleEditor(
                    rule: $rule, server: server, submitted: submitted,
                    visited: Binding(get: { visitedFields[rule.id] ?? [] }, set: { visitedFields[rule.id] = $0 }),
                    focusRequest: rule.id == rules.first(where: { visibleIssues.contains($0.id) })?.id
                        ? focusRequest : nil
                ) { invalid in
                    if invalid { visibleIssues.insert(rule.id) } else { visibleIssues.remove(rule.id) }
                } remove: {
                    visibleIssues.remove(rule.id)
                    rules.removeAll { $0.id == rule.id }
                }.id(rule.id)
                if let liveController { SavedTunnelStatus(controller: liveController, rule: rule) }
            }
            if !rules.isEmpty {
                Button("Add Tunnel…") { rules.append(.newRule()) }.disabled(rules.count >= 16 || unavailable)
            }
        }.textFieldStyle(.roundedBorder)
    }
}

private struct SavedTunnelStatus: View {
    @ObservedObject var controller: SSHForwardingController
    let rule: SSHForwardingRule
    var body: some View {
        if let status = controller.statuses[rule.id] {
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("Live: \(status.title)")
                if controller.rules.first(where: { $0.id == rule.id }) != rule {
                    Text("— session uses different settings")
                }
            }.font(.callout).foregroundStyle(ConnectionFormLayout.captionColor)
        }
    }
}

struct SSHForwardingRuleEditor: View {
    @Binding var rule: SSHForwardingRule
    var server: String
    var submitted: Bool
    var reportInvalid: (Bool) -> Void = { _ in }
    var remove: (() -> Void)?
    @State private var edited: Set<SSHForwardingField> = []
    @Binding var visited: Set<SSHForwardingField>
    var focusRequest: UUID?
    @State private var listenText: String
    @State private var destinationText: String
    init(
        rule: Binding<SSHForwardingRule>, server: String, submitted: Bool,
        visited: Binding<Set<SSHForwardingField>>, focusRequest: UUID? = nil,
        reportInvalid: @escaping (Bool) -> Void = { _ in }, remove: (() -> Void)? = nil
    ) {
        _rule = rule
        self.server = server
        self.submitted = submitted
        _visited = visited
        self.focusRequest = focusRequest
        self.reportInvalid = reportInvalid
        self.remove = remove
        _listenText = State(initialValue: rule.wrappedValue.bindPort == 0 ? "" : String(rule.wrappedValue.bindPort))
        _destinationText = State(
            initialValue: rule.wrappedValue.destinationPort == 0 ? "" : String(rule.wrappedValue.destinationPort))
    }
    @FocusState private var focused: SSHForwardingField?
    private func message(_ field: SSHForwardingField) -> String? {
        guard submitted || visited.contains(field) else { return nil }
        return rule.validationMessage(for: field)
    }
    private var hasVisibleIssue: Bool { SSHForwardingField.allCases.contains { message($0) != nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConnectionFormRow(label: "Type") {
                HStack(spacing: 8) {
                    Picker("Tunnel type", selection: $rule.kind) {
                        ForEach(SSHForwardingKind.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().accessibilityLabel("Tunnel type")
                    Toggle("Start on connect", isOn: $rule.enabled).fixedSize().font(.callout)
                    if let remove {
                        IconActionButton(title: "Remove tunnel", symbol: "trash", action: remove)
                    }
                }
            }
            hint(rule.kind.explanation)
            ConnectionFormRow(label: "Listen") {
                HStack(spacing: 6) {
                    if rule.kind == .remote {
                        TextField("Listen address", text: $rule.bindAddress)
                            .accessibilityLabel("Remote listen address")
                            .focused($focused, equals: .listenAddress).invalidBorder(message(.listenAddress) != nil)
                    } else {
                        LoopbackAddressPicker(selection: $rule.bindAddress).frame(maxWidth: .infinity)
                    }
                    Text(":").foregroundStyle(.secondary).accessibilityHidden(true)
                    portField(.listenPort, value: $rule.bindPort, placeholder: "Auto")
                }
            }
            fieldErrors([.listenAddress, .listenPort])
            if rule.kind != .socks {
                ConnectionFormRow(label: "Forward to") {
                    HStack(spacing: 6) {
                        TextField("Destination host", text: $rule.destinationHost, prompt: Text("Host or IP address"))
                            .accessibilityLabel("Destination host")
                            .focused($focused, equals: .destinationHost).invalidBorder(message(.destinationHost) != nil)
                        Text(":").foregroundStyle(.secondary).accessibilityHidden(true)
                        portField(.destinationPort, value: $rule.destinationPort, placeholder: "Port")
                    }
                }
                fieldErrors([.destinationHost, .destinationPort])
                hint(
                    rule.kind == .remote
                        ? "Host and port reachable from this Mac." : "Host and port reachable from the server.")
            }
            if rule.exposesListener {
                Label(
                    "Other devices on the server’s network can connect to this port.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if rule.kind == .socks { hint("No password. Any app on this Mac can use this proxy.") }
            if rule.kind == .remote { hint("The server must allow remote listeners.") }
            Divider()
            Text(rule.pathSummary(server: server)).font(.callout).foregroundStyle(ConnectionFormLayout.captionColor)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: focused) { old, _ in
                if let old, edited.contains(old) { visited.insert(old) }
                if old == .listenPort && rule.bindPort == 0 { listenText = "" }
            }
            .onChange(of: rule) { old, new in
                if old.bindAddress != new.bindAddress { edited.insert(.listenAddress) }
                if old.bindPort != new.bindPort { edited.insert(.listenPort) }
                if old.destinationHost != new.destinationHost { edited.insert(.destinationHost) }
                if old.destinationPort != new.destinationPort { edited.insert(.destinationPort) }
                if old.kind != new.kind && new.kind != .remote && !["127.0.0.1", "::1"].contains(new.bindAddress) {
                    rule.bindAddress = "127.0.0.1"
                }
            }
            .onChange(of: hasVisibleIssue, initial: true) { _, invalid in reportInvalid(invalid) }
            .background(
                EditorValidationReveal(request: focusRequest) {
                    focused = SSHForwardingField.allCases.first { message($0) != nil }
                }.allowsHitTesting(false).accessibilityHidden(true))
    }
    private func portField(_ field: SSHForwardingField, value: Binding<Int>, placeholder: String) -> some View {
        TextField(
            placeholder,
            text: Binding(
                get: { field == .listenPort ? listenText : destinationText },
                set: { text in
                    if field == .listenPort { listenText = text } else { destinationText = text }
                    edited.insert(field)
                    // Non-numeric input stays invalid rather than silently becoming Auto.
                    value.wrappedValue = text.isEmpty ? 0 : Int(text) ?? -1
                }), prompt: Text(placeholder)
        )
        .frame(width: 64).focused($focused, equals: field)
        .accessibilityLabel(field == .listenPort ? "Listen port, empty chooses Auto" : "Destination port")
        .invalidBorder(message(field) != nil)
    }
    @ViewBuilder private func fieldErrors(_ fields: [SSHForwardingField]) -> some View {
        ForEach(fields, id: \.self) { field in
            if let message = message(field) { hint(message, error: true) }
        }
    }
    private func hint(_ text: String, error: Bool = false) -> some View {
        Text(text).font(.callout).foregroundStyle(error ? Color.red : ConnectionFormLayout.captionColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, ConnectionFormLayout.labelWidth + ConnectionFormLayout.gap)
    }
}

// Native popup fills its allocated address column instead of centering an intrinsic-width label.
private struct LoopbackAddressPicker: NSViewRepresentable {
    @Binding var selection: String
    private static let addresses = ["127.0.0.1", "::1"]
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.addItems(withTitles: Self.addresses)
        control.controlSize = .regular
        control.target = context.coordinator
        control.action = #selector(Coordinator.choose(_:))
        control.setAccessibilityLabel("Local loopback listen address")
        return control
    }
    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = Self.addresses.contains(selection) ? Self.addresses : Self.addresses + [selection]
        if control.itemTitles != titles {
            control.removeAllItems()
            control.addItems(withTitles: titles)
        }
        control.selectItem(withTitle: selection)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: 28)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: LoopbackAddressPicker
        init(_ parent: LoopbackAddressPicker) { self.parent = parent }
        @objc func choose(_ control: NSPopUpButton) {
            guard let value = control.titleOfSelectedItem, LoopbackAddressPicker.addresses.contains(value) else {
                return
            }
            parent.selection = value
        }
    }
}
