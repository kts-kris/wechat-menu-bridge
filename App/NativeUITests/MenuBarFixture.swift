import AppKit

// This app contributes no status items. It supplies a compact regular app
// menu so native tests do not depend on which app the user had in front.
@main @MainActor
private final class MenuBarFixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = MenuBarFixture()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.max(by: { $0.visibleFrame.width < $1.visibleFrame.width }) else {
            Self.fail("No display available for the fixture window")
        }
        let menu = NSMenu()
        let item = NSMenuItem()
        item.submenu = NSMenu(title: "QA")
        item.submenu?.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(item)
        NSApp.mainMenu = menu

        let viewport = screen.visibleFrame
        let frame = NSRect(x: viewport.midX - 145, y: viewport.midY - 40, width: 290, height: 80)
        // A normal window must not be mistaken for an interruption dialog by XCTest.
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "微信桥隔离测试"
        window.setFrame(frame, display: false)
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        waitForFocus(on: screen, deadline: ProcessInfo.processInfo.systemUptime + 8)
    }

    private func waitForFocus(on screen: NSScreen, deadline: TimeInterval) {
        if NSApp.isActive && window?.isKeyWindow == true && window?.screen?.frame == screen.frame {
            guard let path = ProcessInfo.processInfo.environment["WMB_UI_FOCUS_MARKER"], path.hasPrefix("/") else {
                Self.fail("No absolute path for the fixture marker")
            }
            let marker = URL(fileURLWithPath: path)
            do { try "\(screen.frame)\n".write(to: marker, atomically: true, encoding: .utf8) }
            catch { Self.fail("Could not write the fixture marker: \(error.localizedDescription)") }
        } else if ProcessInfo.processInfo.systemUptime < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForFocus(on: screen, deadline: deadline) }
        } else {
            Self.fail("Fixture active: \(NSApp.isActive); key: \(window?.isKeyWindow == true); window display: \(window?.screen?.frame.debugDescription ?? "none"); requested: \(screen.frame)")
        }
    }

    private static func fail(_ text: String) -> Never {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
        exit(2)
    }
}
