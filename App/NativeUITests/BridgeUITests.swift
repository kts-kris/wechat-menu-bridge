import AppKit
import ApplicationServices
import XCTest

// v2.1 five-pane console. Every case runs a disposable, re-signed copy under
// scripts/uitest.sh; network peers are the synthetic fixture only.
final class BridgeUITests: XCTestCase {
    private static let tabs: [(id: String, title: String, marker: String)] = [
        ("overview", "概览与动态", "只看未读"),
        ("conversations", "会话与策略", "conversation-add"),
        ("plugins", "后链路插件", "plugin-create-digest"),
        ("memory", "人格与记忆", "persona-auto-merge"),
        ("settings", "连接与设置", "mcp-url"),
    ]

    @MainActor
    func testConsoleOpensAndSwitchesAllFiveSidebarTabs() throws {
        continueAfterFailure = false
        let run = try isolated("home-console")
        try run.start(showControls: true)
        let console = try run.controls()
        for tab in Self.tabs {
            XCTAssertTrue(control("console-tab-\(tab.id)", in: console).waitForExistence(timeout: 5),
                          "Missing sidebar entry \(tab.title); \(console.debugDescription)")
        }
        // Visit every pane, then come back to the first, so each switch is observed in both directions.
        for tab in Self.tabs.dropFirst() + Self.tabs.prefix(1) {
            try click(control("console-tab-\(tab.id)", in: console))
            try assertShowing(tab.id, in: console)
        }
    }

    @MainActor
    func testOpeningRunningBundleRestoresConsoleWindow() async throws {
        continueAfterFailure = false
        let run = try isolated("home-reopen")
        try run.start(showControls: true)
        let console = try run.controls()
        try click(control("console-tab-settings", in: console))
        try assertShowing("settings", in: console)
        try click(console.buttons[XCUIIdentifierCloseWindow])
        XCTAssertTrue(console.waitForNonExistence(timeout: 5), "The console did not close")

        try await run.reopenUsingLaunchServices()
        XCTAssertTrue(console.waitForExistence(timeout: 6), "Reopening the running bundle should restore the console")
        XCTAssertTrue(control("console-tab-overview", in: console).waitForExistence(timeout: 5), console.debugDescription)
        try click(control("console-tab-conversations", in: console))
        try assertShowing("conversations", in: console)
    }

