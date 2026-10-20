import AppKit

// Compile with hud/CompanionHub.swift. No NSWindow is created or ordered in this test.
@MainActor private final class HubSurfaceRecorder: CompanionHubSurface {
    var frames: [CGRect] = [], animations: [Bool] = []
    var focusRequests = 0, releases = 0, hides = 0, closes = 0
    func display(frame: CGRect, animate: Bool) { frames.append(frame); animations.append(animate) }
    func focus(_ view: NSView) { focusRequests += 1 }
    func endInteraction() { releases += 1 }
    func hide() { hides += 1 }
    func close() { closes += 1 }
}

@main @MainActor struct CompanionHubChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fputs("FAIL \(message)\n", stderr); exit(1) }
    }

    static let laptop = CompanionHubScreen(
        id: "laptop", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1243),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1205.5), safeTop: 37.5,
        auxiliaryLeft: CGRect(x: -1920, y: 1205.5, width: 856, height: 37.5),
        auxiliaryRight: CGRect(x: -856, y: 1205.5, width: 856, height: 37.5))
    static let external = CompanionHubScreen(
        id: "external", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 40, width: 2560, height: 1376), safeTop: 0, isMain: true)

    static func geometry() {
        let automatic = CompanionHubGeometry.layout(screens: [external, laptop], expanded: false, contentHeight: 350)!
        check(automatic.screenID == "external", "the automatic hub uses the main monitor instead of forcing the laptop notch")
        let compact = CompanionHubGeometry.layout(screens: [external, laptop], expanded: false, contentHeight: 350, preferredScreenID: "laptop")!
        check(compact.screenID == "laptop" && compact.notched, "an explicit laptop choice uses the real notch")
        check(compact.frame.midX == -960, "derive the camera center on a negative-origin display")
        check(compact.frame.maxY == 1199.5, "preserve fractional safe top and leave a gap below exclusion")
        check(compact.frame.maxY < 1205.5, "all controls lie below menu and camera")
        let expanded = CompanionHubGeometry.layout(screens: [external, laptop], expanded: true, contentHeight: 380, preferredScreenID: "laptop")!
        check(expanded.frame.maxY == compact.frame.maxY && expanded.frame.minY < compact.frame.minY, "expansion goes downward")
        check(laptop.visibleFrame.contains(expanded.frame), "expanded hub remains in visible bounds")

        let asymmetric = CompanionHubScreen(id: "asymmetric", frame: CGRect(x: -1500.25, y: -600.5, width: 1300.5, height: 900.25),
            visibleFrame: CGRect(x: -1500.25, y: -580.5, width: 1300.5, height: 850.25), safeTop: 30,
            auxiliaryLeft: CGRect(x: -1500.25, y: 269.75, width: 400.25, height: 30),
            auxiliaryRight: CGRect(x: -920, y: 269.75, width: 720.25, height: 30))
        let shifted = CompanionHubGeometry.layout(screens: [asymmetric], expanded: true, contentHeight: 250)!
        check(shifted.frame.midX == -1010, "auxiliary area edges determine the center, not a hardcoded notch width")
        check(shifted.frame.maxY == 263.75, "fractional displays below the main display stay below safe top")

        let menu = CompanionHubScreen(id: "menu", frame: laptop.frame,
            visibleFrame: CGRect(x: -1920, y: 60, width: 1920, height: 1120), safeTop: 37.5,
            auxiliaryLeft: laptop.auxiliaryLeft, auxiliaryRight: laptop.auxiliaryRight)
        let menuLayout = CompanionHubGeometry.layout(screens: [menu], expanded: true, contentHeight: 5000)!
        check(menuLayout.frame.maxY == 1174, "a lower visibleFrame wins over safeAreaInsets")
        check(menu.visibleFrame.contains(menuLayout.frame), "large contents scroll instead of leaving the display")
        let fallback = CompanionHubGeometry.layout(screens: [external], expanded: false, contentHeight: 0)!
        check(!fallback.notched && fallback.frame.midX == 1280 && fallback.frame.maxY == 1410, "safe capsule on a non-notched display")
        check(CompanionHubGeometry.layout(screens: [], expanded: false, contentHeight: 0) == nil, "no screens means no overlay")
        for bad in [CGRect.zero, CGRect(x: 0, y: 0, width: 100, height: 30), CGRect(x: CGFloat.nan, y: 0, width: 500, height: 500)] {
            let screen = CompanionHubScreen(id: "bad", frame: bad, visibleFrame: bad, safeTop: 0)
            check(CompanionHubGeometry.layout(screens: [screen], expanded: false, contentHeight: 0) == nil, "invalid or tiny displays use the menu fallback")
        }
        let unsafe = CompanionHubScreen(id: "unsafe", frame: external.frame, visibleFrame: external.visibleFrame, safeTop: .nan)
        check(CompanionHubGeometry.layout(screens: [unsafe], expanded: false, contentHeight: 0) == nil, "invalid safe geometry fails closed")
    }

    static func client(_ id: String = "client-1", capabilities: [String: Any] = ["observe": true, "openHost": true]) -> [String: Any] {
        ["id": id, "name": "Terminal client", "status": "busy", "source": "mcp", "stale": false,
         "host": ["ancestors": [123, 456], "bundleId": "com.apple.Terminal"], "capabilities": capabilities,
         "client": ["name": "Codex", "version": "1"], "updatedAt": 1234]
    }

    static func payload() -> [String: Any] {
        ["connected": true, "activeSessionID": "session-1", "sessions": [
            ["id": "session-1", "name": "Planning", "status": "thinking", "needsApproval": false],
            ["id": "session-2", "name": "Review", "status": "idle", "needsApproval": true],
            ["id": "session-3", "name": "Finished", "status": "done", "needsApproval": false]],
         "hub": ["clients": [client()], "providers": [
            ["id": "codex", "name": "Codex", "available": true, "capabilities": ["attach": true, "send": true, "openHost": true]],
            ["id": "cursor", "name": "Cursor", "available": false]]]]
    }

    static func validation() {
        let clean = CompanionHubState(payload())
        check(clean.connected && clean.activeSessionID == "session-1", "accept the frozen hubState shape")
        check(clean.sessions.count == 3 && clean.clients.count == 1 && clean.providers.count == 2, "decode only supported metadata")
        check(clean.clients.first?.canOpenHost == true, "registered current host with openHost capability is eligible")
        var secrets = payload()
        secrets["token"] = "SECRET"; secrets["draft"] = "SECRET"; secrets["messages"] = [["text": "SECRET"]]
        var sessions = secrets["sessions"] as! [[String: Any]]
        sessions[0]["messages"] = [["text": "SECRET"]]; sessions[0]["key"] = "SECRET"
        secrets["sessions"] = sessions
        check(CompanionHubState(secrets) == clean, "token, draft, conversation and tool keys are not retained")

        let malformed = CompanionHubState(["connected": "true", "activeSessionID": "missing", "sessions": [
            ["id": "valid-id", "name": "A\nB\u{202e}C", "status": "SECRET", "needsApproval": "true"],
            ["id": "valid-id", "name": "duplicate", "status": "thinking"],
            ["id": "bad/id", "name": "bad"], ["id": "bad\n", "name": "bad"],
            ["id": String(repeating: "x", count: 129), "name": "bad"], ["id": 17, "name": "bad"]]])
        check(!malformed.connected && malformed.activeSessionID == nil, "connection booleans and active identity are validated")
        check(malformed.sessions.count == 1, "reject duplicate, malformed, and unbounded IDs")
        check(malformed.sessions[0].status == "unknown" && !malformed.sessions[0].needsApproval, "unknown state and string booleans fail closed")
        check(!malformed.sessions[0].name.contains("\n") && !malformed.sessions[0].name.contains("\u{202e}"), "strip controls and bidi overrides from labels")
        check(!CompanionHubState(["connected": 1]).connected, "numeric booleans cannot grant capabilities")
        let large = CompanionHubState(["sessions": (0..<1000).map { ["id": "s\($0)", "name": String(repeating: "x", count: 1000)] },
            "hub": ["clients": (0..<1000).map { client("c\($0)") }, "providers": (0..<1000).map { ["id": "p\($0)", "name": "Provider"] }]])
        check(large.sessions.count <= 32 && large.clients.count <= 32 && large.providers.count <= 16, "all row collections are bounded")
        check(large.sessions.allSatisfy { $0.name.count <= 80 }, "labels have a finite display bound")
        check(CompanionHubState([:]).sessions.isEmpty, "absent optional hub metadata works")
        for count in [17, 32, 33] {
            let row = client().merging(["host": ["ancestors": Array(1000..<(1000 + count)), "bundleId": "com.apple.Terminal"]]) { _, next in next }
            let state = CompanionHubState(["hub": ["clients": [row]]])
            check(state.clients.first?.canOpenHost == (count <= 32), "host ancestry uses the same 32-entry contract as the producer and resolver")
        }

        for changes: [String: Any] in [
            ["capabilities": ["openHost": false]], ["capabilities": ["openHost": "true"]],
            ["capabilities": ["openHost": 1]], ["host": NSNull()], ["stale": true], ["status": "exited"],
            ["status": "unknown"], ["host": ["ancestors": [-1], "bundleId": "com.apple.Terminal"]],
            ["host": ["ancestors": [true], "bundleId": "com.apple.Terminal"]],
            ["host": ["ancestors": [1.5], "bundleId": "com.apple.Terminal"]],
            ["host": ["ancestors": [123], "bundleId": "bad/path"]], ["source": "inventory"]
        ] {
            let row = client().merging(changes) { _, next in next }
            let state = CompanionHubState(["hub": ["clients": [row]]])
            check(state.clients.first?.canOpenHost != true, "invalid, stale, or unauthorized hosts cannot be focused")
        }
    }

    static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
    static func button(_ root: NSView, _ id: String) -> NSButton? {
        allViews(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }
    }
    static func menuItem(_ menu: NSMenu, _ id: String) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == id { return item }
            if let submenu = item.submenu, let found = menuItem(submenu, id) { return found }
        }
        return nil
    }
    static func pressMenu(_ item: NSMenuItem) {
        guard let menu = item.menu else { check(false, "menu item is attached"); return }
        menu.performActionForItem(at: menu.index(of: item))
    }

    static func controller() {
        let surface = HubSurfaceRecorder(), notifications = NotificationCenter(), workspace = NotificationCenter()
        var screens = [external, laptop], screenReads = 0, preferences = CompanionHubPreferences(reduceMotion: true, reduceTransparency: true, displayID: "laptop")
        var factories = 0, events: [String] = []
        let hub = CompanionHubController(screens: { screenReads += 1; return screens }, preferences: { preferences },
            notificationCenter: notifications, workspaceNotifications: workspace, makeSurface: { _ in factories += 1; return surface })
        hub.onAsk = { events.append("ask") }
        hub.onOpenSession = { events.append("open:\($0)") }
        hub.onStopSession = { events.append("stop:\($0)") }
        hub.onOpenHost = { events.append("host:\($0)") }
        let menu = hub.makeMenuItem().submenu!
        check(factories == 0 && surface.focusRequests == 0, "initialization and menu fallback do not create or focus windows")
        hub.apply(payload())
        check(factories == 1 && !hub.expanded && events.isEmpty, "passive payload only displays compact status")
        check(surface.focusRequests == 0 && surface.animations.allSatisfy { !$0 }, "passive display never takes key focus or animates")
        check(surface.frames.last!.maxY < 1205.5, "the real controller uses safe geometry")
        let root = hub.contentView
        let toggle = button(root, "hub.toggle")!
        // AppKit exposes AXUnknown on a detached control; its native cell exposes AXButton.
        check(toggle.cell?.accessibilityRole() == .button && !(toggle.accessibilityLabel() ?? "").isEmpty, "native toggle has a named button role")
        check(!toggle.isAccessibilityExpanded(), "collapsed state is exposed to accessibility")
        toggle.performClick(nil)
        check(hub.expanded && surface.focusRequests == 1, "explicit expansion alone requests keyboard access")
        check(toggle.isAccessibilityExpanded() && surface.frames.last!.height > 44, "expanded state is exposed and grows downward")
        check(surface.animations.last == false, "Reduce Motion suppresses expansion animation")
        check(allViews(root).compactMap { $0 as? NSVisualEffectView }.allSatisfy(\.isHidden), "Reduce Transparency removes background blur")
        for control in allViews(root).compactMap({ $0 as? NSButton }).filter({ !$0.isHidden }) {
            check(!(control.accessibilityLabel() ?? "").isEmpty, "every button announces its action")
            check(control.frame.width >= 24 && control.frame.height >= 24, "native actions retain usable hit targets")
            check(control.focusRingType != .none, "native keyboard focus indicators are retained")
        }
        check(button(root, "hub.session.stop.session-3")?.isHidden != false, "completed sessions do not offer stop")
        let hostControl = button(root, "hub.client.open.client-1")!
        check(hostControl.title.contains("Open host") && (hostControl.accessibilityLabel() ?? "").contains("host"), "connected-client actions explicitly offer host focus, not conversation attachment")
        check(toggle.nextKeyView === button(root, "hub.ask") && toggle.nextKeyView?.nextKeyView === button(root, "hub.display") && button(root, "hub.display")?.nextKeyView === button(root, "hub.session.open.session-1"), "keyboard order includes the display choice before sessions")
        let open = button(root, "hub.session.open.session-1")!
        open.performClick(nil)
        check(events == ["open:session-1"], "selecting a session never submits a prompt")
        toggle.performClick(nil)
        button(root, "hub.session.stop.session-1")!.performClick(nil)
        button(root, "hub.session.stop.session-2")!.performClick(nil)
        button(root, "hub.client.open.client-1")!.performClick(nil)
        check(events == ["open:session-1", "stop:session-1", "stop:session-2", "host:client-1"], "callbacks carry only exact eligible session/client IDs")
        let providerViews = allViews(root).filter { $0.identifier?.rawValue.hasPrefix("hub.provider.") == true }
        check(!providerViews.isEmpty && providerViews.allSatisfy { !($0 is NSButton) }, "provider inventory is information-only")
        let labels = allViews(root).compactMap { ($0 as? NSTextField)?.stringValue }
        check(labels.contains(where: { $0.contains("Not attached") }), "installed provider rows explicitly say Not attached")
        check(labels.contains(where: { $0.contains("CUA activity") }), "client transport state is not mislabeled as conversation attachment")

        let focusBefore = surface.focusRequests
        hub.apply(payload()); hub.reflow()
        check(surface.focusRequests == focusBefore, "apply and reflow never restore or steal focus")
        check(button(root, "hub.session.open.session-1") === open, "ordinary state refresh preserves native control identity")
        let readsBefore = screenReads
        screens = [external]
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        check(screenReads > readsBefore && surface.frames.last!.minX > 0 && surface.frames.last!.maxY < 1416, "display changes fetch fresh geometry and migrate to a safe capsule")
        check(surface.focusRequests == focusBefore, "display migration is passive")
        preferences = CompanionHubPreferences(reduceMotion: false, reduceTransparency: false)
        workspace.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        check(allViews(root).compactMap { $0 as? NSVisualEffectView }.contains(where: { !$0.isHidden }), "accessibility preference changes are applied live")
        check(root.layer?.backgroundColor?.alpha == 1, "hub text always has an opaque base behind its material")

        let staleStop = button(root, "hub.session.stop.session-1")!
        let staleHost = button(root, "hub.client.open.client-1")!
        let staleMenuStop = menuItem(menu, "hub.session.stop.session-1")!
        var disconnected = payload(); disconnected["connected"] = false
        hub.apply(disconnected)
        let oldEvents = events
        staleStop.performClick(nil); staleHost.performClick(nil)
        _ = staleMenuStop.target?.perform(staleMenuStop.action, with: staleMenuStop)
        check(events == oldEvents, "stale native and menu actions revalidate the current connection")
        hub.apply(["connected": true, "sessions": []])
        _ = staleMenuStop.target?.perform(staleMenuStop.action, with: staleMenuStop)
        check(events == oldEvents, "removed session actions cannot target a different or missing session")
        hub.apply(payload())
        let explicitBefore = surface.focusRequests
        pressMenu(menuItem(menu, "hub.expand")!)
        check(hub.expanded && surface.focusRequests == explicitBefore + 1, "menu keyboard fallback explicitly expands and focuses")
        check(menuItem(menu, "hub.expand")!.keyEquivalent == "h", "hub has a menu shortcut without a global event tap")
        hub.apply(disconnected)
        check(toggle.title.contains("Offline"), "expanded hub keeps connection status visible when actions become unavailable")
        check(hub.expanded && surface.focusRequests == explicitBefore + 1, "passive updates of an expanded hub preserve state without refocusing")
        hub.apply(payload())
        let staleMenuHost = menuItem(menu, "hub.client.open.client-1")!
        var restricted = payload()
        restricted["hub"] = ["clients": [client(capabilities: ["observe": true, "openHost": false])]]
        hub.apply(restricted)
        _ = staleMenuHost.target?.perform(staleMenuHost.action, with: staleMenuHost)
        check(events == oldEvents, "capability revocation invalidates retained host actions even while connected")
        hub.apply(payload())
        pressMenu(menuItem(menu, "hub.ask")!)
        check(events.last == "ask" && !hub.expanded, "Ask hands off to the native composer without submitting")
        toggle.performClick(nil)
        check(surface.animations.last == true, "explicit expansion may animate when Reduce Motion is off")
        root.cancelOperation(nil)
        check(!hub.expanded && surface.releases > 0, "Escape collapses and releases hub keyboard ownership")
        check(surface.frames.last!.height == 44, "collapse restores the compact surface")

        screens = []
        hub.reflow()
        check(surface.hides > 0, "losing all screens hides the overlay without disabling menu access")
        pressMenu(menuItem(menu, "hub.ask")!)
        check(events.last == "ask", "menu actions remain usable with no eligible display")
        let closedFocus = surface.focusRequests, closedFrames = surface.frames.count
        hub.close(); hub.close(); hub.apply(payload()); hub.reflow()
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        toggle.performClick(nil)
        check(surface.closes == 1 && surface.frames.count == closedFrames && surface.focusRequests == closedFocus, "close is terminal, idempotent, and removes passive observers")
        check(NSApplication.shared.windows.isEmpty, "headless suite never creates a desktop window")
    }

    static func displaySelection() {
        let surface = HubSurfaceRecorder(), notifications = NotificationCenter()
        var screens = [external, laptop], preferences = CompanionHubPreferences(reduceMotion: true, reduceTransparency: true)
        let hub = CompanionHubController(screens: { screens }, preferences: { preferences },
            selectDisplay: { preferences.displayID = $0 }, notificationCenter: notifications,
            workspaceNotifications: NotificationCenter(), makeSurface: { _ in surface })
        let menu = hub.makeMenuItem().submenu!
        hub.apply(payload())
        check(surface.frames.last!.minX > 0, "default controller placement uses the external main display")
        let savedLaptop = menuItem(menu, "hub.display.laptop")!
        pressMenu(savedLaptop)
        check(preferences.displayID == "laptop" && surface.frames.last!.maxX < 0, "the menu pins the hub to the chosen notch")
        let choice = button(hub.contentView, "hub.display") as! NSPopUpButton
        check(choice.selectedItem?.representedObject as? String == "laptop", "the hub exposes its selected display")
        let retained = choice.item(at: 1)
        hub.apply(payload())
        check(choice.item(at: 1) === retained, "passive payloads do not rebuild an open display menu")
        screens = [external]; notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        check(preferences.displayID == "laptop" && surface.frames.last!.minX > 0, "a missing preferred display falls back without erasing the preference")
        check(choice.selectedItem?.isEnabled == false, "the picker explains that the saved display is unavailable")
        screens = [external, laptop]; hub.reflow()
        check(surface.frames.last!.maxX < 0 && choice.selectedItem?.isEnabled == true, "the hub returns when the preferred display reconnects")
        choice.select(choice.itemArray.first { $0.representedObject as? String == "external" })
        _ = choice.sendAction(choice.action!, to: choice.target)
        check(preferences.displayID == "external" && surface.frames.last!.minX > 0, "the expanded-hub picker uses the same display action")
        pressMenu(menuItem(menu, "hub.display.auto")!)
        check(preferences.displayID == nil && surface.frames.last!.minX > 0, "automatic placement can be restored")
        screens = [external]
        _ = savedLaptop.target?.perform(savedLaptop.action, with: savedLaptop)
        check(preferences.displayID == nil, "stale menu actions cannot choose a disconnected display")
        check(surface.focusRequests == 0, "display changes and selections do not take keyboard focus")
        hub.close()
    }

    static func main() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        geometry(); validation(); controller(); displaySelection()
        print("PASS \(checks) companion hub geometry, payload, accessibility, callback, and passive-focus checks (no windows)")
    }
}
