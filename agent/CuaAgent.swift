import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreImage

// CuaAgent - native-app half of cua. Holds the Accessibility and Screen Recording
// grants (macOS ties both to this binary's code signature, so it is built once
// and left alone). Serves JSON lines on a unix socket.
//
// It never touches the user's cursor or global input:
//  - element clicks are Accessibility actions (AXPress etc.); coordinate clicks,
//    scrolls and drags are mouse events posted to the target process and window
//    only (postToPid), so the user's cursor never moves
//  - text goes in through AXSelectedText; keys, when allowed, are posted to the
//    target process only (CGEvent.postToPid), never to the system event tap
//  - capture uses ScreenCaptureKit window filters, which work while occluded

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let runDir = ProcessInfo.processInfo.environment["CUA_RUN_DIR"] ?? "\(home)/Library/Application Support/cua/run"
let sockPath = "\(runDir)/agent.sock"
let framePath = "\(runDir)/frame.jpg"
let configPath = ProcessInfo.processInfo.environment["CUA_CONFIG"] ?? "\(home)/.config/cua/config.json"

func readConfig() -> [String: Any] {
    guard let d = fm.contents(atPath: configPath),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}
func cfgNumber(_ section: String, _ key: String, _ def: Double) -> Double {
    ((readConfig()[section] as? [String: Any])?[key] as? NSNumber)?.doubleValue ?? def
}

struct AgentError: Error {
    let message: String
    let code: String
    init(_ m: String, code: String = "native_error") { message = m; self.code = code }
}

func requireScreenRecording() throws {
    guard CGPreflightScreenCaptureAccess() else {
        throw AgentError("Screen Recording is not granted. Run cua permissions screen-recording, then grant CuaAgent in System Settings. Capture will not request permission automatically.", code: "permission_denied")
    }
}
var requestedPermissions = Set<String>()

// MARK: - Accessibility helpers

