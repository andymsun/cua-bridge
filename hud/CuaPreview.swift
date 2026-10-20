import AppKit

// CuaPreview - the HUD. A chrome-less card showing what the agent is driving, with
// the agent's OWN cursor drawn on top (the user's real cursor is never involved).
// Hover reveals two bare glyphs: close, and take-over (opens the live browser).
// Needs no permissions: it only reads files the cua daemon / agent write.

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let runDir = ProcessInfo.processInfo.environment["CUA_RUN_DIR"] ?? (Bundle.main.object(forInfoDictionaryKey: "CuaRunDir") as? String) ?? "\(home)/Library/Application Support/cua/run"
let configPath = ProcessInfo.processInfo.environment["CUA_CONFIG"] ?? (Bundle.main.object(forInfoDictionaryKey: "CuaConfigPath") as? String) ?? "\(home)/.config/cua/config.json"
let previewID: String? = {
    guard let index = CommandLine.arguments.firstIndex(of: "--view"), index + 1 < CommandLine.arguments.count else { return nil }
    guard let id = UUID(uuidString: CommandLine.arguments[index + 1]) else { exit(2) }
    return id.uuidString.lowercased()
}()
let previewMetadata = previewID.map { "\(runDir)/view-\($0).json" }
let framePath = previewID.map { "\(runDir)/view-\($0).jpg" } ?? "\(runDir)/frame.jpg", cursorPath = "\(runDir)/cursor.json", statusPath = "\(runDir)/status.txt"
let hostPath = "\(runDir)/host.json"

func readJSON(_ p: String) -> [String: Any] {
    guard let d = fm.contents(atPath: p), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

/// hud.mode "auto": the app the latest agent call came from. The daemon records the calling
/// harness's process ancestry (nearest first) and inherited bundle id; the host is the nearest
/// regular app that has a window, so helpers, shells and the CLI itself are skipped.
var autoHostCache: (key: Data, pid: Int32)?
func autoHost() -> Int32? {
    guard let data = fm.contents(atPath: hostPath) else { return nil }
    if let c = autoHostCache, c.key == data, NSRunningApplication(processIdentifier: c.pid)?.isTerminated == false { return c.pid }
    let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    // Any window counts, not only on-screen ones: the host may be on another Space right now.
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let owners = Set(windows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
    func usable(_ a: NSRunningApplication) -> Bool { a.activationPolicy == .regular && owners.contains(a.processIdentifier) }
    var pid = ((o["ancestors"] as? [NSNumber]) ?? []).lazy.compactMap { NSRunningApplication(processIdentifier: $0.int32Value) }.first(where: usable)?.processIdentifier
    if pid == nil, let id = o["bundleId"] as? String {
        pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: usable)?.processIdentifier
    }
    // A miss is retried every tick: the host may not have opened a window yet.
    autoHostCache = pid.map { (data, $0) }
    return pid
}

/// Defaults of the keys quick settings writes; values equal to these are not stored,
/// matching how the daemon saves the config.
let quickDefaults: [String: Any] = ["mode": "auto", "anchor": "bottom-right", "width": 460, "opacity": 1.0,
                                    "showAgentCursor": true, "hideWhenHostInactive": true]

func saveHud(_ key: String, _ value: Any) {
    var all: [String: Any] = [:]
    if let d = fm.contents(atPath: configPath) {
        // Never replace a config we cannot read with one that only holds this change.
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { NSSound.beep(); return }
        all = o
    }
    var h = all["hud"] as? [String: Any] ?? [:]
    if let d = quickDefaults[key], NSDictionary(dictionary: ["v": d]).isEqual(to: ["v": value]) { h.removeValue(forKey: key) } else { h[key] = value }
    if h.isEmpty { all.removeValue(forKey: "hud") } else { all["hud"] = h }
    guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    do { try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: configPath), options: .atomic) } catch { NSSound.beep() }
}

/// Hold an exclusive lock for this process's lifetime; false when another instance has it.
/// The HUD and the pointer overlay are separate instances of this app, so each takes its own.
func holdLock(_ name: String) -> Bool {
    let fd = open("\(runDir)/\(name)", O_CREAT | O_RDWR, 0o600)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0   // the descriptor stays open on purpose
}

/// A menu item that runs a closure.
final class ClosureItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, on: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self; state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("unused") }
    @objc private func fire() { run() }
}

