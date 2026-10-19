import SwiftUI

struct SidebarSectionHeader: View {
    let title: String
    @Binding var expanded: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack {
                Text(title.uppercased()).tracking(0.3)
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .opacity(hovering || !expanded ? 1 : 0)
            }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.top, 14).padding(.bottom, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel(title).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .help(expanded ? "Collapse \(title)" : "Expand \(title)")
    }
}

struct SidebarFolderLabel: View {
    let name: String
    let count: Int
    let expanded: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "folder.fill" : "folder")
                .foregroundStyle(Color.accentColor.opacity(0.65)).frame(width: 22)
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(count, format: .number).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .opacity(!expanded || hovering ? 1 : 0)
        }.frame(minHeight: 28).contentShape(Rectangle()).onHover { hovering = $0 }
            .help("\(name), \(count) items")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), folder")
            .accessibilityValue("\(expanded ? "expanded" : "collapsed"), \(count) items")
    }
}

struct ConnectionProtocolIcon: View {
    let kind: RemoteProtocol
    var routed = false
    var vpnState: SessionState = .disconnected

    var body: some View {
        Image(systemName: kind.icon)
            .font(.system(size: 16))
            .foregroundStyle(kind == .ssh ? Color.teal : kind == .rdp ? Color.indigo : Color.orange)
            .frame(width: 22, height: 22)
            .overlay(alignment: .bottomTrailing) {
                if routed {
                    Image(systemName: "lock.shield.fill").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(vpnState.color)
                        .background(.background, in: Circle())
                        .offset(x: 3, y: 2)
                }
            }
            .accessibilityHidden(true)
    }
}

struct SidebarConnectionRow: View {
    let connection: SavedConnection
    @ObservedObject var workspace: Workspace
    let folder: String
    let tunnel: SavedWireGuard?
    let toggleFavorite: () -> Void
    @State private var hovering = false

    private var destination: String {
        let host = connection.host.contains(":") ? "[\(connection.host)]" : connection.host
        return "\(connection.username.isEmpty ? "" : connection.username + "@")\(host):\(connection.port)"
    }
    private var help: String {
        var lines = ["\(connection.name) · \(connection.kind.rawValue)", destination]
        if connection.wireGuardID != nil {
            lines.append(
                "Via \((try? tunnel?.configuration().protocolName) ?? "VPN"): \(tunnel?.name ?? "Unavailable profile")")

        }
        if !folder.isEmpty { lines.append(folder) }
        if connection.favorite { lines.append("Favorite shortcut") }
        return lines.joined(separator: "\n")
    }
    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let session = workspace.sidebarSession(for: connection.id)
                ConnectionProtocolIcon(
                    kind: connection.kind, routed: connection.wireGuardID != nil,
                    vpnState: session?.vpnState ?? .disconnected
                )
                .help(
                    connection.wireGuardID == nil
                        ? connection.kind.rawValue
                        : "\(connection.kind.rawValue), VPN \(session?.vpnState.title ?? "Disconnected")")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name).font(.system(size: 13)).lineLimit(1)
                HStack(spacing: 0) {
                    if !connection.username.isEmpty {
                        Text(connection.username).truncationMode(.head).layoutPriority(-1)
                        Text("@")
                    }
                    Text(connection.host).truncationMode(.middle).layoutPriority(1)
                    if !folder.isEmpty {
                        Text(" · " + folder).truncationMode(.middle).frame(maxWidth: 64).layoutPriority(2)
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if connection.favorite || hovering {
                Button(action: toggleFavorite) {
                    Image(systemName: connection.favorite ? "star.fill" : "star")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
                    .help(connection.favorite ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel(connection.favorite ? "Remove from Favorites" : "Add to Favorites")
            }
            SidebarSessionState(workspace: workspace, profileID: connection.id)
        }.padding(.vertical, 3).contentShape(Rectangle()).onHover { hovering = $0 }
            .help(help).accessibilityElement(children: .contain)
            .accessibilityLabel(
                "\(connection.name), \(connection.kind.rawValue)\(connection.favorite ? ", favorite" : "")")
    }
}

struct SidebarConnectionInfo: View {
    let connection: SavedConnection
    let folder: String
    let tunnel: SavedWireGuard?
    var body: some View {
        Form {
            LabeledContent("Protocol", value: connection.kind.rawValue)
            LabeledContent(
                "Address",
                value:
                    "\(connection.username.isEmpty ? "" : connection.username + "@")\(connection.host):\(connection.port)"
            )
            if !folder.isEmpty { LabeledContent("Folder", value: folder) }
            if connection.wireGuardID != nil {
                LabeledContent("VPN", value: tunnel?.name ?? "Unavailable profile")
            }
            LabeledContent("Last connected", value: connection.lastConnected?.formatted() ?? "Never")
            if !connection.notes.isEmpty { LabeledContent("Notes", value: connection.notes) }
        }.formStyle(.grouped).textSelection(.enabled).frame(width: 420)
    }
}
