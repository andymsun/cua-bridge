import AppKit
import WebKit
import Carbon

@main struct CompanionReconnectChecks {
    static func main() throws {
        let good = "http://127.0.0.1:45678/companion?t=owned-valid-token"
        precondition(CompanionDelegate.recoveryURL(good)?.absoluteString == good)
        for bad in [good.replacingOccurrences(of: "http:", with: "https:"), good.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
                    good.replacingOccurrences(of: "127.0.0.1", with: "user@127.0.0.1"), good.replacingOccurrences(of: ":45678", with: ""),
                    good.replacingOccurrences(of: ":45678", with: ":70000"), good.replacingOccurrences(of: "/companion", with: "/other"),
                    good + "#fragment", good + "&t=duplicate-token", good + "&other=value", good.replacingOccurrences(of: "owned-valid-token", with: "short"),
                    good.replacingOccurrences(of: "owned-valid-token", with: "%6fwned-valid-token")] {
            precondition(CompanionDelegate.recoveryURL(bad) == nil, "unsafe recovery URL was accepted")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: root.appendingPathComponent("fixture.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: String]
        let a = fixture["a"]!, b = fixture["b"]!, first = URL(string: fixture["url"]!)!
        let initial = CommandLine.arguments.contains("--initial")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let companion = CompanionDelegate()
        companion.openCompanion(initial ? URL(string: first.absoluteString.replacingOccurrences(of: "owned-before-token", with: "owned-invalid-token"))! : first)
        companion.hotkeys.forEach { UnregisterEventHotKey($0) }; companion.hotkeys = []
        if let handler = companion.eventHandler { RemoveEventHandler(handler); companion.eventHandler = nil }
        if let item = companion.statusItem { NSStatusBar.system.removeStatusItem(item); companion.statusItem = nil }
        func wait(_ label: String, seconds: Double = 8, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() >= deadline { fputs("FAIL \(label)\n", stderr); exit(1) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        func pump(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        func js(_ expression: String) -> Any? {
            var finished = false, value: Any?
            companion.web.evaluateJavaScript(expression) { result, _ in value = result; finished = true }
            wait("owned WebKit callback", seconds: 3) { finished }; return value
        }
        func probeCount() -> Int {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("probe.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return 0 }
            return object["count"] ?? 0
        }
        func select(_ id: String) {
            companion.composer.selectSession(id: id)
            wait("native conversation selected") { companion.composer.activeSessionID == id && companion.composer.editor.isEditable }
        }
        func append(_ text: String) {
            let editor = companion.composer.editor
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let draftFile = root.appendingPathComponent("companion-drafts.json")
        func saved(_ id: String) -> String? {
            guard let bytes = try? Data(contentsOf: draftFile), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let drafts = object["drafts"] as? [String: [String: Any]] else { return nil }
            return drafts[id]?["text"] as? String
        }
        wait("native restore acknowledged", seconds: 15) { companion.web.url == first && js("nativeDraftReady && online") as? Bool == true }
        if initial {
            precondition(companion.panel.contentView?.subviews.count == 2, "failed pages must not stack labels over the composer")
            precondition(!companion.panel.isVisible)
            companion.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            print("PASS initial authentication failure recovers before draft acknowledgment, without revealing the popup")
            exit(0)
        }
        select(a); append("Keep A: 日本語 and coffee ☕")
        select(b); append("Keep B: another unsent question")
        wait("both owned drafts saved") { saved(a) == "Keep A: 日本語 and coffee ☕" && saved(b) == "Keep B: another unsent question" }
        select(a)
        let oldEpoch = js("nativeDraftEpoch") as! Int, oldProbes = probeCount()
        try Data().write(to: root.appendingPathComponent("stale-probe"))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        _ = js("online=false;paint()")
        pump(1.2); precondition(probeCount() == oldProbes, "sleep pauses discovery")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        pump(1.2); precondition(probeCount() == oldProbes, "wake cannot bypass an inactive session")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        wait("owned discovery started") { probeCount() > oldProbes }
        _ = js("online=true;paint()")
        pump(1)
        precondition(js("nativeDraftEpoch") as? Int == oldEpoch && companion.web.url == first, "online recovery rejects a stale discovery result")
        _ = js("window.savedPrepare=window.baristaPrepareReconnect;window.baristaPrepareReconnect=()=>new Promise(()=>{});online=false;paint()")
        wait("an unresponsive page must release its recovery probe", seconds: 8) { companion.composer.status.stringValue == "Page did not answer" }
        precondition(companion.web.url == first && companion.composer.editor.string == "Keep A: 日本語 and coffee ☕")
        _ = js("window.baristaPrepareReconnect=window.savedPrepare;online=true;paint()")
        try FileManager.default.removeItem(at: root.appendingPathComponent("stale-probe"))
        let socket = root.appendingPathComponent("daemon.sock"), heldSocket = root.appendingPathComponent("held.sock")
        try FileManager.default.moveItem(at: socket, to: heldSocket)
        _ = js("online=false;paint()")
        wait("missing socket has actionable feedback") { companion.composer.status.stringValue == "Local CUA unavailable" && companion.composer.status.toolTip?.contains("CUA_RUN_DIR") == true }
        precondition(companion.web.url == first && companion.composer.editor.string == "Keep A: 日本語 and coffee ☕")
        try FileManager.default.moveItem(at: heldSocket, to: socket)
        _ = js("online=true;paint()")
        let handle = try FileHandle(forWritingTo: draftFile)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("\n".utf8)); try handle.close()
        let externalBytes = try Data(contentsOf: draftFile)
        append(" · newest unsaved edit")
        wait("owned external-change error surfaced") { (js("draftStorageError") as? String)?.isEmpty == false }
        let expected = companion.composer.editor.string
        companion.composer.editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try Data().write(to: root.appendingPathComponent("restart"))
        wait("replacement owned server ready") { FileManager.default.fileExists(atPath: root.appendingPathComponent("next.json").path) }
        pump(2)
        precondition(companion.web.url == first && companion.composer.editor.hasMarkedText(), "recovery must not interrupt IME composition")
        let beforeDiscovery = probeCount()
        companion.composer.editor.unmarkText(); companion.composer.editor.didChangeText()
        precondition(companion.composer.editor.string.hasPrefix(expected), "composition kept the newer unsaved edit")
        wait("discovery after IME") { probeCount() > beforeDiscovery }
        append(" · edited during discovery")
        let composed = companion.composer.editor.string
        let next = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("next.json"))) as! [String: String]
        wait("native page did not recover after a daemon URL change", seconds: 15) { companion.web.url?.absoluteString == next["url"] && js("nativeDraftReady && online") as? Bool == true }
        precondition(companion.composer.activeSessionID == a && companion.composer.editor.string == composed, "reconnect preserves the latest native draft, not stale disk bytes")
        precondition((js("draftStorageError") as? String)?.isEmpty == false, "reconnect keeps the draft-save error visible")
        select(b); precondition(companion.composer.editor.string == "Keep B: another unsent question")
        select(a); precondition(companion.composer.editor.string == composed)
        try Data().write(to: root.appendingPathComponent("rotate"))
        wait("same-port token rotation ready") { FileManager.default.fileExists(atPath: root.appendingPathComponent("rotated.json").path) }
        let rotated = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("rotated.json"))) as! [String: String]
        precondition(URL(string: rotated["url"]!)!.port == URL(string: next["url"]!)!.port)
        wait("same-port token rotation recovered", seconds: 15) { companion.web.url?.absoluteString == rotated["url"] && js("nativeDraftReady && online") as? Bool == true }
        precondition(companion.composer.editor.string == composed)
        let afterRecovery = try Data(contentsOf: draftFile)
        precondition(afterRecovery == externalBytes, "reconnect does not overwrite externally changed draft bytes")
        precondition(js("state.sessions.every(s => s.messages.length === 0)") as? Bool == true, "recovery never sends a question")
        precondition(!companion.panel.isVisible, "background recovery does not reveal or focus the popup")
        companion.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("PASS actual WebKit port/token recovery, stale discovery, IME deferral, latest unsaved drafts, save errors, and no automatic send")
        exit(0)
    }
}
