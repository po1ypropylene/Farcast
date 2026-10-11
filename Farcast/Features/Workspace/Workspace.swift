import AppKit
import Combine
import SwiftData
import UniformTypeIdentifiers

@MainActor final class Workspace: NSObject, ObservableObject, NSWindowDelegate {
    @Published var sessions: [RemoteSession] = []
    @Published var selectedSessionID: UUID?
    @Published var prompts: [SessionPrompt] = []
    @Published var error: String?
    @Published var testServerImport: TestServerImportRequest?
    @Published var editor: EditorRequest?
    @Published var showWireGuard = false
    @Published var showLibraryImport = false
    @Published var showInspector = false
    @Published private(set) var detachedSessions: [UUID: UUID] = [:]
    @Published private(set) var focusedDetachedSlot: UUID?
    @Published private(set) var detachedInspectors: Set<UUID> = []
    func toggleInspector(slot: UUID? = nil) {
        if let slot = slot ?? focusedDetachedSlot {
            if detachedInspectors.contains(slot) {
                detachedInspectors.remove(slot)
            } else {
                detachedInspectors.insert(slot)
            }
        } else {
            showInspector.toggle()
        }
    }
    private weak var mainWindow: NSWindow?
    private var sessionWindows: [UUID: NSWindow] = [:]
    var attachedSessions: [RemoteSession] { sessions.filter { !detachedSessions.values.contains($0.id) } }
    var activeSession: RemoteSession? {
        if let slot = focusedDetachedSlot { return session(in: slot) }
        return selectedSession
    }
    func session(in slot: UUID) -> RemoteSession? { sessions.first { $0.id == detachedSessions[slot] } }
    let trust: TrustStore
    private let loadCredential: (UUID) throws -> ConnectionCredential?
    private let defaults: UserDefaults
    private(set) var isShuttingDown = false
    private var shutdownFinished = false
    private var shutdownCompletions: [@MainActor @Sendable () -> Void] = []
    var modelContext: ModelContext?
    var selectedSession: RemoteSession? { sessions.first { $0.id == selectedSessionID } }

    init(
        loadCredential: @escaping (UUID) throws -> ConnectionCredential? = CredentialStore.load,
        defaults: UserDefaults = .standard
    ) {
        self.loadCredential = loadCredential
        self.defaults = defaults
        trust = TrustStore(defaults: defaults)
        super.init()
    }

    private func credential(for draft: ConnectionDraft, provided: ConnectionCredential? = nil) throws
        -> ConnectionCredential?
    {
        if draft.kind == .ssh && draft.authentication == .interactive { return ConnectionCredential() }
        return try provided ?? loadCredential(draft.id)
    }

