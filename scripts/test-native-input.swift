// These cases run extracted production handle -> click -> eventClick -> postMouse,
// including production LookupReader reads. Only OS boundaries are synthetic.
let fixturePID: pid_t = 4242
let fixtureWindowID: CGWindowID = 73
let group = CommandLine.arguments.dropFirst().first ?? "all"
var passed = 0, failed = 0
struct CheckFailure: Error { let message: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}
func check(_ category: String, _ name: String, _ body: () throws -> Void) {
    guard group == "all" || group == category else { return }
    do { try body(); passed += 1; print("PASS \(category): \(name)") }
    catch { failed += 1; print("FAIL \(category): \(name): \(error)") }
}
struct Fixture {
    let table: Table
    let app: AXUIElement
    let window: AXUIElement
    let viewport: AXUIElement
    let target: AXUIElement
    func request(button: String = "left", count: Int = 1) -> [String: Any] {
        var req: [String: Any] = ["cmd": "press", "pid": Int(table.pid), "process": table.process,
                                  "generation": table.generation, "index": 1, "button": button, "count": count]
        if let id = table.windowID { req["windowId"] = Int(id) }
        return req
    }
}
func fixture(origin: CGPoint = CGPoint(x: 100, y: 100)) -> Fixture {
    posted = []; mouseConstructionFailure = nil; axCalls = []; hitTests = []; tables = [:]; applications = [:]; identities = [:]
    let frame = CGRect(origin: origin, size: CGSize(width: 800, height: 600))
    let app = AXUIElement("app", pid: fixturePID, role: "AXApplication")
    let window = AXUIElement("window", pid: fixturePID, role: "AXWindow", windowID: fixtureWindowID, frame: frame)
    let viewport = AXUIElement("viewport", pid: fixturePID, role: "AXScrollArea",
                               frame: CGRect(x: origin.x + 20, y: origin.y + 100, width: 500, height: 400))
    let target = AXUIElement("target", pid: fixturePID,
                             frame: CGRect(x: origin.x + 60, y: origin.y + 120, width: 120, height: 20))
    viewport.attrs[kAXWindowAttribute] = window; viewport.attrs[kAXParentAttribute] = window
    target.attrs[kAXWindowAttribute] = window; target.attrs[kAXParentAttribute] = viewport
    app.attrs[kAXFocusedWindowAttribute] = window; app.attrs[kAXWindowsAttribute] = [window] as NSArray
    window.hit = target; app.hit = target
    applications[fixturePID] = app; identities[fixturePID] = "4242:1700000000.25"
    let table = Table(); table.pid = fixturePID; table.process = identities[fixturePID]!
    table.windowElement = window; table.window = frame; table.windowID = fixtureWindowID; table.items = [target]
    tables[table.generation] = table
    return Fixture(table: table, app: app, window: window, viewport: viewport, target: target)
}
func node(_ name: String, in fixture: Fixture, parent: AXUIElement?, pid: pid_t = fixturePID) -> AXUIElement {
    let el = AXUIElement(name, pid: pid)
    el.attrs[kAXWindowAttribute] = fixture.window; el.attrs[kAXParentAttribute] = parent
    return el
}
func refuse(_ f: Fixture, button: String = "left", count: Int = 1) throws {
    var failure: AgentError?
    do { _ = try handle(f.request(button: button, count: count)) }
    catch let error as AgentError { failure = error }
    try expect(posted.isEmpty, "unsafe request emitted \(posted.count) mouse events")
    try expect(failure != nil, "unsafe request succeeded instead of an explicit refusal")
    try expect(tables[f.table.generation] == nil, "mutation must consume its snapshot even when refused")
}
func expectMouse(_ point: CGPoint, button: CGMouseButton = .left, count: Int = 1) throws {
    let pair: [CGEventType] = button == .center ? [.otherMouseDown, .otherMouseUp]
        : button == .right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
    try expect(posted.map(\.type) == [.mouseMoved] + Array(repeating: pair, count: count).flatMap { $0 }, "wrong event sequence")
    try expect(posted.dropFirst().allSatisfy { $0.button == button }, "wrong mouse button")
    try expect(posted.map { $0.fields[.mouseEventClickState] } == [0] + (1...count).flatMap { [Int64($0), Int64($0)] }, "wrong click counts")
    try expect(posted.allSatisfy { $0.pid == fixturePID && $0.point == point
        && $0.fields[.mouseEventWindowUnderMousePointer] == Int64(fixtureWindowID)
        && $0.fields[.mouseEventWindowUnderMousePointerThatCanHandleThisEvent] == Int64(fixtureWindowID) }, "wrong point or selected recipient")
}

