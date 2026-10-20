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
