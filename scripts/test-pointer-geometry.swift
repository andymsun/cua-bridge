import Foundation
import CoreGraphics

@main struct PointerGeometryChecks {
    static func main() {
        let left = CGRect(x: -1920, y: -197, width: 1920, height: 1243)
        let point = PointerGeometry.local(CGPoint(x: -1000, y: 500), screen: left, primaryTop: 1440)
        precondition(point == CGPoint(x: 920, y: 106), "negative-origin display conversion")
        let offscreen = PointerGeometry.local(CGPoint(x: 100, y: 100), screen: left, primaryTop: 1440)
        precondition(offscreen.x == 2020, "keep offscreen motion continuous instead of clipping the target")
        let screen = CGRect(x: 0, y: 0, width: 320, height: 240)
        let bubble = PointerGeometry.bubble(at: CGPoint(x: 315, y: 235), size: CGSize(width: 220, height: 80), bounds: screen, occupied: [])
        precondition(screen.insetBy(dx: 8, dy: 8).contains(bubble), "bubble stays inside all screen edges")
        let second = PointerGeometry.bubble(at: CGPoint(x: 315, y: 235), size: CGSize(width: 220, height: 80), bounds: screen, occupied: [bubble])
        precondition(!second.intersects(bubble), "concurrent cursor labels do not overlap when space exists")
        let rect = PointerGeometry.selection(from: CGPoint(x: 100, y: 80), to: CGPoint(x: -20, y: 40), primaryTop: 1440)
        precondition(rect == CGRect(x: -20, y: 1360, width: 120, height: 40), "drag direction and top-left origin")
        let crowded = CGPoint(x: 100, y: 100)
        let separated = PointerGeometry.cursor(at: crowded, occupied: [crowded], screens: [screen])
        precondition(hypot(separated.x - crowded.x, separated.y - crowded.y) >= 28, "concurrent cursors remain distinct")
        precondition(screen.contains(separated), "collision avoidance stays on a display")
        let selected = CGRect(x: 80, y: 80, width: 160, height: 90)
        let outside = PointerGeometry.bubble(at: CGPoint(x: selected.midX, y: selected.midY), size: CGSize(width: 160, height: 44), bounds: screen, occupied: [selected])
        precondition(!outside.intersects(selected), "labels do not cover a selected area when space exists")
        let popup = PointerGeometry.popup(at: CGPoint(x: -5, y: -190), size: CGSize(width: 360, height: 150), bounds: left)
        precondition(left.insetBy(dx: 8, dy: 8).contains(popup), "popup stays on the pointer's display")
        precondition(abs(popup.maxX + 5) < 40, "popup flips beside the pointer near an edge")
        let trace = PointerGeometry.along([CGPoint(x: 0,y: 0), CGPoint(x: 100,y: 0), CGPoint(x: 100,y: 100)], progress: 0.75)
        precondition(trace == CGPoint(x: 100,y: 50), "stroke motion uses distance, not point count")
        let circle = PointerGeometry.stroke(kind: "circle", rect: CGRect(x: 20,y: 30,width: 100,height: 80), points: [])
        precondition(circle.count > 30 && hypot(circle.first!.x-circle.last!.x,circle.first!.y-circle.last!.y)<0.01)
        for mouse in [CGPoint(x:left.minX+2,y:left.minY+2),CGPoint(x:left.maxX-2,y:left.maxY-2)] {
            let companion=PointerGeometry.companion(at:mouse,bounds:left)
            precondition(left.insetBy(dx:24,dy:24).contains(companion),"idle companion stays inside negative-origin screen edges")
            precondition(hypot(companion.x-mouse.x,companion.y-mouse.y)>=28,"idle companion does not cover the mouse")
        }
        print("PASS coordinates, popup placement, label/cursor collisions, and stroke geometry")
    }
}
