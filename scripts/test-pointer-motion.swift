import AppKit

final class MotionChecks: NSObject, NSApplicationDelegate {
    let overlay = PointerOverlay()
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in await check() }
    }
    @MainActor func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
    func position(_ cursor: AgentCursor) -> CGPoint { cursor.layer!.sublayers!.first!.position }
    func require(_ condition: Bool, _ message: String) {
        if !condition { overlay.windows.forEach { $0.window.close() }; fputs("FAIL \(message)\n", stderr); exit(1) }
    }
    @MainActor func checkActiveGuidance(_ screenIndex: Int = 0) async {
        let previousMouse = overlay.readMouse
        defer { overlay.readMouse = previousMouse }
        let screen = overlay.windows[screenIndex], top = NSScreen.screens.first!.frame.maxY
        let bounds = CGRect(x: screen.screen.frame.minX, y: top-screen.screen.frame.maxY, width: screen.screen.frame.width, height: screen.screen.frame.height)
        let area = CGRect(x: bounds.minX+100, y: bounds.minY+100, width: 120, height: 80)
        let target = CGPoint(x: area.midX, y: area.midY)
        let elsewhere = CGPoint(x: bounds.minX+bounds.width*0.8, y: bounds.minY+bounds.height*0.7)
        var mouse = elsewhere
        overlay.readMouse = { CGPoint(x: mouse.x, y: top-mouse.y) }
        let stamp = Date().timeIntervalSince1970*1000-4000
        overlay.boundsByID[999999999] = area
        let instruction: [String: Any] = ["target": ["windowId": 999999999, "rect": ["x": 0, "y": 0, "w": 1, "h": 1]],
            "kind": "spotlight", "state": "waiting", "persistent": true, "name": "Owned guide", "label": "Complete this manual step", "t": stamp,
            "annotations": [["id": "reference", "kind": "circle", "target": ["screenRect": ["x": area.minX, "y": area.minY, "w": area.width, "h": area.height]], "t": stamp]]]
        overlay.document = ["cursors": ["guidance": instruction]]
        let unchanged = NSDictionary(dictionary: overlay.document)
        overlay.tick(updateWindows: false)
        await pause(0.2)
        var mark = overlay.marks["guidance"]![screenIndex]!
        let localTarget = PointerGeometry.local(target, screen: screen.screen.frame, primaryTop: top)
        require(hypot(position(mark.cursor).x-localTarget.x, position(mark.cursor).y-localTarget.y)<2, "an unvisited pending target remains anchored even when its timestamp is old")
        require(overlay.presenceTimer == nil, "an unvisited pending target does not start presence polling")
        let ink = mark.annotationLayers["reference"]!.path!.boundingBox
        mouse = target; overlay.tick(updateWindows: false)
        await pause(0.8)
        require(mark.leader.opacity>0 && mark.ring.opacity>0, "visiting a pending target yields without releasing its target cues")
        overlay.boundsByID[999999999] = area.offsetBy(dx: 400, dy: 220); overlay.tick(updateWindows: false)
        mouse.x += 1; overlay.tick(updateWindows: false)
        require(overlay.presenceTimer == nil && mark.ring.opacity>0, "window movement and pointer jitter alone do not imply a human departure")
        overlay.boundsByID[999999999] = area; overlay.tick(updateWindows: false)
        mouse = CGPoint(x: area.maxX+60, y: target.y); overlay.tick(updateWindows: false)
        await pause(0.8)
        require(overlay.presenceTimer == nil && mark.ring.opacity>0, "small movement around a pending target does not release it")
        mouse = elsewhere; overlay.tick(updateWindows: false)
        await pause(1.5)
        let localMouse = PointerGeometry.local(mouse, screen: screen.screen.frame, primaryTop: top)
        require(hypot(position(mark.cursor).x-localMouse.x, position(mark.cursor).y-localMouse.y)<120, "a pending guide follows after the person visits its target and moves elsewhere")
        require(mark.pill.isHidden && mark.leader.opacity==0 && mark.ring.opacity==0 && screen.shade.opacity==0, "visual release retires the old instruction, leader, ring, and spotlight")
        require(mark.annotationLayers["reference"]!.path!.boundingBox==ink && mark.annotationLayers["reference"]!.opacity>0, "visual release keeps explicit ink at its original target")
        require(unchanged.isEqual(to: overlay.document), "visual release cannot complete a pending step or alter its target authority")
        require(overlay.presenceTimer != nil, "a released pending cursor uses existing adaptive presence")
        mouse = target; overlay.tick(updateWindows: false)
        await pause(0.8)
        require(mark.pill.isHidden && mark.leader.opacity==0 && mark.ring.opacity==0, "returning near an old target cannot revive released guidance")
        overlay.boundsByID = [:]; overlay.tick(updateWindows: false)
        require(overlay.presenceTimer != nil, "a released guide keeps following when its old target disappears")
        overlay.boundsByID[999999999] = area.offsetBy(dx: 400, dy: 220); overlay.tick(updateWindows: false)
        require(mark.ring.opacity==0 && mark.leader.opacity==0, "a reappearing target cannot revive released guidance")
        overlay.marks.values.flatMap { $0.values }.forEach { $0.remove() }; overlay.marks = [:]; overlay.seen = [:]
        overlay.tick(updateWindows: false); await pause(0.2)
        mark = overlay.marks["guidance"]![screenIndex]!
        require(overlay.presenceTimer != nil && mark.pill.isHidden && mark.ring.opacity==0, "rebuilding presentation does not revive released guidance")
        var other = instruction
        other["target"] = ["screenRect": ["x": bounds.minX+80, "y": bounds.maxY-160, "w": 80, "h": 60]]
        overlay.document = ["cursors": ["guidance": instruction, "other": other]]; overlay.tick(updateWindows: false)
        require(mark.pill.isHidden && !overlay.marks["other"]![screenIndex]!.pill.isHidden, "one released cursor does not release another guide")
        var changed = instruction
        changed["target"] = ["screenRect": ["x": area.minX+80, "y": area.minY+160, "w": area.width, "h": area.height]]
        overlay.document = ["cursors": ["guidance": changed]]; overlay.tick(updateWindows: false)
        require(!mark.pill.isHidden && mark.ring.opacity>0 && overlay.presenceTimer == nil, "a changed target re-arms guidance even when its millisecond timestamp is unchanged")
        overlay.boundsByID[999999999] = area
        var next = instruction; next["t"] = stamp+1
        mouse = elsewhere; overlay.document = ["cursors": ["guidance": next]]; overlay.tick(updateWindows: false)
        await pause(1.5)
        require(hypot(position(mark.cursor).x-localTarget.x, position(mark.cursor).y-localTarget.y)<2 && !mark.pill.isHidden && mark.ring.opacity>0, "a fresh published update re-arms the pending target")
        require(overlay.presenceTimer == nil, "a fresh target stops released presence polling")
        next["t"] = Date().timeIntervalSince1970*1000
        mouse = target; overlay.document = ["cursors": ["guidance": next]]; overlay.tick(updateWindows: false)
        mouse = elsewhere; overlay.tick(updateWindows: false)
        require(overlay.presenceTimer == nil && mark.ring.opacity>0, "a new target keeps its initial hold despite an immediate visit and departure")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            next["t"] = stamp+2; next["motion"] = "pending-stroke"
            next["annotations"] = [["id": "pending-stroke", "kind": "draw", "points": [[target.x, target.y], [elsewhere.x, elsewhere.y]], "durationMs": 6000, "t": Date().timeIntervalSince1970*1000]]
            mouse = target; overlay.document = ["cursors": ["guidance": next]]; overlay.tick(updateWindows: false)
            mouse = elsewhere; overlay.tick(updateWindows: false)
            require(mark.cursor.isTracing && overlay.presenceTimer == nil && mark.ring.opacity>0, "departure cannot interrupt a pending guide's drawing")
            overlay.document = ["cursors": [:]]; overlay.tick(updateWindows: false)
            let recent = Date().timeIntervalSince1970*1000-2600
            var short = instruction; short["t"] = recent; short["kind"] = "click"; short["motion"] = "rebuild"
            let start = PointerGeometry.stroke(kind: "circle", rect: area, points: []).first!
            short["origin"] = ["x": start.x, "y": start.y]
            short["annotations"] = [["id": "rebuild", "kind": "circle", "target": ["screenRect": ["x": area.minX, "y": area.minY, "w": area.width, "h": area.height]], "durationMs": 120, "t": recent]]
            mouse = target; overlay.document = ["cursors": ["guidance": short]]; overlay.tick(updateWindows: false)
            await pause(0.18)
            mouse = elsewhere; overlay.tick(updateWindows: false)
            mark = overlay.marks["guidance"]![screenIndex]!
            require(!mark.cursor.isTracing && mark.pill.isHidden, "a short trace finishes before visual release")
            overlay.marks.values.flatMap { $0.values }.forEach { $0.remove() }; overlay.marks = [:]; overlay.seen = [:]
            overlay.tick(updateWindows: false); mark = overlay.marks["guidance"]![screenIndex]!
            require(!mark.cursor.isTracing, "rebuilding released guidance cannot restart its ink motion")
            await pause(0.03)
            require(hypot(position(mark.cursor).x-localMouse.x, position(mark.cursor).y-localMouse.y)<120, "released guidance cannot replay a flight from its old origin")
            let holder = mark.cursor.layer!.sublayers!.first!, transform = holder.transform
            let pressScale = hypot(transform.m21, transform.m22) / (0.4 + 0.6 * CGFloat(holder.opacity))
            require(abs(pressScale-1)<0.01, "rebuilding released guidance cannot replay a click pulse")
        }
        overlay.document = ["cursors": ["guidance": ["target": NSNull(), "t": stamp]]]; overlay.tick(updateWindows: false)
        require(overlay.attention.isEmpty && overlay.presenceTimer == nil, "hiding a target clears its visual release history")
        overlay.document = ["cursors": [:]]; overlay.tick(updateWindows: false)
        require(overlay.attention.isEmpty && overlay.presenceTimer == nil, "removing guidance clears its visual release history and presence timer")
        overlay.document = ["cursors": ["guidance": instruction]]; mouse = elsewhere; overlay.tick(updateWindows: false)
        require(!overlay.marks["guidance"]![screenIndex]!.pill.isHidden, "a reused cursor id does not inherit released guidance")
        overlay.document = ["cursors": [:]]; overlay.tick(updateWindows: false)
        print("PASS active guide visit, departure, visual release, pending-state preservation, and fresh-update rearm on screen \(screenIndex)")
    }
    @MainActor func checkCompletedInk(_ screenIndex: Int = 0) async {
        let previousMouse = overlay.readMouse
        defer { overlay.readMouse = previousMouse }
        let screen = overlay.windows[screenIndex], top = NSScreen.screens.first!.frame.maxY
        let x = screen.screen.frame.minX+100, y = top-screen.screen.frame.maxY+100
        overlay.readMouse = { CGPoint(x: x+600, y: top-y-400) }
        let now = Date().timeIntervalSince1970*1000
        let rect: [String: Any] = ["screenRect": ["x": x, "y": y, "w": 120, "h": 80]]
        let shapes: [[String: Any]] = [
            ["id": "circle", "kind": "circle", "target": rect, "t": now-60000],
            ["id": "highlight", "kind": "highlight", "target": rect, "t": now-60000],
            ["id": "arrow", "kind": "arrow", "points": [[x,y],[x+120,y+80]], "t": now-60000],
            ["id": "draw", "kind": "draw", "points": [[x,y],[x+60,y+80],[x+120,y]], "t": now-60000]
        ]
        var completed: [String: Any] = ["target": rect, "state": "done", "persistent": true, "t": now, "completedAt": now-5000, "annotations": shapes]
        let waiting: [String: Any] = ["target": rect, "state": "waiting", "persistent": true, "t": now-60000, "annotations": shapes]
        let selected: [String: Any] = ["target": rect, "kind": "rect", "state": "done", "persistent": true, "t": now-60000]
        overlay.document = ["labelSeconds": 6, "cursors": ["completed": completed, "waiting": waiting, "selected": selected]]
        overlay.tick(updateWindows: false)
        let mark = overlay.marks["completed"]![screenIndex]!, layers = Array(mark.annotationLayers.values)
        require(layers.count==4 && layers.allSatisfy { $0.opacity>0 }, "completed shapes keep their short hold even when their creation times are old")
        completed["completedAt"] = now-7000
        overlay.document = ["labelSeconds": 6, "cursors": ["completed": completed, "waiting": waiting, "selected": selected]]
        let unchanged = NSDictionary(dictionary: overlay.document)
        overlay.tick(updateWindows: false)
        require(mark.annotationLayers.isEmpty && layers.allSatisfy { $0.superlayer == nil }, "expired circles, highlights, arrows, and freehand layers detach after their completed hold")
        require(mark.cursor.superview != nil, "ink expiry keeps the companion cursor")
        require(overlay.marks["waiting"]![screenIndex]!.annotationLayers.count==4, "ink expiry cannot erase a waiting guide")
        require(overlay.marks["selected"]![screenIndex]!.ring.opacity>0, "ink expiry cannot erase a persistent selected area")
        require(unchanged.isEqual(to: overlay.document), "presentation expiry cannot change guide or target authority")
        overlay.marks.values.flatMap { $0.values }.forEach { $0.remove() }; overlay.marks = [:]; overlay.seen = [:]
        overlay.tick(updateWindows: false)
        require(overlay.marks["completed"]![screenIndex]!.annotationLayers.isEmpty, "display rebuild cannot revive expired ink")
        completed["completedAt"] = nil; completed["t"] = now-7000
        overlay.document = ["labelSeconds": 6, "cursors": ["completed": completed]]; overlay.tick(updateWindows: false)
        require(overlay.marks["completed"]![screenIndex]!.annotationLayers.isEmpty, "older feeds without a completion clock also expire")
        completed["state"] = "pointing"; completed["t"] = now; completed["annotations"] = [shapes[0]]
        overlay.document = ["labelSeconds": 6, "cursors": ["completed": completed]]; overlay.tick(updateWindows: false)
        let fresh = overlay.marks["completed"]![screenIndex]!.annotationLayers["circle"]!
        require(fresh.opacity>0, "fresh work still draws after expiry")
        completed["target"] = NSNull(); overlay.document = ["cursors": ["completed": completed]]; overlay.tick(updateWindows: false)
        require(fresh.opacity==0, "a null target hides its ink")
        overlay.document = ["cursors": [:]]; overlay.tick(updateWindows: false)
        require(fresh.superlayer == nil && overlay.marks.isEmpty, "an empty feed detaches the actual ink layers")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            var stroke: [String: Any] = ["target": rect, "state": "pointing", "persistent": true, "t": now, "motion": "finishing",
                "annotations": [["id": "finishing", "kind": "draw", "points": [[x,y],[x+120,y+80]], "t": Date().timeIntervalSince1970*1000, "durationMs": 250]]]
            overlay.document = ["cursors": ["stroke": stroke]]; overlay.tick(updateWindows: false)
            let drawing = overlay.marks["stroke"]![screenIndex]!
            require(drawing.cursor.isTracing, "the owned completion case starts a real stroke trace")
            stroke["state"] = "done"; stroke["completedAt"] = now-7000
            overlay.document = ["labelSeconds": 6, "cursors": ["stroke": stroke]]; overlay.tick(updateWindows: false)
            require(!drawing.annotationLayers.isEmpty, "expiry does not interrupt the current stroke")
            await pause(0.4); overlay.tick(updateWindows: false)
            require(drawing.annotationLayers.isEmpty, "completed ink clears after the protected stroke ends")
            overlay.document = ["cursors": [:]]; overlay.tick(updateWindows: false)
        }
        print("PASS completed ink lifetime, rebuild, and active-guide/selection isolation on screen \(screenIndex)")
    }
    @MainActor func check() async {
        let hz60:CGFloat=1/60, hz120:CGFloat=1/120, remainder:CGFloat=1/150
        let partitions:[[CGFloat]]=[Array(repeating:0.001,count:40),[0.04],[0.007,0.013,0.003,0.017],[hz60,hz60,remainder],[hz120,hz120,hz120,hz120,remainder]]
        for steps in partitions {
            var spring = Spring(0, 0.3, 0.9); spring.target = 1
            for dt in steps { spring.step(dt) }
            require(abs(spring.value-0.213624598)<0.03 && abs(spring.v-8.072935403)<0.6, "spring integrates 40 ms rather than rounding every frame up: value=\(spring.value), velocity=\(spring.v)")
        }
        var guarded = Spring(0, 0.3, 0.9); guarded.target = 1
        for dt: CGFloat in [0, -1, .nan, .infinity] { guarded.step(dt) }
        require(guarded.value==0 && guarded.v==0, "invalid frame intervals leave the spring unchanged")
        var bounded=guarded; guarded.step(1000); bounded.step(0.05)
        require(guarded.value==bounded.value && guarded.v==bounded.v, "a long pause keeps the bounded frame-time cap")
        let canvas=FlippedView(frame:CGRect(x:0,y:0,width:400,height:400))
        let preview=PointerMark(in:canvas,color:.systemOrange,scale:1)
        for rect in [CGRect(x:20,y:30,width:24,height:240),CGRect(x:20,y:30,width:200,height:20),CGRect(x:20,y:30,width:30,height:30),CGRect(x:20,y:30,width:0.5,height:1.5)] {
            preview.annotations([["id":"highlight","kind":"highlight","target":["screenRect":["x":rect.minX,"y":rect.minY,"w":rect.width,"h":rect.height]]]],motion:nil,local:{$0},resolve:{_ in (CGPoint(x:rect.midX,y:rect.midY),rect)})
            let layer=preview.annotationLayers["highlight"]!
            let ink=layer.path!.copy(strokingWithWidth:layer.lineWidth,lineCap:layer.lineCap == .butt ? .butt : .round,lineJoin:.round,miterLimit:10).boundingBoxOfPath
            require(ink==rect,"rendered highlight covers its rectangle without overflow: \(ink) vs \(rect)")
        }
        preview.remove()
        let realMouse = NSEvent.mouseLocation
        let primary=NSScreen.screens.first!.frame
        let initialMouse=CGPoint(x:primary.minX+primary.width*0.45,y:primary.maxY-primary.height*0.35)
        var simulatedMouse=initialMouse
        overlay.buildWindows()
        let mouseViews=overlay.windows.map { entry -> (NSImageView,NSTextField) in
            let image=NSImageView(image:NSCursor.arrow.image),label=NSTextField(labelWithString:"Simulated mouse")
            label.textColor = .white;label.backgroundColor = .black;label.drawsBackground=true;label.sizeToFit()
            entry.view.addSubview(image);entry.view.addSubview(label);return (image,label)
        }
        overlay.readMouse={ [self] in
            let top=NSScreen.screens.first!.frame.maxY
            for (i,entry) in overlay.windows.enumerated() {
                let p=PointerGeometry.local(CGPoint(x:simulatedMouse.x,y:top-simulatedMouse.y),screen:entry.screen.frame,primaryTop:top)
                mouseViews[i].0.frame=CGRect(x:p.x,y:p.y,width:20,height:24)
                mouseViews[i].1.setFrameOrigin(CGPoint(x:p.x+22,y:p.y))
            }
            return simulatedMouse
        }
        let screen = overlay.windows[0], top = NSScreen.screens.first!.frame.maxY
        let cursor = AgentCursor(frame: screen.view.bounds, color: .systemOrange)
        screen.view.addSubview(cursor)
        cursor.begin(at: CGPoint(x: 20, y: 100))
        require(position(cursor) == CGPoint(x: 20, y: 100), "a new cursor begins at its captured origin")
        cursor.move(to: CGPoint(x: 100, y: 100), click: false)
        await pause(0.03)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            require(position(cursor).x < 80, "the first target uses a flight instead of appearing in place")
        }
        await pause(0.3)
        cursor.move(to: CGPoint(x: 420, y: 240), click: false)
        await pause(1.8)
        require(hypot(position(cursor).x-420, position(cursor).y-240)<2, "cursor resumes after it settles")
        cursor.removeFromSuperview()
        overlay.document = ["cursors": ["fixture": ["target": ["screen": [100,100]], "state": "done", "persistent": true, "name": "Motion fixture", "label": "Finished", "t": Date().timeIntervalSince1970*1000-4000]]]
        overlay.tick()
        await pause(1.3)
        let mark = overlay.marks["fixture"]![0]!
        let localMouse = PointerGeometry.local(CGPoint(x:initialMouse.x,y:top-initialMouse.y),screen:screen.screen.frame,primaryTop:top)
        require(hypot(position(mark.cursor).x-localMouse.x,position(mark.cursor).y-localMouse.y)<120, "finished cursor returns near the mouse instead of freezing at its old target")
        let coversMouse=mark.pill.frame.contains(localMouse)
        _=mark.label("Move your mouse · I’ll follow",name:"Andy · Local demo",state:"done",at:position(mark.cursor),bounds:screen.view.bounds,occupied:[])
        let needed=mark.body.cell!.cellSize(forBounds:CGRect(x:0,y:0,width:mark.body.frame.width,height:1000)).height
        if coversMouse || mark.body.frame.height<needed {print("Label check: covers mouse=\(coversMouse), height=\(mark.body.frame.height), needed=\(needed)")}
        require(!coversMouse && mark.body.frame.height>=needed,"cursor labels avoid the mouse and fit native wrapped text")
        let firstPosition=position(mark.cursor)
        simulatedMouse=CGPoint(x:initialMouse.x+180,y:initialMouse.y+60)
        await pause(1.2)
        require(hypot(position(mark.cursor).x-firstPosition.x,position(mark.cursor).y-firstPosition.y)>100,"idle cursor adapts to mouse motion after settling")
        overlay.tick()
        require(mark.pill.isHidden,"completed instructions expire while the idle cursor remains")
        overlay.document=["cursors":["fixture":["target":["screenRect":["x":100,"y":100,"w":180,"h":80]],"kind":"rect","state":"done","persistent":true,"label":"Old completed step","t":Date().timeIntervalSince1970*1000-60000]]]
        overlay.tick()
        require(mark.pill.isHidden,"reloading old completed output does not revive its instruction")
        require(mark.ring.opacity>0,"label expiry does not erase a persistent selected area")
        let annotations:[[String:Any]]=[["id":"circle","kind":"circle","target":["screenRect":["x":100,"y":100,"w":180,"h":80]],"t":Date().timeIntervalSince1970*1000-5000]]
        overlay.document=["cursors":["fixture":["target":["screen":[420,240]],"state":"waiting","persistent":true,"name":"Motion fixture","annotations":annotations,"t":Date().timeIntervalSince1970*1000]]]
        overlay.tick();await pause(1.5)
        require(hypot(position(mark.cursor).x-420,position(mark.cursor).y-240)<2,"a new guide target interrupts idle following")
        require(overlay.presenceTimer==nil,"active guide targets do not poll the mouse at animation rate")
        let drawn=mark.annotationLayers["circle"]!.path!.boundingBox
        simulatedMouse=CGPoint(x:120,y:top-120);overlay.tick();await pause(0.3)
        require(mark.annotationLayers["circle"]!.path!.boundingBox==drawn,"mouse motion does not move existing marks")
        simulatedMouse=CGPoint(x:420,y:top-240);overlay.tick();await pause(0.8)
        require(hypot(position(mark.cursor).x-420,position(mark.cursor).y-240)>=27,"guide cursor yields space to the real pointer")
        require(mark.leader.opacity>0,"yielding cursor keeps a leader to its exact target")
        overlay.document=["cursors":["fixture":["target":["windowId":999999999,"x":0.5,"y":0.5],"state":"done","persistent":true,"name":"Motion fixture","t":Date().timeIntervalSince1970*1000-4000]]]
        overlay.tick();await pause(1)
        require(mark.cursor.layer!.sublayers!.first!.opacity>0.9,"a completed cursor returns even after its target window closes")
        if let left=overlay.windows.first(where:{$0.screen.frame.minX<0}),let index=overlay.windows.firstIndex(where:{$0.window==left.window}) {
            simulatedMouse=CGPoint(x:left.screen.frame.midX,y:left.screen.frame.midY)
            await pause(1.8)
            let leftCursor=overlay.marks["fixture"]![index]!.cursor
            require(left.view.bounds.contains(position(leftCursor)),"idle companion crosses to a negative-origin display")
            print("PASS negative-origin display")
        } else {print("SKIP negative-origin display: none connected")}
        overlay.document=["cursors":["fixture":["target":["screen":[100,100]],"state":"done","persistent":false,"t":Date().timeIntervalSince1970*1000-3000]]]
        overlay.tick();await pause(0.8)
        require(overlay.presenceTimer != nil,"ordinary nonpersistent cursors return before their idle expiry")
        overlay.document=["cursors":["fixture":["target":["screen":[100,100]],"state":"done","persistent":false,"t":Date().timeIntervalSince1970*1000-9000]]]
        overlay.tick();await pause(0.8)
        require(overlay.presenceTimer==nil && mark.cursor.layer!.sublayers!.first!.opacity<0.1,"ordinary cursor expires without an idle polling timer")
        let now=Date().timeIntervalSince1970*1000
        overlay.document=["cursors":["fixture":["target":["screen":[900,100]],"state":"done","persistent":true,"motion":"long","t":now,"annotations":[["id":"long","kind":"draw","points":[[100,100],[900,100]],"durationMs":3500,"t":now]]]]]
        overlay.tick();await pause(2.7);overlay.tick()
        require(mark.cursor.isTracing && overlay.presenceTimer==nil,"return delay cannot interrupt a long stroke")
        await pause(2);overlay.tick()
        require(!mark.cursor.isTracing && overlay.presenceTimer != nil,"finished stroke returns without another mouse event")
        for index in overlay.windows.indices { await checkActiveGuidance(index); await checkCompletedInk(index) }
        if NSEvent.mouseLocation != realMouse {print("NOTE real mouse changed outside the simulated input source")}
        overlay.document = ["cursors": [:]];overlay.tick()
        require(overlay.marks.isEmpty,"cursor cleanup removes all native marks")
        if CommandLine.arguments.contains("--record") {await pause(3)}
        overlay.readMouse={NSEvent.mouseLocation};overlay.windows.forEach { $0.window.close() }
        print("PASS native retarget, adaptive return, target interruption, mouse avoidance, closed window, negative display, and cleanup")
        exit(0)
    }
}
@main struct MotionTestMain {
    static func main() { let app=NSApplication.shared,delegate=MotionChecks();app.delegate=delegate;withExtendedLifetime(delegate){app.run()} }
}