func ax(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}
func axString(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = ax(el, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func axBool(_ el: AXUIElement, _ name: String) -> Bool? { (ax(el, name) as? NSNumber)?.boolValue }
func axChildren(_ el: AXUIElement) -> [AXUIElement] { (ax(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = ax(el, kAXPositionAttribute), let s = ax(el, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
@discardableResult
func axPerform(_ el: AXUIElement, _ action: String) -> Bool { AXUIElementPerformAction(el, action as CFString) == .success }
@discardableResult
func axSet(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
    AXUIElementSetAttributeValue(el, name as CFString, value) == .success
}

let ROLE_NAMES: [String: String] = [
    "AXStaticText": "text", "AXTextField": "textbox", "AXTextArea": "textbox", "AXSecureTextField": "password",
    "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "popup",
    "AXMenuButton": "menubutton", "AXComboBox": "combobox", "AXSlider": "slider", "AXRow": "row", "AXCell": "cell",
    "AXImage": "image", "AXLink": "link", "AXWindow": "window", "AXSheet": "sheet", "AXDialog": "dialog",
    "AXGroup": "group", "AXScrollArea": "scrollarea", "AXOutline": "outline", "AXTable": "table", "AXList": "list",
    "AXToolbar": "toolbar", "AXMenuItem": "menuitem", "AXMenuBarItem": "menu", "AXMenu": "menu", "AXWebArea": "webarea",
    "AXHeading": "heading", "AXDisclosureTriangle": "disclosure", "AXIncrementor": "stepper",
    "AXProgressIndicator": "progress", "AXTabGroup": "tabs", "AXColumn": "column", "AXBrowser": "browser",
    "AXCollection": "collection", "AXSegmentedControl": "segmented", "AXColorWell": "colorwell",
    "AXDateField": "datefield", "AXLevelIndicator": "level", "AXSplitGroup": "splitgroup",
]
let SKIP_ROLES: Set<String> = ["AXScrollBar", "AXValueIndicator", "AXSplitter", "AXGrowArea", "AXMatte", "AXRuler", "AXLayoutArea"]
let FLATTEN_ROLES: Set<String> = ["AXGroup", "AXSplitGroup", "AXLayoutItem", "AXUnknown", "AXColumn"]
let QUIET_ACTIONS: Set<String> = ["AXPress", "AXShowDefaultUI", "AXScrollToVisible", "AXShowAlternateUI", "AXConfirm", "AXCancel", "AXRaise"]

final class Table {
    let generation = UUID().uuidString
    var pid: pid_t = 0
    var process = ""
    var windowElement: AXUIElement?
    let created = Date()
    var items: [AXUIElement] = []
    var window: CGRect = .zero
    var windowID: CGWindowID?
}
var tables: [String: Table] = [:]
let axQueue = DispatchQueue(label: "cua.ax")

func appElement(_ pid: pid_t) -> AXUIElement {
    let a = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(a, 2.0)
    return a
}

// Electron and Chromium apps only build their accessibility tree when an assistive
// client asks for it. AXManualAccessibility is Electron's switch; AXEnhancedUserInterface
// is Chromium's, set only for those apps since it slows window animations elsewhere.
var axEnabled = Set<String>()
func enableAppAX(_ pid: pid_t) -> Bool {
    let identity = "\(pid):\(NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970 ?? 0)"
    guard !axEnabled.contains(identity) else { return false }
    axEnabled.insert(identity)
    let app = appElement(pid)
    let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    let fw = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Frameworks").path
    let chromium = fw.flatMap { try? fm.contentsOfDirectory(atPath: $0) }?.contains { $0.contains("Electron") || $0.contains("Chrom") || $0.contains("Edge") } ?? false
    if chromium { axSet(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
    return manual || chromium
}

/// macOS answers Accessibility with nothing while the screen is locked: say so instead of
/// reporting an app with no windows.
func requireUnlocked() throws {
    if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
        throw AgentError("The screen is locked, so apps can't be read or driven; unlock the Mac and try again", code: "screen_locked")
    }
}

@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
func windowID(of el: AXUIElement) -> CGWindowID? {
    let win = axString(el, kAXRoleAttribute) == "AXWindow" ? el : ax(el, kAXWindowAttribute).map { $0 as! AXUIElement }
    var w: CGWindowID = 0
    guard let x = win, _AXUIElementGetWindow(x, &w) == .success, w != 0 else { return nil }
    return w
}

// Mouse events go to one process and name its window, so a background window takes
// them like a real click without the app being activated or the cursor moving.
func postMouse(pid: pid_t, _ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, window: CGWindowID?, clickState: Int = 1) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    if let w = window {
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w))
    }
    e.postToPid(pid)
}
func eventClick(pid: pid_t, at p: CGPoint, window: CGWindowID?, button: String, count: Int) {
    let (down, up, b): (CGEventType, CGEventType, CGMouseButton) = button.hasPrefix("r") ? (.rightMouseDown, .rightMouseUp, .right)
        : button.hasPrefix("m") ? (.otherMouseDown, .otherMouseUp, .center) : (.leftMouseDown, .leftMouseUp, .left)
    postMouse(pid: pid, .mouseMoved, at: p, window: window, clickState: 0)
    usleep(20_000)
    for n in 1...max(1, count) {
        postMouse(pid: pid, down, at: p, button: b, window: window, clickState: n); usleep(30_000)
        postMouse(pid: pid, up, at: p, button: b, window: window, clickState: n); usleep(40_000)
    }
}
/// Real click at an element's centre, for elements Accessibility can't press.
func eventClick(_ el: AXUIElement, button: String, count: Int) throws {
    guard let f = axFrame(el), f.width > 0 else { throw AgentError("Element has no on-screen frame to click") }
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    eventClick(pid: pid, at: CGPoint(x: f.midX, y: f.midY), window: windowID(of: el), button: button, count: count)
}
func eventScroll(pid: pid_t, at p: CGPoint, window: CGWindowID?, direction: String, pixels: Double) {
    let sign: Int32 = direction.hasPrefix("u") || direction.hasPrefix("l") ? 1 : -1
    let horizontal = direction.hasPrefix("l") || direction.hasPrefix("r")
    postMouse(pid: pid, .mouseMoved, at: p, window: window, clickState: 0)
    let steps = 10, step = Int32(pixels / Double(steps))
    for _ in 0..<steps {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: horizontal ? 0 : sign * step, wheel2: horizontal ? sign * step : 0, wheel3: 0) else { continue }
        e.location = p
        if let w = window { e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w)) }
        e.postToPid(pid); usleep(12_000)
    }
}

func processIdentity(_ pid: pid_t) throws -> String {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
          let launch = app.launchDate else { throw AgentError("Target process is gone; resolve the app again", code: "stale_target") }
    return "\(pid):\(launch.timeIntervalSince1970)"
}

func checkProcess(_ pid: pid_t, _ expected: String?) throws {
    guard let expected = expected, try processIdentity(pid) == expected else {
        throw AgentError("Process identity changed or was not supplied; resolve the app again", code: "stale_target")
    }
}

func windows(_ pid: pid_t) throws -> [[String: Any]] {
    guard AXIsProcessTrusted() else { throw AgentError("Accessibility is not granted; run cua permissions accessibility", code: "permission_denied") }
    try requireUnlocked()
    let identity = try processIdentity(pid)
    if enableAppAX(pid) { usleep(500_000) }
    return ((ax(appElement(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []).compactMap { w in
        guard let id = windowID(of: w), let f = axFrame(w) else { return nil }
        return ["pid": Int(pid), "process": identity, "windowId": Int(id), "title": axString(w, kAXTitleAttribute) ?? "",
                "minimized": axBool(w, kAXMinimizedAttribute) ?? false,
                "frame": ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height]]
    }
}

func selectedWindow(_ pid: pid_t, _ id: CGWindowID?) throws -> AXUIElement {
    try requireUnlocked()
    let list = (ax(appElement(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if let id = id {
        guard let w = list.first(where: { windowID(of: $0) == id }) else {
            throw AgentError("Selected window closed; list windows and choose again", code: "stale_target")
        }
        return w
    }
    guard list.count == 1 else {
        throw AgentError("Choose a windowId from windows(): this app has \(list.count) windows", code: "ambiguous_target")
    }
    return list[0]
}

func checkedTable(_ pid: pid_t, _ gen: String?) throws -> Table {
    guard let gen = gen, let t = tables[gen], t.pid == pid, Date().timeIntervalSince(t.created) < 600 else {
        throw AgentError("Read the selected window first; the snapshot is missing or expired", code: "stale_snapshot")
    }
    try checkProcess(pid, t.process)
    let w = try selectedWindow(pid, t.windowID)
    guard let old = t.windowElement, CFEqual(w, old), axFrame(w) == t.window,
          axBool(w, kAXMinimizedAttribute) != true else {
        throw AgentError("Window changed or was minimized; read it again before acting", code: "stale_snapshot")
    }
    return t
}

func keyboardTarget(_ pid: pid_t, _ t: Table) throws {
    guard let w = t.windowElement else { throw AgentError("No selected window") }
    let app = appElement(pid)
    if ax(app, kAXFocusedWindowAttribute).map({ CFEqual($0, w) }) != true {
        axSet(w, kAXMainAttribute, kCFBooleanTrue)
        axSet(app, kAXFocusedWindowAttribute, w)
    }
    guard ax(app, kAXFocusedWindowAttribute).map({ CFEqual($0, w) }) == true else {
        throw AgentError("This app cannot route keyboard input to the selected background window. Focus that window yourself, or use setValue on an element. No keys were sent.", code: "keyboard_target_unavailable")
    }
}

func snapshot(pid: pid_t, window: CGWindowID?, maxDepth: Int) throws -> [String: Any] {
    guard AXIsProcessTrusted() else { throw AgentError("Accessibility access is not granted to CuaAgent (System Settings > Privacy & Security > Accessibility)", code: "permission_denied") }
    if enableAppAX(pid) { usleep(500_000) }    // give Chromium a moment to build the tree
    let app = appElement(pid)
    let table = Table()
    table.pid = pid
    table.process = try processIdentity(pid)
    table.items = []
    var entries: [[String: Any]] = []
    let focusedEl = ax(app, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
    var focusedIndex: Int? = nil
    let maxEntries = Int(cfgNumber("native", "maxLines", 500)) * 2

    func walk(_ el: AXUIElement, _ depth: Int, _ parentName: String) {
        if depth > maxDepth || entries.count >= maxEntries { return }
        let rawRole = axString(el, kAXRoleAttribute) ?? "AXUnknown"
        if SKIP_ROLES.contains(rawRole) { return }
        let subrole = axString(el, kAXSubroleAttribute)
        var role = ROLE_NAMES[rawRole] ?? rawRole.replacingOccurrences(of: "AX", with: "").lowercased()
        if subrole == "AXSearchField" { role = "searchbox" }
        if subrole == "AXTabButton" { role = "tab" }
        let title = axString(el, kAXTitleAttribute)
        let desc = axString(el, kAXDescriptionAttribute)
        let secure = rawRole == "AXSecureTextField" || subrole == "AXSecureTextField"
        let valueObj = secure ? nil : ax(el, kAXValueAttribute)
        var name = title ?? desc ?? axString(el, kAXPlaceholderValueAttribute) ?? ""
        var value: String? = nil
        if rawRole == "AXStaticText" { name = axString(el, kAXValueAttribute) ?? name }
        else if let s = valueObj as? String, !s.isEmpty { value = s }
        else if let n = valueObj as? NSNumber, !["AXCheckBox", "AXRadioButton"].contains(rawRole) { value = n.stringValue }
        name = name.replacingOccurrences(of: "\n", with: " ")
        if name.count > 120 { name = String(name.prefix(119)) + "…" }
        if let v = value, v.count > 120 { value = String(v.prefix(119)) + "…" }

        let isFocused = focusedEl.map { CFEqual($0, el) } ?? false
        var states: [String] = []
        if isFocused { states.append("focused") }
        if ["AXCheckBox", "AXRadioButton"].contains(rawRole), let n = valueObj as? NSNumber { if n.intValue == 1 { states.append("checked") } }
        if axBool(el, kAXSelectedAttribute) == true { states.append("selected") }
        if axBool(el, kAXExpandedAttribute) == true { states.append("expanded") }
        if axBool(el, kAXEnabledAttribute) == false { states.append("disabled") }
        let extra = axActions(el).filter { !QUIET_ACTIONS.contains($0) && !$0.hasPrefix("AXScroll") || $0.hasPrefix("AXScroll") && rawRole == "AXScrollArea" }

        let hasName = !name.isEmpty || value != nil
        let flatten = FLATTEN_ROLES.contains(rawRole) && !hasName && extra.isEmpty
        let emit: Bool
        if rawRole == "AXStaticText" { emit = !name.isEmpty && name != parentName }
        else { emit = !flatten && (hasName || !FLATTEN_ROLES.contains(rawRole)) }

        if emit {
            var parts = [role]
            if !name.isEmpty { parts.append("\"\(name)\"") }
            if let v = value { parts.append("value=\"\(v)\"") }
            if !states.isEmpty { parts.append("(\(states.joined(separator: ", ")))") }
            if !extra.isEmpty { parts.append("[actions: \(extra.joined(separator: " "))]") }
            if rawRole == "AXStaticText" { parts = ["text", "\"\(name)\""] }
            table.items.append(el)
            entries.append(["indent": depth, "text": parts.joined(separator: " "), "ref": table.items.count - 1])
            if isFocused { focusedIndex = entries.count - 1 }
        }
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"].contains(rawRole) { return }
        for c in axChildren(el) { walk(c, emit ? depth + 1 : depth, emit ? name : parentName) }
    }

    let win = try selectedWindow(pid, window)
    guard axBool(win, kAXMinimizedAttribute) != true else { throw AgentError("Selected window is minimized", code: "window_unavailable") }
    table.window = axFrame(win) ?? .zero
    table.windowID = windowID(of: win)
    table.windowElement = win
    guard table.windowID != nil, table.window.width > 0, table.window.height > 0 else { throw AgentError("Window has no usable frame") }
    walk(win, 0, "")
    // open context menus hang off the app element
    for c in axChildren(app) where axString(c, kAXRoleAttribute) == "AXMenu" { walk(c, 0, "") }
    // menu bar: top level, plus the contents of whichever menu is open
    for (attr, label) in [(kAXMenuBarAttribute, "menubar"), ("AXExtrasMenuBar", "status items")] {
        guard let bar = ax(app, attr) else { continue }
        let barEl = bar as! AXUIElement
        table.items.append(barEl)
        entries.append(["indent": 0, "text": label, "ref": table.items.count - 1])
        for item in axChildren(barEl) {
            let t = axString(item, kAXTitleAttribute) ?? axString(item, kAXDescriptionAttribute) ?? ""
            if t.isEmpty && attr == kAXMenuBarAttribute { continue }
            table.items.append(item)
            entries.append(["indent": 1, "text": "menu \"\(t)\"", "ref": table.items.count - 1])
            if axBool(item, kAXSelectedAttribute) == true { for m in axChildren(item) { walk(m, 2, t) } }
        }
    }
    tables = tables.filter { Date().timeIntervalSince($0.value.created) < 600 }
    if tables.count >= 512, let oldest = tables.min(by: { $0.value.created < $1.value.created }) { tables.removeValue(forKey: oldest.key) }
    tables[table.generation] = table
    var out: [String: Any] = ["generation": table.generation, "entries": entries, "title": axString(win, kAXTitleAttribute) ?? "",
                              "process": table.process, "windowId": Int(table.windowID!),
                              "window": ["x": table.window.minX, "y": table.window.minY, "w": table.window.width, "h": table.window.height]]
    if let f = focusedIndex { out["focused"] = f }
    return out
}

func element(_ pid: pid_t, _ gen: String?, _ index: Int) throws -> AXUIElement {
    let t = try checkedTable(pid, gen)
    let i = index - 1
    guard i >= 0, i < t.items.count else { throw AgentError("Element \(index) is not in the last read") }
    return t.items[i]
}

func center(_ pid: pid_t, _ gen: String?, _ el: AXUIElement) -> [String: Double]? {
    guard let gen = gen, let t = tables[gen], t.pid == pid, let f = axFrame(el), t.window.width > 0 else { return nil }
    return ["x": Double((f.midX - t.window.minX) / t.window.width), "y": Double((f.midY - t.window.minY) / t.window.height)]
}

func press(_ el: AXUIElement) throws {
    let acts = axActions(el)
    for a in ["AXPress", "AXConfirm", "AXPick", "AXOpen"] where acts.contains(a) { if axPerform(el, a) { return } }
    if axSet(el, kAXSelectedAttribute, kCFBooleanTrue) { return }
    if axPerform(el, "AXPress") { return }
    throw AgentError("Element does not accept a press. Available actions: \(acts.joined(separator: ", "))")
}

// MARK: - passive exact lookup

struct LookupFailure: Error {
    let status: String
    let message: String
    init(_ status: String, _ message: String) { self.status = status; self.message = message }
}

struct LookupQuery {
    let pid: pid_t
    let process: String
    let windowID: CGWindowID?
    let name: String
    let role: String?

    init(_ request: [String: Any]) throws {
        func integer(_ key: String, _ upper: Double) throws -> UInt32 {
            guard let n = request[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                  n.doubleValue > 0, n.doubleValue <= upper else {
                throw LookupFailure("unavailable", "Lookup needs a valid \(key).")
            }
            return n.uint32Value
        }
        let p = try integer("pid", Double(Int32.max))
        guard p > 1, let identity = request["process"] as? String, identity.utf8.count <= 128,
              identity.hasPrefix("\(p):"), let launch = Double(identity.dropFirst("\(p):".count)),
              launch.isFinite, launch > 0 else {
            throw LookupFailure("unavailable", "Lookup needs the running process's pid:launchDateSeconds identity.")
        }
        guard let name = request["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf16.count <= 512 else {
            throw LookupFailure("unavailable", "Lookup needs an exact name of 1 to 512 UTF-16 units.")
        }
        var role: String?
        if let value = request["role"], !(value is NSNull) {
            guard let r = value as? String, Set(ROLE_NAMES.values).union(["searchbox", "tab"]).contains(r) else {
                throw LookupFailure("unavailable", "Use a supported native role such as button, textbox, or menuitem.")
            }
            role = r
        }
        self.pid = pid_t(p); self.process = identity; self.name = name; self.role = role
        if let value = request["windowId"], !(value is NSNull) {
            self.windowID = try integer("windowId", Double(UInt32.max))
        } else { self.windowID = nil }
    }
}

func lookupRole(_ raw: String, _ subrole: String?) -> String {
    if subrole == "AXSearchField" { return "searchbox" }
    if subrole == "AXTabButton" { return "tab" }
    return ROLE_NAMES[raw] ?? raw.replacingOccurrences(of: "AX", with: "").lowercased()
}

struct LookupCandidate {
    let name: String
    let role: String
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let enabled: Bool?
    let secure: Bool
    let hidden: Bool
}

struct LookupMatch: Equatable {
    let name: String
    let role: String
    let windowID: CGWindowID
    let rect: CGRect
    var metadata: [String: Any] {
        var result: [String: Any] = ["name": String(name.prefix(120)), "role": role, "windowId": Int(windowID)]
        if name.count > 120 { result["nameTruncated"] = true }
        return result
    }
}

func lookupPositiveRect(_ rect: CGRect) -> Bool {
    [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rect.maxX, rect.maxY].allSatisfy { $0.isFinite }
        && rect.size.width > 0 && rect.size.height > 0
}

func lookupOcclusionMessage(_ owner: String?) -> String {
    let scalars = (owner ?? "").unicodeScalars.prefix(80).filter {
        !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
    }
    let name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    let subject = name.isEmpty ? "Another window" : "A window from \(name.debugDescription)"
    return "\(subject) overlaps this target. Dismiss that panel or select a visible area."
}

func lookupMatch(_ candidate: LookupCandidate, query: LookupQuery, windowID: CGWindowID, window: CGRect,
                 clips: [CGRect], displays: [CGRect], occluders: [CGRect], occluderNames: [String] = []) throws -> LookupMatch? {
    guard !candidate.secure, !candidate.hidden, candidate.enabled != false else { return nil }
    guard query.role == nil || query.role == candidate.role else { return nil }
    guard candidate.name.utf16.count <= 512 else {
        throw LookupFailure("incomplete", "An accessibility name exceeds the lookup limit; uniqueness is unknown.")
    }
    guard candidate.name == query.name else { return nil }
    guard candidate.pid == query.pid, candidate.windowID == windowID,
          query.windowID == nil || query.windowID == windowID else {
        throw LookupFailure("incomplete", "Target ownership or its selected window could not be verified.")
    }
    guard candidate.enabled == true else { throw LookupFailure("incomplete", "The exact target's enabled state is unavailable.") }
    let frame = candidate.frame
    guard lookupPositiveRect(frame), lookupPositiveRect(window), window.contains(frame),
          clips.allSatisfy({ lookupPositiveRect($0) && $0.contains(frame) }),
          displays.contains(where: { lookupPositiveRect($0) && $0.contains(frame) }) else { return nil }
    // Window bounds are deliberately conservative, including transparent/irregular windows.
    // AX hit tests below supplement this check; neither is a pixel-visibility guarantee.
    if let index = occluders.firstIndex(where: { $0.intersects(frame) }) {
        throw LookupFailure("incomplete", lookupOcclusionMessage(occluderNames.indices.contains(index) ? occluderNames[index] : nil))
    }
    return LookupMatch(name: candidate.name, role: candidate.role, windowID: windowID,
                       rect: CGRect(x: (frame.minX - window.minX) / window.width, y: (frame.minY - window.minY) / window.height,
                                    width: frame.width / window.width, height: frame.height / window.height))
}

func lookupResult(_ matches: [LookupMatch], incomplete: String?) -> [String: Any] {
    if incomplete == nil, matches.count == 1, let match = matches.first {
        return ["status": "matched", "name": match.name, "role": match.role, "windowId": Int(match.windowID),
                "target": ["windowId": Int(match.windowID), "rect": ["x": Double(match.rect.minX), "y": Double(match.rect.minY),
                                                                     "w": Double(match.rect.width), "h": Double(match.rect.height)]]]
    }
    let status = incomplete != nil ? "incomplete" : matches.isEmpty ? "not_found" : "ambiguous"
    let message = incomplete ?? (matches.isEmpty ? "No visible, enabled exact match in the exposed window accessibility tree."
                                                : "More than one visible exact match; specify a role or a more specific name.")
    var result: [String: Any] = ["status": status, "message": String(message.prefix(240))]
    if !matches.isEmpty { result["candidates"] = matches.prefix(8).map { $0.metadata } }
    return result
}

// The snapshot helpers intentionally hide AX errors and truncate labels for display. Lookup
// must retain those failures. All AX reads share a monotonic deadline and per-message timeout;
// arrays are counted before copying, and no enabling/focusing/input helpers are called.
final class LookupReader {
    let deadline = ProcessInfo.processInfo.systemUptime + 1.5
    let maxNodes = 2048
    let maxDepth = 48
    var visited = Set<AXUIElement>()

    func checkTime() throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw LookupFailure("incomplete", "Accessibility lookup reached its time limit; uniqueness is unknown.")
        }
    }
    func prepare(_ element: AXUIElement) throws {
        try checkTime()
        var owner: pid_t = 0
        // System-wide objects would change this helper's global timeout, including other commands.
        guard AXUIElementGetPid(element, &owner) == .success, owner > 1 else {
            throw LookupFailure("incomplete", "Bounded lookup requires an application-owned accessibility object.")
        }
        let timeout = Float(max(0.001, min(0.08, deadline - ProcessInfo.processInfo.systemUptime)))
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else {
            throw LookupFailure("incomplete", "Accessibility read timeout could not be bounded.")
        }
    }
    func checked(_ error: AXError, optional: Bool = false) throws -> Bool {
        try checkTime()
        if error == .success { return true }
        if optional && (error == .attributeUnsupported || error == .noValue) { return false }
        throw LookupFailure(error == .apiDisabled ? "unavailable" : "incomplete",
                            "Accessibility read failed (\(error.rawValue)); the search is not complete.")
    }
    func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        try prepare(element)
        var value: CFTypeRef?
        guard try checked(AXUIElementCopyAttributeValue(element, attribute as CFString, &value), optional: true) else { return nil }
        guard let value = value else { throw LookupFailure("incomplete", "Accessibility returned an invalid attribute value.") }
        return value
    }
    func string(_ element: AXUIElement, _ attribute: String) throws -> String? {
        guard let value = try value(element, attribute) else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            guard CFStringGetLength((value as! CFString)) <= 512 else {
                throw LookupFailure("incomplete", "An accessibility name exceeds the lookup limit; uniqueness is unknown.")
            }
            let text = value as! String
            return text.isEmpty ? nil : text
        }
        if let number = value as? NSNumber { return number.stringValue }
        throw LookupFailure("incomplete", "Accessibility returned a non-text name or role.")
    }
    func bool(_ element: AXUIElement, _ attribute: String) throws -> Bool? {
        guard let value = try value(element, attribute) else { return nil }
        guard let number = value as? NSNumber, number.doubleValue == 0 || number.doubleValue == 1 else {
            throw LookupFailure("incomplete", "Accessibility returned an invalid visibility or enabled state.")
        }
        return number.boolValue
    }
    func element(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement? {
        guard let value = try value(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw LookupFailure("incomplete", "Accessibility returned an invalid owner or parent.") }
        return (value as! AXUIElement)
    }
    func elements(_ element: AXUIElement, _ attribute: String, limit: Int, optional: Bool = true) throws -> [AXUIElement] {
        try prepare(element)
        var count: CFIndex = 0
        guard try checked(AXUIElementGetAttributeValueCount(element, attribute as CFString, &count), optional: optional) else { return [] }
        guard count >= 0, count <= limit else { throw LookupFailure("incomplete", "Accessibility traversal limit reached; uniqueness is unknown.") }
        if count == 0 { return [] }
        try prepare(element)
        var values: CFArray?
        _ = try checked(AXUIElementCopyAttributeValues(element, attribute as CFString, 0, count, &values))
        guard let array = values as? [AnyObject], array.count == count,
              array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
            throw LookupFailure("incomplete", "Accessibility children changed or could not be fully read.")
        }
        try prepare(element)
        var after: CFIndex = 0
        _ = try checked(AXUIElementGetAttributeValueCount(element, attribute as CFString, &after))
        guard after == count else { throw LookupFailure("incomplete", "Accessibility children changed during the search.") }
        return array.map { $0 as! AXUIElement }
    }
    func frame(_ element: AXUIElement) throws -> CGRect? {
        guard let position = try value(element, kAXPositionAttribute), let size = try value(element, kAXSizeAttribute) else { return nil }
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw LookupFailure("incomplete", "Accessibility returned invalid geometry.")
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
            throw LookupFailure("incomplete", "Accessibility geometry could not be read.")
        }
        return CGRect(origin: point, size: dimensions)
    }
    func pid(_ element: AXUIElement) throws -> pid_t {
        try prepare(element)
        var pid: pid_t = 0
        _ = try checked(AXUIElementGetPid(element, &pid))
        return pid
    }
    func windowID(_ window: AXUIElement) throws -> CGWindowID {
        try prepare(window)
        var id: CGWindowID = 0
        _ = try checked(_AXUIElementGetWindow(window, &id))
        guard id != 0 else { throw LookupFailure("incomplete", "Accessibility window identity is unavailable.") }
        return id
    }
    func state(_ element: AXUIElement) throws -> (raw: String, role: String, secure: Bool, enabled: Bool?, hidden: Bool) {
        guard let raw = try string(element, kAXRoleAttribute) else { throw LookupFailure("incomplete", "Accessibility role is unavailable.") }
        let subrole = try string(element, kAXSubroleAttribute)
        return (raw, lookupRole(raw, subrole), raw == "AXSecureTextField" || subrole == "AXSecureTextField",
                try bool(element, kAXEnabledAttribute), try bool(element, "AXHidden") == true)
    }
    func name(_ element: AXUIElement, rawRole: String) throws -> String {
        if rawRole == "AXStaticText", let text = try string(element, kAXValueAttribute) { return text }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            if let text = try string(element, attribute) { return text }
        }
        return ""
    }
    func ownedWindow(_ element: AXUIElement, window: AXUIElement, id: CGWindowID, pid: pid_t) throws {
        guard try self.pid(element) == pid else { throw LookupFailure("incomplete", "Accessibility target belongs to a different process.") }
        let owner = CFEqual(element, window) ? window : try self.element(element, kAXWindowAttribute)
        guard let owner = owner, CFEqual(owner, window), try self.windowID(owner) == id else {
            throw LookupFailure("incomplete", "Accessibility target's exact window ownership is unavailable.")
        }
    }
    func hitTest(_ element: AXUIElement, frame: CGRect, pid: pid_t) throws {
        // AX bounds can include a bezel outside the control's hit region. Verify the cursor anchor.
        let application = appElement(pid)
        try prepare(application)
        var hit: AXUIElement?
        _ = try checked(AXUIElementCopyElementAtPosition(application, Float(frame.midX), Float(frame.midY), &hit))
        var seen = Set<AXUIElement>()
        for _ in 0...maxDepth {
            guard let current = hit, seen.insert(current).inserted, try self.pid(current) == pid else { break }
            if CFEqual(current, element) { return }
            hit = try self.element(current, kAXParentAttribute)
        }
        throw LookupFailure("incomplete", "The exact target's cursor anchor could not be verified by passive accessibility hit testing.")
    }
}

func lookupOverlayWindowIDs(_ record: [String: Any], pid: pid_t, process: String, executable: String, trustedExecutable: String) -> Set<CGWindowID> {
    guard executable == trustedExecutable, pid > 1,
          let version = record["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
          let owner = record["pid"] as? NSNumber, CFGetTypeID(owner) != CFBooleanGetTypeID(), owner.doubleValue == Double(pid),
          record["process"] as? String == process,
          let values = record["windows"] as? [NSNumber], !values.isEmpty, values.count <= 16,
          values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue.rounded() == $0.doubleValue && $0.doubleValue > 0 && $0.doubleValue <= Double(UInt32.max) }) else { return [] }
    let ids = Set(values.map { $0.uint32Value })
    return ids.count == values.count ? ids : []
}

func lookupGuideOverlay() -> (pid: pid_t, windows: Set<CGWindowID>)? {
    let fd = open("\(runDir)/pointer-windows.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 8192 else { return nil }
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
    let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    guard count == bytes.count, let record = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
          let owner = record["pid"] as? NSNumber, owner.doubleValue > 1, owner.doubleValue <= Double(Int32.max),
          let identity = try? processIdentity(owner.int32Value),
          let actual = NSRunningApplication(processIdentifier: owner.int32Value)?.executableURL else { return nil }
    let app = ProcessInfo.processInfo.environment["CUA_HUD_APP"].map { URL(fileURLWithPath: $0) }
        ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("CuaPreview.app")
    let trusted = app.appendingPathComponent("Contents/MacOS/CuaPreview").resolvingSymlinksInPath().standardizedFileURL.path
    let ids = lookupOverlayWindowIDs(record, pid: owner.int32Value, process: identity,
                                    executable: actual.resolvingSymlinksInPath().standardizedFileURL.path, trustedExecutable: trusted)
    return ids.isEmpty ? nil : (owner.int32Value, ids)
}

func lookupIsGuideWindow(_ info: [String: Any], overlay: (pid: pid_t, windows: Set<CGWindowID>)?) -> Bool {
    guard let overlay = overlay, (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == overlay.pid,
          (info[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.screenSaverWindow)),
          let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return false }
    return overlay.windows.contains(id)
}

func lookupVisibility(_ reader: LookupReader, pid: pid_t, windowID: CGWindowID, frame: CGRect) throws -> (displays: [CGRect], occluders: [CGRect], occluderNames: [String]) {
    try reader.checkTime()
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
          windows.count <= 512 else { throw LookupFailure("incomplete", "Visible window metadata is unavailable or exceeds the lookup limit.") }
    guard let index = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
          (windows[index][kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else {
        throw LookupFailure("unavailable", "The selected window is not on the current visible desktop or its ownership changed.")
    }
    func bounds(_ info: [String: Any]) throws -> CGRect {
        guard let data = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: data as CFDictionary), lookupPositiveRect(rect) else {
            throw LookupFailure("incomplete", "Visible window bounds are unavailable.")
        }
        return rect
    }
    guard let alpha = windows[index][kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
          try bounds(windows[index]) == frame else { throw LookupFailure("incomplete", "Selected window visibility or geometry changed.") }
    var occluders: [CGRect] = [], occluderNames: [String] = []
    let overlay = lookupGuideOverlay()
    for info in windows.prefix(index) {
        // Our guide marks are output, not document occlusion. Other local windows remain blockers.
        if lookupIsGuideWindow(info, overlay: overlay) { continue }
        guard let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue.isFinite else {
            throw LookupFailure("incomplete", "A higher window's visibility is unavailable.")
        }
        if alpha.doubleValue > 0 {
            let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let name = info[kCGWindowOwnerName as String] as? String ?? owner.flatMap { $0 > 1 ? NSRunningApplication(processIdentifier: $0)?.localizedName : nil } ?? ""
            occluders.append(try bounds(info)); occluderNames.append(name)
        }
    }
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 16 else {
        throw LookupFailure("unavailable", "Active display geometry is unavailable.")
    }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count)), actual: UInt32 = 0
    guard CGGetActiveDisplayList(count, &displays, &actual) == .success, actual == count else {
        throw LookupFailure("incomplete", "Active displays changed during lookup.")
    }
    try reader.checkTime()
    return (displays.map { CGDisplayBounds($0) }, occluders, occluderNames)
}

func lookup(_ request: [String: Any]) -> [String: Any] {
    var matches: [LookupMatch] = []
    do {
        let query = try LookupQuery(request), reader = LookupReader()
        func preflight() throws {
            guard AXIsProcessTrusted() else { throw LookupFailure("unavailable", "Accessibility permission is not granted; lookup never requests it.") }
            guard CGSessionCopyCurrentDictionary() != nil else { throw LookupFailure("unavailable", "The current login/lock state is unavailable.") }
            try requireUnlocked()
            try checkProcess(query.pid, query.process)
            guard NSRunningApplication(processIdentifier: query.pid)?.isHidden == false else {
                throw LookupFailure("unavailable", "The target application is hidden or no longer running.")
            }
            try reader.checkTime()
        }
        try preflight()
        let app = appElement(query.pid)
        let windows = try reader.elements(app, kAXWindowsAttribute, limit: 64, optional: false)
        if windows.isEmpty {
            try preflight()
            if query.windowID != nil { throw LookupFailure("unavailable", "The exact selected window is no longer available.") }
            return lookupResult([], incomplete: nil)
        }
        if query.windowID == nil && windows.count != 1 {
            let ids = try windows.prefix(8).map { ["windowId": Int(try reader.windowID($0))] }
            try preflight()
            return ["status": "ambiguous", "message": "Choose an exact windowId; the running application has multiple windows.", "candidates": ids]
        }
        var selected: AXUIElement?
        for window in windows {
            if try query.windowID == nil || reader.windowID(window) == query.windowID { selected = window; break }
        }
        guard let window = selected else { throw LookupFailure("unavailable", "The exact selected window is no longer available.") }
        let id = try reader.windowID(window)
        try reader.ownedWindow(window, window: window, id: id, pid: query.pid)
        guard try reader.bool(window, kAXMinimizedAttribute) == false, let frame = try reader.frame(window), lookupPositiveRect(frame) else {
            throw LookupFailure("unavailable", "The selected window is minimized or has no usable visible frame.")
        }
        var visibility = try lookupVisibility(reader, pid: query.pid, windowID: id, frame: frame)
        var elements: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int, ancestors: Set<AXUIElement>, clips: [CGRect]) throws {
            try reader.checkTime()
            guard depth <= reader.maxDepth, !ancestors.contains(element) else { throw LookupFailure("incomplete", "Accessibility depth limit or a cyclic tree prevents a complete search.") }
            guard !reader.visited.contains(element) else { throw LookupFailure("incomplete", "Accessibility returned a shared subtree; unique visible ancestry is unknown.") }
            guard reader.visited.count < reader.maxNodes else { throw LookupFailure("incomplete", "Accessibility node limit reached; uniqueness is unknown.") }
            reader.visited.insert(element)
            guard try reader.pid(element) == query.pid else { throw LookupFailure("incomplete", "Accessibility subtree ownership could not be verified.") }
            let state = try reader.state(element)
            if state.secure || state.hidden || state.enabled == false { return }
            let name = query.role == nil || query.role == state.role ? try reader.name(element, rawRole: state.raw) : ""
            let bounds = try reader.frame(element)
            if name == query.name {
                try reader.ownedWindow(element, window: window, id: id, pid: query.pid)
                let candidate = LookupCandidate(name: name, role: state.role, pid: query.pid, windowID: id, frame: bounds ?? .zero,
                                                enabled: state.enabled, secure: state.secure, hidden: state.hidden)
                if let match = try lookupMatch(candidate, query: query, windowID: id, window: frame, clips: clips,
                                               displays: visibility.displays, occluders: visibility.occluders, occluderNames: visibility.occluderNames) {
                    matches.append(match); elements.append(element)
                }
            }
            let children = try reader.elements(element, kAXChildrenAttribute, limit: reader.maxNodes)
            if depth == 0 && children.isEmpty { throw LookupFailure("incomplete", "The window does not expose a searchable accessibility tree.") }
            var childClips = clips
            if let bounds = bounds { childClips.append(bounds) }
            else if ["AXScrollArea", "AXWebArea"].contains(state.raw) && !children.isEmpty {
                throw LookupFailure("incomplete", "Viewport visibility is unavailable.")
            }
            var path = ancestors; path.insert(element)
            for child in children { try walk(child, depth: depth + 1, ancestors: path, clips: childClips) }
        }
        try walk(window, depth: 0, ancestors: [], clips: [])
        try preflight()
        let currentWindows = try reader.elements(app, kAXWindowsAttribute, limit: 64, optional: false)
        guard (query.windowID != nil || currentWindows.count == 1), currentWindows.contains(where: { CFEqual($0, window) }),
              try reader.windowID(window) == id, try reader.frame(window) == frame,
              try reader.bool(window, kAXMinimizedAttribute) == false else {
            throw LookupFailure("incomplete", "The selected window changed during lookup.")
        }
        visibility = try lookupVisibility(reader, pid: query.pid, windowID: id, frame: frame)
        // Re-read each result and its current parent chain; cached snapshots/old parents cannot
        // authorize a match. Secure parents are never read for names or values.
        for (index, element) in elements.enumerated() {
            var parent: AXUIElement? = element, chain = Set<AXUIElement>(), clips: [CGRect] = []
            var reachedWindow = false
            while let current = parent, chain.count <= reader.maxDepth {
                guard chain.insert(current).inserted, try reader.pid(current) == query.pid else { break }
                let state = try reader.state(current)
                guard !state.secure, !state.hidden, state.enabled != false else { throw LookupFailure("incomplete", "Target or parent became secure, hidden, or disabled.") }
                if !CFEqual(current, element) {
                    if let rect = try reader.frame(current) { clips.append(rect) }
                    else if ["AXScrollArea", "AXWebArea"].contains(state.raw) {
                        throw LookupFailure("incomplete", "Target's current viewport visibility is unavailable.")
                    }
                }
                if CFEqual(current, window) { reachedWindow = true; break }
                parent = try reader.element(current, kAXParentAttribute)
            }
            guard reachedWindow else { throw LookupFailure("incomplete", "Target's current ancestry cannot be verified.") }
            try reader.ownedWindow(element, window: window, id: id, pid: query.pid)
            let state = try reader.state(element)
            guard !state.secure, !state.hidden, state.enabled != false else {
                throw LookupFailure("incomplete", "Target became secure, hidden, or disabled during validation.")
            }
            let name = try reader.name(element, rawRole: state.raw)
            let bounds = try reader.frame(element) ?? .zero
            let candidate = LookupCandidate(name: name, role: state.role, pid: query.pid, windowID: id, frame: bounds,
                                            enabled: state.enabled, secure: state.secure, hidden: state.hidden)
            guard let fresh = try lookupMatch(candidate, query: query, windowID: id, window: frame, clips: clips,
                                               displays: visibility.displays, occluders: visibility.occluders, occluderNames: visibility.occluderNames), fresh == matches[index] else {
                throw LookupFailure("incomplete", "An exact target changed during lookup; retry with fresh context.")
            }
            try reader.hitTest(element, frame: bounds, pid: query.pid)
        }
        try preflight()
        guard try reader.frame(window) == frame, try reader.bool(window, kAXMinimizedAttribute) == false else {
            throw LookupFailure("incomplete", "Window geometry or visibility changed during target validation.")
        }
        let finalVisibility = try lookupVisibility(reader, pid: query.pid, windowID: id, frame: frame)
        for match in matches {
            let rect = CGRect(x: frame.minX + match.rect.minX * frame.width, y: frame.minY + match.rect.minY * frame.height,
                              width: match.rect.width * frame.width, height: match.rect.height * frame.height)
            guard finalVisibility.displays.contains(where: { $0.contains(rect) }) else {
                throw LookupFailure("incomplete", "Target visibility changed during validation.")
            }
            if let index = finalVisibility.occluders.firstIndex(where: { $0.intersects(rect) }) {
                throw LookupFailure("incomplete", lookupOcclusionMessage(finalVisibility.occluderNames[index]))
            }
        }
        try reader.checkTime()
        return lookupResult(matches, incomplete: nil)
    } catch let failure as LookupFailure {
        if failure.status == "incomplete" { return lookupResult(matches, incomplete: failure.message) }
        return ["status": failure.status, "message": String(failure.message.prefix(240))]
    } catch let error as AgentError {
        return ["status": "unavailable", "message": String(error.message.prefix(240))]
    } catch {
        return ["status": "incomplete", "message": "Accessibility lookup could not be completed."]
    }
}

// MARK: - process-targeted keyboard events (never global)

let KEYCODES: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
    "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
    "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 117, "escape": 53, "esc": 53,
    "home": 115, "end": 119, "pageup": 116, "page_up": 116, "pagedown": 121, "page_down": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]
