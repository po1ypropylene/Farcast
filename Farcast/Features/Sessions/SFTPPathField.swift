import AppKit
import SwiftUI

struct SFTPPathField: View {
    let title: String
    @Binding var text: String
    let paths: [String]
    let open: (String) -> Void

    @State private var showing = false
    @State private var filtering = false
    @State private var selection: String?
    @Environment(\.isEnabled) private var enabled

    private var matches: [String] {
        guard filtering, !text.isEmpty else { return paths }
        return paths.filter { $0.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        PathEditor(
            title: title, text: $text,
            began: {
                filtering = false
                selection = nil
                showing = true
            },
            edited: {
                filtering = true
                selection = nil
                showing = true
            }, ended: dismiss, command: handle,
            hasHistory: !paths.isEmpty,
            toggle: { focus in
                let shouldOpen = !showing || matches.isEmpty
                focus()
                selection = nil
                filtering = false
                showing = shouldOpen
            }
        )
        .frame(height: 24)
        .overlay(alignment: .topLeading) {
            if enabled && showing && !matches.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(matches, id: \.self) { path in
                                Button {
                                    submit(path)
                                } label: {
                                    Text(verbatim: path)
                                        .lineLimit(1).truncationMode(.middle)
                                        .padding(.horizontal, 6)
                                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(
                                    selection == path ? Color(nsColor: .selectedMenuItemTextColor) : .primary
                                )
                                .background(
                                    selection == path ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                                .accessibilityAddTraits(selection == path ? .isSelected : [])
                                .id(path)
                            }
                        }.padding(3)
                    }
                    .frame(height: CGFloat(min(matches.count, 6) * 22 + 6))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .onChange(of: selection) { _, path in
                        if let path { proxy.scrollTo(path) }
                    }
                }
                .offset(y: 26)
            }
        }
        .font(.callout)
        .onChange(of: enabled) { _, enabled in if !enabled { dismiss() } }
    }

    private func dismiss() {
        showing = false
        selection = nil
    }

    private func submit(_ path: String) {
        dismiss()
        text = path
        open(path)
    }

    private func handle(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            submit(showing ? selection.flatMap { matches.contains($0) ? $0 : nil } ?? text : text)
        case #selector(NSResponder.cancelOperation(_:)):
            guard showing else { return false }
            dismiss()
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard !matches.isEmpty else { return false }
            showing = true
            let down = command == #selector(NSResponder.moveDown(_:))
            if let selection, let index = matches.firstIndex(of: selection) {
                self.selection = matches[min(max(index + (down ? 1 : -1), 0), matches.count - 1)]
            } else {
                selection = down ? matches.first : matches.last
            }
        default: return false
        }
        return true
    }
}

/// The AppKit field editor routes arrow keys and Return before normal text commands.
private struct PathEditor: NSViewRepresentable {
    let title: String
    @Binding var text: String
    let began: () -> Void
    let edited: () -> Void
    let ended: () -> Void
    let command: (Selector) -> Bool

    let hasHistory: Bool
    let toggle: (() -> Void) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSStackView {
        let field = FolderTextField()
        field.delegate = context.coordinator
        field.becameFocused = { [weak coordinator = context.coordinator] in coordinator?.editor.began() }
        field.font = .preferredFont(forTextStyle: .callout)
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = NSButton(
            image: NSImage(systemSymbolName: "arrowtriangle.down.fill", accessibilityDescription: nil)!,
            target: context.coordinator, action: #selector(Coordinator.toggleHistory))
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Show recent folders"
        button.setAccessibilityLabel("Recent folders for " + title)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        context.coordinator.field = field
        context.coordinator.button = button
        let row = NSStackView(views: [field, button])
        row.spacing = 0
        return row
    }

    func updateNSView(_ row: NSStackView, context: Context) {
        guard let field = context.coordinator.field else { return }
        context.coordinator.button?.isEnabled = context.environment.isEnabled && hasHistory
        context.coordinator.editor = self
        field.isEnabled = context.environment.isEnabled
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var editor: PathEditor
        weak var field: NSTextField?
        weak var button: NSButton?
        @objc func toggleHistory() {
            guard let field else { return }
            editor.toggle { field.window?.makeFirstResponder(field) }
        }
        init(_ editor: PathEditor) { self.editor = editor }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            editor.text = field.stringValue
            editor.edited()
        }

        func controlTextDidEndEditing(_ notification: Notification) { editor.ended() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            return editor.command(commandSelector)
        }
    }
}

private final class FolderTextField: NSTextField {
    var becameFocused: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused { becameFocused?() }
        return focused
    }
}
