import AppKit
import Foundation

let mode = CommandLine.arguments[1]
let pid = pid_t(CommandLine.arguments[2])!
if mode == "window" {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let result = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0 }
    print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
    exit(0)
}
if mode == "activate" {
    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    exit(0)
}
let application = AXUIElementCreateApplication(pid)
func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
    return result
}
func text(_ element: AXUIElement, _ attribute: String) -> String { value(element, attribute) as? String ?? "" }
var entries: [[String: String]] = []
var target: AXUIElement?
func visit(_ element: AXUIElement) {
    let role = text(element, kAXRoleAttribute)
    if role == kAXMenuBarRole { return }
    let labels = [text(element, kAXTitleAttribute), text(element, kAXDescriptionAttribute), text(element, kAXValueAttribute), text(element, kAXIdentifierAttribute)]
    let label = labels.filter { !$0.isEmpty }.joined(separator: " · ")
    if !label.isEmpty { entries.append(["role": role, "label": label,
        "enabled": (value(element, kAXEnabledAttribute) as? NSNumber)?.stringValue ?? "",
        "value": (value(element, kAXValueAttribute) as? NSNumber)?.stringValue ?? text(element, kAXValueAttribute)]) }
    if CommandLine.arguments.count > 3, target == nil, labels.contains(where: { $0.contains(CommandLine.arguments[3]) }) {
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        if (actions as? [String] ?? []).contains(kAXPressAction) { target = element }
    }
    for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child) }
}
visit(application)
if mode == "elements" {
    print(String(data: try JSONSerialization.data(withJSONObject: entries), encoding: .utf8)!)
} else {
    guard let target else { fputs("Cible AX introuvable\n", stderr); exit(2) }
    let result: AXError
    result = AXUIElementPerformAction(target, kAXPressAction as CFString)
    if result != .success { fputs("Action AX refusée : \(result.rawValue)\n", stderr); exit(3) }
}
