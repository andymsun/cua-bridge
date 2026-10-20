import AppKit

struct CompanionHubScreen {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
    let safeTop: CGFloat
    var auxiliaryLeft: CGRect = .zero
    var auxiliaryRight: CGRect = .zero
    var isMain = false

    @MainActor static func current() -> [CompanionHubScreen] {
        let main = NSScreen.main
        return NSScreen.screens.enumerated().map { index, screen in
            CompanionHubScreen(id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "screen-\(index)",
                frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
                auxiliaryLeft: screen.auxiliaryTopLeftArea ?? .zero, auxiliaryRight: screen.auxiliaryTopRightArea ?? .zero,
                isMain: screen == main)
        }
    }
}

enum CompanionHubGeometry {
    struct Placement {
        let screenID: String
        let frame: CGRect
        let notched: Bool
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }

    static func layout(screens: [CompanionHubScreen], expanded: Bool, contentHeight: CGFloat) -> Placement? {
        guard contentHeight.isFinite else { return nil }
        let candidates = screens.compactMap { screen -> (Placement, Bool)? in
            guard valid(screen.frame), valid(screen.visibleFrame), screen.safeTop.isFinite,
                  screen.safeTop >= 0, screen.safeTop < screen.frame.height else { return nil }
            let visible = screen.frame.intersection(screen.visibleFrame)
            guard valid(visible) else { return nil }
            let top = min(visible.maxY, screen.frame.maxY - screen.safeTop) - 6
            let availableHeight = top - visible.minY - 8, availableWidth = visible.width - 16
            guard availableWidth >= 240, availableHeight >= (expanded ? 120 : 44) else { return nil }
            let left = screen.auxiliaryLeft, right = screen.auxiliaryRight
            let notched = screen.safeTop > 0 && valid(left) && valid(right)
                && screen.frame.contains(left) && screen.frame.contains(right)
                && left.maxX < right.minX && left.minY >= screen.frame.maxY - screen.safeTop
                && right.minY >= screen.frame.maxY - screen.safeTop
                && abs(left.minX - screen.frame.minX) < 0.01 && abs(right.maxX - screen.frame.maxX) < 0.01
                && abs(left.maxY - screen.frame.maxY) < 0.01 && abs(right.maxY - screen.frame.maxY) < 0.01
            let center = notched ? (left.maxX + right.minX) / 2 : visible.midX
            let width = min(expanded ? 400 : 268, availableWidth)
            let height = expanded ? min(max(120, contentHeight), 480, availableHeight) : 44
            let x = min(max(center - width / 2, visible.minX + 8), visible.maxX - width - 8)
            return (Placement(screenID: screen.id, frame: CGRect(x: x, y: top - height, width: width, height: height), notched: notched), screen.isMain)
        }
        return (candidates.first { $0.0.notched } ?? candidates.first { $0.1 } ?? candidates.first)?.0
    }
}

// Decode only display metadata. Never retain the original bridge dictionary.
struct CompanionHubState: Equatable {
    struct Session: Equatable {
        let id: String, name: String, status: String
        let needsApproval: Bool
        var canStop: Bool { status == "thinking" || needsApproval }
        var detail: String { needsApproval ? "Approval needed" : CompanionHubState.statusLabel(status) }
    }
    struct Client: Equatable {
        let id: String, name: String, status: String
        let canOpenHost: Bool
    }
    struct Provider: Equatable {
        let id: String, name: String
        let available: Bool
        var detail: String { "\(available ? "Installed" : "Not installed") · Not attached" }
    }
    let connected: Bool
    let activeSessionID: String?
    let sessions: [Session]
    let clients: [Client]
    let providers: [Provider]

