import AppKit

private func cafeColor(_ light: UInt32, _ dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

final class CompanionTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onCompositionEnd: (() -> Void)?
    private var handlingMarkedText = false

    override func unmarkText() {
        super.unmarkText()
        if !hasMarkedText() { onCompositionEnd?() }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        if !hasMarkedText() { onCompositionEnd?() }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if !hasMarkedText() { onCompositionEnd?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() {
            NSAttributedString(string: "Point, circle, highlight…", attributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: cafeColor(0x716454, 0xc4b6a3)])
                .draw(at: CGPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height))
        }
    }

    override func keyDown(with event: NSEvent) {
        handlingMarkedText = hasMarkedText()
        defer { handlingMarkedText = false }
        if handlingMarkedText { super.keyDown(with: event); return }
        if event.keyCode == 53 { onDismiss?(); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) { super.insertNewline(nil) }
            else { onSubmit?() }
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if handlingMarkedText || hasMarkedText() { super.doCommand(by: selector); return }
        if selector == #selector(insertNewline(_:)) { onSubmit?() }
        else if selector == #selector(cancelOperation(_:)) { onDismiss?() }
        else { super.doCommand(by: selector) }
    }
}

/// The web transport owns sessions/drafts. This view only mirrors the selected draft and
/// keeps an edit sequence so a delayed acknowledgment cannot replace newer native input.
final class CompanionComposer: NSView, NSTextViewDelegate {
    let editor = CompanionTextView()
    let sessions = NSPopUpButton()
    let send = NSButton(title: "Send", target: nil, action: nil)
    let stop = NSButton(title: "Stop", target: nil, action: nil)
    let dictate = NSButton(title: "Dictate", target: nil, action: nil)
    let clearMarks = NSButton(title: "Clear marks", target: nil, action: nil)
    let advanced = NSButton(title: "Controls & history", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "Connecting…")
    private let context = NSTextField(labelWithString: "Your screen companion")
    private(set) var activeSessionID: String?
    private(set) var advancedVisible = false
    private var edit = 0, nextEdit = 0
    private var sessionSignature: [String] = []
    private var applying = false
    private var pendingSession: String?
    private var pendingNew = false
    private var deferredState: [String: Any]?
    var onDraft: (([String: Any]) -> Void)?
    var onSubmit: (([String: Any]) -> Void)?
    var onSession: (([String: Any]) -> Void)?
    var onStop: (([String: Any]) -> Void)?
    var onClear: (([String: Any]) -> Void)?
    var onAdvanced: (([String: Any]) -> Void)?
    var onDictation: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let accent = cafeColor(0x785037, 0xd6ac80), muted = cafeColor(0x716454, 0xc4b6a3)
        let cup = NSImageView(image: NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)!)
        cup.contentTintColor = accent; cup.setAccessibilityElement(false)
        cup.widthAnchor.constraint(equalToConstant: 16).isActive = true
        cup.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let title = NSTextField(labelWithString: "Andy")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        context.font = .systemFont(ofSize: 11); context.textColor = muted
        context.lineBreakMode = .byTruncatingTail
        context.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = NSButton(title: "Dismiss", target: self, action: #selector(dismiss))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        close.setAccessibilityLabel("Dismiss composer"); close.toolTip = "Dismiss · Escape keeps your draft"
        advanced.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        advanced.target = self; advanced.action = #selector(toggleAdvanced); advanced.toolTip = "Controls and history"
        for button in [advanced, close] {
            button.imagePosition = .imageOnly; button.isBordered = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let header = NSStackView(views: [cup, title, context, advanced, close])
        header.spacing = 6; header.distribution = .fill; header.alignment = .centerY
        let scroll = NSScrollView(); scroll.borderType = .noBorder; scroll.drawsBackground = false
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        editor.minSize = NSSize(width: 0, height: 44)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = editor
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 14); editor.textColor = cafeColor(0x302820, 0xf4eade); editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 2, height: 6)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Ask Andy")
        editor.setAccessibilityHelp("Name a control or ask a screen question. Enter sends; Shift-Enter inserts a line.")
        editor.delegate = self; editor.isEditable = false
        editor.onSubmit = { [weak self] in self?.submit() }; editor.onDismiss = { [weak self] in self?.dismiss() }
        editor.onCompositionEnd = { [weak self] in
            guard self?.deferredState != nil else { return }
            // Finish the current AppKit edit under its original conversation before applying another.
            DispatchQueue.main.async { [weak self] in self?.applyDeferredState() }
        }
        sessions.setAccessibilityLabel("Conversation"); sessions.target = self; sessions.action = #selector(sessionChosen)
        sessions.controlSize = .small; sessions.font = .systemFont(ofSize: 12); sessions.isBordered = false
        sessions.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessions.widthAnchor.constraint(lessThanOrEqualToConstant: 164).isActive = true
        send.target = self; send.action = #selector(submit); send.isEnabled = false
        send.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        send.bezelStyle = .circular
        send.setAccessibilityLabel("Send question"); send.toolTip = "Send · Enter"
        stop.target = self; stop.action = #selector(stopSession); stop.isHidden = true
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stop.contentTintColor = .systemRed; stop.setAccessibilityLabel("Stop current turn"); stop.toolTip = "Stop current turn"
        dictate.target = self; dictate.action = #selector(dictation)
        dictate.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        dictate.setAccessibilityLabel("Dictate into draft; never sends"); dictate.toolTip = "Dictate into draft; never sends"
        clearMarks.target = self; clearMarks.action = #selector(clearVisuals); clearMarks.isHidden = true
        clearMarks.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        clearMarks.setAccessibilityLabel("Clear marks"); clearMarks.toolTip = "Clear this conversation’s desktop marks"
        for button in [clearMarks, dictate, send, stop] {
            button.imagePosition = .imageOnly
            if button !== send { button.isBordered = false }
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        status.font = .systemFont(ofSize: 11); status.textColor = muted; status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        let controls = NSStackView(views: [sessions, status, clearMarks, dictate, send, stop])
        controls.spacing = 5; controls.distribution = .fill; controls.alignment = .centerY
        let stack = NSStackView(views: [header, scroll, controls])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            scroll.heightAnchor.constraint(equalToConstant: 44)
        ])
        for view in [header, scroll, controls] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        updateBackground()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = cafeColor(0xfcf9f2, 0x26221d).cgColor }
    }

    private var draftPayload: [String: Any] { ["id": activeSessionID as Any? ?? NSNull(), "text": editor.string, "edit": edit] }
    func textDidChange(_ notification: Notification) {
        guard !applying else { return }
        nextEdit = max(nextEdit, edit) + 1; edit = nextEdit; onDraft?(draftPayload)
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString = replacementString else { return true }
        return textView.string.utf16.count - affectedCharRange.length + replacementString.utf16.count <= 8000
    }
    @objc private func submit() {
        guard send.isEnabled, !editor.hasMarkedText() else { return }
        onSubmit?(draftPayload)
    }
    @objc private func dismiss() { guard !editor.hasMarkedText() else { return }; onDismiss?() }
    @objc private func stopSession() { if let id = activeSessionID { onStop?(["id": id]) } }
    @objc private func clearVisuals() { if clearMarks.isEnabled, let id = activeSessionID { onClear?(["id": id]) } }
    @objc private func dictation() { onDictation?() }
    @objc private func toggleAdvanced() { onAdvanced?(["visible": !advancedVisible]) }
    @objc private func sessionChosen() { selectSession(id: sessions.selectedItem?.representedObject as? String) }
    func selectSession(id: String?) {
        pendingSession = id; pendingNew = id == nil; editor.isEditable = false
        onSession?(["id": id as Any? ?? NSNull()])
    }
    func transportError(_ message: String) {
        pendingSession = nil; pendingNew = false
        status.stringValue = message; status.toolTip = message; editor.isEditable = true
        applyDeferredState()
    }
    private func applyDeferredState() {
        guard !editor.hasMarkedText(), let payload = deferredState else { return }
        apply(payload)
    }
    func setContext(_ name: String) { context.stringValue = name.isEmpty ? "Your screen companion" : name; context.toolTip = context.stringValue }
    func focus() { window?.makeFirstResponder(editor) }

    func apply(_ payload: [String: Any]) {
        let id = payload["activeSessionID"] as? String
        if let pending = pendingSession, pending != id { return }
        if pendingNew && id == activeSessionID { return }
        pendingSession = nil; pendingNew = false
        let changedSession = id != activeSessionID
        if changedSession && editor.hasMarkedText() {
            deferredState = payload; send.isEnabled = false
            status.stringValue = "Finish text composition to change conversation."
            return
        }
        deferredState = nil
        activeSessionID = id
        let acknowledged = payload["edit"] as? Int ?? 0
        if !editor.hasMarkedText(), changedSession || acknowledged >= edit {
            applying = true
            let text = payload["draft"] as? String ?? ""
            if editor.string != text {
                editor.string = text; editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
                editor.undoManager?.removeAllActions()
            }
            applying = false
        }
        edit = changedSession ? acknowledged : max(edit, acknowledged)
        nextEdit = max(nextEdit, edit)
        let items = Array((payload["sessions"] as? [[String: Any]] ?? []).prefix(8))
        let signature = items.flatMap { [$0["id"] as? String ?? "", $0["name"] as? String ?? "Andy"] }
        if signature != sessionSignature || sessions.numberOfItems == 0 {
            sessionSignature = signature; sessions.removeAllItems()
            for session in items {
                guard let sessionID = session["id"] as? String else { continue }
                sessions.addItem(withTitle: session["name"] as? String ?? "Andy"); sessions.lastItem?.representedObject = sessionID
            }
            if sessions.numberOfItems == 0 { sessions.addItem(withTitle: "New conversation") }
            sessions.menu?.addItem(.separator()); sessions.addItem(withTitle: "New conversation…")
        }
        if let selected = sessions.itemArray.first(where: { $0.representedObject as? String == id }) { sessions.select(selected) }
        let connected = payload["connected"] as? Bool == true
        let busy = payload["status"] as? String == "thinking" || payload["sending"] as? Bool == true
        editor.isEditable = true; send.isEnabled = connected && !busy
        send.isHidden = busy; stop.isHidden = !busy; stop.isEnabled = connected
        clearMarks.isHidden = payload["hasMarks"] as? Bool != true || busy; clearMarks.isEnabled = connected && !busy
        dictate.isEnabled = connected
        let voicePhase = payload["voicePhase"] as? String ?? "idle"
        let capturing = ["permission", "listening", "finishing"].contains(voicePhase)
        dictate.title = capturing ? "Finish voice" : "Dictate"
        dictate.image = NSImage(systemSymbolName: capturing ? "stop.circle" : "mic", accessibilityDescription: nil)
        dictate.imagePosition = .imageOnly
        dictate.toolTip = capturing ? "Finish voice" : "Dictate into draft; never sends"
        dictate.setAccessibilityLabel(dictate.toolTip)
        advancedVisible = payload["advanced"] as? Bool == true
        advanced.title = advancedVisible ? "Hide controls" : "Controls & history"
        advanced.image = NSImage(systemSymbolName: advancedVisible ? "chevron.up" : "ellipsis", accessibilityDescription: nil)
        advanced.imagePosition = .imageOnly
        advanced.toolTip = advanced.title; advanced.setAccessibilityLabel(advanced.title)
        if !connected { status.stringValue = "Reconnecting to local CUA…" }
        else if let voiceStatus = payload["voiceStatus"] as? String, !voiceStatus.isEmpty { status.stringValue = voiceStatus }
        else if payload["needsApproval"] as? Bool == true { status.stringValue = "Review approval below" }
        else if let notice = payload["notice"] as? String, !notice.isEmpty { status.stringValue = "Needs your attention below" }
        else { status.stringValue = busy ? "Working…" : payload["status"] as? String == "done" ? "Done" : "" }
        status.toolTip = status.stringValue
    }
}

