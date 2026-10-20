// In-memory OS boundaries for source-extracted native-input tests. No AppKit or AX service.
import Foundation
import CoreFoundation
import CoreGraphics // Geometry only. CGEvent and every AX API below are local doubles.

typealias CGWindowID = UInt32
struct CGEventSource {}
enum CGEventType { case mouseMoved, leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp, otherMouseDown, otherMouseUp }
enum CGMouseButton { case left, right, center }
enum CGEventField { case mouseEventClickState, mouseEventWindowUnderMousePointer, mouseEventWindowUnderMousePointerThatCanHandleThisEvent }
struct InputEvent {
    let pid: pid_t
    let type: CGEventType
    let point: CGPoint
    let button: CGMouseButton
    let fields: [CGEventField: Int64]
}
var posted: [InputEvent] = []
final class CGEvent {
    let type: CGEventType
    let point: CGPoint
    let button: CGMouseButton
    var fields: [CGEventField: Int64] = [:]
    init?(mouseEventSource: CGEventSource?, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) {
        type = mouseType; point = mouseCursorPosition; button = mouseButton
    }
    func setIntegerValueField(_ field: CGEventField, value: Int64) { fields[field] = value }
    func postToPid(_ pid: pid_t) { posted.append(InputEvent(pid: pid, type: type, point: point, button: button, fields: fields)) }
}