    @MainActor
    func testMenuBarPopoverOpensConsoleAndFeedbackSheet() throws {
        continueAfterFailure = false
        // home-first: the App writes status-item diagnostics for this home only.
        let run = try isolated("home-first")
        let hosted = run.hasHostedMenuBar
        // Only the legacy coordinate fallback needs a window as its origin.
        try run.start(showControls: !hosted)
        let panel = try run.openPanel()
        let open = panel.buttons["menu-open-console"], feedback = panel.buttons["menu-feedback"]
        XCTAssertTrue(open.waitForExistence(timeout: 5) && open.isEnabled && open.isHittable, panel.debugDescription)
        XCTAssertTrue(feedback.exists && feedback.isEnabled && feedback.isHittable, panel.debugDescription)
        XCTAssertTrue(control("pause-all-sending", in: panel).exists, "The popover must offer the global pause")
        open.click()
        let console = try run.controls()
        XCTAssertTrue(panel.buttons["menu-exit"].waitForNonExistence(timeout: 5), "The popover must close when opening the console")
        try assertShowing("overview", in: console)
        if hosted {
            // The hosted popover may only open while no console substitutes for it.
            try click(console.buttons[XCUIIdentifierCloseWindow])
            XCTAssertTrue(console.waitForNonExistence(timeout: 5))
        }

        let again = try run.openPanel()
        try click(again.buttons["menu-feedback"])
        XCTAssertTrue(console.waitForExistence(timeout: 6), "Feedback must surface in the console")
        let sheet = console.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The feedback sheet did not open; \(console.debugDescription)")
        let repository = control("feedback-repository", in: sheet)
        XCTAssertTrue(repository.waitForExistence(timeout: 5), sheet.debugDescription)
        XCTAssertEqual(repository.value as? String, "kts-kris/wechat-menu-bridge", "Default issue repository must be prefilled")
        let submit = control("feedback-open-issue", in: sheet)
        XCTAssertTrue(submit.exists && submit.isEnabled, "「打开 Issue 提交页」 must be usable with the default repository")
        XCTAssertTrue(control("feedback-export", in: sheet).isEnabled)
        // Never click submit: it would open a browser outside the isolated copy.
        try click(sheet.buttons["完成"])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testSettingsProbeConfigureLocalModelAndPreview() async throws {
        continueAfterFailure = false
        let fixture = try UIFixture("SETTINGS"), run = try isolated("home-settings")
        let mcp = fixture.endpoints.mcp.absoluteString, model = fixture.endpoints.model.absoluteString
        let base = String(model.dropLast("/chat/completions".count))
        try run.start(showControls: true, fixture: fixture)
        var console = try run.controls()
        try click(control("console-tab-settings", in: console))
        try assertShowing("settings", in: console)
        var form = settingsForm(in: console)

        try enter(mcp, into: control("mcp-url", in: console))
        try click(control("mcp-probe", in: console))
        try select(in: run.app, popUp: console.popUpButtons["账号"], option: "模拟账号")
        XCTAssertTrue(console.staticTexts["模拟账号"].waitForExistence(timeout: 5), "Selected account must be shown")

        try click(control("preset-add", in: console), in: form)
        let sheet = console.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The preset editor did not open")
        try enter("隔离模型", into: field("预设名称，如 本机 Qwen", in: sheet))
        try enter(base, into: field("http://127.0.0.1:11434/v1", in: sheet))
        try enter("fixture", into: field("模型名", in: sheet))
        try click(control("preset-apply", in: sheet))
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        let row = "fixture · \(model)"
        XCTAssertTrue(console.staticTexts[row].waitForExistence(timeout: 5), "A /v1 base must be saved as the chat endpoint")
        try select(in: run.app, popUp: control("default-primary-model", in: console), option: "隔离模型", scroll: form)

        try click(control("settings-save", in: console))
        try waitForSaved(in: console)
        let preview = control("model-preview", in: console)
        try click(preview, in: form)
        XCTAssertTrue(console.staticTexts["会回复"].waitForExistence(timeout: 8), "Missing preview result; \(console.debugDescription)")
        XCTAssertTrue(console.staticTexts["哈哈，那挺好"].exists)
        let previewed = try await fixture.request()
        XCTAssertEqual(previewed.models, 1)
        XCTAssertEqual(previewed.sends, 0, "A preview never sends a WeChat message")
        XCTAssertEqual(previewed.faults, 0)
        try run.stop()

        try run.start(showControls: true, fixture: fixture)
        console = try run.controls()
        try click(control("console-tab-settings", in: console))
        try assertShowing("settings", in: console)
        form = settingsForm(in: console)
        XCTAssertEqual(control("mcp-url", in: console).value as? String, mcp, "MCP address must survive a restart")
        XCTAssertTrue(console.staticTexts["模拟账号"].waitForExistence(timeout: 5), "Account must survive a restart")
        XCTAssertTrue(console.staticTexts[row].waitForExistence(timeout: 5), "Model preset must survive a restart")
        XCTAssertEqual(control("settings-dirty-state", in: console).label, "设置已保存")
        let restarted = control("model-preview", in: console)
        try scrollIntoView(restarted, in: form)
        XCTAssertTrue(restarted.isEnabled, "「模型试拟」 must stay usable after a restart")
        let after = try await fixture.request()
        XCTAssertEqual(after.models, 1)
        XCTAssertEqual(after.sends, 0)
        XCTAssertEqual(after.faults, 0)
    }

    @MainActor
    func testConversationDraftAutoPauseAndOptOut() async throws {
        continueAfterFailure = false
        let fixture = try UIFixture("CONVERSATION"), run = try isolated("home-conversation")
        try run.start(showControls: true, fixture: fixture)
        let console = try run.controls()
        try click(control("console-tab-conversations", in: console))
        try assertShowing("conversations", in: console)
        let row = console.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "模拟联系人")).firstMatch
        try click(row)
        let draft = control("conversation-draft", in: console), auto = control("conversation-auto", in: console)
        XCTAssertTrue(draft.waitForExistence(timeout: 6), "The seeded conversation did not open; \(console.debugDescription)")
        XCTAssertTrue(console.staticTexts["未开启"].waitForExistence(timeout: 6))

        // Draft only: a new line produces a temporary draft and nothing is sent.
        try click(draft)
        XCTAssertTrue(console.staticTexts["只拟稿中"].waitForExistence(timeout: 8), console.debugDescription)
        try await fixture.request("push")
        XCTAssertTrue(console.staticTexts["临时草稿 · 未发送"].waitForExistence(timeout: 10), console.debugDescription)
        XCTAssertTrue(console.staticTexts["哈哈，那挺好"].exists)
        let drafted = try await fixture.request()
        XCTAssertEqual(drafted.models, 1)
        XCTAssertEqual(drafted.sends, 0)

