import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreImage

// CuaAgent - native-app half of cua. Holds the Accessibility and Screen Recording
// grants (macOS ties both to this binary's code signature, so it is built once
// and left alone). Serves JSON lines on a unix socket.
//
// It never touches the user's cursor or global input:
//  - clicks are Accessibility actions (AXPress etc.), coordinates are hit-tested
//    into elements and pressed, never turned into mouse events
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

struct AgentError: Error { let message: String; init(_ m: String) { message = m } }

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
    guard let p = ax(el, kAXPositionAttribute), let s = ax(el, kAXSizeAttribute) else { return nil }
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
    var generation = 0
    var items: [AXUIElement] = []
    var window: CGRect = .zero
}
var tables: [pid_t: Table] = [:]
let axQueue = DispatchQueue(label: "cua.ax")

func appElement(_ pid: pid_t) -> AXUIElement {
    let a = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(a, 2.0)
    return a
}

func mainWindow(_ app: AXUIElement) -> AXUIElement? {
    if let w = ax(app, kAXFocusedWindowAttribute) { return (w as! AXUIElement) }
    if let w = ax(app, kAXMainWindowAttribute) { return (w as! AXUIElement) }
    return (ax(app, kAXWindowsAttribute) as? [AXUIElement])?.first
}

func snapshot(pid: pid_t, maxDepth: Int) throws -> [String: Any] {
    guard AXIsProcessTrusted() else { throw AgentError("Accessibility access is not granted to CuaAgent (System Settings > Privacy & Security > Accessibility)") }
    let app = appElement(pid)
    let table = tables[pid] ?? Table()
    table.generation += 1
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
        let valueObj = ax(el, kAXValueAttribute)
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

    guard let win = mainWindow(app) else { throw AgentError("App has no accessible window (is it minimized or on another Space?)") }
    table.window = axFrame(win) ?? .zero
    walk(win, 0, "")
    // menu bar, top level only - enough to reach any command via AXPress
    if let bar = ax(app, kAXMenuBarAttribute) {
        let barEl = bar as! AXUIElement
        table.items.append(barEl)
        entries.append(["indent": 0, "text": "menubar", "ref": table.items.count - 1])
        for item in axChildren(barEl) {
            if let t = axString(item, kAXTitleAttribute) {
                table.items.append(item)
                entries.append(["indent": 1, "text": "menu \"\(t)\"", "ref": table.items.count - 1])
            }
        }
    }
    tables[pid] = table
    var out: [String: Any] = ["generation": table.generation, "entries": entries, "title": axString(win, kAXTitleAttribute) ?? "",
                              "window": ["x": table.window.minX, "y": table.window.minY, "w": table.window.width, "h": table.window.height]]
    if let f = focusedIndex { out["focused"] = f }
    return out
}

func element(_ pid: pid_t, _ gen: Int?, _ index: Int) throws -> AXUIElement {
    guard let t = tables[pid] else { throw AgentError("Read the app first (app.read())") }
    if let g = gen, g != t.generation { throw AgentError("Element indices are from an older read. Call read() again.") }
    let i = index - 1
    guard i >= 0, i < t.items.count else { throw AgentError("Element \(index) is not in the last read") }
    return t.items[i]
}

func center(_ pid: pid_t, _ el: AXUIElement) -> [String: Double]? {
    guard let t = tables[pid], let f = axFrame(el), t.window.width > 0 else { return nil }
    return ["x": Double((f.midX - t.window.minX) / t.window.width), "y": Double((f.midY - t.window.minY) / t.window.height)]
}

func press(_ el: AXUIElement) throws {
    let acts = axActions(el)
    for a in ["AXPress", "AXConfirm", "AXPick", "AXOpen"] where acts.contains(a) { if axPerform(el, a) { return } }
    if axSet(el, kAXSelectedAttribute, kCFBooleanTrue) { return }
    if axPerform(el, "AXPress") { return }
    throw AgentError("Element does not accept a press. Available actions: \(acts.joined(separator: ", "))")
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
        let chunk = Array(units[i..<min(i + 16, units.count)])
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            e.postToPid(pid)
        }
        i += 16
    }
}