func hexColor(_ hex: String) -> NSColor {
    var h = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    guard h.count >= 6, let v = UInt64(h.prefix(6), radix: 16) else { return NSColor(red: 0.2, green: 0.61, blue: 1, alpha: 1) }
    return NSColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

struct Cfg: Equatable {
    var enabled = true, mode = "auto", attachTo = "", anchor = "bottom-right"
    var hideWhenHostInactive = true, clickThrough = false, showAgentCursor = true
    var margin: CGFloat = 16, width: CGFloat = 460, opacity: CGFloat = 1, cornerRadius: CGFloat = 10
    var controlsCorner = "top-left", glyphClose = "xmark", glyphAction = "hand.raised", glyphSettings = "slider.horizontal.3", glyphTint = "auto"
    var glyphSize: CGFloat = 20, glyphInset: CGFloat = 14, glyphGap: CGFloat = 26, scrimOpacity: CGFloat = 0.38
    var hoverFadeIn = 0.12, hoverFadeOut = 0.25, cursorColor = "#339cff"
    var webPort = 47821
    var hostPid: Int32?, hostWindowID: UInt32?
    /// Pinned to a host window: explicitly, or by auto once the host app is known.
    var attached: Bool { mode == "attached" || (mode == "auto" && hostPid != nil) }

    static func load() -> Cfg {
        let all = readJSON(configPath)
        let h = all["hud"] as? [String: Any] ?? [:]
        var c = Cfg()
        func s(_ k: String) -> String? { h[k] as? String }
        func n(_ k: String) -> CGFloat? { (h[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
        func b(_ k: String) -> Bool? { h[k] as? Bool }
        c.enabled = b("enabled") ?? c.enabled; c.mode = s("mode") ?? c.mode; c.attachTo = s("attachTo") ?? c.attachTo
        c.anchor = s("anchor") ?? c.anchor; c.hideWhenHostInactive = b("hideWhenHostInactive") ?? c.hideWhenHostInactive
        c.clickThrough = b("clickThrough") ?? c.clickThrough; c.showAgentCursor = b("showAgentCursor") ?? c.showAgentCursor
        c.margin = n("margin") ?? c.margin; c.width = n("width") ?? c.width; c.opacity = n("opacity") ?? c.opacity
        c.cornerRadius = n("cornerRadius") ?? c.cornerRadius; c.controlsCorner = s("controlsCorner") ?? c.controlsCorner
        c.glyphClose = s("glyphClose") ?? c.glyphClose; c.glyphAction = s("glyphAction") ?? c.glyphAction
        c.glyphSettings = s("glyphSettings") ?? c.glyphSettings
        c.glyphTint = s("glyphTint") ?? c.glyphTint; c.glyphSize = n("glyphSize") ?? c.glyphSize
        c.glyphInset = n("glyphInset") ?? c.glyphInset; c.glyphGap = n("glyphGap") ?? c.glyphGap
        c.scrimOpacity = n("scrimOpacity") ?? c.scrimOpacity; c.cursorColor = s("cursorColor") ?? c.cursorColor
        c.hoverFadeIn = Double(n("hoverFadeIn") ?? CGFloat(c.hoverFadeIn)); c.hoverFadeOut = Double(n("hoverFadeOut") ?? CGFloat(c.hoverFadeOut))
        if let w = all["web"] as? [String: Any], let p = w["port"] as? NSNumber { c.webPort = p.intValue }
        c.hostPid = (h["hostPid"] as? NSNumber)?.int32Value
        c.hostWindowID = (h["hostWindowId"] as? NSNumber)?.uint32Value
        if let metadata = previewMetadata {
            let host = readJSON(metadata)["host"] as? [String: Any] ?? [:]
            c.hostPid = (host["pid"] as? NSNumber)?.int32Value
            c.hostWindowID = (host["windowId"] as? NSNumber)?.uint32Value
            c.enabled = true; c.mode = c.hostPid == nil ? "normal" : "attached"
        } else if c.mode == "auto" {
            c.hostPid = autoHost(); c.hostWindowID = nil
        }
        return c
    }
}

/// Bare SF Symbol glyph, no background.
final class Glyph: NSView {
    var onClick: (() -> Void)?
    private let iv = NSImageView()
    private var hot = false
    var symbol: String { didSet { apply() } }
    var tint: NSColor = .white { didSet { apply() } }
    init(symbol: String, size: CGFloat) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        iv.frame = bounds; iv.autoresizingMask = [.width, .height]; iv.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iv); apply()
    }
    required init?(coder: NSCoder) { nil }
    private func apply() {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        img?.isTemplate = true
        iv.image = img
        iv.contentTintColor = tint.withAlphaComponent(hot ? 1 : 0.85)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hot = true; apply() }
    override func mouseExited(with e: NSEvent) { hot = false; apply() }
    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) { if hot { onClick?() } }
}

/// The agent's own cursor: an arrow that glides to each target, plus a click ripple.
/// A damped spring parameterised like SwiftUI: response (s) and damping fraction.
struct Spring {
    var value: CGFloat, target: CGFloat, v: CGFloat = 0, response: CGFloat, damping: CGFloat
    init(_ x: CGFloat, _ response: CGFloat, _ damping: CGFloat) { value = x; target = x; self.response = response; self.damping = damping }
    mutating func snap(_ x: CGFloat) { value = x; target = x; v = 0 }
    mutating func step(_ dt: CGFloat) {
        let k = pow(2 * .pi / max(0.001, response), 2), c = 4 * .pi * damping / max(0.001, response)
        var t: CGFloat = 0
        while t < dt { v += (k * (target - value) - c * v) / 240; value += v / 240; t += 1 / 240 }
        if abs(target - value) < 0.01 && abs(v) < 0.05 { value = target; v = 0 }
    }
    var settled: Bool { value == target && v == 0 }
}

/// The agent's cursor, matching the live view's: a rounded arrowhead on springs that
/// curves along long moves, scoots on short ones and settles with a small wiggle.
final class AgentCursor: NSView {
    static let size: CGFloat = 24, tip: CGFloat = 3.6, rest: CGFloat = -44, far: CGFloat = 196
    private let holder = CALayer()
    private var x = Spring(0, 0.19, 0.9), y = Spring(0, 0.19, 0.9), rot = Spring(rest, 0.12, 0.9)
    private var stretch = Spring(1, 0.2, 0.85), squash = Spring(1, 0.05, 0.82), tilt = Spring(0, 0.05, 0.82)
    private var vis = Spring(0, 0.42, 0.86), press = Spring(1, 0.16, 0.6)
    private var curve: (a: CGPoint, c: CGPoint, b: CGPoint, p: Spring)?
    private var scoot: (a: CGPoint, b: CGPoint, tilt: CGFloat)?
    private var target: CGPoint?, pendingClick = false, placed = false, axis: CGFloat = 0
    private var settleAt: CFTimeInterval?, timer: Timer?, last: CFTimeInterval = 0
    private var trace: (lead: [CGPoint], points: [CGPoint], start: CFTimeInterval, leadTime: Double, duration: Double, progress: (CGFloat) -> Void)?
    var isTracing: Bool { trace != nil }

    override var isFlipped: Bool { true }       // y-down, like the frame coordinates it receives

    init(frame: NSRect, color: NSColor) {
        super.init(frame: frame)
        wantsLayer = true
        holder.bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        holder.anchorPoint = CGPoint(x: Self.tip / Self.size, y: Self.tip / Self.size)
        holder.opacity = 0
        let path = AgentCursor.glyphPath()
        for (radius, alpha) in [(15.0, 0.45), (6.0, 0.9)] {     // coloured glow, wide then tight
            let g = CAShapeLayer(); g.path = path; g.fillColor = NSColor.black.cgColor
            g.shadowColor = color.cgColor; g.shadowOpacity = Float(alpha); g.shadowRadius = CGFloat(radius); g.shadowOffset = .zero
            holder.addSublayer(g)
        }
        let arrow = CAShapeLayer()
        arrow.path = path
        arrow.fillColor = color.cgColor
        arrow.strokeColor = NSColor.white.cgColor; arrow.lineWidth = 2.2; arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor; arrow.shadowOpacity = 0.35; arrow.shadowRadius = 1.5; arrow.shadowOffset = CGSize(width: 0, height: 1)
        holder.addSublayer(arrow)
        layer?.addSublayer(holder)
    }
    required init?(coder: NSCoder) { nil }
    deinit { timer?.invalidate() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    /// Rounded arrowhead, tip near (3.6, 3.6), pointing up-left (y-down coordinates).
    static func glyphPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 4.2, y: 3.4))
        p.addCurve(to: CGPoint(x: 3.4, y: 4.2), control1: CGPoint(x: 3.7, y: 3.2), control2: CGPoint(x: 3.2, y: 3.7))
        p.addLine(to: CGPoint(x: 9.7, y: 20.5))
        p.addCurve(to: CGPoint(x: 10.8, y: 20.5), control1: CGPoint(x: 9.9, y: 21.0), control2: CGPoint(x: 10.6, y: 21.0))
        p.addLine(to: CGPoint(x: 13.3, y: 14.3))
        p.addCurve(to: CGPoint(x: 13.7, y: 13.9), control1: CGPoint(x: 13.4, y: 14.1), control2: CGPoint(x: 13.5, y: 14.0))
        p.addLine(to: CGPoint(x: 19.9, y: 11.4))
        p.addCurve(to: CGPoint(x: 19.9, y: 10.3), control1: CGPoint(x: 20.4, y: 11.2), control2: CGPoint(x: 20.4, y: 10.5))
        p.closeSubpath()
        return p
    }

    func begin(at point: CGPoint) {
        guard !placed, point.x.isFinite, point.y.isFinite else { return }
        placed = true; x.snap(point.x); y.snap(point.y); vis.snap(1); tick()
    }

    func follow(_ points: [CGPoint], duration: Double, progress: @escaping (CGFloat) -> Void) {
        guard let first = points.first, let end = points.last else { return }
        trace?.progress(1); trace = nil; curve = nil; scoot = nil; target = nil; settleAt = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || duration == 0 { move(to: end, click: false); progress(1); return }
        if !placed { x.snap(first.x); y.snap(first.y); placed = true }
        let from = CGPoint(x: x.value, y: y.value), distance = hypot(from.x-first.x, from.y-first.y)
        let lead = distance < 1 ? 0 : min(0.5, max(0.12, Double(distance)/1500))
        trace = (PointerGeometry.flight(from: from, to: first), points, CACurrentMediaTime(), lead, max(0.1,duration), progress)
        vis.target = 1; progress(0); run()
    }

    func move(to p: CGPoint, click: Bool) {
        if trace != nil { trace?.progress(1); trace = nil }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            curve = nil; scoot = nil; target = nil; settleAt = nil; pendingClick = false; placed = true
            x.snap(p.x); y.snap(p.y); rot.snap(Self.rest); stretch.snap(1); squash.snap(1); tilt.snap(0); press.snap(1); vis.snap(1)
            tick(); return
        }
        vis.target = 1
        if !placed || vis.value < 0.05 {
            placed = true; x.snap(p.x); y.snap(p.y); curve = nil; scoot = nil
            if click { press.value = 0.82; press.target = 1 }
            run(); return
        }
        let a = CGPoint(x: x.value, y: y.value), dx = p.x - a.x, dy = p.y - a.y, dist = hypot(dx, dy)
        if dist < 0.5 { if click { press.value = 0.82; press.target = 1; run() }; return }
        settleAt = nil; pendingClick = click; target = p
        if dist <= Self.far {
            axis = atan2(dy, dx) * 180 / .pi
            scoot = (a, p, max(-1, min(1, dx / dist * 0.75 - dy / dist * 0.62)) * 70 * 0.15); curve = nil
            x.target = p.x; y.target = p.y; x.response = 0.19; y.response = 0.19
        } else {
            axis = 0
            let bow = min(0.22, 40 / dist) * dist, nx = -dy / dist, ny = dx / dist
            let c = CGPoint(x: (a.x + p.x) / 2 + nx * bow, y: (a.y + p.y) / 2 + ny * bow)
            let response = min(0.7, max(0.32, dist / 1400))
            var sp = Spring(0, response, 0.94); sp.target = 1
            curve = (a, c, p, sp); scoot = nil
            x.response = min(0.12, max(0.035, response * 0.18)); y.response = x.response
        }
        run()
    }

    func hide() {
        trace = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { vis.snap(0); tick() }
        else if vis.target != 0 { vis.target = 0; run() }
    }

    private func run() {
        guard timer == nil else { return }
        last = 0
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 20, last == 0 ? 1.0 / 60 : now - last)); last = now
        let px = x.value, py = y.value
        if let path = trace {
            let elapsed = now - path.start, drawing = elapsed >= path.leadTime
            let raw = CGFloat(drawing ? (elapsed-path.leadTime)/path.duration : elapsed/max(0.001,path.leadTime))
            let t = max(0,min(1,raw)), eased = t*t*(3-2*t)
            let point = PointerGeometry.along(drawing ? path.points : path.lead, progress: eased)
            x.snap(point.x); y.snap(point.y)
            if hypot(point.x-px,point.y-py)>0.1 { rot.target = angleTo(rot.value, Self.rest+atan2(point.y-py,point.x-px)*180 / .pi+135) }
            path.progress(drawing ? eased : 0)
            if drawing && t >= 1 { trace = nil; rot.target = angleTo(rot.value,Self.rest); stretch.target = 1 }
        }
        if var cv = curve {
            cv.p.step(dt); curve = cv
            let t = min(1, max(0, cv.p.value)), u = 1 - t
            x.target = u * u * cv.a.x + 2 * u * t * cv.c.x + t * t * cv.b.x
            y.target = u * u * cv.a.y + 2 * u * t * cv.c.y + t * t * cv.b.y
            let tx = 2 * u * (cv.c.x - cv.a.x) + 2 * t * (cv.b.x - cv.c.x), ty = 2 * u * (cv.c.y - cv.a.y) + 2 * t * (cv.b.y - cv.c.y)
            rot.target = angleTo(rot.value, Self.rest + atan2(ty, tx) * 180 / .pi + 135)
        }
        for s in [\AgentCursor.x, \.y, \.rot, \.stretch, \.squash, \.tilt, \.vis, \.press] as [ReferenceWritableKeyPath<AgentCursor, Spring>] { self[keyPath: s].step(dt) }
        let speed = hypot(x.value - px, y.value - py) / max(dt, 1 / 240)
        stretch.target = min(1, max(0.65, 1 - speed / 5500))
        if let sc = scoot {
            let d2 = max(0.0001, pow(sc.b.x - sc.a.x, 2) + pow(sc.b.y - sc.a.y, 2))
            let t = min(1, max(0, ((x.value - sc.a.x) * (sc.b.x - sc.a.x) + (y.value - sc.a.y) * (sc.b.y - sc.a.y)) / d2))
            let bump = sin(t * .pi)
            squash.target = 1 - 0.15 * bump; tilt.target = sc.tilt * bump
        }
        if let b = target, hypot(x.value - b.x, y.value - b.y) < 0.85, abs(x.v) < 12, abs(y.v) < 12, (curve?.p.value ?? 1) > 0.999 {
            x.snap(b.x); y.snap(b.y); curve = nil; scoot = nil; target = nil
            rot.target = angleTo(rot.value, Self.rest); squash.target = 1; tilt.target = 0; stretch.target = 1
            settleAt = now
            if pendingClick { press.value = 0.82; press.v = 0; press.target = 1 }
        }
        var r = rot.value
        if let s0 = settleAt {
            let t = CGFloat(now - s0), env = sin(min(1, t / 1.4) * .pi)
            r += sin(t / 0.66 * .pi * 2) * env * 10
            if t >= 1.4 { settleAt = nil }
        }
        let v = min(1, max(0, vis.value)), scale = (0.4 + 0.6 * v) * press.value
        let rad = { (deg: CGFloat) in deg * .pi / 180 }
        var m = CATransform3DIdentity
        m = CATransform3DRotate(m, rad(axis), 0, 0, 1)
        m = CATransform3DScale(m, 1, squash.value, 1)
        m = CATransform3DRotate(m, rad(-axis), 0, 0, 1)
        m = CATransform3DRotate(m, rad(r - Self.rest + tilt.value), 0, 0, 1)
        m = CATransform3DScale(m, scale * stretch.value, scale, 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        holder.position = CGPoint(x: x.value, y: y.value)
        holder.transform = m
        holder.opacity = Float(v)
        CATransaction.commit()
        let idle = trace == nil && target == nil && settleAt == nil
            && [x, y, rot, stretch, squash, tilt, vis, press].allSatisfy { $0.settled }
        if idle { timer?.invalidate(); timer = nil }
    }

    private func angleTo(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
        var d = to - from
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return from + d
    }
}