        // Pause, then switch to automatic replies.
        try click(draft)
        XCTAssertTrue(console.staticTexts["只拟稿中"].waitForNonExistence(timeout: 6), "Draft mode did not pause")
        XCTAssertTrue(console.staticTexts["已暂停"].waitForExistence(timeout: 6), console.debugDescription)
        XCTAssertTrue(auto.isEnabled, "A paused conversation can be re-armed")
        try click(auto)
        XCTAssertTrue(console.staticTexts["自动回复中"].waitForExistence(timeout: 8), console.debugDescription)

        // Peer opt-out locks the conversation until an explicit, confirmed recovery.
        try await fixture.request("peer-stop")
        XCTAssertTrue(console.staticTexts["对方已叫停"].waitForExistence(timeout: 10), console.debugDescription)
        XCTAssertTrue(console.staticTexts["对方已要求停止。不会再自动回或主动发送。"].waitForExistence(timeout: 5))
        XCTAssertFalse(auto.isEnabled, "Automatic replies must stay locked after a peer opt-out")
        XCTAssertFalse(draft.isEnabled, "Drafting must stay locked after a peer opt-out")
        let recover = control("session-recover", in: console)
        XCTAssertTrue(recover.waitForExistence(timeout: 5) && recover.label == "对方重新同意后恢复", recover.debugDescription)
        let stopped = try await fixture.request()
        XCTAssertEqual(stopped.sends, 0, "The stop line must never be answered")
        XCTAssertEqual(stopped.faults, 0)
    }

    // MARK: - Helpers

    @MainActor private func isolated(_ home: String) throws -> IsolatedApp {
        let run = try IsolatedApp(homeName: home)
        addTeardownBlock { @MainActor in try run.stop() }
        return run
    }

    @MainActor private func control(_ identifier: String, in surface: XCUIElement) -> XCUIElement {
        surface.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // SwiftUI text fields without an identifier expose their title as label or placeholder.
    @MainActor private func field(_ title: String, in surface: XCUIElement) -> XCUIElement {
        surface.textFields.matching(NSPredicate(format: "placeholderValue == %@ OR label == %@ OR title == %@", title, title, title)).firstMatch
    }

    @MainActor private func settingsForm(in console: XCUIElement) -> XCUIElement {
        console.scrollViews.containing(.any, identifier: "mcp-url").firstMatch
    }

    // The window title follows the pane (macOS 14+ bridges navigationTitle) and
    // only the selected pane's own control exists.
    @MainActor private func assertShowing(_ id: String, in console: XCUIElement) throws {
        let tab = try XCTUnwrap(Self.tabs.first { $0.id == id })
        let marker = id == "overview" ? console.checkBoxes[tab.marker] : control(tab.marker, in: console)
        XCTAssertTrue(marker.waitForExistence(timeout: 6), "Pane \(tab.title) did not show; \(console.debugDescription)")
        let deadline = Date.now.addingTimeInterval(5)
        while console.title != tab.title && Date.now < deadline { RunLoop.current.run(until: Date.now.addingTimeInterval(0.1)) }
        XCTAssertEqual(console.title, tab.title, "Window title must follow the selected pane")
        for other in Self.tabs where other.id != id {
            let element = other.id == "overview" ? console.checkBoxes[other.marker] : control(other.marker, in: console)
            XCTAssertFalse(element.exists, "\(other.title) content still visible on \(tab.title)")
        }
    }

    @MainActor private func waitForSaved(in console: XCUIElement) throws {
        let state = control("settings-dirty-state", in: console)
        let deadline = Date.now.addingTimeInterval(8)
        while state.label != "设置已保存" && Date.now < deadline { RunLoop.current.run(until: Date.now.addingTimeInterval(0.1)) }
        XCTAssertEqual(state.label, "设置已保存", "Settings were not saved; \(console.debugDescription)")
    }

    @MainActor private func scrollIntoView(_ element: XCUIElement, in scroll: XCUIElement) throws {
        guard element.waitForExistence(timeout: 5) else { XCTFail("Missing \(element)"); return }
        for _ in 0..<6 where !element.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -480) }
    }

    @MainActor private func click(_ element: XCUIElement, in scroll: XCUIElement? = nil) throws {
        guard element.waitForExistence(timeout: 5) else { XCTFail("Missing \(element)"); return }
        if let scroll, !element.isHittable { try scrollIntoView(element, in: scroll) }
        XCTAssertTrue(element.isEnabled, "Not enabled: \(element); \(element.debugDescription)")
        element.click()
    }

    @MainActor private func enter(_ text: String, into field: XCUIElement) throws {
        try click(field)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "Text entered in \(field)")
    }

    @MainActor private func select(in app: XCUIApplication, popUp: XCUIElement, option: String, scroll: XCUIElement? = nil) throws {
        XCTAssertTrue(popUp.waitForExistence(timeout: 6), "Missing picker for \(option)")
        try click(popUp, in: scroll)
        try click(app.menuItems[option])
    }
}

