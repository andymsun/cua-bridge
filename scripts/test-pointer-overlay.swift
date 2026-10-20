import AppKit

final class OverlayIdentityChecks: NSObject, NSApplicationDelegate {
    let overlay = PointerOverlay()
    func applicationDidFinishLaunching(_ note: Notification) {
        guard ProcessInfo.processInfo.environment["CUA_RUN_DIR"] != nil, let result = CommandLine.arguments.last, result.hasSuffix(".json") else {
            fputs("Use an isolated CUA_RUN_DIR and a result JSON path.\n", stderr); exit(1)
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let active = NSApp.isActive
        let pointer = NSEvent.mouseLocation
        overlay.applicationDidFinishLaunching(note)
        let path = "\(runDir)/pointer-windows.json", first = readJSON(path)
        var checks: [String: Bool] = [:]
        checks["launch identity"] = first["process"] as? String == NSRunningApplication.current.launchDate.map { "\(getpid()):\($0.timeIntervalSince1970)" }
        checks["window identity"] = Set(first["windows"] as? [Int] ?? []) == Set(overlay.windows.map { $0.window.windowNumber }) && !overlay.windows.isEmpty
        checks["click through and nonactivating"] = overlay.windows.allSatisfy { $0.window.ignoresMouseEvents && !$0.window.canBecomeKey && !$0.window.canBecomeMain }
        checks["private manifest"] = ((try? fm.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue == 0o600
        overlay.buildWindows()
        let rebuilt = readJSON(path)
        checks["rebuild replaces window ids"] = Set(rebuilt["windows"] as? [Int] ?? []) != Set(first["windows"] as? [Int] ?? [])
        checks["rebuild keeps process identity"] = rebuilt["process"] as? String == first["process"] as? String
        checks["passive focus"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost && NSApp.isActive == active
        checks["real pointer unchanged"] = NSEvent.mouseLocation == pointer
        overlay.applicationWillTerminate(note)
        checks["manifest removed on exit"] = !fm.fileExists(atPath: path)
        overlay.windows.forEach { $0.window.close() }
        let success = checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["ok": success, "checks": checks, "screens": NSScreen.screens.count]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: result), options: .atomic) }
        catch { fputs("Could not save overlay check: \(error)\n", stderr); exit(1) }
        exit(success ? 0 : 1)
    }
}
@main struct OverlayIdentityMain {
    static func main() { let app = NSApplication.shared, delegate = OverlayIdentityChecks(); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() } }
}
