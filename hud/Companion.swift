import AppKit
import WebKit
import Carbon
import AVFoundation

final class StartupOutput {
    private let lock = NSLock()
    private var bytes = Data()
    func read(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            lock.lock(); bytes.append(chunk); if bytes.count > 16384 { bytes = Data(bytes.suffix(16384)) }; lock.unlock()
        }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

final class SelectionPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        guard (firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        onCancel?()
    }
}

final class AreaSelectionView: NSView {
    var mode = "select", start: CGPoint?, end: CGPoint?, points: [CGPoint] = []
    var update: ((CGPoint, CGPoint, [CGPoint]) -> Void)?
    var finish: ((CGPoint, CGPoint, [CGPoint]) -> Void)?
    var cancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(mode == "select" ? 0.12 : 0.025).setFill(); bounds.fill()
        guard let screen = window?.frame else { return }
        let note = "\(mode == "draw" ? "Draw" : mode.capitalized) · drag on the screen · Esc cancels"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let card = CGRect(x: max(8,(bounds.width-340)/2), y: bounds.height-52, width: min(340,bounds.width-16), height: 30)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect:card,xRadius:10,yRadius:10).fill()
        note.draw(at:CGPoint(x:card.minX+12,y:card.minY+8),withAttributes:attributes)
        guard let a=start, let b=end else { return }
        let rect=CGRect(x:min(a.x,b.x)-screen.minX,y:min(a.y,b.y)-screen.minY,width:abs(a.x-b.x),height:abs(a.y-b.y))
        let color=NSColor(calibratedRed:0.87,green:0.62,blue:0.34,alpha:1)
        if mode == "select" { color.withAlphaComponent(0.12).setFill(); rect.fill(); color.setStroke(); let p=NSBezierPath(rect:rect);p.lineWidth=2;p.stroke();return }
        let local=points.map{CGPoint(x:$0.x-screen.minX,y:$0.y-screen.minY)}
        let line=PointerGeometry.stroke(kind:mode,rect:rect,points:mode == "arrow" ? [CGPoint(x:a.x-screen.minX,y:a.y-screen.minY),CGPoint(x:b.x-screen.minX,y:b.y-screen.minY)] : local)
        guard let first=line.first else{return};let path=NSBezierPath();path.move(to:first);line.dropFirst().forEach{path.line(to:$0)}
        path.lineWidth=mode == "highlight" ? max(12,rect.height) : 3;path.lineCapStyle = .round;path.lineJoinStyle = .round
        (mode == "highlight" ? color.withAlphaComponent(0.3) : color).setStroke();path.stroke()
    }
    override func mouseDown(with event:NSEvent){start=NSEvent.mouseLocation;end=start;points=[start!];update?(start!,end!,points)}
    override func mouseDragged(with event:NSEvent){
        guard let a=start else{return};let p=NSEvent.mouseLocation;end=p
        if let last=points.last,hypot(last.x-p.x,last.y-p.y)>=2{if points.count>=512{points=points.enumerated().filter{$0.offset%2==0}.map{$0.element}};points.append(p)}
        update?(a,p,points)
    }
    override func mouseUp(with event:NSEvent){if let a=start{let b=NSEvent.mouseLocation;if points.count<512{points.append(b)};finish?(a,b,points)}}
    override func cancelOperation(_ sender:Any?){cancel?()}
    override func keyDown(with event:NSEvent){if event.keyCode==53{cancel?()}else{super.keyDown(with:event)}}
}

