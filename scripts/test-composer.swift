import AppKit

@main struct ComposerChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let composer = CompanionComposer(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let editor = composer.editor
        var submitted = 0, dismissed = 0
        composer.onSubmit = { payload in
            precondition(payload["id"] as? String == "a" && payload["text"] as? String == "draft", "native submit forwards selected text as data")
            submitted += 1
        }
        composer.onDismiss = { dismissed += 1 }
        func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            editor.keyDown(with: event)
        }
        func state(_ text: String, edit: Int = 0, id: String = "a") -> [String: Any] {
            ["connected": true, "activeSessionID": id, "draft": text, "edit": edit, "generation": edit, "sessions": [["id": "a", "name": "First"], ["id": "b", "name": "Second"]], "status": "idle"]
        }
        composer.apply(state("draft")); editor.setSelectedRange(NSRange(location: 5, length: 0))
        precondition(composer.dictate.imagePosition == .imageOnly && composer.advanced.imagePosition == .imageOnly, "state updates keep icon controls free of overlapping titles")
        precondition(composer.advanced.accessibilityLabel() == composer.advanced.title, "the icon announces its control action, not its symbol name")
        key(36, "\r"); precondition(submitted == 1 && editor.string == "draft", "Enter submits without eating the draft")
        key(36, "\r", .shift); precondition(editor.string == "draft\n" && submitted == 1, "Shift-Enter inserts a real newline")
        key(53, "\u{1b}"); precondition(dismissed == 1 && editor.string == "draft\n", "Escape preserves the draft")
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(editor.hasMarkedText(), "test uses real marked text")
        key(36, "\r"); precondition(submitted == 1, "IME Enter cannot submit")
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        key(53, "\u{1b}"); precondition(dismissed == 1, "IME Escape cannot dismiss")
        editor.unmarkText()
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        key(36, "\r", .shift); precondition(submitted == 1, "IME Shift-Enter stays with text input")
        editor.unmarkText()
        composer.apply(state("canonical", edit: 100))
        var edits: [[String: Any]] = []
        composer.onDraft = { edits.append($0) }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)); editor.insertText(" typed", replacementRange: editor.selectedRange())
        precondition(edits.last?["text"] as? String == "canonical typed", "actual NSTextView edits reach transport")
        let lastEdit = edits.last?["edit"] as! Int
        composer.apply(state("stale", edit: 100))
        precondition(editor.string == "canonical typed", "a stale snapshot cannot erase unacknowledged typing")
        composer.apply(state("", edit: lastEdit))
        precondition(editor.string.isEmpty, "acknowledged submit can clear the draft")
        composer.apply(state("preserved", edit: lastEdit + 1))
        composer.apply(state("preserved", edit: lastEdit + 1))
        precondition(editor.string == "preserved", "passive state is idempotent")
        composer.apply(state("second", edit: 0, id: "b"))
        composer.apply(state("second dictated", edit: 1, id: "b"))
        precondition(editor.string == "second dictated", "another session's edit counter must not block dictation")
        let item = composer.sessions.item(at: 0)
        composer.apply(state("second dictated", edit: 1, id: "b"))
        precondition(composer.sessions.item(at: 0) === item, "passive state must not rebuild an open session menu")
        let beforePaste = editor.string
        editor.insertText(String(repeating: "x", count: 8001), replacementRange: NSRange(location: 0, length: 0))
        precondition(editor.string == beforePaste, "native paste enforces the same 8000-character bound as web input")
        composer.apply(state("draft for A ", edit: 1000, id: "a"))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        composer.apply(state("keep B existing draft", edit: 2000, id: "b"))
        precondition(composer.activeSessionID == "a", "composition keeps its original conversation during an asynchronous switch")
        let beforeCommit = edits.count
        editor.insertText("確定", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let commits = edits.dropFirst(beforeCommit).filter { ($0["text"] as? String)?.contains("確定") == true }
        precondition(!commits.isEmpty && commits.allSatisfy { $0["id"] as? String == "a" }, "IME completion never labels A's text as B's draft")
        precondition(composer.activeSessionID == "b" && editor.string == "keep B existing draft", "the deferred destination loads after composition ends")
        var cleared: String?
        composer.onClear = { cleared = $0["id"] as? String }
        composer.apply(state("keep draft", edit: 3000, id: "b").merging(["hasMarks": true, "status": "done"]) { _, new in new })
        precondition(!composer.clearMarks.isHidden && composer.clearMarks.isEnabled, "completed desktop marks have an immediate clear control")
        composer.clearMarks.performClick(nil)
        precondition(cleared == "b" && editor.string == "keep draft", "clear targets the selected conversation without consuming its draft")
        cleared = nil
        composer.apply(state("keep draft", edit: 3000, id: "b").merging(["hasMarks": true, "status": "thinking"]) { _, new in new })
        composer.clearMarks.performClick(nil)
        precondition(composer.clearMarks.isHidden && cleared == nil, "a busy turn uses Stop instead of clearing a changing target")
        composer.apply(state("keep draft", edit: 3000, id: "b").merging(["hasMarks": false]) { _, new in new })
        precondition(composer.clearMarks.isHidden, "empty conversations do not show an inactive clear control")
        precondition(composer.window == nil, "checks never order a window or send global input")
        print("PASS native editor Enter/Shift-Enter/Escape, real IME, draft callbacks, and stale-ack protection")
    }
}
