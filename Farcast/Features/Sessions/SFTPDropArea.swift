import AppKit
import SwiftUI

/// Owns the destination independently of the native list's row/insertion handling.
struct SFTPDropArea<Content: View>: NSViewRepresentable {
    var enabled: Bool
    @Binding var isTargeted: Bool
    var accept: ([NSItemProvider]) -> Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> SFTPDropContainer<Content> {
        let view = SFTPDropContainer(content: content())
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SFTPDropContainer<Content>, context: Context) {
        view.host.rootView = content()
        view.enabled = enabled
        view.targetChanged = { isTargeted = $0 }
        view.accept = accept
    }
}

final class SFTPDropContainer<Content: View>: NSView {
    let host: NSHostingView<Content>
    var enabled = false
    var targetChanged: (Bool) -> Void = { _ in }
    var accept: ([NSItemProvider]) -> Bool = { _ in false }

    init(content: Content) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Rows remain drag sources and retain native selection/context menus. Only this
        // ancestor accepts drops, so AppKit never offers row insertion or folder targets.
        func clearDestinations(_ view: NSView) {
            view.unregisterDraggedTypes()
            for child in view.subviews { clearDestinations(child) }
        }
        clearDestinations(host)
    }

    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let supported = enabled && sender.draggingPasteboard.availableType(from: [.fileURL, .string]) != nil
        targetChanged(supported)
        return supported ? .copy : []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { targetChanged(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { targetChanged(false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        targetChanged(false)
        guard enabled else { return false }
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL], !urls.isEmpty
        {
            return accept(urls.map { NSItemProvider(object: $0) })
        }
        guard let token = pasteboard.string(forType: .string) else { return false }
        return accept([NSItemProvider(object: token as NSString)])
    }
}