/// Whole-surface drag with explicit mouse tracking (reliable on a non-activating panel).
final class Surface: NSView {
    var onHover: ((Bool) -> Void)?
    var onDrag: (() -> Void)?
    private var start: NSPoint?, origin: NSPoint?
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { start = NSEvent.mouseLocation; origin = window?.frame.origin }
    override func mouseDragged(with e: NSEvent) {
        guard let s = start, let o = origin, let w = window else { return }
        let now = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: o.x + now.x - s.x, y: o.y + now.y - s.y))
        onDrag?()
    }
    override func mouseUp(with e: NSEvent) { start = nil; origin = nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSPanel!
    var surface: Surface!
    var imageView: NSImageView!
    var cursor: AgentCursor!
    var controls: NSView!
    var scrim: CAGradientLayer!
    var closeGlyph: Glyph!, actionGlyph: Glyph!, settingsGlyph: Glyph!
    var cfg = Cfg.load()
    var lastFrame: Date?, lastCursorT: Double = 0
    var hovering = false, userMoved = false
    var lastTint = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if previewID == nil, !holdLock("hud.lock") { exit(0) }   // one HUD; per-view previews are independent
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: cfg.width, height: cfg.width * 0.625),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.becomesKeyOnlyIfNeeded = true; window.hidesOnDeactivate = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true

        surface = Surface(frame: window.contentView!.bounds)
        surface.autoresizingMask = [.width, .height]; surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        surface.layer?.masksToBounds = true
        surface.onHover = { [weak self] on in self?.setHover(on) }
        surface.onDrag = { [weak self] in self?.userMoved = true }
        window.contentView = surface

        imageView = NSImageView(frame: surface.bounds)
        imageView.autoresizingMask = [.width, .height]; imageView.imageScaling = .scaleAxesIndependently
        imageView.unregisterDraggedTypes()
        surface.addSubview(imageView)

        cursor = AgentCursor(frame: surface.bounds, color: hexColor(cfg.cursorColor)); cursor.autoresizingMask = [.width, .height]
        surface.addSubview(cursor)

        controls = NSView(frame: surface.bounds); controls.autoresizingMask = [.width, .height]
        controls.wantsLayer = true; controls.alphaValue = 0
        surface.addSubview(controls)
        scrim = CAGradientLayer(); scrim.type = .radial
        controls.layer?.addSublayer(scrim)

        closeGlyph = Glyph(symbol: cfg.glyphClose, size: cfg.glyphSize)
        closeGlyph.onClick = {
            if let metadata = previewMetadata { try? fm.removeItem(atPath: metadata) }
            NSApp.terminate(nil)
        }
        actionGlyph = Glyph(symbol: cfg.glyphAction, size: cfg.glyphSize)
        actionGlyph.onClick = { [weak self] in self?.takeOver() }
        settingsGlyph = Glyph(symbol: cfg.glyphSettings, size: cfg.glyphSize)
        settingsGlyph.onClick = { [weak self] in self?.showQuickSettings() }
        controls.addSubview(closeGlyph); controls.addSubview(actionGlyph); controls.addSubview(settingsGlyph)

        applyChrome(); layoutControls()
        window.center(); window.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tickFrame() }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tickConfig() }
    }

    /// Take over: open the live, interactive browser view (or bring the native app forward).
    func takeOver() {
        let target = readJSON(previewMetadata ?? "\(runDir)/target.json")
        if target["pid"] != nil {
            DispatchQueue.global().async {
                func failure(_ message: String) { DispatchQueue.main.async {
                    let alert = NSAlert(); alert.messageText = "Cannot take over this window"; alert.informativeText = message; alert.runModal()
                } }
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { failure("Cannot create local connection"); return }
                defer { close(fd) }
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array("\(runDir)/agent.sock".utf8)
                guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { failure("Socket path is too long"); return }
                withUnsafeMutableBytes(of: &address.sun_path) { b in b.copyBytes(from: bytes); b[bytes.count] = 0 }
                let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                guard connected == 0 else { failure("CuaAgent is not reachable"); return }
                var request = target; request["cmd"] = "activateWindow"; request["id"] = 1
                guard var data = try? JSONSerialization.data(withJSONObject: request) else { failure("Invalid target"); return }
                data.append(10)
                let sent = data.withUnsafeBytes { b -> Bool in
                    var offset = 0
                    while offset < data.count {
                        let n = write(fd, b.baseAddress!.advanced(by: offset), data.count - offset)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { return false }; offset += n
                    }
                    return true
                }
                guard sent else { failure("Connection closed; not retried"); return }
                var buffer = [UInt8](repeating: 0, count: 4096), response = Data()
                while !response.contains(10) && response.count < 65536 {
                    let n = read(fd, &buffer, buffer.count)
                    if n <= 0 { failure("No confirmation received; not retried"); return }
                    response.append(buffer, count: n)
                }
                guard let result = try? JSONSerialization.jsonObject(with: response) as? [String: Any], result["ok"] as? Bool == true else {
                    let result = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
                    failure(result?["error"] as? String ?? "Invalid helper response"); return
                }
            }
            return
        }
        if previewID != nil { return }
        let token = (try? String(contentsOfFile: "\(runDir)/token", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = URL(string: "http://127.0.0.1:\(cfg.webPort)/?t=\(token)") { NSWorkspace.shared.open(url) }
    }

    /// The settings people change while watching, one click away from the card.
    func showQuickSettings() {
        let menu = NSMenu(), current = cfg
        func header(_ title: String) { menu.addItem(.sectionHeader(title: title)) }
        func add(_ title: String, on: Bool = false, _ run: @escaping () -> Void) { menu.addItem(ClosureItem(title, on: on, run)) }

        header("Position")
        let host = cfg.mode == "auto" ? cfg.hostPid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } : nil
        add(host.map { "Follow the app the agent started in (\($0))" } ?? "Follow the app the agent started in", on: cfg.mode == "auto") { saveHud("mode", "auto") }
        if cfg.mode == "attached" { add("Pinned to \(cfg.attachTo.isEmpty ? "a host window" : cfg.attachTo)", on: true) {} }
        add("Float above everything", on: cfg.mode == "overlay") { saveHud("mode", "overlay") }
        add("Ordinary window", on: cfg.mode == "normal") { saveHud("mode", "normal") }
        if cfg.attached {
            for (title, value) in [("Top left", "top-left"), ("Top right", "top-right"), ("Bottom left", "bottom-left"), ("Bottom right", "bottom-right"), ("Center", "center")] {
                add("  \(title)", on: cfg.anchor == value) { [weak self] in self?.userMoved = false; saveHud("anchor", value) }
            }
            if userMoved { add("Snap back to the corner") { [weak self] in self?.userMoved = false } }
        }
        menu.addItem(.separator())
        header("Size")
        for (title, width) in [("Small", 320), ("Medium", 460), ("Large", 640)] {
            add(title, on: Int(cfg.width) == width) { saveHud("width", width) }
        }
        header("Opacity")
        for percent in [100, 85, 70, 50] {
            add("\(percent)%", on: Int((cfg.opacity * 100).rounded()) == percent) { saveHud("opacity", Double(percent) / 100) }
        }
        menu.addItem(.separator())
        add("Show the agent's cursor", on: cfg.showAgentCursor) { saveHud("showAgentCursor", !current.showAgentCursor) }
        if cfg.attached { add("Hide when the app isn't active", on: cfg.hideWhenHostInactive) { saveHud("hideWhenHostInactive", !current.hideWhenHostInactive) } }
        menu.addItem(.separator())
        add("All settings…") {
            let token = (try? String(contentsOfFile: "\(runDir)/token", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let url = URL(string: "http://127.0.0.1:\(current.webPort)/settings?t=\(token)") { NSWorkspace.shared.open(url) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: settingsGlyph.frame.minX, y: settingsGlyph.frame.minY), in: controls)
    }

    func setHover(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? cfg.hoverFadeIn : cfg.hoverFadeOut
            controls.animator().alphaValue = on ? 1 : 0
        }
    }

    func applyChrome() {
        window.alphaValue = cfg.opacity
        window.ignoresMouseEvents = cfg.clickThrough
        window.level = cfg.attached || cfg.mode == "overlay" ? .floating : .normal
        window.collectionBehavior = cfg.attached ? [.managed, .fullScreenAuxiliary] : [.canJoinAllSpaces, .fullScreenAuxiliary]
        surface.layer?.cornerRadius = cfg.cornerRadius
        closeGlyph.symbol = cfg.glyphClose; actionGlyph.symbol = cfg.glyphAction; settingsGlyph.symbol = cfg.glyphSettings
        cursor.isHidden = !cfg.showAgentCursor
    }

    func layoutControls() {
        let w = surface.bounds.width, h = surface.bounds.height, gs = cfg.glyphSize
        let top = cfg.controlsCorner.hasPrefix("top"), left = cfg.controlsCorner.hasSuffix("left")
        let y = top ? h - cfg.glyphInset - gs : cfg.glyphInset
        closeGlyph.frame = NSRect(x: left ? cfg.glyphInset : w - cfg.glyphInset - gs, y: y, width: gs, height: gs)
        actionGlyph.frame = NSRect(x: left ? cfg.glyphInset + cfg.glyphGap : w - cfg.glyphInset - gs - cfg.glyphGap, y: y, width: gs, height: gs)
        settingsGlyph.frame = NSRect(x: left ? cfg.glyphInset + 2 * cfg.glyphGap : w - cfg.glyphInset - gs - 2 * cfg.glyphGap, y: y, width: gs, height: gs)
        scrim.frame = CGRect(x: left ? 0 : w - 220, y: top ? h - 150 : 0, width: 220, height: 150)
        scrim.startPoint = CGPoint(x: left ? 0 : 1, y: top ? 1 : 0)
        scrim.endPoint = CGPoint(x: left ? 0.62 : 0.38, y: top ? 0.15 : 0.85)
    }

    /// Glyphs dark on light pages, light on dark pages. Samples a 16x10 thumbnail of the
    /// controls corner at most every 1.5s - never the full frame.
    func retint(_ img: NSImage) {
        if Date().timeIntervalSince(lastTint) < 1.5 { return }
        lastTint = Date()
        var light = false
        if cfg.glyphTint == "auto", let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let cw = 16, ch = 10
            let region = CGRect(x: cfg.controlsCorner.hasSuffix("left") ? 0 : cg.width * 3 / 4,
                                y: cfg.controlsCorner.hasPrefix("top") ? 0 : cg.height * 3 / 4,
                                width: cg.width / 4, height: cg.height / 4)
            var px = [UInt8](repeating: 0, count: cw * ch * 4)
            if let crop = cg.cropping(to: region),
               let c = CGContext(data: &px, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                c.interpolationQuality = .low
                c.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
                var total = 0
                for i in stride(from: 0, to: px.count, by: 4) { total += Int(px[i]) * 299 + Int(px[i + 1]) * 587 + Int(px[i + 2]) * 114 }
                light = Double(total) / Double(cw * ch * 1000 * 255) > 0.55
            }
        } else { light = cfg.glyphTint == "dark" }
        let tint: NSColor = light ? .black : .white
        closeGlyph.tint = tint; actionGlyph.tint = tint; settingsGlyph.tint = tint
        let base: CGFloat = light ? 1 : 0
        scrim.colors = [NSColor(calibratedWhite: base, alpha: cfg.scrimOpacity).cgColor, NSColor(calibratedWhite: base, alpha: 0).cgColor]
    }

    func tickFrame() {
        if let metadata = previewMetadata, !fm.fileExists(atPath: metadata) { NSApp.terminate(nil); return }
        if !fm.fileExists(atPath: framePath) { imageView.image = nil; lastFrame = nil; cursor.hide() }
        if let a = try? fm.attributesOfItem(atPath: framePath), let stamp = a[.modificationDate] as? Date, stamp != lastFrame,
           let d = fm.contents(atPath: framePath), let img = NSImage(data: d), img.size.width > 1 {
            lastFrame = stamp
            imageView.image = img
            retint(img)
            let h = (img.size.height / img.size.width) * window.frame.width
            if abs(window.frame.height - h) > 1 {
                var f = window.frame; f.origin.y += f.size.height - h; f.size.height = h
                window.setFrame(f, display: true); layoutControls()
            }
        }
        let c = readJSON(cursorPath)
        if let metadata = previewMetadata {
            let target = readJSON(metadata)
            guard (c["app"] as? NSNumber) == (target["pid"] as? NSNumber),
                  (c["windowId"] as? NSNumber) == (target["windowId"] as? NSNumber) else { cursor.hide(); return }
        }
        if let t = (c["t"] as? NSNumber)?.doubleValue, t != lastCursorT,
           let x = (c["x"] as? NSNumber)?.doubleValue, let y = (c["y"] as? NSNumber)?.doubleValue {
            lastCursorT = t
            let b = surface.bounds
            cursor.move(to: CGPoint(x: CGFloat(x) * b.width, y: CGFloat(y) * b.height), click: (c["kind"] as? String) == "click")
        }
    }

    func hostWindow() -> CGRect? {
        if let metadata = previewMetadata, let pid = cfg.hostPid {
            let host = readJSON(metadata)["host"] as? [String: Any] ?? [:]
            guard let launch = NSRunningApplication(processIdentifier: pid)?.launchDate,
                  host["process"] as? String == "\(pid):\(launch.timeIntervalSince1970)" else { return nil }
        }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let screen = NSScreen.screens.first else { return nil }
        var matches: [CGRect] = []
        for w in info {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let ownerMatches = cfg.hostPid.map { (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == $0 }
                ?? (!cfg.attachTo.isEmpty && owner.localizedCaseInsensitiveCompare(cfg.attachTo) == .orderedSame)
            guard ownerMatches,
                  cfg.hostWindowID.map({ (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value == $0 }) ?? true,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double], let x = b["X"], let y = b["Y"], let bw = b["Width"], let bh = b["Height"],
                  bw * bh > 100_000 else { continue }
            let r = CGRect(x: x, y: Double(screen.frame.height) - y - bh, width: bw, height: bh)
            matches.append(r)
        }
        // auto follows the host app's front window (the list is front to back); explicit
        // attachment never guesses between several windows.
        return cfg.mode == "auto" ? matches.first : matches.count == 1 ? matches[0] : nil
    }

    func tickConfig() {
        let c = Cfg.load()
        if c != cfg {
            let widthChanged = c.width != cfg.width
            if c.hostPid != cfg.hostPid { userMoved = false }   // a new host: snap to it
            cfg = c; applyChrome()
            if widthChanged { var f = window.frame; f.size.width = c.width; window.setFrame(f, display: true) }
            layoutControls()
        }
        if !cfg.enabled { if window.isVisible { window.orderOut(nil) }; return }
        guard cfg.attached else { if !window.isVisible { window.orderFrontRegardless() }; return }
        if cfg.hideWhenHostInactive {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            let active = (cfg.hostPid.map { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0 }
                ?? (!cfg.attachTo.isEmpty && front.localizedCaseInsensitiveCompare(cfg.attachTo) == .orderedSame)) || NSApp.isActive
            if active { if !window.isVisible { window.orderFrontRegardless() } } else if window.isVisible { window.orderOut(nil) }
            if !active { return }
        }
        guard let host = hostWindow() else { window.orderOut(nil); return }
        guard !userMoved else { return }
        let s = window.frame.size, m = cfg.margin
        let p: NSPoint
        switch cfg.anchor {
        case "top-left": p = NSPoint(x: host.minX + m, y: host.maxY - s.height - m)
        case "top-right": p = NSPoint(x: host.maxX - s.width - m, y: host.maxY - s.height - m)
        case "bottom-left": p = NSPoint(x: host.minX + m, y: host.minY + m)
        case "center": p = NSPoint(x: host.midX - s.width / 2, y: host.midY - s.height / 2)
        default: p = NSPoint(x: host.maxX - s.width - m, y: host.minY + m)
        }
        if abs(window.frame.origin.x - p.x) > 1 || abs(window.frame.origin.y - p.y) > 1 { window.setFrameOrigin(p) }
    }
}

// MARK: - on-screen pointer (`--pointer`)

/// A click-through layer over one screen. Never key, never main, never in the way.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .screenSaver; ignoresMouseEvents = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A cursor and a readable café card. The surrounding window stays click-through.
final class PointerMark {
    let cursor: AgentCursor, pill = FlippedView(), title = NSTextField(labelWithString: ""), body = NSTextField(wrappingLabelWithString: ""), ring = CAShapeLayer(), leader = CAShapeLayer()
    let color: NSColor
    var labelUntil = Date.distantPast
    var annotationLayers: [String: CAShapeLayer] = [:], lastMotion: String?
    weak var canvas: NSView?
    init(in view: NSView, color: NSColor, scale: CGFloat) {
        self.color = color; canvas = view
        cursor = AgentCursor(frame: view.bounds, color: color); cursor.autoresizingMask = [.width, .height]; view.addSubview(cursor)
        ring.fillColor = color.withAlphaComponent(0.10).cgColor; ring.strokeColor = color.cgColor; ring.lineWidth = 2.5
        ring.shadowColor = color.cgColor; ring.shadowOpacity = 0.4; ring.shadowRadius = 8; ring.opacity = 0
        view.layer?.addSublayer(ring)
        leader.strokeColor = color.cgColor; leader.lineWidth = 1.5; leader.lineDashPattern = [3, 3]; leader.opacity = 0
        view.layer?.addSublayer(leader)
        pill.wantsLayer = true; pill.layer?.backgroundColor = hexColor("#fffaf1").cgColor; pill.layer?.cornerRadius = 13
        pill.layer?.borderColor = color.withAlphaComponent(0.75).cgColor; pill.layer?.borderWidth = 1.5
        pill.layer?.shadowColor = NSColor.black.cgColor; pill.layer?.shadowOpacity = 0.18; pill.layer?.shadowRadius = 12; pill.layer?.shadowOffset = CGSize(width: 0, height: -3)
        title.font = .systemFont(ofSize: 10 * scale, weight: .bold); title.textColor = hexColor("#795034")
        body.font = .systemFont(ofSize: 13 * scale, weight: .medium); body.textColor = hexColor("#302820"); body.maximumNumberOfLines = 5
        pill.addSubview(title); pill.addSubview(body); pill.isHidden = true; view.addSubview(pill)
    }
    func label(_ text: String, name: String, state: String, at point: CGPoint, bounds: CGRect, occupied: [CGRect]) -> CGRect {
        title.stringValue = ["pointing", "idle"].contains(state) ? name : name + " · " + state
        body.stringValue = text
        let preferred = max((text as NSString).size(withAttributes:[.font:body.font!]).width, (title.stringValue as NSString).size(withAttributes:[.font:title.font!]).width) + 24
        let width = min(min(250, bounds.width - 24), max(110, preferred))
        let height = max(18, body.cell!.cellSize(forBounds: CGRect(x:0,y:0,width:width-24,height:120)).height)
        let frame = PointerGeometry.bubble(at: point, size: CGSize(width: width, height: height + 42), bounds: bounds, occupied: occupied)
        pill.frame = frame; title.frame = CGRect(x: 12, y: 9, width: frame.width - 24, height: 14)
        body.frame = CGRect(x: 12, y: 27, width: frame.width - 24, height: height + 4)
        return frame
    }
    func annotations(_ shapes: [[String: Any]], motion: String?, local: (CGPoint) -> CGPoint, resolve: ([String: Any]) -> (point: CGPoint, rect: CGRect?)?) {
        let ids = Set(shapes.compactMap { $0["id"] as? String })
        for id in Array(annotationLayers.keys) where !ids.contains(id) { annotationLayers.removeValue(forKey: id)?.removeFromSuperlayer() }
        for shape in shapes {
            guard let id = shape["id"] as? String, let kind = shape["kind"] as? String else { continue }
            let rect = (shape["target"] as? [String: Any]).flatMap { resolve($0)?.rect }
            let raw = (shape["points"] as? [[NSNumber]] ?? []).filter { $0.count == 2 }.map { CGPoint(x:$0[0].doubleValue,y:$0[1].doubleValue) }
            let points = PointerGeometry.stroke(kind: kind, rect: rect, points: raw).map(local)
            guard let first = points.first else { annotationLayers[id]?.opacity = 0; continue }
            let layer = annotationLayers[id] ?? { let layer = CAShapeLayer(); canvas?.layer?.insertSublayer(layer, at: 1); annotationLayers[id] = layer; return layer }()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let path = CGMutablePath(); path.move(to:first); points.dropFirst().forEach { path.addLine(to:$0) }
            layer.path = path; layer.fillColor = nil; layer.strokeColor = color.cgColor; layer.lineCap = .round; layer.lineJoin = .round
            layer.lineWidth = kind == "highlight" ? max(4,rect?.height ?? 20) : 3
            layer.opacity = kind == "highlight" ? 0.28 : 0.95
            CATransaction.commit()
            if motion == id && lastMotion != id {
                lastMotion = id
                let age = Date().timeIntervalSince1970 - ((shape["t"] as? NSNumber)?.doubleValue ?? 0)/1000
                let duration = age < 3 ? ((shape["durationMs"] as? NSNumber)?.doubleValue ?? 900)/1000 : 0
                cursor.follow(points, duration:duration) { [weak layer] progress in
                    CATransaction.begin(); CATransaction.setDisableActions(true); layer?.strokeEnd = progress; CATransaction.commit()
                }
            }
        }
    }
    func hide() { cursor.hide(); pill.isHidden = true; ring.opacity = 0; leader.opacity = 0; annotationLayers.values.forEach { $0.opacity = 0 } }
    func remove() { cursor.removeFromSuperview(); pill.removeFromSuperview(); ring.removeFromSuperlayer(); leader.removeFromSuperlayer(); annotationLayers.values.forEach { $0.removeFromSuperlayer() } }
}

final class PointerOverlay: NSObject, NSApplicationDelegate {
    let path = "\(runDir)/pointers.json"
    var windows: [(screen: NSScreen, window: OverlayWindow, view: FlippedView, shade: CAShapeLayer)] = []
    var marks: [String: [Int: PointerMark]] = [:]
    var seen: [String: Double] = [:]
    var emptySince: Date?, watcher: DispatchSourceFileSystemObject?, watcherFD: Int32 = -1
    var modified: Date?, document: [String: Any] = [:]
    var boundsByID: [UInt32: CGRect] = [:]
    var readMouse: () -> CGPoint = { NSEvent.mouseLocation }
    var presenceTimer: Timer?, lastMouse = CGPoint.zero

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard holdLock("pointer.lock") else { exit(0) }
        buildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.buildWindows(); self?.tick() }
        watcherFD = open(runDir, O_EVTONLY)
        if watcherFD >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watcherFD, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.refresh() }; source.resume(); watcher = source
        }
        // File notifications deliver new targets immediately. This slow timer follows native windows and expires labels.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh(); self?.tick() }
        refresh()
    }
    func refresh() {
        guard let attributes = try? fm.attributesOfItem(atPath: path), let date = attributes[.modificationDate] as? Date else { NSApp.terminate(nil); return }
        guard modified != date else { return }
        modified = date; document = readJSON(path); tick()
    }
    func buildWindows() {
        marks.values.flatMap { $0.values }.forEach { $0.remove() }; marks = [:]; seen = [:]
        windows.forEach { $0.window.close() }
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen), view = FlippedView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true; view.layer?.masksToBounds = true
            let shade = CAShapeLayer(); shade.fillColor = NSColor.black.withAlphaComponent(0.34).cgColor; shade.fillRule = .evenOdd; shade.opacity = 0
            view.layer?.addSublayer(shade); window.contentView = view; window.orderFrontRegardless()
            return (screen, window, view, shade)
        }
        let application = NSRunningApplication.current
        if let launched = application.launchDate {
            let record: [String: Any] = ["version": 1, "pid": Int(application.processIdentifier),
                "process": "\(application.processIdentifier):\(launched.timeIntervalSince1970)",
                "windows": windows.map { $0.window.windowNumber }]
            do {
                let url = URL(fileURLWithPath: "\(runDir)/pointer-windows.json")
                try JSONSerialization.data(withJSONObject: record).write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { NSLog("Could not publish guide window identity: %@", error.localizedDescription) }
        }
    }
    func resolve(_ t: [String: Any]) -> (point: CGPoint, rect: CGRect?)? {
        if let s = t["screen"] as? [NSNumber], s.count == 2 { return (CGPoint(x: s[0].doubleValue, y: s[1].doubleValue), nil) }
        if let r = t["screenRect"] as? [String: NSNumber], let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"] {
            let rect = CGRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
            return (CGPoint(x: rect.midX, y: rect.midY), rect)
        }
        guard let id = (t["windowId"] as? NSNumber)?.uint32Value, let bounds = boundsByID[id] else { return nil }
        if let r = t["rect"] as? [String: NSNumber] {
            let rect = CGRect(x: bounds.minX + CGFloat(r["x"]?.doubleValue ?? 0) * bounds.width, y: bounds.minY + CGFloat(r["y"]?.doubleValue ?? 0) * bounds.height,
                              width: CGFloat(r["w"]?.doubleValue ?? 0) * bounds.width, height: CGFloat(r["h"]?.doubleValue ?? 0) * bounds.height)
            return (CGPoint(x: rect.midX, y: rect.midY), rect)
        }
        guard let x = t["x"] as? NSNumber, let y = t["y"] as? NSNumber else { return nil }
        return (CGPoint(x: bounds.minX + CGFloat(x.doubleValue) * bounds.width, y: bounds.minY + CGFloat(y.doubleValue) * bounds.height), nil)
    }
    func tick(updateWindows: Bool = true) {
        let cursors = document["cursors"] as? [String: [String: Any]] ?? [:]
        let labelSeconds = (document["labelSeconds"] as? NSNumber)?.doubleValue ?? 6, idle = (document["idleSeconds"] as? NSNumber)?.doubleValue ?? 8
        let scale = max(0.7, min(2, CGFloat((document["scale"] as? NSNumber)?.doubleValue ?? 1)))
        let now = Date(), top = NSScreen.screens.first?.frame.maxY ?? 0
        let live = cursors.filter { (_, c) in (c["persistent"] as? Bool ?? false) || now.timeIntervalSince1970 - ((c["t"] as? NSNumber)?.doubleValue ?? 0) / 1000 < idle }
        if updateWindows { boundsByID = [:] }
        if updateWindows && live.values.contains(where: { c in
            (c["target"] as? [String: Any])?["windowId"] != nil || (c["annotations"] as? [[String: Any]] ?? []).contains { ($0["target"] as? [String: Any])?["windowId"] != nil }
        }) {
            let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for info in infos {
                if let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, let raw = info[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) { boundsByID[id] = rect }
            }
        }
        for id in Array(marks.keys) where cursors[id] == nil { marks[id]?.values.forEach { $0.remove() }; marks[id] = nil; seen[id] = nil }
        var occupied: [Int: [CGRect]] = [:], spotlights: [Int: (time: Double, rect: CGRect)] = [:]
        var occupiedTips: [CGPoint] = [], hasPresence = false
        lastMouse = readMouse()
        let mouse = CGPoint(x:lastMouse.x,y:top-lastMouse.y)
        let screens = windows.map { CGRect(x: $0.screen.frame.minX, y: top - $0.screen.frame.maxY, width: $0.screen.frame.width, height: $0.screen.frame.height) }
        for id in cursors.keys.sorted() {
            guard let c = live[id], let target = c["target"] as? [String: Any] else { marks[id]?.values.forEach { $0.hide() }; continue }
            let t = (c["t"] as? NSNumber)?.doubleValue ?? 0, fresh = seen[id] != t; seen[id] = t
            let tracing = marks[id]?.values.contains { $0.cursor.isTracing } ?? false
            let returning = c["state"] as? String == "done" && now.timeIntervalSince1970-t/1000 >= 2.5 && !tracing
            guard let at = resolve(target) ?? (returning ? (point:mouse,rect:nil) : nil) else {marks[id]?.values.forEach{$0.hide()};continue}
            let kind = c["kind"] as? String ?? "point", text = c["label"] as? String ?? ""
            let persistent = c["persistent"] as? Bool ?? false
            let mouseScreen = screens.first { $0.contains(mouse) }
            let home = returning ? mouseScreen.map { PointerGeometry.companion(at:mouse,bounds:$0) } : nil
            hasPresence = hasPresence || home != nil
            let tip = PointerGeometry.cursor(at: home ?? at.point, occupied: occupiedTips + [mouse], screens: screens); occupiedTips.append(tip)
            for (i, entry) in windows.enumerated() {
                let mark = marks[id]?[i] ?? { let m = PointerMark(in: entry.view, color: hexColor(c["color"] as? String ?? "#ad794c"), scale: scale); marks[id, default: [:]][i] = m; return m }()
                let p = PointerGeometry.local(tip, screen: entry.screen.frame, primaryTop: top)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                if !returning && tip != at.point {
                    let path = CGMutablePath(); path.move(to: p); path.addLine(to: PointerGeometry.local(at.point, screen: entry.screen.frame, primaryTop: top))
                    mark.leader.path = path; mark.leader.opacity = 0.75
                } else { mark.leader.opacity = 0 }
                CATransaction.commit()
                // Every screen receives the same global flight, including its offscreen portions.
                if let origin = c["origin"] as? [String: NSNumber], let x = origin["x"], let y = origin["y"] {
                    mark.cursor.begin(at: PointerGeometry.local(CGPoint(x: x.doubleValue, y: y.doubleValue), screen: entry.screen.frame, primaryTop: top))
                }
                let motion = c["motion"] as? String
                mark.annotations(c["annotations"] as? [[String: Any]] ?? [], motion: motion, local: { PointerGeometry.local($0, screen: entry.screen.frame, primaryTop: top) }, resolve: resolve)
                if motion == nil || !mark.cursor.isTracing { mark.cursor.move(to: p, click: fresh && kind == "click") }
                if fresh { mark.labelUntil = now.addingTimeInterval(labelSeconds) }
                let show = persistent || now < mark.labelUntil
                mark.pill.isHidden = !(show && !text.isEmpty && entry.view.bounds.contains(p))
                if !mark.pill.isHidden {
                    var avoid = occupied[i] ?? []
                    let human = PointerGeometry.local(mouse,screen:entry.screen.frame,primaryTop:top)
                    avoid.append(CGRect(x:human.x-16,y:human.y-16,width:32,height:32))
                    if let area = at.rect { avoid.append(CGRect(origin: PointerGeometry.local(area.origin, screen: entry.screen.frame, primaryTop: top), size: area.size)) }
                    let frame = mark.label(text, name: c["name"] as? String ?? "Andy", state: c["state"] as? String ?? "pointing", at: p, bounds: entry.view.bounds, occupied: avoid)
                    occupied[i, default: []].append(frame)
                }
                if let r = at.rect, ["rect", "spotlight"].contains(kind), show {
                    let origin = PointerGeometry.local(r.origin, screen: entry.screen.frame, primaryTop: top)
                    let rect = CGRect(origin: origin, size: r.size).insetBy(dx: -4, dy: -4)
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    mark.ring.path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil); mark.ring.opacity = 1
                    CATransaction.commit()
                    if kind == "spotlight", entry.view.bounds.intersects(rect), t >= (spotlights[i]?.time ?? 0) { spotlights[i] = (t, rect) }
                } else { mark.ring.opacity = 0 }
            }
        }
        for (i, entry) in windows.enumerated() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if let spot = spotlights[i] { let path = CGMutablePath(); path.addRect(entry.view.bounds); path.addRoundedRect(in: spot.rect, cornerWidth: 8, cornerHeight: 8); entry.shade.path = path; entry.shade.opacity = 1 }
            else { entry.shade.opacity = 0 }
            CATransaction.commit()
        }
        if hasPresence && presenceTimer == nil {
            let timer = Timer(timeInterval:1.0/30,repeats:true) { [weak self] _ in
                guard let self=self,self.readMouse() != self.lastMouse else{return}
                self.tick(updateWindows:false)
            }
            RunLoop.main.add(timer,forMode:.common);presenceTimer=timer
        } else if !hasPresence {presenceTimer?.invalidate();presenceTimer=nil}
        if live.isEmpty { emptySince = emptySince ?? now; if now.timeIntervalSince(emptySince!) > 60 { NSApp.terminate(nil) } } else { emptySince = nil }
    }
    func applicationWillTerminate(_ n: Notification) {
        presenceTimer?.invalidate(); watcher?.cancel(); if watcherFD >= 0 { close(watcherFD) }
        try? fm.removeItem(atPath: "\(runDir)/pointer-windows.json")
    }
}

#if !COMPANION_TEST
@main struct PreviewMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate: NSApplicationDelegate = CommandLine.arguments.contains("--pointer") ? PointerOverlay() : (CommandLine.arguments.contains("--companion") || Bundle.main.bundleIdentifier?.hasSuffix(".barista") == true) ? CompanionDelegate() : AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
