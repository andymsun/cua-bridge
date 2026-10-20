import AppKit

private func cafeColor(_ light: UInt32, _ dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

enum CompanionFileInput {
    case urls([URL]), image(Data, String), unsupported
    static func pasted(_ pasteboard: NSPasteboard) -> CompanionFileInput? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return .urls(urls) }
        for (type, name) in [(NSPasteboard.PasteboardType.png, "Pasted image.png"), (NSPasteboard.PasteboardType("public.jpeg"), "Pasted image.jpg")] {
            if let data = pasteboard.data(forType: type) { return .image(data, name) }
        }
        return pasteboard.types?.contains(.tiff) == true ? .unsupported : nil
    }
    func read() throws -> [[String: String]] {
        func error(_ message: String) -> NSError { NSError(domain: "CompanionFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        var files: [(String, Data)] = []
        switch self {
        case .urls(let urls):
            guard !urls.isEmpty, urls.count <= 4 else { throw error("Choose one to four files.") }
            for url in urls {
                guard url.isFileURL else { throw error("Choose a local file.") }
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw error("The file could not be opened. Choose the original file, not a link.") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var before = stat(), after = stat()
                guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= 8388608 else { throw error("Choose a nonempty file up to 8 MiB.") }
                let data = try handle.read(upToCount: 8388609) ?? Data()
                guard fstat(fd, &after) == 0, data.count == before.st_size, after.st_size == before.st_size,
                      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw error("The file changed while it was read. Choose it again.") }
                files.append((url.lastPathComponent, data))
            }
        case .image(let data, let name): files = [(name, data)]
        case .unsupported: throw error("This clipboard image is TIFF. Export a PNG or JPEG, then attach that file.")
        }
        guard files.allSatisfy({ !$0.1.isEmpty && $0.1.count <= 8388608 }), files.reduce(0, { $0 + $1.1.count }) <= 16777216 else { throw error("Use files up to 8 MiB each and 16 MiB together.") }
        return files.map { ["name": $0.0, "data": $0.1.base64EncodedString()] }
    }
}

final class CompanionTextView: NSTextView {
    var onFiles: ((CompanionFileInput) -> Void)?
    func acceptFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard isEditable, !hasMarkedText(), let input = CompanionFileInput.pasted(pasteboard), let onFiles = onFiles else { return false }
        onFiles(input); return true
    }
    override func paste(_ sender: Any?) { if !acceptFiles(.general) { super.paste(sender) } }
    private func hasFiles(_ pasteboard: NSPasteboard) -> Bool { pasteboard.availableType(from: [.fileURL, .png, .tiff, .init("public.jpeg")]) != nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { hasFiles(sender.draggingPasteboard) ? (isEditable ? .copy : []) : super.draggingEntered(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { hasFiles(sender.draggingPasteboard) ? (isEditable ? .copy : []) : super.draggingUpdated(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hasFiles(sender.draggingPasteboard) ? isEditable : super.prepareForDragOperation(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { hasFiles(sender.draggingPasteboard) ? acceptFiles(sender.draggingPasteboard) : super.performDragOperation(sender) }
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
    let resume = NSButton(title: "Continue guide", target: nil, action: nil)
    private var guideID: String?
    var onResume: (([String: Any]) -> Void)?
    let attach = NSButton(title: "Attach files", target: nil, action: nil)
    var onAttach: (() -> Void)?
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
        attach.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        attach.target = self; attach.action = #selector(attachFiles); attach.isEnabled = false
        attach.setAccessibilityLabel("Attach files"); attach.toolTip = "Attach files; they stay local until Send or Continue"
        for button in [attach, advanced, close] {
            button.imagePosition = .imageOnly; button.isBordered = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let header = NSStackView(views: [cup, title, context, attach, advanced, close])
        header.spacing = 6; header.distribution = .fill; header.alignment = .centerY
        let scroll = NSScrollView(); scroll.borderType = .noBorder; scroll.drawsBackground = false
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        editor.minSize = NSSize(width: 0, height: 44)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = editor
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.registerForDraggedTypes([.fileURL, .png, .tiff, .init("public.jpeg")])
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
        resume.target = self; resume.action = #selector(resumeGuide); resume.isHidden = true
        resume.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
        resume.setAccessibilityLabel("Continue guide"); resume.toolTip = "Continue the paused guide; keep your draft"
        for button in [clearMarks, resume, dictate, send, stop] {
            button.imagePosition = .imageOnly
            if button !== send { button.isBordered = false }
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        status.font = .systemFont(ofSize: 11); status.textColor = muted; status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        let controls = NSStackView(views: [sessions, status, clearMarks, resume, dictate, send, stop])
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

    var draftPayload: [String: Any] { ["id": activeSessionID as Any? ?? NSNull(), "text": editor.string, "edit": edit] }
    var canReconnect: Bool { !editor.hasMarkedText() && pendingSession == nil && !pendingNew }
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
    @objc private func resumeGuide() { if resume.isEnabled, let id = activeSessionID, let step = guideID { onResume?(["id": id, "guideId": step]) } }
    @objc private func attachFiles() { if attach.isEnabled { onAttach?() } }
    @objc private func dictation() { onDictation?() }
    @objc private func toggleAdvanced() { onAdvanced?(["visible": !advancedVisible]) }
    @objc private func sessionChosen() { selectSession(id: sessions.selectedItem?.representedObject as? String) }
    func selectSession(id: String?) {
        pendingSession = id; pendingNew = id == nil; editor.isEditable = false
        onSession?(["id": id as Any? ?? NSNull()])
    }
    func beginRestore() {
        editor.isEditable = false; send.isEnabled = false; dictate.isEnabled = false; sessions.isEnabled = false
        clearMarks.isEnabled = false; resume.isEnabled = false; attach.isEnabled = false
        edit = 0; pendingSession = nil; pendingNew = false; deferredState = nil
        status.stringValue = "Restoring drafts…"
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
        let filesBusy = payload["filesBusy"] as? Bool == true
        attach.isEnabled = connected && id != nil && !filesBusy
        let fileCount = payload["fileCount"] as? Int ?? 0
        attach.toolTip = fileCount > 0 ? "\(fileCount) files for this conversation; add more" : "Attach files; they stay local until Send or Continue"
        editor.isEditable = id != nil; sessions.isEnabled = connected; send.isEnabled = connected && !busy && id != nil && !filesBusy
        send.isHidden = busy; stop.isHidden = !busy; stop.isEnabled = connected
        guideID = (payload["guideID"] as? String).flatMap { !$0.isEmpty && $0.utf16.count <= 128 ? $0 : nil }
        resume.isHidden = guideID == nil || busy; resume.isEnabled = connected && !busy && guideID != nil && !filesBusy
        clearMarks.isHidden = payload["hasMarks"] as? Bool != true || busy || guideID != nil; clearMarks.isEnabled = connected && !busy && guideID == nil
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
        else if filesBusy { status.stringValue = "Adding files…" }
        else if busy { status.stringValue = "Working…" }
        else {
            switch payload["status"] as? String {
            case "paused": status.stringValue = "Paused"
            case "stopped": status.stringValue = "Stopped"
            case "done": status.stringValue = "Done"
            default: status.stringValue = ""
            }
        }
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