    init(_ payload: [String: Any]) {
        connected = Self.flag(payload["connected"])
        sessions = Self.rows(payload["sessions"], limit: 32).map { id, row in
            Session(id: id, name: Self.label(row["name"], fallback: "Companion"),
                status: Self.status(row["status"], allowed: ["idle", "thinking", "done", "stopped", "error"]),
                needsApproval: Self.flag(row["needsApproval"]))
        }
        let selected = Self.identifier(payload["activeSessionID"])
        activeSessionID = sessions.contains { $0.id == selected } ? selected : nil
        let hub = payload["hub"] as? [String: Any] ?? [:]
        clients = Self.rows(hub["clients"], limit: 32).compactMap { id, row in
            guard row["source"] as? String == "mcp" else { return nil }
            let status = Self.status(row["status"], allowed: ["idle", "busy", "awaiting_user", "error", "exited"])
            let capabilities = row["capabilities"] as? [String: Any] ?? [:]
            // Host ancestry is validated here, but only the client ID crosses the callback boundary.
            let current = row["stale"] == nil || Self.isFalse(row["stale"])
            let canOpen = current && status != "unknown" && status != "exited"
                && Self.flag(capabilities["openHost"]) && Self.validHost(row["host"])
            return Client(id: id, name: Self.label(row["name"], fallback: "MCP client"), status: status, canOpenHost: canOpen)
        }
        providers = Self.rows(hub["providers"], limit: 16).map { id, row in
            Provider(id: id, name: Self.label(row["name"], fallback: "Provider"), available: Self.flag(row["available"]))
        }
    }

    var summary: String {
        guard connected else { return "Andy · Offline" }
        if sessions.contains(where: \.needsApproval) { return "Andy · Approval needed" }
        let working = sessions.filter { $0.status == "thinking" }.count
        if working > 0 { return "Andy · \(working) working" }
        if clients.contains(where: { $0.status == "busy" }) { return "Andy · CUA active" }
        return "Andy · Ready"
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "idle": return "Idle"
        case "thinking": return "Thinking"
        case "done": return "Done"
        case "stopped": return "Stopped"
        case "busy": return "Busy"
        case "awaiting_user": return "Awaiting user"
        case "error": return "Error"
        case "exited": return "Exited"
        default: return "Unknown"
        }
    }

    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
    private static func isFalse(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return !number.boolValue
    }
    private static func identifier(_ value: Any?, limit: Int = 128, colon: Bool = true) -> String? {
        guard let string = value as? String else { return nil }
        let bytes = Array(string.utf8.prefix(limit + 1))
        guard !bytes.isEmpty, bytes.count <= limit, bytes.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95 || (colon && $0 == 58)
        }) else { return nil }
        return string
    }
    private static func label(_ value: Any?, fallback: String) -> String {
        guard let string = value as? String else { return fallback }
        var text = ""
        for scalar in string.unicodeScalars.prefix(256) {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { text.append(" ") }
            else if !CharacterSet.controlCharacters.contains(scalar) && scalar.properties.generalCategory != .format {
                text.unicodeScalars.append(scalar)
            }
        }
        let result = String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
        return result.isEmpty ? fallback : result
    }
    private static func status(_ value: Any?, allowed: Set<String>) -> String {
        guard let string = identifier(value, limit: 32), allowed.contains(string) else { return "unknown" }
        return string
    }
    private static func rows(_ value: Any?, limit: Int) -> [(String, [String: Any])] {
        guard let array = value as? [Any] else { return [] }
        var seen = Set<String>()
        return array.prefix(limit).compactMap { raw in
            guard let row = raw as? [String: Any], let id = identifier(row["id"]), seen.insert(id).inserted else { return nil }
            return (id, row)
        }
    }
    private static func validHost(_ value: Any?) -> Bool {
        guard let host = value as? [String: Any], identifier(host["bundleId"], limit: 200, colon: false) != nil,
              let ancestors = host["ancestors"] as? [Any], !ancestors.isEmpty, ancestors.count <= 32 else { return false }
        return ancestors.allSatisfy { value in
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue.isFinite && number.int32Value > 0 && number.doubleValue == Double(number.int32Value)
        }
    }
}

