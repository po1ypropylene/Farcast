import AppKit
import ImageIO

struct ScreenshotFeedback: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var url: URL?
    var thumbnail: CGImage?
    var png: Data?
    var failed = false
    var retry: (@MainActor () -> Void)?
    var chooseFolder: (@MainActor () -> Void)?
}

@MainActor enum ScreenshotService {
    enum Command { case take, copy, saveAs, entireDesktop }

    private static let shutter = Bundle.main.url(forResource: "ScreenshotShutter", withExtension: "wav")
        .flatMap { NSSound(contentsOf: $0, byReference: false) }

    static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp.keyWindow as Any? ?? NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    static func capture(_ session: RemoteSession, _ command: Command = .take) {
        guard session.canTakeScreenshot else { return }
        do {
            let source: ScreenshotSource
            if let terminal = session.terminal {
                source = try terminal.screenshot()
            } else if let desktop = session.screenshotDesktop {
                source = try desktop.screenshot(entireDesktop: command == .entireDesktop)
            } else {
                throw ScreenshotImageError.unavailable
            }
            let date = Date()
            let defaults = UserDefaults.standard
            let format = ScreenshotFormat(rawValue: defaults.string(forKey: "screenshot.format") ?? "") ?? .png
            let preview = defaults.object(forKey: "screenshot.showPreview") as? Bool ?? true
            let name = ScreenshotImage.filename(connection: session.profile.name, date: date)
            flash(session)
            if defaults.bool(forKey: "screenshot.playSound") { shutter?.play() }

            var folder = ScreenshotFolder()
            let save =
                command == .take || command == .entireDesktop
                ? defaults.object(forKey: "screenshot.saveToFolder") as? Bool ?? true : false
            var copy =
                command == .copy
                || ((command == .take || command == .entireDesktop)
                    && (defaults.bool(forKey: "screenshot.copyToClipboard") || !save))
            var saveURL: URL?
            if command == .saveAs {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name + "." + format.fileExtension
                panel.allowedContentTypes = [format.contentType]
                panel.directoryURL = folder.url
                elevateModal(panel)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                saveURL = url
            } else if save && folder.bookmark == nil {
                if grantDesktop() { folder = ScreenshotFolder() } else { copy = true }
            }
            let outputFolder = save && folder.bookmark != nil ? folder : nil
            Task { [weak session] in
                do {
                    let output = try await Writer.shared.process(
                        source, format: format, name: name, folder: outputFolder, saveURL: saveURL, copy: copy,
                        preview: preview)
                    guard let session else { return }
                    complete(
                        output, session: session, preview: preview, name: name, format: format,
                        folder: outputFolder, saveURL: saveURL)
                } catch {
                    guard let session else { return }
                    var feedback = ScreenshotFeedback(title: error.localizedDescription, detail: "", failed: true)
                    feedback.retry = { [weak session] in
                        if let session { capture(session, command) }
                    }
                    publish(feedback, session: session, preview: true)
                }
            }
        } catch {
            publish(
                ScreenshotFeedback(title: error.localizedDescription, detail: "", failed: true),
                session: session, preview: true)
        }
    }

    private actor Writer {
        static let shared = Writer()

        func process(
            _ source: ScreenshotSource, format: ScreenshotFormat, name: String,
            folder: ScreenshotFolder?, saveURL: URL?, copy: Bool, preview: Bool
        ) throws -> Output {
            try autoreleasepool {
                try prepare(
                    source.render(), format: format, name: name, folder: folder,
                    saveURL: saveURL, copy: copy, preview: preview)
            }
        }
    }

    private struct Output: Sendable {
        var url: URL?
        var png: Data?
        var file: Data?
        var thumbnail: CGImage?
        var saveError: String?
        var folderError = false
        var copyError = false
    }