check("geometry", "visible fallback uses the global center once at zero, positive, and negative origins") {
    for origin in [CGPoint.zero, CGPoint(x: 300, y: 200), CGPoint(x: -1400, y: -350)] {
        let f = fixture(origin: origin)
        _ = try handle(f.request())
        try expectMouse(CGPoint(x: origin.x + 120, y: origin.y + 130))
    }
}
check("geometry", "clipped old center in a toolbar is refused, not clamped") {
    let f = fixture()
    f.target.frame = CGRect(x: 160, y: 150, width: 120, height: 20)
    f.app.hit = node("toolbar-control", in: f, parent: f.window)
    try refuse(f)
}
check("geometry", "partially clipped target is refused even when its center is visible") {
    let f = fixture(); f.target.frame = CGRect(x: 160, y: 190, width: 120, height: 30)
    try refuse(f)
}
check("geometry", "target outside the selected window is refused") {
    let f = fixture(); f.target.attrs[kAXParentAttribute] = f.window
    f.target.frame = CGRect(x: 110, y: 70, width: 20, height: 20)
    try refuse(f)
}
check("geometry", "missing, zero, negative, nonfinite, and overflowing target geometry is refused") {
    let invalid: [CGRect?] = [nil, CGRect(x: 160, y: 220, width: 120, height: 0),
        CGRect(x: 160, y: 220, width: 0, height: 20), CGRect(x: 160, y: 220, width: -1, height: 20),
        CGRect(x: 160, y: 220, width: 120, height: -1), CGRect(x: Double.nan, y: 220, width: 120, height: 20),
        CGRect(x: 160, y: Double.nan, width: 120, height: 20), CGRect(x: 160, y: 220, width: Double.nan, height: 20),
        CGRect(x: 160, y: 220, width: 120, height: Double.nan), CGRect(x: Double.infinity, y: 220, width: 120, height: 20),
        CGRect(x: 160, y: -Double.infinity, width: 120, height: 20), CGRect(x: 160, y: 220, width: Double.infinity, height: 20),
        CGRect(x: 160, y: 220, width: 120, height: Double.infinity),
        CGRect(x: Double.greatestFiniteMagnitude, y: 220, width: Double.greatestFiniteMagnitude, height: 20)]
    for frame in invalid { let f = fixture(); f.target.frame = frame; try refuse(f) }
}
check("geometry", "zero and nonfinite selected-window geometry is refused") {
    for frame in [CGRect.zero, CGRect(x: 100, y: 100, width: Double.infinity, height: 600)] {
        let f = fixture(); f.window.frame = frame; f.table.window = frame; try refuse(f)
    }
}
check("geometry", "empty and nonfinite ancestor clips are refused") {
    for frame in [CGRect.zero, CGRect(x: 120, y: 200, width: 500, height: -1),
                  CGRect(x: Double.nan, y: 200, width: 500, height: 400),
                  CGRect(x: 120, y: 200, width: Double.infinity, height: 400)] {
        let f = fixture(); f.viewport.frame = frame; try refuse(f)
    }
}
check("geometry", "scroll and web viewports with unavailable geometry are refused") {
    for role in ["AXScrollArea", "AXWebArea"] {
        let f = fixture(); f.viewport.attrs[kAXRoleAttribute] = role as NSString; f.viewport.frame = nil
        try refuse(f)
    }
}
check("geometry", "layout-only ancestor without a frame does not invent a clip") {
    let f = fixture(); f.target.attrs[kAXParentAttribute] = node("layout", in: f, parent: f.viewport)
    _ = try handle(f.request()); try expectMouse(CGPoint(x: 220, y: 230))
}
check("geometry", "missing, cyclic, and over-depth target ancestry is refused") {
    for mode in ["missing", "cycle", "depth"] {
        let f = fixture()
        if mode == "missing" { f.viewport.attrs[kAXParentAttribute] = nil }
        if mode == "cycle" { f.viewport.attrs[kAXParentAttribute] = f.target }
        if mode == "depth" {
            var parent = f.window
            for i in 0..<60 { parent = node("ancestor-\(i)", in: f, parent: parent) }
            f.target.attrs[kAXParentAttribute] = parent
        }
        try refuse(f)
    }
}
check("geometry", "hidden or disabled target and ancestors are refused") {
    for target in [true, false] {
        for attribute in ["AXHidden", kAXEnabledAttribute] {
            let f = fixture(); let element = target ? f.target : f.viewport
            element.attrs[attribute] = NSNumber(value: attribute == "AXHidden")
            try refuse(f)
        }
    }
}
check("geometry", "wrong process on target, ancestor, or selected window is refused") {
    for component in ["target", "ancestor", "window"] {
        let f = fixture(); let element = component == "target" ? f.target : component == "ancestor" ? f.viewport : f.window
        element.owner = fixturePID + 1; try refuse(f)
    }
}
check("geometry", "same numeric window ID cannot replace exact AX window ownership") {
    for ancestor in [false, true] {
        let f = fixture()
        let impostor = AXUIElement("other-window", pid: fixturePID, role: "AXWindow", windowID: fixtureWindowID, frame: f.table.window)
        (ancestor ? f.viewport : f.target).attrs[kAXWindowAttribute] = impostor
        try refuse(f)
    }
}
check("geometry", "missing selected window ID or element window ownership is refused") {
    let f = fixture(); f.target.attrs[kAXWindowAttribute] = nil; try refuse(f)
    let g = fixture(); g.table.windowID = nil; try refuse(g)
}
check("geometry", "wrong window in the request or target is refused") {
    let f = fixture()
    f.target.attrs[kAXWindowAttribute] = AXUIElement("other", pid: fixturePID, role: "AXWindow", windowID: 88)
    try refuse(f)
    let g = fixture(); var request = g.request(); request["windowId"] = 88
    do { _ = try handle(request); throw CheckFailure(message: "wrong selected window accepted") }
    catch is AgentError { try expect(posted.isEmpty, "wrong request window emitted input") }
}
check("geometry", "unreadable geometry, PID, visibility, and parent metadata fail closed") {
    for mode in ["geometry-type", "geometry-error", "pid", "timeout", "parent", "role", "hidden"] {
        let f = fixture()
        switch mode {
        case "geometry-type": f.target.attrs[kAXPositionAttribute] = "invalid" as NSString
        case "geometry-error": f.target.errors[kAXSizeAttribute] = .failure
        case "pid": f.target.pidError = .failure
        case "timeout": f.target.timeoutError = .failure
        case "parent": f.target.attrs[kAXParentAttribute] = "invalid" as NSString
        case "role": f.viewport.attrs[kAXRoleAttribute] = nil
        default: f.viewport.errors["AXHidden"] = .failure
        }
        try refuse(f)
    }
}
check("geometry", "unavailable, failed, sibling, foreign-process, and foreign-window hit tests are refused") {
    for mode in ["nil", "failure", "sibling", "pid", "window"] {
        let f = fixture()
        let hit = node("hit", in: f, parent: mode == "sibling" ? f.window : f.target)
        if mode == "pid" { hit.owner = fixturePID + 1 }
        if mode == "window" { hit.attrs[kAXWindowAttribute] = AXUIElement("other", pid: fixturePID, role: "AXWindow", windowID: 88) }
        f.app.hit = mode == "nil" ? nil : hit
        if mode == "failure" { f.app.hitError = .failure }
        try refuse(f)
    }
}
check("geometry", "cyclic and over-depth hit ancestry is refused") {
    let f = fixture(); let cyclic = node("hit-cycle", in: f, parent: nil); cyclic.attrs[kAXParentAttribute] = cyclic
    f.app.hit = cyclic; try refuse(f)
    let g = fixture(); var parent = g.target
    for i in 0..<60 { parent = node("hit-descendant-\(i)", in: g, parent: parent) }
    g.app.hit = parent; try refuse(g)
}
check("geometry", "a hit on a descendant label of the exact target is accepted") {
    let f = fixture(); f.app.hit = node("label", in: f, parent: f.target)
    _ = try handle(f.request()); try expectMouse(CGPoint(x: 220, y: 230))
}
check("geometry", "background window fallback uses app-scoped hit ownership without focusing") {
    let f = fixture()
    let front = AXUIElement("front-window", pid: fixturePID, role: "AXWindow", windowID: 88,
                            frame: CGRect(x: 1000, y: 100, width: 400, height: 400))
    f.app.attrs[kAXWindowsAttribute] = [front, f.window] as NSArray
    f.app.attrs[kAXFocusedWindowAttribute] = front
    _ = try handle(f.request()); try expectMouse(CGPoint(x: 220, y: 230))
    try expect(hitTests.count == 1 && hitTests[0].0 === f.app, "hit testing must stay app-scoped, not require global foreground ownership")
    try expect(!axCalls.contains { $0.contains("AXFocused") || $0.contains("AXMain") }, "background fallback must not focus another window")
}
check("geometry", "overlapping same-app window cannot authorize delivery to the selected window") {
    let f = fixture()
    let front = AXUIElement("front-window", pid: fixturePID, role: "AXWindow", windowID: 88, frame: f.table.window)
    f.app.attrs[kAXWindowsAttribute] = [front, f.window] as NSArray
    f.app.attrs[kAXFocusedWindowAttribute] = front; f.app.hit = front
    try refuse(f)
    try expect(!axCalls.contains { $0.contains("AXFocused") || $0.contains("AXMain") }, "refusal must not focus a window")
}
check("geometry", "mouse delivery uses the same representable point as hit testing") {
    let f = fixture(); f.target.frame = CGRect(x: 160.1, y: 220.2, width: 120.2, height: 20.2)
    _ = try handle(f.request())
    try expect(hitTests.count == 1 && posted.allSatisfy { $0.point == hitTests[0].1 }, "hit-tested and posted points differ")
}
check("geometry", "Float rounding outside a tiny target is refused rather than clamped") {
    let f = fixture(); f.target.frame = CGRect(x: 160.000001, y: 220, width: 0.000001, height: 20)
    try refuse(f)
}
check("geometry", "geometry or process changes during hit validation prevent delivery") {
    for mode in ["target", "window", "process", "owner", "minimized", "clip", "parent", "hidden"] {
        let f = fixture()
        f.app.onHit = {
            switch mode {
            case "target": f.target.frame = CGRect(x: 160, y: 150, width: 120, height: 20)
            case "window": f.window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            case "process": identities[fixturePID] = "4242:1700000001.25"
            case "owner": f.target.owner = fixturePID + 1
            case "clip": f.viewport.frame = CGRect(x: 120, y: 250, width: 500, height: 400)
            case "parent": f.target.attrs[kAXParentAttribute] = nil
            case "hidden": f.viewport.attrs["AXHidden"] = kCFBooleanTrue
            default: f.window.attrs[kAXMinimizedAttribute] = kCFBooleanTrue
            }
        }
        try refuse(f)
    }
}

