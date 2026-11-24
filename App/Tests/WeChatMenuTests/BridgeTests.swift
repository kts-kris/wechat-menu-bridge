import Darwin
import Foundation
import Security
import XCTest
@testable import WeChatMenu

final class BridgeTests: XCTestCase {
    func testBeginBlockerPreservesEveryExistingSafetyGate() {
        let singleBlockers: [Int: BeginBlocker] = [0: .backend, 3: .running, 5: .inFlight, 9: .uncertain,
                                                  17: .peerStopped, 33: .authorizing, 65: .savingSettings]
        for bits in 0..<128 {
            let ready = bits & 1 != 0
            var state = EngineState()
            state.running = bits & 2 != 0
            state.inFlight = bits & 4 != 0
            state.uncertain = bits & 8 != 0
            state.peerStopped = bits & 16 != 0
            let authorizing = bits & 32 != 0
            let saving = bits & 64 != 0
            let expected = ready && !state.running && !state.inFlight && !state.uncertain && !state.peerStopped && !authorizing && !saving
            let blocker = BeginBlocker.evaluate(ready: ready, state: state, authorizing: authorizing, savingSettings: saving)
            XCTAssertEqual(blocker == nil, expected, "Changed safety gate for mask \(bits)")
            if let expectedBlocker = singleBlockers[bits] { XCTAssertEqual(blocker, expectedBlocker) }
            if let blocker { XCTAssertFalse(blocker.guidance.isEmpty) }
        }
    }

    func testReplyBlockerExplainsEveryReasonWithoutAuthorizing() {
        var config = Configuration()
        XCTAssertEqual(ReplyBlocker.evaluate(begin: .backend, configuration: config, reason: nil), .begin(.backend))
        XCTAssertEqual(ReplyBlocker.evaluate(begin: nil, configuration: config, reason: nil), .target)
        config.mcp = "http://127.0.0.1:12345/mcp"
        config.account = "mock_account"
        config.contact = ContactOption(id: "wxid_fixture", label: "模拟联系人")
        XCTAssertEqual(ReplyBlocker.evaluate(begin: nil, configuration: config, reason: nil), .model)
        config.modelName = "fixture"
        XCTAssertNil(ReplyBlocker.evaluate(begin: nil, configuration: config, reason: nil))
        XCTAssertNil(ReplyBlocker.evaluate(begin: nil, configuration: config, reason: "settings-changed"))
        for reason in ["event-gap", "wechat-changed", "mcp-contract", "wrong-anchor", "backlog-limit"] {
            let blocker = ReplyBlocker.evaluate(begin: nil, configuration: config, reason: reason)
            XCTAssertEqual(blocker, .read(reason))
            XCTAssertFalse(blocker?.guidance.isEmpty ?? true)
        }
        XCTAssertEqual(ReplyBlocker.evaluate(begin: .uncertain, configuration: config, reason: "event-gap"), .begin(.uncertain))
    }

