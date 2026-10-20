import AppKit

@MainActor private final class MenuProbe {
    var opened = false, stayedExpanded = false
    var menu: NSMenu?
}

@main @MainActor struct HubHoverWindowChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fputs("Pass a new output directory for owned-window evidence.\n", stderr); exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        NSApplication.shared.setActivationPolicy(.accessory)
        let screens = CompanionHubScreen.current(), realPointer = NSEvent.mouseLocation
        var evidence: [[String: Any]] = []
        func wait(_ condition: () -> Bool) {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !condition() {
                precondition(ProcessInfo.processInfo.systemUptime < deadline, "owned window reached its expected state")
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        for (index, screen) in screens.enumerated() {
            var point = CGPoint(x: screen.frame.midX, y: screen.frame.midY), time = 0.0
            let options = CompanionHubPreferences(reduceMotion: false, reduceTransparency: false, displayID: screen.id)
            let hub = CompanionHubController(screens: { screens }, preferences: { options }, pointer: { point }, clock: { time })
            hub.onAsk = {}
            hub.apply(["connected": true, "sessions": [["id": "owned-hover", "name": "Owned hover check", "status": "idle"]]])
            precondition(!NSApp.windows.contains { $0.title == "Andy Hub" && $0.isVisible }, "idle creates no visible hub")
            let layout = CompanionHubGeometry.layout(screens: screens, expanded: false, contentHeight: 44, preferredScreenID: screen.id)!
            point = CGPoint(x: layout.trigger.midX, y: layout.trigger.midY); hub.pollHover(); time = 0.13; hub.pollHover()
            func labelFixture() {
                let button = hub.contentView.subviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "hub.toggle" }!
                button.attributedTitle = NSAttributedString(string: "Owned hover test", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13)])
            }
            labelFixture()
            let window = NSApp.windows.first { $0.title == "Andy Hub" && $0.isVisible }!
            wait { window.alphaValue > 0.99 && abs(window.frame.minY - layout.frame.minY) < 0.1 }
            precondition(!window.isKeyWindow && hub.phase == .hover, "real hover windows never take keyboard focus")
            precondition(abs(window.frame.midX - layout.frame.midX) < 0.1 && window.frame.maxY <= screen.visibleFrame.maxY, "real windows use the selected display's safe frame")
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", root.appendingPathComponent("hover-\(index).png").path]
            try capture.run(); capture.waitUntilExit(); precondition(capture.terminationStatus == 0, "owned window capture succeeded")
            point = CGPoint(x: screen.frame.minX + 20, y: screen.frame.midY); time += 0.01; hub.pollHover(); time += 0.23; hub.pollHover()
            precondition(hub.phase == .hidden, "exit hides the preview")
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            point = CGPoint(x: layout.trigger.midX, y: layout.trigger.midY); hub.pollHover(); time += 0.13; hub.pollHover(); labelFixture()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            precondition(window.isVisible && window.alphaValue > 0.99, "a stale exit animation cannot hide a new hover")
            hub.contentView.cancelOperation(nil); wait { !window.isVisible }
            time += 1; hub.pollHover(); precondition(!window.isVisible, "Escape waits for a new entry")
            let menu = hub.makeMenuItem().submenu!, open = menu.items.first { $0.identifier?.rawValue == "hub.expand" }!
            menu.performActionForItem(at: menu.index(of: open)); precondition(hub.expanded, "the real menu explicitly opens controls")
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            let picker = descendants(hub.contentView).compactMap { $0 as? NSPopUpButton }.first!
            let probe = MenuProbe()
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { probe.opened = true; probe.stayedExpanded = hub.expanded; probe.menu = note.object as? NSMenu }
            }
            let cancel = Timer(timeInterval: 0.15, repeats: false) { _ in MainActor.assumeIsolated { probe.menu?.cancelTrackingWithoutAnimation() } }
            RunLoop.main.add(cancel, forMode: .common)
            picker.performClick(nil); cancel.invalidate(); NotificationCenter.default.removeObserver(observer)
            precondition(probe.opened && probe.stayedExpanded && hub.expanded, "opening the real Display picker does not collapse its parent")
            window.resignKey(); wait { !window.isVisible }
            precondition(hub.phase == .hidden, "loss of keyboard focus hides expanded controls")
            evidence.append(["screen": screen.name, "notched": layout.notched, "trigger": NSStringFromRect(layout.trigger), "frame": NSStringFromRect(layout.frame), "hoverNoFocus": true, "interruptedExit": true, "escapeHidden": true, "outsideFocusHidden": true])
            hub.close()
        }
        let report: [String: Any] = ["simulation": true, "syntheticPointer": true, "screens": evidence, "realPointerUnchanged": NSEvent.mouseLocation == realPointer]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print("PASS real hover windows, geometry, animation interruption, and hide on \(screens.count) displays; synthetic pointer input")
    }
}
