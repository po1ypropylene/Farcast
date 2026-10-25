import AppKit
import Combine
import Foundation
import SwiftTerm

@MainActor final class RemoteSession: ObservableObject, Identifiable {
    let id = UUID()
    let profile: ConnectionDraft
    let persistent: Bool
    @Published private(set) var connectedAt: Date?
    @Published private(set) var terminalZoom = 100
    @Published var state = SessionState.waiting {
        didSet {
            terminal?.view.inputEnabled = state == .connected && terminalAvailable
            if state == .connected && oldValue != .connected { connectedAt = Date() }
            if state != .connected { connectedAt = nil }
            if state == .disconnected { vpnState = .disconnected }
        }
    }
    @Published var message = "Waiting for credentials"
    @Published var remoteTitle = ""
    @Published var logs: [SessionLog] = []
    @Published var sshMode = SSHWorkspaceMode.terminal {
        didSet { ssh?.setTerminalVisible(sshMode == .terminal || sshMode == .split) }
    }
    @Published private(set) var terminalAvailable = true
    @Published private(set) var filesAvailable = true
    let forwarding: SSHForwardingController
    @Published private(set) var credentialsRejected = false
    let files: SFTPController
    let terminal: TerminalController?
    let desktop: RDPDesktopView?
    private var ssh: FCSSHClient?
    private var vnc: FCVNCClient?
    @Published private(set) var vncTyping = false
    private var vncPointerMask = 0
    private var appleRequestedSize: CGSize?
    private var appleResizeObservation: DispatchWorkItem?
    private var rdp: FCRDPClient?
    var rdpPerformanceStatistics: [String: NSNumber] { rdp?.performanceStatistics ?? [:] }
    private let makeRDPClient: @MainActor () -> FCRDPClient
    private var rdpCredential: ConnectionCredential?
    private var rdpReconnect = RDPReconnectPolicy()
    private var rdpReconnectTask: Task<Void, Never>?
    private var rdpHealthTask: Task<Void, Never>?
    private var rdpTunnelFailed = false
    private var fullScreen: RDPFullScreenPresentation?
    private var displayLayout: RDPDisplayLayout?
    private var displayScreens: [RDPDisplayScreen] = []
    private let screenSnapshot: @MainActor (Bool, NSScreen?) -> [RDPDisplayScreen]
    @Published private(set) var observedDesktopSize: CGSize?
    @Published private(set) var initialResolution = ""
    @Published private(set) var experimentalRDPEnabled = false
    @Published private(set) var graphicsPath = "Compatible bitmap graphics"
    @Published private(set) var latestFailure = ""
    private var confirmedMonitors = false
    private var startupPresentationPending = false
    private var displayObservationTask: DispatchWorkItem?
    private var resizeCoordinator = RDPResizeCoordinator()
    private var lastSubmittedScale: Int?
    @Published private(set) var fullScreenPresented = false
    @Published private(set) var displayMessage = "" {
        didSet {
            if !displayMessage.isEmpty && displayMessage != oldValue { record("Display: \(displayMessage)") }
        }
    }
    @Published private(set) var vpnState = SessionState.waiting {
        didSet {
            guard profile.wireGuardID != nil, vpnState != oldValue else { return }
            switch vpnState {
            case .connecting: record("VPN: establishing session transport…")
            case .connected: record("VPN: destination lease ready. This is not a continuous peer-health check.")
            case .failed: record("VPN: session transport failed.")
            case .disconnected: record("VPN: session transport released.")
            default: break
            }
        }
    }
    private var tunnel: WireGuardTransport?
    private var tunnelTask: Task<Void, Never>?
    private var pendingWaiters: [PromptWaiter] = []
    private var generation = UUID()
    private var clipboardTimer: Timer?
    @Published private(set) var clipboardMessage = ""
    private let clipboardBridge = RDPClipboardBridge()
    @Published var hasUnreadOutput = false
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            if isSelected { hasUnreadOutput = false }
            rdp?.setClipboardActive(isSelected)
            if !isSelected {
                fullScreen?.releaseInput()
                desktop?.releaseInput()
                vnc?.cancelTyping()
            }
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
        screenSnapshot: @escaping @MainActor (Bool, NSScreen?) -> [RDPDisplayScreen] = RDPFullScreenPresentation
            .screens,
        makeRDPClient: @escaping @MainActor () -> FCRDPClient = { FCRDPClient() }
    ) {
        self.profile = profile
        self.makeRDPClient = makeRDPClient
        self.screenSnapshot = screenSnapshot
        self.workspace = workspace
        self.persistent = persistent
        self.files = files ?? SFTPController()
        self.forwarding = SSHForwardingController(rules: profile.forwardingRules)
        if profile.kind == .ssh {
            terminal = TerminalController(profile: profile)
            desktop = nil
        } else {
            terminal = nil
            let view = RDPDesktopView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            view.displayMode = profile.effectiveDisplayMode
            view.retinaDisplay =
                (profile.kind == .rdp || (profile.kind == .vnc && profile.vncRemoteIsMac)) && profile.retinaDisplay
            view.setDesktopSize(CGSize(width: profile.desktopWidth, height: profile.desktopHeight))
            desktop = view
        }
    }
    func start(credential: ConnectionCredential) {
        guard workspace?.isShuttingDown != true else { return }
        record(
            "Starting \(profile.kind.rawValue) session via \(profile.wireGuardID == nil ? "direct transport" : "VPN").")
        if profile.kind == .rdp { rdpCredential = credential }
        if profile.kind == .ssh || (profile.kind == .vnc && profile.vncRemoteIsMac),
            let error = profile.validationMessage
        {
            update("failed", message: error, attempt: generation)
            return
        }
        if profile.kind == .rdp && profile.redirectedFoldersUnavailable {
            rdpCredential = nil
            update(
                "failed",
                message: "Saved folder settings are unavailable. Edit the connection and choose the folders again.",
                attempt: generation)
            return
        }
        guard let tunnelID = profile.wireGuardID else {
            startProtocol(credential: credential)
            return
        }
        generation = UUID()
        let attempt = generation
        state = rdpReconnect.attempts > 0 ? .reconnecting : .connecting
        vpnState = .connecting
        message =
            rdpReconnect.attempts > 0
            ? "Reconnect attempt \(rdpReconnect.attempts) of 3 · Starting VPN…" : "Starting VPN…"
        do {
            guard let workspace else { throw WireGuardError.unavailable }
            let (configuration, keys) = try workspace.wireGuardSettings(for: tunnelID)
            record("VPN engine: \(configuration.protocolName).")
            let transport = WireGuardTransport()
            tunnel = transport
            let host = profile.host
            let port = profile.port
            let reference = WeakRemoteSession(self)
            let onExit: @Sendable () -> Void = {
                Task { @MainActor in
                    guard let self = reference.value, self.generation == attempt, self.state.active,
                        self.state != .stale
                    else { return }
                    self.vpnState = .failed
                    self.rdpTunnelFailed = self.profile.kind == .rdp
                    self.ssh?.disconnect()
                    self.rdp?.disconnect()
                    self.vnc?.disconnect()
                    self.update(
                        "failed",
                        message:
                            WireGuardError.transport.localizedDescription,
                        attempt: attempt)
                    if self.profile.kind == .rdp {
                        if self.rdp == nil { self.rdpStopped(retryable: true, attempt: attempt) }
                    } else {
                        self.generation = UUID()
                    }
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
                    self.vpnState = .connected
                    self.startProtocol(
                        credential: credential, attempt: attempt, tunnelPort: endpoint.port, tunnelToken: endpoint.token
                    )
                } catch {
                    guard let self, self.generation == attempt, !Task.isCancelled else {
                        transport.stop()
                        return
                    }
                    self.vpnState = .failed
                    self.update(
                        "failed",
                        message: (error as? OpenVPNError)?.errorDescription ?? (error as? WireGuardError)?
                            .errorDescription
                            ?? WireGuardError.transport.localizedDescription,
                        attempt: attempt)
                    if self.profile.kind == .rdp {
                        self.rdpStopped(retryable: true, attempt: attempt)
                    }
                }
            }
        } catch {
            rdpCredential = nil
            vpnState = .failed
            update(
                "failed",
                message: (error as? OpenVPNError)?.errorDescription ?? (error as? WireGuardError)?.errorDescription
                    ?? WireGuardError.unavailable.localizedDescription, attempt: attempt)
        }
    }
    private func startProtocol(
        credential: ConnectionCredential, attempt previousAttempt: UUID? = nil,
        tunnelPort: Int = 0, tunnelToken: String? = nil
    ) {
        generation = previousAttempt ?? UUID()
        let attempt = generation
        state = rdpReconnect.attempts > 0 ? .reconnecting : .connecting
        message = rdpReconnect.attempts > 0 ? "Reconnecting, attempt \(rdpReconnect.attempts) of 3…" : "Connecting…"
        if let terminal {
            terminalAvailable = true
            filesAvailable = true
            credentialsRejected = false
            let client = FCSSHClient()
            client.tunnelPort = tunnelPort
            client.tunnelToken = tunnelToken
            client.forwardingRules = profile.forwardingRules.map(\.nativeConfiguration)
            client.setTerminalVisible(sshMode == .terminal || sshMode == .split)
            ssh = client
            forwarding.attach(client)
            client.onForwarding = { [weak self] id, status, port, count, message in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt else { return }
                    self.forwarding.receive(id: id, state: status, port: port, connections: count, message: message)
                }
            }
            client.onFileAvailability = { [weak self] available in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt else { return }
                    self.filesAvailable = available
                    if !available && (self.sshMode == .files || self.sshMode == .split) {
                        self.sshMode = self.terminalAvailable ? .terminal : .tunnels
                    }
                }
            }
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
                    if !available { self.sshMode = self.filesAvailable ? .files : .tunnels }
                }
            }
            client.onData = { [weak self] data in
                DispatchQueue.main.sync {
                    guard let self, self.generation == attempt else { return }
                    if !self.isSelected { self.hasUnreadOutput = true }
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
        } else if profile.kind == .vnc, let desktop {
            startVNC(
                credential: credential, desktop: desktop, attempt: attempt, tunnelPort: tunnelPort,
                tunnelToken: tunnelToken)
        } else if let desktop {
            do {
                if profile.launchFullScreen {
                    displayScreens = screenSnapshot(
                        profile.useAllMonitors, desktop.window?.screen ?? NSApp.keyWindow?.screen)
                    displayLayout = try RDPDisplayLayout(screens: displayScreens, retina: profile.retinaDisplay)
                    startupPresentationPending = true
                }
            } catch {
                rdpCredential = nil
                update("failed", message: error.localizedDescription, attempt: attempt)
                return
            }
            resizeCoordinator = RDPResizeCoordinator()
            lastSubmittedScale = nil
            observedDesktopSize = nil
            confirmedMonitors = false
            displayMessage = ""
            let client = makeRDPClient()
            rdp = client
            rdpTunnelFailed = false
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
                    let previouslyConfirmed = self.confirmedMonitors
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
                    if self.confirmedMonitors != previouslyConfirmed {
                        self.record(
                            self.confirmedMonitors
                                ? "RDP: server confirmed the monitor layout."
                                : "RDP: server monitor layout differs from the requested layout.")
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
                    self.observeDesktop(size)
                    self.desktop?.adoptDesktopSize(size)
                    if self.fullScreenPresented, size != self.fullScreen?.layout.bounds.size {
                        self.exitFullScreen(
                            reason: "The server changed the desktop size. The session continues in the workspace.")
                    }
                    let next = self.resizeCoordinator.observe(size)
                    if self.resizeCoordinator.pending == nil {
                        self.displayMessage = ""
                    }
                    self.submitResize(next)
                    self.scheduleResizeObservation()
                    self.presentStartupDesktopIfReady()
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
            client.onStopped = { [weak self] retryable in
                DispatchQueue.main.async { self?.rdpStopped(retryable: retryable, attempt: attempt) }
            }
            client.onTrust = trustCallback(attempt: attempt)
            experimentalRDPEnabled = UserDefaults.standard.bool(forKey: "experimentalRDP")
            graphicsPath =
                experimentalRDPEnabled ? "GFX / H.264 requested (experimental)" : "Compatible bitmap graphics"
            client.experimentalGraphics = experimentalRDPEnabled
            client.inputWakeEnabled = experimentalRDPEnabled
            client.onGraphicsPath = { [weak self] path in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state.active else { return }
                    if self.graphicsPath != path {
                        self.graphicsPath = path
                        if self.experimentalRDPEnabled { self.record("Graphics: \(path)") }
                    }
                }
            }
            if experimentalRDPEnabled {
                client.onFrameRegion = { [weak desktop] data, width, height, x, y, w, h in
                    desktop?.mailbox.patch(
                        data, desktopWidth: width, desktopHeight: height,
                        rect: CGRect(x: x, y: y, width: w, height: h))
                }
            }
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
            desktop.synchronizeCapsLock = { [weak client] enabled in client?.synchronizeCapsLock(enabled) }
            desktop.preparePaste = { [weak self] in self?.syncClipboard() }
            desktop.sendPointer = { [weak client] flags, x, y in client?.sendPointerFlags(flags, x: x, y: y) }
            client.onDisplayAvailability = { [weak self] available in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state.active else { return }
                    if self.resizeCoordinator.available != available {
                        self.record(
                            available
                                ? "RDP: server enabled Display Control resolution updates."
                                : "RDP: server disabled Display Control resolution updates.")
                    }
                    let next = self.resizeCoordinator.availability(available)
                    if self.resizeCoordinator.isSatisfied { self.displayMessage = "" }
                    self.submitResize(next)
                    self.scheduleResizeObservation()
                }
            }
            client.onResizeResult = { [weak self] id, result in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state == .connected,
                        let pending = self.resizeCoordinator.pending, pending.id == id
                    else { return }
                    let outcome =
                        result == "submitted"
                        ? "submitted; awaiting server geometry"
                        : (result == "restricted" ? "restricted by server limits" : "could not be sent")
                    self.record(
                        "RDP resize #\(id): \(Self.resolution(pending.request.size)), scale \(pending.request.scale)% — \(outcome)."
                    )
                    let next = self.resizeCoordinator.result(id: id, submitted: result == "submitted")
                    if result == "submitted" {
                        self.lastSubmittedScale = pending.request.scale
                        self.displayMessage =
                            self.resizeCoordinator.pending == nil
                            ? "Scaling requested; Windows controls its application."
                            : "Resolution requested; waiting for the server’s desktop."
                    } else {
                        self.displayMessage =
                            result == "restricted"
                            ? "The server does not allow this resolution. The desktop is fitted locally."
                            : "The resolution update could not be sent. The desktop is fitted locally."
                    }
                    self.submitResize(next)
                    self.scheduleResizeObservation()
                }
            }
            desktop.resizeRemote = { [weak self] width, height, scale in
                guard let self, self.generation == attempt, self.resizeEnabled,
                    let request = RDPResizeRequest(width: width, height: height, scale: scale)
                else { return }
                let changed = self.resizeCoordinator.desired != request
                if changed {
                    self.record(
                        "RDP window resize requested: \(Self.resolution(request.size)), scale \(request.scale)%.")
                }
                let next = self.resizeCoordinator.request(request)
                if self.resizeCoordinator.isSatisfied { self.displayMessage = "" }
                self.submitResize(next)
                if changed { self.scheduleResizeObservation() }
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
                self.initialResolution = "\(Self.resolution(size)), scale \(scale)%"
                self.record(
                    "RDP initial resolution requested: \(self.initialResolution); \(self.displayLayout?.monitors.count ?? 1) monitor(s)."
                )
                self.record(
                    "RDP options: Resize with window \(self.profile.dynamicResolution ? "on" : "off"), Retina \(self.profile.retinaDisplay ? "on" : "off"), clipboard \(self.profile.clipboard ? "on" : "off"), audio \(self.profile.audioPlayback ? "on" : "off"), \(self.profile.redirectedFolders.count) shared folder(s)."
                )
                self.lastSubmittedScale = scale
                self.resizeCoordinator.initialScale(scale)
                client?.connectHost(
                    self.profile.host, port: self.profile.port, username: self.profile.username,
                    domain: self.profile.domain, password: credential.password,
                    width: Int(size.width), height: Int(size.height), scale: scale,
                    clipboard: self.profile.clipboard, audioPlayback: self.profile.audioPlayback)
            }
            if let layout = displayLayout {
                connect(layout.bounds.size, layout.monitors[0].desktopScale)
            } else {
                desktop.withInitialSize(
                    width: profile.desktopWidth, height: profile.desktopHeight,
                    matchWindow: profile.dynamicResolution || profile.displayMode == .matchWindow,
                    settle: profile.dynamicResolution
                ) {
                    [weak desktop] size in
                    let factor =
                        self.profile.retinaDisplay
                        ? desktop?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1 : 1
                    let requested =
                        self.profile.dynamicResolution || self.profile.displayMode == .matchWindow
                        ? size
                        : CGSize(
                            width: self.profile.retinaDisplay ? floor(size.width * factor / 2) * 2 : size.width,
                            height: floor(size.height * factor))
                    connect(
                        requested,
                        self.profile.dynamicResolution
                            ? desktop?.initialDesktopScale ?? 100 : Int((factor * 100).rounded()))
                }
            }
        }
    }
    private var resizeEnabled: Bool {
        state == .connected && profile.dynamicResolution
            && (displayLayout?.monitors.count ?? 1) == 1
            && !fullScreenPresented && !startupPresentationPending
    }
    private func startVNC(
        credential: ConnectionCredential, desktop: RDPDesktopView, attempt: UUID,
        tunnelPort: Int, tunnelToken: String?
    ) {
        let client = FCVNCClient()
        client.appleVirtualDisplay = profile.vncRemoteIsMac
        client.adaptiveVideo = profile.vncRemoteIsMac && tunnelPort == 0
        desktop.usesTextKeySymbols = true
        client.retinaDisplay = profile.retinaDisplay
        client.desktopWidth = profile.desktopWidth
        client.desktopHeight = profile.desktopHeight
        vnc = client
        vncPointerMask = 0
        client.tunnelPort = tunnelPort
        client.tunnelToken = tunnelToken
        client.onTrust = trustCallback(attempt: attempt)
        client.onStatus = { [weak self] status, message in
            DispatchQueue.main.async { self?.update(status, message: message, attempt: attempt) }
        }
        client.onAuthenticationRejected = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == attempt else { return }
                self.credentialsRejected = true
            }
        }
        client.onKeyboardInput = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == attempt, self.state.active else { return }
                self.record("VNC keyboard input sent. Key contents are not recorded.")
            }
        }
        client.onTyping = { [weak self] typing in
            DispatchQueue.main.async {
                guard let self, self.generation == attempt else { return }
                if self.vncTyping && !typing && self.displayMessage == "Typing clipboard text…" {
                    self.displayMessage = ""
                }
                self.vncTyping = typing
            }
        }
        client.onAppleLayout = { [weak self] logicalW, logicalH, backingW, backingH in
            DispatchQueue.main.async {
                guard let self, self.generation == attempt, self.state.active else { return }
                self.record(
                    "Apple display confirmed: \(logicalW) × \(logicalH) logical, \(backingW) × \(backingH) pixels.")
                self.appleResizeObservation?.cancel()
                let observed = CGSize(width: logicalW, height: logicalH)
                self.displayMessage =
                    self.appleRequestedSize == nil || self.appleRequestedSize == observed
                    ? "" : "The Mac selected \(logicalW) × \(logicalH). The desktop is fitted locally."
            }
        }
        client.onPixelBuffer = { [weak desktop] buffer in
            desktop?.submit(buffer)
        }
        var firstFrame = true
        client.onFrame = { [weak self, weak desktop] pixels, width, height, stride in
            desktop?.submit(pixels, width: width, height: height, stride: stride)
            if firstFrame {
                firstFrame = false
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.state.active else { return }
                    self.record("VNC first framebuffer received: \(width) × \(height) px.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak desktop] in
                        guard let self, self.generation == attempt, self.state.active, let desktop else { return }
                        let frame = desktop.mailbox.snapshot()?.1
                        self.record(
                            "VNC renderer: queued \(frame?.width ?? 0) × \(frame?.height ?? 0), expected \(desktop.expectedDesktopSize.map(Self.resolution) ?? "unset"), uploaded \(desktop.uploadedBytes) bytes, presented \(desktop.presentationMetrics.count), suspended \(desktop.renderingSuspended), mounted \(desktop.window != nil)."
                        )
                    }
                }
            }
        }
        client.onDesktopSize = { [weak self] width, height in
            DispatchQueue.main.async {
                guard let self, self.generation == attempt, self.state.active else { return }
                if self.fullScreenPresented { self.exitFullScreen() }
                let firstSize = self.observedDesktopSize == nil
                self.observeDesktop(CGSize(width: width, height: height))
                if self.profile.vncRemoteIsMac, let requested = self.appleRequestedSize {
                    let factor: CGFloat = self.profile.retinaDisplay ? 2 : 1
                    if requested.width * factor == CGFloat(width) && requested.height * factor == CGFloat(height) {
                        self.appleResizeObservation?.cancel()
                        self.displayMessage = ""
                    }
                }
                self.desktop?.adoptDesktopSize(CGSize(width: width, height: height))
                if firstSize && self.profile.launchFullScreen {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == attempt else { return }
                        self.enterFullScreen()
                    }
                }
            }
        }
        desktop.keySymbolForEvent = VNCKeyboard.keySym(keyCode:characters:)
        desktop.sendKeySymbol = { [weak client] key, down in client?.sendKeySym(key, pressed: down) }
        desktop.sendKey = { [weak client] code, down, extended in
            if let key = VNCKeyboard.keySym(scanCode: code, extended: extended) {
                client?.sendKeySym(key, pressed: down)
            }
        }
        desktop.sendText = { [weak client] text in
            for scalar in text.unicodeScalars {
                let key = scalar.value <= 255 ? scalar.value : 0x0100_0000 | scalar.value
                client?.sendKeySym(key, pressed: true)
                client?.sendKeySym(key, pressed: false)
            }
        }
        desktop.typeClipboard = { [weak self] in self?.pasteTextFromClipboard() }
        desktop.sendPointer = { [weak self, weak client] flags, x, y in
            guard let self else { return }
            let buttons = [(0x1000, 1), (0x2000, 4), (0x4000, 2)]
            for (flag, mask) in buttons where flags & flag != 0 {
                if flags & 0x8000 != 0 { self.vncPointerMask |= mask } else { self.vncPointerMask &= ~mask }
            }
            if flags & 0x0200 != 0 {
                let wheel = flags & 0x0100 == 0 ? 8 : 16
                client?.sendPointerMask(self.vncPointerMask | wheel, x: x, y: y)
            }
            client?.sendPointerMask(self.vncPointerMask, x: x, y: y)
        }
        if profile.vncRemoteIsMac {
            desktop.resizeRemote = { [weak self, weak client] width, height, scale in
                guard let self, self.generation == attempt, self.state == .connected,
                    self.profile.dynamicResolution, !self.fullScreenPresented
                else { return }
                let factor = self.profile.retinaDisplay ? 2 : 1
                let viewportScale = max(1, scale / 100)
                let requestedW = min(3840 / factor, max(200, width / viewportScale))
                let requestedH = min(2160 / factor, max(200, height / viewportScale))
                let requested = CGSize(width: requestedW, height: requestedH)
                guard self.appleRequestedSize != requested else { return }
                self.appleRequestedSize = requested
                client?.resizeAppleWidth(requestedW, height: requestedH)
                self.record("Apple display resize submitted: \(requestedW) × \(requestedH) logical.")
                self.appleResizeObservation?.cancel()
                let observation = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == attempt, self.state == .connected else { return }
                    self.displayMessage =
                        "The Mac has not confirmed the resolution change. The desktop is fitted locally."
                }
                self.appleResizeObservation = observation
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: observation)
            }
            desktop.withInitialSize(
                width: profile.desktopWidth, height: profile.desktopHeight,
                matchWindow: profile.dynamicResolution || profile.displayMode == .matchWindow,
                settle: profile.dynamicResolution
            ) { [weak self, weak client] size in
                guard let self, self.generation == attempt, self.state.active, let client else { return }
                let factor = self.profile.retinaDisplay ? 2 : 1
                let match = self.profile.dynamicResolution || self.profile.displayMode == .matchWindow
                let viewportScale =
                    match && self.profile.retinaDisplay ? self.desktop?.window?.backingScaleFactor ?? 1 : 1
                client.desktopWidth = min(3840 / factor, max(200, Int(size.width / viewportScale)))
                client.desktopHeight = min(2160 / factor, max(200, Int(size.height / viewportScale)))
                self.appleRequestedSize = CGSize(width: client.desktopWidth, height: client.desktopHeight)
                self.initialResolution = "\(client.desktopWidth) × \(client.desktopHeight) logical"
                client.connectHost(
                    self.profile.host, port: self.profile.port, username: self.profile.username,
                    password: credential.password)
            }
        } else {
            client.connectHost(
                profile.host, port: profile.port, username: profile.username, password: credential.password)
        }
    }

    private func submitResize(_ submission: RDPResizeCoordinator.Submission?) {
        guard resizeEnabled, let submission else { return }
        let request = submission.request
        record(
            "RDP resize #\(submission.id) sending: \(Self.resolution(request.size)), scale \(request.scale)%.")
        rdp?.resizeWidth(request.width, height: request.height, scale: request.scale, requestID: submission.id)
        scheduleResizeObservation()
    }
    private func scheduleResizeObservation() {
        guard resizeEnabled else { return }
        displayObservationTask?.cancel()
        displayObservationTask = nil
        guard let observation = resizeCoordinator.observation else { return }
        let attempt = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == attempt, self.resizeEnabled,
                self.resizeCoordinator.observation == observation
            else { return }
            self.displayObservationTask = nil
            let next = self.resizeCoordinator.expire()
            if self.resizeCoordinator.isSatisfied {
                self.displayMessage = ""
            } else if next == nil {
                self.displayMessage =
                    self.resizeCoordinator.available
                    ? "The resolution change was not confirmed. The desktop is fitted locally."
                    : "The server has not enabled resolution updates. The desktop is fitted locally."
            }
            self.submitResize(next)
        }
        displayObservationTask = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
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
        resizeCoordinator.cancel()
        rdp?.cancelResize()
        displayMessage = ""
        let presentation = RDPFullScreenPresentation(desktop: desktop, screens: screens, layout: layout)
        presentation.onActivate = { [weak self] in
            guard let self, self.state == .connected else { return }
            self.workspace?.activatePresentation(of: self)
        }
        presentation.onExit = { [weak self] reason in self?.exitFullScreen(reason: reason) }
        fullScreen = presentation
        fullScreenPresented = true
        record("Desktop entered full screen on \(screens.count) display(s).")
        presentation.show()
    }
    func exitFullScreen(reason: String? = nil, restoreFocus: Bool = true) {
        let presentation = fullScreen
        fullScreen = nil
        fullScreenPresented = false
        startupPresentationPending = false
        presentation?.exit(notify: false, restoreFocus: restoreFocus && state == .connected)
        if presentation != nil { record("Desktop exited full screen.") }
        if let reason { displayMessage = reason }
        desktop?.requestResize()
    }
    private func retireFullScreen() {
        displayObservationTask?.cancel()
        resizeCoordinator.cancel()
        rdp?.cancelResize()
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
        if profile.kind == .rdp, rdpReconnect.attempts > 0,
            [.connecting, .verifying, .authenticating].contains(state)
        {
            if state == .connecting { state = .reconnecting }
            self.message = "Reconnect attempt \(rdpReconnect.attempts) of 3 · \(message)"
        }
        if state == .failed || state == .stale { latestFailure = message }
        if state == .failed || state == .disconnected { appleResizeObservation?.cancel() }
        record(message)
        if state == .connected {
            if profile.kind == .rdp {
                rdpReconnect.connected(now: ProcessInfo.processInfo.systemUptime)
                monitorRDP(attempt: attempt)
            }
            if profile.kind == .ssh && filesAvailable && (sshMode == .files || sshMode == .split) { files.showFiles() }
            desktop?.inputEnabled = true
            presentStartupDesktopIfReady()
            if profile.kind == .vnc && profile.launchFullScreen { enterFullScreen() }
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
        if !state.active || state == .stale {
            rdpHealthTask?.cancel()
            rdpHealthTask = nil
            vncTyping = false
            retireFullScreen()
            files.disconnected()
            forwarding.disconnected()
            tunnelTask?.cancel()
            tunnel?.stop()
            tunnel = nil
            if vpnState != .failed { vpnState = .disconnected }
            cancelPrompts()
            stopClipboard()
            desktop?.cancelPendingDisplayWork()
            desktop?.releaseInput()
            desktop?.inputEnabled = false
        }
    }
    static func resolution(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height)) px"
    }
    private func observeDesktop(_ size: CGSize) {
        guard observedDesktopSize != size else { return }
        let initial = observedDesktopSize == nil
        observedDesktopSize = size
        record(
            "\(profile.kind.rawValue) \(initial ? "initial desktop received" : "desktop resized by server"): \(Self.resolution(size))."
        )
    }
    private func record(_ message: String) {
        logs.append(SessionLog(message: message))
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
    private func monitorRDP(attempt: UUID) {
        rdpHealthTask?.cancel()
        rdpHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.generation == attempt, self.state == .connected else { return }
                if self.rdp?.responsive == false {
                    self.update(
                        "stale", message: "The RDP connection stopped responding. Closing the old connection…",
                        attempt: attempt)
                    self.rdp?.interruptStalledConnection()
                    return
                }
            }
        }
    }
    private func rdpStopped(retryable: Bool, attempt: UUID) {
        guard generation == attempt, workspace?.isShuttingDown != true else { return }
        rdp = nil
        rdpHealthTask?.cancel()
        rdpHealthTask = nil
        guard retryable || rdpTunnelFailed, rdpCredential != nil,
            let delay = rdpReconnect.nextDelay(now: ProcessInfo.processInfo.systemUptime)
        else {
            if state == .stale { state = .failed }
            if (retryable || rdpTunnelFailed) && rdpReconnect.attempts == 3 {
                state = .failed
                message = "Could not reconnect after 3 attempts. Check the network and reconnect when ready."
                record(message)
            }
            rdpCredential = nil
            return
        }
        // Invalidate queued callbacks before scheduling a fresh native client and tunnel lease.
        generation = UUID()
        let retryGeneration = generation
        state = .reconnecting
        message = "Connection lost. Reconnecting in \(Int(delay)) seconds (attempt \(rdpReconnect.attempts) of 3)…"
        record(message)
        rdpReconnectTask?.cancel()
        rdpReconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == retryGeneration, self.state == .reconnecting,
                let credential = self.rdpCredential, self.workspace?.isShuttingDown != true
            else { return }
            self.start(credential: credential)
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
        appleResizeObservation?.cancel()
        appleResizeObservation = nil
        rdpReconnectTask?.cancel()
        rdpReconnectTask = nil
        rdpHealthTask?.cancel()
        rdpHealthTask = nil
        rdpCredential = nil
        rdpReconnect = RDPReconnectPolicy()
        retireFullScreen()
        generation = UUID()
        tunnelTask?.cancel()
        tunnelTask = nil
        tunnel?.stop()
        tunnel = nil
        vpnState = .disconnected
        cancelPrompts()
        stopClipboard()
        desktop?.cancelPendingDisplayWork()
        desktop?.releaseInput()
        desktop?.inputEnabled = false
        files.disconnected()
        forwarding.disconnected()
        ssh?.disconnect()
        rdp?.disconnect()
        vnc?.disconnect()
        vncTyping = false
        generation = UUID()
        state = .disconnected
        message = "Disconnected"
        record(message)
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
        guard profile.kind == .rdp, profile.clipboard, isSelected, state == .connected else { return }
        clipboardBridge.synchronize(
            text: { rdp?.setClipboardText($0) }, files: { rdp?.setClipboardFiles($0) })
    }
    private func stopClipboard() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        clipboardBridge.invalidate()
        clipboardMessage = ""
    }
    func controlAltDelete() {
        guard state == .connected else { return }
        desktop?.releaseInput()
        fullScreen?.releaseInput()
        rdp?.sendControlAltDelete()
        vnc?.sendControlAltDelete()
    }
    func pasteTextFromClipboard() {
        guard profile.kind == .vnc, state == .connected, !vncTyping else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            displayMessage = "The clipboard does not contain text."
            return
        }
        typeVNCText(text)
    }
    func typeVNCText(_ text: String) {
        guard profile.kind == .vnc, state == .connected else { return }
        desktop?.releaseInput()
        fullScreen?.releaseInput()
        if vnc?.typeText(text) == true {
            vncTyping = true
            displayMessage = "Typing clipboard text…"
        } else {
            displayMessage = "Use nonempty text up to 16,384 characters, with no controls other than tabs and newlines."
        }
    }
    func cancelVNCTyping() {
        vnc?.cancelTyping()
        vncTyping = false
        displayMessage = "Typing cancelled. Characters already sent remain on the server."
    }

    func focus() {
        guard profile.kind != .ssh || (terminalAvailable && (sshMode == .terminal || sshMode == .split)) else { return }
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

extension RemoteSession {
    func supports(_ mode: SSHWorkspaceMode) -> Bool {
        switch mode {
        case .terminal: return terminalAvailable
        case .files: return filesAvailable
        case .split: return terminalAvailable && filesAvailable
        case .tunnels: return true
        }
    }
    var showsTerminalTools: Bool {
        profile.kind == .ssh && terminalAvailable && (sshMode == .terminal || sshMode == .split)
    }
    var interruptionReason: String? {
        if files.busy && forwarding.hasActiveTunnels {
            return "This stops file work and closes all tunnel connections."
        }
        if files.busy { return "This stops the current file work." }
        if forwarding.hasActiveTunnels { return "This stops active tunnels and closes their connections." }
        return nil
    }
    func zoomTerminal(_ delta: Double) {
        terminal?.zoom(delta)
        terminalZoom = Int(
            ((terminal.map { Double($0.view.font.pointSize) } ?? profile.fontSize) / profile.fontSize * 100).rounded())
    }
    func resetTerminalZoom() {
        if let terminal { terminal.zoom(profile.fontSize - terminal.view.font.pointSize) }
        terminalZoom = 100
    }
}
