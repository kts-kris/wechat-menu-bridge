import AppKit
import ApplicationServices
import XCTest

final class BridgeUITests: XCTestCase {
    @MainActor
    func testControlWindowOpensFirstLaunchSettings() throws {
        continueAfterFailure = false
        let run = try isolated("home-controls")
        try run.start(showControls: true)
        let controls = run.app.windows["微信桥控制台"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5), "The control window did not open; \(run.app.debugDescription)")
        XCTAssertTrue(controls.staticTexts["尚未绑定私聊"].exists)
        try click(controls.buttons["去设置…"])
        XCTAssertTrue(run.app.windows["微信桥设置"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testControlWindowExplainsUnavailableAutomaticReply() throws {
        continueAfterFailure = false
        let run = try isolated("home-controls-unavailable")
        try run.start(showControls: true)
        let controls = try run.controls()
        let toggle = control("automatic-reply", in: controls)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(toggle.isEnabled, "An unconfigured target must not permit automatic replies")
        XCTAssertTrue(controls.staticTexts["请在设置中检查小禾地址，并选定账号和一个私聊。"].waitForExistence(timeout: 5),
                      "A disabled switch must explain what the user can do; \(controls.debugDescription)")
        XCTAssertFalse(controls.staticTexts["确认开启自动回复"].exists)
    }

    @MainActor
    func testOpeningRunningBundleRestoresControlWindow() async throws {
        continueAfterFailure = false
        let run = try isolated("home-reopen")
        try run.start(showControls: true)
        let controls = try run.controls()
        try click(controls.buttons[XCUIIdentifierCloseWindow])
        XCTAssertTrue(controls.waitForNonExistence(timeout: 5))

        try await run.reopenUsingLaunchServices()
        XCTAssertTrue(controls.waitForExistence(timeout: 6), "Reopening the running bundle should reopen the control window")
        try click(controls.buttons["去设置…"])
        XCTAssertTrue(run.app.windows["微信桥设置"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFirstLaunchOpensSettingsFromMenuBar() throws {
        continueAfterFailure = false
        let run = try isolated("home-first")
        // Only the legacy coordinate fallback needs a window as its origin.
        try run.start(showControls: !run.hasHostedMenuBar)
        let panel = try run.openPanel()
        let button = panel.buttons["去设置…"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "The status item did not expose the first-launch panel")
        XCTAssertTrue(panel.staticTexts["尚未绑定私聊"].exists, "Missing unbound-chat status")
        XCTAssertTrue(button.isHittable, "The settings button in the menu popover must be clickable")
        button.click()
        let settings = run.app.windows["微信桥设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings did not open from the menu panel")
        XCTAssertTrue(panel.buttons["menu-exit"].waitForNonExistence(timeout: 5), "The popover must close when opening Settings")
        try click(settings.buttons[XCUIIdentifierCloseWindow])
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        _ = try run.openPanel()
    }

    @MainActor
    func testUnavailableAutomaticReplyExplainsWhatToFixInMenuBar() throws {
        continueAfterFailure = false
        let run = try isolated("home-menu-unavailable")
        try XCTSkipUnless(run.hasHostedMenuBar, "This case covers the system-hosted menu bar on macOS 27")
        try run.start()
        let panel = try run.openPanel()
        let toggle = control("automatic-reply", in: panel)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(toggle.isEnabled, "An unconfigured target must not permit automatic replies")
        XCTAssertTrue(panel.staticTexts["请在设置中检查小禾地址，并选定账号和一个私聊。"].waitForExistence(timeout: 5),
                      "A disabled switch must explain what the user can do; \(panel.debugDescription)")
        XCTAssertFalse(panel.staticTexts["确认开启自动回复"].exists)
    }

    @MainActor
    func testAutomaticReplyStartsFromHostedMenuBarAfterConfirmation() async throws {
        continueAfterFailure = false
        let run = try isolated("home-menu-replies")
        try XCTSkipUnless(run.hasHostedMenuBar, "This case covers the system-hosted menu bar on macOS 27")
        let fixture = try UIFixture("MENUREPLIES")
        try run.start(fixture: fixture)
        let panel = try run.openPanel()
        XCTAssertTrue(panel.staticTexts["未开启"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["模拟联系人"].exists)

        let toggle = control("automatic-reply", in: panel)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The switch must be in the popover")
        XCTAssertTrue(toggle.isEnabled, "The seeded, idle popover must allow opening review; \(panel.debugDescription)")
        XCTAssertTrue(toggle.isHittable, "The menu bar switch itself must be clickable")
        try click(toggle)
        XCTAssertTrue(panel.staticTexts["确认开启自动回复"].waitForExistence(timeout: 5), "The menu bar switch did not open confirmation; \(panel.debugDescription)")
        let risk = panel.staticTexts["可能漏判；检查后收到的叫停可能来不及阻止本次提交，已发出的请求无法撤回。"]
        XCTAssertTrue(risk.waitForExistence(timeout: 5) && risk.isHittable, "The residual risk must be visible before approval")
        let confirm = panel.buttons["确认开启"]
        XCTAssertFalse(confirm.isEnabled)
        let unapproved = try await fixture.request()
        XCTAssertEqual(unapproved.waits, 0)
        XCTAssertEqual(unapproved.models, 0)
        XCTAssertEqual(unapproved.sends, 0)

        let consent = control("peer-consent", in: panel)
        XCTAssertTrue(consent.isHittable, "Consent must be available without opening the console")
        try click(consent)
        XCTAssertTrue(confirm.isHittable, "The confirmation button must be visible in the menu popover")
        try click(confirm)
        XCTAssertTrue(panel.staticTexts["自动回复中"].waitForExistence(timeout: 6), panel.debugDescription)

        try click(control("automatic-reply", in: panel))
        XCTAssertTrue(panel.staticTexts["已停止监听，不再提交新消息。"].waitForExistence(timeout: 5))
        let paused = try await fixture.request()
        XCTAssertEqual(paused.models, 0)
        XCTAssertEqual(paused.sends, 0)
        XCTAssertEqual(paused.faults, 0)
    }

    @MainActor
    func testCloudAutomaticReplyRequiresSeparateMenuBarConfirmation() async throws {
        continueAfterFailure = false
        let run = try isolated("home-menu-cloud")
        try XCTSkipUnless(run.hasHostedMenuBar, "This case covers the system-hosted menu bar on macOS 27")
        let fixture = try UIFixture("MENUCLOUD")
        try run.start(fixture: fixture)
        let panel = try run.openPanel()
        XCTAssertTrue(panel.staticTexts["未开启"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["模拟联系人"].exists)

        clickAutomaticThumb(in: panel)

        XCTAssertTrue(panel.staticTexts["确认开启自动回复"].waitForExistence(timeout: 5), panel.debugDescription)
        XCTAssertTrue(panel.staticTexts["https://wechat-bridge.invalid/v1/chat/completions"].exists)
        let confirm = panel.buttons["确认开启"]
        XCTAssertFalse(confirm.isEnabled)
        let peer = control("peer-consent", in: panel)
        let cloud = control("cloud-consent", in: panel)
        XCTAssertTrue(peer.isHittable && cloud.isHittable, "Both checkboxes must be usable in the menu bar")
        try click(peer)
        XCTAssertFalse(confirm.isEnabled, "Peer consent alone must not authorize cloud transmission")
        try click(cloud)
        XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
        try click(panel.buttons["取消"])
        XCTAssertTrue(panel.staticTexts["确认开启自动回复"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["未开启"].exists)
        let counts = try await fixture.request()
        XCTAssertEqual(counts.waits, 0)
        XCTAssertEqual(counts.models, 0)
        XCTAssertEqual(counts.sends, 0)
        XCTAssertEqual(counts.faults, 0)
    }

    @MainActor
    func testAutomaticReplyOpensReviewWithSettingsStillOpen() async throws {
        continueAfterFailure = false
        let run = try isolated("home-menu-settings")
        try XCTSkipUnless(run.hasHostedMenuBar, "This case covers the system-hosted menu bar on macOS 27")
        let fixture = try UIFixture("MENUSETTINGS")
        try run.start(fixture: fixture)
        let initial = try run.openPanel()
        XCTAssertTrue(initial.staticTexts["未开启"].waitForExistence(timeout: 5))
        try click(initial.buttons["设置"])
        let settings = run.app.windows["微信桥设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(initial.buttons["menu-exit"].waitForNonExistence(timeout: 5))
        try click(settings.buttons["保存设置"])
        XCTAssertTrue(settings.staticTexts["设置已保存。"].waitForExistence(timeout: 5))

        let panel = try run.openPanel(withSettingsOpen: true)
        XCTAssertTrue(panel.staticTexts["未开启"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["模拟联系人"].exists)
        clickAutomaticThumb(in: panel)
        XCTAssertTrue(panel.staticTexts["确认开启自动回复"].waitForExistence(timeout: 5), panel.debugDescription)
        XCTAssertFalse(panel.buttons["确认开启"].isEnabled)
        XCTAssertTrue(panel.buttons["menu-exit"].isHittable)
        XCTAssertTrue(settings.exists, "Review must have opened without closing Settings")
        try click(panel.buttons["取消"])
        XCTAssertTrue(panel.staticTexts["确认开启自动回复"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["未开启"].exists)
        let counts = try await fixture.request()
        XCTAssertEqual(counts.waits, 0)
        XCTAssertEqual(counts.models, 0)
        XCTAssertEqual(counts.sends, 0)
        XCTAssertEqual(counts.faults, 0)
    }

    @MainActor
    func testFirstTimeConfigurationAndLocalPreviewSurviveReopen() async throws {
        continueAfterFailure = false
        let run = try isolated("home-config")
        let fixture = try UIFixture("CONFIG")
        try run.start(showControls: true, fixture: fixture)
        let settings = try run.settings(firstLaunch: true)
        let mcp = fixture.endpoints.mcp.absoluteString
        try enter(mcp, into: settings.textFields["小禾 MCP 地址"])
        try click(settings.buttons["读取账号"])
        try select(in: run.app, named: "wechat-account", option: "模拟账号 · 可读写")
        try enter("fixture", into: settings.textFields["搜索私聊联系人"])
        try click(settings.buttons["查找私聊"])
        try select(in: run.app, named: "direct-contact", option: "模拟联系人 · …fixture", absent: "模拟群聊")

        let full = fixture.endpoints.model.absoluteString
        let base = String(full.dropLast("/chat/completions".count))
        try enter(base, into: settings.textFields["模型 API 地址"])
        try enter("fixture", into: settings.textFields["模型 ID"])
        try click(settings.buttons["保存设置"])
        XCTAssertTrue(settings.staticTexts["设置已保存。"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["实际请求：\(full)"].exists)
        try run.stop()

        try run.start(showControls: true, fixture: fixture)
        let reopened = try run.settings()
        XCTAssertEqual(reopened.textFields["模型 API 地址"].value as? String, base)
        XCTAssertEqual(reopened.textFields["模型 ID"].value as? String, "fixture")
        XCTAssertTrue(reopened.staticTexts["已选账号：模拟账号"].exists)
        XCTAssertTrue(reopened.staticTexts["已选私聊：模拟联系人 · …fixture"].exists)
        let before = try await fixture.request()
        XCTAssertEqual(before.waits, 0)
        XCTAssertEqual(before.models, 0)
        XCTAssertEqual(before.sends, 0)
        try click(reopened.buttons["试拟一条"], in: reopened.scrollViews.firstMatch)
        XCTAssertTrue(reopened.staticTexts["哈哈，那挺好"].waitForExistence(timeout: 6))
        let after = try await fixture.request()
        XCTAssertEqual(after.models, 1)
        XCTAssertEqual(after.waits, 0)
        XCTAssertEqual(after.sends, 0)
        XCTAssertEqual(after.faults, 0)
    }

    @MainActor
    func testCloudRequiresSeparateConsentAndUsesKeychainAfterUpgrade() async throws {
        continueAfterFailure = false
        let fixture = try UIFixture("CLOUD"), run = try isolated("home-cloud")
        let base = "https://wechat-bridge.invalid/v1", full = base + "/chat/completions"
        try run.start(showControls: true, fixture: fixture)
        let settings = try run.settings()
        let url = settings.textFields["模型 API 地址"]
        XCTAssertEqual(url.value as? String, full)
        XCTAssertTrue(settings.staticTexts["已选私聊：模拟联系人 · …fixture"].exists)
        XCTAssertTrue(settings.buttons["试拟一条"].isEnabled)
        try click(settings.buttons["试拟一条"], in: settings.scrollViews.firstMatch)
        XCTAssertTrue(settings.staticTexts["确认单次云端试拟"].waitForExistence(timeout: 5), settings.debugDescription)
        XCTAssertTrue(settings.buttons["确认发送脱敏例句试拟"].isEnabled)
        try click(settings.buttons["取消"], in: settings.scrollViews.firstMatch)
        XCTAssertTrue(settings.staticTexts["确认单次云端试拟"].waitForNonExistence(timeout: 5))
        try enter(base, into: url)
        let key = settings.secureTextFields["model-key"]
        try click(key, in: settings.scrollViews.firstMatch)
        key.typeText("we-are-testing-no-real-api-key")
        try click(settings.buttons["存入钥匙串"], in: settings.scrollViews.firstMatch)
        XCTAssertTrue(settings.staticTexts["密钥已存到当前端点的钥匙串条目。"].waitForExistence(timeout: 5), settings.debugDescription)
        try run.stop()

        try run.start(showControls: true, fixture: fixture)
        let controls = try run.controls()
        let before = try await fixture.request()
        XCTAssertEqual(before.waits, 0)
        XCTAssertEqual(before.sends, 0)
        try click(controls.buttons["只拟稿…"])
        XCTAssertTrue(controls.staticTexts[full].exists)
        let confirm = controls.buttons["确认开启"]
        XCTAssertFalse(confirm.isEnabled)
        try click(control("peer-consent", in: controls))
        XCTAssertFalse(confirm.isEnabled, "Peer consent alone must not authorize cloud transmission")
        let unapproved = try await fixture.request()
        XCTAssertEqual(unapproved.waits, 0)
        XCTAssertEqual(unapproved.models, 0)
        try click(control("cloud-consent", in: controls))
        try click(confirm)
        // No incoming message is injected into this fixture, even after consent.
        XCTAssertTrue(controls.staticTexts["只拟稿 · 不发送"].waitForExistence(timeout: 6), controls.debugDescription)
        try click(controls.buttons["立即暂停"])
        let reopened = try run.settings()
        XCTAssertEqual(reopened.textFields["模型 API 地址"].value as? String, full)
        try click(reopened.buttons["移除"], in: reopened.scrollViews.firstMatch)
        XCTAssertTrue(reopened.staticTexts["当前端点的钥匙串条目已移除。"].waitForExistence(timeout: 5), reopened.debugDescription)
        try click(reopened.buttons[XCUIIdentifierCloseWindow])
        try authorizeDraft(in: controls, cloud: true)
        XCTAssertTrue(controls.staticTexts["请在设置中将这个云端点的密钥存入钥匙串。"].waitForExistence(timeout: 6))
        let after = try await fixture.request()
        XCTAssertGreaterThan(after.waits, 0)
        XCTAssertEqual(after.sends, 0)
        XCTAssertEqual(after.models, 0)
        XCTAssertEqual(after.faults, 0)
    }

    @MainActor
    func testDraftAutoSwitchPauseRestartAndPeerOptOut() async throws {
        continueAfterFailure = false
        let fixture = try UIFixture("REPLIES"), run = try isolated("home-replies")
        try run.start(showControls: true, fixture: fixture)
        let controls = try run.controls()
        try authorizeDraft(in: controls)
        XCTAssertTrue(controls.staticTexts["只拟稿 · 不发送"].waitForExistence(timeout: 6))
        try await fixture.request("push")
        XCTAssertTrue(controls.staticTexts["临时草稿 · 未发送"].waitForExistence(timeout: 8))
        XCTAssertTrue(controls.staticTexts["哈哈，那挺好"].exists)
        let draft = try await fixture.request()
        XCTAssertEqual(draft.sends, 0)
        XCTAssertEqual(draft.models, 1)
        try click(controls.buttons["立即暂停"])
        XCTAssertTrue(controls.staticTexts["临时草稿 · 未发送"].waitForNonExistence(timeout: 5))

        try authorizeAutomatic(in: controls)
        try await fixture.request("push")
        XCTAssertTrue(controls.staticTexts["已提交 · 送达未知"].waitForExistence(timeout: 10))
        let sent = try await fixture.request()
        XCTAssertEqual(sent.last, .init(account: "mock_account", peer: "wxid_fixture", text: "哈哈，那挺好"))
        XCTAssertEqual(sent.sends, 1)
        try click(control("automatic-reply", in: controls))
        XCTAssertTrue(controls.staticTexts["已停止监听，不再提交新消息。"].waitForExistence(timeout: 5))
        try await fixture.request("push") // A line arriving during a pause is not a new grant.
        try authorizeAutomatic(in: controls)
        try click(controls.buttons["退出"])
        try run.stop(requestQuit: false)
        try run.start(showControls: true, fixture: fixture)
        let restarted = try run.controls()
        XCTAssertTrue(restarted.staticTexts["未开启"].waitForExistence(timeout: 6))
        XCTAssertFalse(restarted.staticTexts["自动回复中"].exists)
        let afterRestart = try await fixture.request()
        XCTAssertEqual(afterRestart.sends, 1)
        XCTAssertEqual(afterRestart.models, 2)

        try authorizeAutomatic(in: restarted)
        try await fixture.request("peer-stop")
        XCTAssertTrue(restarted.staticTexts["对方已要求停止。不会再自动回或主动发送。"].waitForExistence(timeout: 6))
        XCTAssertFalse(control("automatic-reply", in: restarted).isEnabled)
        XCTAssertFalse(restarted.buttons["发送一条…"].exists)
        try click(restarted.buttons["对方重新同意后恢复"])
        try click(restarted.buttons["确认"])
        XCTAssertTrue(restarted.staticTexts["未开启"].waitForExistence(timeout: 5))
        let afterOptOut = try await fixture.request()
        XCTAssertEqual(afterOptOut.sends, 1)
        XCTAssertEqual(afterOptOut.models, 2)
        XCTAssertEqual(afterOptOut.faults, 0)
    }

    @MainActor
    func testOneShotConfirmsRecipientTextAndTimeAndChecksReceipt() async throws {
        continueAfterFailure = false
        let fixture = try UIFixture("COMPOSE"), run = try isolated("home-compose")
        try run.start(showControls: true, fixture: fixture)
        let controls = try run.controls()
        let compose = run.app.windows["单独发送一条"]
        let text = "Synthetic-one-shot-confirmation"
        try click(controls.buttons["发送一条…"])
        XCTAssertTrue(compose.waitForExistence(timeout: 5), "Compose did not open")
        let risk = compose.staticTexts["检查后收到的叫停可能来不及阻止本次提交；已发出的请求无法撤回。"]
        XCTAssertTrue(risk.waitForExistence(timeout: 5) && risk.isHittable)
        XCTAssertTrue(compose.staticTexts["模拟联系人"].exists, "Missing selected contact; \(compose.debugDescription)")
        XCTAssertTrue(compose.staticTexts["账号：模拟账号 · 私聊尾号 …fixture"].exists, "Missing selected account or contact suffix; \(compose.debugDescription)")
        let field = control("compose-text", in: compose)
        try enter(text, into: field)
        XCTAssertFalse(compose.buttons["核对内容…"].isEnabled)
        try click(control("one-shot-consent", in: compose))
        try click(compose.buttons["核对内容…"])
        let immediate = "将向 模拟联系人现在提交上方文字。"
        let immediateReview = compose.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", immediate, immediate)).firstMatch
        XCTAssertTrue(immediateReview.waitForExistence(timeout: 5), "Missing immediate-send review; \(compose.staticTexts.debugDescription)")
        XCTAssertEqual(field.value as? String, text)
        XCTAssertFalse(field.isEnabled)
        let before = try await fixture.request()
        XCTAssertEqual(before.sends, 0)
        try click(compose.buttons["确认单次发送"])
        XCTAssertTrue(compose.waitForNonExistence(timeout: 6), "Compose did not close after submitting; \(compose.debugDescription)")
        XCTAssertTrue(controls.staticTexts["已提交 · 送达未知"].waitForExistence(timeout: 8), "Missing submitted receipt; \(controls.debugDescription)")
        let done = try await fixture.request()
        XCTAssertEqual(done.sends, 1)
        XCTAssertEqual(done.last, .init(account: "mock_account", peer: "wxid_fixture", text: text))
        try await fixture.request("delivered")
        try click(controls.buttons["查回执"])
        XCTAssertTrue(controls.staticTexts["已送达（小禾回执）"].waitForExistence(timeout: 6), "Missing refreshed receipt; \(controls.debugDescription)")

        try click(controls.buttons["发送一条…"])
        XCTAssertTrue(compose.buttons["核对内容…"].waitForExistence(timeout: 5), "The new composer reused an old confirmation")
        XCTAssertFalse(compose.buttons["核对内容…"].isEnabled)
        XCTAssertNotEqual(field.value as? String, text)
        let discarded = "Synthetic-abandoned-text"
        try enter(discarded, into: field)
        try click(control("one-shot-consent", in: compose))
        try click(compose.buttons["核对内容…"])
        try click(compose.buttons[XCUIIdentifierCloseWindow])
        XCTAssertTrue(compose.waitForNonExistence(timeout: 6), "Compose did not close when discarding review")

        try click(controls.buttons["发送一条…"])
        XCTAssertTrue(compose.buttons["核对内容…"].waitForExistence(timeout: 5), "Closing an unsubmitted review must revoke it")
        XCTAssertNotEqual(field.value as? String, discarded)
        let scheduledText = "Synthetic-schedule-to-cancel"
        try enter(scheduledText, into: field)
        XCTAssertFalse(compose.buttons["核对内容…"].isEnabled, "Consent must not carry over to the next send")
        try click(control("scheduled-once", in: compose))
        try click(control("one-shot-consent", in: compose))
        try click(compose.buttons["核对内容…"])
        let prefix = "将向 模拟联系人于 ", suffix = "提交上方文字。"
        let review = compose.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", prefix, prefix)).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5), "Missing scheduled-send review; \(compose.staticTexts.debugDescription)")
        let reviewText = try XCTUnwrap([review.value as? String, review.label].compactMap { $0 }.first { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) })
        let time = String(reviewText.dropFirst(prefix.count).dropLast(suffix.count))
        let display = DateFormatter()
        display.timeStyle = .short
        let timeOfDay = try XCTUnwrap(display.date(from: time), "Review must show a valid local time: \(time)")
        let calendar = Calendar.autoupdatingCurrent
        let selected = calendar.dateComponents([.hour, .minute], from: timeOfDay)
        let now = Date.now
        let due = try XCTUnwrap(calendar.date(bySettingHour: try XCTUnwrap(selected.hour), minute: try XCTUnwrap(selected.minute), second: 0, of: now))
        XCTAssertTrue(due > now && calendar.isDate(due, inSameDayAs: now), "The review must show a future time today")
        XCTAssertEqual(field.value as? String, scheduledText)
        XCTAssertFalse(field.isEnabled)
        XCTAssertFalse(control("scheduled-once", in: compose).isEnabled)
        let beforeSchedule = try await fixture.request()
        XCTAssertEqual(beforeSchedule.sends, 1, "Nothing may be sent while reviewing")
        try click(compose.buttons["确认单次发送"])
        XCTAssertTrue(controls.staticTexts["一次发送待提交"].waitForExistence(timeout: 6), "Missing queued schedule; \(controls.debugDescription)")
        let queued = controls.staticTexts["计划 \(time) · 仅此一次"]
        XCTAssertTrue(queued.exists, "The queued time must match the reviewed time")
        try click(controls.buttons["立即暂停"])
        XCTAssertTrue(controls.staticTexts["已停止监听，不再提交新消息。"].waitForExistence(timeout: 6), "Schedule was not cancelled; \(controls.debugDescription)")
        XCTAssertFalse(queued.exists)
        XCTAssertFalse(controls.staticTexts["一次发送待提交"].exists)
        let after = try await fixture.request()
        XCTAssertEqual(after.sends, 1)
        XCTAssertEqual(after.models, 0)
        XCTAssertEqual(after.faults, 0)
    }

    @MainActor
    func testGapAndUnknownSubmissionStayBlockedUntilExplicitReview() async throws {
        continueAfterFailure = false
        let fixture = try UIFixture("RECOVERY"), run = try isolated("home-recovery")
        try run.start(showControls: true, fixture: fixture)
        let controls = try run.controls()
        try authorizeAutomatic(in: controls)
        try await fixture.request("gap")
        XCTAssertTrue(controls.staticTexts["小禾事件缓存有缺口；不会补扫聊天。"].waitForExistence(timeout: 6))
        XCTAssertFalse(control("automatic-reply", in: controls).isEnabled)
        try await fixture.request("gap-clear")
        try click(controls.buttons["核对身份并建立新起点"])
        try click(controls.buttons["确认"])
        XCTAssertTrue(controls.staticTexts["未开启"].waitForExistence(timeout: 6))
        let before = try await fixture.request()
        XCTAssertEqual(before.sends, 0)
        XCTAssertEqual(before.models, 0)

        try await fixture.request("drop")
        try authorizeAutomatic(in: controls)
        try await fixture.request("push")
        XCTAssertTrue(controls.staticTexts["提交结果未知 · 不会重发"].waitForExistence(timeout: 12))
        XCTAssertFalse(control("automatic-reply", in: controls).isEnabled)
        try click(controls.buttons["退出"])
        try run.stop(requestQuit: false)
        try run.start(showControls: true, fixture: fixture)
        let restarted = try run.controls()
        XCTAssertTrue(restarted.buttons["已在微信核对，不重发"].waitForExistence(timeout: 6))
        try click(restarted.buttons["已在微信核对，不重发"])
        try click(restarted.buttons["确认"])
        XCTAssertTrue(restarted.staticTexts["未开启"].waitForExistence(timeout: 6))
        let after = try await fixture.request()
        XCTAssertEqual(after.sends, 1)
        XCTAssertEqual(after.models, 1)
        XCTAssertEqual(after.faults, 0)
    }

    @MainActor private func isolated(_ home: String) throws -> IsolatedApp {
        let run = try IsolatedApp(homeName: home)
        addTeardownBlock { @MainActor in try run.stop() }
        return run
    }

    @MainActor private func control(_ identifier: String, in surface: XCUIElement) -> XCUIElement {
        surface.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func clickAutomaticThumb(in panel: XCUIElement) {
        // Click the off-state thumb, not the label or the switch's best hit point.
        let toggle = control("automatic-reply", in: panel)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5) && toggle.isEnabled && toggle.isHittable, panel.debugDescription)
        let frame = toggle.frame
        XCTAssertTrue((18...96).contains(frame.width) && (10...36).contains(frame.height),
                      "Expected the switch track, not the entire row: \(toggle.debugDescription)")
        let thumb = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        XCTAssertTrue(frame.contains(thumb.screenPoint), "Cannot verify a point on the switch thumb")
        thumb.click()
    }

    @MainActor private func authorizeDraft(in surface: XCUIElement, cloud: Bool = false) throws {
        try click(surface.buttons["只拟稿…"])
        try click(control("peer-consent", in: surface))
        if cloud { try click(control("cloud-consent", in: surface)) }
        try click(surface.buttons["确认开启"])
    }

    @MainActor private func authorizeAutomatic(in surface: XCUIElement) throws {
        try click(control("automatic-reply", in: surface))
        let risk = surface.staticTexts["可能漏判；检查后收到的叫停可能来不及阻止本次提交，已发出的请求无法撤回。"]
        XCTAssertTrue(risk.waitForExistence(timeout: 5) && risk.isHittable)
        XCTAssertFalse(surface.buttons["确认开启"].isEnabled)
        try click(control("peer-consent", in: surface))
        try click(surface.buttons["确认开启"])
        XCTAssertTrue(surface.staticTexts["自动回复中"].waitForExistence(timeout: 6), surface.debugDescription)
    }

    @MainActor private func click(_ element: XCUIElement, in scroll: XCUIElement? = nil) throws {
        guard element.waitForExistence(timeout: 5) else { XCTFail("Missing \(element)"); return }
        if let scroll, !element.isHittable {
            for _ in 0..<4 where !element.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -480) }
        }
        XCTAssertTrue(element.isEnabled, "Not enabled: \(element); \(element.debugDescription)")
        element.click()
    }

    @MainActor private func enter(_ text: String, into field: XCUIElement) throws {
        try click(field)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "Text entered in \(field)")
    }

    @MainActor private func select(in app: XCUIApplication, named name: String, option: String, absent: String? = nil) throws {
        let picker = app.descendants(matching: .any).matching(identifier: name).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Missing picker: \(name)")
        try click(picker)
        if let absent {
            XCTAssertFalse(app.menuItems.matching(NSPredicate(format: "label BEGINSWITH %@", absent)).firstMatch.exists)
        }
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

    func openPanel(withSettingsOpen: Bool = false) throws -> XCUIElement {
        let hosted = hasHostedMenuBar
        // The system-hosted popover isn't necessarily an AX Window. A
        // hosted launch has no console, and only the popover has menu-exit.
        let surface: XCUIElement = hosted ? app : app.windows.containing(.button, identifier: "menu-exit").firstMatch
        let exit = surface.buttons["menu-exit"]
        let settings = app.windows["微信桥设置"]
        XCTAssertEqual(settings.exists, withSettingsOpen, "Unexpected Settings window state before the status-item click")
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

    func settings(firstLaunch: Bool = false) throws -> XCUIElement {
        let controls = try controls()
        let button = controls.buttons[firstLaunch ? "去设置…" : "设置"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        let settings = app.windows["微信桥设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        return settings
    }

    func controls() throws -> XCUIElement {
        let controls = app.windows["微信桥控制台"]
        XCTAssertTrue(controls.waitForExistence(timeout: 8), "The control window did not open; \(app.debugDescription)")
        return controls
    }
}
