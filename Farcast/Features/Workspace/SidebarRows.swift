import SwiftUI

/// Visible content bounds keep the root drop target below rows, including folder children.
struct SidebarContentBoundsKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

struct SidebarRootDropTarget: View {
    let dropConnections: ([String]) -> Bool
    @State private var targeted = false

    var body: some View {
        Rectangle().fill(targeted ? Color.accentColor.opacity(0.12) : .clear)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { values, _ in
                dropConnections(values)
            } isTargeted: {
                targeted = $0
            }
            .accessibilityHidden(true)
    }
}

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
            .anchorPreference(key: SidebarContentBoundsKey.self, value: .bounds) { [$0] }
            .accessibilityLabel(title).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .help(expanded ? "Collapse \(title)" : "Expand \(title)")
    }
}

struct SidebarFolderLabel: View {
    let name: String
    let count: Int
    let expanded: Bool
    let dropConnections: ([String]) -> Bool
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "folder.fill" : "folder")
                .foregroundStyle(Color.accentColor.opacity(0.65)).frame(width: 22)
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(count, format: .number).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .opacity(!expanded || hovering ? 1 : 0)
        }.frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
            .background {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2))
                }
            }
            .dropDestination(for: String.self) { values, _ in
                dropConnections(values)
            } isTargeted: {
                dropTargeted = $0
            }
            .anchorPreference(key: SidebarContentBoundsKey.self, value: .bounds) { [$0] }
            .onHover { hovering = $0 }
            .help("\(name), \(count) items")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), folder")
            .accessibilityValue("\(expanded ? "expanded" : "collapsed"), \(count) items")
    }
}

struct ConnectionProtocolIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let kind: RemoteProtocol
    var routed = false
    var vpnState: SessionState = .disconnected
    var selected = false
    var size: CGFloat = 16

    private var tint: Color {
        if selected { return selectedTint }
        // Darker light-mode shades and lighter dark-mode shades preserve the strokes.
        let dark = colorScheme == .dark
        let increased = contrast == .increased
        switch kind {
        case .ssh:
            return dark
                ? Color(red: increased ? 0.55 : 0.35, green: 0.85, blue: 0.86)
                : Color(red: 0, green: increased ? 0.34 : 0.42, blue: increased ? 0.38 : 0.46)
        case .rdp:
            return dark
                ? Color(red: increased ? 0.83 : 0.72, green: increased ? 0.79 : 0.67, blue: 1)
                : Color(red: increased ? 0.27 : 0.32, green: increased ? 0.20 : 0.27, blue: 0.72)
        case .vnc:
            return dark
                ? Color(red: 1, green: increased ? 0.79 : 0.71, blue: 0.42)
                : Color(red: increased ? 0.53 : 0.64, green: increased ? 0.23 : 0.29, blue: 0)
        }
    }

    private var selectedTint: Color {
        let light: NSColor
        let dark: NSColor
        switch kind {
        case .ssh:
            light = NSColor(srgbRed: 0.75, green: 0.95, blue: 0.95, alpha: 1)
            dark = NSColor(srgbRed: 0, green: 0.20, blue: 0.24, alpha: 1)
        case .rdp:
            light = NSColor(srgbRed: 0.90, green: 0.87, blue: 1, alpha: 1)
            dark = NSColor(srgbRed: 0.20, green: 0.10, blue: 0.50, alpha: 1)
        case .vnc:
            light = NSColor(srgbRed: 1, green: 0.90, blue: 0.75, alpha: 1)
            dark = NSColor(srgbRed: 0.35, green: 0.13, blue: 0, alpha: 1)
        }
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }
        let background = luminance(.selectedContentBackgroundColor)
        func ratio(_ color: NSColor) -> Double {
            let foreground = luminance(color)
            return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
        }
        return Color(nsColor: ratio(light) >= ratio(dark) ? light : dark)
    }

    var body: some View {
        Image(systemName: kind.icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size + 6, height: size + 6)
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
    @Environment(\.controlActiveState) private var controlActiveState
    let connection: SavedConnection
    @ObservedObject var workspace: Workspace
    let tunnel: SavedWireGuard?
    var selected = false
    var selectionEmphasized = false

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
        return lines.joined(separator: "\n")
    }
    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let session = workspace.sidebarSession(for: connection.id)
                ConnectionProtocolIcon(
                    kind: connection.kind, routed: connection.wireGuardID != nil,
                    vpnState: session?.vpnState ?? .disconnected,
                    selected: selected && selectionEmphasized && controlActiveState == .key
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
                    if connection.wireGuardID != nil {
                        Text(" via " + (tunnel?.name ?? "Unavailable VPN"))
                            .truncationMode(.middle).layoutPriority(2)
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(connection.kind.rawValue)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            SidebarSessionState(workspace: workspace, profileID: connection.id)
        }.padding(.vertical, 3).contentShape(Rectangle())
            .help(help).accessibilityElement(children: .contain)
            .accessibilityLabel(
                "\(connection.name), \(connection.kind.rawValue)")
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
