struct MouseCheckFailure: Error { let message: String }
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw MouseCheckFailure(message: message) }
}
NSApplication.shared.setActivationPolicy(.prohibited)
let pointerBefore = NSEvent.mouseLocation
var checks = 0

do {
    if CommandLine.arguments.contains("--missing-spi") {
        do {
            try postMouse(pid: 4242, .leftMouseDown, at: CGPoint(x: 10, y: 10), window: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            throw MouseCheckFailure(message: "missing window binding must fail")
        } catch let error as AgentError { try expect(error.code == "window_input_unavailable", "missing SPI has an explicit error") }
        try expect(captured.isEmpty, "missing SPI posts no events")
        print("PASS missing window-location SPI fails without input"); exit(0)
    }
    for style: NSWindow.StyleMask in [.borderless, .titled] {
        let window = NSWindow(contentRect: CGRect(x: -1000, y: 100, width: 540, height: 440), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let height = NSScreen.screens.first!.frame.maxY
        let frame = CGRect(x: window.frame.minX, y: height-window.frame.maxY, width: window.frame.width, height: window.frame.height)
        let local = CGPoint(x: 134, y: 292), point = CGPoint(x: frame.minX+local.x, y: frame.maxY-local.y)
        for (type, button): (CGEventType, CGMouseButton) in [(.leftMouseDown,.left),(.leftMouseUp,.left),(.rightMouseDown,.right),(.rightMouseUp,.right),(.otherMouseDown,.center),(.otherMouseUp,.center),(.leftMouseDragged,.left),(.mouseMoved,.left)] {
            captured = []
            try postMouse(pid: 4242, type, at: point, button: button, window: CGWindowID(window.windowNumber), frame: frame, clickState: 1)
            try expect(captured.count == 1, "one event was constructed")
            let event = captured[0]
            guard let cocoa = NSEvent(cgEvent: event) else { throw MouseCheckFailure(message: "AppKit event conversion failed") }
            try expect(cocoa.windowNumber == window.windowNumber, "the event must name its receiving window, not only the window under the pointer")
            try expect(abs(cocoa.locationInWindow.x-local.x)<0.001 && abs(cocoa.locationInWindow.y-local.y)<0.001, "the event must keep its window-local point, including title-bar offsets")
            try expect(event.location == point, "global Quartz coordinates stay exact")
            try expect(event.type == type && cocoa.buttonNumber == button.rawValue, "mouse type and button stay exact")
            try expect(cocoa.clickCount == 1 && cocoa.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, "no hidden Command modifier or changed click count")
            checks += 1
        }
        captured = []
        try eventScroll(pid: 4242, at: point, window: CGWindowID(window.windowNumber), frame: frame, direction: "down", pixels: 100)
        try expect(captured.count == 11, "one move and ten scroll events")
        for event in captured.dropFirst() {
            guard let cocoa = NSEvent(cgEvent: event) else { throw MouseCheckFailure(message: "scroll conversion failed") }
            try expect(cocoa.windowNumber == window.windowNumber, "scroll events must name the receiving window")
            try expect(abs(cocoa.locationInWindow.x-local.x)<0.001 && abs(cocoa.locationInWindow.y-local.y)<0.001, "scroll events must keep their local point")
            try expect(cocoa.type == .scrollWheel && cocoa.hasPreciseScrollingDeltas && cocoa.scrollingDeltaY == -10, "pixel scroll units and direction stay exact")
            checks += 1
        }
        try expect(!window.isVisible, "metadata checks do not show windows")
    }
    let valid = CGRect(x: 0, y: 0, width: 100, height: 100)
    for (window, point, frame): (CGWindowID?, CGPoint, CGRect) in [(nil, .zero, valid), (0, .zero, valid), (1, .zero, .zero), (1, CGPoint(x: 101, y: 10), valid), (1, CGPoint(x: Double.nan, y: 10), valid)] {
        captured = []
        do {
            try postMouse(pid: 4242, .leftMouseDown, at: point, window: window, frame: frame)
            throw MouseCheckFailure(message: "invalid event target was accepted")
        } catch let error as AgentError { try expect(error.code == "window_input_unavailable", "invalid target has an explicit error") }
        try expect(captured.isEmpty, "invalid target posts no events"); checks += 1
    }
    if NSEvent.mouseLocation != pointerBefore { print("NOTE the real pointer changed during metadata checks; no events were posted") }
    print("PASS \(checks) real AppKit event metadata cases without input")
} catch {
    fputs("FAIL native mouse metadata: \(error)\n", stderr)
    exit(1)
}
