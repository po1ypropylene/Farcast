import AppKit
import QuartzCore
import SwiftUI

/// Settings uses the existing card appearance and one shared control column.
enum SettingsLayout {
    static let width: CGFloat = 620
    static let labelWidth: CGFloat = 190
    static let inset: CGFloat = 20
}

struct SettingsRow<Content: View>: View {
    let label: String
    var caption = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).frame(width: SettingsLayout.labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                content()
                if !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 3)
    }
}

struct PendingTag: View {
    var body: some View {
        Text("Pending").font(.caption).foregroundStyle(.tint)
            .accessibilityLabel("Pending change")
    }
}

struct InfoPopoverButton: View {
    let title: String
    let detail: String
    @State private var showing = false
    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(detail).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(width: 340)
        }
    }
}

struct StorageStatusRow: View {
    enum Status { case ok, attention, failure }
    let text: String
    var status: Status = .ok
    var body: some View {
        Label(
            text,
            systemImage: status == .ok
                ? "checkmark.circle.fill" : status == .attention ? "exclamationmark.triangle.fill" : "xmark.circle.fill"
        )
        .foregroundStyle(status == .ok ? Color.green : status == .attention ? .orange : .red)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsPathRow: View {
    let url: URL
    var isDefault = false
    private var abbreviated: String {
        let home = ConnectionStorage.realHome.path
        let path = url.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    var body: some View {
        HStack(spacing: 4) {
            Text(abbreviated).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .help(url.path).accessibilityLabel(url.path)
                .contextMenu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    }
                }
            if isDefault { Text("(default location)").foregroundStyle(.secondary).font(.caption) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

/// The footer occupies real layout space, so even a short screen can reach the last content line.
struct SettingsPane<Content: View, Footer: View>: View {
    var reportHeight: (CGFloat) -> Void = { _ in }
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content().padding(SettingsLayout.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background { heightReader }
            }.scrollBounceBehavior(.basedOnSize)
            footer().fixedSize(horizontal: false, vertical: true).background { heightReader }
        }
        .onPreferenceChange(SettingsContentHeightKey.self) { height in
            guard height > 0 else { return }
            DispatchQueue.main.async { reportHeight(height) }
        }
    }
    private var heightReader: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SettingsContentHeightKey.self, value: geometry.size.height)
        }
    }
}

/// Keeps the native Settings window's top edge stable and tracks the current screen's usable height.
struct SettingsWindowSizing: NSViewRepresentable {
    var contentHeight: CGFloat
    @Binding var maximumContentHeight: CGFloat
    let selectedTab: String
    let selectTab: (String) -> Void
    let controller: ConnectionStorageController
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) {
        view.updateMaximum = { maximumContentHeight = $0 }
        view.selectedTab = selectedTab
        view.selectTab = selectTab
        view.desiredHeight = contentHeight
        view.controller = controller
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: WindowView, coordinator: ()) { view.restoreDelegate() }
    final class WindowView: NSView, NSWindowDelegate, NSToolbarDelegate {
        var desiredHeight: CGFloat = 600
        var updateMaximum: ((CGFloat) -> Void)?
        var selectedTab = "general"
        var selectTab: ((String) -> Void)?
        private var originalToolbar: NSToolbar?
        private let toolbarID = NSToolbar.Identifier("FarcastSettings")
        weak var controller: ConnectionStorageController?
        private weak var originalDelegate: NSWindowDelegate?
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false
        private var resizing = false
        override func layout() {
            super.layout()
            scheduleUpdate()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            if window.delegate !== self {
                originalDelegate = window.delegate
                window.delegate = self
            }
            originalToolbar = window.toolbar
            installToolbar(window)
            window.styleMask.remove([.resizable, .miniaturizable])
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            for name in [
                NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification,
                NSApplication.didChangeScreenParametersNotification,
            ] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleUpdate() }
                    })
            }
            scheduleUpdate()
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        func restoreDelegate() {
            if let window {
                if window.delegate === self { window.delegate = originalDelegate }
                if window.toolbar?.identifier == toolbarID { window.toolbar = originalToolbar }
            }
        }
        private func installToolbar(_ window: NSWindow) {
            if window.toolbar?.identifier != toolbarID {
                let toolbar = NSToolbar(identifier: toolbarID)
                toolbar.delegate = self
                toolbar.displayMode = .iconAndLabel
                toolbar.allowsUserCustomization = false
                window.toolbar = toolbar
                window.toolbarStyle = .preference
            }
            window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(selectedTab)
            window.title = selectedTab == "storage" ? "Storage" : "General"
        }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [NSToolbarItem.Identifier("general"), NSToolbarItem.Identifier("storage")]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }
        func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }
        func toolbar(
            _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: identifier)
            let storage = identifier.rawValue == "storage"
            item.label = storage ? "Storage" : "General"
            item.image = NSImage(
                systemSymbolName: storage ? "externaldrive" : "gearshape", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(selectPane(_:))
            return item
        }
        @objc private func selectPane(_ sender: NSToolbarItem) { selectTab?(sender.itemIdentifier.rawValue) }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            originalDelegate?.responds(to: selector) == true ? originalDelegate : super.forwardingTarget(for: selector)
        }
        func scheduleUpdate() {
            guard !scheduled && !resizing else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.resize()
            }
        }
        private func resize() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            if window.delegate !== self {
                originalDelegate = window.delegate
                window.delegate = self
            }
            installToolbar(window)
            let visible = screen.visibleFrame
            let chrome = window.frame.height - window.contentLayoutRect.height
            let maximum = max(1, visible.height - 40 - chrome)
            updateMaximum?(maximum)
            var frame = NSRect(x: 0, y: 0, width: SettingsLayout.width, height: min(desiredHeight, maximum) + chrome)
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            guard
                abs(frame.height - window.frame.height) > 0.5 || abs(frame.width - window.frame.width) > 0.5
                    || abs(frame.minY - window.frame.minY) > 0.5
            else { return }
            window.minSize = NSSize(width: frame.width, height: 0)
            window.maxSize = NSSize(width: frame.width, height: visible.height)
            resizing = true
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration =
                        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !window.isVisible ? 0 : 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                },
                completionHandler: { [weak self] in
                    guard let self else { return }
                    self.resizing = false
                    self.scheduleUpdate()
                })
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let draft = controller?.settingsDraft, draft.dirty else {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            let alert = NSAlert()
            alert.messageText = "Apply pending storage changes?"
            alert.informativeText = draft.pendingSummary
            alert.addButton(withTitle: "Apply Changes…")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
                MainActor.assumeIsolated {
                    guard let sender else { return }
                    if response == .alertFirstButtonReturn {
                        self?.selectTab?("storage")
                        draft.reviewRequested = true
                        draft.closeAfterReview = { [weak sender] in sender?.performClose(nil) }
                    } else if response == .alertSecondButtonReturn {
                        draft.revert()
                        sender.performClose(nil)
                    }
                }
            }
            return false
        }
    }
}
