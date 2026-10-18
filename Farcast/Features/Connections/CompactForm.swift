import SwiftUI
import UniformTypeIdentifiers

/// Compact cards shared by Settings and the VPN editor; native controls retain keyboard behavior.
struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5)) }
        }
    }
}

struct FormRow<Content: View>: View {
    let label: String
    var caption = ""
    var error: String?
    var active = false
    var focus: (() -> Void)?
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let focus {
                Text(label).frame(width: 128, alignment: .leading)
                    .contentShape(Rectangle()).onTapGesture { focus() }
                    .accessibilityAddTraits(.isButton).accessibilityAction { focus() }
            } else {
                Text(label).frame(width: 128, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                content()
                if !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .background(active ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct FormTextField: View {
    let label: String
    let id: String
    @Binding var text: String
    var prompt = "Optional"
    var caption = ""
    var error: String?
    var secret = false
    var key = false
    var selectionRequest: UUID?
    var focus: FocusState<String?>.Binding
    var submit: () -> Void = {}
    @State private var textSelection: TextSelection?
    @State private var revealed = false
    @State private var hovered = false

    var body: some View {
        FormRow(
            label: label, caption: caption, error: error, active: focus.wrappedValue == id,
            focus: { focus.wrappedValue = id }
        ) {
            HStack(spacing: 2) {
                Group {
                    if secret && !revealed {
                        SecureField(label, text: $text, prompt: Text(prompt).foregroundStyle(.tertiary))
                    } else {
                        TextField(
                            label, text: $text, selection: $textSelection,
                            prompt: Text(prompt).foregroundStyle(.tertiary)
                        )
                        .task(id: selectionRequest) {
                            guard selectionRequest != nil else { return }
                            focus.wrappedValue = id
                            textSelection = TextSelection(range: text.startIndex..<text.endIndex)
                        }
                        .font(key ? .system(.body, design: .monospaced) : .body)
                    }
                }
                .textFieldStyle(.plain).labelsHidden().padding(.horizontal, 8)
                .focused(focus, equals: id).onSubmit(submit)
                .accessibilityLabel(label.replacingOccurrences(of: " *", with: "")).accessibilityHint(error ?? caption)
                if secret {
                    Button {
                        revealed.toggle()
                        focus.wrappedValue = id
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye").frame(width: 28, height: 28).contentShape(
                            Rectangle())
                    }
                    .help(revealed ? "Hide \(label)" : "Show \(label)")
                    .accessibilityLabel(revealed ? "Hide \(label)" : "Show \(label)")
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first {
                            text = value
                            focus.wrappedValue = id
                        }
                    }.labelStyle(.iconOnly).help("Paste \(label)").accessibilityLabel("Paste \(label)")
                    if !text.isEmpty {
                        Button {
                            text = ""
                            focus.wrappedValue = id
                        } label: {
                            Image(systemName: "xmark.circle").frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .help("Clear \(label)").accessibilityLabel("Clear \(label)")
                    }
                }
            }
            .buttonStyle(.borderless).controlSize(.regular)
            .frame(minHeight: 28)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        error != nil
                            ? Color.red
                            : focus.wrappedValue == id
                                ? .accentColor : Color(nsColor: .separatorColor).opacity(hovered ? 1 : 0.6),
                        lineWidth: focus.wrappedValue == id ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }.onHover { hovered = $0 }
        }.id(id)
    }
}