let kAXRoleAttribute = "AXRole", kAXSubroleAttribute = "AXSubrole", kAXEnabledAttribute = "AXEnabled"
let kAXPositionAttribute = "AXPosition", kAXSizeAttribute = "AXSize", kAXParentAttribute = "AXParent"
let kAXWindowAttribute = "AXWindow", kAXWindowsAttribute = "AXWindows", kAXChildrenAttribute = "AXChildren"
let kAXFocusedWindowAttribute = "AXFocusedWindow", kAXMainAttribute = "AXMain", kAXSelectedAttribute = "AXSelected"
let kAXMinimizedAttribute = "AXMinimized", kAXTitleAttribute = "AXTitle", kAXDescriptionAttribute = "AXDescription"
let kAXValueAttribute = "AXValue", kAXPlaceholderValueAttribute = "AXPlaceholderValue"
enum AXError: Int32 { case success = 0, failure = -25200, apiDisabled = -25211, attributeUnsupported = -25205, noValue = -25212 }
enum AXValueType { case cgPoint, cgSize }
final class AXValue: NSObject {
    let point: CGPoint?
    let size: CGSize?
    init(point: CGPoint) { self.point = point; size = nil }
    init(size: CGSize) { self.size = size; point = nil }
}
func AXValueGetTypeID() -> CFTypeID { 900001 }
func AXUIElementGetTypeID() -> CFTypeID { 900002 }
func CFGetTypeID(_ value: CFTypeRef) -> CFTypeID {
    if value is AXValue { return AXValueGetTypeID() }
    if value is AXUIElement { return AXUIElementGetTypeID() }
    return CoreFoundation.CFGetTypeID(value)
}
@discardableResult func AXValueGetValue(_ value: AXValue, _ type: AXValueType, _ result: UnsafeMutableRawPointer) -> Bool {
    if type == .cgPoint, let point = value.point { result.assumingMemoryBound(to: CGPoint.self).pointee = point; return true }
    if type == .cgSize, let size = value.size { result.assumingMemoryBound(to: CGSize.self).pointee = size; return true }
    return false
}
final class AXUIElement: NSObject {
    let name: String
    var owner: pid_t
    var windowID: CGWindowID?
    var frame: CGRect?
    var attrs: [String: AnyObject]
    var errors: [String: AXError] = [:]
    var pidError = AXError.success
    var timeoutError = AXError.success
    var actions: [String] = []
    var successfulActions = Set<String>()
    var settable = Set<String>()
    var hit: AXUIElement?
    var hitError = AXError.success
    var onHit: (() -> Void)?
    init(_ name: String, pid: pid_t, role: String = "AXGroup", windowID: CGWindowID? = nil, frame: CGRect? = nil) {
        self.name = name; owner = pid; self.windowID = windowID; self.frame = frame
        attrs = [kAXRoleAttribute: role as NSString, kAXEnabledAttribute: kCFBooleanTrue!, kAXMinimizedAttribute: kCFBooleanFalse!]
    }
}
var axCalls: [String] = []
var hitTests: [(AXUIElement, CGPoint)] = []
var applications: [pid_t: AXUIElement] = [:]
var identities: [pid_t: String] = [:]
var tables: [String: Table] = [:]
func AXUIElementCopyAttributeValue(_ el: AXUIElement, _ attribute: CFString, _ result: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    let key = attribute as String
    if let error = el.errors[key] { return error }
    if let value = el.attrs[key] { result.pointee = value; return .success }
    if let frame = el.frame {
        if key == kAXPositionAttribute { result.pointee = AXValue(point: frame.origin); return .success }
        if key == kAXSizeAttribute { result.pointee = AXValue(size: frame.size); return .success }
    }
    return .attributeUnsupported
}
func AXUIElementCopyActionNames(_ el: AXUIElement, _ result: UnsafeMutablePointer<CFArray?>) -> AXError {
    result.pointee = el.actions as CFArray; return .success
}
func AXUIElementPerformAction(_ el: AXUIElement, _ action: CFString) -> AXError {
    axCalls.append("perform \(el.name) \(action)")
    return el.successfulActions.contains(action as String) ? .success : .failure
}
func AXUIElementSetAttributeValue(_ el: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
    let name = attribute as String
    axCalls.append("set \(el.name) \(name)")
    guard el.settable.contains(name) else { return .failure }
    el.attrs[name] = value; return .success
}
@discardableResult func AXUIElementGetPid(_ el: AXUIElement, _ result: UnsafeMutablePointer<pid_t>) -> AXError {
    result.pointee = el.owner; return el.pidError
}
func AXUIElementSetMessagingTimeout(_ el: AXUIElement, _ timeout: Float) -> AXError { el.timeoutError }
func _AXUIElementGetWindow(_ el: AXUIElement, _ result: UnsafeMutablePointer<CGWindowID>) -> AXError {
    guard let id = el.windowID else { return .failure }
    result.pointee = id; return .success
}
func AXUIElementGetAttributeValueCount(_ el: AXUIElement, _ attribute: CFString, _ count: UnsafeMutablePointer<CFIndex>) -> AXError {
    guard let values = el.attrs[attribute as String] as? [AXUIElement] else { return .attributeUnsupported }
    count.pointee = values.count; return .success
}
func AXUIElementCopyAttributeValues(_ el: AXUIElement, _ attribute: CFString, _ start: CFIndex, _ count: CFIndex,
                                   _ result: UnsafeMutablePointer<CFArray?>) -> AXError {
    guard let values = el.attrs[attribute as String] as? [AXUIElement] else { return .attributeUnsupported }
    result.pointee = Array(values.dropFirst(start).prefix(count)) as CFArray; return .success
}
func AXUIElementCopyElementAtPosition(_ root: AXUIElement, _ x: Float, _ y: Float, _ result: UnsafeMutablePointer<AXUIElement?>) -> AXError {
    hitTests.append((root, CGPoint(x: Double(x), y: Double(y))))
    result.pointee = root.hit
    root.onHit?()
    return root.hitError
}
func appElement(_ pid: pid_t) -> AXUIElement { applications[pid]! }
func processIdentity(_ pid: pid_t) throws -> String {
    guard let identity = identities[pid] else { throw AgentError("Fixture process is gone", code: "stale_target") }
    return identity
}
func requireUnlocked() throws {}
func lookup(_ req: [String: Any]) -> Any { fatalError("Lookup is not an input fixture command") }