func postKey(pid: pid_t, combo: String) throws {
    let parts = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard let keyName = parts.last, let code = KEYCODES[keyName] else { throw AgentError("Unknown key in \(combo)") }
    var flags: CGEventFlags = []
    for m in parts.dropLast() {
        switch m.replacingOccurrences(of: "_l", with: "").replacingOccurrences(of: "_r", with: "") {
        case "cmd", "command", "meta", "super": flags.insert(.maskCommand)
        case "ctrl", "control": flags.insert(.maskControl)
        case "alt", "option": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        default: throw AgentError("Unknown modifier \(m)")
        }
    }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
        e.flags = flags
        e.postToPid(pid)
    }
}
func postText(pid: pid_t, text: String) {
    let units = Array(text.utf16)
    var i = 0
    while i < units.count {
        var end = min(i + 16, units.count)
        if end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
        let chunk = Array(units[i..<end])
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            e.postToPid(pid)
        }
        i = end
    }
}

/// Click semantics through Accessibility: right-click shows the element's menu,
/// double-click opens it (or presses twice when it has no open action).
func click(_ el: AXUIElement, button: String, count: Int) throws {
    if button.hasPrefix("r") {
        if axActions(el).contains("AXShowMenu"), axPerform(el, "AXShowMenu") { return }
        return try eventClick(el, button: button, count: 1)
    }
    if count >= 2 {
        if axActions(el).contains("AXOpen"), axPerform(el, "AXOpen") { return }
        return try eventClick(el, button: button, count: count)
    }
    // plain groups and custom views (common in Electron apps) have no press action
    do { try press(el) } catch { try eventClick(el, button: button, count: 1) }
}

