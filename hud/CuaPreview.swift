import AppKit

// CuaPreview - the HUD. A chrome-less card showing what the agent is driving, with
// the agent's OWN cursor drawn on top (the user's real cursor is never involved).
// Hover reveals two bare glyphs: close, and take-over (opens the live browser).
// Needs no permissions: it only reads files the cua daemon / agent write.

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let runDir = ProcessInfo.processInfo.environment["CUA_RUN_DIR"] ?? "\(home)/Library/Application Support/cua/run"
let configPath = ProcessInfo.processInfo.environment["CUA_CONFIG"] ?? "\(home)/.config/cua/config.json"
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
        arrow.fillColor = NSColor(calibratedWhite: 0.05, alpha: 1).cgColor
        arrow.strokeColor = NSColor.white.cgColor; arrow.lineWidth = 2.2; arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor; arrow.shadowOpacity = 0.35; arrow.shadowRadius = 1.5; arrow.shadowOffset = CGSize(width: 0, height: 1)
        holder.addSublayer(arrow)
        layer?.addSublayer(holder)
    }
    required init?(coder: NSCoder) { nil }
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

    func move(to p: CGPoint, click: Bool) {
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

    func hide() { vis.target = 0; run() }

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
        let idle = target == nil && settleAt == nil
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

/// One agent's cursor on one screen: the spring arrow, a label pill and a highlight ring.
final class PointerMark {
    let cursor: AgentCursor, pill = NSTextField(labelWithString: ""), ring = CAShapeLayer()
    let color: NSColor
    var shownAt: Date?, labelUntil = Date.distantPast
    init(in view: NSView, color: NSColor, scale: CGFloat) {
        self.color = color
        cursor = AgentCursor(frame: view.bounds, color: color)
        cursor.autoresizingMask = [.width, .height]
        view.addSubview(cursor)
        ring.fillColor = color.withAlphaComponent(0.10).cgColor; ring.strokeColor = color.cgColor; ring.lineWidth = 2.5
        ring.shadowColor = color.cgColor; ring.shadowOpacity = 0.8; ring.shadowRadius = 8; ring.shadowOffset = .zero; ring.opacity = 0
        view.layer?.addSublayer(ring)
        pill.font = .systemFont(ofSize: 13 * scale, weight: .semibold); pill.textColor = .white
        pill.wantsLayer = true; pill.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor
        pill.layer?.cornerRadius = 9 * scale; pill.alignment = .center; pill.isHidden = true
        view.addSubview(pill)
    }
    func remove() { cursor.removeFromSuperview(); pill.removeFromSuperview(); ring.removeFromSuperlayer() }
}

final class PointerOverlay: NSObject, NSApplicationDelegate {
    let path = "\(runDir)/pointers.json"
    var windows: [(screen: NSScreen, window: OverlayWindow, view: FlippedView)] = []
    var marks: [String: [Int: PointerMark]] = [:]          // cursor id -> screen index -> mark
    var seen: [String: Double] = [:]                         // cursor id -> last target time
    var emptySince: Date?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard holdLock("pointer.lock") else { exit(0) }   // one overlay; a second launch leaves it alone
        buildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.buildWindows() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    func buildWindows() {
        for m in marks.values.flatMap({ $0.values }) { m.remove() }
        marks = [:]; seen = [:]
        windows.forEach { $0.window.orderOut(nil) }
        windows = NSScreen.screens.map { s in
            let w = OverlayWindow(screen: s), v = FlippedView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.wantsLayer = true; w.contentView = v; w.orderFrontRegardless()
            return (s, w, v)
        }
    }

    /// Global top-left points (CGWindow space) for a target, following its window as it moves.
    func resolve(_ t: [String: Any]) -> (point: CGPoint, rect: CGRect?)? {
        if let s = t["screen"] as? [NSNumber], s.count == 2 { return (CGPoint(x: s[0].doubleValue, y: s[1].doubleValue), nil) }
        guard let id = (t["windowId"] as? NSNumber)?.uint32Value,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let b = info[kCGWindowBounds as String] as? [String: Double], let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
        if let r = t["rect"] as? [String: NSNumber] {
            let rect = CGRect(x: x + (r["x"]?.doubleValue ?? 0) * w, y: y + (r["y"]?.doubleValue ?? 0) * h,
                              width: (r["w"]?.doubleValue ?? 0) * w, height: (r["h"]?.doubleValue ?? 0) * h)
            return (CGPoint(x: rect.midX, y: rect.midY), rect)
        }
        guard let nx = (t["x"] as? NSNumber)?.doubleValue, let ny = (t["y"] as? NSNumber)?.doubleValue else { return nil }
        return (CGPoint(x: x + nx * w, y: y + ny * h), nil)
    }

    /// Global top-left point -> point in one screen's flipped view (nil when on another screen).
    func local(_ p: CGPoint, _ s: NSScreen) -> CGPoint? {
        let top = NSScreen.screens.first?.frame.maxY ?? s.frame.maxY
        let q = CGPoint(x: p.x - s.frame.minX, y: p.y - (top - s.frame.maxY))
        return q.x >= -40 && q.y >= -40 && q.x <= s.frame.width + 40 && q.y <= s.frame.height + 40 ? q : nil
    }

    func tick() {
        // the daemon removes the file on shutdown: nothing left to draw
        guard fm.fileExists(atPath: path) else { NSApp.terminate(nil); return }
        let doc = readJSON(path)
        let cursors = doc["cursors"] as? [String: [String: Any]] ?? [:]
        let labelSeconds = (doc["labelSeconds"] as? NSNumber)?.doubleValue ?? 6, idle = (doc["idleSeconds"] as? NSNumber)?.doubleValue ?? 8
        let scale = CGFloat((doc["scale"] as? NSNumber)?.doubleValue ?? 1)
        let now = Date()
        for (id, perScreen) in marks where cursors[id] == nil { perScreen.values.forEach { $0.remove() }; marks[id] = nil; seen[id] = nil }
        for (id, c) in cursors {
            guard let target = c["target"] as? [String: Any], let at = resolve(target) else { marks[id]?.values.forEach { $0.cursor.hide() }; continue }
            let t = (c["t"] as? NSNumber)?.doubleValue ?? 0, fresh = seen[id] != t
            seen[id] = t
            let kind = c["kind"] as? String ?? "point", text = c["label"] as? String ?? ""
            let color = hexColor(c["color"] as? String ?? "#339cff")
            let age = now.timeIntervalSince1970 - t / 1000
            for (i, entry) in windows.enumerated() {
                let mark = marks[id]?[i] ?? { let m = PointerMark(in: entry.view, color: color, scale: scale); marks[id, default: [:]][i] = m; return m }()
                guard let p = local(at.point, entry.screen), age < idle else { mark.cursor.hide(); mark.pill.isHidden = true; mark.ring.opacity = 0; continue }
                // the arrow's tip sits on the target; moves follow the target as its window moves
                mark.cursor.move(to: p, click: fresh && kind == "click")
                if fresh { mark.labelUntil = now.addingTimeInterval(text.isEmpty && kind != "rect" ? 0 : labelSeconds) }
                let showLabel = now < mark.labelUntil
                mark.pill.isHidden = !(showLabel && !text.isEmpty)
                if !mark.pill.isHidden {
                    mark.pill.stringValue = text
                    let size = mark.pill.intrinsicContentSize
                    mark.pill.frame = NSRect(x: p.x + 18 * scale, y: p.y + 14 * scale, width: size.width + 18 * scale, height: size.height + 8 * scale)
                }
                if let r = at.rect, kind == "rect", showLabel, let o = local(CGPoint(x: r.minX, y: r.minY), entry.screen) {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    mark.ring.path = CGPath(roundedRect: CGRect(x: o.x - 4, y: o.y - 4, width: r.width + 8, height: r.height + 8), cornerWidth: 8, cornerHeight: 8, transform: nil)
                    CATransaction.commit()
                    mark.ring.opacity = 1
                } else { mark.ring.opacity = 0 }
            }
        }
        // quit after a quiet minute (idle cursors count as quiet); the daemon relaunches on the next point
        let live = cursors.values.contains { now.timeIntervalSince1970 - ((($0["t"] as? NSNumber)?.doubleValue ?? 0) / 1000) < idle }
        if !live { emptySince = emptySince ?? now; if now.timeIntervalSince(emptySince!) > 60 { NSApp.terminate(nil) } } else { emptySince = nil }
    }
}

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let pointerMode = CommandLine.arguments.contains("--pointer")
let delegate: NSApplicationDelegate = pointerMode ? PointerOverlay() : AppDelegate()
app.delegate = delegate
app.run()
