import AppKit
import SwiftUI

struct ScreenshotSettingsView: View {
    @AppStorage("screenshot.saveToFolder") private var save = true
    @AppStorage("screenshot.copyToClipboard") private var copy = false
    @AppStorage("screenshot.format") private var format = ScreenshotFormat.png
    @AppStorage("screenshot.showPreview") private var preview = true
    @AppStorage("screenshot.playSound") private var sound = false
    @AppStorage(ScreenshotFolder.pathKey) private var path = ""
    @AppStorage(ScreenshotFolder.bookmarkKey) private var bookmark: Data?
    @State private var folderStatus = ""
    @State private var folderReady = false
    @State private var destinationWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormSection(title: String(localized: "After Capture")) {
                SettingsRow(label: String(localized: "After capture")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Save to folder", isOn: destination($save, other: copy))
                        Text("Saves the screenshot as an image file.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Copy to clipboard", isOn: destination($copy, other: save))
                        Text("Pastes as an image into most apps.").font(.caption).foregroundStyle(.secondary)
                        if destinationWarning {
                            Text("Choose at least one destination.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                SettingsRow(label: String(localized: "Folder")) {
                    VStack(alignment: .leading, spacing: 7) {
                        SettingsPathRow(url: ScreenshotFolder().url)
                        HStack {
                            Button("Choose Folder…") { choose(ScreenshotFolder().url) }
                            Button("Use Desktop") { choose(ScreenshotFolder.desktop, desktop: true) }
                                .disabled(ScreenshotFolder().url.path == ScreenshotFolder.desktop.path)
                            Button("Reveal") { ScreenshotFolder().reveal() }
                                .accessibilityLabel("Reveal screenshots folder in Finder").disabled(!folderReady)
                        }
                        StorageStatusRow(text: folderStatus, status: folderReady ? .ok : .attention)
                    }.disabled(!save)
                }
            }
            FormSection(title: String(localized: "Image")) {
                SettingsRow(label: String(localized: "Format")) {
                    Picker("Format", selection: $format) {
                        Text("PNG").tag(ScreenshotFormat.png)
                        Text("JPEG").tag(ScreenshotFormat.jpeg)
                    }.labelsHidden().fixedSize()
                }
                SettingsRow(
                    label: String(localized: "Resolution"),
                    caption: String(localized: "Remote sessions keep their native pixel size.")
                ) {
                    Text("Native")
                }
            }
            FormSection(title: String(localized: "Feedback")) {
                SettingsRow(label: String(localized: "After capture")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Show preview", isOn: $preview)
                        Toggle("Play sound", isOn: $sound)
                    }
                }
            }
        }
        .onAppear {
            if !save && !copy { save = true }
            updateStatus()
        }
        .onChange(of: path) { updateStatus() }
        .onChange(of: bookmark) { updateStatus() }
    }

    private func destination(_ value: Binding<Bool>, other: Bool) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue },
            set: { enabled in
                destinationWarning = !enabled && !other
                if destinationWarning {
                    ScreenshotService.announce(String(localized: "Choose at least one destination."))
                } else {
                    value.wrappedValue = enabled
                }
            })
    }

    private func choose(_ initial: URL, desktop: Bool = false) {
        do {
            try ScreenshotFolder.choose(at: initial, requireDesktop: desktop)
            updateStatus()
        } catch {
            folderReady = false
            folderStatus = error.localizedDescription
        }
    }

    private func updateStatus() {
        do {
            try ScreenshotFolder().check()
            folderReady = true
            folderStatus = String(localized: "Farcast can save to this folder")
        } catch {
            folderReady = false
            folderStatus = error.localizedDescription
        }
    }
}
