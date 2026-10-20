import AppKit

@main struct PopupChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let companion = CompanionDelegate()
        companion.panel = SelectionPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        companion.panel.isReleasedWhenClosed = false
        companion.composer = CompanionComposer(frame: companion.panel.contentView!.bounds)
        companion.panel.contentView = companion.composer
        companion.composer.apply(["connected": true, "activeSessionID": "a", "draft": "keep this draft", "edit": 0])
        companion.anchor = CGPoint(x: -1100.25, y: 1000.75)
        companion.anchorBounds = CGRect(x: -1920, y: 0, width: 1920, height: 1205.5)
        companion.panel.setFrame(PointerGeometry.popup(at: companion.anchor, size: companion.panel.frame.size, bounds: companion.anchorBounds), display: false)
        companion.resizePopup(180)
        precondition(companion.anchorBounds.insetBy(dx: 8, dy: 8).contains(companion.panel.frame))
        let other = NSTextField(); companion.composer.addSubview(other)
        companion.panel.makeFirstResponder(other)
        companion.composer.apply(["connected": true, "activeSessionID": "a", "draft": "keep this draft", "edit": 0, "status": "thinking"])
        precondition(companion.panel.firstResponder !== companion.composer.editor, "passive updates never take editor focus")
        companion.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: companion.panel))
        companion.resizePopup(240)
        precondition(companion.panel.firstResponder !== companion.composer.editor, "outside focus and resize never retry editor focus")
        var escapes = 0
        let panel = companion.panel as! SelectionPanel
        panel.onCancel = { escapes += 1 }
        companion.panel.makeFirstResponder(companion.composer.editor)
        companion.composer.editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        panel.cancelOperation(nil); precondition(escapes == 0, "window-level Escape also respects marked text")
        companion.composer.editor.unmarkText(); panel.cancelOperation(nil)
        precondition(escapes == 1, "Escape from other native controls reaches dismissal")
        companion.composer.apply(["connected": true, "activeSessionID": "a", "draft": "keep this draft", "edit": 10])
        companion.dismiss(restoreFocus: false)
        precondition(companion.composer.editor.string == "keep this draft", "dismiss keeps native draft")
        precondition(!companion.panel.isVisible && !companion.voice.active, "checks do not show UI or capture audio")
        let payload = CompanionContext.payload(pid: 42, launchDate: Date(timeIntervalSince1970: 1234.5), app: "Fixture", bundleID: "example.fixture", windowID: 71, cursor: CGPoint(x: -1200.25, y: 1199.75), primaryTop: 1440)
        precondition(payload["process"] as? String == "42:1234.5")
        precondition(payload["windowId"] as? Int == 71)
        let origin = payload["cursorOrigin"] as! [String: CGFloat]
        precondition(origin["x"] == -1200.25 && origin["y"] == 240.25, "context preserves fractional global-top-left origin")
        func window(_ id: Int, _ pid: Int, layer: Int = 0) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id, kCGWindowLayer as String: layer, kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 300, "Height": 200]]
        }
        let windows = [window(8, 99), window(9, 42, layer: 2), window(71, 42), window(72, 42)]
        precondition(CompanionContext.windowID(pid: 42, windows: windows) == 71)
        precondition(CompanionContext.windowID(pid: 42, windows: windows, preferred: 72) == 72, "explicit area-selected window is preserved")
        precondition(CompanionContext.windowID(pid: 42, windows: windows, preferred: 73) == nil, "an unavailable selected window is not silently replaced")
        precondition(CompanionDelegate.modelDocumentation("codex/gpt-6-astra")?.absoluteString == "https://developers.openai.com/api/docs/models/gpt-6-astra")
        precondition(CompanionDelegate.modelDocumentation("codex/gpt-5.6-sol")?.absoluteString == "https://developers.openai.com/api/docs/models/gpt-5.6-sol")
        for value: Any in ["https://untrusted.example", "codex/../secrets", "gpt-6-astra", NSNull(), 1] {
            precondition(CompanionDelegate.modelDocumentation(value) == nil, "documentation actions cannot open an arbitrary URL")
        }
        var lookups: [pid_t] = []
        let client: [String: Any] = ["capabilities": ["openHost": true], "host": ["ancestors": [4, 42, 99], "bundleId": "example.fixture"]]
        let pid = CompanionContext.hostPID(client) { pid in lookups.append(pid); return pid == 42 ? "example.fixture" : "other.app" }
        precondition(pid == 42 && lookups == [4, 42], "only registered ancestry with a matching live bundle is considered")
        precondition(CompanionContext.hostPID(["capabilities": ["openHost": false], "host": client["host"]!]) { _ in "example.fixture" } == nil)
        precondition(CompanionContext.hostPID(client) { _ in nil } == nil, "exited hosts never resolve to an arbitrary app")
        let canvasWindow = NSWindow(contentRect: CGRect(x: -1700, y: 100, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        canvasWindow.isReleasedWhenClosed = false
        let canvas = AreaSelectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        canvasWindow.contentView = canvas
        let down = CGPoint(x: 17.25, y: 31.5), drag = CGPoint(x: 93.5, y: 110.25), up = CGPoint(x: 141.75, y: 169.5)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, window: Int? = nil) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window ?? canvasWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func near(_ a: CGPoint?, _ b: CGPoint) -> Bool { a.map { hypot($0.x - b.x, $0.y - b.y) < 0.001 } ?? false }
        let pointer = NSEvent.mouseLocation
        var completed = 0, finalPoints: [CGPoint] = []
        canvas.finish = { a, b, points in
            precondition(near(a, canvasWindow.convertPoint(toScreen: down)) && near(b, canvasWindow.convertPoint(toScreen: up)), "gesture bounds come from their own down and up events")
            completed += 1; finalPoints = points
        }
        for mode in ["select", "circle", "highlight", "arrow", "draw"] {
            canvas.mode = mode
            canvas.mouseDown(with: mouse(.leftMouseDown, down))
            precondition(near(canvas.start, canvasWindow.convertPoint(toScreen: down)), "down uses the queued event, not current global mouse position")
            canvas.mouseDragged(with: mouse(.leftMouseDragged, drag))
            precondition(near(canvas.end, canvasWindow.convertPoint(toScreen: drag)), "drag preserves its event position on a negative-origin display")
            canvas.mouseUp(with: mouse(.leftMouseUp, up))
            precondition(finalPoints.count == 3 && near(finalPoints[1], canvasWindow.convertPoint(toScreen: drag)), "freehand points keep the event path")
            canvas.mouseUp(with: mouse(.leftMouseUp, up))
        }
        precondition(completed == 5, "each gesture finishes once")
        canvas.mouseDown(with: mouse(.leftMouseDown, down))
        for i in 1...511 { canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: down.x + CGFloat(i) * 3, y: down.y))) }
        canvas.mouseUp(with: mouse(.leftMouseUp, up))
        precondition(finalPoints.count == 512 && near(finalPoints.last, canvasWindow.convertPoint(toScreen: up)), "the point cap still keeps the actual final event")
        canvas.mouseDown(with: mouse(.leftMouseDown, down))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, drag, window: canvasWindow.windowNumber + 100000))
        canvas.mouseUp(with: mouse(.leftMouseUp, up))
        precondition(completed == 6 && canvas.start == nil, "a foreign-window event cannot complete an old drag")
        canvas.mouseDown(with: mouse(.leftMouseDown, down)); canvasWindow.contentView = NSView()
        canvas.mouseUp(with: mouse(.leftMouseUp, up))
        precondition(completed == 6 && canvas.start == nil && canvas.points.isEmpty, "a detached view cancels stale gesture state")
        precondition(!canvasWindow.isVisible, "synthetic gestures never expose an overlay or send system input")
        if NSEvent.mouseLocation != pointer { print("NOTE real pointer changed during this direct-handler check; no input events were posted") }
        canvasWindow.close()
        print("PASS popup focus/drafts, identity, host ancestry, and event-bound drawing in all five modes")
    }
}
