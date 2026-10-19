extension RemoteSession {
    func startShowcase() {
        state = .connected
        message = "Connected"
        vpnState = profile.wireGuardID == nil ? .disconnected : .connected
        record("Session connected.")
        if let terminal {
            files.showcaseListing(path: "/home/\(profile.username)")
            if ShowcaseLibrary.fileProfiles.contains(profile.id) { sshMode = .files }
            let text = """
                \u{1B}[1;36mWelcome to \(profile.host)\u{1B}[0m
                Ubuntu 24.04.3 LTS · arm64 · Secure Shell

                  System load:  0.08              Processes:       142
                  Memory usage: 24%               Users logged in: 2
                  Disk usage:   18% of 240 GB     Updates:         0 pending

                \u{1B}[32m\(profile.username)@\(profile.host)\u{1B}[0m:~$ systemctl --user status research-stack
                \u{1B}[32m●\u{1B}[0m research-stack.service - Research services
                     Loaded: loaded; enabled
                     Active: \u{1B}[32mactive (running)\u{1B}[0m

                  SERVICE                STATUS       UPTIME      HEALTH
                  telemetry-api          running      12d 04h     healthy
                  archive-worker         running      12d 04h     healthy
                  metrics-collector      running      12d 04h     healthy
                  backup-scheduler       running       3d 17h     healthy

                \u{1B}[32m\(profile.username)@\(profile.host)\u{1B}[0m:~$ ls projects
                \u{1B}[1;34marchives  cortex  telemetry  reports\u{1B}[0m

                \u{1B}[32m\(profile.username)@\(profile.host)\u{1B}[0m:~$ 
                """
            terminal.view.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
            let username = profile.username
            terminal.sendBytes = { [weak terminal] bytes in
                guard let terminal else { return }
                if bytes.contains(13) {
                    terminal.view.feed(text: "\r\nAll services healthy.\r\n\u{1B}[32m\(username)\u{1B}[0m:~$ ")
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
