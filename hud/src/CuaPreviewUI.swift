import AppKit

// Preview HUD modelled on Codex's "Computer Use" window.
//
// Resting: a rounded card showing the live frame. No title bar, no status text,
// no border chrome of any kind.
// Hover:   two bare glyphs fade in at the TOP-LEFT over a soft radial scrim -
//          close, and hand-back-control. No button backgrounds.
//
// Holds no permissions: renders /tmp/cua-preview/frame.jpg written by CuaCapture,
// and reads host-window bounds from its state.json. Safe to rebuild freely.

let base = ProcessInfo.processInfo.environment["CUA_BRIDGE_HOME"]
    ?? ("~/.claude/cua-bridge" as NSString).expandingTildeInPath
let runtimeDir = ProcessInfo.processInfo.environment["CUA_RUNTIME_DIR"] ?? "/tmp/cua-preview"
let configPath = (base as NSString).appendingPathComponent("config.json")
let framePath = runtimeDir + "/frame.jpg"
let statePath = runtimeDir + "/state.json"

func readJSON(_ p: String) -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: p),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
    return o
}

struct Config: Equatable {
    var mode = "attached", attachTo = "Claude", anchor = "bottom-right"
    var hideWhenHostInactive = true
    var margin: CGFloat = 16, opacity: CGFloat = 1.0, cornerRadius: CGFloat = 10
    var clickThrough = false, width: CGFloat = 460
    // look
    var controlsCorner = "top-left"      // top-left | top-right | bottom-left | bottom-right
    var glyphClose = "xmark"
    var glyphAction = "cursorarrow.click.badge.clock"
    var glyphSize: CGFloat = 20, glyphInset: CGFloat = 14, glyphGap: CGFloat = 26
    var scrimOpacity: CGFloat = 0.38
    var adaptiveGlyphTint = true
    var glyphTint = "auto"               // auto | light | dark
    var hoverFadeIn: Double = 0.12, hoverFadeOut: Double = 0.25
    static func load() -> Config {
        var c = Config(); let o = readJSON(configPath)
        if let v = o["mode"] as? String { c.mode = v }
        if let v = o["attachTo"] as? String { c.attachTo = v }
        if let v = o["anchor"] as? String { c.anchor = v }
        if let v = o["hideWhenHostInactive"] as? Bool { c.hideWhenHostInactive = v }
        if let v = o["margin"] as? Double { c.margin = CGFloat(v) }
        if let v = o["opacity"] as? Double { c.opacity = CGFloat(v) }
        if let v = o["cornerRadius"] as? Double { c.cornerRadius = CGFloat(v) }
        if let v = o["clickThrough"] as? Bool { c.clickThrough = v }
        if let v = o["width"] as? Double { c.width = CGFloat(v) }
        if let v = o["controlsCorner"] as? String { c.controlsCorner = v }
        if let v = o["glyphClose"] as? String { c.glyphClose = v }
        if let v = o["glyphAction"] as? String { c.glyphAction = v }
        if let v = o["glyphSize"] as? Double { c.glyphSize = CGFloat(v) }
        if let v = o["glyphInset"] as? Double { c.glyphInset = CGFloat(v) }
        if let v = o["glyphGap"] as? Double { c.glyphGap = CGFloat(v) }
        if let v = o["scrimOpacity"] as? Double { c.scrimOpacity = CGFloat(v) }
        if let v = o["glyphTint"] as? String { c.glyphTint = v }
        if let v = o["hoverFadeIn"] as? Double { c.hoverFadeIn = v }
        if let v = o["hoverFadeOut"] as? Double { c.hoverFadeOut = v }
        return c
    }
    func write(_ k: String, _ v: Any) {
        var o = readJSON(configPath); o[k] = v
        if let d = try? JSONSerialization.data(withJSONObject: o, options: .prettyPrinted) {
            try? d.write(to: URL(fileURLWithPath: configPath))
        }
    }
}

/// Bare glyph, no background - matches Codex's hover controls.
final class Glyph: NSView {
    var onClick: (() -> Void)?
    private let iv = NSImageView()
    private var hot = false
    private var symbol: String
    var tint: NSColor = .black { didSet { apply() } }