final class CompanionDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var panel: NSPanel!, web: WKWebView!, statusItem: NSStatusItem?
    var composer: CompanionComposer!
    private var webHeight: NSLayoutConstraint?
    private let composerHeight: CGFloat = 128
    private lazy var hub = CompanionHubController()
    private var hubClients: [[String: Any]] = []
    var selections: [SelectionPanel] = []
    let voice = CompanionVoice()
    private var voiceCaptureID: String?
    private var voicePreparing = false
    var terminating = false, keyHeld = false, shortcutOpened = false, holdStarted = false
    var holdAction: DispatchWorkItem?
    var anchor = CGPoint.zero, anchorBounds = CGRect.zero
    var returnApp: NSRunningApplication?
    var hotkeys: [EventHotKeyRef] = []
    var eventHandler: EventHandlerRef?
    var pageURL: URL!
    var appContext: [String: Any] = [:]
    var startupError = "Check that Node and this CUA checkout are available."

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        rememberApp(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notice in
            self?.rememberApp(notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: composerHeight), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Andy Barista"; panel.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: "Connecting to local CUA…")
        label.frame = NSRect(x: 18, y: 18, width: 324, height: 92); panel.contentView?.addSubview(label); panel.center(); show()
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let url = self.resolveURL()
            DispatchQueue.main.async {
                guard let url = url, url.scheme == "http", url.host == "127.0.0.1", url.path == "/companion" else {
                    label.stringValue = "Andy Barista could not start local CUA.\n\n\(self.startupError)\n\nRun cua doctor, then reopen this app."; return
                }
                self.panel.close(); self.openCompanion(url)
            }
        }
    }

    func openCompanion(_ url: URL) {
        pageURL = url
        if !holdLock("companion.lock") {
            DistributedNotificationCenter.default().postNotificationName(.init("com.andymsun.cua.companion.show"), object: nil)
            NSApp.terminate(nil); return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(show), name: .init("com.andymsun.cua.companion.show"), object: nil)
        let controller = WKUserContentController(); controller.add(self, name: "barista")
        let configuration = WKWebViewConfiguration(); configuration.userContentController = controller
        web = WKWebView(frame: .zero, configuration: configuration); web.navigationDelegate = self
        panel = SelectionPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: composerHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; web.underPageBackgroundColor = .clear
        panel.title = "Andy Barista"; panel.titlebarAppearsTransparent = true; panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: composerHeight); panel.delegate = self
        (panel as? SelectionPanel)?.onCancel = { [weak self] in self?.dismiss() }
        let root = NSVisualEffectView(); root.material = .popover; root.state = .active
        root.wantsLayer = true; root.layer?.cornerRadius = 14; root.layer?.masksToBounds = true
        composer = CompanionComposer(frame: .zero)
        panel.contentView = root; root.addSubview(composer); root.addSubview(web)
        composer.translatesAutoresizingMaskIntoConstraints = false; web.translatesAutoresizingMaskIntoConstraints = false
        let height = web.heightAnchor.constraint(equalToConstant: 0); webHeight = height
        NSLayoutConstraint.activate([
            composer.topAnchor.constraint(equalTo: root.topAnchor), composer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: root.trailingAnchor), composer.heightAnchor.constraint(equalToConstant: composerHeight),
            web.topAnchor.constraint(equalTo: composer.bottomAnchor), web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor), web.bottomAnchor.constraint(equalTo: root.bottomAnchor), height
        ])
        composer.onDraft = { [weak self] in self?.nativeCall("baristaNativeDraft", $0) }
        composer.onSubmit = { [weak self] in self?.nativeCall("baristaNativeSubmit", $0) }
        composer.onSession = { [weak self] payload in
            self?.nativeCall("baristaNativeSession", payload) { value in
                if value == nil || value as? Bool == false { self?.composer.transportError("Could not change conversation. Try again.") }
            }
        }
        composer.onStop = { [weak self] in self?.nativeCall("baristaNativeStop", $0) }
        composer.onClear = { [weak self] in self?.nativeCall("baristaNativeClear", $0) }
        composer.onAdvanced = { [weak self] in self?.nativeCall("baristaNativeAdvanced", $0) }
        composer.onDismiss = { [weak self] in self?.dismiss() }
        composer.onDictation = { [weak self] in
            guard let self = self else { return }
            if self.voiceCaptureID != nil { self.finishVoice() } else { self.beginVoice(route: "dictation") }
        }
        hub.onAsk = { [weak self] in self?.show() }
        hub.onOpenSession = { [weak self] id in self?.composer.selectSession(id: id); self?.show() }
        hub.onStopSession = { [weak self] id in self?.nativeCall("baristaNativeStop", ["id": id]) }
        hub.onOpenHost = { [weak self] id in self?.openHost(id) }
        anchor = NSEvent.mouseLocation
        anchorBounds = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        web.load(URLRequest(url: url))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Andy Barista")
        let menu = NSMenu(); menu.addItem(ClosureItem("Open Andy Barista   ⌃⌥Space") { [weak self] in self?.show() })
        menu.addItem(hub.makeMenuItem())
        menu.addItem(ClosureItem("Select an area") { [weak self] in self?.selectArea() })
        menu.addItem(ClosureItem("Stop all companions   ⌃⌥Escape") { [weak self] in self?.stopAll() })
        menu.addItem(.separator()); menu.addItem(ClosureItem("Quit companion") { NSApp.terminate(nil) })
        statusItem?.menu = menu
        voice.onState = { [weak self] id, phase in
            guard let self = self else { return }
            if phase == "ready", self.voiceCaptureID == id { self.voiceCaptureID = nil; self.voicePreparing = false }
            self.nativeCall("baristaVoiceState", ["captureID": id, "phase": phase])
        }
        voice.onText = { [weak self] id, text in self?.nativeCall("baristaVoiceText", ["captureID": id, "text": text]) }
        voice.onFinal = { [weak self] id, text in
            guard let self = self, self.voiceCaptureID == id else { return }
            self.voiceCaptureID = nil
            self.nativeCall("baristaVoiceFinal", ["captureID": id, "text": text])
        }
        voice.onError = { [weak self] id, message in
            guard let self = self, self.voiceCaptureID == id else { return }
            self.voiceCaptureID = nil
            self.nativeCall("baristaNativeError", ["captureID": id, "message": message])
        }
        registerShortcuts(); show()
    }

    func resolveURL() -> URL? {
        if let index = CommandLine.arguments.firstIndex(of: "--companion"), index + 1 < CommandLine.arguments.count { return URL(string: CommandLine.arguments[index + 1]) }
        guard let cli = Bundle.main.object(forInfoDictionaryKey: "CuaCLIPath") as? String,
              let node = Bundle.main.object(forInfoDictionaryKey: "CuaNodePath") as? String else { startupError = "The app is missing CuaCLIPath or CuaNodePath. Rebuild it with scripts/build-native.py."; return nil }
        let process = Process(), output = Pipe(), errors = Pipe()
        func bundlePath(_ value: String) -> String { value.hasPrefix("/") ? value : Bundle.main.bundleURL.appendingPathComponent(value).path }
        process.executableURL = URL(fileURLWithPath: node); process.arguments = [bundlePath(cli), "companion", "--url"]
        var environment = ProcessInfo.processInfo.environment
        environment["CUA_RUN_DIR"] = runDir
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        if let config = Bundle.main.object(forInfoDictionaryKey: "CuaConfigPath") as? String { environment["CUA_CONFIG"] = config }
        if let preview = Bundle.main.object(forInfoDictionaryKey: "CuaPreviewPath") as? String { environment["CUA_HUD_APP"] = bundlePath(preview) }
        if let agent = Bundle.main.object(forInfoDictionaryKey: "CuaAgentPath") as? String { environment["CUA_AGENT_APP"] = bundlePath(agent) }
        process.environment = environment; process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { startupError = error.localizedDescription; NSLog("Companion startup: %@", startupError); return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
        let stdout = StartupOutput(), stderr = StartupOutput(), drained = DispatchGroup()
        for (capture, handle) in [(stdout, output.fileHandleForReading), (stderr, errors.fileHandleForReading)] {
            drained.enter(); DispatchQueue.global().async { capture.read(handle); drained.leave() }
        }
        process.waitUntilExit()
        guard drained.wait(timeout: .now() + 3) == .success else { startupError = "Startup output did not close. Quit the stalled CLI process, then reopen this app."; return nil }
        let address = stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !address.isEmpty else {
            startupError = "Startup exited \(process.terminationStatus). \(String(stderr.text.suffix(1800)))"; NSLog("Companion startup: %@", startupError); return nil
        }
        return URL(string: address)
    }

    @objc func show() {
        let before = CACurrentMediaTime()
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            returnApp = front; rememberApp(front)
        } else if let pid = (appContext["pid"] as? NSNumber)?.int32Value, let app = NSRunningApplication(processIdentifier: pid),
                  let launch = app.launchDate, appContext["process"] as? String == "\(pid):\(launch.timeIntervalSince1970)" {
            rememberApp(app, windowID: (appContext["windowId"] as? NSNumber)?.uint32Value)
        } else { appContext = [:] }
        anchor=NSEvent.mouseLocation
        anchorBounds=(NSScreen.screens.first{$0.frame.contains(anchor)} ?? NSScreen.main)?.visibleFrame ?? .zero
        if panel != nil {panel.setFrame(PointerGeometry.popup(at:anchor,size:panel.frame.size,bounds:anchorBounds),display:false)}
        panel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        composer?.focus(); nativeCall("baristaContext", appContext); nativeCall("baristaOpened", [:])
        NSLog("Popup show call %.2f ms",(CACurrentMediaTime()-before)*1000)
    }
    func toggle(){if panel?.isVisible == true && panel?.isKeyWindow == true{dismiss()}else{show()}}
    func dismiss(restoreFocus:Bool=true,silence:Bool=true){
        let hadFocus = panel?.isKeyWindow == true && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        keyHeld=false;holdAction?.cancel();cancelVoice()
        if silence{voice.silence();nativeCall("baristaDismissed", [:])}
        panel?.orderOut(nil)
        if restoreFocus && hadFocus,let previous=returnApp,!previous.isTerminated{previous.activate(options:[])}
    }
    func resizePopup(_ height:CGFloat){
        guard anchorBounds.width>0, height.isFinite else{return}
        let extra = max(0, min(280, height)); webHeight?.constant = extra
        let size=CGSize(width:360,height:composerHeight + extra)
        var frame=PointerGeometry.popup(at:anchor,size:size,bounds:anchorBounds)
        if abs(panel.frame.width-frame.width)<1 {frame.origin.x=panel.frame.minX}
        if abs(panel.frame.height-frame.height)>1{panel.setFrame(frame,display:true)}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{dismiss();return false}
    func windowDidResignKey(_ notification: Notification) {
        keyHeld = false; holdAction?.cancel(); cancelVoice()
        // An outside click leaves the composer and its draft in place; never retry focus.
    }
    func nativeCall(_ callback: String, _ payload: [String: Any], completion: ((Any?) -> Void)? = nil) {
        guard let web = web else { completion?(nil); return }
        web.callAsyncJavaScript("return window[callback]?.(payload)", arguments: ["callback": callback, "payload": payload], in: nil, in: .page) { [weak self] result in
            switch result {
            case .success(let value): completion?(value)
            case .failure(let error): self?.composer?.transportError(error.localizedDescription); completion?(nil)
            }
        }
    }
    func evaluate(_ js: String) { web?.evaluateJavaScript(js) { _, error in if let error = error { NSLog("Companion UI: %@", error.localizedDescription) } } }
    func json(_ value: Any) -> String { guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), let result = String(data: data, encoding: .utf8) else { return "null" }; return result }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "127.0.0.1",
              message.frameInfo.securityOrigin.port == (pageURL.port ?? 80),
              message.frameInfo.request.url?.scheme == pageURL.scheme, message.frameInfo.request.url?.path == pageURL.path,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "select": selectArea()
        case "draw": if let mode=body["kind"] as? String,["circle","highlight","arrow","draw"].contains(mode){selectArea(mode:mode)}
        case "dismiss": dismiss()
        case "resize": if let height=body["height"] as? NSNumber{resizePopup(CGFloat(height.doubleValue))}
        case "demo":
            guard let screen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main else{return}
            let top=NSScreen.screens.first?.frame.maxY ?? 0, f=screen.visibleFrame, mouse=NSEvent.mouseLocation
            let data:[String:Any] = ["bounds":["x":f.minX,"y":top-f.maxY,"w":f.width,"h":f.height],"start":[mouse.x,top-mouse.y]]
            evaluate("window.baristaDemoContext?.(\(json(data)))")
        case "composerState": composer.apply(body)
        case "hubState":
            hubClients = Array(((body["hub"] as? [String: Any])?["clients"] as? [[String: Any]] ?? []).prefix(32))
            hub.apply(body)
        case "voiceStart":
            guard let id = body["captureID"] as? String, !id.isEmpty, id.utf16.count <= 128,
                  let session = body["id"] as? String, session == composer.activeSessionID,
                  let generation = body["generation"] as? Int, generation >= 0,
                  let route = body["route"] as? String, ["command", "dictation"].contains(route) else { return }
            cancelVoice(); voiceCaptureID = id; voice.start(captureID: id)
        case "voiceEnd": if body["captureID"] as? String == voiceCaptureID { finishVoice() }
        case "voiceCancel": if body["captureID"] as? String == voiceCaptureID { cancelVoice(notify: false) }
        case "speak": if let text=body["text"] as? String{voice.speak(text,enqueue:body["enqueue"] as? Bool ?? false)}
        case "silence": voice.silence()
        default: break
        }
    }
    func rememberApp(_ app: NSRunningApplication?, windowID: CGWindowID? = nil) {
        guard let app = app, !app.isTerminated, let launch = app.launchDate,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !(app.bundleIdentifier ?? "").hasPrefix("com.andymsun.cua.") else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // Keep an explicit selected ID if it closes, so lookup rejects that target instead of choosing another window.
        let selected = CompanionContext.windowID(pid: app.processIdentifier, windows: windows, preferred: windowID) ?? windowID
        appContext = CompanionContext.payload(pid: app.processIdentifier, launchDate: launch, app: app.localizedName ?? "", bundleID: app.bundleIdentifier, windowID: selected,
                                               cursor: NSEvent.mouseLocation, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        composer?.setContext(app.localizedName ?? "")
        nativeCall("baristaContext", appContext)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        nativeCall("baristaContext", appContext)
        if panel.isVisible { nativeCall("baristaOpened", [:]) }
        if let v = CompanionVoice.preferredVoice() { nativeCall("baristaVoiceInfo", ["name": v.name, "enhanced": v.quality.rawValue > 1]) }
    }
    func openHost(_ id: String) {
        guard let client = hubClients.first(where: { $0["id"] as? String == id }),
              let pid = CompanionContext.hostPID(client, bundleForPID: { pid in
                  guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
                  return app.bundleIdentifier
              }), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier == (client["host"] as? [String: Any])?["bundleId"] as? String else { return }
        app.activate(options: [])
    }
    func beginVoice(route: String) {
        guard voiceCaptureID == nil, !composer.editor.hasMarkedText() else { return }
        let id = UUID().uuidString
        voiceCaptureID = id; voicePreparing = true
        nativeCall("baristaNativeVoicePrepare", ["id": composer.activeSessionID as Any? ?? NSNull(), "captureID": id, "route": route]) { [weak self] value in
            guard let self = self else { return }
            guard self.voiceCaptureID == id else { self.nativeCall("baristaVoiceCancelled", ["captureID": id]); return }
            self.voicePreparing = false
            guard let binding = value as? [String: Any], binding["captureID"] as? String == id,
                  binding["id"] as? String == self.composer.activeSessionID, binding["route"] as? String == route,
                  let generation = binding["generation"] as? Int, generation >= 0 else { self.cancelVoice(); return }
            self.voice.start(captureID: id)
        }
    }
    func finishVoice() {
        if voicePreparing { cancelVoice() } else { voice.finish() }
    }
    func cancelVoice(notify: Bool = true) {
        let id = voiceCaptureID; voiceCaptureID = nil; voicePreparing = false; voice.cancel()
        if notify, let id = id { nativeCall("baristaVoiceCancelled", ["captureID": id]) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == pageURL.scheme, url.host == pageURL.host, url.port == pageURL.port, url.path == pageURL.path else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let label = NSTextField(wrappingLabelWithString: "Cannot reach local CUA. Run cua start, then reopen Andy Barista.\n\n\(error.localizedDescription)")
        label.frame = NSRect(x: 24, y: 100, width: 360, height: 150); panel.contentView?.addSubview(label)
    }

    func selectArea(mode:String="select") {
        guard selections.isEmpty else { return }
        panel.orderOut(nil)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for screen in NSScreen.screens {
            let w = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            w.hidesOnDeactivate = false; w.isReleasedWhenClosed = false; w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = AreaSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size)); v.mode=mode; w.contentView = v
            v.update = { [weak self] a, b, points in self?.selections.forEach { if let view = $0.contentView as? AreaSelectionView { view.start=a;view.end=b;view.points=points;view.needsDisplay=true } } }
            v.cancel = { [weak self] in self?.endSelection() }
            v.finish = { [weak self] a, b, points in
                guard let self = self else { return }
                let rect = PointerGeometry.selection(from: a, to: b, primaryTop: primaryTop)
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                if let selected = windows.first(where: { info in
                    guard (info[kCGWindowLayer as String] as? Int) == 0, let raw = info[kCGWindowBounds as String] as? [String: Any], let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
                    return bounds.contains(CGPoint(x: rect.midX, y: rect.midY))
                }), let pid = (selected[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value {
                    self.rememberApp(NSRunningApplication(processIdentifier: pid), windowID: (selected[kCGWindowNumber as String] as? NSNumber)?.uint32Value)
                }
                self.endSelection()
                let height=max(mode == "highlight" ? 12 : 0,rect.height)
                let box:[String:CGFloat] = ["x":rect.minX,"y":rect.minY-(height-rect.height)/2,"w":rect.width,"h":height]
                if mode == "select" {if rect.width>=4 && rect.height>=4{self.evaluate("window.baristaSelection?.(\(self.json(box)))")}}
                else if mode == "circle" || mode == "highlight" {
                    if rect.width>=4 && (rect.height>=4 || mode == "highlight"){self.evaluate("window.baristaAnnotation?.(\(self.json(["kind":mode,"rect":box])))")}
                } else if hypot(a.x-b.x,a.y-b.y)>3 || points.count>3 {
                    let stroke=(mode == "arrow" ? [a,b] : points).prefix(512).map{[$0.x,primaryTop-$0.y]}
                    self.evaluate("window.baristaAnnotation?.(\(self.json(["kind":mode,"points":Array(stroke)])))")
                }
            }
            selections.append(w); w.orderFrontRegardless(); w.makeKey(); w.makeFirstResponder(v)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func endSelection() { selections.forEach { $0.close() }; selections.removeAll(); show() }

    func shortcut(pressed:Bool) {
        if pressed {
            guard !keyHeld else{return}
            keyHeld=true;holdStarted=false
            shortcutOpened = !(panel?.isVisible == true && panel?.isKeyWindow == true)
            if shortcutOpened {show()}
            let hold=DispatchWorkItem{[weak self] in
                guard let self=self,self.keyHeld else{return}
                self.holdStarted=true
                guard self.panel?.isKeyWindow == true else { return }
                self.beginVoice(route: "command")
            }
            holdAction=hold;DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:hold)
        } else {
            guard keyHeld else{return}
            keyHeld=false;holdAction?.cancel()
            if holdStarted{finishVoice()}else if !shortcutOpened{dismiss()}
        }
    }

    func registerShortcuts() {
        var types=[EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(),{_,event,context in
            guard let event=event,let context=context else{return noErr}
            var id=EventHotKeyID();GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            let owner=Unmanaged<CompanionDelegate>.fromOpaque(context).takeUnretainedValue()
            let pressed=GetEventKind(event)==UInt32(kEventHotKeyPressed)
            if id.id==1 {owner.shortcut(pressed:pressed)} else if pressed {owner.stopAll()}
            return noErr
        },2,&types,Unmanaged.passUnretained(self).toOpaque(),&eventHandler)
        for(id,key) in [(UInt32(1),UInt32(49)),(UInt32(2),UInt32(53))]{
            var reference:EventHotKeyRef?
            let result=RegisterEventHotKey(key,UInt32(controlKey|optionKey),EventHotKeyID(signature:0x43554142,id:id),GetApplicationEventTarget(),0,&reference)
            if result==noErr,let reference=reference{hotkeys.append(reference)}else{NSLog("Companion shortcut unavailable: %d",result)}
        }
    }
    func stopAll(){cancelVoice();voice.silence();if !selections.isEmpty{endSelection()};nativeCall("baristaStopAll", [:])}

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let pageURL = pageURL else { return .terminateNow }
        if terminating { return .terminateLater }; terminating = true
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        components.path = "/api/companion/stop-all"
        var request = URLRequest(url: components.url!); request.httpMethod = "POST"; request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = Data("{}".utf8)
        let finish = { [weak self] in
            guard let self = self, self.terminating else { return }
            self.terminating = false; NSApp.reply(toApplicationShouldTerminate: true)
        }
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error { NSLog("Companion stop on quit: %@", error.localizedDescription) }
            DispatchQueue.main.async(execute: finish)
        }.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: finish)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.forEach { UnregisterEventHotKey($0) }; if let handler = eventHandler { RemoveEventHandler(handler) }
        holdAction?.cancel()
        cancelVoice();voice.silence();selections.forEach{$0.close()};hub.close()
        // Only companion sessions are stopped; other harness sessions belong to the daemon.
    }
}