    func testConfigurationRoundTripAndPermissions() throws {
        let root = try privateTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SettingsDisk(directory: root)
        XCTAssertNil(try disk.load().target)
        var cfg = Configuration()
        cfg.mcp = "http://127.0.0.1:12345/mcp"
        cfg.account = "mock_account"
        cfg.contact = ContactOption(id: "wxid_fixture", label: "模拟联系人")
        try disk.save(cfg)
        XCTAssertEqual(try disk.load(), cfg)
        let file = root.appendingPathComponent("settings.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains("apiKey"))
        XCTAssertFalse(saved.contains("cloudApproved"))
        XCTAssertFalse(saved.contains("expiresAt"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root)
        XCTAssertThrowsError(try disk.load())
        XCTAssertThrowsError(try disk.save(cfg))
    }

    func testEndpointsAndToday() throws {
        XCTAssertTrue(Configuration.validURL("http://127.0.0.1:5245/mcp", kind: "mcp"))
        XCTAssertTrue(Configuration.validURL("https://example.invalid/v1/chat/completions", kind: "cloud"))
        for bad in ["http://127.0.0.1:5245/mcp?secret=bad", "http://localhost:5245/mcp", "http://127.0.0.2:5245/mcp",
                    "http://user:pass@127.0.0.1:5245/mcp", "https://127.0.0.1:5245/mcp", "http://127.0.0.1:5245/other"] {
            XCTAssertFalse(Configuration.validURL(bad, kind: "mcp"))
        }
        let now = Date.now
        let midnight = nextMidnight(now)
        XCTAssertGreaterThan(midnight, now)
        XCTAssertEqual(Calendar.autoupdatingCurrent.component(.hour, from: midnight), 0)
    }

    func testLegacySettingsKeepScopeAndDropTheDailyLimitOnSave() throws {
        let root = try privateTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let legacy = """
            {"mcp":"http://127.0.0.1:12345/mcp","account":"mock_account","accountLabel":"模拟账号",
             "contact":{"id":"wxid_fixture","label":"模拟联系人"},"mode":"cloud",
             "modelURL":"https://example.invalid/v1/chat/completions","modelName":"fixture",
             "stylePath":"/fixture/style.md","memoryPath":"/fixture/memory.md","dailyLimit":1}
            """
        try Data(legacy.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let disk = SettingsDisk(directory: root)
        let cfg = try disk.load()
        XCTAssertEqual(cfg.account, "mock_account")
        XCTAssertEqual(cfg.contact, ContactOption(id: "wxid_fixture", label: "模拟联系人"))
        XCTAssertEqual(cfg.modelEndpoint, "https://example.invalid/v1/chat/completions")
        XCTAssertEqual(cfg.stylePath, "/fixture/style.md")
        XCTAssertEqual(cfg.memoryPath, "/fixture/memory.md")
        try disk.save(cfg)
        XCTAssertEqual(try disk.load(), cfg)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("dailyLimit"))
    }

    func testModelBaseAddressResolvesWithoutChangingDestination() throws {
        var cfg = Configuration()
        cfg.mode = .cloud
        cfg.modelName = "fixture"
        for address in ["https://example.invalid/api/v1", " https://example.invalid/api/v1/ \n",
                        "https://example.invalid/api/v1/chat/completions"] {
            cfg.modelURL = address
            XCTAssertTrue(Configuration.validURL(address, kind: "cloud"))
            XCTAssertTrue(cfg.modelComplete)
            XCTAssertEqual(try cfg.model(approved: true)["url"] as? String, "https://example.invalid/api/v1/chat/completions")
        }
        for address in ["https://v1", "https://example.invalid/v1/models", "https://example.invalid/v1?key=foo",
                        "https://example.invalid/v1#fragment", "https://user:pass@example.invalid/v1",
                        "https://example.invalid/a/../v1", "https://example.invalid/%76%31", "https:///v1",
                        "https://example.invalid:99999/v1", "http://example.invalid/v1", "https://127.0.0.1/v1"] {
            XCTAssertFalse(Configuration.validURL(address, kind: "cloud"), address)
        }
        XCTAssertTrue(Configuration.validURL("http://127.0.0.1:11434/v1", kind: "local"))
        XCTAssertFalse(Configuration.validURL("http://example.invalid:11434/v1", kind: "local"))
    }

    // The test creates and deletes one temporary keychain without touching the user's default keychain.
    @available(macOS, deprecated: 12.0, message: "Use the classic Keychain path to test ad-hoc builds without entitlements.")
    func testKeychainStoresByExactDestination() throws {
        let dir = try privateTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let isolated = try ScopedKeychain(directory: dir)
        defer { _ = SecKeychainDelete(isolated.keychain) }
        let store = isolated.storage
        let target = "https://example.invalid/v1/chat/completions"
        let base = "https://example.invalid/v1/"
        let key = "fixture-key-\(UUID().uuidString)"
        let legacy = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                      kSecAttrAccount as String: target, kSecValueData as String: Data(key.utf8),
                       kSecUseKeychain as String: isolated.keychain] as [String: Any]
        XCTAssertEqual(SecItemAdd(legacy as CFDictionary, nil), errSecSuccess)
        XCTAssertTrue(try store.read(base) == key)
        XCTAssertTrue(try store.read(target) == key)
        XCTAssertThrowsError(try store.read("https://other.invalid/v1"))
        XCTAssertThrowsError(try store.read("https://example.invalid/other/v1"))
        let updated = "fixture-updated-\(UUID().uuidString)"
        try store.save(updated, for: base)
        XCTAssertTrue(try store.read(target) == updated)
        try store.remove(base)
        XCTAssertThrowsError(try store.read(target))
        try store.save(key, for: base)
        XCTAssertTrue(try store.read(target) == key)
    }

    @MainActor
    @available(macOS, deprecated: 12.0, message: "Use an isolated classic Keychain in this test.")
    func testCloudConfirmationAndMissingKeyThroughBundledHelper() async throws {
        let h = try Fixture()
        defer { h.close() }
        let root = try privateTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = try ScopedKeychain(directory: root)
        defer { _ = SecKeychainDelete(isolated.keychain) }
        let store = AppStore(disk: SettingsDisk(directory: root), executable: h.engine, keychain: isolated.storage)
        defer { store.client.shutdown() }
        let profile = root.appendingPathComponent("synthetic-style.md")
        try Data("合成示例：<!-- bridge-cloud:start --> 短句 <!-- bridge-cloud:end -->".utf8).write(to: profile)
        let cfg = Configuration(mcp: h.info.mcp, account: "mock_account", accountLabel: "模拟账号",
                                contact: ContactOption(id: "wxid_fixture", label: "模拟联系人"), mode: .cloud,
                                modelURL: "https://example.invalid/qa/v1", modelName: "synthetic-model", stylePath: profile.path)
        store.start()
        try await eventually { store.ready }
        try await store.save(cfg)
        XCTAssertThrowsError(try store.arm(.automatic, consent: true, cloud: false, confirmed: cfg)) {
            XCTAssertEqual($0 as? BridgeFault, BridgeFault("cloud-not-approved"))
        }
        try store.arm(.automatic, consent: true, cloud: true, confirmed: cfg)
        try await eventually { store.error == "missing-key" && !store.authorizing }
        try await store.saveKey("fixture-key-\(UUID().uuidString)", for: "https://example.invalid/qa/v1/chat/completions")
        try store.arm(.automatic, consent: true, cloud: true, confirmed: cfg)
        try await eventually { store.error == "cloud-profile" && !store.authorizing }
        let blocked = try await h.counts()
        XCTAssertEqual(blocked.waits, 0)
        XCTAssertEqual(blocked.models, 0)
        XCTAssertEqual(blocked.sends, 0)
        try Data("<!-- bridge-cloud:start -->\n只用短句\n<!-- bridge-cloud:end -->".utf8).write(to: profile)
        try store.arm(.automatic, consent: true, cloud: true, confirmed: cfg)
        try await eventually { store.state.phase == "listening" && !store.authorizing }
        store.pause() // No fixture event is injected on this route: the cloud URL is never called.
        try await eventually { !store.automaticReplyOn && !store.state.running }
        try await store.removeKey(for: cfg.modelURL)
        try store.arm(.automatic, consent: true, cloud: true, confirmed: cfg)
        try await eventually { store.error == "missing-key" && !store.authorizing }
        let after = try await h.counts()
        XCTAssertEqual(after.models, 0)
        XCTAssertEqual(after.sends, 0)
        XCTAssertEqual(after.faults, 0)
    }

    @MainActor
    func testExtractedAppStartsWithCleanHomeAndLegacySettingsWithoutArming() async throws {
        guard let path = ProcessInfo.processInfo.environment["WMB_TEST_APP"] else { throw XCTSkip("run bash scripts/selftest.sh") }
        let stage = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["WMB_TEST_TEMP"]), isDirectory: true)
        let h = try Fixture()
        defer { h.close() }
        let legacy: [String: Any] = [
            "mcp": h.info.mcp, "account": "mock_account", "accountLabel": "模拟账号",
            "contact": ["id": "wxid_fixture", "label": "模拟联系人"], "mode": "local", "modelURL": h.info.model,
            "modelName": "fixture", "stylePath": "", "memoryPath": "", "dailyLimit": 1,
        ]
        let saved = try JSONSerialization.data(withJSONObject: legacy)
        for useLegacy in [false, true] {
            let home = try privateTemp()
            defer { try? FileManager.default.removeItem(at: home) }
            let pathInHome = home.appendingPathComponent("Library/Application Support/WeChatMenuBridge", isDirectory: true)
            let settings = pathInHome.appendingPathComponent("settings.json")
            let journal = pathInHome.appendingPathComponent("bridge.sqlite")
            if useLegacy {
                try SettingsDisk(directory: pathInHome).prepare()
                try saved.write(to: settings)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
            }
            let app = Process()
            app.executableURL = URL(fileURLWithPath: path)
            app.currentDirectoryURL = home
            app.environment = ["PATH": "/usr/bin:/bin", "CFFIXED_USER_HOME": home.path, "HOME": home.path, "TMPDIR": home.path]
            app.standardInput = FileHandle.nullDevice
            app.standardOutput = FileHandle.nullDevice
            app.standardError = FileHandle.nullDevice
            guard try QAProcessCheck.liveApps(in: stage).isEmpty else { throw BridgeFault("qa-exit-unconfirmed") }
            try app.run()
            defer { if app.isRunning { app.terminate() } }
            try await eventually {
                let size = (try? FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int) ?? 0
                return !app.isRunning || size > 0
            }
            XCTAssertTrue(app.isRunning, "Extracted app did not stay up in the isolated home")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? Int, 0o600)
            if useLegacy {
                let backup = pathInHome.appendingPathComponent("settings.v1.bak.json")
                XCTAssertEqual(try Data(contentsOf: backup), saved)
                let migrated = try String(contentsOf: settings, encoding: .utf8)
                XCTAssertTrue(migrated.contains("\"schemaVersion\":2"))
                XCTAssertTrue(migrated.contains("\"replyMode\":\"off\""))
            } else { XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path)) }
            let calls = try await h.counts()
            XCTAssertEqual(calls.waits, 0)
            XCTAssertEqual(calls.models, 0)
            XCTAssertEqual(calls.sends, 0)
            if app.isRunning { app.terminate() }
            try await eventually { !app.isRunning }
            app.waitUntilExit()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while try !QAProcessCheck.liveApps(in: stage).isEmpty {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeFault("qa-exit-unconfirmed") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    @MainActor
    func testSwiftControllerThroughBundledHelperWithSyntheticMCPAndModel() async throws {
        let h = try Fixture()
        let root = try privateTemp()
        let disk = SettingsDisk(directory: root)
        let store = AppStore(disk: disk, executable: h.engine)
        defer { store.client.shutdown(); try? FileManager.default.removeItem(at: root); h.close() }
        store.start()
        try await eventually { store.ready }
        XCTAssertEqual(store.state.phase, "idle")
        XCTAssertFalse(store.automaticReplyOn)
        let accounts = try await store.accounts(h.info.mcp)
        XCTAssertEqual(accounts.map(\.id), ["mock_account"])
        XCTAssertTrue(accounts[0].canSend)
        let contacts = try await store.contacts(h.info.mcp, account: accounts[0].id, query: "模拟")
        XCTAssertEqual(contacts.map(\.id), ["wxid_fixture"])

        var cfg = Configuration()
        cfg.mcp = h.info.mcp; cfg.account = accounts[0].id; cfg.accountLabel = accounts[0].label; cfg.contact = contacts[0]
        cfg.modelURL = h.info.model.replacingOccurrences(of: "/chat/completions", with: ""); cfg.modelName = "fixture"
        try await store.save(cfg)
        XCTAssertEqual(try disk.load(), cfg)
        XCTAssertFalse(store.automaticReplyOn)
        XCTAssertThrowsError(try store.arm(.automatic, consent: false, cloud: false, confirmed: cfg))
        try store.arm(.automatic, consent: true, cloud: false, confirmed: cfg)
        XCTAssertTrue(store.automaticReplyOn)
        store.pause() // Turn off before the activation task sends its arm command.
        try await eventually { !store.automaticReplyOn && store.state.phase == "paused" }
        let canceled = try await h.counts()
        XCTAssertEqual(canceled.waits, 0)
        XCTAssertEqual(canceled.sends, 0)

        let preview = try await store.preview(cfg, text: "阳光还挺好")
        XCTAssertEqual(preview, PreviewResult(action: "reply", text: "哈哈，那挺好"))
        try store.arm(.draft, consent: true, cloud: false, confirmed: cfg)
        try await eventually { store.state.phase == "listening" && store.state.dryRun && !store.authorizing }
        _ = try await h.counts("push")
        try await eventually { store.state.draft == preview.text }
        XCTAssertTrue(store.state.dryRun)
        XCTAssertFalse(store.automaticReplyOn)
        let draftsOnly = try await h.counts()
        XCTAssertEqual(draftsOnly.sends, 0)
        store.pause()
        try await eventually { !store.state.running }
        XCTAssertNil(store.state.draft)

        try store.arm(.automatic, consent: true, cloud: false, confirmed: cfg)
        try await eventually { store.state.phase == "listening" && store.state.autoReply && !store.authorizing }
        _ = try await h.counts("push")
        try await eventually { store.state.statistics?.count == 1 }
        XCTAssertEqual(store.state.receipt?.caption, "已提交 · 送达未知")
        store.pause()
        try await eventually { !store.state.running && !store.automaticReplyOn }
        _ = try await h.counts("push") // A new message while off is not sent or generated.

        try await store.send("确认过的合成单条", at: nil, confirmed: cfg)
        try await eventually { store.state.reason == "one-shot-complete" }
        let final = try await h.counts()
        XCTAssertEqual(final.sends, 2)
        XCTAssertEqual(final.models, 3)
        XCTAssertEqual(final.faults, 0)
    }

    @MainActor
    func testHelperEOFAndSingleInstanceStateLock() async throws {
        let engine = try Fixture.executable()
        let root = try privateTemp()
        let client = BridgeClient(), competitor = BridgeClient()
        defer { client.shutdown(); competitor.shutdown(); try? FileManager.default.removeItem(at: root) }
        try client.start(engine: engine, directory: root)
        try await eventually { client.ready }
        var failure: String?
        competitor.onFailure = { code in failure = code }
        try competitor.start(engine: engine, directory: root)
        try await eventually { failure != nil }
        XCTAssertEqual(failure, "storage-in-use")
        client.shutdown()
        let replacement = BridgeClient()
        defer { replacement.shutdown() }
        try await Task.sleep(nanoseconds: 350_000_000)
        try replacement.start(engine: engine, directory: root)
        try await eventually { replacement.ready }
        let status: EngineState = try await replacement.request("status")
        XCTAssertFalse(status.running)
        XCTAssertFalse(status.autoReply)
        XCTAssertEqual(status.phase, "idle")
    }

    @MainActor
    @available(macOS, deprecated: 12.0, message: "Use an isolated classic Keychain in this test.")
    func testCloudPreviewNeedsApprovalBeforeKeychainOrEngine() async throws {
        let root = try privateTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = try ScopedKeychain(directory: root)
        defer { _ = SecKeychainDelete(isolated.keychain) }
        let engine = try FakeEngine(directory: root)
        let store = AppStore(disk: SettingsDisk(directory: root), executable: engine.executable, keychain: isolated.storage)
        defer { store.client.shutdown() }
        let cfg = cloudPreviewConfiguration()
        try await store.saveKey("fixture-key-\(UUID().uuidString)", for: cfg.modelURL)

        // 后台未就绪时同样先报未同意，错误码不随运行状态变化。
        await assertPreviewFault("cloud-not-approved") { try await store.preview(cfg, text: "合成例句") }
        store.start()
        try await eventually { store.ready }
        await assertPreviewFault("cloud-not-approved") { try await store.preview(cfg, text: "合成例句") }
        await assertPreviewFault("cloud-not-approved") { try await store.preview(cfg, text: "合成例句", cloudApproved: false) }
        XCTAssertTrue(try engine.requests().isEmpty, "An unapproved cloud preview must not reach the helper")
    }

    @MainActor
    @available(macOS, deprecated: 12.0, message: "Use an isolated classic Keychain in this test.")
    func testCloudPreviewReadsEndpointKeyOnlyAfterApproval() async throws {
        let root = try privateTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = try ScopedKeychain(directory: root)
        defer { _ = SecKeychainDelete(isolated.keychain) }
        let engine = try FakeEngine(directory: root)
        let store = AppStore(disk: SettingsDisk(directory: root), executable: engine.executable, keychain: isolated.storage)
        defer { store.client.shutdown() }
        let cfg = cloudPreviewConfiguration()
        store.start()
        try await eventually { store.ready }

        await assertPreviewFault("missing-key") { try await store.preview(cfg, text: "合成例句", cloudApproved: true) }
        XCTAssertTrue(try engine.requests().isEmpty, "A missing key must stop before the helper")

        // 其他端点的密钥不能用于当前端点。
        try await store.saveKey("fixture-other-\(UUID().uuidString)", for: "https://other.invalid/v1")
        await assertPreviewFault("missing-key") { try await store.preview(cfg, text: "合成例句", cloudApproved: true) }
        XCTAssertTrue(try engine.requests().isEmpty)

        let key = "fixture-key-\(UUID().uuidString)"
        try await store.saveKey(key, for: cfg.modelURL)
        let result = try await store.preview(cfg, text: "合成例句", cloudApproved: true)
        XCTAssertEqual(result, PreviewResult(action: "reply", text: "合成试拟"))
        let sent = try engine.requests()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]["method"] as? String, "preview")
        let params = try XCTUnwrap(sent[0]["params"] as? [String: Any])
        XCTAssertEqual(params["text"] as? String, "合成例句")
        let model = try XCTUnwrap(params["model"] as? [String: Any])
        XCTAssertEqual(model["mode"] as? String, "cloud")
        XCTAssertEqual(model["url"] as? String, "https://example.invalid/qa/v1/chat/completions")
        XCTAssertEqual(model["cloudApproved"] as? Bool, true)
        XCTAssertTrue(model["apiKey"] as? String == key, "The helper must receive this endpoint's key")
    }

    @MainActor
    @available(macOS, deprecated: 12.0, message: "Use an isolated classic Keychain in this test.")
    func testLocalPreviewNeverCarriesCloudApprovalOrKey() async throws {
        let root = try privateTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = try ScopedKeychain(directory: root)
        defer { _ = SecKeychainDelete(isolated.keychain) }
        let engine = try FakeEngine(directory: root)
        let store = AppStore(disk: SettingsDisk(directory: root), executable: engine.executable, keychain: isolated.storage)
        defer { store.client.shutdown() }
        var cfg = Configuration()
        cfg.modelName = "synthetic-model"
        store.start()
        try await eventually { store.ready }

        for approved in [false, true] {
            _ = try await store.preview(cfg, text: "合成例句", cloudApproved: approved)
        }
        let sent = try engine.requests()
        XCTAssertEqual(sent.count, 2)
        for frame in sent {
            let params = try XCTUnwrap(frame["params"] as? [String: Any])
            let model = try XCTUnwrap(params["model"] as? [String: Any])
            XCTAssertEqual(model["mode"] as? String, "local")
            XCTAssertEqual(model["cloudApproved"] as? Bool, false)
            XCTAssertNil(model["apiKey"])
        }
    }

    func testEverySavedFieldCountsAsAnUnsavedChange() {
        let saved = cloudPreviewConfiguration()
        var same = saved
        XCTAssertEqual(same, saved)
        same.modelName = saved.modelName
        XCTAssertFalse(same != saved)
        let edits: [(String, (inout Configuration) -> Void)] = [
            ("mcp", { $0.mcp = "http://127.0.0.1:54321/mcp" }), ("account", { $0.account = "other_account" }),
            ("accountLabel", { $0.accountLabel = "其他账号" }), ("contact", { $0.contact = nil }),
            ("mode", { $0.mode = .local }), ("modelURL", { $0.modelURL = "https://example.invalid/other/v1" }),
            ("modelName", { $0.modelName = "other-model" }), ("stylePath", { $0.stylePath = "/fixture/style.md" }),
            ("memoryPath", { $0.memoryPath = "/fixture/memory.md" }),
        ]
        XCTAssertEqual(edits.count, Mirror(reflecting: saved).children.count, "A new setting must be covered by change detection")
        for (name, edit) in edits {
            var changed = saved
            edit(&changed)
            XCTAssertNotEqual(changed, saved, name)
        }
    }

    func testPreviewFaultsKeepSpecificGuidance() {
        let fallback = explanation("unrecognized-code")
        for code in ["preview-local-only", "cloud-not-approved", "missing-key", "keychain-unavailable", "busy", "engine-not-ready"] {
            XCTAssertNotEqual(explanation(code), fallback, code)
        }
    }

    func testMenuPanelKeepsFixedWidthAndCapsHeight() {
        XCTAssertEqual(MenuPanelMetrics.size(contentHeight: 300.2), NSSize(width: 336, height: 301))
        XCTAssertEqual(MenuPanelMetrics.size(contentHeight: 560), NSSize(width: 336, height: 560))
        XCTAssertEqual(MenuPanelMetrics.size(contentHeight: 900), NSSize(width: 336, height: 560))
    }

    private func cloudPreviewConfiguration() -> Configuration {
        Configuration(mcp: "http://127.0.0.1:12345/mcp", account: "mock_account", accountLabel: "模拟账号",
                      contact: ContactOption(id: "wxid_fixture", label: "模拟联系人"), mode: .cloud,
                      modelURL: "https://example.invalid/qa/v1", modelName: "synthetic-model")
    }

    @MainActor private func assertPreviewFault(_ code: String, _ run: () async throws -> PreviewResult,
                                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await run()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BridgeFault, BridgeFault(code), file: file, line: line)
        }
    }

    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        let limit = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= limit { throw BridgeFault("test-timeout") }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