    private func start(_ session: RemoteSession, credential: ConnectionCredential?) {
        if let credential { session.start(credential: credential) } else { session.askForCredentials() }
    }
    func chooseTestServerFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Test Servers"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw TestServerImportError.invalidDocument }
            let document = try TestServerDocument.read(Data(contentsOf: url))
            guard !document.enabledServers.isEmpty else {
                error =
                    "No enabled test servers. Fill in the local file and set enabled to true for each server you want to import."
                return
            }
            testServerImport = TestServerImportRequest(document: document)
        } catch let problem as TestServerImportError {
            error = problem.localizedDescription
        } catch {
            self.error = "The test-server file could not be read. Check its format and permissions locally."
        }
    }
    func connect(_ draft: ConnectionDraft, credential: ConnectionCredential? = nil, persistent: Bool = true) {
        guard !isShuttingDown else { return }
        guard draft.validationMessage == nil else {
            error = draft.validationMessage
            return
        }
        do {
            let stored = try self.credential(for: draft, provided: credential)
            let session = RemoteSession(profile: draft, workspace: self, persistent: persistent)
            sessions.append(session)
            select(session.id)
            start(session, credential: stored)
            persistWorkspace()
        } catch { self.error = error.localizedDescription }
    }
    func select(_ id: UUID?) {
        if let slot = detachedSessions.first(where: { $0.value == id })?.key {
            sessionWindows[slot]?.makeKeyAndOrderFront(nil)
            return
        }
        selectedSessionID = id
        focusedDetachedSlot = nil
        updateActiveSession()
    }
    private func updateActiveSession() {
        for session in sessions {
            let selected = session.id == activeSession?.id
            if session.isSelected && !selected { session.desktop?.releaseInput() }
            session.isSelected = selected
        }
        DispatchQueue.main.async { [weak self] in self?.activeSession?.focus() }
    }
    func popOut(_ session: RemoteSession, content: (UUID) -> NSView) {
        guard !isShuttingDown, sessions.contains(where: { $0 === session }) else { return }
        if let slot = detachedSessions.first(where: { $0.value == session.id })?.key {
            sessionWindows[slot]?.makeKeyAndOrderFront(nil)
            return
        }
        let slot = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = session.profile.name
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 480)
        detachedSessions[slot] = session.id
        sessionWindows[slot] = window
        window.contentView = content(slot)
        window.center()
        if selectedSessionID == session.id { selectedSessionID = attachedSessions.first?.id }
        focusedDetachedSlot = slot
        updateActiveSession()
        window.makeKeyAndOrderFront(nil)
    }
    func activatePresentation(of session: RemoteSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        if let slot = detachedSessions.first(where: { $0.value == session.id })?.key {
            focusedDetachedSlot = slot
        } else {
            focusedDetachedSlot = nil
            selectedSessionID = session.id
        }
        updateActiveSession()
    }
    func activate(_ window: NSWindow) {
        if let slot = sessionWindows.first(where: { $0.value === window })?.key {
            focusedDetachedSlot = slot
        } else if window === mainWindow || window.title == "Farcast" {
            mainWindow = window
            focusedDetachedSlot = nil
        } else {
            // Sheets and file pickers retain their presenting connection's ownership.
            return
        }
        updateActiveSession()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { activate(window) }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let slot = sessionWindows.first(where: { $0.value === window })?.key
        else { return }
        let wasFocused = focusedDetachedSlot == slot
        detachedInspectors.remove(slot)
        let id = detachedSessions.removeValue(forKey: slot)
        sessionWindows.removeValue(forKey: slot)
        if wasFocused { focusedDetachedSlot = nil }
        if !isShuttingDown && wasFocused {
            select(id)
            mainWindow?.makeKeyAndOrderFront(nil)
        } else {
            if selectedSessionID == nil { selectedSessionID = id }
            updateActiveSession()
        }
    }
    func returnToWorkspace(slot: UUID) { sessionWindows[slot]?.close() }
    func close(_ session: RemoteSession) {
        guard
            let index = attachedSessions.firstIndex(where: { $0.id == session.id })
                ?? sessions.firstIndex(where: { $0.id == session.id })
        else { return }
        session.disconnect()
        if let slot = detachedSessions.first(where: { $0.value == session.id })?.key {
            detachedInspectors.remove(slot)
            detachedSessions.removeValue(forKey: slot)
            let window = sessionWindows.removeValue(forKey: slot)
            window?.delegate = nil
            window?.close()
            if focusedDetachedSlot == slot { focusedDetachedSlot = nil }
        }
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            select(attachedSessions.isEmpty ? nil : attachedSessions[min(index, attachedSessions.count - 1)].id)
        }
        updateActiveSession()
        persistWorkspace()
    }
    func reconnect(_ session: RemoteSession) {
        guard !isShuttingDown else { return }
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        var draft = session.profile
        let persistent = session.persistent
        if persistent, let modelContext {
            do {
                let profileID = draft.id
                var query = FetchDescriptor<SavedConnection>(predicate: #Predicate { $0.id == profileID })
                query.fetchLimit = 1
                if let saved = try modelContext.fetch(query).first { draft = ConnectionDraft(saved) }
            } catch {
                self.error = "Could not reload the saved connection. Try again before reconnecting."
                return
            }
        }
        guard draft.validationMessage == nil else {
            error = draft.validationMessage
            return
        }
        do {
            // Resolve failures before replacing the existing tab or transport.
            let stored: ConnectionCredential?
            if session.credentialsRejected && draft.authentication != .interactive {
                stored = nil
            } else {
                stored = try credential(for: draft)
            }
            let replacement = RemoteSession(profile: draft, workspace: self, persistent: persistent)
            let wasSelected = selectedSessionID == session.id
            session.disconnect()
            sessions[index] = replacement
            if let slot = detachedSessions.first(where: { $0.value == session.id })?.key {
                detachedSessions[slot] = replacement.id
                sessionWindows[slot]?.title = draft.name
                updateActiveSession()
            } else if wasSelected {
                select(replacement.id)
            }
            start(replacement, credential: stored)
            persistWorkspace()
        } catch { self.error = error.localizedDescription }
    }
    func enqueue(_ prompt: SessionPrompt) {
        guard !isShuttingDown else {
            prompt.waiter.resolve(nil)
            return
        }
        prompts.append(prompt)
    }
    func cancelPrompts(sessionID: UUID) {
        for prompt in prompts where prompt.sessionID == sessionID { prompt.waiter.resolve(nil) }
        prompts.removeAll { $0.sessionID == sessionID }
    }
    func answer(_ prompt: SessionPrompt, value: String?, remember: Bool = false) {
        if remember, prompt.kind == .trust, let session = sessions.first(where: { $0.id == prompt.sessionID }),
            let fingerprint = prompt.fingerprint
        {
            trust.remember(fingerprint, for: session.profile.endpointKey)
        }
        prompt.waiter.resolve(value)
        prompts.removeAll { $0.id == prompt.id }
    }
    func saveCredentials(_ credential: ConnectionCredential, for prompt: SessionPrompt) throws {
        guard let session = sessions.first(where: { $0.id == prompt.sessionID }), session.persistent else { return }
        try CredentialStore.save(credential, for: session.profile.id)
    }
    func reorder(_ source: UUID, before destination: UUID) {
        guard let from = sessions.firstIndex(where: { $0.id == source }),
            let to = sessions.firstIndex(where: { $0.id == destination }), from != to
        else { return }
        let session = sessions.remove(at: from)
        sessions.insert(session, at: from < to ? to - 1 : to)
        persistWorkspace()
    }
    func persistWorkspace() {
        defaults.set(
            sessions.filter(\.persistent).map { $0.profile.id.uuidString }, forKey: "workspaceConnections")
    }
    func restoreWorkspace(_ saved: [SavedConnection]) {
        guard !isShuttingDown, sessions.isEmpty, defaults.object(forKey: "restoreWorkspace") as? Bool ?? true else {
            return
        }
        for id in defaults.stringArray(forKey: "workspaceConnections") ?? [] {
            guard let profile = saved.first(where: { $0.id.uuidString == id }) else { continue }
            let session = RemoteSession(profile: ConnectionDraft(profile), workspace: self)
            session.state = .disconnected
            session.message = "Restored · reconnect when ready"
            sessions.append(session)
        }
        select(sessions.first?.id)
    }
    func shutdown(completion: @escaping @MainActor @Sendable () -> Void) {
        if shutdownFinished {
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                MainActor.assumeIsolated { completion() }
            }
            return
        }
        shutdownCompletions.append(completion)
        guard !isShuttingDown else { return }
        isShuttingDown = true
        persistWorkspace()
        for session in sessions { session.disconnect() }
        for prompt in prompts { prompt.waiter.resolve(nil) }
        prompts.removeAll()
        // Include workers from tabs already closed or replaced by reconnect.
        let cleanup = DispatchGroup()
        cleanup.enter()
        FCSSHClient.whenAllDisconnected { cleanup.leave() }
        cleanup.enter()
        FCRDPClient.whenAllDisconnected { cleanup.leave() }
        cleanup.enter()
        WireGuardTransport.shutdownAll { cleanup.leave() }
        cleanup.notify(queue: .global(qos: .userInitiated)) { [self] in
            // AppKit can run a nested event loop while awaiting terminateLater.
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                MainActor.assumeIsolated {
                    self.shutdownFinished = true
                    let completions = self.shutdownCompletions
                    self.shutdownCompletions.removeAll()
                    for completion in completions { completion() }
                }
            }
        }
    }
}