    private nonisolated static func prepare(
        _ image: ScreenshotImage, format: ScreenshotFormat, name: String, folder: ScreenshotFolder?, saveURL: URL?,
        copy: Bool, preview: Bool
    ) -> Output {
        var output = Output()
        let png = copy || (format == .png && (folder != nil || saveURL != nil)) ? try? image.encode(as: .png) : nil
        if copy {
            output.png = png
            output.copyError = png == nil
        }
        if folder != nil || saveURL != nil {
            do {
                let bytes: Data
                if format == .png {
                    guard let png else { throw ScreenshotImageError.encoding }
                    bytes = png
                } else {
                    bytes = try image.encode(as: format)
                }
                output.file = bytes
                output.url = try write(bytes, folder: folder, saveURL: saveURL, name: name, format: format)
                output.file = nil
            } catch {
                output.folderError =
                    folder != nil
                    && (error is ScreenshotFolder.Issue
                        || (error as? CocoaError)?.code == .fileWriteNoPermission
                        || (error as? CocoaError)?.code == .fileNoSuchFile)
                output.saveError =
                    output.folderError
                    ? String(localized: "Couldn’t save the screenshot to “\(folder?.url.lastPathComponent ?? "")”.")
                    : String(localized: "Couldn’t save the screenshot: \(error.localizedDescription)")
            }
        }
        if preview || output.saveError != nil {
            let maximum = 160
            let ratio = min(1, CGFloat(maximum) / CGFloat(max(image.image.width, image.image.height)))
            let context = CGContext(
                data: nil, width: max(1, Int(CGFloat(image.image.width) * ratio)),
                height: max(1, Int(CGFloat(image.image.height) * ratio)),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            if let context {
                context.interpolationQuality = .high
                context.draw(image.image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                output.thumbnail = context.makeImage()
            }
        }
        return output
    }

    private nonisolated static func write(
        _ data: Data, folder: ScreenshotFolder?, saveURL: URL?, name: String, format: ScreenshotFormat
    ) throws -> URL? {
        if let saveURL {
            try data.write(to: saveURL, options: .atomic)
            return saveURL
        }
        return try folder?.withAccess { try ScreenshotImage.save(data, in: $0, name: name, format: format) }
    }

    static func copy(_ data: Data) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }

    private static func complete(
        _ output: Output, session: RemoteSession, preview: Bool, name: String, format: ScreenshotFormat,
        folder: ScreenshotFolder?, saveURL: URL?
    ) {
        let copied = output.png.map { copy($0) } ?? false
        let title = output.url != nil ? String(localized: "Screenshot saved") : String(localized: "Screenshot copied")
        let copyError = output.copyError || (output.png != nil && !copied)
        let copyFailure = copyError ? String(localized: "Couldn’t copy the screenshot to the clipboard.") : nil
        let error = output.saveError ?? copyFailure
        let detail = [
            output.url?.deletingLastPathComponent().lastPathComponent,
            copied ? String(localized: "Copied to clipboard") : (output.saveError == nil ? nil : copyFailure),
        ].compactMap { $0 }.joined(separator: " · ")
        var feedback = ScreenshotFeedback(
            title: error ?? title, detail: detail, url: output.url, thumbnail: output.thumbnail,
            png: output.png, failed: error != nil)
        if let data = output.file {
            let thumbnail = output.thumbnail
            let retry: @MainActor (ScreenshotFolder?) -> Void = { [weak session] target in
                Task { [weak session] in
                    let result = await Task.detached(priority: .userInitiated) {
                        Result { try write(data, folder: target, saveURL: saveURL, name: name, format: format) }
                    }.value
                    guard let session else { return }
                    switch result {
                    case .success(let url):
                        complete(
                            Output(url: url, thumbnail: thumbnail), session: session,
                            preview: preview, name: name, format: format, folder: target, saveURL: saveURL)
                    case .failure:
                        announce(String(localized: "Couldn’t save the screenshot."))
                    }
                }
            }
            feedback.retry = { retry(folder) }
            if output.folderError {
                feedback.chooseFolder = {
                    if (try? ScreenshotFolder.choose(at: nil)) == true { retry(ScreenshotFolder()) }
                }
            }
        }
        publish(feedback, session: session, preview: preview || error != nil)
    }

    private final class FlashView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private static func flash(_ session: RemoteSession) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if session.fullScreenPresented, let root = session.screenshotDesktop?.superview {
            let flash = FlashView(frame: root.bounds)
            flash.wantsLayer = true
            flash.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
            root.addSubview(flash)
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                flash.removeFromSuperview()
            }
        } else {
            session.screenshotFlash = true
            Task { [weak session] in
                try? await Task.sleep(for: .milliseconds(150))
                session?.screenshotFlash = false
            }
        }
    }

    private static func publish(_ feedback: ScreenshotFeedback, session: RemoteSession, preview: Bool) {
        session.screenshotFeedback = preview ? feedback : nil
        session.screenshotStatus = feedback.title
        announce([feedback.title, feedback.detail].filter { !$0.isEmpty }.joined(separator: ". "))
        let id = feedback.id
        session.screenshotFeedbackID = id
        let duration: Duration = .seconds(feedback.failed ? 10 : 6)
        Task { [weak session] in
            try? await Task.sleep(for: .seconds(3))
            if session?.screenshotFeedbackID == id { session?.screenshotStatus = nil }
        }
        Task { [weak session] in
            var remaining = duration
            let tick = Duration.milliseconds(250)
            while remaining > .zero {
                try? await Task.sleep(for: tick)
                guard let session, session.screenshotFeedback?.id == id else { return }
                if !session.screenshotPreviewHovered && !session.screenshotPreviewFocused { remaining -= tick }
            }
            if session?.screenshotFeedback?.id == id { session?.screenshotFeedback = nil }
        }
    }

    static func elevateModal(_ window: NSWindow) {
        if let parent = NSApp.keyWindow, parent.level >= window.level, parent !== window {
            window.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        }
    }

    private static func grantDesktop() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Farcast to save screenshots to your Desktop?")
        alert.informativeText = String(
            localized:
                "macOS needs your permission to write to this folder. You can copy this screenshot to the clipboard instead."
        )
        alert.addButton(withTitle: String(localized: "Choose Desktop…"))
        alert.addButton(withTitle: String(localized: "Choose Another…"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        elevateModal(alert.window)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return (try? ScreenshotFolder.choose(at: ScreenshotFolder.desktop, requireDesktop: true)) == true
        case .alertSecondButtonReturn: return (try? ScreenshotFolder.choose(at: nil)) == true
        default: return false
        }
    }
}
