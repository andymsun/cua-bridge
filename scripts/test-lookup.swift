// Appended to the real CuaAgent declarations by test-lookup.py. No socket, GUI, or TCC request.
var lookupChecks = 0
func checkLookup(_ name: String, _ body: () throws -> Void) {
    do { try body(); lookupChecks += 1; print("PASS \(name)") }
    catch { fputs("FAIL \(name): \(error)\n", stderr); exit(1) }
}
func expectLookup(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw AgentError(message) }
}
func expectLookupFailure(_ status: String, _ body: () throws -> Void) throws {
    do { try body() }
    catch let error as LookupFailure {
        try expectLookup(error.status == status, "expected \(status), got \(error.status)")
        return
    }
    throw AgentError("expected \(status), operation succeeded")
}

checkLookup("lookup rejects missing identity with a bounded protocol result") {
    let result = try handle(["cmd": "lookup", "name": "Save"]) as? [String: Any]
    try expectLookup(result?["status"] as? String == "unavailable", "malformed lookup must be unavailable, not an unknown command or thrown protocol error")
    try expectLookup((result?["message"] as? String)?.count ?? 1000 <= 240, "message must be bounded")
}
let validLookupRequest: [String: Any] = ["cmd": "lookup", "pid": 4242, "process": "4242:1700000000.25", "windowId": 42, "name": "Save", "role": "button"]
let lookupQuery = try LookupQuery(validLookupRequest)
let lookupWindow = CGRect(x: -1000, y: 100, width: 400, height: 300)
let lookupDisplays = [CGRect(x: -1200, y: 0, width: 1200, height: 900)]
func lookupCandidate(name: String = "Save", role: String = "button", pid: pid_t = 4242, windowID: CGWindowID = 42,
                     frame: CGRect = CGRect(x: -900, y: 160, width: 80, height: 30),
                     enabled: Bool? = true, secure: Bool = false, hidden: Bool = false) -> LookupCandidate {
    LookupCandidate(name: name, role: role, pid: pid, windowID: windowID, frame: frame, enabled: enabled, secure: secure, hidden: hidden)
}
func validateLookup(_ candidate: LookupCandidate, query: LookupQuery = lookupQuery,
                    window: CGRect = lookupWindow, clips: [CGRect] = [], displays: [CGRect] = lookupDisplays,
                    occluders: [CGRect] = []) throws -> LookupMatch? {
    try lookupMatch(candidate, query: query, windowID: 42, window: window, clips: clips, displays: displays, occluders: occluders)
}