struct CompanionHubPreferences {
    var reduceMotion: Bool
    var reduceTransparency: Bool
    @MainActor static func current() -> CompanionHubPreferences {
        CompanionHubPreferences(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
}

// The window boundary keeps passive rendering separate from explicit keyboard ownership.
@MainActor protocol CompanionHubSurface: AnyObject {
    func display(frame: CGRect, animate: Bool)
    func focus(_ view: NSView)
    func endInteraction()
    func hide()
    func close()
}

@MainActor private final class CompanionHubPanel: NSPanel {
    var allowsKeyboard = false
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { contentView?.cancelOperation(sender) }
}

@MainActor private final class CompanionHubPanelSurface: CompanionHubSurface {
    private let panel: CompanionHubPanel
    init(contentView: CompanionHubView) {
        panel = CompanionHubPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "Andy Hub"; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = contentView
    }
    func display(frame: CGRect, animate: Bool) {
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: animate) }
        panel.recalculateKeyViewLoop()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func focus(_ view: NSView) {
        panel.allowsKeyboard = true
        panel.makeKey(); panel.makeFirstResponder(view)
    }
    func endInteraction() {
        if panel.isKeyWindow { panel.resignKey() }
        panel.allowsKeyboard = false
    }
    func hide() { endInteraction(); panel.orderOut(nil) }
    func close() { endInteraction(); panel.close() }
}

private enum CompanionHubAction {
    case toggle, expand, collapse, ask
    case openSession(String), stopSession(String), openHost(String)
}

@MainActor private final class CompanionHubButton: NSButton {
    var invoke: (() -> Void)?
    init(_ title: String, id: String) {
        super.init(frame: .zero)
        self.title = title; identifier = NSUserInterfaceItemIdentifier(id)
        bezelStyle = .rounded; setButtonType(.momentaryPushIn); font = .systemFont(ofSize: 12)
        target = self; action = #selector(pressed)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scrollToVisible(bounds) }
        return accepted
    }
    @objc private func pressed() { if isEnabled { invoke?() } }
}

@MainActor private final class CompanionHubMenuAction: NSMenuItem {
    private let invoke: () -> Void
    init(_ title: String, id: String, enabled: Bool = true, invoke: @escaping () -> Void) {
        self.invoke = invoke
        super.init(title: title, action: #selector(pressed), keyEquivalent: "")
        identifier = NSUserInterfaceItemIdentifier(id); isEnabled = enabled; target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func pressed() { if isEnabled { invoke() } }
}

@MainActor private class CompanionHubFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class CompanionHubRow: CompanionHubFlippedView {
    let open: CompanionHubButton, stop: CompanionHubButton
    let name = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
    init(id: String) {
        open = CompanionHubButton("", id: "hub.\(id)")
        stop = CompanionHubButton("Stop", id: "hub.\(id).stop")
        super.init(frame: .zero)
        for field in [name, detail] {
            field.lineBreakMode = .byTruncatingTail; field.usesSingleLineMode = true
            field.font = .systemFont(ofSize: field === name ? 13 : 11)
        }
        detail.textColor = .secondaryLabelColor
        [open, stop, name, detail].forEach(addSubview)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - (stop.isHidden ? 0 : 70))
        open.frame = CGRect(x: 0, y: 0, width: width, height: 28)
        name.frame = CGRect(x: 4, y: 5, width: max(0, width - 8), height: 20)
        stop.frame = CGRect(x: bounds.width - 64, y: 0, width: 64, height: 28)
        detail.frame = CGRect(x: 4, y: 32, width: max(0, bounds.width - 8), height: 18)
    }
}

@MainActor final class CompanionHubView: NSView {
    private let effect = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let document = CompanionHubFlippedView()
    fileprivate let toggle = CompanionHubButton("Andy Hub", id: "hub.toggle")
    private let ask = CompanionHubButton("Ask Andy", id: "hub.ask")
    private var rows: [String: CompanionHubRow] = [:]
    private var elements: [(NSView, CGFloat)] = []
    private var expanded = false, reduceTransparency = false
    fileprivate var onAction: ((CompanionHubAction) -> Void)?
    var contentHeight: CGFloat { 64 + elements.reduce(0) { $0 + $1.1 } }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        effect.material = .hudWindow; effect.blendingMode = .withinWindow; effect.state = .active
        addSubview(effect); addSubview(toggle); addSubview(ask); addSubview(scroll)
        toggle.isBordered = false; toggle.font = .systemFont(ofSize: 13, weight: .medium)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.documentView = document
        toggle.invoke = { [weak self] in self?.onAction?(.toggle) }
        ask.invoke = { [weak self] in self?.onAction?(.ask) }
        setAccessibilityRole(.group); setAccessibilityLabel("Andy companion hub")
    }
    required init?(coder: NSCoder) { nil }
    override func cancelOperation(_ sender: Any?) { onAction?(.collapse) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }
    private func updateBackground() {
        effect.isHidden = reduceTransparency
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        layer?.cornerRadius = expanded ? 14 : 20
    }

