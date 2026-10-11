import AppKit
import Combine
import Foundation
import SwiftData
import SwiftTerm

@MainActor final class RemoteSession: ObservableObject, Identifiable {
    let id = UUID()
    let profile: ConnectionDraft
    let persistent: Bool
    @Published var state = SessionState.waiting {
        didSet { terminal?.view.inputEnabled = state == .connected && terminalAvailable }
    }
    @Published var message = "Waiting for credentials"
    @Published var remoteTitle = ""
    @Published var logs: [SessionLog] = []
    @Published var sshMode = SSHWorkspaceMode.terminal {
        didSet { ssh?.setTerminalVisible(sshMode != .files) }
    }
    @Published private(set) var terminalAvailable = true
    @Published private(set) var credentialsRejected = false
    let files: SFTPController
    let terminal: TerminalController?
    let desktop: RDPDesktopView?
    private var ssh: FCSSHClient?
    private var rdp: FCRDPClient?
    private var fullScreen: RDPFullScreenPresentation?
    private var displayLayout: RDPDisplayLayout?
    private var displayScreens: [RDPDisplayScreen] = []
    private let screenSnapshot: @MainActor (Bool, NSScreen?) -> [RDPDisplayScreen]
    private var observedDesktopSize: CGSize?
    private var confirmedMonitors = false
    private var startupPresentationPending = false
    private var displayObservationTask: DispatchWorkItem?
    private var requestedResize: CGSize?
    private var requestedResizeScale: Int?
    private var lastSubmittedScale: Int?
    @Published private(set) var fullScreenPresented = false
    @Published private(set) var displayMessage = ""
    private var tunnel: WireGuardTransport?
    private var tunnelTask: Task<Void, Never>?
    private var pendingWaiters: [PromptWaiter] = []
    private var generation = UUID()
    private var clipboardTimer: Timer?
    @Published private(set) var clipboardMessage = ""
    private let clipboardBridge = RDPClipboardBridge()
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            rdp?.setClipboardActive(isSelected)
            if !isSelected { fullScreen?.releaseInput() }
            if isSelected {
                clipboardBridge.reset()
            } else {
                clipboardBridge.invalidate()
                clipboardMessage = ""
            }
        }
    }
    weak var workspace: Workspace?

    init(
        profile: ConnectionDraft, workspace: Workspace, persistent: Bool = true, files: SFTPController? = nil,
        screenSnapshot: @escaping @MainActor (Bool, NSScreen?) -> [RDPDisplayScreen] = RDPFullScreenPresentation.screens
    ) {
        self.profile = profile
        self.screenSnapshot = screenSnapshot
        self.workspace = workspace
        self.persistent = persistent
        self.files = files ?? SFTPController()
        if profile.kind == .ssh {
            terminal = TerminalController(profile: profile)
            desktop = nil
        } else {
            terminal = nil
            let view = RDPDesktopView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            view.displayMode = profile.displayMode
            view.retinaDisplay = profile.retinaDisplay
            view.setDesktopSize(CGSize(width: profile.desktopWidth, height: profile.desktopHeight))
            desktop = view
        }
    }
    func start(credential: ConnectionCredential) {
        guard workspace?.isShuttingDown != true else { return }
        if profile.kind == .rdp && profile.redirectedFoldersUnavailable {
            update(
                "failed",
                message: "Saved folder settings are unavailable. Edit the connection and choose the folders again.",
                attempt: generation)
            return
        }
        guard profile.kind == .rdp, let tunnelID = profile.wireGuardID else {
            startProtocol(credential: credential)
            return
        }
        generation = UUID()
        let attempt = generation
        state = .connecting
        message = "Starting WireGuard…"
        do {
            guard let context = workspace?.modelContext else { throw WireGuardError.unavailable }
            var query = FetchDescriptor<SavedWireGuard>(predicate: #Predicate { $0.id == tunnelID })
            query.fetchLimit = 1
            guard let saved = try context.fetch(query).first else { throw WireGuardError.unavailable }
            let configuration = try saved.configuration()
            guard let keys = try CredentialStore.load(tunnelID) else { throw WireGuardError.missingKeys }
            let transport = WireGuardTransport()
            tunnel = transport
            let host = profile.host
            let port = profile.port
            let reference = WeakRemoteSession(self)
            let onExit: @Sendable () -> Void = {
                Task { @MainActor in
                    guard let self = reference.value, self.generation == attempt, self.state.active else { return }
                    self.rdp?.disconnect()
                    self.update("failed", message: WireGuardError.transport.localizedDescription, attempt: attempt)
                    self.generation = UUID()
                }
            }
            tunnelTask = Task { [weak self] in
                do {
                    let endpoint = try await Task.detached(priority: .userInitiated) {
                        try transport.start(
                            id: tunnelID, configuration: configuration, credential: keys, host: host, port: port,
                            onExit: onExit)
                    }.value
                    guard let self, self.generation == attempt, !Task.isCancelled else {
                        transport.stop()
                        return
                    }
                    self.startProtocol(
                        credential: credential, attempt: attempt, tunnelPort: endpoint.port, tunnelToken: endpoint.token
                    )
                } catch {
                    guard let self, self.generation == attempt, !Task.isCancelled else {
                        transport.stop()
                        return
                    }
                    self.update(
                        "failed",
                        message: (error as? WireGuardError)?.localizedDescription
                            ?? WireGuardError.transport.localizedDescription, attempt: attempt)
                }
            }
        } catch {
            update(
                "failed",
                message: (error as? WireGuardError)?.localizedDescription
                    ?? WireGuardError.unavailable.localizedDescription, attempt: attempt)
        }
    }
    private func startProtocol(
        credential: ConnectionCredential, attempt previousAttempt: UUID? = nil,
        tunnelPort: Int = 0, tunnelToken: String? = nil
    ) {
        generation = previousAttempt ?? UUID()
        let attempt = generation
        state = .connecting
        message = "Connecting…"
        if let terminal {
            terminalAvailable = true
            credentialsRejected = false
            let client = FCSSHClient()
            client.setTerminalVisible(sshMode != .files)
            ssh = client
            files.attach(client)
            let fileController = files
            client.onFiles = { [weak self, fileController] id, result, error in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt else { return }
                    fileController.receive(id: id, result: result, error: error)
                }
            }
            client.onFileProgress = { [weak self, fileController] id, bytes, total in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt else { return }
                    fileController.receiveProgress(id: id, bytes: bytes, total: total)
                }
            }
            terminal.sendBytes = { [weak client] in client?.send($0) }
            terminal.resize = { [weak client] cols, rows in client?.resizeColumns(cols, rows: rows) }
            terminal.updateTitle = { [weak self] title in self?.remoteTitle = title }
            client.onStatus = { [weak self] status, message in
                DispatchQueue.main.async { self?.update(status, message: message, attempt: attempt) }
            }
            client.onAuthenticationRejected = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt else { return }
                    self.credentialsRejected = true
                }
            }
            client.onTerminalAvailability = { [weak self] available in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt else { return }
                    self.terminalAvailable = available
                    self.terminal?.view.inputEnabled = self.state == .connected && available
                    if !available { self.sshMode = .files }
                }
            }
            client.onData = { [weak self] data in
                DispatchQueue.main.sync {
                    guard let self, self.generation == attempt else { return }
                    self.terminal?.view.feed(byteArray: Array(data)[...])
                }
            }
            client.onTrust = trustCallback(attempt: attempt)
            client.onPrompt = { [weak self] prompt, echo in
                let waiter = PromptWaiter()
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state.active else {
                        waiter.resolve(nil)
                        return
                    }
                    self.pendingWaiters.append(waiter)
                    self.workspace?.enqueue(
                        SessionPrompt(
                            sessionID: self.id, kind: .interactive, title: "SSH authentication", details: prompt,
                            echo: echo, waiter: waiter))
                }
                return waiter.wait()
            }
            client.connectHost(
                profile.host, port: profile.port, username: profile.username, password: credential.password,
                privateKey: credential.privateKey, authentication: profile.authentication.rawValue)
        } else if let desktop {
            do {
                if profile.launchFullScreen {
                    displayScreens = screenSnapshot(
                        profile.useAllMonitors, desktop.window?.screen ?? NSApp.keyWindow?.screen)
                    displayLayout = try RDPDisplayLayout(screens: displayScreens, retina: profile.retinaDisplay)
                    startupPresentationPending = true
                }
            } catch {
                update("failed", message: error.localizedDescription, attempt: attempt)
                return
            }
            let client = FCRDPClient()
            rdp = client
            client.monitorDefinitions =
                displayLayout?.monitors.map { monitor in
                    let physical = monitor.physicalSize
                    let validPhysical = (10...10000).contains(physical.width) && (10...10000).contains(physical.height)
                    return [
                        "x": Int(monitor.rect.minX), "y": Int(monitor.rect.minY),
                        "width": Int(monitor.rect.width), "height": Int(monitor.rect.height),
                        "primary": monitor.primary ? 1 : 0, "scale": monitor.desktopScale,
                        "physicalWidth": validPhysical ? Int(physical.width.rounded()) : 0,
                        "physicalHeight": validPhysical ? Int(physical.height.rounded()) : 0,
                        "orientation": monitor.orientation,
                    ]
                } ?? []
            client.onMonitorLayout = { [weak self] monitors in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, let layout = self.displayLayout else { return }
                    self.confirmedMonitors =
                        monitors.count == layout.monitors.count
                        && layout.monitors.allSatisfy { wanted in
                            monitors.contains { received in
                                (received["x"] as? NSNumber)?.intValue == Int(wanted.rect.minX)
                                    && (received["y"] as? NSNumber)?.intValue == Int(wanted.rect.minY)
                                    && (received["width"] as? NSNumber)?.intValue == Int(wanted.rect.width)
                                    && (received["height"] as? NSNumber)?.intValue == Int(wanted.rect.height)
                                    && (received["primary"] as? NSNumber)?.boolValue == wanted.primary
                            }
                        }
                    if self.fullScreenPresented && !self.confirmedMonitors {
                        self.exitFullScreen(
                            reason: "The server changed its monitor layout. The session continues in the workspace.")
                    }
                    self.presentStartupDesktopIfReady()
                }
            }
            client.onDesktopSize = { [weak self] width, height in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state.active else { return }
                    let size = CGSize(width: width, height: height)
                    self.observedDesktopSize = size
                    self.desktop?.setDesktopSize(size)
                    if self.fullScreenPresented, size != self.fullScreen?.layout.bounds.size {
                        self.exitFullScreen(
                            reason: "The server changed the desktop size. The session continues in the workspace.")
                    }
                    if let requested = self.requestedResize, requested == size {
                        self.displayObservationTask?.cancel()
                        self.requestedResize = nil
                        self.displayMessage = ""
                    }
                    self.presentStartupDesktopIfReady()
                }
            }
            client.onDisplayUpdate = { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state == .connected else { return }
                    self.displayMessage = message
                }
            }
            client.redirectedFolders = profile.redirectedFolders.map {
                ["name": $0.name, "bookmark": $0.bookmark, "readOnly": $0.readOnly] as [String: Any]
            }
            client.setClipboardActive(isSelected)
            client.tunnelPort = tunnelPort
            client.tunnelToken = tunnelToken
            client.onStatus = { [weak self] status, message in
                DispatchQueue.main.async { self?.update(status, message: message, attempt: attempt) }
            }
            client.onTrust = trustCallback(attempt: attempt)
            client.onFrame = { [weak desktop] data, width, height, stride in
                desktop?.submit(data, width: width, height: height, stride: stride)
            }
            client.onCursor = { [weak self] data, width, height, x, y in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state.active else { return }
                    self.desktop?.setRemoteCursor(data, width: width, height: height, hotX: x, hotY: y)
                    self.fullScreen?.cursor(data, width: width, height: height, x: x, y: y)
                }
            }
            client.onClipboard = { [weak self] text in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state == .connected, self.profile.clipboard,
                        self.isSelected
                    else { return }
                    self.clipboardBridge.receive(text: text)
                }
            }
            client.onClipboardChange = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state == .connected,
                        self.profile.clipboard, self.isSelected
                    else { return }
                    self.clipboardBridge.remoteChanged()
                }
            }
            client.onClipboardBatch = { [weak self] batch in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state == .connected,
                        self.profile.clipboard, self.isSelected
                    else { return }
                    self.clipboardBridge.receive(batch: batch)
                }
            }
            client.onClipboardProgress = { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state == .connected,
                        self.profile.clipboard, self.isSelected
                    else { return }
                    self.clipboardMessage = message
                }
            }
            desktop.sendKey = { [weak client] code, down, extended in
                client?.sendScanCode(code, pressed: down, extended: extended)
            }
            desktop.sendUnicode = { [weak client] code, down in client?.sendUnicode(code, pressed: down) }
            desktop.preparePaste = { [weak self] in self?.syncClipboard() }
            desktop.sendPointer = { [weak client] flags, x, y in client?.sendPointerFlags(flags, x: x, y: y) }
            desktop.resizeRemote = { [weak self, weak client] width, height, scale in
                guard let self, self.generation == attempt, self.profile.displayMode == .fit,
                    self.profile.dynamicResolution, self.displayLayout == nil || !self.profile.useAllMonitors,
                    !self.fullScreenPresented, !self.startupPresentationPending
                else { return }
                let size = CGSize(width: min(8192, max(200, width / 2 * 2)), height: min(8192, max(200, height)))
                guard self.requestedResize != size || self.requestedResizeScale != scale else { return }
                guard self.observedDesktopSize != size || self.lastSubmittedScale != scale else { return }
                self.requestedResize = size
                self.requestedResizeScale = scale
                self.lastSubmittedScale = scale
                self.displayObservationTask?.cancel()
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == attempt, self.requestedResize != nil, self.state == .connected
                    else { return }
                    self.displayMessage =
                        "The display change was not confirmed. The server may restrict resolution or scaling."
                }
                self.displayObservationTask = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
                client?.resizeWidth(Int(size.width), height: Int(size.height), scale: scale)
            }
            let connect: (CGSize, Int) -> Void = { [weak self, weak client] size, scale in
                guard let self, self.generation == attempt, self.state.active else { return }
                let dimension = self.displayLayout == nil ? 8192 : RDPDisplayLimits.dimension
                guard size.width >= 200, size.height >= 200, size.width <= CGFloat(dimension),
                    size.height <= CGFloat(dimension),
                    size.width * size.height <= CGFloat(RDPDisplayLimits.pixels)
                else {
                    self.update("failed", message: RDPDisplayLayoutError.invalid.localizedDescription, attempt: attempt)
                    return
                }
                self.lastSubmittedScale = scale
                client?.connectHost(
                    self.profile.host, port: self.profile.port, username: self.profile.username,
                    domain: self.profile.domain, password: credential.password,
                    width: Int(size.width), height: Int(size.height), scale: scale,
                    clipboard: self.profile.clipboard, audioPlayback: self.profile.audioPlayback)
            }
            if let layout = displayLayout {
                connect(layout.bounds.size, layout.monitors[0].desktopScale)
            } else {
                desktop.withInitialSize(width: profile.desktopWidth, height: profile.desktopHeight) {
                    [weak desktop] size in
                    let factor =
                        self.profile.retinaDisplay
                        ? desktop?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1 : 1
                    let requested =
                        self.profile.displayMode == .matchWindow
                        ? size
                        : CGSize(
                            width: self.profile.retinaDisplay ? floor(size.width * factor / 2) * 2 : size.width,
                            height: floor(size.height * factor))
                    connect(requested, Int((factor * 100).rounded()))
                }
            }
        }
    }
    private func presentStartupDesktopIfReady() {
        guard startupPresentationPending, state == .connected, let desktop, let layout = displayLayout,
            observedDesktopSize == layout.bounds.size, layout.monitors.count == 1 || confirmedMonitors
        else { return }
        startupPresentationPending = false
        displayObservationTask?.cancel()
        presentDesktopFullScreen(desktop: desktop, screens: displayScreens, layout: layout)
    }
    func enterFullScreen() {
        guard state == .connected, let desktop, !fullScreenPresented, let size = observedDesktopSize else { return }
        let screens = screenSnapshot(
            displayLayout != nil && profile.useAllMonitors, desktop.window?.screen ?? NSApp.keyWindow?.screen)
        do {
            let layout: RDPDisplayLayout
            if let negotiated = displayLayout, negotiated.monitors.count > 1 {
                guard confirmedMonitors, size == negotiated.bounds.size else {
                    displayMessage =
                        "The server has not confirmed the monitor layout. The desktop remains in the workspace."
                    return
                }
                guard screens.count == displayScreens.count,
                    displayScreens.allSatisfy({ screens.contains($0) })
                else {
                    displayMessage = "Displays changed. Reconnect to use the new monitor arrangement or Retina density."
                    return
                }
                layout = negotiated
                presentDesktopFullScreen(desktop: desktop, screens: displayScreens, layout: layout)
            } else {
                guard let screen = screens.first else { throw RDPDisplayLayoutError.invalid }
                layout = try RDPDisplayLayout(
                    screen: screen, desktopSize: size, desktopScale: lastSubmittedScale ?? 100)
                presentDesktopFullScreen(desktop: desktop, screens: [screen], layout: layout)
            }
        } catch {
            displayMessage = error.localizedDescription
        }
    }
    private func presentDesktopFullScreen(
        desktop: RDPDesktopView, screens: [RDPDisplayScreen], layout: RDPDisplayLayout
    ) {
        startupPresentationPending = false
        displayObservationTask?.cancel()
        requestedResize = nil
        requestedResizeScale = nil
        displayMessage = ""
        let presentation = RDPFullScreenPresentation(desktop: desktop, screens: screens, layout: layout)
        presentation.onActivate = { [weak self] in
            guard let self, self.state == .connected else { return }
            self.workspace?.activatePresentation(of: self)
        }
        presentation.onExit = { [weak self] reason in self?.exitFullScreen(reason: reason) }
        fullScreen = presentation
        fullScreenPresented = true
        presentation.show()
    }
    func exitFullScreen(reason: String? = nil, restoreFocus: Bool = true) {
        let presentation = fullScreen
        fullScreen = nil
        fullScreenPresented = false
        startupPresentationPending = false
        presentation?.exit(notify: false, restoreFocus: restoreFocus && state == .connected)
        if let reason { displayMessage = reason }
        desktop?.requestResize()
    }
    private func retireFullScreen() {
        displayObservationTask?.cancel()
        requestedResize = nil
        requestedResizeScale = nil
        startupPresentationPending = false
        exitFullScreen(restoreFocus: false)
    }
    private func trustCallback(attempt: UUID) -> (String, String) -> Bool {
        { [weak self] fingerprint, details in
            let waiter = PromptWaiter()
            DispatchQueue.main.async {
                guard let self, self.generation == attempt, self.state.active, let workspace = self.workspace else {
                    waiter.resolve(nil)
                    return
                }
                let previous = workspace.trust.fingerprint(for: self.profile.endpointKey)
                if previous == fingerprint {
                    waiter.resolve("trusted")
                    return
                }
                self.pendingWaiters.append(waiter)
                workspace.enqueue(
                    SessionPrompt(
                        sessionID: self.id, kind: .trust,
                        title: previous == nil ? "Verify server identity" : "Server identity has changed",
                        details: details, fingerprint: fingerprint, previousFingerprint: previous, waiter: waiter))
            }
            return waiter.wait() == "trusted"
        }
    }
    private func update(_ status: String, message: String, attempt: UUID) {
        guard generation == attempt else { return }
        state = SessionState(rawValue: status) ?? .failed
        self.message = message
        logs.append(SessionLog(message: message))
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        if state == .connected {
            if profile.kind == .ssh && sshMode != .terminal { files.showFiles() }
            desktop?.inputEnabled = true
            presentStartupDesktopIfReady()
            if startupPresentationPending {
                displayObservationTask?.cancel()
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == attempt, self.startupPresentationPending else { return }
                    self.startupPresentationPending = false
                    self.displayMessage =
                        "The server did not confirm the requested monitor layout. The desktop remains in the workspace."
                }
                displayObservationTask = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            }
            desktop?.requestResize()
            startClipboardTimer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.isSelected else { return }
                self.focus()
            }
        }
        if !state.active {
            retireFullScreen()
            files.disconnected()
            tunnelTask?.cancel()
            tunnel?.stop()
            tunnel = nil
            cancelPrompts()
            stopClipboard()
            desktop?.cancelPendingDisplayWork()
            desktop?.releaseInput()
            desktop?.inputEnabled = false
        }
    }
    func askForCredentials() {
        let waiter = PromptWaiter()
        pendingWaiters.append(waiter)
        workspace?.enqueue(
            SessionPrompt(
                sessionID: id, kind: .credentials, title: "Connect to \(profile.name)",
                details: "\(profile.username)@\(profile.host):\(profile.port)", waiter: waiter))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = waiter.wait()
            DispatchQueue.main.async {
                guard let self, self.state == .waiting else { return }
                guard let result, let data = result.data(using: .utf8),
                    let credential = try? JSONDecoder().decode(ConnectionCredential.self, from: data)
                else {
                    self.disconnect()
                    return
                }
                self.start(credential: credential)
            }
        }
    }
    func disconnect() {
        retireFullScreen()
        generation = UUID()
        tunnelTask?.cancel()
        tunnelTask = nil
        tunnel?.stop()
        tunnel = nil
        cancelPrompts()
        stopClipboard()
        desktop?.cancelPendingDisplayWork()
        desktop?.releaseInput()
        desktop?.inputEnabled = false
        files.disconnected()
        ssh?.disconnect()
        rdp?.disconnect()
        generation = UUID()
        state = .disconnected
        message = "Disconnected"
        logs.append(SessionLog(message: message))
    }
    private func cancelPrompts() {
        for waiter in pendingWaiters { waiter.resolve(nil) }
        pendingWaiters.removeAll()
        workspace?.cancelPrompts(sessionID: id)
    }
    private func startClipboardTimer() {
        guard profile.kind == .rdp, profile.clipboard else { return }
        stopClipboard()
        clipboardBridge.reset()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncClipboard()
            }
        }
    }
    private func syncClipboard() {
        guard profile.clipboard, isSelected, state == .connected else { return }
        clipboardBridge.synchronize(
            text: { rdp?.setClipboardText($0) }, files: { rdp?.setClipboardFiles($0) })
    }
    private func stopClipboard() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        clipboardBridge.invalidate()
        clipboardMessage = ""
    }
    func controlAltDelete() { if state == .connected { rdp?.sendControlAltDelete() } }
    func focus() {
        guard profile.kind != .ssh || (terminalAvailable && sshMode != .files) else { return }
        if fullScreenPresented, let presentation = fullScreen,
            let index = presentation.windows.firstIndex(where: { $0.isKeyWindow })
        {
            presentation.windows[index].makeFirstResponder(presentation.surfaces[index])
        } else if let view = terminal?.view ?? desktop {
            view.window?.makeFirstResponder(view)
        }
    }
}

@MainActor private final class WeakRemoteSession {
    weak var value: RemoteSession?
    init(_ value: RemoteSession) { self.value = value }
}
