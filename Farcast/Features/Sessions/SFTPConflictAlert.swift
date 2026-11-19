import AppKit
import Combine
import SwiftUI

struct SFTPConflictAlert: NSViewRepresentable {
    let controller: SFTPController

    func makeNSView(context: Context) -> Host { Host() }

    func updateNSView(_ view: Host, context: Context) {
        view.observe(controller)
    }

    static func dismantleNSView(_ view: Host, coordinator: ()) {
        view.observe(nil)
        view.dismiss()
    }

    final class Host: NSView {
        private weak var controller: SFTPController?
        private var conflictObservation: AnyCancellable?
        private var presented: (id: String, alert: NSAlert)?
        private var presentationScheduled = false
        private var pointerMonitor: Any?
        private weak var pressedButton: NSButton?
        private var releaseTimer: Timer?
        private let pointerState: (NSWindow) -> (isPressed: Bool, location: NSPoint)?

        init(
            pointerState: @escaping (NSWindow) -> (isPressed: Bool, location: NSPoint)? = { sheet in
                guard sheet.isKeyWindow else { return nil }
                return (NSEvent.pressedMouseButtons & 1 != 0, sheet.mouseLocationOutsideOfEventStream)
            }
        ) {
            self.pointerState = pointerState
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: window)
            }
            if newWindow !== window { dismiss() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(sheetDidEnd(_:)), name: NSWindow.didEndSheetNotification, object: window)
            schedulePresentation()
        }

        func observe(_ controller: SFTPController?) {
            guard self.controller !== controller else { return }
            conflictObservation?.cancel()
            dismiss()
            self.controller = controller
            conflictObservation = controller?.$conflict.sink { [weak self] _ in
                self?.schedulePresentation()
            }
        }

        @objc private func sheetDidEnd(_ notification: Notification) {
            schedulePresentation()
        }

        private func schedulePresentation() {
            guard !presentationScheduled else { return }
            presentationScheduled = true
            // A drop can report its conflict while AppKit is still in event
            // tracking. Present on the next turn of either active mode.
            RunLoop.main.perform(inModes: [.common, .eventTracking]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.presentationScheduled = false
                    self.presentIfNeeded()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }

        private func presentIfNeeded() {
            let conflict = controller?.conflict
            if let presented, presented.id == conflict?.id { return }
            dismiss()
            guard let window, window.attachedSheet == nil, let controller, let conflict else { return }

            let alert = SFTPConflictAlert.makeAlert(for: conflict)
            alert.window.appearance = window.effectiveAppearance
            presented = (conflict.id, alert)
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            ]) {
                [weak self] event in
                guard let self else { return event }
                return self.trackPointer(event)
            }
            alert.beginSheetModal(for: window) { [weak self, weak controller, weak alert] response in
                MainActor.assumeIsolated {
                    guard let self, let alert, self.presented?.alert === alert else { return }
                    self.stopPointerTracking()
                    self.presented = nil
                    guard let controller, controller.conflict?.id == conflict.id else { return }
                    // AppKit completes the sheet before the worker can report a new conflict.
                    switch response {
                    case .alertFirstButtonReturn: controller.resolveConflict(overwrite: false)
                    case .alertSecondButtonReturn: controller.resolveConflict(overwrite: true)
                    case .alertThirdButtonReturn: controller.resolveConflict(overwrite: true, all: true)
                    default: break
                    }
                }
            }
        }

        func dismiss() {
            guard let alert = presented?.alert else { return }
            stopPointerTracking()
            presented = nil
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
        }

        private func stopPointerTracking() {
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
            pointerMonitor = nil
            finishPress(activate: false)
        }

        // Stop safely on the press even if a preceding drag consumes its release.
        // Confirm replacements only after a release on the pressed button.
        private func trackPointer(_ event: NSEvent) -> NSEvent? {
            if event.type == .leftMouseDown {
                finishPress(activate: false)
                guard let button = actionButton(at: event) else { return event }
                if button === presented?.alert.buttons.first {
                    _ = button.sendAction(button.action, to: button.target)
                } else {
                    pressedButton = button
                    button.highlight(true)
                    watchForRelease()
                }
                return nil
            }
            guard let button = pressedButton else { return event }
            let inside = actionButton(at: event) === button
            if event.type == .leftMouseDragged {
                button.highlight(inside)
                return nil
            }
            finishPress(activate: inside)
            return nil
        }

        private func watchForRelease() {
            // AppKit can consume the first mouse-up after a drag. If the button
            // is already up, use its current position to finish the pending click.
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkForRelease() }
            }
            releaseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }

        private func checkForRelease() {
            guard let button = pressedButton, let sheet = button.window, let state = pointerState(sheet) else {
                finishPress(activate: false)
                return
            }
            let inside = containsPointer(button, at: state.location)
            if state.isPressed {
                button.highlight(inside)
            } else {
                finishPress(activate: inside)
            }
        }

        private func finishPress(activate: Bool) {
            releaseTimer?.invalidate()
            releaseTimer = nil
            let button = pressedButton
            pressedButton = nil
            button?.highlight(false)
            if activate, let button { _ = button.sendAction(button.action, to: button.target) }
        }

        private func actionButton(at event: NSEvent) -> NSButton? {
            guard let alert = presented?.alert, event.window === alert.window else { return nil }
            let actions = alert.buttons + (alert.accessoryView?.subviews.compactMap { $0 as? NSButton } ?? [])
            return actions.first { containsPointer($0, at: event.locationInWindow) }
        }

        private func containsPointer(_ button: NSButton, at location: NSPoint) -> Bool {
            button.isEnabled && !button.isHiddenOrHasHiddenAncestor
                && button.bounds.contains(button.convert(location, from: nil))
        }
    }

    static func makeAlert(for conflict: FileConflict) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "A file named “\(conflict.name)” already exists."
        alert.informativeText =
            "Replace this file, replace all conflicting files in the remaining transfer, or stop the entire transfer. Completed files stay completed."

        // NSAlert owns its standard buttons' colors. Put the two colored actions
        // in its accessory view and give them ordinary native button tracking.
        alert.accessoryView = OverwriteActions()
        let stop = alert.addButton(withTitle: "Stop Transfer")
        stop.keyEquivalent = "\u{1b}"
        alert.window.defaultButtonCell = nil
        return alert
    }
}