    fileprivate func update(_ state: CompanionHubState, expanded: Bool, preferences: CompanionHubPreferences,
                            canAsk: Bool, canOpen: Bool, canStop: Bool, canOpenHost: Bool) {
        self.expanded = expanded; reduceTransparency = preferences.reduceTransparency
        updateBackground()
        toggle.title = state.summary
        toggle.setAccessibilityLabel("\(toggle.title), \(expanded ? "collapse" : "expand") sessions")
        toggle.setAccessibilityExpanded(expanded)
        toggle.setAccessibilityHelp("Show companion sessions and connected CUA clients. Escape collapses the hub.")
        toggle.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        toggle.imagePosition = .imageTrailing
        ask.isHidden = !expanded; ask.isEnabled = canAsk; scroll.isHidden = !expanded

        elements.removeAll()
        var used = Set<String>(), keys: [NSView] = [toggle]
        if expanded && canAsk { keys.append(ask) }
        func text(_ title: String, heading: Bool = false, height: CGFloat = 24) {
            let label = NSTextField(wrappingLabelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: heading ? .semibold : .regular)
            label.textColor = heading ? .labelColor : .secondaryLabelColor
            elements.append((label, height))
        }
        func row(_ key: String, name: String, detail: String, open action: CompanionHubAction?, openID: String,
                 enabled: Bool = true, stop stopAction: CompanionHubAction? = nil, stopID: String = "") {
            let view = rows[key] ?? CompanionHubRow(id: key)
            rows[key] = view; used.insert(key)
            view.name.stringValue = name; view.name.isHidden = action != nil
            view.name.identifier = NSUserInterfaceItemIdentifier("hub.\(key).name")
            view.detail.stringValue = detail
            view.detail.identifier = NSUserInterfaceItemIdentifier("hub.\(key).detail")
            view.open.title = name; view.open.identifier = NSUserInterfaceItemIdentifier(openID)
            view.open.isHidden = action == nil; view.open.isEnabled = enabled
            if case .some(.openHost(_)) = action {
                view.open.title = "Open host · \(name)"
                view.open.setAccessibilityLabel("Open host for \(name)")
            } else {
                view.open.setAccessibilityLabel(action == nil ? name : "Open \(name)")
            }
            view.open.setAccessibilityHelp(detail)
            view.open.invoke = { [weak self] in if let action { self?.onAction?(action) } }
            view.stop.identifier = NSUserInterfaceItemIdentifier(stopID)
            view.stop.isHidden = stopAction == nil; view.stop.isEnabled = stopAction != nil
            view.stop.setAccessibilityLabel("Stop \(name)")
            view.stop.invoke = { [weak self] in if let stopAction { self?.onAction?(stopAction) } }
            view.setAccessibilityLabel("\(name), \(detail)")
            elements.append((view, 56))
            if expanded, action != nil, enabled { keys.append(view.open) }
            if expanded, stopAction != nil { keys.append(view.stop) }
        }
        text("Companions", heading: true)
        if state.sessions.isEmpty { text("No companion sessions") }
        for session in state.sessions {
            let detail = (state.activeSessionID == session.id ? "Selected · " : "") + session.detail
            row("session.\(session.id)", name: session.name, detail: detail,
                open: .openSession(session.id), openID: "hub.session.open.\(session.id)", enabled: state.connected && canOpen,
                stop: state.connected && canStop && session.canStop ? .stopSession(session.id) : nil,
                stopID: "hub.session.stop.\(session.id)")
        }
        text("Connected clients", heading: true)
        if state.clients.isEmpty { text("No connected clients") }
        for client in state.clients {
            row("client.\(client.id)", name: client.name, detail: "CUA activity: \(CompanionHubState.statusLabel(client.status))",
                open: client.canOpenHost && canOpenHost ? .openHost(client.id) : nil,
                openID: "hub.client.open.\(client.id)", enabled: state.connected)
        }
        text("Providers", heading: true)
        if state.providers.isEmpty { text("No provider inventory") }
        for provider in state.providers {
            row("provider.\(provider.id)", name: provider.name, detail: provider.detail, open: nil, openID: "")
        }
        text("Client status is CUA activity, not conversation state.", height: 36)
        for key in Array(rows.keys) where !used.contains(key) { rows.removeValue(forKey: key)?.removeFromSuperview() }
        let retained = Set(elements.map { ObjectIdentifier($0.0) })
        for view in document.subviews where !retained.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        for (view, _) in elements where view.superview !== document { document.addSubview(view) }
        for (index, view) in keys.enumerated() { view.nextKeyView = keys[(index + 1) % keys.count] }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        toggle.frame = CGRect(x: 8, y: 8, width: max(24, bounds.width - (expanded ? 124 : 16)), height: 28)
        ask.frame = CGRect(x: bounds.width - 108, y: 8, width: 100, height: 28)
        scroll.frame = CGRect(x: 10, y: 48, width: max(0, bounds.width - 20), height: max(0, bounds.height - 58))
        scroll.tile()
        let width = scroll.contentSize.width
        document.setFrameSize(CGSize(width: width, height: max(contentHeight - 64, scroll.contentSize.height)))
        var y: CGFloat = 0
        for (view, height) in elements {
            view.frame = CGRect(x: 0, y: y, width: width, height: height)
            view.needsLayout = true; view.layoutSubtreeIfNeeded()
            y += height
        }
    }
}

@MainActor final class CompanionHubController: NSObject {
    var onAsk: (() -> Void)? { didSet { refresh() } }
    var onOpenSession: ((String) -> Void)? { didSet { refresh() } }
    var onStopSession: ((String) -> Void)? { didSet { refresh() } }
    var onOpenHost: ((String) -> Void)? { didSet { refresh() } }
    let contentView = CompanionHubView()
    private(set) var expanded = false
    private var state = CompanionHubState([:])
    private var hasPayload = false, closed = false
    private let screens: @MainActor () -> [CompanionHubScreen]
    private let preferences: @MainActor () -> CompanionHubPreferences
    private let makeSurface: @MainActor (CompanionHubView) -> CompanionHubSurface
    private let notificationCenter: NotificationCenter, workspaceNotifications: NotificationCenter
    private var surface: CompanionHubSurface?
    private var placement: CompanionHubGeometry.Placement?
    private var menuRoot: NSMenuItem?