/// Click semantics through Accessibility: right-click shows the element's menu,
/// double-click opens it (or presses twice when it has no open action).
func click(_ el: AXUIElement, button: String, count: Int) throws {
    if button.hasPrefix("r") {
        guard axPerform(el, "AXShowMenu") else { throw AgentError("This element has no context menu") }
        return
    }
    if count >= 2 {
        if axActions(el).contains("AXOpen"), axPerform(el, "AXOpen") { return }
        try press(el); usleep(60_000); try press(el); return
    }
    try press(el)
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
func drag(pid: pid_t, from a: CGPoint, to b: CGPoint) {
    let steps = max(4, Int(hypot(b.x - a.x, b.y - a.y) / 20))
    func post(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.postToPid(pid)
    }
    post(.leftMouseDown, a); usleep(30_000)
    for i in 1...steps { post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / CGFloat(steps), y: a.y + (b.y - a.y) * CGFloat(i) / CGFloat(steps))); usleep(12_000) }
    post(.leftMouseUp, b)
}

// MARK: - apps

func runningApps() -> [[String: Any]] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .map { ["name": $0.localizedName ?? "", "bundleId": $0.bundleIdentifier ?? "", "pid": Int($0.processIdentifier), "active": $0.isActive] }
}

func resolve(_ query: String) throws -> [String: Any] {
    let q = query.lowercased()
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    let hit = apps.first { $0.bundleIdentifier?.lowercased() == q }
        ?? apps.first { $0.localizedName?.lowercased() == q }
        ?? apps.first { $0.localizedName?.lowercased().contains(q) == true }
    if let a = hit { return ["pid": Int(a.processIdentifier), "name": a.localizedName ?? query, "bundleId": a.bundleIdentifier ?? ""] }
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
    return ["pid": Int(a.processIdentifier), "name": a.localizedName ?? query, "bundleId": a.bundleIdentifier ?? ""]
}

// MARK: - capture

func scWindow(pid: pid_t) throws -> SCWindow {
    let sem = DispatchSemaphore(value: 0)
    var content: SCShareableContent?
    var err: Error?
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { c, e in content = c; err = e; sem.signal() }
    _ = sem.wait(timeout: .now() + 10)
    if let e = err { throw AgentError("Screen Recording is not granted to CuaAgent (\(e.localizedDescription))") }
    let wins = (content?.windows ?? []).filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 }
    guard let w = wins.first(where: { $0.isOnScreen }) ?? wins.first else { throw AgentError("No capturable window for this app") }
    return w
}

func jpeg(_ cg: CGImage, quality: Double) -> Data? {
    NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: quality])
}

func screenshot(pid: pid_t) throws -> String {
    let w = try scWindow(pid: pid)
    let conf = SCStreamConfiguration()
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    conf.width = Int(w.frame.width * scale); conf.height = Int(w.frame.height * scale)
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
    let ci = CIContext()
    let q = DispatchQueue(label: "cua.stream")

    func start(pid newPid: pid_t?) throws {
        if newPid == pid && stream != nil { return }
        stop()
        guard let p = newPid else { return }
        let w = try scWindow(pid: p)
        let conf = SCStreamConfiguration()
        let width = cfgNumber("stream", "maxWidth", 1280)
        let s = min(1.0, width / Double(w.frame.width * 2)) * 2
        conf.width = Int(Double(w.frame.width) * s); conf.height = Int(Double(w.frame.height) * s)
        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, cfgNumber("stream", "fps", 12))))
        conf.showsCursor = false        // the HUD draws the agent's cursor; never the user's
        let st = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: conf, delegate: self)
        try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        let sem = DispatchSemaphore(value: 0); var err: Error?
        st.startCapture { e in err = e; sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        if let e = err { throw AgentError("Stream failed: \(e.localizedDescription)") }
        stream = st; pid = p
    }
    func stop() { stream?.stopCapture { _ in }; stream = nil; pid = nil }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let img = CIImage(cvPixelBuffer: px)
        guard let data = ci.jpegRepresentation(of: img, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: cfgNumber("stream", "quality", 70) / 100]) else { return }
        let tmp = framePath + ".agent.tmp"
        try? data.write(to: URL(fileURLWithPath: tmp))
        _ = try? fm.replaceItemAt(URL(fileURLWithPath: framePath), withItemAt: URL(fileURLWithPath: tmp))
    }
    func stream(_ s: SCStream, didStopWithError error: Error) { stream = nil; pid = nil }
}
let streamer = Streamer()