checkLookup("request keeps exact names and native role strings") {
    var request = validLookupRequest
    request["name"] = " Save\nAs "
    request["role"] = "searchbox"
    let query = try LookupQuery(request)
    try expectLookup(query.name == " Save\nAs " && query.role == "searchbox", "must not trim, case-fold, or normalize names")
    try expectLookup(query.process == "4242:1700000000.25" && query.windowID == 42, "identity and window must be preserved")
}
checkLookup("optional role and window accept absence or JSON null") {
    var request = validLookupRequest
    request.removeValue(forKey: "windowId"); request["role"] = NSNull()
    let query = try LookupQuery(request)
    try expectLookup(query.windowID == nil && query.role == nil, "optional filters must remain optional")
}
checkLookup("request accepts the whole native window-id range") {
    var request = validLookupRequest; request["windowId"] = NSNumber(value: UInt32.max)
    try expectLookup(try LookupQuery(request).windowID == UInt32.max, "CGWindowID is unsigned, not Int32")
}
for (field, values) in [
    ("pid", [true, 0, 1, -1, 2.5, Double.infinity, "4242", NSNull()] as [Any]),
    ("windowId", [true, 0, -1, 1.5, Double(UInt32.max) + 1, "42"] as [Any]),
    ("name", ["", "   ", String(repeating: "x", count: 513), 1, NSNull()] as [Any]),
    ("role", ["AXButton", "Button", "made-up-role", "", 1] as [Any]),
    ("process", ["", "Fixture", "99:1700000000.25", "4242:nan", "4242:0", "4242:-1", NSNull()] as [Any])
] {
    checkLookup("request rejects invalid \(field) without live access") {
        for value in values {
            var request = validLookupRequest; request[field] = value
            try expectLookupFailure("unavailable") { _ = try LookupQuery(request) }
            let result = try handle(request) as? [String: Any]
            try expectLookup(result?["status"] as? String == "unavailable", "invalid \(field) must be a lookup status")
        }
    }
}
checkLookup("human-readable roles use the existing map and subroles") {
    try expectLookup(lookupRole("AXButton", nil) == "button", "native button role")
    try expectLookup(lookupRole("AXTextField", "AXSearchField") == "searchbox", "native search subrole")
    try expectLookup(lookupRole("AXRadioButton", "AXTabButton") == "tab", "native tab subrole")
    try expectLookup(lookupRole("AXMenuItem", nil) == "menuitem", "native menu role")
}
checkLookup("exact match returns window-normalized fractional geometry on a negative-origin display") {
    let match = try validateLookup(lookupCandidate())
    try expectLookup(match?.rect == CGRect(x: 0.25, y: 0.2, width: 0.2, height: 0.1), "wrong normalized rectangle")
    let response = lookupResult(match.map { [$0] } ?? [], incomplete: nil)
    try expectLookup(response["status"] as? String == "matched", "unique valid match must succeed")
    let target = response["target"] as? [String: Any], rect = target?["rect"] as? [String: Double]
    try expectLookup(target?["windowId"] as? Int == 42 && rect?["x"] == 0.25 && rect?["h"] == 0.1, "wire coordinates must match locate's convention")
    try expectLookup(response["name"] as? String == "Save" && response["role"] as? String == "button", "wire match metadata")
}
checkLookup("matching is exact, not substring, case-folded, or whitespace-folded") {
    for name in ["save", "Save As", " Save", "Save ", "Sa\nve"] {
        try expectLookup(try validateLookup(lookupCandidate(name: name)) == nil, "\(name) must not match Save")
    }
    try expectLookup(try validateLookup(lookupCandidate(role: "textbox")) == nil, "role filter must be exact")
}
checkLookup("omitted role permits a fresh exact name in any native role") {
    var request = validLookupRequest; request.removeValue(forKey: "role")
    try expectLookup(try validateLookup(lookupCandidate(role: "textbox"), query: LookupQuery(request)) != nil, "optional role must not default to button")
}
checkLookup("long names cannot be shortened into an exact match") {
    try expectLookupFailure("incomplete") { _ = try validateLookup(lookupCandidate(name: "Save" + String(repeating: "x", count: 509))) }
    let literal = "Save…"
    var request = validLookupRequest; request["name"] = literal
    try expectLookup(try validateLookup(lookupCandidate(name: literal), query: LookupQuery(request)) != nil, "an actual ellipsis is an exact character, not a wildcard")
}
checkLookup("secure, hidden, or disabled candidates never expose a target") {
    for candidate in [lookupCandidate(secure: true), lookupCandidate(hidden: true), lookupCandidate(enabled: false)] {
        try expectLookup(try validateLookup(candidate) == nil, "excluded target must not match")
    }
}
checkLookup("unknown enabled state cannot establish a valid match") {
    try expectLookupFailure("incomplete") { _ = try validateLookup(lookupCandidate(enabled: nil)) }
}
checkLookup("foreign process, window, or request window cannot yield coordinates") {
    try expectLookupFailure("incomplete") { _ = try validateLookup(lookupCandidate(pid: 4243)) }
    try expectLookupFailure("incomplete") { _ = try validateLookup(lookupCandidate(windowID: 43)) }
    var request = validLookupRequest; request["windowId"] = 43
    try expectLookupFailure("incomplete") { _ = try validateLookup(lookupCandidate(), query: LookupQuery(request)) }
}
checkLookup("zero, negative, nonfinite, or out-of-window geometry is rejected") {
    for frame in [CGRect(x: -900, y: 160, width: 0, height: 30), CGRect(x: -900, y: 160, width: 80, height: -1),
                  CGRect(x: Double.nan, y: 160, width: 80, height: 30), CGRect(x: -900, y: 160, width: Double.infinity, height: 30),
                  CGRect(x: -1010, y: 160, width: 80, height: 30), CGRect(x: -650, y: 160, width: 80, height: 30)] {
        try expectLookup(try validateLookup(lookupCandidate(frame: frame)) == nil, "invalid/clipped frame must not match")
    }
    try expectLookup(try validateLookup(lookupCandidate(), window: .zero) == nil, "zero window cannot normalize")
}
checkLookup("scroll clipping and off-display regions cannot produce visible matches") {
    try expectLookup(try validateLookup(lookupCandidate(), clips: [CGRect(x: -1000, y: 100, width: 150, height: 300)]) == nil, "clipped by scroll viewport")
    try expectLookup(try validateLookup(lookupCandidate(), displays: [CGRect(x: 0, y: 0, width: 1200, height: 900)]) == nil, "offscreen")
    try expectLookup(try validateLookup(lookupCandidate(), displays: []) == nil, "no display evidence")
    try expectLookup(try validateLookup(lookupCandidate(), displays: [CGRect(x: -900, y: 0, width: 30, height: 900), CGRect(x: -850, y: 0, width: 30, height: 900)]) == nil, "display gap is not visible")
}
checkLookup("names beyond snapshot display length still match only in full") {
    let full = String(repeating: "x", count: 150)
    var request = validLookupRequest; request["name"] = full
    try expectLookup(try validateLookup(lookupCandidate(name: full), query: LookupQuery(request)) != nil, "full AX label must not use snapshot's 120-character truncation")
    request["name"] = String(repeating: "x", count: 119) + "…"
    try expectLookup(try validateLookup(lookupCandidate(name: full), query: LookupQuery(request)) == nil, "snapshot display prefix must never become an exact match")
}
checkLookup("invalid ancestor clips and partial display visibility fail closed") {
    try expectLookup(try validateLookup(lookupCandidate(), clips: [.zero]) == nil, "empty parent viewport cannot expose its child")
    try expectLookup(try validateLookup(lookupCandidate(), displays: [CGRect(x: -890, y: 0, width: 1000, height: 900)]) == nil, "partially offscreen target cannot match")
}
checkLookup("any overlapping higher window makes visibility incomplete") {
    try expectLookupFailure("incomplete") { _ = try validateLookup(lookupCandidate(), occluders: [CGRect(x: -895, y: 165, width: 1, height: 1)]) }
    try expectLookup(try validateLookup(lookupCandidate(), occluders: [CGRect(x: -800, y: 160, width: 20, height: 30)]) != nil, "unrelated window must not block")
}
let validLookupMatch = try validateLookup(lookupCandidate())!
checkLookup("complete search distinguishes no match from duplicate matches") {
    try expectLookup(lookupResult([], incomplete: nil)["status"] as? String == "not_found", "complete empty search")
    let result = lookupResult([validLookupMatch, validLookupMatch], incomplete: nil)
    try expectLookup(result["status"] as? String == "ambiguous" && result["target"] == nil, "duplicate matches cannot select first")
}
checkLookup("a partial search never proves absence, uniqueness, or a usable target") {
    for matches in [[], [validLookupMatch], [validLookupMatch, validLookupMatch]] {
        let result = lookupResult(matches, incomplete: "Traversal or name budget exhausted")
        try expectLookup(result["status"] as? String == "incomplete" && result["target"] == nil, "partial search must fail closed")
    }
}
checkLookup("diagnostic candidates and messages are bounded, with label truncation disclosed") {
    let match = LookupMatch(name: String(repeating: "x", count: 512), role: "button", windowID: 42, rect: validLookupMatch.rect)
    let result = lookupResult(Array(repeating: match, count: 100), incomplete: String(repeating: "x", count: 1000))
    let candidates = result["candidates"] as? [[String: Any]] ?? []
    try expectLookup(candidates.count <= 8 && !candidates.isEmpty, "bounded candidate count")
    try expectLookup((candidates[0]["name"] as? String)?.count ?? 1000 <= 120 && candidates[0]["nameTruncated"] as? Bool == true, "display-only truncation must be explicit")
    try expectLookup((result["message"] as? String)?.count ?? 1000 <= 240, "bounded message")
    try expectLookup(candidates.allSatisfy { $0["target"] == nil && $0["rect"] == nil }, "diagnostics must not look like actionable coordinates")
    _ = try JSONSerialization.data(withJSONObject: result)
}
checkLookup("bounded reader rejects system-wide objects rather than changing the global AX timeout") {
    try expectLookupFailure("incomplete") { try LookupReader().prepare(AXUIElementCreateSystemWide()) }
}
checkLookup("existing releaseSnapshot command remains compatible") {
    let result = try handle(["cmd": "releaseSnapshot", "generation": "missing"]) as? [String: Any]
    try expectLookup(result?["released"] as? Bool == true, "existing dispatch changed")
}
checkLookup("only a current trusted overlay identity can exempt its bounded window IDs") {
    let executable = "/fixture/CuaPreview.app/Contents/MacOS/CuaPreview"
    let record: [String: Any] = ["version": 1, "pid": 4242, "process": "4242:1700000000.25", "windows": [31, 32]]
    func windows(_ value: [String: Any], process: String = "4242:1700000000.25", actual: String? = nil) -> Set<CGWindowID> {
        lookupOverlayWindowIDs(value, pid: 4242, process: process, executable: actual ?? executable, trustedExecutable: executable)
    }
    try expectLookup(windows(record) == Set([31, 32]), "current overlay window IDs")
    try expectLookup(windows(record, process: "4242:1700000001.25").isEmpty, "PID reuse must reject the old identity")
    try expectLookup(windows(record, actual: "/foreign/CuaPreview").isEmpty, "a matching process or bundle name is not enough")
    for (key, values) in [("version", [true, 2] as [Any]), ("pid", [42, true] as [Any]),
                          ("windows", [[31, 31], [0], [-1], [1.5], [true], Array(1...17)] as [Any])] {
        for value in values { var bad = record; bad[key] = value; try expectLookup(windows(bad).isEmpty, "malformed \(key) must fail closed") }
    }
    let guide = (pid: pid_t(4242), windows: Set<CGWindowID>([31]))
    let info: [String: Any] = [kCGWindowOwnerPID as String: 4242, kCGWindowNumber as String: 31, kCGWindowLayer as String: Int(CGWindowLevelForKey(.screenSaverWindow))]
    try expectLookup(lookupIsGuideWindow(info, overlay: guide), "known annotation window")
    for (key, value) in [(kCGWindowOwnerPID as String, 4243), (kCGWindowNumber as String, 32), (kCGWindowLayer as String, 25)] {
        var other = info; other[key] = value
        try expectLookup(!lookupIsGuideWindow(other, overlay: guide), "foreign owner/window and interactive panels remain occluders")
    }
}
print("\(lookupChecks) native lookup checks passed (no live AX or GUI checks)")