    init(screens: @escaping @MainActor () -> [CompanionHubScreen] = CompanionHubScreen.current,
         preferences: @escaping @MainActor () -> CompanionHubPreferences = CompanionHubPreferences.current,
         notificationCenter: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         makeSurface: @escaping @MainActor (CompanionHubView) -> CompanionHubSurface = { CompanionHubPanelSurface(contentView: $0) }) {
        self.screens = screens; self.preferences = preferences; self.makeSurface = makeSurface
        self.notificationCenter = notificationCenter; self.workspaceNotifications = workspaceNotifications
        super.init()
        contentView.onAction = { [weak self] in self?.perform($0) }
        notificationCenter.addObserver(self, selector: #selector(reflow), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(reflow), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    deinit { notificationCenter.removeObserver(self); workspaceNotifications.removeObserver(self) }

    func apply(_ payload: [String: Any]) {
        guard !closed else { return }
        state = CompanionHubState(payload); hasPayload = true; refresh()
    }
    @objc func reflow() { refresh() }
    func close() {
        guard !closed else { return }
        closed = true; expanded = false
        notificationCenter.removeObserver(self); workspaceNotifications.removeObserver(self)
        surface?.close(); surface = nil; placement = nil
        contentView.onAction = nil
        updateMenu()
    }
    func makeMenuItem() -> NSMenuItem {
        if menuRoot == nil {
            let item = NSMenuItem(title: "Andy Hub", action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: "Andy Hub"); item.submenu?.autoenablesItems = false
            menuRoot = item
        }
        updateMenu()
        return menuRoot!
    }

    private func refresh(animate: Bool = false) {
        guard !closed else { return }
        updateMenu()
        guard hasPayload else { return }
        let options = preferences()
        contentView.update(state, expanded: expanded, preferences: options, canAsk: onAsk != nil,
            canOpen: onOpenSession != nil, canStop: onStopSession != nil, canOpenHost: onOpenHost != nil)
        let previous = placement
        placement = CompanionHubGeometry.layout(screens: screens(), expanded: expanded, contentHeight: contentView.contentHeight)
        guard let placement else { surface?.hide(); return }
        contentView.setFrameSize(placement.frame.size); contentView.layoutSubtreeIfNeeded()
        if surface == nil { surface = makeSurface(contentView) }
        surface?.display(frame: placement.frame,
            animate: animate && !options.reduceMotion && previous?.screenID == placement.screenID)
    }
    private func collapse() {
        expanded = false; surface?.endInteraction(); refresh()
    }
    private func perform(_ action: CompanionHubAction) {
        guard !closed else { return }
        switch action {
        case .toggle:
            if expanded { collapse() } else { perform(.expand) }
        case .expand:
            hasPayload = true; expanded = true; refresh(animate: true)
            if placement != nil { surface?.focus(contentView.toggle) }
        case .collapse: collapse()
        case .ask:
            guard let onAsk else { return }
            collapse(); onAsk()
        case .openSession(let id):
            guard state.connected, state.sessions.contains(where: { $0.id == id }), let onOpenSession else { return }
            collapse(); onOpenSession(id)
        case .stopSession(let id):
            guard state.connected, state.sessions.contains(where: { $0.id == id && $0.canStop }), let onStopSession else { return }
            onStopSession(id)
        case .openHost(let id):
            guard state.connected, state.clients.contains(where: { $0.id == id && $0.canOpenHost }), let onOpenHost else { return }
            collapse(); onOpenHost(id)
        }
    }
    private func updateMenu() {
        guard let menu = menuRoot?.submenu else { return }
        menu.removeAllItems()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
        }
        func action(_ title: String, _ id: String, _ action: CompanionHubAction, enabled: Bool = true) -> NSMenuItem {
            let item = CompanionHubMenuAction(title, id: id, enabled: enabled) { [weak self] in self?.perform(action) }
            menu.addItem(item); return item
        }
        if closed { info("Andy Hub closed"); return }
        info(state.summary)
        let expand = action("Show sessions", "hub.expand", .expand)
        expand.keyEquivalent = "h"; expand.keyEquivalentModifierMask = [.control, .option]
        if expanded { _ = action("Collapse hub", "hub.collapse", .collapse) }
        _ = action("Ask Andy", "hub.ask", .ask, enabled: onAsk != nil)
        if !state.sessions.isEmpty { menu.addItem(.separator()); info("Companions") }
        for session in state.sessions {
            let open = action("\(session.name) — \(session.detail)", "hub.session.open.\(session.id)", .openSession(session.id), enabled: state.connected && onOpenSession != nil)
            open.state = session.id == state.activeSessionID ? .on : .off
            if session.canStop, onStopSession != nil {
                _ = action("Stop \(session.name)", "hub.session.stop.\(session.id)", .stopSession(session.id), enabled: state.connected)
            }
        }
        if !state.clients.isEmpty { menu.addItem(.separator()); info("Connected clients · CUA activity") }
        for client in state.clients {
            if client.canOpenHost, onOpenHost != nil {
                _ = action("Open \(client.name) host — \(CompanionHubState.statusLabel(client.status))", "hub.client.open.\(client.id)", .openHost(client.id), enabled: state.connected)
            } else { info("\(client.name) — \(CompanionHubState.statusLabel(client.status))") }
        }
        if !state.providers.isEmpty { menu.addItem(.separator()); info("Providers") }
        for provider in state.providers { info("\(provider.name) — \(provider.detail)") }
    }
}