// MARK: - request dispatch

func handle(_ req: [String: Any]) throws -> Any {
    let cmd = req["cmd"] as? String ?? ""
    let pid = (req["pid"] as? NSNumber).map { pid_t($0.intValue) }
    let gen = (req["generation"] as? NSNumber)?.intValue
    let index = (req["index"] as? NSNumber)?.intValue
    func needPid() throws -> pid_t { guard let p = pid else { throw AgentError("pid required") }; return p }
    func el() throws -> AXUIElement { guard let i = index else { throw AgentError("index required") }; return try element(try needPid(), gen, i) }

    switch cmd {
    case "status":
        return ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "pid": Int(getpid()), "version": "2.1.0"]
    case "apps": return runningApps()
    case "resolve": return try resolve(req["query"] as? String ?? "")
    case "snapshot": return try snapshot(pid: try needPid(), maxDepth: (req["maxDepth"] as? NSNumber)?.intValue ?? 30)
    case "press":
        let e = try el(); let c = center(try needPid(), e)
        try click(e, button: req["button"] as? String ?? "left", count: (req["count"] as? NSNumber)?.intValue ?? 1)
        return ["center": c as Any]
    case "pressAt":
        let p = try needPid()
        guard let t = tables[p] else { throw AgentError("Read the app first (app.read())") }
        let x = (req["x"] as? NSNumber)?.doubleValue ?? 0, y = (req["y"] as? NSNumber)?.doubleValue ?? 0
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement(p), Float(t.window.minX + x), Float(t.window.minY + y), &hit) == .success, let h = hit
        else { throw AgentError("Nothing accessible at \(x),\(y)") }
        try click(h, button: req["button"] as? String ?? "left", count: (req["count"] as? NSNumber)?.intValue ?? 1)
        return ["center": ["x": x / Double(t.window.width), "y": y / Double(t.window.height)]]
    case "focus":
        let e = try el(); axSet(e, kAXFocusedAttribute, kCFBooleanTrue)
        return ["center": center(try needPid(), e) as Any]
    case "setValue":
        let e = try el(); let v = req["value"] as? String ?? ""
        axSet(e, kAXFocusedAttribute, kCFBooleanTrue)
        let current = ax(e, kAXValueAttribute)
        let ok = current is NSNumber && Double(v) != nil ? axSet(e, kAXValueAttribute, NSNumber(value: Double(v)!)) : axSet(e, kAXValueAttribute, v as CFString)
        if !ok { throw AgentError("Element's value is not settable") }
        return ["center": center(try needPid(), e) as Any]
    case "action":
        let e = try el(); let name = req["name"] as? String ?? ""
        let acts = axActions(e)
        let actual = acts.first { $0 == name || $0 == "AX" + name.replacingOccurrences(of: " ", with: "") } ?? name
        guard axPerform(e, actual) else { throw AgentError("Action \(name) failed. Available: \(acts.joined(separator: ", "))") }
        return ["center": center(try needPid(), e) as Any]
    case "scroll":
        let dir = (req["direction"] as? String ?? "down").lowercased(), pages = max(1, (req["pages"] as? NSNumber)?.intValue ?? 1)
        let sa = try scroll(try el(), direction: dir, pages: pages)
        return ["center": center(try needPid(), sa) as Any]
    case "scrollAt":
        let p = try needPid()
        guard let t = tables[p] else { throw AgentError("Read the app first") }
        let x = (req["x"] as? NSNumber)?.doubleValue ?? 0, y = (req["y"] as? NSNumber)?.doubleValue ?? 0
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement(p), Float(t.window.minX + x), Float(t.window.minY + y), &hit) == .success, let h = hit
        else { throw AgentError("Nothing accessible at \(x),\(y)") }
        let dir = (req["direction"] as? String ?? "down").lowercased(), pages = max(1, (req["pages"] as? NSNumber)?.intValue ?? 1)
        _ = try scroll(h, direction: dir, pages: pages)
        return ["center": ["x": x / Double(t.window.width), "y": y / Double(t.window.height)]]
    case "selectText":
        let e = try el()
        try selectText(e, text: req["text"] as? String ?? "", prefix: req["prefix"] as? String ?? "", suffix: req["suffix"] as? String ?? "", type: req["selectionType"] as? String ?? "text")
        return ["center": center(try needPid(), e) as Any]
    case "drag":
        let p = try needPid()
        guard let t = tables[p] else { throw AgentError("Read the app first") }
        let n = { (k: String) in CGFloat((req[k] as? NSNumber)?.doubleValue ?? 0) }
        drag(pid: p, from: CGPoint(x: t.window.minX + n("fromX"), y: t.window.minY + n("fromY")), to: CGPoint(x: t.window.minX + n("toX"), y: t.window.minY + n("toY")))
        return ["center": ["x": Double(n("toX")) / Double(t.window.width), "y": Double(n("toY")) / Double(t.window.height)]]
    case "typeText":
        let p = try needPid(); let text = req["text"] as? String ?? ""
        var target: AXUIElement?
        if index != nil { let e = try el(); axSet(e, kAXFocusedAttribute, kCFBooleanTrue); target = e }
        else { target = ax(appElement(p), kAXFocusedUIElementAttribute).map { $0 as! AXUIElement } }
        if let t = target, axSet(t, kAXSelectedTextAttribute, text as CFString) {
            return ["center": center(p, t) as Any, "result": "inserted via Accessibility"]
        }
        guard req["allowKeyEvents"] as? Bool ?? true else { throw AgentError("The focused element doesn't accept Accessibility text, and key events are disabled") }
        postText(pid: p, text: text)
        return ["center": target.flatMap { center(p, $0) } as Any, "result": "typed via process-targeted key events"]
    case "pressKey":
        let p = try needPid()
        if index != nil { let e = try el(); axSet(e, kAXFocusedAttribute, kCFBooleanTrue) }
        try postKey(pid: p, combo: req["combo"] as? String ?? "")
        return ["center": NSNull()]
    case "screenshot": return ["jpeg": try screenshot(pid: try needPid())]
    case "stream":
        try streamer.start(pid: pid)
        return ["streaming": streamer.pid != nil]
    default: throw AgentError("unknown command \(cmd)")
    }
}

// MARK: - unix socket server

func serve() {
    try? fm.createDirectory(atPath: runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            Thread.detachNewThread { session(client) }
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
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            var resp: [String: Any] = ["id": req["id"] ?? 0]
            axQueue.sync {
                do { resp["ok"] = true; resp["result"] = try handle(req) }
                catch let e as AgentError { resp["ok"] = false; resp["error"] = e.message }
                catch { resp["ok"] = false; resp["error"] = error.localizedDescription }
            }
            if var out = try? JSONSerialization.data(withJSONObject: resp) {
                out.append(0x0A)
                out.withUnsafeBytes { p in _ = write(fd, p.baseAddress, out.count) }
            }
        }
    }
}

// MARK: - main

NSApplication.shared.setActivationPolicy(.prohibited)   // no Dock icon, never activates
if !AXIsProcessTrusted() {
    // shows the system prompt once, pointing the user at the right settings pane
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
}
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
serve()
NSLog("cua agent listening on \(sockPath)")
RunLoop.main.run()
