extension RemoteSession {
    func startShowcase() {
        state = .connected
        message = "Connected"
        vpnState = profile.wireGuardID == nil ? .disconnected : .connected
        record("Session connected.")
        if let terminal {
            files.showcaseListing(path: ".")
            if ShowcaseLibrary.fileProfiles.contains(profile.id) { sshMode = .files }
            let prompt = TerminalSample.prompt
            let text = TerminalSample.text
            terminal.view.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
            terminal.sendBytes = { [weak terminal] bytes in
                guard let terminal else { return }
                if bytes.contains(13) {
                    terminal.view.feed(text: "\r\nGideon is online. All systems are operational.\r\n\(prompt)")
                } else {
                    terminal.view.feed(byteArray: Array(bytes)[...])
                }
            }
        } else if let desktop {
            let frame = ShowcaseDesktop.frame(kind: profile.kind, username: profile.username)
            observedDesktopSize = CGSize(width: frame.width, height: frame.height)
            initialResolution = "\(frame.width) × \(frame.height)"
            desktop.adoptDesktopSize(observedDesktopSize!)
            desktop.mailbox.put(frame)
            desktop.inputEnabled = true
        }
    }
}
