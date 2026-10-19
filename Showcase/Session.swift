extension RemoteSession {
    func startShowcase() {
        state = .connected
        message = "Connected"
        vpnState = profile.wireGuardID == nil ? .disconnected : .connected
        record("Session connected.")
        if let terminal {
            files.showcaseListing(path: ".")
            if ShowcaseLibrary.fileProfiles.contains(profile.id) { sshMode = .files }
            let prompt = "barry@star-labs:~$ "
            let text = """
                S.T.A.R. LABS
                Scientific and Technological Advanced Research Laboratories

                \(prompt)gideon status

                  \u{1B}[32mGideon is online. All systems are operational.\u{1B}[0m

                  Service                 Status      Last update
                  Cortex telemetry        running     2 minutes ago
                  Speed Force monitor     stable      12 seconds ago
                  Particle accelerator    standby     1 hour ago
                  Central City sensors    connected   just now

                \(prompt)ls research
                \u{1B}[34mfield-reports  telemetry  archives\u{1B}[0m

                \(prompt)
                """
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
