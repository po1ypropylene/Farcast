import SwiftUI

/// Compact pointer controls follow native macOS sizing, help and keyboard behavior.
struct IconActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var size: CGFloat = 24

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .accessibilityLabel(title)
        .help(title)
    }
}

struct PrimaryActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.glassProminent)
            .controlSize(.regular)
            .accessibilityLabel(title)
    }
}
