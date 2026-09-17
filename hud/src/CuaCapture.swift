import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

// Capture daemon. This binary holds the Screen Recording grant and is meant to
// stay FROZEN - the UI lives in a separate app so its look can be changed
// without invalidating TCC (macOS keys the grant to this binary's cdhash).
//
// Reads : config.json (width/fps/showCursor/attachTo), stream/target.json
// Writes: /tmp/cua-preview/frame.jpg   (atomic swap)
//         /tmp/cua-preview/state.json  (stream status + host window bounds)

let base = ProcessInfo.processInfo.environment["CUA_BRIDGE_HOME"]
    ?? ("~/.claude/cua-bridge" as NSString).expandingTildeInPath
let runtimeDir = ProcessInfo.processInfo.environment["CUA_RUNTIME_DIR"] ?? "/tmp/cua-preview"
let configPath = (base as NSString).appendingPathComponent("config.json")
let targetPath = (base as NSString).appendingPathComponent("stream/target.json")
let outDir = runtimeDir
let framePath = outDir + "/frame.jpg"
let statePath = outDir + "/state.json"

struct Spec: Equatable {
    var app: String?, title: String?
    var width: CGFloat = 460, fps: Int = 30, showCursor = true, attachTo = "Claude"
    var isEmpty: Bool { (app ?? "").isEmpty && (title ?? "").isEmpty }
}

func readJSON(_ p: String) -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: p),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
    return o
}

final class Capture: NSObject, SCStreamDelegate, SCStreamOutput {
    var spec = Spec()
    var stream: SCStream?
    var retargeting = false
    var lastTry = Date.distantPast
    var status = "starting"
    let ci = CIContext()
    let q = DispatchQueue(label: "cua.capture")

    func start() {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func currentSpec() -> Spec {
        var s = Spec()
        let c = readJSON(configPath), t = readJSON(targetPath)
        if let v = c["width"] as? Double { s.width = CGFloat(v) }
        if let v = c["fps"] as? Double { s.fps = Int(v) }
        if let v = c["showCursor"] as? Bool { s.showCursor = v }
        if let v = c["attachTo"] as? String { s.attachTo = v }
        s.app = t["app"] as? String; s.title = t["title"] as? String
        return s
    }

    func tick() {
        let s = currentSpec()
        if s != spec { spec = s; let x = s; Task { await retarget(x) } }
        else if stream == nil, !spec.isEmpty, !retargeting, Date().timeIntervalSince(lastTry) > 3 {
            lastTry = Date(); let x = spec; Task { await retarget(x) }
        }
        publishState()
    }

    /// Host-window bounds are published here so the UI app needs no permissions.
    func hostBounds() -> [String: Double]? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
              let screen = NSScreen.screens.first else { return nil }
        var best: [String: Double]?
        var bestArea = 0.0
        for w in info {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner.localizedCaseInsensitiveContains(spec.attachTo),
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let cw = b["Width"] as? Double, let ch = b["Height"] as? Double,
                  cw * ch > 100000 else { continue }
            if cw * ch > bestArea {
                bestArea = cw * ch
                best = ["x": x, "y": Double(screen.frame.height) - y - ch, "w": cw, "h": ch]
            }
        }
        return best
    }

    func publishState() {
        var o: [String: Any] = [
            "status": status,
            "streaming": stream != nil,
            "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
        ]
        if let b = hostBounds() { o["hostBounds"] = b }
        if let d = try? JSONSerialization.data(withJSONObject: o) {
            try? d.write(to: URL(fileURLWithPath: statePath + ".tmp"))
            _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: statePath),
                                                       withItemAt: URL(fileURLWithPath: statePath + ".tmp"))
        }
    }

    func retarget(_ s: Spec) async {
        retargeting = true; defer { retargeting = false }
        if let st = stream { try? await st.stopCapture(); stream = nil }
        guard !s.isEmpty else { status = "idle"; return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let match = content.windows.first { w in
                guard w.isOnScreen, w.frame.width * w.frame.height > 40000 else { return false }
                if let a = s.app, !a.isEmpty,
                   !(w.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(a) { return false }
                if let t = s.title, !t.isEmpty,
                   !(w.title ?? "").localizedCaseInsensitiveContains(t) { return false }
                return true
            }
            guard let win = match else { status = "no-window-match"; return }
            let c = SCStreamConfiguration()
            let scale = s.width / max(win.frame.width, 1)
            c.width = Int(s.width)
            c.height = max(Int(win.frame.height * scale), 80)
            c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(s.fps, 1)))
            c.showsCursor = s.showCursor
            c.scalesToFit = true
            let st = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: c, delegate: self)
            try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
            try await st.startCapture()
            stream = st
            status = "streaming \(win.owningApplication?.applicationName ?? "?") \(c.width)x\(c.height)@\(s.fps)"
        } catch {
            status = "capture-error: \(error.localizedDescription)"
        }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let img = CIImage(cvPixelBuffer: px)
        guard let data = ci.jpegRepresentation(of: img,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.72])
        else { return }
        let tmp = framePath + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tmp))
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: framePath),
                                                   withItemAt: URL(fileURLWithPath: tmp))
    }

    func stream(_ s: SCStream, didStopWithError e: Error) { stream = nil; status = "stopped: \(e.localizedDescription)" }
}

NSApplication.shared.setActivationPolicy(.prohibited)
let cap = Capture()
cap.start()
RunLoop.main.run()