/// Scroll the nearest scroll area at or above an element by pages.
func scroll(_ e: AXUIElement, direction dir: String, pages: Int) throws -> AXUIElement {
    var area: AXUIElement? = e
    while let a = area, axString(a, kAXRoleAttribute) != "AXScrollArea" { area = ax(a, kAXParentAttribute).map { $0 as! AXUIElement } }
    guard let sa = area else { throw AgentError("No scroll area at or above this element") }
    let key = dir.hasPrefix("u") ? "up" : dir.hasPrefix("l") ? "left" : dir.hasPrefix("r") ? "right" : "down"
    let action = ["up": "AXScrollUpByPage", "down": "AXScrollDownByPage", "left": "AXScrollLeftByPage", "right": "AXScrollRightByPage"][key]!
    if axActions(sa).contains(action), (0..<pages).allSatisfy({ _ in axPerform(sa, action) }) { return sa }
    let barAttr = (key == "left" || key == "right") ? kAXHorizontalScrollBarAttribute : kAXVerticalScrollBarAttribute
    guard let bar = ax(sa, barAttr).map({ $0 as! AXUIElement }), let v = (ax(bar, kAXValueAttribute) as? NSNumber)?.doubleValue
    else { throw AgentError("This area cannot be scrolled through Accessibility") }
    let delta = (key == "up" || key == "left" ? -0.2 : 0.2) * Double(pages)
    axSet(bar, kAXValueAttribute, NSNumber(value: min(1, max(0, v + delta))))
    return sa
}