private final class OverwriteActions: NSView {
    init() {
        let width: CGFloat = 228
        let height: CGFloat = 28
        let spacing: CGFloat = 6
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height * 2 + spacing))
        let once = NSButton(frame: NSRect(x: 0, y: height + spacing, width: width, height: height))
        once.cell = OverwriteButtonCell(
            title: "Overwrite Once", fill: (0x9C4100, 0xFFAA5C), label: (0xFFFFFF, 0x201000))
        once.target = self
        once.action = #selector(overwriteOnce)
        addSubview(once)
        let all = NSButton(frame: NSRect(x: 0, y: 0, width: width, height: height))
        all.cell = OverwriteButtonCell(
            title: "Overwrite All", fill: (0xF0F0F0, 0x343434), label: (0xA82232, 0xFF7D86))
        all.target = self
        all.action = #selector(overwriteAll)
        addSubview(all)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func overwriteOnce() { finish(.alertSecondButtonReturn) }
    @objc private func overwriteAll() { finish(.alertThirdButtonReturn) }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: response)
    }
}

private final class OverwriteButtonCell: NSButtonCell {
    private let fill: NSColor
    private let label: NSColor

    init(title: String, fill: (light: UInt32, dark: UInt32), label: (light: UInt32, dark: UInt32)) {
        self.fill = Self.adaptiveColor(light: fill.light, dark: fill.dark)
        self.label = Self.adaptiveColor(light: label.light, dark: label.dark)
        super.init(textCell: title)
        setButtonType(.momentaryPushIn)
        isBordered = true
        font = .systemFont(ofSize: NSFont.systemFontSize)
        alignment = .center
        focusRingType = .exterior
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let background = isHighlighted ? fill.blended(withFraction: 0.12, of: .black) ?? fill : fill
        background.setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let coloredTitle = NSMutableAttributedString(attributedString: title)
        coloredTitle.addAttribute(.foregroundColor, value: label, range: NSRange(location: 0, length: title.length))
        return super.drawTitle(coloredTitle, withFrame: frame, in: controlView)
    }

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1)
        }
    }
}
