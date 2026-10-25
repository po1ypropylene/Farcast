import AppKit
import CoreGraphics

/// Each native display presents a cropped region of one shared session framebuffer.
/// No additional login, frame queue or full-desktop texture is created per monitor.
@MainActor final class RDPFullScreenPresentation: NSObject, NSWindowDelegate {
    struct Target {
        let screen: RDPDisplayScreen
        let monitor: RDPDisplayMonitor
    }
    let layout: RDPDisplayLayout
    private let desktop: RDPDesktopView
    private let targets: [Target]
    private(set) var windows: [NSWindow] = []
    private(set) var surfaces: [RDPDesktopView] = []
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []
    var onExit: ((String?) -> Void)?
    var onActivate: (() -> Void)?

    static func screens(all: Bool, preferred: NSScreen?) -> [RDPDisplayScreen] {
        let available = NSScreen.screens.filter { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayMirrorsDisplay(id.uint32Value) == kCGNullDirectDisplay
        }
        let selected = all ? available : [preferred ?? NSScreen.main ?? available.first].compactMap { $0 }
        return selected.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = number.uint32Value
            return RDPDisplayScreen(
                id: id, frame: screen.frame, backingScale: screen.backingScaleFactor,
                physicalSize: CGDisplayScreenSize(id), orientation: Int(CGDisplayRotation(id)) % 360)
        }
    }

    init(desktop: RDPDesktopView, screens: [RDPDisplayScreen], layout: RDPDisplayLayout) {
        self.desktop = desktop
        self.layout = layout
        targets = zip(screens, layout.monitors).map { Target(screen: $0.0, monitor: $0.1) }
        super.init()
    }
    func show() {
        guard windows.isEmpty else { return }
        parent = desktop.window
        desktop.releaseInput()
        desktop.suspendRendering(true)
        for target in targets {
            let window = RDPFullScreenWindow(
                contentRect: target.screen.frame, styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = true
            window.delegate = self
            window.title = "Farcast remote desktop"
            let root = NSView(frame: CGRect(origin: .zero, size: target.screen.frame.size))
            let surface = RDPDesktopView(frame: root.bounds, mailbox: desktop.mailbox)
            surface.autoresizingMask = [.width, .height]
            surface.displayMode = .fit
            surface.sourceRect = layout.sourceRect(for: target.monitor)
            surface.expectedDesktopSize = layout.bounds.size
            surface.setDesktopSize(target.monitor.rect.size)
            surface.inputEnabled = desktop.inputEnabled
            surface.keySymbolForEvent = desktop.keySymbolForEvent
            surface.sendKeySymbol = desktop.sendKeySymbol
            surface.sendKey = desktop.sendKey
            surface.sendUnicode = desktop.sendUnicode
            surface.synchronizeCapsLock = desktop.synchronizeCapsLock
            surface.sendText = desktop.sendText
            surface.usesTextKeySymbols = desktop.usesTextKeySymbols
            surface.serverDrawsCursor = desktop.serverDrawsCursor
            surface.typeClipboard = desktop.typeClipboard
            surface.sendPointer = desktop.sendPointer
            surface.preparePaste = desktop.preparePaste
            surface.exitFullScreen = { [weak self] in self?.exit() }
            surface.routePointer = { [weak self, weak window] event in
                guard let self, let window else { return nil }
                return self.remotePoint(event: event, originatingWindow: window)
            }
            root.addSubview(surface)
            let exit = NSButton(title: "Exit Full Screen", target: self, action: #selector(exitAction))
            exit.bezelStyle = .rounded
            exit.controlSize = .small
            exit.toolTip = "Return to the workspace (Control–Command–F). The desktop session stays connected."
            exit.setAccessibilityLabel("Exit remote desktop full screen")
            // An opaque native background keeps the label legible over arbitrary remote pixels.
            let exitBackground = NSBox(
                frame: CGRect(x: root.bounds.width - 150, y: root.bounds.height - 42, width: 138, height: 32))
            exitBackground.boxType = .custom
            exitBackground.cornerRadius = 8
            exitBackground.borderWidth = 1
            exitBackground.borderColor = .separatorColor
            exitBackground.fillColor = .windowBackgroundColor
            exitBackground.contentViewMargins = NSSize(width: 4, height: 4)
            exitBackground.autoresizingMask = [.minXMargin, .minYMargin]
            if let content = exitBackground.contentView {
                exit.frame = content.bounds
                exit.autoresizingMask = [.width, .height]
                content.addSubview(exit)
            }
            root.addSubview(exitBackground)
            window.contentView = root
            window.setFrame(target.screen.frame, display: false)
            surfaces.append(surface)
            windows.append(window)
            window.orderFront(nil)
        }
        if let first = windows.first, let surface = surfaces.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(surface)
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.exit(
                        reason: "Displays changed. Reconnect to use the new monitor arrangement or Retina density.")
                }
            })
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let window = notification.object as? NSWindow,
                            let index = self.windows.firstIndex(where: { $0 === window })
                        else { return }
                        let screen = window.screen
                        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                            .uint32Value
                        let snapshot = self.targets[index].screen
                        if id != snapshot.id || window.backingScaleFactor != snapshot.backingScale {
                            self.exit(
                                reason: "The display or Retina density changed. Reconnect to use its new geometry.")
                        }
                    }
                })
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let inactive = notification.name == NSApplication.didResignActiveNotification
                        if inactive { self.releaseInput() }
                        for surface in self.surfaces { surface.suspendRendering(inactive) }
                    }
                })
        }
    }
    private func remotePoint(event: NSEvent, originatingWindow: NSWindow) -> CGPoint? {
        let global = originatingWindow.convertPoint(toScreen: event.locationInWindow)
        for (index, window) in windows.enumerated() where window.frame.contains(global) {
            let surface = surfaces[index]
            let local = surface.convert(window.convertPoint(fromScreen: global), from: nil)
            guard let source = surface.sourceRect else { continue }
            return RDPDisplayTransform(source: source, destination: surface.displayRect(in: surface.bounds.size))
                .remotePoint(local: local, viewHeight: surface.bounds.height)
        }
        return nil
    }
    func setInputEnabled(_ enabled: Bool) {
        for surface in surfaces {
            if !enabled { surface.releaseInput() }
            surface.inputEnabled = enabled
        }
    }
    func releaseInput() { for surface in surfaces { surface.releaseInput() } }
    func cursor(_ data: Data, width: Int, height: Int, x: Int, y: Int) {
        for surface in surfaces { surface.setRemoteCursor(data, width: width, height: height, hotX: x, hotY: y) }
    }
    func windowDidBecomeKey(_ notification: Notification) { onActivate?() }
    func windowDidResignKey(_ notification: Notification) { releaseInput() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        exit()
        return false
    }
    @objc private func exitAction() { exit() }
    func exit(reason: String? = nil, notify: Bool = true, restoreFocus: Bool = true) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        releaseInput()
        for window in windows {
            window.delegate = nil
            window.close()
        }
        windows.removeAll()
        surfaces.removeAll()
        desktop.suspendRendering(false)
        if notify {
            onExit?(reason)
        }
        if restoreFocus { parent?.makeKeyAndOrderFront(nil) }
    }
}

private final class RDPFullScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