/// Select `text` in an editable element, or put the caret before/after it.
func selectText(_ el: AXUIElement, text: String, prefix: String, suffix: String, type: String) throws {
    axSet(el, kAXFocusedAttribute, kCFBooleanTrue)
    guard let value = ax(el, kAXValueAttribute) as? String else { throw AgentError("This element has no editable text") }
    let hay = value as NSString
    let r = hay.range(of: prefix + text + suffix)
    guard r.location != NSNotFound else { throw AgentError("\"\(text)\" not found in the element") }
    let start = r.location + (prefix as NSString).length, len = (text as NSString).length
    var range = type == "cursor_before" ? CFRange(location: start, length: 0)
        : type == "cursor_after" ? CFRange(location: start + len, length: 0) : CFRange(location: start, length: len)
    guard let v = AXValueCreate(.cfRange, &range), AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    else { throw AgentError("This element doesn't allow setting a selection") }
}

/// Drag with mouse events posted to one process only - the user's cursor never moves.
func drag(pid: pid_t, window: CGWindowID?, from a: CGPoint, to b: CGPoint) {
    let steps = max(4, Int(hypot(b.x - a.x, b.y - a.y) / 20))
    func post(_ type: CGEventType, _ p: CGPoint) { postMouse(pid: pid, type, at: p, window: window) }
    post(.mouseMoved, a); usleep(20_000)
    post(.leftMouseDown, a); usleep(30_000)
    for i in 1...steps { post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / CGFloat(steps), y: a.y + (b.y - a.y) * CGFloat(i) / CGFloat(steps))); usleep(12_000) }
    post(.leftMouseUp, b)
}