@MainActor private final class IsolatedApp {
    let app: XCUIApplication
    let home: URL
    private let stage: URL
    private let bundle: URL
    private let id: String
    private var needsExitCheck = false
    private static var stopBatch = false

    private struct LifecycleFault: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    init(homeName: String) throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["WMB_UI_STAGE"], "run scripts/uitest.sh")
        stage = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        home = stage.appendingPathComponent(homeName, isDirectory: true)
        bundle = stage.appendingPathComponent("WeChatMenuBridge.app", isDirectory: true)
        id = try XCTUnwrap(Bundle(url: bundle)?.bundleIdentifier)
        let prefix = "local.wechatmenubridge.nativeqa."
        guard stage.lastPathComponent.hasPrefix(".uitest."), id.hasPrefix(prefix),
              UUID(uuidString: String(id.dropFirst(prefix.count))) != nil else {
            throw LifecycleFault("Do not UI-test an installed instance")
        }
        app = XCUIApplication(url: bundle)
    }

    func start(showControls: Bool = false, fixture: UIFixture? = nil) throws {
        try verifyLaunchAllowed()
        app.launchEnvironment = launchEnvironment(fixture: fixture)
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + (showControls ? ["--controls"] : [])
        needsExitCheck = true
        XCTContext.runActivity(named: "Confirmed no prior isolated App or helper before launch") { _ in }
        app.launch()
    }

    private func verifyLaunchAllowed() throws {
        guard !Self.stopBatch, !FileManager.default.fileExists(atPath: stopFile.path) else {
            throw LifecycleFault("A prior exit was not confirmed. This batch will not launch another App.")
        }
        do {
            let existing = try QAProcessCheck.liveApps(in: stage)
            guard existing.isEmpty, runningApps.isEmpty, !needsExitCheck else {
                throw LifecycleFault("Not launching while a prior isolated App/helper exit is unconfirmed: \(existing)")
            }
        } catch {
            Self.stopBatch = true
            throw error
        }
    }

    private func launchEnvironment(fixture: UIFixture?) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "CFFIXED_USER_HOME": home.path,
                           "TMPDIR": home.path, "WMB_QA_HOME": home.lastPathComponent]
        if let fixture {
            environment["WMB_QA_MCP"] = fixture.endpoints.mcp.absoluteString
            environment["WMB_QA_MODEL"] = fixture.endpoints.model.absoluteString
        }
        return environment
    }

    func stop(requestQuit: Bool = true) throws {
        guard needsExitCheck else { return }
        if requestQuit {
            if runningApps.contains(where: { $0.bundleURL?.resolvingSymlinksInPath().path == bundle.path }) {
                // Use XCTest's quit request for this exact bundle, not an Apple
                // event from the runner. Neither XCTest state nor the request
                // returning is sufficient evidence that the helper has exited.
                app.terminate()
            }
        }
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            repeat {
                let existing = try QAProcessCheck.liveApps(in: stage)
                if existing.isEmpty, runningApps.isEmpty {
                    needsExitCheck = false
                    XCTContext.runActivity(named: "Confirmed isolated App and helper both exited") { _ in }
                    return
                }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    throw LifecycleFault("Did not confirm isolated App/helper exit: \(existing)")
                }
                RunLoop.current.run(until: Date.now.addingTimeInterval(0.15))
            } while true
        } catch {
            Self.stopBatch = true
            throw error
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
    }

    private var stopFile: URL { stage.appendingPathComponent("no-more-launches") }

    func reopenUsingLaunchServices() async throws {
        let running = try XCTUnwrap(runningApps.first)
        // Reopen the same bundle through the system path used by Finder, without --controls.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        let reopened = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        XCTAssertEqual(reopened.processIdentifier, running.processIdentifier)
    }

    private static let menuBarAgent = "com.apple.MenuBarAgent"
    var hasHostedMenuBar: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.menuBarAgent).isEmpty }

    func openPanel() throws -> XCUIElement {
        let hosted = hasHostedMenuBar
        // The system-hosted popover isn't necessarily an AX Window. A
        // hosted launch has no console, and only the popover has menu-exit.
        let surface: XCUIElement = hosted ? app : app.windows.containing(.button, identifier: "menu-exit").firstMatch
        let exit = surface.buttons["menu-exit"]
        XCTAssertFalse(exit.exists, "The menu panel must be opened by a status-item click")
        if hosted {
            XCTAssertFalse(app.windows["微信桥控制台"].exists, "A console must not substitute for the menu bar")
            let item = try hostedStatusItem()
            item.click()
        } else {
            try clickLocallyHostedStatusItem()
        }
        XCTAssertTrue(exit.waitForExistence(timeout: 5) && exit.isHittable,
                      "Click did not expose a hittable isolated popover; \(app.debugDescription)")
        if hosted { XCTAssertFalse(app.windows["微信桥控制台"].exists) }
        return surface
    }

    private func hostedStatusItem() throws -> XCUIElement {
        let identity = NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "bridge-status-\(id)", "微信桥验收 \(id) · ")
        // The compositor and accessibility publisher may be different
        // processes. Neither an offscreen proxy nor a different app is safe.
        let ownerItem = app.descendants(matching: .any).matching(identity).firstMatch
        let host = XCUIApplication(bundleIdentifier: Self.menuBarAgent)
        let item = host.descendants(matching: .any).matching(identity).firstMatch
        if item.waitForExistence(timeout: 5), item.isHittable { return item }
        if ownerItem.exists, ownerItem.isHittable { return ownerItem }

        let ownerDetail = ownerItem.exists ? "frame \(ownerItem.frame)" : "not found"
        let hostDetail = item.exists ? "frame \(item.frame), enabled \(item.isEnabled), \(hitDiagnostic(item.frame))" : "not found"
        throw LifecycleFault("Neither app nor MenuBarAgent has a hittable isolated status item (app: \(ownerDetail); MenuBarAgent: \(hostDetail)). No fallback click was sent.")
    }

    private func hitDiagnostic(_ frame: CGRect) -> String {
        // Read-only: never click a coordinate when XCTest cannot verify it.
        // Do not log the identity or content of another menu-bar item.
        guard AXIsProcessTrusted() else { return "AX hit test unavailable" }
        guard frame.midX.isFinite, frame.midY.isFinite, !frame.isEmpty else { return "invalid frame" }
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(frame.midX), Float(frame.midY), &hit)
        guard result == .success, let hit else { return "AX hit test error \(result.rawValue)" }
        for name in ["AXIdentifier", "AXDescription", "AXTitle"] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(hit, name as CFString, &value) == .success, let text = value as? String else { continue }
            if text == "bridge-status-\(id)" || text.hasPrefix("微信桥验收 \(id) · ") { return "AX hit matches isolated identity" }
        }
        return "AX hit did not directly match isolated identity"
    }

    private func clickLocallyHostedStatusItem() throws {
        // On older macOS the AppKit status window can be matched by its PID.
        // The console supplies a coordinate origin, not a control to click.
        let reference = try controls()
        let anchor = home.appendingPathComponent("status-anchor.json")
        let deadline = Date.now.addingTimeInterval(6)
        while !FileManager.default.fileExists(atPath: anchor.path) && Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.06))
        }
        let point = try JSONDecoder().decode(CGPoint.self, from: Data(contentsOf: anchor))
        let target = try coordinate(point, in: reference)
        let pid = try XCTUnwrap(runningApps.first?.processIdentifier)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let status = windows.first { row in
            guard row[kCGWindowLayer as String] as? Int == NSWindow.Level.statusBar.rawValue,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(point)
        }
        guard status?[kCGWindowOwnerPID as String] as? Int32 == pid else {
            throw LifecycleFault("Cannot verify the isolated status window is on screen")
        }
        target.click()
    }

    private func coordinate(_ point: CGPoint, in reference: XCUIElement) throws -> XCUICoordinate {
        let zero = reference.coordinate(withNormalizedOffset: .zero)
        let location = zero.screenPoint
        guard location.x.isFinite, location.y.isFinite else { throw LifecycleFault("No finite XCUI origin for status-bar point \(point)") }
        let target = zero.withOffset(CGVector(dx: point.x - location.x, dy: point.y - location.y))
        let resolved = target.screenPoint
        guard resolved == point else { throw LifecycleFault("XCTest did not resolve status-bar point \(point); resolved \(resolved) from \(location)") }
        return target
    }

    func controls() throws -> XCUIElement {
        let controls = app.windows["微信桥控制台"]
        XCTAssertTrue(controls.waitForExistence(timeout: 8), "The console window did not open; \(app.debugDescription)")
        return controls
    }
}