/// Pure geometry/identity projection; callers supply a fresh running application and window list.
enum CompanionContext {
    static func hostPID(_ client: [String: Any], bundleForPID: (pid_t) -> String?) -> pid_t? {
        guard (client["capabilities"] as? [String: Any])?["openHost"] as? Bool == true,
              client["stale"] as? Bool != true,
              let host = client["host"] as? [String: Any], let bundle = host["bundleId"] as? String,
              !bundle.isEmpty, bundle.utf16.count <= 256,
              let ancestors = host["ancestors"] as? [NSNumber] else { return nil }
        for number in ancestors.prefix(32) {
            guard let pid = pid_t(exactly: number.int64Value), pid > 0,
                  number.doubleValue == Double(pid) else { continue }
            if bundleForPID(pid) == bundle { return pid }
        }
        return nil
    }
    static func payload(pid: pid_t, launchDate: Date, app: String, bundleID: String?, windowID: CGWindowID?, cursor: CGPoint, primaryTop: CGFloat) -> [String: Any] {
        var value: [String: Any] = ["pid": Int(pid), "process": "\(pid):\(launchDate.timeIntervalSince1970)", "app": app,
                                   "cursorOrigin": ["x": cursor.x, "y": primaryTop - cursor.y]]
        if let bundleID = bundleID { value["bundleId"] = bundleID }
        if let windowID = windowID { value["windowId"] = Int(windowID) }
        return value
    }
    static func windowID(pid: pid_t, windows: [[String: Any]], preferred: CGWindowID? = nil) -> CGWindowID? {
        let ids = windows.compactMap { info -> CGWindowID? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber, number.int64Value > 0,
                  let id = CGWindowID(exactly: number.int64Value),
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.width > 0, bounds.height > 0 else { return nil }
            return id
        }
        if let preferred = preferred { return ids.contains(preferred) ? preferred : nil }
        return ids.first
    }
}