// MARK: - apps

func runningApps(includeAccessories: Bool = false) -> [[String: Any]] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular || includeAccessories && $0.activationPolicy == .accessory }
        .map { ["name": $0.localizedName ?? "", "bundleId": $0.bundleIdentifier ?? "", "pid": Int($0.processIdentifier), "active": $0.isActive, "process": (try? processIdentity($0.processIdentifier)) ?? ""] }
}

func resolve(_ query: String) throws -> [String: Any] {
    let q = query.lowercased()
    let all = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
    let apps = all.filter { $0.activationPolicy == .regular }
    guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError("App query is empty") }
    let exact = all.filter { $0.bundleIdentifier?.lowercased() == q || $0.localizedName?.lowercased() == q || String($0.processIdentifier) == q }
    let candidates = exact.isEmpty ? apps.filter { $0.localizedName?.lowercased().contains(q) == true } : exact
    guard candidates.count <= 1 else { throw AgentError("Multiple processes match; choose a pid from apps()", code: "ambiguous_target") }
    if let a = candidates.first { return ["pid": Int(a.processIdentifier), "name": a.localizedName ?? query, "bundleId": a.bundleIdentifier ?? "", "process": try processIdentity(a.processIdentifier)] }
    // not running: launch it in the background without activating it
    var url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query)
    if url == nil {
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "\(home)/Applications"] {
            let p = "\(dir)/\(query).app"
            if fm.fileExists(atPath: p) { url = URL(fileURLWithPath: p); break }
        }
    }
    guard let appURL = url else { throw AgentError("No running or installed app matches \"\(query)\"") }
    let conf = NSWorkspace.OpenConfiguration()
    conf.activates = false
    conf.addsToRecentItems = false
    let sem = DispatchSemaphore(value: 0)
    var launched: NSRunningApplication?
    NSWorkspace.shared.openApplication(at: appURL, configuration: conf) { app, _ in launched = app; sem.signal() }
    _ = sem.wait(timeout: .now() + 15)
    guard let a = launched else { throw AgentError("Could not launch \(appURL.lastPathComponent)") }
    Thread.sleep(forTimeInterval: 1.0)
    return ["pid": Int(a.processIdentifier), "name": a.localizedName ?? query, "bundleId": a.bundleIdentifier ?? "", "process": try processIdentity(a.processIdentifier)]
}

// MARK: - capture

func scWindow(pid: pid_t, window: CGWindowID) throws -> SCWindow {
    try requireScreenRecording()
    let sem = DispatchSemaphore(value: 0)
    var content: SCShareableContent?
    var err: Error?
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { c, e in content = c; err = e; sem.signal() }
    _ = sem.wait(timeout: .now() + 10)
    if let e = err { throw AgentError("Screen Recording is not granted to CuaAgent (\(e.localizedDescription))") }
    let wins = (content?.windows ?? []).filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 }
    // the window the last read used, so screenshot pixels line up with click coordinates
    guard let w = wins.first(where: { $0.windowID == window }) else { throw AgentError("Selected window is not capturable", code: "window_unavailable") }
    return w
}

func jpeg(_ cg: CGImage, quality: Double) -> Data? {
    NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: quality])
}

func screenshot(pid: pid_t, window: CGWindowID) throws -> String {
    let w = try scWindow(pid: pid, window: window)
    let conf = SCStreamConfiguration()
    // 1x, so a pixel in the screenshot is the window point that click({x, y}) takes
    conf.width = Int(w.frame.width); conf.height = Int(w.frame.height)
    conf.showsCursor = false
    let sem = DispatchSemaphore(value: 0)
    var image: CGImage?; var err: Error?
    SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: conf) { i, e in image = i; err = e; sem.signal() }
    _ = sem.wait(timeout: .now() + 15)
    if let e = err { throw AgentError("Capture failed: \(e.localizedDescription)") }
    guard let cg = image, let data = jpeg(cg, quality: 0.8) else { throw AgentError("Capture returned no image") }
    return data.base64EncodedString()
}