check("buttons", "left AXPress remains semantic even when the frame is clipped") {
    let f = fixture(); f.target.frame = CGRect(x: 160, y: 150, width: 120, height: 20)
    f.target.actions = ["AXPress"]; f.target.successfulActions = ["AXPress"]
    _ = try handle(f.request())
    try expect(posted.isEmpty && axCalls == ["perform target AXPress"] && hitTests.isEmpty, "left semantic press must not require foreground geometry")
}
check("buttons", "left double-click keeps AXOpen semantics without requiring a frame") {
    let f = fixture(); f.target.frame = nil; f.target.actions = ["AXOpen"]; f.target.successfulActions = ["AXOpen"]
    _ = try handle(f.request(count: 2))
    try expect(posted.isEmpty && axCalls == ["perform target AXOpen"] && hitTests.isEmpty, "left double-click must retain AXOpen")
}
check("buttons", "right menu remains semantic without requiring a frame") {
    let f = fixture(); f.target.frame = nil; f.target.actions = ["AXShowMenu"]; f.target.successfulActions = ["AXShowMenu"]
    _ = try handle(f.request(button: "right"))
    try expect(posted.isEmpty && axCalls == ["perform target AXShowMenu"] && hitTests.isEmpty, "right click must retain AXShowMenu")
}
check("buttons", "middle single-click never invokes AXPress or AXSelected") {
    let f = fixture(); f.target.actions = ["AXPress"]; f.target.successfulActions = ["AXPress"]
    f.target.settable = [kAXSelectedAttribute]
    _ = try handle(f.request(button: "middle"))
    try expectMouse(CGPoint(x: 220, y: 230), button: .center)
    try expect(axCalls.isEmpty, "middle button ran a left semantic action")
}
check("buttons", "middle multi-click never invokes AXOpen and preserves event counts") {
    for count in [2, 3] {
        let f = fixture(); f.target.actions = ["AXOpen", "AXPress"]; f.target.successfulActions = ["AXOpen", "AXPress"]
        _ = try handle(f.request(button: "middle", count: count))
        try expectMouse(CGPoint(x: 220, y: 230), button: .center, count: count)
        try expect(axCalls.isEmpty, "middle multi-click ran a left semantic action")
    }
}
check("buttons", "unsafe middle clicks fail explicitly without semantic actions") {
    for count in [1, 2] {
        let f = fixture(); f.target.actions = ["AXPress", "AXOpen"]; f.target.successfulActions = ["AXPress", "AXOpen"]
        f.target.frame = CGRect(x: 160, y: 150, width: 120, height: 20)
        try refuse(f, button: "middle", count: count)
        try expect(axCalls.isEmpty, "unsafe middle click fell back to AXPress/AXOpen")
    }
}
check("buttons", "left double-click and right fallback retain their own event types") {
    let f = fixture(); _ = try handle(f.request(count: 2)); try expectMouse(CGPoint(x: 220, y: 230), count: 2)
    let g = fixture(); _ = try handle(g.request(button: "right", count: 3)); try expectMouse(CGPoint(x: 220, y: 230), button: .right)
}
check("buttons", "all indexed fallback branches reject clipped geometry") {
    for (button, count) in [("left", 1), ("left", 2), ("right", 1), ("middle", 1), ("middle", 2)] {
        let f = fixture(); f.target.frame = CGRect(x: 160, y: 150, width: 120, height: 20)
        try refuse(f, button: button, count: count)
    }
}
check("buttons", "coordinate middle control still uses window-local translation") {
    let f = fixture(origin: CGPoint(x: -1000, y: 200)); var req = f.request(button: "middle")
    req["cmd"] = "pressAt"; req["x"] = 90; req["y"] = 70
    _ = try handle(req); try expectMouse(CGPoint(x: -910, y: 270), button: .center)
}
check("buttons", "event construction failure posts no movement or partial click") {
    for (type, button) in [(CGEventType.mouseMoved, "left"), (.leftMouseDown, "left"), (.leftMouseUp, "left"), (.otherMouseUp, "middle")] {
        let f = fixture(); mouseConstructionFailure = type
        try refuse(f, button: button)
    }
}
check("buttons", "uncertain press, open, and menu results never send a second action") {
    for (action, button, count) in [("AXPress", "left", 1), ("AXOpen", "left", 2), ("AXShowMenu", "right", 1)] {
        for error in [AXError.cannotComplete, .failure, .apiDisabled, .invalidUIElement] {
            let f = fixture(); f.target.actions = [action]; f.target.actionErrors[action] = error; f.target.effectActions = [action]
            var failure: AgentError?
            do { _ = try handle(f.request(button: button, count: count)) } catch let e as AgentError { failure = e }
            try expect(failure?.code == "action_outcome_unknown", "uncertain action did not stop: \(axCalls), \(posted.count) mouse events")
            try expect(f.target.effects == 1 && axCalls == ["perform target \(action)"] && posted.isEmpty, "uncertain action caused more input")
            try expect(tables[f.table.generation] == nil, "uncertain action must consume its snapshot")
        }
    }
}
check("buttons", "uncertain selection never continues to AXPress or mouse input") {
    for error in [AXError.cannotComplete, .failure] {
        let f = fixture(); f.target.settable = [kAXSelectedAttribute]; f.target.setErrors[kAXSelectedAttribute] = error; f.target.selectionEffect = true
        var failure: AgentError?
        do { _ = try handle(f.request()) } catch let e as AgentError { failure = e }
        try expect(failure?.code == "action_outcome_unknown", "uncertain selection fell through: \(axCalls), \(posted.count) mouse events")
        try expect(f.target.effects == 1 && axCalls == ["set target AXSelected"] && posted.isEmpty, "selection caused more input")
    }
}
check("buttons", "definitely unsupported press actions allow fallback without retrying AXPress") {
    for error in [AXError.actionUnsupported, .notImplemented] {
        let f = fixture(); f.target.actions = ["AXPress", "AXConfirm", "AXPick", "AXOpen"]
        f.target.actionErrors = Dictionary(uniqueKeysWithValues: f.target.actions.map { ($0, error) })
        _ = try handle(f.request()); try expectMouse(CGPoint(x: 220, y: 230))
        try expect(axCalls.filter { $0 == "perform target AXPress" }.count == 1, "unsupported AXPress was repeated")
    }
}
check("buttons", "unsupported open and menu actions keep validated mouse fallback") {
    for (action, button, count) in [("AXOpen", "left", 2), ("AXShowMenu", "right", 1)] {
        let f = fixture(); f.target.actions = [action]; f.target.actionErrors[action] = .actionUnsupported
        _ = try handle(f.request(button: button, count: count))
        try expectMouse(CGPoint(x: 220, y: 230), button: button == "right" ? .right : .left, count: count)
        try expect(axCalls == ["perform target \(action)"], "unsupported action ran more AX actions")
    }
}
check("buttons", "successful selection and unadvertised AXPress stay semantic") {
    let f = fixture(); f.target.settable = [kAXSelectedAttribute]
    _ = try handle(f.request()); try expect(posted.isEmpty && axCalls == ["set target AXSelected"], "successful selection emitted more input")
    let g = fixture(); g.target.successfulActions = ["AXPress"]
    _ = try handle(g.request()); try expect(posted.isEmpty && axCalls.filter { $0.hasPrefix("perform") } == ["perform target AXPress"], "unadvertised press no longer works")
}
check("buttons", "unreadable selection support stops before mutation") {
    let f = fixture(); f.target.settableError = .cannotComplete
    try refuse(f); try expect(axCalls.isEmpty, "unreadable selection support caused input")
}
check("buttons", "explicit named actions never have a mouse fallback") {
    let f = fixture(); f.target.actions = ["AXOpen"]; f.target.actionErrors["AXOpen"] = .cannotComplete; f.target.effectActions = ["AXOpen"]
    var request = f.request(); request["cmd"] = "action"; request["name"] = "AXOpen"
    var failure: AgentError?
    do { _ = try handle(request) } catch let e as AgentError { failure = e }
    try expect(failure != nil && posted.isEmpty && f.target.effects == 1 && axCalls == ["perform target AXOpen"], "named action retried input")
}
print("NATIVE_INPUT_CHECKS passed=\(passed) failed=\(failed)")
exit(failed == 0 ? 0 : 1)
