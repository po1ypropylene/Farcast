import AppKit
import ApplicationServices
import SwiftData
import SwiftUI

/// Regressions for VPN draft loss and native field accessibility, using only synthetic credentials.
@main struct VPNUIReviewChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            do {
                try runChecks()
                exit(0)
            } catch {
                print("Synthetic VPN UI checks failed: \(error)")
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
    @MainActor static func runChecks() throws {
        let app = NSApplication.shared
        let suite = "com.peterpo.farcast.vpn-ui-checks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(
            for: SavedWireGuard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var configuration = WireGuardConfiguration()
        configuration.addresses = "10.0.0.2/32"
        configuration.endpoint = "vpn.example.invalid:51820"
        configuration.allowedIPs = "0.0.0.0/0"
        configuration.publicKey = Data(repeating: 2, count: 32).base64EncodedString()
        let profile = try SavedWireGuard(name: "Synthetic VPN", configuration: configuration)
        container.mainContext.insert(profile)
        try container.mainContext.save()
        var secrets = [
            profile.id: ConnectionCredential(wireGuardPrivateKey: Data(repeating: 1, count: 32).base64EncodedString())
        ]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 740),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Farcast synthetic VPN UI checks"
        defer { window.close() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        func settle() {
            let until = Date().addingTimeInterval(0.3)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
        func nodes(_ object: Any) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            func walk(_ object: Any) -> [NSObject] {
                guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
                let children =
                    ((attribute(node, "accessibilityChildren") as? [Any]) ?? [])
                    + ((attribute(node, "accessibilityRows") as? [Any]) ?? [])
                let sheet: [Any] = (node as? NSWindow)?.attachedSheet.map { [$0] } ?? []
                return [node] + (children + sheet).flatMap { walk($0) }
            }
            return walk(object)
        }
        let accessibilityApp = AXUIElementCreateApplication(getpid())
        AXUIElementSetAttributeValue(accessibilityApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(accessibilityApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        func labels() -> [String] {
            nodes(window).flatMap { node in
                [attribute(node, "accessibilityLabel") as? String, attribute(node, "accessibilityValue") as? String]
                    .compactMap { $0 }
            }
        }
        func press(_ label: String) {
            let root = window.attachedSheet ?? window
            guard
                let button = nodes(root).first(where: {
                    attribute($0, "accessibilityLabel") as? String == label
                        && attribute($0, "accessibilityRole") as? String == "AXButton"
                })
            else {
                print("Synthetic AX labels: \(labels())")
                fflush(stdout)
                preconditionFailure("Missing synthetic control: \(label)")
            }
            if let native = button as? NSButton {
                precondition(native.isEnabled, "Disabled synthetic button: \(label)")
                native.performClick(nil)
            } else {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                precondition(button.responds(to: selector))
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                let perform = unsafeBitCast(button.method(for: selector), to: Press.self)
                _ = perform(button, selector)
            }
            settle()
        }
        func focus(_ label: String) {
            guard
                let field = nodes(window).first(where: {
                    attribute($0, "accessibilityLabel") as? String == label
                        && attribute($0, "accessibilityRole") as? String == "AXTextField"
                })
            else { preconditionFailure("Missing synthetic field: \(label)") }
            let selector = NSSelectorFromString("setAccessibilityFocused:")
            precondition(field.responds(to: selector))
            typealias Focus = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(field.method(for: selector), to: Focus.self)(field, selector, true)
            settle()
        }
        func setText(_ label: String, _ value: String) {
            guard
                let field = nodes(window).first(where: {
                    attribute($0, "accessibilityLabel") as? String == label
                        && attribute($0, "accessibilityRole") as? String == "AXTextField"
                })
            else { preconditionFailure("Missing synthetic field: \(label)") }
            let selector = NSSelectorFromString("setAccessibilityValue:")
            precondition(field.responds(to: selector))
            typealias SetValue = @convention(c) (AnyObject, Selector, NSString) -> Void
            unsafeBitCast(field.method(for: selector), to: SetValue.self)(field, selector, value as NSString)
            settle()
        }

        func control(_ label: String) -> NSObject {
            guard let node = nodes(window).first(where: { attribute($0, "accessibilityLabel") as? String == label })
            else {
                print(labels())
                preconditionFailure("Missing synthetic control")
            }
            return node
        }
        func enabled(_ label: String) -> Bool {
            let node = control(label)
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            precondition(node.responds(to: selector))
            typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(node.method(for: selector), to: Enabled.self)(node, selector)
        }
        func capture(_ name: String) throws {
            guard CommandLine.arguments.count > 1, let view = window.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if ProcessInfo.processInfo.environment["FARCAST_VPN_UI_REVIEW"] == name {
                print("REVIEW synthetic VPN window: \(Bundle.main.bundlePath)")
                fflush(stdout)
                let marker = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("continue")
                let deadline = Date().addingTimeInterval(45)
                while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
            }
            let composite = NSImage(size: view.bounds.size)
            composite.lockFocus()
            window.backgroundColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
            bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            composite.unlockFocus()
            let rendered = NSBitmapImageRep(data: composite.tiffRepresentation!)!
            try rendered.representation(using: .png, properties: [:])?.write(
                to:
                    URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
        }
        for scheme in [ColorScheme.light, .dark] {
            window.setContentSize(NSSize(width: 820, height: 740))
            window.contentView = NSHostingView(
                rootView: WireGuardLibrary(
                    loadCredential: { secrets[$0] },
                    saveCredential: { secrets[$1] = $0 }, deleteCredential: { secrets.removeValue(forKey: $0) }
                )
                .modelContainer(container).preferredColorScheme(scheme))
            settle()
            try capture("vpn-\(scheme)")
            precondition(
                nodes(window).contains(where: {
                    attribute($0, "accessibilityLabel") as? String == "Name"
                        && attribute($0, "accessibilityValue") as? String == "Synthetic VPN"
                }), "First profile is selected and loaded")
            precondition(!enabled("Save"), "Unchanged profile cannot save")
            precondition(enabled("Delete"))
            precondition(!labels().contains("MTU"), "Advanced fields start collapsed")
            try capture("vpn-\(scheme)")
            focus("Name")
            setText("Name", "Edited VPN")
            precondition(enabled("Save"))
            try capture("vpn-focused-\(scheme)")
            press("Done")
            precondition(labels().contains("Save changes to this VPN profile?"))
            press("Cancel")
            precondition(
                !labels().contains("Save changes to this VPN profile?"), "Cancel keeps edits and dismisses the alert")
            press("Revert")
            precondition(!enabled("Save"))
            press("Show Private key *")
            precondition(labels().contains("Hide Private key *"))
            press("Clear Private key *")
            press("Save")
            precondition(labels().contains("Enter a valid 44-character key."))
            press("Revert")
            precondition(labels().contains("Show Private key *"), "Revert masks secrets again")
            focus("Name")
            setText("Name", "Saved VPN")
            press("Save")
            precondition(profile.name == "Saved VPN")
            precondition(!enabled("Save"))
            press("New")
            precondition(
                nodes(window).contains(where: {
                    attribute($0, "accessibilityLabel") as? String == "Name"
                        && attribute($0, "accessibilityValue") as? String == "Untitled VPN"
                }))
            try capture("vpn-new-\(scheme)")
            press("Revert")
            // Restore the synthetic name for the next appearance.
            profile.name = "Synthetic VPN"
            try container.mainContext.save()
            print("PASS VPN selection, dirty/Cancel/Revert/Save, secure fields and validation in \(scheme)")
        }
        var openVPN = WireGuardConfiguration()
        openVPN.openVPN = true
        let imported = try SavedWireGuard(name: "A Synthetic OpenVPN", configuration: openVPN)
        container.mainContext.insert(imported)
        try container.mainContext.save()
        secrets[imported.id] = ConnectionCredential(
            password: "synthetic",
            openVPNProfile:
                "client\ndev tun\nproto tcp-client\nremote vpn.example.invalid 443\nauth-user-pass\n<ca>\nsynthetic\n</ca>\n",
            openVPNUsername: "synthetic")
        for scheme in [ColorScheme.light, .dark] {
            window.setContentSize(NSSize(width: 820, height: 740))
            window.contentView = NSHostingView(
                rootView: WireGuardLibrary(
                    loadCredential: { secrets[$0] },
                    saveCredential: { secrets[$1] = $0 }, deleteCredential: { secrets.removeValue(forKey: $0) }
                )
                .modelContainer(container).preferredColorScheme(scheme))
            settle()
            precondition(labels().contains("TCP · 443 · vpn.example.invalid"))
            precondition(labels().contains("Saved OpenVPN configuration"))
            try capture("openvpn-\(scheme)")
            let settings = NSHostingView(
                rootView: AppSettings().defaultAppStorage(defaults).preferredColorScheme(scheme))
            window.contentView = settings
            settle()
            window.setContentSize(settings.fittingSize)
            settle()
            for title in ["General", "Terminal", "Security", "About"] { precondition(labels().contains(title)) }
            try capture("settings-\(scheme)")
        }
        for scheme in [ColorScheme.light, .dark] {
            let raw = "client\ndev tun\nremote example.invalid 1194\nca ca.crt\ncert client.crt\nkey client.key\n"
            var document = try OpenVPNImportDocument(data: Data(raw.utf8))
            window.setContentSize(NSSize(width: 560, height: 460))
            window.contentView = NSHostingView(
                rootView: OpenVPNImportReview(
                    document: document, filename: "Synthetic configuration.conf", onImport: { _ in }
                ).preferredColorScheme(scheme))
            settle()
            precondition(labels().contains("Choose CA certificate"))
            precondition(labels().contains("Choose Private key"))
            precondition(!enabled("Import"))
            try capture("openvpn-companions-\(scheme)")
            document.files = [
                .ca: Data("synthetic CA".utf8), .cert: Data("synthetic certificate".utf8),
                .key: Data("synthetic key".utf8),
            ]
            var accepted = false
            window.contentView = NSHostingView(
                rootView: OpenVPNImportReview(
                    document: document, filename: "Synthetic bundle.zip", onImport: { _ in accepted = true }
                ).preferredColorScheme(scheme))
            settle()
            precondition(enabled("Import"))
            try capture("openvpn-bundle-\(scheme)")
            press("Import")
            precondition(accepted)
            document.isTAP = true
            window.contentView = NSHostingView(
                rootView: OpenVPNImportReview(
                    document: document, filename: "Synthetic TAP bundle.zip",
                    onImport: { _ in preconditionFailure("TAP must be refused") }
                ).preferredColorScheme(scheme))
            settle()
            precondition(!enabled("Import"))
            try capture("openvpn-tap-\(scheme)")
        }
        print("PASS OpenVPN bundle review, explicit companion selection and actionable TAP refusal in both appearances")
        print("PASS saved OpenVPN import summary and grouped Settings in both appearances")
    }
}
