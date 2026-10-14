import AppKit
import ApplicationServices
import SwiftData
import SwiftUI

@MainActor private final class TunnelFormFixture: ObservableObject {
    @Published var rules = [SSHForwardingRule.newRule()]
    @Published var unavailable = false
    @Published var visibleIssues: Set<UUID> = []
    @Published var visited: [UUID: Set<SSHForwardingField>] = [:]
    @Published var submitted = false
}

private struct TunnelFormHost: View {
    @ObservedObject var fixture: TunnelFormFixture
    var body: some View {
        VStack {
            ScrollView {
                SSHForwardingEditor(
                    rules: $fixture.rules, unavailable: $fixture.unavailable,
                    server: "fixture.invalid", submitted: fixture.submitted,
                    visibleIssues: $fixture.visibleIssues, visitedFields: $fixture.visited)
            }
            Button("Validate") { fixture.submitted = true }
        }.padding(24).frame(width: 540, height: 600).buttonStyle(.bordered)
    }
}

/// Owned windows, in-memory profiles and fake credentials only. No user app state or clipboard.
@main struct ConnectionUIReviewChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            do {
                try runChecks()
                exit(0)
            } catch {
                print("Synthetic UI checks failed: \(error)")
                exit(1)
            }
        }
        app.run()
    }
    @MainActor static func runChecks() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let suite = "com.peterpo.farcast.ui-review-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(loadCredential: { _ in nil }, defaults: defaults)
        let container = try ModelContainer(
            for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        workspace.modelContext = container.mainContext
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Farcast synthetic UI checks"
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        defer { window.close() }
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
            guard let node = object as? NSObject else { return [] }
            return [node] + ((attribute(node, "accessibilityChildren") as? [Any]) ?? []).flatMap { nodes($0) }
        }
        let accessibilityApp = AXUIElementCreateApplication(getpid())
        AXUIElementSetAttributeValue(accessibilityApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(accessibilityApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        func labels() -> [String] {
            nodes(window).compactMap {
                attribute($0, "accessibilityLabel") as? String ?? attribute($0, "accessibilityValue") as? String
            }
        }
        func press(_ label: String) {
            guard let button = nodes(window).first(where: { attribute($0, "accessibilityLabel") as? String == label })
            else {
                print("Synthetic AX labels: \(labels())")
                fflush(stdout)
                preconditionFailure("Missing synthetic control: \(label)")
            }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            precondition(button.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let perform = unsafeBitCast(button.method(for: selector), to: Press.self)
            precondition(perform(button, selector), "Control could not be activated")
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
        func snapshot(_ name: String) throws {
            guard CommandLine.arguments.count > 1,
                ProcessInfo.processInfo.environment["FARCAST_UI_REVIEW"] == "1"
            else { return }
            if let scene = ProcessInfo.processInfo.environment["FARCAST_UI_REVIEW_SCENE"], scene != name { return }
            print("REVIEW \(name) | \(Bundle.main.bundlePath)")
            fflush(stdout)
            let marker = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("continue")
            let deadline = Date().addingTimeInterval(120)
            while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            try? FileManager.default.removeItem(at: marker)
        }
        for scheme in [ColorScheme.light, .dark] {
            window.contentView = NSHostingView(
                rootView: ConnectionEditor(
                    workspace: workspace,
                    request: EditorRequest(draft: ConnectionDraft(), mode: .create), loadCredential: { _ in nil }
                )
                .modelContainer(container).preferredColorScheme(scheme))
            settle()
            precondition(
                !labels().contains {
                    $0.contains("Enter a host") || $0.contains("invalid settings") || $0.contains("issue in")
                        || $0.contains("issues in")
                })
            try snapshot("new-connection-\(scheme)")
            if scheme == .light {
                focus("Address")
                focus("Port")
                precondition(
                    labels().contains { $0.contains("Enter a host name") }, "Skipping Address must reveal validation")
            }
            press("Save")
            precondition(labels().contains { $0.contains("Enter a host name") })
            precondition(labels().contains { $0.contains("in General") })
            setText("Address", "ssh://fixture.invalid")
            press("Save")
            let name = nodes(window).first {
                attribute($0, "accessibilityLabel") as? String == "Name"
                    && attribute($0, "accessibilityRole") as? String == "AXTextField"
            }!
            precondition(
                (attribute(name, "accessibilityValue") as? String ?? "").isEmpty,
                "An invalid Save must not fill the default connection name")
            try snapshot("connection-validation-\(scheme)")
        }
        print(
            "PASS new connection opens quietly; skipping Address or Save reveals inline hostname validation in light/dark"
        )
        window.contentView = NSHostingView(
            rootView: ConnectionEditor(
                workspace: workspace,
                request: EditorRequest(draft: ConnectionDraft(), mode: .quick), loadCredential: { _ in nil }
            )
            .modelContainer(container).preferredColorScheme(.dark))
        settle()
        precondition(!labels().contains { $0.contains("Enter a host") || $0.contains("invalid settings") })
        setText("Quick address", "rdp://fixture-user@fixture.invalid:22")
        press("Use")
        let port = nodes(window).first {
            attribute($0, "accessibilityLabel") as? String == "Port"
                && attribute($0, "accessibilityRole") as? String == "AXTextField"
        }!
        precondition(
            String(describing: attribute(port, "accessibilityValue")!) == "22",
            "Quick address must preserve an explicit port across protocol changes")
        let address = nodes(window).first {
            attribute($0, "accessibilityLabel") as? String == "Address"
                && attribute($0, "accessibilityRole") as? String == "AXTextField"
        }!
        precondition(attribute(address, "accessibilityValue") as? String == "fixture.invalid")
        print("PASS Quick Connect opens quietly and URL Use preserves explicit nonstandard protocol ports")
        for scheme in [ColorScheme.light, .dark] {
            let fixture = TunnelFormFixture()
            window.contentView = NSHostingView(rootView: TunnelFormHost(fixture: fixture).preferredColorScheme(scheme))
            settle()
            precondition(fixture.visibleIssues.isEmpty)
            precondition(
                !labels().contains {
                    $0.contains("Enter a tunnel destination") || $0.contains("Enter a destination port")
                })
            try snapshot("new-tunnel-\(scheme)")
            press("Validate")
            precondition(fixture.visibleIssues.count == 1)
            precondition(labels().filter { $0.contains("Enter a destination port") }.count == 1)
            fixture.rules[0].kind = .socks
            settle()
            precondition(fixture.visibleIssues.isEmpty)
            try snapshot("socks-editor-\(scheme)")
        }
        print(
            "PASS fresh tunnel placeholders defer validation; inline errors occur once; SOCKS hides irrelevant fields")
        var longDraft = ConnectionDraft()
        longDraft.host = "fixture.invalid"
        longDraft.username = "fixture"
        longDraft.forwardingRules = (0..<15).map { _ in SSHForwardingRule(kind: .socks) } + [.newRule()]
        window.contentView = NSHostingView(
            rootView: ConnectionEditor(
                workspace: workspace,
                request: EditorRequest(draft: longDraft, mode: .edit), loadCredential: { _ in nil }
            )
            .modelContainer(container).preferredColorScheme(.dark))
        settle()
        press("Save")
        let destination = nodes(window).first { attribute($0, "accessibilityLabel") as? String == "Destination host" }!
        let selector = NSSelectorFromString("accessibilityFrame")
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        let rectangle = unsafeBitCast(destination.method(for: selector), to: Frame.self)(destination, selector)
        try snapshot("long-tunnel-validation")
        precondition(
            rectangle.height > 0 && rectangle.minY >= window.frame.minY && rectangle.maxY <= window.frame.maxY,
            "Validation must reveal the invalid field in a long tunnel list")
        print("PASS validation scrolls to the invalid tunnel in a 16-rule editor")
        window.setContentSize(NSSize(width: 1280, height: 700))
        let empty = SSHForwardingController(rules: [])
        window.contentView = NSHostingView(
            rootView: SSHForwardingView(controller: empty, connected: true)
                .modelContainer(container).preferredColorScheme(.dark))
        settle()
        try snapshot("live-tunnels-empty")
        let populated = SSHForwardingController(rules: [
            SSHForwardingRule(kind: .socks), SSHForwardingRule(destinationPort: 80),
        ])
        window.contentView = NSHostingView(
            rootView: SSHForwardingView(controller: populated, connected: true, server: "fixture.invalid")
                .modelContainer(container).preferredColorScheme(.dark))
        settle()
        try snapshot("live-tunnels-cards")
        print("PASS native empty/populated tunnel hosts render in wide owned windows")
    }
}
