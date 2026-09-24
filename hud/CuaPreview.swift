import AppKit

// CuaPreview - the HUD. A chrome-less card showing what the agent is driving, with
// the agent's OWN cursor drawn on top (the user's real cursor is never involved).
// Hover reveals two bare glyphs: close, and take-over (opens the live browser).
// Needs no permissions: it only reads files the cua daemon / agent write.

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let runDir = ProcessInfo.processInfo.environment["CUA_RUN_DIR"] ?? "\(home)/Library/Application Support/cua/run"
let configPath = ProcessInfo.processInfo.environment["CUA_CONFIG"] ?? "\(home)/.config/cua/config.json"
let framePath = "\(runDir)/frame.jpg", cursorPath = "\(runDir)/cursor.json", statusPath = "\(runDir)/status.txt"

func readJSON(_ p: String) -> [String: Any] {
    guard let d = fm.contents(atPath: p), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

struct Cfg: Equatable {
    var enabled = true, mode = "attached", attachTo = "Claude", anchor = "bottom-right"
    var hideWhenHostInactive = true, clickThrough = false, showAgentCursor = true
    var margin: CGFloat = 16, width: CGFloat = 460, opacity: CGFloat = 1, cornerRadius: CGFloat = 10
    var controlsCorner = "top-left", glyphClose = "xmark", glyphAction = "hand.raised", glyphTint = "auto"
    var glyphSize: CGFloat = 20, glyphInset: CGFloat = 14, glyphGap: CGFloat = 26, scrimOpacity: CGFloat = 0.38
    var hoverFadeIn = 0.12, hoverFadeOut = 0.25
    var webPort = 47821

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
        c.glyphTint = s("glyphTint") ?? c.glyphTint; c.glyphSize = n("glyphSize") ?? c.glyphSize
        c.glyphInset = n("glyphInset") ?? c.glyphInset; c.glyphGap = n("glyphGap") ?? c.glyphGap
        c.scrimOpacity = n("scrimOpacity") ?? c.scrimOpacity
        c.hoverFadeIn = Double(n("hoverFadeIn") ?? CGFloat(c.hoverFadeIn)); c.hoverFadeOut = Double(n("hoverFadeOut") ?? CGFloat(c.hoverFadeOut))
        if let w = all["web"] as? [String: Any], let p = w["port"] as? NSNumber { c.webPort = p.intValue }
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
final class AgentCursor: NSView {
    let arrow = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let p = CGMutablePath()
        let pts: [CGPoint] = [.init(x: 0, y: 0), .init(x: 0, y: -15), .init(x: 4, y: -11.2), .init(x: 6.6, y: -17), .init(x: 9.2, y: -15.9), .init(x: 6.7, y: -10.2), .init(x: 12, y: -10.2)]
        p.addLines(between: pts); p.closeSubpath()
        arrow.path = p
        arrow.fillColor = NSColor.white.cgColor
        arrow.strokeColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        arrow.lineWidth = 1.1; arrow.lineJoin = .round
        arrow.shadowOpacity = 0.45; arrow.shadowRadius = 1.5; arrow.shadowOffset = CGSize(width: 0, height: -1)
        arrow.opacity = 0
        layer?.addSublayer(arrow)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    func move(to p: CGPoint, click: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        arrow.position = p
        arrow.opacity = 1
        CATransaction.commit()
        guard click else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.ripple(at: p) }
    }
    private func ripple(at p: CGPoint) {
        let r = CAShapeLayer()
        r.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        r.position = p; r.fillColor = nil
        r.strokeColor = NSColor(red: 0.2, green: 0.61, blue: 1, alpha: 1).cgColor; r.lineWidth = 2
        layer?.addSublayer(r)
        let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 0.3; s.toValue = 1.6
        let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 0.9; o.toValue = 0
        let g = CAAnimationGroup(); g.animations = [s, o]; g.duration = 0.55
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        r.opacity = 0; r.add(g, forKey: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { r.removeFromSuperlayer() }
    }
    func hide() { arrow.opacity = 0 }
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
    var closeGlyph: Glyph!, actionGlyph: Glyph!
    var cfg = Cfg.load()
    var lastFrame: Date?, lastCursorT: Double = 0
    var hovering = false, userMoved = false
    var lastTint = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
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

        cursor = AgentCursor(frame: surface.bounds); cursor.autoresizingMask = [.width, .height]
        surface.addSubview(cursor)

        controls = NSView(frame: surface.bounds); controls.autoresizingMask = [.width, .height]
        controls.wantsLayer = true; controls.alphaValue = 0
        surface.addSubview(controls)
        scrim = CAGradientLayer(); scrim.type = .radial
        controls.layer?.addSublayer(scrim)

        closeGlyph = Glyph(symbol: cfg.glyphClose, size: cfg.glyphSize)
        closeGlyph.onClick = { NSApp.terminate(nil) }
        actionGlyph = Glyph(symbol: cfg.glyphAction, size: cfg.glyphSize)
        actionGlyph.onClick = { [weak self] in self?.takeOver() }
        controls.addSubview(closeGlyph); controls.addSubview(actionGlyph)

        applyChrome(); layoutControls()
        window.center(); window.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tickFrame() }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tickConfig() }
    }

    /// Take over: open the live, interactive browser view (or bring the native app forward).
    func takeOver() {
        let src = readJSON(cursorPath)["source"] as? String
        if src == "native", let pid = (readJSON(cursorPath)["app"] as? NSNumber)?.int32Value,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(); return
        }
        let token = (try? String(contentsOfFile: "\(runDir)/token", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = URL(string: "http://127.0.0.1:\(cfg.webPort)/?t=\(token)") { NSWorkspace.shared.open(url) }
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
        window.level = cfg.mode == "normal" ? .normal : .floating
        window.collectionBehavior = cfg.mode == "attached" ? [.managed, .fullScreenAuxiliary] : [.canJoinAllSpaces, .fullScreenAuxiliary]
        surface.layer?.cornerRadius = cfg.cornerRadius
        closeGlyph.symbol = cfg.glyphClose; actionGlyph.symbol = cfg.glyphAction
        cursor.isHidden = !cfg.showAgentCursor
    }

    func layoutControls() {
        let w = surface.bounds.width, h = surface.bounds.height, gs = cfg.glyphSize
        let top = cfg.controlsCorner.hasPrefix("top"), left = cfg.controlsCorner.hasSuffix("left")
        let y = top ? h - cfg.glyphInset - gs : cfg.glyphInset
        closeGlyph.frame = NSRect(x: left ? cfg.glyphInset : w - cfg.glyphInset - gs, y: y, width: gs, height: gs)
        actionGlyph.frame = NSRect(x: left ? cfg.glyphInset + cfg.glyphGap : w - cfg.glyphInset - gs - cfg.glyphGap, y: y, width: gs, height: gs)
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
        closeGlyph.tint = tint; actionGlyph.tint = tint
        let base: CGFloat = light ? 1 : 0
        scrim.colors = [NSColor(calibratedWhite: base, alpha: cfg.scrimOpacity).cgColor, NSColor(calibratedWhite: base, alpha: 0).cgColor]
    }

    func tickFrame() {
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
        if let t = (c["t"] as? NSNumber)?.doubleValue, t != lastCursorT,
           let x = (c["x"] as? NSNumber)?.doubleValue, let y = (c["y"] as? NSNumber)?.doubleValue {
            lastCursorT = t
            let b = surface.bounds
            cursor.move(to: CGPoint(x: CGFloat(x) * b.width, y: b.height - CGFloat(y) * b.height), click: (c["kind"] as? String) == "click")
        }
    }

    func hostWindow() -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let screen = NSScreen.screens.first else { return nil }
        var best: CGRect?
        for w in info {
            guard let owner = w[kCGWindowOwnerName as String] as? String, owner.localizedCaseInsensitiveContains(cfg.attachTo),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double], let x = b["X"], let y = b["Y"], let bw = b["Width"], let bh = b["Height"],
                  bw * bh > 100_000 else { continue }
            let r = CGRect(x: x, y: Double(screen.frame.height) - y - bh, width: bw, height: bh)
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best
    }

    func tickConfig() {
        let c = Cfg.load()
        if c != cfg {
            let widthChanged = c.width != cfg.width
            cfg = c; applyChrome()
            if widthChanged { var f = window.frame; f.size.width = c.width; window.setFrame(f, display: true) }
            layoutControls()
        }
        if !cfg.enabled { if window.isVisible { window.orderOut(nil) }; return }
        guard cfg.mode == "attached" else { if !window.isVisible { window.orderFrontRegardless() }; return }
        if cfg.hideWhenHostInactive {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            let active = front.localizedCaseInsensitiveContains(cfg.attachTo) || NSApp.isActive
            if active { if !window.isVisible { window.orderFrontRegardless() } } else if window.isVisible { window.orderOut(nil) }
            if !active { return }
        }
        guard !userMoved, let host = hostWindow() else { return }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
