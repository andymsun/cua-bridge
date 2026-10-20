import AppKit
import ApplicationServices

// Run only as the generated .app through LaunchServices. A bare executable has no
// NSRunningApplication.launchDate on this host and is not a valid identity fixture.
final class LookupFixtureState {
    let path: String
    let mode: String
    var windows: [String: NSWindow] = [:]
    var actions = 0
    var inputEvents = 0
    var secureValueReads = 0
    init() {
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        path = argument("--state-file") ?? ""
        mode = argument("--mode") ?? "basic"
    }
    func save() {
        guard !path.isEmpty else { return }
        let app = NSRunningApplication.current
        let identity = app.launchDate.map { "\(app.processIdentifier):\($0.timeIntervalSince1970)" }
        let point = CGEvent(source: nil)?.location ?? .zero
        let payload: [String: Any] = ["pid": Int(app.processIdentifier), "process": identity as Any? ?? NSNull(),
            "mode": mode, "windows": windows.mapValues { $0.windowNumber }, "actions": actions,
            "inputEvents": inputEvents, "secureValueReads": secureValueReads,
            "frontmostPid": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),
            "pointer": ["x": Double(point.x), "y": Double(point.y)], "ready": !windows.isEmpty && identity != nil]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
let fixtureState = LookupFixtureState()
final class LookupSecureFixtureField: NSSecureTextField {
    override func accessibilityValue() -> String? {
        fixtureState.secureValueReads += 1
        return super.accessibilityValue()
    }
}
final class LookupSlowFixtureButton: NSButton {
    override func accessibilityTitle() -> String? {
        Thread.sleep(forTimeInterval: 0.4)
        return super.accessibilityTitle()
    }
}
final class LookupFlippedView: NSView { override var isFlipped: Bool { true } }

final class LookupFixtureDelegate: NSObject, NSApplicationDelegate {
    var monitor: Any?
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !fixtureState.path.isEmpty else { NSApp.terminate(nil); return }
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = NSWindow(contentRect: CGRect(x: visible.minX + 80, y: visible.minY + 80, width: 700, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Native Exact Lookup Fixture"
        window.isReleasedWhenClosed = false
        fixtureState.windows["primary"] = window
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        window.contentView = content
        func button(_ title: String, _ x: CGFloat, _ y: CGFloat, into parent: NSView? = nil) -> NSButton {
            let button = NSButton(title: title, target: self, action: #selector(pressed))
            button.frame = CGRect(x: x, y: y, width: 150, height: 32)
            (parent ?? content).addSubview(button)
            return button
        }
        _ = button("Save", 30, 420)
        _ = button("Repeat", 30, 360)
        _ = button("Repeat", 230, 360)
        _ = button("Shared", 30, 300)
        let check = NSButton(checkboxWithTitle: "Shared", target: self, action: #selector(pressed))
        check.frame = CGRect(x: 230, y: 300, width: 150, height: 32); content.addSubview(check)
        let disabled = button("Disabled", 30, 240); disabled.isEnabled = false
        let hidden = button("Hidden", 230, 240); hidden.isHidden = true
        _ = button("Offscreen", -300, 50)
        let secure = LookupSecureFixtureField(frame: CGRect(x: 30, y: 180, width: 180, height: 30))
        secure.setAccessibilityLabel("Secret")
        secure.stringValue = "never-read-this-value"
        content.addSubview(secure)
        let scroll = NSScrollView(frame: CGRect(x: 470, y: 40, width: 180, height: 160))
        let document = LookupFlippedView(frame: CGRect(x: 0, y: 0, width: 160, height: 700))
        scroll.documentView = document; scroll.hasVerticalScroller = true; content.addSubview(scroll)
        _ = button("Clipped", 0, 500, into: document)

        switch fixtureState.mode {
        case "sibling": _ = button("Cover", 60, 420)
        case "long-name": _ = button(String(repeating: "L", count: 513), 400, 420)
        case "large-tree":
            for n in 0..<2200 { _ = button("Item \(n)", 400, 230, into: content) }
        case "deep-tree":
            var parent = content
            for _ in 0..<55 {
                let group = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
                group.setAccessibilityElement(true); group.setAccessibilityRole(.group)
                parent.addSubview(group); parent = group
            }
            _ = button("Deep", 30, 100, into: parent)
        case "slow":
            let slow = LookupSlowFixtureButton(title: "Slow", target: self, action: #selector(pressed))
            slow.frame = CGRect(x: 400, y: 420, width: 150, height: 32); content.addSubview(slow)
        default: break
        }
        window.makeKeyAndOrderFront(nil)
        if fixtureState.mode == "multi-window" {
            let second = NSWindow(contentRect: CGRect(x: visible.minX + 800, y: visible.minY + 80, width: 180, height: 180),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            second.title = "Second Lookup Window"; second.isReleasedWhenClosed = false
            fixtureState.windows["second"] = second; second.orderFront(nil)
        }
        if fixtureState.mode == "occluded" {
            let cover = NSWindow(contentRect: window.convertToScreen(CGRect(x: 40, y: 425, width: 80, height: 20)),
                                 styleMask: .borderless, backing: .buffered, defer: false)
            cover.backgroundColor = .white; cover.isReleasedWhenClosed = false
            fixtureState.windows["cover"] = cover; cover.orderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            fixtureState.inputEvents += 1
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            fixtureState.save()
            if FileManager.default.fileExists(atPath: fixtureState.path + ".stop") { NSApp.terminate(nil) }
        }
        // Even if the test client fails, this fixture does not stay running indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { NSApp.terminate(nil) }
        fixtureState.save()
    }
    @objc func pressed() { fixtureState.actions += 1; fixtureState.save() }
}
let fixtureApp = NSApplication.shared
let fixtureDelegate = LookupFixtureDelegate()
fixtureApp.setActivationPolicy(fixtureState.mode == "accessory" ? .accessory : .regular)
fixtureApp.delegate = fixtureDelegate
fixtureApp.run()
