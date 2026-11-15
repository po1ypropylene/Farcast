import AppKit
import SwiftUI

struct AppSettings: View {
    let storageController: ConnectionStorageController
    @StateObject private var storageDraft: ConnectionStorageDraft
    init(storageController: ConnectionStorageController? = nil) {
        let controller = storageController ?? .shared
        self.storageController = controller
        _storageDraft = StateObject(wrappedValue: ConnectionStorageDraft(controller: controller))
    }
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("settings.selectedTab") private var selectedTab = "general"
    @AppStorage("restoreWorkspace") private var restoreWorkspace = true
    @AppStorage("reuseConnectedSession") private var reuseConnectedSession = false
    @AppStorage(SSHInteractionView.rightClickPreference) private var sshRightClickAction = "menu"
    @AppStorage("reconnectRDPAfterWake") private var reconnectRDPAfterWake = false
    @AppStorage("experimentalRDP") private var experimentalRDP = false
    @State private var paneHeights: [String: CGFloat] = [:]
    @State private var maximumHeight: CGFloat = 900
    @State private var notices: BundledNotices?
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            if selectedTab == "storage" {
                ConnectionStorageSettings(
                    controller: storageController, draft: storageDraft, reportHeight: { paneHeights["storage"] = $0 })
            } else {
                SettingsPane(reportHeight: { paneHeights["general"] = $0 }) {
                    general
                } footer: {
                    EmptyView()
                }
            }
        }.controlSize(.regular)
            .frame(width: SettingsLayout.width, height: min(paneHeights[selectedTab] ?? 600, maximumHeight))
            .background {
                SettingsWindowSizing(
                    contentHeight: paneHeights[selectedTab] ?? 600, maximumContentHeight: $maximumHeight,
                    selectedTab: selectedTab, selectTab: { selectedTab = $0 }, controller: storageController)
            }
            .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
            .sheet(item: $notices) { BundledNoticesView(kind: $0) { notices = nil } }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormSection(title: "General") {
                SettingsRow(label: "Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }.labelsHidden()
                }
                SettingsRow(
                    label: "When a connection is already open",
                    caption:
                        "Applies to the same saved SSH, RDP or VNC connection. Popped-out sessions come to the front."
                ) {
                    Picker("When a connection is already open", selection: $reuseConnectedSession) {
                        Text("Open a new session").tag(false)
                        Text("Switch to connected session").tag(true)
                    }.labelsHidden()
                }
                SettingsRow(label: "", caption: "Restored tabs stay disconnected until you reconnect.") {
                    Toggle("Restore session tabs at launch", isOn: $restoreWorkspace)
                }
            }
            FormSection(title: "Terminal") {
                SettingsRow(
                    label: "SSH terminal right-click",
                    caption: "Shift–right-click uses local actions in mouse-aware terminal apps."
                ) {
                    Picker("SSH terminal right-click", selection: $sshRightClickAction) {
                        Text("Show context menu").tag("menu")
                        Text("Copy or paste automatically").tag("automatic")
                    }.labelsHidden()
                    if sshRightClickAction == "automatic" {
                        Text(
                            "Copies selected text or the clicked output line; pastes on the active cursor line. Files are ignored. Cut is unavailable."
                        )
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            FormSection(title: "Remote Desktop") {
                SettingsRow(
                    label: "",
                    caption:
                        "RDP disconnects when the Mac sleeps. Farcast reconnects after waking using this session’s sign-in details."
                ) {
                    Toggle("Automatically reconnect RDP after Mac wakes", isOn: $reconnectRDPAfterWake)
                }
                SettingsRow(
                    label: "",
                    caption:
                        "Uses H.264 graphics and faster input handling. Applies when connecting or reconnecting. Turn off if you see display problems."
                ) {
                    Toggle(isOn: $experimentalRDP) {
                        HStack {
                            Text("Experimental RDP features")
                            Text("Experimental").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    InfoPopoverButton(
                        title: "Experimental RDP features",
                        detail:
                            "Enables GFX/H.264 negotiation with a compatible-graphics fallback, immediate input wakeups, dirty-region updates and diagnostic metrics. The server chooses the graphics codec."
                    )
                }
            }
            FormSection(title: "About") {
                ViewThatFits(in: .horizontal) {
                    Grid(
                        alignment: .leadingFirstTextBaseline, horizontalSpacing: SettingsLayout.labelGap,
                        verticalSpacing: SettingsLayout.rowSpacing
                    ) {
                        GridRow {
                            Text("Version").frame(width: SettingsLayout.labelWidth, alignment: .trailing)
                            versionValue
                            copyButton
                        }
                        GridRow {
                            Text("Resources").frame(width: SettingsLayout.labelWidth, alignment: .trailing)
                            Button("Acknowledgements…") { notices = .acknowledgements }
                            Button {
                                notices = .releaseNotes
                            } label: {
                                Text("Release Notes…").frame(maxWidth: .infinity)
                            }
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack {
                        SettingsRow(label: "Version") {
                            versionValue
                            copyButton
                        }
                        SettingsRow(label: "Licenses") { Button("Acknowledgements…") { notices = .acknowledgements } }
                        SettingsRow(label: "What’s new") { Button("Release Notes…") { notices = .releaseNotes } }
                    }
                }.buttonStyle(.bordered).controlSize(.regular)

            }
        }
    }
    private var versionValue: some View {
        Text(Self.version).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
            .accessibilityLabel("Version, " + Self.version)
    }
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                "Farcast \(Self.version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), arm64",
                forType: .string)
            copyReset?.cancel()
            copied = true
            AccessibilityNotification.Announcement("Version copied").post()
            copyReset = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                copied = false
            }
        } label: {
            ZStack {
                Text("Copy Version").opacity(copied ? 0 : 1)
                Label("Copied", systemImage: "checkmark").opacity(copied ? 1 : 0)
            }.frame(maxWidth: .infinity)
        }.accessibilityLabel("Copy version information")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: copied)
            .onDisappear {
                copyReset?.cancel()
                copied = false
            }
    }
    private static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (Build \(build))"
    }
}

enum BundledNotices: String, Identifiable {
    case acknowledgements = "Acknowledgements"
    case releaseNotes = "Release Notes"
    var id: String { rawValue }
}
private struct BundledNoticesView: View {
    let kind: BundledNotices
    let dismiss: () -> Void
    private var documents: [(String, String)] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        if kind == .releaseNotes {
            return [
                (
                    "Release Notes",
                    (try? String(contentsOf: resources.appendingPathComponent("CHANGELOG.md"), encoding: .utf8))
                        ?? "Release notes are unavailable in this test host."
                )
            ]
        }
        let directory = resources.appendingPathComponent("ThirdParty")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let urls =
            [resources.appendingPathComponent("LICENSE")]
            + files.filter { $0.lastPathComponent != "README.md" }.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        return urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.lastPathComponent, text)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind.rawValue).font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(documents.enumerated()), id: \.offset) { _, document in
                        Text(document.0).font(.headline).accessibilityAddTraits(.isHeader)
                        Text(document.1).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 640, height: 500)
    }
}
