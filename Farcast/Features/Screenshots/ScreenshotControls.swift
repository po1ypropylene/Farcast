import AppKit
import ImageIO
import SwiftUI

struct ScreenshotToolbarButton: View {
    @ObservedObject var session: RemoteSession

    var body: some View {
        Menu {
            ScreenshotMenuItems(session: session)
        } label: {
            Label("Take Screenshot", systemImage: "camera.viewfinder").labelStyle(.iconOnly)
        } primaryAction: {
            ScreenshotService.capture(session)
        }
        .disabled(!session.canTakeScreenshot)
        .help(
            session.canTakeScreenshot
                ? String(localized: "Take Screenshot (⇧⌘S)") : String(localized: "Nothing to capture yet.")
        )
        .accessibilityLabel("Take Screenshot")
    }
}

struct ScreenshotMenuItems: View {
    @ObservedObject var session: RemoteSession
    var shortcuts = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if shortcuts {
                takeButton.keyboardShortcut("s", modifiers: [.command, .shift])
            } else {
                takeButton
            }
            Button("Copy Screenshot to Clipboard") { ScreenshotService.capture(session, .copy) }
                .disabled(!session.canTakeScreenshot)
            Button("Save Screenshot As…") { ScreenshotService.capture(session, .saveAs) }
                .disabled(!session.canTakeScreenshot)
            if let desktop = session.screenshotDesktop, let (_, frame) = desktop.mailbox.snapshot(),
                desktop.screenshotRegion(for: frame) != CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            {
                Divider()
                Button("Capture Entire Remote Desktop") { ScreenshotService.capture(session, .entireDesktop) }
                    .disabled(!session.canTakeScreenshot)
            }
            Divider()
            Button("Show Screenshots Folder") { ScreenshotFolder().reveal() }
                .disabled(ScreenshotFolder().bookmark == nil)
            Button("Screenshot Settings…") {
                UserDefaults.standard.set("screenshots", forKey: "settings.selectedTab")
                openSettings()
            }
        }
    }

    private var takeButton: some View {
        Button("Take Screenshot") { ScreenshotService.capture(session) }
            .disabled(!session.canTakeScreenshot)
            .help(
                session.canTakeScreenshot
                    ? String(localized: "Take Screenshot (⇧⌘S)") : String(localized: "Nothing to capture yet."))
    }
}

struct ScreenshotOverlay: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.openSettings) private var openSettings
    private enum Control: Hashable { case thumbnail, dismiss, reveal, open, recovery, settings }
    @FocusState private var keyboardFocus: Control?

    var body: some View {
        if let feedback = session.screenshotFeedback {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    if let thumbnail = feedback.thumbnail {
                        if let url = feedback.url {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                image(thumbnail)
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Open screenshot").focused($keyboardFocus, equals: .thumbnail)
                                .contextMenu {
                                    Button("Copy") { copy(feedback) }
                                    Button("Move to Trash", role: .destructive) {
                                        do {
                                            try withFileAccess(to: url) {
                                                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                                            }
                                            session.screenshotFeedback = nil
                                        } catch {
                                            ScreenshotService.announce(
                                                String(localized: "Couldn’t move the screenshot to Trash."))
                                        }
                                    }
                                    Button("Show in Finder") { reveal(url) }
                                }
                        } else {
                            image(thumbnail).accessibilityHidden(true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(feedback.title).font(.callout.weight(.semibold)).fixedSize(
                            horizontal: false, vertical: true)
                        if let url = feedback.url {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        }
                        if !feedback.detail.isEmpty { Text(feedback.detail).foregroundStyle(.secondary) }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    IconActionButton(title: String(localized: "Dismiss Screenshot Preview"), symbol: "xmark") {
                        session.screenshotFeedback = nil
                    }.focused($keyboardFocus, equals: .dismiss)
                }
                HStack {
                    if let url = feedback.url {
                        Button("Show in Finder") { reveal(url) }.focused($keyboardFocus, equals: .reveal)
                        Button("Open") { NSWorkspace.shared.open(url) }.focused($keyboardFocus, equals: .open)
                    }
                    if let choose = feedback.chooseFolder {
                        Button("Choose Folder…", action: choose).focused($keyboardFocus, equals: .recovery)
                    } else if let retry = feedback.retry {
                        Button("Retry", action: retry).focused($keyboardFocus, equals: .recovery)
                    }
                    if feedback.failed {
                        Button("Open Settings") {
                            UserDefaults.standard.set("screenshots", forKey: "settings.selectedTab")
                            openSettings()
                        }.focused($keyboardFocus, equals: .settings)
                    }
                }.buttonStyle(.bordered)
            }
            .padding(12).frame(width: 350)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.25)) }
            .onHover { session.screenshotPreviewHovered = $0 }
            .onChange(of: keyboardFocus) { _, focused in session.screenshotPreviewFocused = focused != nil }
            .onDisappear {
                session.screenshotPreviewHovered = false
                session.screenshotPreviewFocused = false
            }
            .padding(16)
        }
    }

    private func withFileAccess(to url: URL, _ action: () throws -> Void) throws {
        let folder = ScreenshotFolder()
        if folder.bookmark != nil && folder.url.path == url.deletingLastPathComponent().path {
            try folder.withAccess { _ in try action() }
        } else {
            try action()
        }
    }

    private func image(_ thumbnail: CGImage) -> some View {
        Image(decorative: thumbnail, scale: 2).resizable().scaledToFit().frame(width: 80, height: 54)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ feedback: ScreenshotFeedback) {
        if let png = feedback.png {
            _ = ScreenshotService.copy(png)
        } else if let url = feedback.url {
            Task {
                let png = await Task.detached {
                    autoreleasepool {
                        let read: () throws -> Data? = {
                            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                            else { return nil }
                            let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
                            let dpi = metadata?[kCGImagePropertyDPIWidth as String] as? Double ?? 72
                            return try ScreenshotImage(image: image, scale: dpi / 72).encode(as: .png)
                        }
                        return (try? read()) ?? (try? ScreenshotFolder().withAccess { _ in try read() })
                    }
                }.value
                if let png { _ = ScreenshotService.copy(png) }
            }
        }
    }
}

@MainActor enum ScreenshotShortcut {
    private static var monitor: Any?

    static func install(workspace: Workspace) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak workspace] event in
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift],
                event.charactersIgnoringModifiers?.lowercased() == "s",
                let workspace, let window = event.window, let session = workspace.activeSession,
                workspace.isSessionPresentation(window) || session.screenshotDesktop?.window === window
            else { return event }
            if let desktop = event.window?.firstResponder as? RDPDesktopView { desktop.releaseInput() }
            if !event.isARepeat { ScreenshotService.capture(session) }
            return nil
        }
    }
}