    init(symbol: String, size: CGFloat = 20) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        iv.frame = bounds
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        addSubview(iv)
        apply()
    }
    required init?(coder: NSCoder) { nil }

    private func apply() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            iv.image = img
            iv.contentTintColor = tint.withAlphaComponent(hot ? 1.0 : 0.85)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hot = true; apply() }
    override func mouseExited(with e: NSEvent) { hot = false; apply() }
    override func mouseDown(with e: NSEvent) {}        // swallow: don't start a drag
    override func mouseUp(with e: NSEvent) { if hot { onClick?() } }
}

/// Whole-surface drag. Explicit mouseDown/mouseDragged is reliable on a
/// non-activating panel, where isMovableByWindowBackground often is not.
final class Surface: NSView {
    var onHover: ((Bool) -> Void)?
    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }

    override func mouseDown(with e: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin
    }
    override func mouseDragged(with e: NSEvent) {
        guard let start = dragOrigin, let origin = windowOrigin, let w = window else { return }
        let now = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: origin.x + (now.x - start.x),
                                 y: origin.y + (now.y - start.y)))
        // a manual drag means the user has repositioned it: stop auto-anchoring
        (NSApp.delegate as? AppDelegate)?.userMoved = true
    }
    override func mouseUp(with e: NSEvent) { dragOrigin = nil; windowOrigin = nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSPanel!
    var surface: Surface!
    var imageView: NSImageView!
    var scrim: CAGradientLayer!
    var controls: NSView!
    var closeGlyph: Glyph!
    var handBackGlyph: Glyph!
    var cfg = Config.load()
    var lastFrame: Date?
    var hovering = false
    var userMoved = false

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let w = cfg.width

        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: w * 0.63),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        surface = Surface(frame: window.contentView!.bounds)
        surface.autoresizingMask = [.width, .height]
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        surface.layer?.cornerRadius = cfg.cornerRadius
        surface.layer?.masksToBounds = true
        surface.onHover = { [weak self] on in self?.setHover(on) }
        window.contentView = surface

        imageView = NSImageView(frame: surface.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.unregisterDraggedTypes()
        surface.addSubview(imageView)

        // hover layer: soft radial scrim in the top-left + two bare glyphs
        controls = NSView(frame: surface.bounds)
        controls.autoresizingMask = [.width, .height]
        controls.wantsLayer = true
        controls.alphaValue = 0
        surface.addSubview(controls)

        scrim = CAGradientLayer()
        scrim.type = .radial
        scrim.colors = [NSColor(calibratedWhite: 0, alpha: 0.55).cgColor,
                        NSColor(calibratedWhite: 0, alpha: 0).cgColor]
        scrim.locations = [0, 1]
        scrim.startPoint = CGPoint(x: 0, y: 1)          // top-left
        scrim.endPoint = CGPoint(x: 0.62, y: 0.15)
        controls.layer?.addSublayer(scrim)

        closeGlyph = Glyph(symbol: cfg.glyphClose, size: cfg.glyphSize)
        closeGlyph.onClick = { NSApp.terminate(nil) }
        controls.addSubview(closeGlyph)

        handBackGlyph = Glyph(symbol: cfg.glyphAction, size: cfg.glyphSize)
        handBackGlyph.onClick = { [weak self] in self?.toggleMode() }
        controls.addSubview(handBackGlyph)

        layoutControls()
        applyChrome()
        window.center()
        window.orderFrontRegardless()

        Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in self?.tickFrame() }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tickConfig() }
    }

    func layoutControls() {
        let inset = cfg.glyphInset, gap = cfg.glyphGap
        let w = surface.bounds.width, h = surface.bounds.height
        let gs = closeGlyph.frame.height
        let top = cfg.controlsCorner.hasPrefix("top")
        let left = cfg.controlsCorner.hasSuffix("left")
        let y = top ? h - inset - gs : inset
        let x0 = left ? inset : w - inset - gs
        let x1 = left ? inset + gap : w - inset - gs - gap
        closeGlyph.frame.origin = NSPoint(x: x0, y: y)
        handBackGlyph.frame.origin = NSPoint(x: x1, y: y)
        let sw: CGFloat = 220, sh: CGFloat = 150
        scrim.frame = CGRect(x: left ? 0 : w - sw, y: top ? h - sh : 0, width: sw, height: sh)
        scrim.startPoint = CGPoint(x: left ? 0 : 1, y: top ? 1 : 0)
        scrim.endPoint = CGPoint(x: left ? 0.62 : 0.38, y: top ? 0.15 : 0.85)
    }

    func setHover(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? self.cfg.hoverFadeIn : self.cfg.hoverFadeOut
            controls.animator().alphaValue = on ? 1 : 0
        }
    }

    func toggleMode() {
        let next = cfg.mode == "overlay" ? "attached" : "overlay"
        cfg.write("mode", next)
    }

    func applyChrome() {
        window.alphaValue = cfg.opacity
        window.ignoresMouseEvents = cfg.clickThrough
        window.level = cfg.mode == "normal" ? .normal : .floating
        window.collectionBehavior = cfg.mode == "attached"
            ? [.managed, .fullScreenAuxiliary] : [.canJoinAllSpaces, .fullScreenAuxiliary]
        surface.layer?.cornerRadius = cfg.cornerRadius
    }

    /// Glyphs go dark on light pages, light on dark ones - Codex's look on white
    /// pages, still legible on dark ones.
    func retintGlyphs(from img: NSImage) {
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff) else { return }
        let w = min(90, bmp.pixelsWide), h = min(60, bmp.pixelsHigh)
        var total: CGFloat = 0, n: CGFloat = 0
        for x in stride(from: 0, to: w, by: 6) {
            for y in stride(from: 0, to: h, by: 6) {
                guard let c = bmp.colorAt(x: x, y: y) else { continue }
                total += c.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0.5; n += 1
            }
        }
        guard n > 0 else { return }
        let lightPage = (total / n) > 0.55
        let tint: NSColor
        switch cfg.glyphTint {
        case "light": tint = .white
        case "dark":  tint = .black
        default:      tint = lightPage ? .black : .white
        }
        closeGlyph.tint = tint
        handBackGlyph.tint = tint
        let scrimWhite: CGFloat = lightPage ? 1 : 0
        scrim.colors = [NSColor(calibratedWhite: scrimWhite, alpha: cfg.scrimOpacity).cgColor,
                        NSColor(calibratedWhite: scrimWhite, alpha: 0).cgColor]
    }

    func tickFrame() {
        guard let a = try? FileManager.default.attributesOfItem(atPath: framePath),
              let stamp = a[.modificationDate] as? Date, stamp != lastFrame else { return }
        lastFrame = stamp
        guard let d = FileManager.default.contents(atPath: framePath),
              let img = NSImage(data: d), img.size.width > 1 else { return }
        imageView.image = img
        retintGlyphs(from: img)
        let w = window.frame.width
        let h = (img.size.height / img.size.width) * w
        if abs(window.frame.height - h) > 1 {
            var f = window.frame
            f.origin.y += (f.size.height - h)
            f.size.height = h
            window.setFrame(f, display: true)
            layoutControls()
        }
    }

    func tickConfig() {
        let c = Config.load()
        if c != cfg {
            let widthChanged = c.width != cfg.width
            cfg = c; applyChrome()
            if widthChanged {
                var f = window.frame; f.size.width = c.width; window.setFrame(f, display: true)
                layoutControls()
            }
        }
        let st = readJSON(statePath)
        guard cfg.mode == "attached" else {
            if !window.isVisible { window.orderFrontRegardless() }
            return
        }
        if cfg.hideWhenHostInactive {
            let front = (st["frontmost"] as? String) ?? ""
            let active = front.localizedCaseInsensitiveContains(cfg.attachTo)
                || front.localizedCaseInsensitiveContains("CuaPreview") || NSApp.isActive
            if active { if !window.isVisible { window.orderFrontRegardless() } }
            else if window.isVisible { window.orderOut(nil) }
            if !active { return }
        }
        guard !userMoved,                                   // respect a manual drag
              let b = st["hostBounds"] as? [String: Double],
              let hx = b["x"], let hy = b["y"], let hw = b["w"], let hh = b["h"] else { return }
        let s = window.frame.size, m = cfg.margin
        var p: NSPoint
        switch cfg.anchor {
        case "top-left":    p = NSPoint(x: hx + m, y: hy + hh - s.height - m)
        case "top-right":   p = NSPoint(x: hx + hw - s.width - m, y: hy + hh - s.height - m)
        case "bottom-left": p = NSPoint(x: hx + m, y: hy + m)
        case "center":      p = NSPoint(x: hx + hw/2 - s.width/2, y: hy + hh/2 - s.height/2)
        default:            p = NSPoint(x: hx + hw - s.width - m, y: hy + m)
        }
        if abs(window.frame.origin.x - p.x) > 1 || abs(window.frame.origin.y - p.y) > 1 {
            window.setFrameOrigin(p)
        }
    }
}

let app = NSApplication.shared
let d = AppDelegate()
app.delegate = d
app.run()