private struct ScopedKeychain: @unchecked Sendable {
    let keychain: SecKeychain
    private let service = "local.wechatmenubridge.selftest.\(UUID().uuidString)"

    @available(macOS, deprecated: 12.0, message: "Temporary classic Keychain for tests only.")
    init(directory: URL) throws {
        let url = directory.appendingPathComponent("fixture.keychain")
        let pass = UUID().uuidString
        var temp: SecKeychain?
        let result = pass.withCString { password in
            url.path.withCString { path in SecKeychainCreate(path, UInt32(pass.utf8.count), password, false, nil, &temp) }
        }
        XCTAssertEqual(result, errSecSuccess)
        keychain = try XCTUnwrap(temp)
    }

    var storage: ModelKeychain {
        ModelKeychain(service: service) { inserting in
            inserting ? [kSecUseKeychain as String: keychain] : [kSecMatchSearchList as String: [keychain]]
        }
    }
}

// 只说 IPC 协议的最小替身：记录收到的帧并返回固定试拟结果，不联网、不依赖打包后的 Engine。
private struct FakeEngine {
    let executable: URL
    private let log: URL

    init(directory: URL) throws {
        executable = directory.appendingPathComponent("fake-engine")
        log = directory.appendingPathComponent("fake-engine-requests.ndjson")
        let script = """
            #!/bin/sh
            printf '{"kind":"hello","v":2}\\n'
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> '\(log.path)'
              id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\\1/')
              printf '{"kind":"reply","id":%s,"ok":true,"result":{"action":"reply","text":"合成试拟"}}\\n' "$id"
            done
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func requests() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}

private func privateTemp() throws -> URL {
    let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WMB_TEST_TEMP"] ?? NSTemporaryDirectory(), isDirectory: true)
    let path = base.appendingPathComponent("wmb-swift-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return path
}

private struct Fixture {
    struct Connection: Decodable { let mcp: String; let model: String; let control: String }
    struct Counts: Decodable { let sends: Int; let models: Int; let waits: Int; let faults: Int }
    let engine: URL
    let info: Connection
    let process: Process
    let input: FileHandle

    static func executable() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["WMB_TEST_ENGINE"] else { throw XCTSkip("run bash scripts/selftest.sh") }
        return URL(fileURLWithPath: path)
    }

    init() throws {
        engine = try Self.executable()
        let env = ProcessInfo.processInfo.environment
        guard let bun = env["WMB_TEST_BUN"], let runner = env["WMB_TEST_FIXTURE"] else { throw XCTSkip("run bash scripts/selftest.sh") }
        let f = Process(), stdin = Pipe(), stdout = Pipe()
        process = f; input = stdin.fileHandleForWriting
        f.executableURL = URL(fileURLWithPath: bun)
        f.arguments = [runner]
        f.standardInput = stdin; f.standardOutput = stdout; f.standardError = FileHandle.nullDevice
        try f.run()
        let fd = stdout.fileHandleForReading.fileDescriptor
        do {
            var data = Data()
            let end = ProcessInfo.processInfo.systemUptime + 4
            while data.count < 4096 {
                let left = end - ProcessInfo.processInfo.systemUptime
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard left > 0, poll(&p, 1, Int32(left * 1000)) > 0,
                      let byte = try stdout.fileHandleForReading.read(upToCount: 1)?.first else { break }
                if byte == 10 { break }
                data.append(byte)
            }
            info = try JSONDecoder().decode(Connection.self, from: data)
            guard Configuration.validURL(info.mcp, kind: "mcp"), Configuration.validURL(info.model, kind: "local"),
                  URL(string: info.control)?.host == "127.0.0.1" else { throw BridgeFault("fixture-config") }
        } catch {
            try? input.close()
            f.terminate()
            throw error
        }
    }

    func close() { try? input.close(); process.waitUntilExit() }

    func counts(_ path: String = "counts") async throws -> Counts {
        let url = try XCTUnwrap(URL(string: info.control + path))
        var request = URLRequest(url: url, timeoutInterval: 2)
        if path != "counts" { request.httpMethod = "POST" }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Counts.self, from: data)
    }
}
