import AppKit
import SwiftUI

// Shared by the connection form and saved/live tunnel editors.
enum ConnectionFormLayout {
    static let labelWidth: CGFloat = 128
    static let gap: CGFloat = 12
    static let inset: CGFloat = 24
    static let captionColor = Color.primary.opacity(0.8)
}

struct ConnectionFormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ConnectionFormLayout.gap) {
            Text(label).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: ConnectionFormLayout.labelWidth, alignment: .trailing)
            content().frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        }
    }
}

struct UnderlineTabButton: View {
    let title: String
    let selected: Bool
    var invalid = false
    var enabled = true
    var help: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.body.weight(selected ? .semibold : .regular))
                if invalid { Circle().fill(.red).frame(width: 5, height: 5).accessibilityHidden(true) }
            }.foregroundStyle(selected ? Color.primary : .secondary)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(.tint).frame(height: 2) }
                }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel(invalid ? "\(title), invalid settings" : title)
            .accessibilityValue(selected ? "Selected" : "")
            .help(help.isEmpty ? title : help)
    }
}

// Reveal the laid-out native card before focusing a field in a long SwiftUI scroll view.
struct EditorValidationReveal: NSViewRepresentable {
    let request: UUID?
    let focus: () -> Void
    func makeNSView(context: Context) -> RevealView { RevealView() }
    func updateNSView(_ view: RevealView, context: Context) {
        view.request = request
        view.focus = focus
        view.needsLayout = true
        DispatchQueue.main.async { view.revealIfReady() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RevealView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    final class RevealView: NSView {
        var request: UUID?
        var focus: (() -> Void)?
        private var applied: UUID?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            revealIfReady()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
        }
        func revealIfReady() {
            guard let request, applied != request, window != nil, bounds.width > 0, bounds.height > 0,
                enclosingScrollView != nil
            else { return }
            applied = request
            scrollToVisible(bounds)
            DispatchQueue.main.async { [weak self] in self?.focus?() }
        }
    }
}
