// axctl: drives DeviceHub (Xcode 27's device window) through the macOS accessibility API, for the iPhone Duo
// simulator's fold controls, which have no simctl command. Development tool (tools/foldable/README.md).
//   axctl <pid> dump [depth] [filter] | press <match> | selectrow <match> | set <match> <number>
//         | actions <match> | front | click <x> <y>
// <match> is a substring of an element's "role t=title d=description id=identifier ..." line (first match,
// depth-first). Needs the Accessibility permission for the terminal that runs it.
import ApplicationServices
import Foundation
let args = CommandLine.arguments
let pid = pid_t(args[1])!
let cmd = args[2]
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 10)
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func line(_ e: AXUIElement) -> String {
    let role = attr(e, "AXRole") as? String ?? "?"
    let t = (attr(e, "AXTitle") as? String) ?? ""
    let desc = (attr(e, "AXDescription") as? String) ?? ""
    let ident = (attr(e, "AXIdentifier") as? String) ?? ""
    let help = (attr(e, "AXHelp") as? String) ?? ""
    let val = attr(e, "AXValue").map { "\($0)" } ?? ""
    var pos = CGPoint.zero, size = CGSize.zero
    if let p = attr(e, "AXPosition") { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let s = attr(e, "AXSize") { AXValueGetValue(s as! AXValue, .cgSize, &size) }
    return "\(role) t=\(t) d=\(desc) id=\(ident) h=\(help.prefix(40)) v=\(val.prefix(50)) @\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height))"
}
func children(_ e: AXUIElement) -> [AXUIElement] {
    // at the application, its windows and menu bar: DeviceHub's own child list can come back as copies of the
    // application element (seen after a restart), which would hide every window
    if CFEqual(e, app) {
        let w = (attr(e, "AXWindows") as? [AXUIElement]) ?? []
        let m = attr(e, "AXMenuBar").map { [$0 as! AXUIElement] } ?? []
        return w + m
    }
    return (attr(e, "AXChildren") as? [AXUIElement]) ?? []
}
func walk(_ e: AXUIElement, _ d: Int, _ maxD: Int, _ f: (AXUIElement, Int) -> Bool,
          _ ancestors: [AXUIElement] = []) -> Bool {
    // DeviceHub can expose its application as each AXWindows child. Do not recurse
    // through that cycle before reaching its menu bar (or duplicate device windows).
    if ancestors.contains(where: { CFEqual($0, e) }) { return false }
    if f(e, d) { return true }
    if d >= maxD { return false }
    for c in children(e) { if walk(c, d + 1, maxD, f, ancestors + [e]) { return true } }
    return false
}
func find(_ m: String) -> AXUIElement? {
    var hit: AXUIElement?
    _ = walk(app, 0, 40) { e, _ in
        let l = line(e)
        if l.contains(m) { hit = e; return true }
        return false
    }
    return hit
}
switch cmd {
case "windows":
    for window in (attr(app, "AXWindows") as? [AXUIElement]) ?? [] { print(line(window)) }
case "raisewindow":
    let windows = (attr(app, "AXWindows") as? [AXUIElement]) ?? []
    guard let window = windows.first(where: { (attr($0, "AXTitle") as? String ?? "").contains(args[3]) }) else {
        print("no matching device window"); exit(2)
    }
    let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    print("raise window:", result.rawValue)
    if result != .success { exit(2) }
case "dump":
    let maxD = args.count > 3 ? Int(args[3])! : 30
    let filter = args.count > 4 ? args[4] : ""
    _ = walk(app, 0, maxD) { e, d in
        let l = line(e)
        if filter.isEmpty || l.localizedCaseInsensitiveContains(filter) { print(String(repeating: " ", count: d) + l) }
        return false
    }
case "press", "select", "set", "actions", "raise":
    guard let e = find(args[3]) else { print("no match"); exit(2) }
    print("hit:", line(e))
    var names: CFArray?
    AXUIElementCopyActionNames(e, &names)
    if cmd == "actions" { print(names as? [String] ?? []); break }
    if cmd == "press" { print("press:", AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue) }
    if cmd == "raise" { print("raise:", AXUIElementPerformAction(e, kAXRaiseAction as CFString).rawValue) }
    if cmd == "select" { print("select:", AXUIElementSetAttributeValue(e, "AXSelected" as CFString, kCFBooleanTrue).rawValue) }
    if cmd == "set" { print("set:", AXUIElementSetAttributeValue(e, "AXValue" as CFString, NSNumber(value: Double(args[4])!)).rawValue) }
case "selectrow":
    guard let e = find(args[3]) else { print("no match"); exit(2) }
    var cur: AXUIElement? = e
    while let c = cur, (attr(c, "AXRole") as? String) != "AXRow" { cur = attr(c, "AXParent").map { $0 as! AXUIElement } }
    guard let row = cur else { print("no row"); exit(2) }
    print("row:", line(row), "select:", AXUIElementSetAttributeValue(row, "AXSelected" as CFString, kCFBooleanTrue).rawValue)
case "front":
    print("front:", AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue).rawValue)
case "click":
    let pt = CGPoint(x: Double(args[3])!, y: Double(args[4])!)
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60000)
    }
    print("clicked", pt)
default: print("unknown")
}
