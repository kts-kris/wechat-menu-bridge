import AppKit
import ApplicationServices
import Foundation

// Read-only host-side diagnostic for one disposable status item. It never
// posts an event and never prints attributes belonging to a different item.
guard CommandLine.arguments.count == 3 else { exit(2) }
let stage = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
let id = CommandLine.arguments[2]
let prefix = "local.wechatmenubridge.nativeqa."
guard stage.lastPathComponent.hasPrefix(".uitest."), id.hasPrefix(prefix),
      UUID(uuidString: String(id.dropFirst(prefix.count))) != nil,
      Bundle(url: stage.appendingPathComponent("WeChatMenuBridge.app"))?.bundleIdentifier == id else { exit(2) }

let anchor = stage.appendingPathComponent("home-first/status-anchor.json")
let deadline = ProcessInfo.processInfo.systemUptime + 60
let stop = stage.appendingPathComponent("no-more-launches")
while !FileManager.default.fileExists(atPath: anchor.path) && !FileManager.default.fileExists(atPath: stop.path) && ProcessInfo.processInfo.systemUptime < deadline {
    Thread.sleep(forTimeInterval: 0.1)
}
// Allow the system-hosted item to settle, then read the latest anchor once.
Thread.sleep(forTimeInterval: 0.5)
guard let data = try? Data(contentsOf: anchor), let point = try? JSONDecoder().decode(CGPoint.self, from: data),
      point.x.isFinite, point.y.isFinite else { print("Isolated AX hit test: no valid anchor"); exit(0) }
let bundle = stage.appendingPathComponent("WeChatMenuBridge.app").resolvingSymlinksInPath()
let isolated = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
    !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == bundle
}
guard !isolated.isEmpty else { print("Isolated AX hit test: isolated app not running"); exit(0) }
guard AXIsProcessTrusted() else { print("Isolated AX hit test: unavailable"); exit(0) }
var hit: AXUIElement?
let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
guard result == .success, var current = hit else { print("Isolated AX hit test: error \(result.rawValue)"); exit(0) }
var pid: pid_t = 0
if AXUIElementGetPid(current, &pid) == .success {
    let host = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
    let owner = isolated.contains { $0.processIdentifier == pid } ? "isolated app" :
        host.contains { $0.processIdentifier == pid } ? "menu-bar host" : "other process"
    print("Isolated AX hit owner: \(owner)")
}
for _ in 0..<8 {
    for name in ["AXIdentifier", "AXDescription", "AXTitle"] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(current, name as CFString, &value) == .success, let text = value as? String else { continue }
        if text == "bridge-status-\(id)" || text.hasPrefix("微信桥验收 \(id) · ") {
            print("Isolated AX hit test: identity matched at point or an ancestor; no click sent")
            exit(0)
        }
    }
    var parent: CFTypeRef?
    guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
          let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
    current = parent as! AXUIElement
}
print("Isolated AX hit test: identity not matched; no click sent")