final class Streamer: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    var pid: pid_t?
    var window: CGWindowID?
    var identity: String?
    let output: String
    let ci = CIContext()
    let q = DispatchQueue(label: "cua.stream")
    init(output: String = framePath) { self.output = output }

    func start(pid newPid: pid_t?, window newWindow: CGWindowID?) throws {
        let newIdentity = try newPid.map(processIdentity)
        if newPid == pid && newWindow == window && newIdentity == identity && stream != nil { return }
        stop()
        guard let p = newPid, let id = newWindow else { return }
        let w = try scWindow(pid: p, window: id)
        let conf = SCStreamConfiguration()
        let width = max(64, min(4096, cfgNumber("stream", "maxWidth", 1280)))
        let scale = min(2, width / Double(w.frame.width))
        conf.width = max(1, Int(Double(w.frame.width) * scale)); conf.height = max(1, Int(Double(w.frame.height) * scale))
        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(60, cfgNumber("stream", "fps", 12)))))
        conf.showsCursor = false
        let st = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: conf, delegate: self)
        try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        q.sync { stream = st }
        let sem = DispatchSemaphore(value: 0); var err: Error?
        st.startCapture { e in err = e; sem.signal() }
        guard sem.wait(timeout: .now() + 10) == .success else { stop(); throw AgentError("Stream startup timed out") }
        if let e = err { stop(); throw AgentError("Stream failed: \(e.localizedDescription)") }
        pid = p; window = newWindow; identity = newIdentity
    }
    func stop() {
        let previous = q.sync { () -> SCStream? in
            let old = stream; stream = nil
            try? fm.removeItem(atPath: output)
            return old
        }
        previous?.stopCapture { _ in }
        pid = nil; window = nil; identity = nil
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard s === stream, type == .screen, sb.isValid, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let img = CIImage(cvPixelBuffer: px)
        guard let data = ci.jpegRepresentation(of: img, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: max(1, min(100, cfgNumber("stream", "quality", 70))) / 100]) else { return }
        do { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        catch { NSLog("cua frame write failed: %@", error.localizedDescription) }
    }
    func stream(_ s: SCStream, didStopWithError error: Error) {
        axQueue.async { if self.stream === s { self.stop() } }
    }
}
let streamer = Streamer()
struct NativeView { let stream: Streamer; let info: [String: Any] }
var views: [String: NativeView] = [:]
func viewMetadata(_ id: String) -> String { "\(runDir)/view-\(id).json" }

// MARK: - request dispatch

func handle(_ req: [String: Any]) throws -> Any {
    let cmd = req["cmd"] as? String ?? ""
    if cmd == "lookup" { return lookup(req) }
    for key in ["pid", "windowId", "index", "count", "pages", "maxDepth"] {
        if let value = req[key], !(value is NSNull) {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                  n.doubleValue >= 1, n.doubleValue <= Double(Int32.max) else { throw AgentError("Invalid integer: \(key)") }
        }
    }
    let mutations: Set<String> = ["press", "pressAt", "focus", "setValue", "action", "scroll", "scrollAt", "selectText", "drag", "typeText", "pressKey"]
    defer {
        if mutations.contains(cmd), let generation = req["generation"] as? String { tables.removeValue(forKey: generation) }
    }
    let pid = (req["pid"] as? NSNumber).flatMap { pid_t(exactly: $0.int64Value) }
    let gen = req["generation"] as? String
    let targetWindow = (req["windowId"] as? NSNumber).flatMap { CGWindowID(exactly: $0.int64Value) }
    let index = (req["index"] as? NSNumber)?.intValue
    func needPid() throws -> pid_t {
        guard let p = pid, p > 1 else { throw AgentError("Valid pid required") }
        try checkProcess(p, req["process"] as? String)
        return p
    }
    func table() throws -> Table {
        let t = try checkedTable(try needPid(), gen)
        guard targetWindow == t.windowID else { throw AgentError("Snapshot belongs to a different window", code: "stale_target") }
        return t
    }
    func point(_ xKey: String, _ yKey: String, _ t: Table) throws -> CGPoint {
        guard let x = (req[xKey] as? NSNumber)?.doubleValue, let y = (req[yKey] as? NSNumber)?.doubleValue,
              x.isFinite, y.isFinite, x >= 0, y >= 0, x < t.window.width, y < t.window.height else {
            throw AgentError("Coordinates must be finite points inside the selected window")
        }
        return CGPoint(x: x, y: y)
    }
    func el() throws -> AXUIElement {
        guard let i = index else { throw AgentError("index required") }
        let t = try table(), p = try needPid(), e = try element(p, gen, i)
        if let window = windowID(of: e) {
            guard window == t.windowID else { throw AgentError("Element moved to another window; read again", code: "stale_snapshot") }
        } else { try keyboardTarget(p, t) }
        return e
    }

    if let count = req["count"] as? NSNumber, !(1...3).contains(count.intValue) { throw AgentError("click count must be 1...3") }
    if let pages = req["pages"] as? NSNumber, !(1...20).contains(pages.intValue) { throw AgentError("pages must be 1...20") }
    if let dir = req["direction"] as? String, !["up", "down", "left", "right"].contains(dir.lowercased()) { throw AgentError("Unknown scroll direction") }
    switch cmd {
    case "status":
        return ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "pid": Int(getpid()), "version": "2.3.0"]
    case "requestPermission":
        let permission = req["permission"] as? String ?? ""
        guard ["accessibility", "screen-recording"].contains(permission) else { throw AgentError("Choose accessibility or screen-recording") }
        let granted = permission == "accessibility" ? AXIsProcessTrusted() : CGPreflightScreenCaptureAccess()
        if !granted && !requestedPermissions.contains(permission) {
            requestedPermissions.insert(permission)
            DispatchQueue.main.async {
                if permission == "accessibility" {
                    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                } else { CGRequestScreenCaptureAccess() }
            }
        }
        return ["granted": granted, "permission": permission, "message": "Grant access in System Settings > Privacy & Security. Repeated calls do not repeat the prompt during this helper run."]
    case "releaseSnapshot":
        if let gen = gen { tables.removeValue(forKey: gen) }
        return ["released": true]
    case "apps": return runningApps(includeAccessories: req["includeAccessories"] as? Bool == true)
    case "resolve": return try resolve(req["query"] as? String ?? "")
    case "windows": return try windows(try needPid())
    case "snapshot": return try snapshot(pid: try needPid(), window: targetWindow, maxDepth: min(60, max(1, (req["maxDepth"] as? NSNumber)?.intValue ?? 30)))
    case "press":
        let e = try el(); let c = center(try needPid(), gen, e)
        try click(e, button: req["button"] as? String ?? "left", count: (req["count"] as? NSNumber)?.intValue ?? 1)
        return ["center": c as Any]
    case "pressAt":
        let p = try needPid()
        let t = try table()
        let relative = try point("x", "y", t), x = relative.x, y = relative.y
        // a coordinate click is a real click on that window, so canvases and custom views get it too
        let pt = CGPoint(x: t.window.minX + x, y: t.window.minY + y)
        eventClick(pid: p, at: pt, window: t.windowID, button: req["button"] as? String ?? "left", count: (req["count"] as? NSNumber)?.intValue ?? 1)
        return ["center": ["x": x / Double(t.window.width), "y": y / Double(t.window.height)]]
    case "locate":
        // Read-only, for the on-screen pointer: where an element or point is, normalised to the
        // selected window so the overlay can follow the window as it moves. No input is sent.
        let t = try table()
        guard let window = t.windowID, t.window.width > 0, t.window.height > 0 else { throw AgentError("Window has no usable frame") }
        if let i = index {
            guard let f = axFrame(try element(try needPid(), gen, i)), f.width > 0 || f.height > 0 else { throw AgentError("Element has no on-screen frame") }
            return ["windowId": Int(window), "rect": ["x": Double((f.minX - t.window.minX) / t.window.width), "y": Double((f.minY - t.window.minY) / t.window.height),
                                                    "w": Double(f.width / t.window.width), "h": Double(f.height / t.window.height)]]
        }
        let p = try point("x", "y", t)
        return ["windowId": Int(window), "x": Double(p.x / t.window.width), "y": Double(p.y / t.window.height)]
    case "focus":
        let e = try el(); axSet(e, kAXFocusedAttribute, kCFBooleanTrue)
        return ["center": center(try needPid(), gen, e) as Any]
    case "setValue":
        let e = try el(); let v = req["value"] as? String ?? ""
        axSet(e, kAXFocusedAttribute, kCFBooleanTrue)
        let current = ax(e, kAXValueAttribute)
        let ok = current is NSNumber && Double(v) != nil ? axSet(e, kAXValueAttribute, NSNumber(value: Double(v)!)) : axSet(e, kAXValueAttribute, v as CFString)
        if !ok { throw AgentError("Element's value is not settable") }
        return ["center": center(try needPid(), gen, e) as Any]
    case "action":
        let e = try el(); let name = req["name"] as? String ?? ""
        let acts = axActions(e)
        let actual = acts.first { $0 == name || $0 == "AX" + name.replacingOccurrences(of: " ", with: "") } ?? name
        guard axPerform(e, actual) else { throw AgentError("Action \(name) failed. Available: \(acts.joined(separator: ", "))") }
        return ["center": center(try needPid(), gen, e) as Any]
    case "scroll":
        let dir = (req["direction"] as? String ?? "down").lowercased(), pages = max(1, (req["pages"] as? NSNumber)?.intValue ?? 1)
        let sa = try scroll(try el(), direction: dir, pages: pages)
        return ["center": center(try needPid(), gen, sa) as Any]
    case "scrollAt":
        let p = try needPid()
        let t = try table()
        let relative = try point("x", "y", t), x = relative.x, y = relative.y
        let dir = (req["direction"] as? String ?? "down").lowercased(), pages = max(1, (req["pages"] as? NSNumber)?.intValue ?? 1)
        eventScroll(pid: p, at: CGPoint(x: t.window.minX + x, y: t.window.minY + y), window: t.windowID, direction: dir,
                    pixels: Double(t.window.height) * 0.8 * Double(pages))
        return ["center": ["x": x / Double(t.window.width), "y": y / Double(t.window.height)]]
    case "selectText":
        let e = try el()
        try selectText(e, text: req["text"] as? String ?? "", prefix: req["prefix"] as? String ?? "", suffix: req["suffix"] as? String ?? "", type: req["selectionType"] as? String ?? "text")
        return ["center": center(try needPid(), gen, e) as Any]
    case "drag":
        let p = try needPid()
        let t = try table()
        let from = try point("fromX", "fromY", t), to = try point("toX", "toY", t)
        let coords = ["fromX": from.x, "fromY": from.y, "toX": to.x, "toY": to.y]
        let n = { (k: String) in coords[k]! }
        drag(pid: p, window: t.windowID, from: CGPoint(x: t.window.minX + n("fromX"), y: t.window.minY + n("fromY")), to: CGPoint(x: t.window.minX + n("toX"), y: t.window.minY + n("toY")))
        return ["center": ["x": Double(n("toX")) / Double(t.window.width), "y": Double(n("toY")) / Double(t.window.height)]]
    case "typeText":
        let p = try needPid(); let text = req["text"] as? String ?? ""
        let t = try table()
        try keyboardTarget(p, t)
        var target: AXUIElement?
        if index != nil { let e = try el(); axSet(e, kAXFocusedAttribute, kCFBooleanTrue); target = e }
        else { target = ax(appElement(p), kAXFocusedUIElementAttribute).map { $0 as! AXUIElement } }
        if let target = target {
            guard windowID(of: target) == t.windowID,
                  axString(target, kAXRoleAttribute) != "AXSecureTextField",
                  axString(target, kAXSubroleAttribute) != "AXSecureTextField" else {
                throw AgentError("Text target is a different window or secure input; no text sent")
            }
        }
        if let t = target, axSet(t, kAXSelectedTextAttribute, text as CFString) {
            return ["center": center(p, gen, t) as Any, "result": "inserted via Accessibility"]
        }
        guard req["allowKeyEvents"] as? Bool ?? true else { throw AgentError("The focused element doesn't accept Accessibility text, and key events are disabled") }
        try keyboardTarget(p, t)
        guard let target = target, ax(appElement(p), kAXFocusedUIElementAttribute).map({ CFEqual($0, target) }) == true else {
            throw AgentError("Cannot focus the intended text element; no keys sent")
        }
        postText(pid: p, text: text)
        return ["center": center(p, gen, target) as Any, "result": "typed via process-targeted key events"]
    case "pressKey":
        let p = try needPid()
        let t = try table()
        try keyboardTarget(p, t)
        if index != nil {
            let e = try el(); axSet(e, kAXFocusedAttribute, kCFBooleanTrue)
            guard ax(appElement(p), kAXFocusedUIElementAttribute).map({ CFEqual($0, e) }) == true else {
                throw AgentError("Cannot focus the intended element; no keys sent")
            }
        }
        try keyboardTarget(p, t)
        try postKey(pid: p, combo: req["combo"] as? String ?? "")
        return ["center": NSNull()]
    case "screenshot":
        let t = try table()
        return ["jpeg": try screenshot(pid: try needPid(), window: t.windowID!)]
    case "views":
        return views.values.map { view -> [String: Any] in
            var info = view.info; info["streaming"] = view.stream.pid != nil; return info
        }
    case "attach":
        let t = try table()
        guard views.count < 8 else { throw AgentError("Eight native previews are already attached; detach one first") }
        var host: [String: Any] = [:]
        if let h = req["host"] as? [String: Any] {
            guard let p = h["pid"] as? Int32, let id = h["windowId"] as? UInt32 else { throw AgentError("Host needs pid, process and windowId") }
            try checkProcess(p, h["process"] as? String)
            _ = try selectedWindow(p, id)
            host = ["pid": p, "process": h["process"]!, "windowId": id]
        }
        let id = UUID().uuidString.lowercased(), output = "\(runDir)/view-\(id).jpg"
        let view = Streamer(output: output)
        try view.start(pid: t.pid, window: t.windowID)
        let info: [String: Any] = ["id": id, "pid": t.pid, "process": t.process, "windowId": Int(t.windowID!),
                                  "title": t.windowElement.flatMap { axString($0, kAXTitleAttribute) } ?? "", "host": host]
        do { try JSONSerialization.data(withJSONObject: info).write(to: URL(fileURLWithPath: viewMetadata(id)), options: .atomic) }
        catch { view.stop(); throw error }
        views[id] = NativeView(stream: view, info: info)
        return info
    case "detach":
        guard let id = req["viewId"] as? String, let view = views.removeValue(forKey: id) else { throw AgentError("Unknown preview") }
        view.stream.stop(); try? fm.removeItem(atPath: viewMetadata(id))
        return ["detached": true]
    case "activateWindow":
        let p = try needPid(), w = try selectedWindow(try needPid(), targetWindow)
        guard targetWindow != nil, axPerform(w, kAXRaiseAction) else { throw AgentError("Cannot raise the selected window") }
        axSet(w, kAXMainAttribute, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: p)?.activate()
        return ["activated": true]
    case "stream":
        if pid != nil { _ = try table() }
        try streamer.start(pid: pid, window: pid == nil ? nil : try table().windowID)
        return ["streaming": streamer.pid != nil]
    default: throw AgentError("unknown command \(cmd)")
    }
}

