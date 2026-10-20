import Foundation
import CoreGraphics

enum PointerGeometry {
    static func local(_ p: CGPoint, screen: CGRect, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: p.x - screen.minX, y: p.y - (primaryTop - screen.maxY))
    }

    static func selection(from a: CGPoint, to b: CGPoint, primaryTop: CGFloat) -> CGRect {
        CGRect(x: min(a.x, b.x), y: primaryTop - max(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func popup(at p: CGPoint, size: CGSize, bounds: CGRect) -> CGRect {
        let safe = bounds.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(size.width, safe.width), height: min(size.height, safe.height))
        let x = p.x + 16 + size.width <= safe.maxX ? p.x + 16 : p.x - size.width - 16
        let y = p.y - size.height - 12 >= safe.minY ? p.y - size.height - 12 : p.y + 16
        return CGRect(x: max(safe.minX, min(x, safe.maxX - size.width)), y: max(safe.minY, min(y, safe.maxY - size.height)), width: size.width, height: size.height)
    }

    static func companion(at mouse: CGPoint, bounds: CGRect) -> CGPoint {
        let safe = bounds.insetBy(dx: 24, dy: 24)
        let x = mouse.x-38 >= safe.minX ? mouse.x-38 : mouse.x+38
        let y = mouse.y-32 >= safe.minY ? mouse.y-32 : mouse.y+32
        return CGPoint(x:max(safe.minX,min(x,safe.maxX)),y:max(safe.minY,min(y,safe.maxY)))
    }

    static func along(_ points: [CGPoint], progress: CGFloat) -> CGPoint {
        guard let first = points.first else { return .zero }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        if total < 0.001 { return first }
        var distance = max(0, min(1, progress)) * total
        for (index, length) in lengths.enumerated() {
            if distance <= length && length > 0 {
                let t = distance / length, a = points[index], b = points[index + 1]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            distance -= length
        }
        return points.last!
    }

    static func flight(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let dx = b.x-a.x, dy = b.y-a.y, distance = max(1, hypot(dx, dy)), bow = min(40, distance * 0.15)
        let c = CGPoint(x: (a.x+b.x)/2 - dy/distance*bow, y: (a.y+b.y)/2 + dx/distance*bow)
        return (0...20).map { i in let t = CGFloat(i)/20, u = 1-t; return CGPoint(x: u*u*a.x+2*u*t*c.x+t*t*b.x, y: u*u*a.y+2*u*t*c.y+t*t*b.y) }
    }

    static func stroke(kind: String, rect: CGRect?, points: [CGPoint]) -> [CGPoint] {
        if let r = rect {
            if kind == "circle" { return (0...64).map { i in let a = CGFloat(i)/64 * 2 * .pi - .pi/2; return CGPoint(x: r.midX+cos(a)*r.width/2, y: r.midY+sin(a)*r.height/2) } }
            if kind == "highlight" { let inset = min(r.width/2, r.height/2); return [CGPoint(x:r.minX+inset,y:r.midY), CGPoint(x:r.maxX-inset,y:r.midY)] }
        }
        if kind == "arrow", let a = points.first, let b = points.last {
            let angle = atan2(b.y-a.y,b.x-a.x), size = min(16, hypot(b.x-a.x,b.y-a.y)/3)
            return [a,b,CGPoint(x:b.x-cos(angle-0.5)*size,y:b.y-sin(angle-0.5)*size),b,CGPoint(x:b.x-cos(angle+0.5)*size,y:b.y-sin(angle+0.5)*size)]
        }
        return points
    }

    static func cursor(at p: CGPoint, occupied: [CGPoint], screens: [CGRect]) -> CGPoint {
        let offsets: [(CGFloat, CGFloat)] = [(0, 0), (32, 0), (-32, 0), (0, 32), (0, -32), (32, 32), (-32, -32), (32, -32), (-32, 32)]
        for (x, y) in offsets {
            let candidate = CGPoint(x: p.x + x, y: p.y + y)
            if screens.contains(where: { $0.contains(candidate) }) && !occupied.contains(where: { hypot($0.x - candidate.x, $0.y - candidate.y) < 28 }) { return candidate }
        }
        return p
    }

    static func bubble(at p: CGPoint, size: CGSize, bounds: CGRect, occupied: [CGRect]) -> CGRect {
        let safe = bounds.insetBy(dx: 8, dy: 8)
        let w = min(size.width, safe.width), h = min(size.height, safe.height)
        func clamp(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: max(safe.minX, min(x, safe.maxX - w)), y: max(safe.minY, min(y, safe.maxY - h)), width: w, height: h)
        }
        let first = clamp(p.x + 22, p.y + 20)
        var candidates = [first, clamp(p.x - w - 22, p.y + 20), clamp(p.x + 22, p.y - h - 20), clamp(p.x - w - 22, p.y - h - 20)]
        for r in occupied { candidates += [clamp(first.minX, r.minY - h - 8), clamp(first.minX, r.maxY + 8)] }
        return candidates.first { candidate in !occupied.contains { $0.intersects(candidate) } } ?? first
    }
}