// MARK: - unix socket server

func serve() {
    do {
        try fm.createDirectory(atPath: runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try fm.attributesOfItem(atPath: runDir)
        guard info[.type] as? FileAttributeType == .typeDirectory,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            throw AgentError("Run directory must be a private, owned directory")
        }
    } catch { NSLog("cua agent: %@", error.localizedDescription); exit(1) }
    let lock = open("\(runDir)/agent.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { NSLog("cua agent already running"); exit(1) }
    signal(SIGPIPE, SIG_IGN)
    guard sockPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { NSLog("cua agent socket path is too long"); exit(1) }
    // Old capture files are not a live preview after a helper restart.
    for file in (try? fm.contentsOfDirectory(atPath: runDir)) ?? [] {
        if file == "frame.jpg" || file.range(of: "^view-[0-9a-f-]{36}\\.(jpg|json)$", options: .regularExpression) != nil {
            try? fm.removeItem(atPath: "\(runDir)/\(file)")
        }
    }
    unlink(sockPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        let bytes = Array(sockPath.utf8.prefix(buf.count - 1))
        buf.copyBytes(from: bytes); buf[bytes.count] = 0
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }) == 0 else {
        NSLog("cua agent: bind failed"); exit(1)
    }
    chmod(sockPath, 0o600)
    listen(fd, 8)
    let clients = DispatchSemaphore(value: 64)
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            guard clients.wait(timeout: .now()) == .success else { close(client); continue }
            Thread.detachNewThread { defer { clients.signal() }; session(client) }
        }
    }
}

func session(_ fd: Int32) {
    var pending = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { close(fd); return }
        pending.append(buf, count: n)
        if pending.count > 1 << 20 { close(fd); return }
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            var resp: [String: Any] = ["id": req["id"] ?? 0]
            axQueue.sync {
                var probe: UInt8 = 0
                if recv(fd, &probe, 1, MSG_PEEK | MSG_DONTWAIT) == 0 {
                    resp["ok"] = false; resp["error"] = "Client disconnected before dispatch"; return
                }
                do { resp["ok"] = true; resp["result"] = try handle(req) }
                catch let e as AgentError { resp["ok"] = false; resp["error"] = e.message; resp["code"] = e.code }
                catch { resp["ok"] = false; resp["error"] = error.localizedDescription }
            }
            if var out = try? JSONSerialization.data(withJSONObject: resp) {
                out.append(0x0A)
                let sent = out.withUnsafeBytes { p -> Bool in
                    var offset = 0
                    while offset < out.count {
                        let n = write(fd, p.baseAddress!.advanced(by: offset), out.count - offset)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { return false }
                        offset += n
                    }
                    return true
                }
                if !sent { close(fd); return }
            }
        }
    }
}

// MARK: - main

NSApplication.shared.setActivationPolicy(.prohibited)   // no Dock icon, never activates
// Permission requests belong only to the explicit requestPermission command.
serve()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    axQueue.async {
        for (id, view) in views {
            let valid = (try? processIdentity(view.info["pid"] as? Int32 ?? 0)) == view.info["process"] as? String
            if !fm.fileExists(atPath: viewMetadata(id)) || !valid || view.stream.pid == nil {
                view.stream.stop(); views.removeValue(forKey: id); try? fm.removeItem(atPath: viewMetadata(id))
            }
        }
    }
}
NSLog("cua agent listening on \(sockPath)")
RunLoop.main.run()
