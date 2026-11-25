import CryptoKit
import Darwin
import Foundation
import Security
import XCTest
@testable import WeChatMenu

// 黄金样本逐字对应 Engine/src/contracts/*.ts；testEveryFrameAgainstEngineZodSchemas 用真实 zod schema 复核。
private enum Golden {
    static let capabilities = #"{"accountWideEvents":true,"canSendText":true,"groupMembers":true,"historyQuery":true,"historySearch":false,"listConversations":true,"mentionSend":false,"nativeReply":true,"readMedia":false}"#
    static let session = #"{"cooldownUntil":20,"draft":"草稿","phase":"blocked-unknown","reason":"send-unknown","receipt":{"delivery":"unknown","operationId":"op-1","status":"unknown"},"replyMode":"auto","scheduledAt":10}"#
    static let pluginState = #"{"approvedPermissions":["read_events","call_model"],"circuitOpen":false,"consecutiveFailures":1,"enabled":true,"kind":"module","lastError":"plugin-timeout","lastRunAt":30,"manifestHash":"hash-1"}"#
    static let declarativeState = #"{"approvedPermissions":[],"circuitOpen":false,"consecutiveFailures":0,"enabled":false,"kind":"declarative"}"#
    static let feed = #"{"body":"摘要","conversationId":"g@chatroom","createdAt":40,"id":"feed-1","kind":"plugin_digest","pluginId":"p1","read":false,"refPath":"outputs/a.md","title":"群聊摘要"}"#
    static let proposal = #"{"createdAt":50,"filePath":"memory/proposals/pr-1.json","proposalId":"pr-1","sampleCount":25,"status":"pending","summary":"更简短"}"#
    static let revision = #"{"createdAt":60,"diffPreview":"+ 新条目","revId":"rev-1","scopeKey":"wxid_a","snapshotPath":"memory/history/a.md","source":"proposal_accepted","summary":"整理","targetKind":"scope"}"#
    static let status = #"{"capabilities":\#(capabilities),"globalPhase":"running","pendingProposalCount":2,"plugins":{"p1":\#(pluginState)},"sessions":{"wxid_a":\#(session)},"unreadFeedCount":3}"#
    static let hello = #"{"capabilities":\#(capabilities),"globalPhase":"running","pendingProposalCount":2,"plugins":{"p1":\#(pluginState)},"sessions":{"wxid_a":\#(session)},"unreadFeedCount":3,"v":3}"#
    static let declarative = #"{"description":"群摘要","enabled":true,"builtinTemplate":"group-digest","id":"p2","name":"摘要","processor":{"maxInputChars":24000,"outputFormat":"structured_digest_json","skipWhenNoValue":true,"systemPrompt":"s","userPromptTemplate":"u"},"rateLimit":{"maxRunsPerHour":4,"maxWeChatSendsPerDay":20},"scope":{"conversationIds":["g@chatroom"],"excludeSelf":true,"includeTypes":["group"],"kinds":["text","recall"]},"sinks":[{"id":"s1","notifyDesktop":true,"type":"app_feed"},{"filenameTemplate":"{{date}}.md","id":"s2","mode":"append","type":"markdown_file"},{"approved":false,"id":"s3","targetConversationId":"filehelper","type":"wechat"},{"hasSecret":true,"id":"s4","type":"webhook","url":"https://hooks.example.invalid/x"},{"hasSecret":false,"id":"s5","platform":"feishu","type":"webhook","url":"https://open.feishu.cn/open-apis/bot/v2/hook/x"}],"trigger":{"everyMinutes":60,"minMessages":5,"timesOfDay":["09:30"],"type":"window_time"}}"#
    static let trace = #"{"at":80,"conversationId":"wxid_a","detail":"对方连发 3 条","id":"trace-1","level":"warn","stage":"policy","summary":"跳过本轮"}"#
    static let healthCheck = #"{"ok":false,"steps":[{"detail":"已连接","durationMs":12,"id":"xiaohe","label":"小禾连接","ok":true},{"detail":"在白名单内","durationMs":3,"id":"whitelist","label":"发信白名单","ok":true},{"detail":"已读取","durationMs":5,"id":"credentials","label":"本机凭据读取","ok":true},{"detail":"模型返回格式错误","durationMs":4200,"id":"model","label":"云端模型实测","ok":false}]}"#
    static let manifest = #"{"entry":"index.ts","id":"p1","name":"代码插件","permissions":["read_events","call_model","send_wechat"],"version":"1.0.0"}"#

    static let pushes: [PushTopic: String] = [
        .hello: frame("hello", hello),
        .sessionUpdated: frame("session.updated", #"{"conversationId":"wxid_a","status":\#(session)}"#),
        .globalUpdated: frame("global.updated", #"{"activeAutoCount":1,"activePluginCount":2,"error":"event-gap","inFlightCount":0,"phase":"error"}"#),
        .feedAdded: frame("feed.added", #"{"item":\#(feed),"notifyDesktop":true}"#),
        .pluginUpdated: frame("plugin.updated", #"{"pluginId":"p1","state":\#(pluginState)}"#),
        .proposalUpdated: frame("proposal.updated", #"{"latestProposal":\#(proposal),"pendingCount":1}"#),
        .backfillProgress: frame("backfill.progress", #"{"conversationId":"wxid_a","done":false,"error":"mcp-offline","fetched":7,"jobId":"job-1"}"#),
        .sessionTrace: frame("session.trace", #"{"entry":\#(trace)}"#),
    ]

    static func frame(_ topic: String, _ payload: String) -> String {
        #"{"kind":"event","payload":\#(payload),"topic":"\#(topic)","v":3}"#
    }

    static let webhookTest = #"{"detail":"飞书已接收","ok":true,"statusCode":200}"#

    static let hotBundles = #"{"items":[{"name":"policy.json","sha256":"\#(String(repeating: "a", count: 64))","verified":true}],"lastReloadAt":90,"loadedCount":1,"version":"2026.11.24"}"#

    static let results: [RPCMethod: String] = [
        .systemStatus: status, .systemPauseAll: "true", .systemHealthCheck: healthCheck, .systemBundles: hotBundles,
        .xiaoheAccounts: #"[{"canRead":true,"canSend":true,"id":"acct","label":"账号","sendConversations":["wxid_a"]}]"#,
        .xiaoheConversations: #"{"items":[{"conversationId":"g@chatroom","displayName":"群","isSticky":true,"nickname":"n","remark":"r","type":"group"}],"nextCursor":null,"syncStatus":"ready"}"#,
        .xiaoheGroupMembers: #"[{"displayName":"甲","userId":"u1"}]"#,
        .xiaoheCapabilities: capabilities, .settingsApply: "true",
        .modelPreview: #"{"action":"reply","text":"好的"}"#,
        .sessionArm: "true", .sessionPause: "true", .sessionSendOneShot: "true",
        .sessionRefreshReceipt: #"{"delivery":"delivered","operationId":"op-2","status":"submitted"}"#,
        .sessionRecover: "true", .sessionBackfill: #"{"jobId":"job-1"}"#,
        .sessionTraces: #"{"items":[\#(trace)]}"#, .sessionResumeCooldown: "true",
        .pluginsList: #"[{"config":\#(declarative),"kind":"declarative","pluginId":"p2","state":\#(declarativeState)},{"kind":"module","manifest":\#(manifest),"pluginId":"p1","state":\#(pluginState)}]"#,
        .pluginsSaveDeclarative: "true", .pluginsDeleteDeclarative: "true", .pluginsSetEnabled: "true",
        .pluginsRunNow: #"{"runId":"run-1"}"#, .pluginsTestWebhook: webhookTest,
        .pluginsRuns: #"{"items":[{"errorCode":"plugin-limit","finishedAt":71,"itemCount":3,"outputPaths":["outputs/a.md"],"pluginId":"p1","runId":"run-1","startedAt":70,"status":"error","summaryPreview":"预览","triggerKind":"window_count"}],"nextCursor":"c2"}"#,
        .memoryGet: ##"{"path":"memory/persona.md","text":"# 人格"}"##, .memorySave: revision, .memorySetEntryLock: revision,
        .memorySetEntryVisibility: revision, .memoryConsolidateNow: "null",
        .memoryRevisions: #"{"items":[\#(revision)],"nextCursor":null}"#, .memoryRollback: revision,
        .personaProposals: #"{"items":[\#(proposal)],"nextCursor":null}"#,
        .personaDecide: #"{"createdAt":50,"decidedAt":55,"filePath":"memory/proposals/pr-1.json","proposalId":"pr-1","sampleCount":25,"status":"accepted","summary":"更简短"}"#,
        .feedList: #"{"items":[\#(feed)],"nextCursor":"f2"}"#, .feedMarkRead: "true",
    ]

    static let idleHello = frame("hello", #"{"capabilities":\#(capabilities),"globalPhase":"idle","pendingProposalCount":0,"plugins":{},"sessions":{},"unreadFeedCount":0,"v":3}"#)
}

@MainActor
private final class MockTransport: BridgeTransport {
    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    private(set) var frames: [[String: Any]] = []
    private(set) var rawFrames: [Data] = []
    private(set) var replies: [String] = []
    private(set) var closed = false
    var responder: ((RPCMethod, [String: Any]) -> String?)?

    func send(_ frame: Data) {
        rawFrames.append(frame)
        guard let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let id = value["id"] as? Int, let name = value["method"] as? String,
              let method = RPCMethod(rawValue: name) else { return XCTFail("Malformed outbound frame") }
        frames.append(value)
        guard let result = responder?(method, value["params"] as? [String: Any] ?? [:]) else { return }
        let line = result.hasPrefix("!")
            ? #"{"code":"\#(result.dropFirst())","id":\#(id),"kind":"reply","ok":false,"v":3}"#
            : #"{"id":\#(id),"kind":"reply","ok":true,"result":\#(result),"v":3}"#
        replies.append(line)
        feed(line)
    }

    func close() { closed = true }
    func feed(_ line: String) { onData?(Data((line + "\n").utf8)) }

    func params(of method: RPCMethod) -> [String: Any]? {
        frames.last { $0["method"] as? String == method.rawValue }?["params"] as? [String: Any]
    }

    func count(_ method: RPCMethod) -> Int { frames.filter { $0["method"] as? String == method.rawValue }.count }
}

@MainActor
private final class MockNotifications: NotificationDelivering {
    private(set) var delivered: [FeedNotification] = []
    func deliver(_ notification: FeedNotification) { delivered.append(notification) }
}

private final class TemporaryKeychain: @unchecked Sendable {
    let keychain: SecKeychain

    @available(macOS, deprecated: 12.0, message: "Temporary classic Keychain for tests only.")
    init(directory: URL) throws {
        let path = directory.appendingPathComponent("v2.keychain").path
        let pass = UUID().uuidString
        var created: SecKeychain?
        let status = pass.withCString { password in
            path.withCString { SecKeychainCreate($0, UInt32(pass.utf8.count), password, false, nil, &created) }
        }
        XCTAssertEqual(status, errSecSuccess)
        keychain = try XCTUnwrap(created)
    }

    func scope(_ inserting: Bool) -> [String: Any] {
        inserting ? [kSecUseKeychain as String: keychain] : [kSecMatchSearchList as String: [keychain]]
    }

    var vault: KeychainVault { KeychainVault(scope: { [self] in scope($0) }) }

    @available(macOS, deprecated: 12.0, message: "Temporary classic Keychain for tests only.")
    func destroy() { _ = SecKeychainDelete(keychain) }
}

@MainActor
private func connectedRuntime(hello: String = Golden.idleHello) throws -> (BridgeRuntime, MockTransport) {
    let runtime = BridgeRuntime()
    let transport = MockTransport()
    try runtime.connect(transport)
    transport.feed(hello)
    XCTAssertTrue(runtime.ready)
    return (runtime, transport)
}

private func temporaryDirectory() throws -> URL {
    let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WMB_TEST_TEMP"] ?? NSTemporaryDirectory(), isDirectory: true)
    let path = base.appendingPathComponent("wmb-v2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return path
}

private func writePrivate(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    guard chmod(path, 0o600) == 0 else { throw BridgeFault("storage-unavailable") }
}

private func fileMode(_ path: String) throws -> Int {
    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
}

private func jsonEqual(_ left: Data, _ right: Data) throws -> Bool {
    let a = try JSONSerialization.jsonObject(with: left, options: .fragmentsAllowed)
    let b = try JSONSerialization.jsonObject(with: right, options: .fragmentsAllowed)
    return NSArray(object: a).isEqual(NSArray(object: b))
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

@MainActor
private func assertFault(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                         _ run: () async throws -> Void) async {
    do {
        try await run()
        XCTFail("Expected \(code)", file: file, line: line)
    } catch {
        XCTAssertEqual((error as? BridgeFault)?.code, code, file: file, line: line)
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Condition was not met in time")
}

private let v1Fixture = #"{"mcp":"http://127.0.0.1:21454/mcp","account":"acct","accountLabel":"小禾","contact":{"id":"wxid_a","label":"甲"},"mode":"cloud","modelURL":"https://api.example.invalid/v1/","modelName":" model-1 ","stylePath":"/example/style.md","memoryPath":"","dailyLimit":3,"replyMode":"auto","autoReply":true}"#

final class V2ClientTests: XCTestCase {
    // MARK: IPC 模型

    func testAllPushTopicsRoundTripGoldenFrames() throws {
        XCTAssertEqual(Set(Golden.pushes.keys), Set(PushTopic.allCases))
        XCTAssertEqual(PushTopic.allCases.count, 8)
        for (topic, json) in Golden.pushes {
            let data = Data(json.utf8)
            let event = try IPCv3.decodeStrict(PushEvent.self, from: data)
            XCTAssertEqual(event.topic, topic)
            XCTAssertTrue(try jsonEqual(IPCv3.encoder().encode(event), data), "\(topic) changed in round trip")
        }
    }

    func testAllRPCResultsRoundTripGoldenReplies() throws {
        XCTAssertEqual(RPCMethod.allCases.count, 36)
        XCTAssertEqual(Set(Golden.results.keys), Set(RPCMethod.allCases))
        func check<T: Codable>(_ method: RPCMethod, _ type: T.Type) throws {
            let json = Data(try XCTUnwrap(Golden.results[method]).utf8)
            let value = try IPCv3.decodeStrict(T.self, from: json)
            XCTAssertTrue(try jsonEqual(IPCv3.encoder().encode(value), json), method.rawValue)
        }
        try check(.systemStatus, SystemStatus.self)
        try check(.xiaoheAccounts, [XiaoheAccountOption].self)
        try check(.xiaoheConversations, XiaoheConversationPage.self)
        try check(.xiaoheGroupMembers, [GroupMember].self)
        try check(.modelPreview, ModelPreviewResult.self)
        try check(.sessionRefreshReceipt, SessionReceipt.self)
        try check(.sessionTraces, SessionTraceList.self)
        try check(.sessionResumeCooldown, Bool.self)
        try check(.systemHealthCheck, HealthCheckResult.self)
        try check(.systemBundles, HotBundlesStatus.self)
        try check(.pluginsList, [PluginListItem].self)
        try check(.pluginsRuns, IPCPage<PluginRun>.self)
        try check(.pluginsTestWebhook, WebhookTestResult.self)
        try check(.memoryGet, MemoryContent.self)
        try check(.memorySave, MemoryRevision.self)
        try check(.memoryConsolidateNow, MemoryRevision?.self)
        try check(.memoryRevisions, IPCPage<MemoryRevision>.self)
        try check(.personaProposals, IPCPage<PersonaProposal>.self)
        try check(.personaDecide, PersonaProposal.self)
        try check(.feedList, IPCPage<FeedItem>.self)
    }

    func testStrictDecodingRejectsContractViolations() throws {
        let bad = [
            #"{"kind":"event","topic":"session.updated","v":3,"payload":{"conversationId":"a","status":{"phase":"idle","replyMode":"off","extra":1}}}"#,
            #"{"kind":"event","topic":"session.updated","v":3,"payload":{"conversationId":"a","status":{"phase":"idle","replyMode":"off","draft":null}}}"#,
            #"{"kind":"event","topic":"session.updated","v":3,"payload":{"conversationId":"a","status":{"phase":"blocked_unknown","replyMode":"off"}}}"#,
            #"{"kind":"event","topic":"unknown.topic","v":3,"payload":{}}"#,
            #"{"kind":"event","topic":"hello","v":2,"payload":{}}"#,
        ]
        for json in bad { XCTAssertThrowsError(try IPCv3.decodeStrict(PushEvent.self, from: Data(json.utf8)), json) }
        XCTAssertThrowsError(try IPCv3.decodeStrict(IPCPage<FeedItem>.self, from: Data(#"{"items":[]}"#.utf8)), "nullable 字段不可缺失")
        XCTAssertThrowsError(try IPCv3.decodeStrict(IPCAck.self, from: Data("false".utf8)))
    }

    func testContractDefaultsFillOnlyMissingFields() throws {
        let json = #"{"conversationId":"g@chatroom","label":"群","type":"group","enabled":true,"replyMode":"draft"}"#
        let policy = try IPCv3.decodeStrict(ConversationPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(policy.groupTrigger, .mentionOnly)
        XCTAssertEqual(policy.backfillOnArmCount, 10)
        XCTAssertFalse(policy.memoryEnabled, "群聊记忆默认关闭")
        XCTAssertEqual(policy.riskProfile.takeoverCooldownMinutes, 15)
        XCTAssertNil(policy.riskProfile.selectedLevel, "未写风控字段的旧会话也沿用原有策略")
        let explicitNull = #"{"conversationId":"g","label":"群","type":"group","enabled":true,"replyMode":"off","pluginIds":null}"#
        XCTAssertThrowsError(try IPCv3.decodeStrict(ConversationPolicy.self, from: Data(explicitNull.utf8)))
    }

    func testRiskLevelPreservesLegacyRulesAndRoundTrips() throws {
        XCTAssertEqual(RiskProfile().selectedLevel, .recommended)
        let old = try IPCv3.decodeStrict(RiskProfile.self, from: Data(#"{"strictLegacyRules":false,"busyChatAction":"pause_session"}"#.utf8))
        XCTAssertNil(old.selectedLevel)
        XCTAssertEqual(old.busyChatAction, .pauseSession)
        XCTAssertFalse(String(decoding: try IPCv3.encoder().encode(old), as: UTF8.self).contains(#""level""#))
        var strict = try IPCv3.decodeStrict(RiskProfile.self, from: Data(#"{"strictLegacyRules":true}"#.utf8))
        XCTAssertEqual(strict.selectedLevel, .strict)
        let explicit = try IPCv3.decodeStrict(RiskProfile.self, from: Data(#"{"strictLegacyRules":true,"level":"minimal"}"#.utf8))
        XCTAssertEqual(explicit.selectedLevel, .minimal)
        for level in RiskProfile.Level.allCases {
            strict.selectedLevel = level
            let data = try IPCv3.encoder().encode(strict)
            XCTAssertEqual(try IPCv3.decodeStrict(RiskProfile.self, from: data), strict)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""level":"\#(level.rawValue)""#))
        }
        for invalid in [#"{"level":null}"#, #"{"level":"off"}"#] {
            XCTAssertThrowsError(try IPCv3.decodeStrict(RiskProfile.self, from: Data(invalid.utf8)))
        }
    }

    func testNewSettingsFieldsStayOptionalAndStrict() throws {
        // 既有预设不含新字段：解码为 nil，编码后也不能多出键。
        let legacy = #"{"id":"m","kind":"chat","maxTokens":320,"mode":"local","modelName":"q","name":"本机","temperature":0.35,"url":"http://127.0.0.1:11434/v1/chat/completions"}"#
        let preset = try IPCv3.decodeStrict(ModelPreset.self, from: Data(legacy.utf8))
        XCTAssertNil(preset.reasoningEffort)
        XCTAssertTrue(try jsonEqual(IPCv3.encoder().encode(preset), Data(legacy.utf8)))

        for effort in ReasoningEffort.allCases {
            let json = legacy.replacingOccurrences(of: #""temperature":0.35"#, with: #""reasoningEffort":"\#(effort.rawValue)","temperature":0.35"#)
            let value = try IPCv3.decodeStrict(ModelPreset.self, from: Data(json.utf8))
            XCTAssertEqual(value.reasoningEffort, effort)
            XCTAssertTrue(try jsonEqual(IPCv3.encoder().encode(value), Data(json.utf8)), effort.rawValue)
        }
        XCTAssertEqual(Set(ReasoningEffort.allCases.map(\.rawValue)), ["default", "low", "medium", "high", "max"])
        let unknown = legacy.replacingOccurrences(of: #""temperature":0.35"#, with: #""reasoningEffort":"extreme","temperature":0.35"#)
        XCTAssertThrowsError(try IPCv3.decodeStrict(ModelPreset.self, from: Data(unknown.utf8)))
        let null = legacy.replacingOccurrences(of: #""temperature":0.35"#, with: #""reasoningEffort":null,"temperature":0.35"#)
        XCTAssertThrowsError(try IPCv3.decodeStrict(ModelPreset.self, from: Data(null.utf8)), "optional 字段上的 null 必须拒绝")

        XCTAssertEqual(String(decoding: try IPCv3.encoder().encode(SettingsV2.DefaultModels()), as: UTF8.self), "{}")
        let models = try IPCv3.decodeStrict(SettingsV2.DefaultModels.self, from: Data(#"{"fallbackReplyPresetId":"m2","replyPresetId":"m1"}"#.utf8))
        XCTAssertEqual(models.fallbackReplyPresetId, "m2")
        XCTAssertThrowsError(try IPCv3.decodeStrict(SettingsV2.DefaultModels.self, from: Data(#"{"fallbackReplyPresetId":null}"#.utf8)))

        let risk = try IPCv3.decodeStrict(RiskProfile.self, from: Data(#"{"takeoverAction":"ignore"}"#.utf8))
        XCTAssertEqual(risk.takeoverAction, .ignore)
        XCTAssertTrue(String(decoding: try IPCv3.encoder().encode(risk), as: UTF8.self).contains(#""takeoverAction":"ignore""#))

        var invalid = SettingsV2()
        invalid.defaultModels.fallbackReplyPresetId = ""
        XCTAssertThrowsError(try invalid.validate(), "备用预设 ID 与其他默认项同样校验")
    }

    func testFastReplyModeDefaultsAndRoundTrips() throws {
        // 既有 settings.json 没有这个键，必须读成关闭。
        let legacy = #"{"approvedCloudPresetIds":[],"autoResumeReadOnlyPlugins":false,"maxConcurrentLlmCalls":3,"pinnedConversationIds":[]}"#
        let decoded = try IPCv3.decodeStrict(SettingsV2.Runtime.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.fastReplyMode)
        XCTAssertTrue(String(decoding: try IPCv3.encoder().encode(decoded), as: UTF8.self).contains(#""fastReplyMode":false"#))

        let enabled = #"{"approvedCloudPresetIds":[],"autoResumeReadOnlyPlugins":false,"fastReplyMode":true,"maxConcurrentLlmCalls":3,"pinnedConversationIds":[],"quietHours":{"action":"skip_turn","enabled":false,"end":"08:00","start":"23:00"}}"#
        let value = try IPCv3.decodeStrict(SettingsV2.Runtime.self, from: Data(enabled.utf8))
        XCTAssertTrue(value.fastReplyMode)
        XCTAssertEqual(value.quietHours, SettingsV2.QuietHours())
        XCTAssertTrue(try jsonEqual(IPCv3.encoder().encode(value), Data(enabled.utf8)))
        let null = legacy.replacingOccurrences(of: #""maxConcurrentLlmCalls""#, with: #""fastReplyMode":null,"maxConcurrentLlmCalls""#)
        XCTAssertThrowsError(try IPCv3.decodeStrict(SettingsV2.Runtime.self, from: Data(null.utf8)))
    }

    func testHotBundlesContractIsStrict() throws {
        let minimal = #"{"items":[],"loadedCount":0}"#
        let empty = try IPCv3.decodeStrict(HotBundlesStatus.self, from: Data(minimal.utf8))
        XCTAssertNil(empty.version)
        XCTAssertTrue(try jsonEqual(IPCv3.encoder().encode(empty), Data(minimal.utf8)))
        for bad in [#"{"items":[],"loadedCount":0,"version":null}"#, #"{"extra":1,"items":[],"loadedCount":0}"#, #"{"items":[]}"#] {
            XCTAssertThrowsError(try IPCv3.decodeStrict(HotBundlesStatus.self, from: Data(bad.utf8)), bad)
        }
        XCTAssertEqual(RPCMethod.systemBundles.rawValue, "system.bundles")
    }

    @MainActor
    func testSystemBundlesSendsActionParam() async throws {
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { method, _ in Golden.results[method] }
        let status = try await runtime.client.systemBundles(action: .reload)
        XCTAssertEqual(status.loadedCount, 1)
        XCTAssertEqual(status.items.first?.id, "policy.json")
        let frame = try XCTUnwrap(transport.frames.last)
        XCTAssertEqual(frame["method"] as? String, "system.bundles")
        XCTAssertEqual((frame["params"] as? [String: Any])?["action"] as? String, "reload")
        XCTAssertNil((frame["params"] as? [String: Any])?["manifestUrl"], "未指定清单时省略 manifestUrl")
    }

    @MainActor
    func testSystemBundlesSyncAndResetParams() async throws {
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { method, _ in Golden.results[method] }
        let manifest = "https://github.com/kts-kris/wechat-menu-bridge/releases/latest/download/bundles-manifest.json"
        _ = try await runtime.client.systemBundles(action: .sync, manifestUrl: manifest)
        XCTAssertEqual(transport.params(of: .systemBundles)?["action"] as? String, "sync")
        XCTAssertEqual(transport.params(of: .systemBundles)?["manifestUrl"] as? String, manifest)
        _ = try await runtime.client.systemBundles(action: .reset)
        XCTAssertEqual(transport.params(of: .systemBundles)?.keys.sorted(), ["action"])
        XCTAssertEqual(transport.params(of: .systemBundles)?["action"] as? String, "reset")
        XCTAssertEqual(Set(HotBundlesAction.allCases.map(\.rawValue)), ["status", "reload", "sync", "reset"])
    }

    func testConversationReplyStyleFieldsDefaultAndRoundTrip() throws {
        // v2.1 的 settings.json 没有这两个键：读成 false，编码后补齐默认值（与 zod default 一致）。
        let legacy = #"{"conversationId":"g@chatroom","label":"群","type":"group","enabled":true,"replyMode":"draft"}"#
        let policy = try IPCv3.decodeStrict(ConversationPolicy.self, from: Data(legacy.utf8))
        XCTAssertFalse(policy.useNativeReply)
        XCTAssertFalse(policy.mentionReplySender)
        let encoded = String(decoding: try IPCv3.encoder().encode(policy), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""useNativeReply":false"#))
        XCTAssertTrue(encoded.contains(#""mentionReplySender":false"#))

        let on = legacy.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":true,"mentionReplySender":true,"useNativeReply":true"#)
        let value = try IPCv3.decodeStrict(ConversationPolicy.self, from: Data(on.utf8))
        XCTAssertTrue(value.useNativeReply)
        XCTAssertTrue(value.mentionReplySender)
        XCTAssertEqual(try IPCv3.decodeStrict(ConversationPolicy.self, from: IPCv3.encoder().encode(value)), value)
        for bad in [#""useNativeReply":null"#, #""mentionReplySender":"yes""#] {
            let json = legacy.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":true,\#(bad)"#)
            XCTAssertThrowsError(try IPCv3.decodeStrict(ConversationPolicy.self, from: Data(json.utf8)), bad)
        }
    }

    func testWebhookPlatformAndDailyBriefingContract() throws {
        XCTAssertEqual(Set(PluginSinkConfig.WebhookPlatform.allCases.map(\.rawValue)), ["generic", "feishu", "wecom", "telegram", "notion"])
        XCTAssertEqual(DeclarativePluginConfig.BuiltinTemplate.dailyBriefing.rawValue, "daily-briefing")

        let legacy = #"{"hasSecret":true,"id":"s4","type":"webhook","url":"https://hooks.example.invalid/x"}"#
        let old = try IPCv3.decodeStrict(PluginSinkConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(old, .webhook(id: "s4", url: "https://hooks.example.invalid/x", hasSecret: true))
        XCTAssertTrue(try jsonEqual(IPCv3.encoder().encode(old), Data(legacy.utf8)), "platform 为 nil 时省略")
        for platform in PluginSinkConfig.WebhookPlatform.allCases {
            let json = legacy.replacingOccurrences(of: #""id":"s4""#, with: #""id":"s4","platform":"\#(platform.rawValue)""#)
            let value = try IPCv3.decodeStrict(PluginSinkConfig.self, from: Data(json.utf8))
            XCTAssertEqual(value, .webhook(id: "s4", url: "https://hooks.example.invalid/x", hasSecret: true, platform: platform))
            XCTAssertTrue(try jsonEqual(IPCv3.encoder().encode(value), Data(json.utf8)), platform.rawValue)
        }
        for bad in [#""platform":null"#, #""platform":"slack""#] {
            let json = legacy.replacingOccurrences(of: #""id":"s4""#, with: #""id":"s4",\#(bad)"#)
            XCTAssertThrowsError(try IPCv3.decodeStrict(PluginSinkConfig.self, from: Data(json.utf8)), bad)
        }
        let briefing = Golden.declarative.replacingOccurrences(of: #""builtinTemplate":"group-digest""#, with: #""builtinTemplate":"daily-briefing""#)
        XCTAssertEqual(try IPCv3.decodeStrict(DeclarativePluginConfig.self, from: Data(briefing.utf8)).builtinTemplate, .dailyBriefing)
    }

    func testWebhookTestResultIsStrict() throws {
        let minimal = #"{"detail":"连接超时","ok":false}"#
        let value = try IPCv3.decodeStrict(WebhookTestResult.self, from: Data(minimal.utf8))
        XCTAssertNil(value.statusCode)
        XCTAssertTrue(try jsonEqual(IPCv3.encoder().encode(value), Data(minimal.utf8)))
        for bad in [#"{"detail":"x","ok":true,"statusCode":null}"#, #"{"detail":"x","extra":1,"ok":true}"#, #"{"ok":true}"#] {
            XCTAssertThrowsError(try IPCv3.decodeStrict(WebhookTestResult.self, from: Data(bad.utf8)), bad)
        }
        XCTAssertEqual(RPCMethod.pluginsTestWebhook.rawValue, "plugins.testWebhook")
    }

    @MainActor
    func testPluginsTestWebhookSendsParamsWithoutStoringSecret() async throws {
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { method, _ in Golden.results[method] }
        let result = try await runtime.client.pluginsTestWebhook(.init(pluginId: "p2", sinkId: "s5",
                                                                        url: "https://open.feishu.cn/open-apis/bot/v2/hook/x",
                                                                        platform: .feishu, secret: "sign-secret"))
        XCTAssertEqual(result, WebhookTestResult(ok: true, statusCode: 200, detail: "飞书已接收"))
        let params = try XCTUnwrap(transport.params(of: .pluginsTestWebhook))
        XCTAssertEqual(params["platform"] as? String, "feishu")
        XCTAssertEqual(params["secret"] as? String, "sign-secret")
        _ = try await runtime.client.pluginsTestWebhook(.init(pluginId: "p2", sinkId: "s4", url: "https://hooks.example.invalid/x"))
        XCTAssertEqual(transport.params(of: .pluginsTestWebhook)?.keys.sorted(), ["pluginId", "sinkId", "url"],
                       "通用平台与已存密钥都省略可选字段")
    }

    func testChatPresetCanBackVisionDefaultThroughSettingsContract() throws {
        var value = SettingsV2()
        value.models = [ModelPreset(id: "main", name: "主模型", mode: .local, kind: .chat,
                                    url: "http://127.0.0.1:11434/v1/chat/completions", modelName: "multimodal")]
        value.defaultModels.replyPresetId = "main"
        value.defaultModels.visionPresetId = "main"
        XCTAssertNoThrow(try value.validate())
        let decoded = try IPCv3.decodeStrict(SettingsV2.self, from: IPCv3.encoder().encode(value))
        XCTAssertEqual(decoded.defaultModels.visionPresetId, "main")

        // 跟随主模型时不写入该键，引擎才会回退到 replyPresetId。
        value.defaultModels.visionPresetId = nil
        let following = String(decoding: try IPCv3.encoder().encode(value.defaultModels), as: UTF8.self)
        XCTAssertFalse(following.contains("visionPresetId"))
        XCTAssertTrue(following.contains(#""replyPresetId":"main""#))
    }

    func testTraceEntryRejectsContractViolations() throws {
        let entry = try IPCv3.decodeStrict(SessionTraceEntry.self, from: Data(Golden.trace.utf8))
        XCTAssertEqual(entry.stage, .policy)
        XCTAssertEqual(entry.level, .warn)
        for bad in [Golden.trace.replacingOccurrences(of: #""stage":"policy""#, with: #""stage":"other""#),
                    Golden.trace.replacingOccurrences(of: #""level":"warn""#, with: #""level":"fatal""#),
                    Golden.trace.replacingOccurrences(of: #""detail":"对方连发 3 条""#, with: #""detail":null"#),
                    Golden.trace.replacingOccurrences(of: #""summary""#, with: #""extra":1,"summary""#)] {
            XCTAssertThrowsError(try IPCv3.decodeStrict(SessionTraceEntry.self, from: Data(bad.utf8)), bad)
        }
        XCTAssertThrowsError(try IPCv3.decodeStrict(PushEvent.self, from: Data(Golden.frame("session.trace", Golden.trace).utf8)),
                             "推送载荷必须包在 entry 内")
    }

    func testSlowModelMethodsGetExtendedTimeout() {
        XCTAssertEqual(BridgeClientV3.defaultTimeout(.modelPreview), 95)
        XCTAssertEqual(BridgeClientV3.defaultTimeout(.systemHealthCheck), 95)
        XCTAssertEqual(BridgeClientV3.defaultTimeout(.sessionTraces), 26)
        XCTAssertEqual(BridgeClientV3.defaultTimeout(.sessionPause), 2)
    }

    func testEnumsMatchEngineContractSources() throws {
        let contracts = repositoryRoot.appendingPathComponent("Engine/src/contracts")
        guard FileManager.default.fileExists(atPath: contracts.path) else { throw XCTSkip("Engine contracts unavailable") }
        let ipc = try String(contentsOf: contracts.appendingPathComponent("ipc.ts"), encoding: .utf8)
        let errors = try String(contentsOf: contracts.appendingPathComponent("errors.ts"), encoding: .utf8)
        for method in RPCMethod.allCases { XCTAssertTrue(ipc.contains("'\(method.rawValue)': {"), method.rawValue) }
        for topic in PushTopic.allCases where topic != .hello { XCTAssertTrue(ipc.contains("'\(topic.rawValue)':"), topic.rawValue) }
        let list = try XCTUnwrap(errors.range(of: "ERROR_CODES = [")).upperBound
        let end = try XCTUnwrap(errors[list...].range(of: "] as const")).lowerBound
        let codes = errors[list..<end].split(separator: "'").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        XCTAssertEqual(Set(codes), Set(IPCErrorCode.allCases.map(\.rawValue)))
        XCTAssertEqual(codes.count, IPCErrorCode.allCases.count)
    }

    // 所有 36 个请求、36 个响应、8 种推送与 v1 迁移结果，都交给引擎的真实 zod schema 校验。
    @MainActor
    func testEveryFrameAgainstEngineZodSchemas() async throws {
        let env = ProcessInfo.processInfo.environment
        let bun = env["WMB_TEST_BUN"] ?? NSHomeDirectory() + "/.bun/bin/bun"
        let contracts = repositoryRoot.appendingPathComponent("Engine/src/contracts")
        guard FileManager.default.isExecutableFile(atPath: bun),
              FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent("Engine/node_modules/zod").path) else {
            throw XCTSkip("bun or Engine dependencies unavailable")
        }
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { method, _ in Golden.results[method] }
        let c = runtime.client
        let config = try JSONDecoder().decode(DeclarativePluginConfig.self, from: Data(Golden.declarative.utf8))
        let backfill = BackfillRequest(conversationId: "wxid_a", recentCount: 20, purpose: .memory)
        let previewModel = PreviewModel(mode: .cloud, url: "https://api.example.invalid/v1/chat/completions", name: "m",
                                        stylePath: "", memoryPath: "", cloudApproved: true, apiKey: "fixture-key", reasoningEffort: .low)
        var settings = SettingsV2()
        settings.xiaohe = .init(mcpUrl: "http://127.0.0.1:21454/mcp", accountId: "acct", accountLabel: "小禾")
        settings.models = [ModelPreset(id: "m1", name: "云", mode: .cloud, kind: .stt, url: "https://api.example.invalid/v1", modelName: "w"),
                           ModelPreset(id: "m2", name: "备用", mode: .cloud, kind: .chat, url: "https://api.example.invalid/v1",
                                       modelName: "c", reasoningEffort: .default)]
        settings.defaultModels.fallbackReplyPresetId = "m2"
        var risk = RiskProfile()
        risk.takeoverAction = .ignore
        risk.selectedLevel = .minimal
        settings.conversations["g@chatroom"] = ConversationPolicy(conversationId: "g@chatroom", label: "群", type: .group, riskProfile: risk,
                                                                  useNativeReply: true, mentionReplySender: true)

        _ = try await c.systemStatus()
        _ = try await c.systemHealthCheck(presetId: "m2", conversationId: "wxid_a")
        _ = try await c.systemBundles(action: .status)
        _ = try await c.systemBundles(action: .reload)
        _ = try await c.systemBundles(action: .sync, manifestUrl: "https://github.com/kts-kris/wechat-menu-bridge/releases/latest/download/bundles-manifest.json")
        _ = try await c.systemBundles(action: .reset)
        _ = try await c.sessionTraces(conversationId: "wxid_a", limit: 40)
        _ = try await c.sessionResumeCooldown(conversationId: "wxid_a")
        try await c.systemPauseAll(scope: .sendingOnly, reason: .userPaused)
        _ = try await c.xiaoheAccounts(mcpUrl: "http://127.0.0.1:21454/mcp")
        _ = try await c.xiaoheConversations(.init(accountId: "acct", query: "q", type: .group, cursor: "c", limit: 20))
        _ = try await c.xiaoheGroupMembers(conversationId: "g@chatroom")
        _ = try await c.xiaoheCapabilities()
        try await c.settingsApply(settings)
        _ = try await c.modelPreview(model: previewModel, text: "你好")
        try await c.sessionArm(.init(conversationId: "g@chatroom", replyMode: .auto, cloudApproved: true, groupConfirmed: true, apiKey: "fixture-key"))
        try await c.sessionPause(conversationId: "wxid_a", reason: .userPaused)
        try await c.sessionSendOneShot(.init(conversationId: "wxid_a", text: "你好", request: UUID().uuidString, at: 1000, groupConfirmed: false))
        _ = try await c.sessionRefreshReceipt(conversationId: "wxid_a")
        try await c.sessionRecover(conversationId: "wxid_a", action: .restoreConsent)
        _ = try await c.sessionBackfill(.start(backfill))
        _ = try await c.pluginsList()
        try await c.pluginsSaveDeclarative(config)
        try await c.pluginsDeleteDeclarative(pluginId: "p2")
        try await c.pluginsSetEnabled(.init(pluginId: "p1", enabled: true, approvedPermissions: [.readEvents], manifestHash: "hash-1"))
        _ = try await c.pluginsRunNow(.init(pluginId: "p1", conversationId: "wxid_a", range: TimeRange(startTime: 1, endTime: 2)))
        _ = try await c.pluginsRuns(.init(pluginId: "p1", cursor: "c", limit: 10))
        _ = try await c.pluginsTestWebhook(.init(pluginId: "p2", sinkId: "s5", url: "https://open.feishu.cn/open-apis/bot/v2/hook/x",
                                                 platform: .feishu, secret: "sign secret"))
        _ = try await c.memoryGet(.persona)
        _ = try await c.memorySave(.scope(conversationId: "wxid_a"), content: MemoryContent(text: "内容", path: "memory/a.md"))
        _ = try await c.memorySetEntryLock(.persona, entryId: "e1", locked: true)
        _ = try await c.memorySetEntryVisibility(.persona, entryId: "e1", visibility: .localOnly)
        _ = try await c.memoryConsolidateNow(conversationId: "wxid_a", backfill: backfill)
        _ = try await c.memoryRevisions(.init(target: .persona, cursor: "c", limit: 5))
        _ = try await c.memoryRollback(.persona, revId: "rev-1")
        _ = try await c.personaProposals(.init(limit: 5))
        _ = try await c.personaDecide(.acceptEdited(proposalId: "pr-1", content: MemoryContent(path: "memory/edited.md")))
        _ = try await c.feedList(.init(limit: 5, unreadOnly: true))
        try await c.feedMarkRead(ids: ["feed-1"])
        // 判别联合的其余分支。
        _ = try await c.sessionBackfill(.cancel(jobId: "job-1"))
        _ = try await c.personaDecide(.reject(proposalId: "pr-1"))
        _ = try await c.memoryGet(.scope(conversationId: "wxid_a"))

        XCTAssertEqual(Set(transport.frames.compactMap { $0["method"] as? String }), Set(RPCMethod.allCases.map(\.rawValue)))

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePrivate(v1Fixture, to: root.appendingPathComponent("settings.json").path)
        let migrated = try SettingsV2Disk(directory: root).load()
        let payload: [String: Any] = [
            "requests": transport.rawFrames.compactMap { String(data: $0, encoding: .utf8) },
            "replies": transport.replies,
            "pushes": Array(Golden.pushes.values),
            "methods": RPCMethod.allCases.map(\.rawValue),
            "topics": PushTopic.allCases.map(\.rawValue),
            "errors": IPCErrorCode.allCases.map(\.rawValue),
            "phases": SessionRuntimeState.Phase.allCases.map(\.rawValue),
            "feedKinds": FeedItem.Kind.allCases.map(\.rawValue),
            "permissions": PluginPermission.allCases.map(\.rawValue),
            "v1": v1Fixture,
            "migrated": String(decoding: try IPCv3.encoder().encode(migrated), as: UTF8.self),
        ]
        let input = root.appendingPathComponent("frames.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: input)
        let script = root.appendingPathComponent("check.ts")
        try """
        import { PUSH_TOPICS, RPC_METHODS, feedItemSchema, pushFrameSchema, rpcReplySchema, rpcRequestSchema, sessionRuntimeStateSchema } from '\(contracts.path)/ipc.ts';
        import { ERROR_CODES } from '\(contracts.path)/errors.ts';
        import { pluginPermissionSchema } from '\(contracts.path)/plugins.ts';
        import { migrateSettingsV1ToV2, settingsV2Schema } from '\(contracts.path)/settings.ts';
        const x = JSON.parse(await Bun.file(process.argv[2]).text());
        const failures: string[] = [];
        const same = (name: string, a: readonly string[], b: readonly string[]) => {
          if ([...a].sort().join() !== [...b].sort().join()) failures.push('enum:' + name);
        };
        same('methods', x.methods, RPC_METHODS); same('topics', x.topics, PUSH_TOPICS); same('errors', x.errors, ERROR_CODES);
        same('phases', x.phases, sessionRuntimeStateSchema.shape.phase.options);
        same('feedKinds', x.feedKinds, feedItemSchema.shape.kind.options);
        same('permissions', x.permissions, pluginPermissionSchema.options);
        const methods = new Map<number, string>();
        for (const line of x.requests) {
          const r = rpcRequestSchema.safeParse(JSON.parse(line));
          if (!r.success) failures.push('request:' + JSON.parse(line).method); else methods.set(r.data.id, r.data.method);
        }
        for (const line of x.replies) {
          const value = JSON.parse(line);
          const method = methods.get(value.id) as any;
          if (!rpcReplySchema(method).safeParse(value).success) failures.push('reply:' + method);
        }
        for (const line of x.pushes) if (!pushFrameSchema.safeParse(JSON.parse(line)).success) failures.push('push:' + JSON.parse(line).topic);
        const swift = JSON.parse(x.migrated);
        if (!settingsV2Schema.safeParse(swift).success) failures.push('migrated:schema');
        if (!Bun.deepEquals(swift, migrateSettingsV1ToV2(JSON.parse(x.v1)))) failures.push('migrated:differs');
        console.log(JSON.stringify({ failures, requests: x.requests.length, replies: x.replies.length, pushes: x.pushes.length }));
        """.write(to: script, atomically: true, encoding: .utf8)

        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: bun)
        process.arguments = [script.path, input.path]
        process.currentDirectoryURL = root
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors, as: UTF8.self))
        struct Report: Decodable { let failures: [String]; let requests: Int; let replies: Int; let pushes: Int }
        let report = try JSONDecoder().decode(Report.self, from: output)
        XCTAssertEqual(report.failures, [])
        XCTAssertGreaterThanOrEqual(report.requests, 35)
        XCTAssertEqual(report.pushes, 8)
    }

    // MARK: BridgeClientV3

    @MainActor
    func testFrameBoundaryAcceptsExactly256KiBAndRejectsOneMore() throws {
        let prefix = #"{"kind":"event","payload":{"conversationId":"wxid_a","status":{"draft":""#
        let suffix = #"","phase":"idle","replyMode":"draft"}},"topic":"session.updated","v":3}"#
        let exact = IPCv3.maxFrameBytes - prefix.utf8.count - suffix.utf8.count
        let (runtime, transport) = try connectedRuntime()
        var received = 0
        runtime.client.onEvent = { event in
            if case .sessionUpdated(let update) = event { received = update.status.draft?.utf8.count ?? 0 }
        }
        let frame = prefix + String(repeating: "x", count: exact) + suffix
        XCTAssertEqual(frame.utf8.count, 262_144)
        // 按小块投递，覆盖跨 chunk 组帧。
        let bytes = Data((frame + "\n").utf8)
        for start in stride(from: 0, to: bytes.count, by: 16_384) {
            transport.onData?(bytes.subdata(in: start..<min(start + 16_384, bytes.count)))
        }
        XCTAssertEqual(received, exact)
        XCTAssertTrue(runtime.ready)
        transport.feed(prefix + String(repeating: "x", count: exact + 1) + suffix)
        XCTAssertFalse(runtime.ready)
        XCTAssertEqual(runtime.fault, "engine-protocol")
        XCTAssertTrue(transport.closed)
    }

    @MainActor
    func testUnterminatedOversizedFrameFailsBeforeNewline() throws {
        let (runtime, transport) = try connectedRuntime()
        transport.onData?(Data(repeating: 0x78, count: IPCv3.maxFrameBytes))
        XCTAssertTrue(runtime.ready, "恰好上限且未换行时继续等待")
        transport.onData?(Data([0x78]))
        XCTAssertEqual(runtime.fault, "engine-protocol")
        XCTAssertTrue(transport.closed)
    }

    @MainActor
    func testOversizedRequestIsRejectedWithoutWriting() async throws {
        let (runtime, transport) = try connectedRuntime()
        await assertFault("invalid-configuration") {
            _ = try await runtime.client.memorySave(.persona, content: MemoryContent(text: String(repeating: "x", count: IPCv3.maxFrameBytes)))
        }
        XCTAssertTrue(transport.frames.isEmpty)
        XCTAssertTrue(runtime.ready)
    }

    func testPipeWriterDeliversLargeFramesThroughShortWrites() async throws {
        let pipe = Pipe()
        let writer = try PipeFrameWriter(handle: pipe.fileHandleForWriting) { XCTFail("Writer failed") }
        var expected = Data()
        for marker in [UInt8(0x61), 0x62, 0x63] {
            var frame = Data(repeating: marker, count: IPCv3.maxFrameBytes)
            frame.append(10)
            expected.append(frame)
            writer.send(frame)
        }
        let reader = pipe.fileHandleForReading.fileDescriptor
        let total = expected.count
        // 用 read(2)：FileHandle.read(upToCount:) 会一直等到读满或 EOF。
        let received = await Task.detached { () -> Data in
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 32_768)
            while data.count < total {
                let count = Darwin.read(reader, &chunk, chunk.count)
                guard count > 0 else { break }
                data.append(contentsOf: chunk[0..<count])
                usleep(200)
            }
            return data
        }.value
        writer.close()
        XCTAssertEqual(received, expected)
    }

    @MainActor
    func testPushRoutingUpdatesOnlyTheTargetStore() throws {
        let (runtime, transport) = try connectedRuntime(hello: Golden.pushes[.hello]!)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(runtime: runtime, disk: SettingsV2Disk(directory: root))
        let sessions = SessionsStore(runtime: runtime, settings: settings)
        let plugins = PluginsStore(runtime: runtime)
        let memory = MemoryStore(runtime: runtime, stateDirectory: root)
        let notes = MockNotifications()
        let feed = FeedStore(runtime: runtime, notifications: notes)

        transport.feed(Golden.pushes[.sessionUpdated]!)
        XCTAssertEqual(sessions.sessions["wxid_a"]?.phase, .blockedUnknown)
        XCTAssertTrue(plugins.states.isEmpty && memory.proposals.isEmpty && feed.items.isEmpty)
        transport.feed(Golden.pushes[.pluginUpdated]!)
        XCTAssertEqual(plugins.states["p1"]?.manifestHash, "hash-1")
        transport.feed(Golden.pushes[.proposalUpdated]!)
        XCTAssertEqual(memory.pendingProposalCount, 1)
        XCTAssertEqual(memory.proposals.map(\.proposalId), ["pr-1"])
        transport.feed(Golden.pushes[.backfillProgress]!)
        XCTAssertEqual(sessions.backfills["job-1"]?.error, .mcpOffline)
        transport.feed(Golden.pushes[.globalUpdated]!)
        XCTAssertEqual(runtime.globalPhase, .error)
        XCTAssertEqual(runtime.global?.error, .eventGap)
        transport.feed(Golden.pushes[.feedAdded]!)
        XCTAssertEqual(feed.items.map(\.id), ["feed-1"])
        transport.feed(Golden.pushes[.sessionTrace]!)
        XCTAssertEqual(sessions.traces["wxid_a"]?.map(\.id), ["trace-1"])

        // 断线后不能继续显示会话正在运行。
        runtime.stop()
        XCTAssertTrue(sessions.sessions.isEmpty)
        XCTAssertTrue(sessions.traces.isEmpty)
        XCTAssertTrue(plugins.states.isEmpty)
        XCTAssertNil(runtime.capabilities)
    }

    @MainActor
    func testHandshakeFailsClosed() async throws {
        for line in [#"{"kind":"hello","v":2,"status":{}}"#, Golden.pushes[.sessionUpdated]!,
                     #"{"kind":"reply","id":1,"ok":true,"result":true,"v":3}"#, "not json"] {
            let runtime = BridgeRuntime(), transport = MockTransport()
            try runtime.connect(transport)
            transport.feed(line)
            XCTAssertFalse(runtime.ready, line)
            XCTAssertEqual(runtime.fault, "engine-protocol", line)
            XCTAssertTrue(transport.closed, line)
        }
        let fatal = BridgeRuntime(), fatalTransport = MockTransport()
        try fatal.connect(fatalTransport)
        fatalTransport.feed(#"{"kind":"fatal","code":"storage-in-use"}"#)
        XCTAssertEqual(fatal.fault, "storage-in-use")

        let (framed, framedTransport) = try connectedRuntime()
        framedTransport.feed(#"{"v":3,"kind":"error","code":"invalid-frame"}"#)
        XCTAssertEqual(framed.fault, "invalid-frame")
        XCTAssertFalse(framed.ready, "帧错误后本地状态不可信，必须断开")
        XCTAssertTrue(framedTransport.closed)

        let (again, transport) = try connectedRuntime()
        transport.feed(Golden.idleHello)
        XCTAssertFalse(again.ready, "重复 hello 属于协议错误")

        let slow = BridgeRuntime(client: BridgeClientV3(helloTimeout: 0.02)), slowTransport = MockTransport()
        try slow.connect(slowTransport)
        try await eventually { slow.fault == "engine-timeout" }
        XCTAssertTrue(slowTransport.closed)
    }

    @MainActor
    func testReplyFaultsAndTimeouts() async throws {
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { _, _ in "!busy" }
        await assertFault("busy") { _ = try await runtime.client.systemStatus() }
        XCTAssertTrue(runtime.ready, "业务错误不断开连接")
        transport.responder = { _, _ in #"{"unexpected":true}"# }
        await assertFault("engine-protocol") { _ = try await runtime.client.systemStatus() }
        XCTAssertFalse(runtime.ready)

        let timed = BridgeRuntime(client: BridgeClientV3(replyTimeout: { _ in 0.02 })), silent = MockTransport()
        try timed.connect(silent)
        silent.feed(Golden.idleHello)
        await assertFault("engine-timeout") { _ = try await timed.client.systemStatus() }
        XCTAssertTrue(silent.closed, "超时必须断开管道以撤销授权")
    }

    @MainActor
    func testSystemEventsPauseAllAndUnconfirmedPauseDisconnects() throws {
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { _, _ in "true" }
        for event in [BridgeSystemEvent.willSleep, .didWake, .sessionResigned] { runtime.handle(event) }
        XCTAssertEqual(transport.count(.systemPauseAll), 3)
        XCTAssertEqual(transport.params(of: .systemPauseAll)?["scope"] as? String, "all")
        XCTAssertEqual(transport.params(of: .systemPauseAll)?["reason"] as? String, "system-sleep")
        XCTAssertEqual(runtime.pauseRevision, 3)
        XCTAssertTrue(runtime.ready)
        transport.responder = { _, _ in "!internal-error" }
        runtime.handle(.willSleep)
        XCTAssertTrue(transport.closed, "暂停失败时必须断开管道")
        XCTAssertFalse(runtime.ready)
    }

    // 真实子进程：验证握手、超过管道容量的请求、EOF 退出和崩溃上报。
    @MainActor
    func testProcessTransportLifecycle() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = root.appendingPathComponent("fake-engine")
        let hello = Golden.idleHello.replacingOccurrences(of: "'", with: "")
        try """
        #!/usr/bin/perl
        $| = 1;
        print '\(hello)' . "\\n";
        while (my $line = <STDIN>) {
          exit(7) if $line =~ /session\\.pause/;
          my ($id) = $line =~ /"id":(\\d+)/;
          my $size = length($line);
          print qq({"id":$id,"jobId":0,"kind":"reply","ok":true,"result":{"jobId":"size-$size"},"v":3}\\n) =~ s/"jobId":0,//r;
        }
        open(my $mark, '>', "$ARGV[1]/exited-on-eof"); close($mark);
        """.write(to: engine, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(engine.path, 0o700), 0)

        let runtime = BridgeRuntime()
        try runtime.start(engine: engine, directory: root)
        XCTAssertThrowsError(try runtime.start(engine: engine, directory: root), "同一时间只允许一个后台")
        try await eventually { runtime.ready }
        XCTAssertFalse(runtime.starting)

        // 200 KiB 超过管道缓冲区，旧版单次非阻塞 write 会在这里断开。
        let large = String(repeating: "x", count: 200 * 1024)
        let job = try await runtime.client.sessionBackfill(.cancel(jobId: large))
        XCTAssertTrue(job.jobId.hasPrefix("size-"))
        XCTAssertGreaterThan(Int(job.jobId.dropFirst(5)) ?? 0, 200 * 1024)

        runtime.stop()
        XCTAssertFalse(runtime.ready)
        XCTAssertNil(runtime.fault, "主动停止不算故障")
        let marker = root.appendingPathComponent("exited-on-eof").path
        try await eventually { FileManager.default.fileExists(atPath: marker) }

        try runtime.start(engine: engine, directory: root)
        try await eventually { runtime.ready }
        await assertFault("engine-exited") { try await runtime.client.sessionPause(conversationId: "wxid_a") }
        XCTAssertEqual(runtime.fault, "engine-exited")
        XCTAssertFalse(runtime.ready)
    }

    // MARK: KeychainVault

    @available(macOS, deprecated: 12.0, message: "Uses an isolated classic Keychain.")
    func testKeychainNamespacesAreIsolated() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let isolated = try TemporaryKeychain(directory: dir)
        defer { isolated.destroy() }
        let vault = isolated.vault
        XCTAssertEqual(KeychainNamespace.model.rawValue, "local.wechatmenubridge.model")
        XCTAssertEqual(KeychainNamespace.mcp.rawValue, "local.wechatmenubridge.mcp")
        XCTAssertEqual(KeychainNamespace.webhook.rawValue, "local.wechatmenubridge.webhook")
        XCTAssertEqual(KeychainNamespace.github.rawValue, "local.wechatmenubridge.github")

        let entries = KeychainNamespace.allCases.map { KeychainEntry(namespace: $0, account: "same-account") }
        for entry in entries { try vault.save("secret-\(entry.namespace)", for: entry) }
        for entry in entries { XCTAssertEqual(try vault.read(entry), "secret-\(entry.namespace)") }
        try vault.remove(entries[0])
        XCTAssertThrowsError(try vault.read(entries[0]))
        XCTAssertEqual(try vault.read(entries[1]), "secret-mcp")
        XCTAssertEqual(try vault.read(entries[2]), "secret-webhook")
        XCTAssertEqual(try vault.read(entries[3]), "secret-github")
    }

    @available(macOS, deprecated: 12.0, message: "Uses an isolated classic Keychain.")
    func testVaultReadsLegacyModelKeychainEntries() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let isolated = try TemporaryKeychain(directory: dir)
        defer { isolated.destroy() }
        let legacy = ModelKeychain(scope: { [isolated] in isolated.scope($0) })
        try legacy.save("legacy-key", for: "https://api.example.invalid/v1/")
        let migrated = ModelPreset(id: "preset-legacy-default", name: "m", mode: .cloud, kind: .chat,
                                   url: "https://api.example.invalid/v1/", modelName: "m")
        XCTAssertEqual(migrated.url, "https://api.example.invalid/v1/chat/completions")
        XCTAssertEqual(try isolated.vault.read(.model(endpoint: migrated.url)), "legacy-key")
        try isolated.vault.save("rotated-key", for: .model(endpoint: "https://api.example.invalid/v1"))
        XCTAssertEqual(try legacy.read(migrated.url), "rotated-key")
    }

    func testKeychainEntriesUseSpecifiedAccounts() throws {
        XCTAssertEqual(try KeychainEntry.mcp(url: "http://127.0.0.1:21454/mcp").account, "http://127.0.0.1:21454/mcp")
        XCTAssertEqual(try KeychainEntry.webhook(pluginId: "p1", sinkId: "s1").account, "plugin:p1:sink:s1")
        XCTAssertEqual(try KeychainEntry.model(endpoint: "https://a.invalid/v1", kind: .stt).account,
                       "https://a.invalid/v1/audio/transcriptions")
        XCTAssertThrowsError(try KeychainEntry.mcp(url: "https://example.invalid/mcp"))
        XCTAssertThrowsError(try KeychainEntry.model(endpoint: "http://127.0.0.1:11434/v1"))
        // 两组不同 ID 不能拼出同一账户名。
        XCTAssertThrowsError(try KeychainEntry.webhook(pluginId: "a:sink:b", sinkId: "c"))
        XCTAssertThrowsError(try KeychainEntry.webhook(pluginId: "a", sinkId: "b:sink:c"))
    }

    // MARK: SettingsStore

    @MainActor
    func testV1MigrationIsLosslessAndNeverRestoresAuto() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SettingsV2Disk(directory: root)
        try writePrivate(v1Fixture, to: disk.settingsPath)
        let store = SettingsStore(runtime: BridgeRuntime(), disk: disk)
        try store.load()
        let value = store.saved
        XCTAssertEqual(value.xiaohe.mcpUrl, "http://127.0.0.1:21454/mcp")
        XCTAssertEqual(value.xiaohe.accountId, "acct")
        XCTAssertEqual(value.models.first?.id, "preset-legacy-default")
        XCTAssertEqual(value.models.first?.url, "https://api.example.invalid/v1/chat/completions")
        XCTAssertEqual(value.models.first?.modelName, "model-1")
        XCTAssertEqual(value.defaultModels.replyPresetId, "preset-legacy-default")
        XCTAssertEqual(value.conversations["wxid_a"]?.replyMode, .off)
        XCTAssertEqual(value.conversations["wxid_a"]?.enabled, false)
        XCTAssertEqual(value.memory.legacyStylePath, "/example/style.md")
        XCTAssertFalse(store.hasUnsavedChanges)

        XCTAssertEqual(try String(contentsOfFile: disk.backupPath, encoding: .utf8), v1Fixture, "备份必须保留原始字节")
        XCTAssertEqual(try fileMode(disk.backupPath), 0o600)
        XCTAssertEqual(try fileMode(disk.settingsPath), 0o600)
        let written = try String(contentsOfFile: disk.settingsPath, encoding: .utf8)
        XCTAssertTrue(written.contains(#""schemaVersion":2"#))
        XCTAssertFalse(written.contains("dailyLimit"))
        XCTAssertEqual(try disk.load(), value, "第二次加载不再迁移")
        XCTAssertEqual(try String(contentsOfFile: disk.backupPath, encoding: .utf8), v1Fixture)
    }

    func testMigrationRefusesConflictingBackupAndKeepsOriginal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SettingsV2Disk(directory: root)
        try writePrivate(v1Fixture, to: disk.settingsPath)
        try writePrivate(#"{"mcp":""}"#, to: disk.backupPath)
        XCTAssertThrowsError(try disk.load()) { XCTAssertEqual(($0 as? BridgeFault)?.code, "storage-unavailable") }
        XCTAssertEqual(try String(contentsOfFile: disk.settingsPath, encoding: .utf8), v1Fixture)
    }

    func testPersistedAutoResetsToOffAndUnsafeFilesAreRefused() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SettingsV2Disk(directory: root)
        var value = SettingsV2()
        value.conversations["wxid_a"] = ConversationPolicy(conversationId: "wxid_a", label: "甲", type: .direct, enabled: true, replyMode: .auto)
        try disk.save(value)
        XCTAssertEqual(try disk.load().conversations["wxid_a"]?.replyMode, .off)
        XCTAssertEqual(chmod(disk.settingsPath, 0o644), 0)
        XCTAssertThrowsError(try disk.load())
        XCTAssertEqual(chmod(disk.settingsPath, 0o600), 0)
        try FileManager.default.removeItem(atPath: disk.settingsPath)
        try FileManager.default.createSymbolicLink(atPath: disk.settingsPath, withDestinationPath: disk.backupPath)
        XCTAssertThrowsError(try disk.load())
        XCTAssertThrowsError(try disk.save(value))
    }

    @MainActor
    func testUnreadableSettingsAreNeverOverwritten() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SettingsV2Disk(directory: root)
        let broken = #"{"schemaVersion":2,"unknown":true}"#
        try writePrivate(broken, to: disk.settingsPath)
        let store = SettingsStore(runtime: BridgeRuntime(), disk: disk)
        XCTAssertThrowsError(try store.load())
        store.draft.xiaohe.accountLabel = "changed"
        await assertFault("config-unreadable") { try await store.save() }
        XCTAssertEqual(try String(contentsOfFile: disk.settingsPath, encoding: .utf8), broken)
    }

    @MainActor
    func testDirtyStateSaveAndDiscard() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { _, _ in "true" }
        let disk = SettingsV2Disk(directory: root)
        let store = SettingsStore(runtime: runtime, disk: disk)
        try store.load()
        XCTAssertFalse(store.hasUnsavedChanges)
        store.draft.runtime.maxConcurrentLlmCalls = 5
        XCTAssertTrue(store.hasUnsavedChanges)
        store.discardChanges()
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(store.draft.runtime.maxConcurrentLlmCalls, 3)

        store.upsertPreset(ModelPreset(id: "m1", name: "本机", mode: .local, kind: .chat,
                                       url: "http://127.0.0.1:11434/v1", modelName: "q"))
        store.draft.defaultModels.replyPresetId = "m1"
        XCTAssertTrue(store.hasUnsavedChanges)
        try await store.save()
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(transport.count(.settingsApply), 1)
        XCTAssertEqual(try disk.load(), store.saved)

        store.removePreset(id: "m1")
        XCTAssertNil(store.draft.defaultModels.replyPresetId, "删除预设时清除默认引用")
        store.discardChanges()
        XCTAssertEqual(store.draft.models.count, 1)

        store.upsertPreset(ModelPreset(id: "m2", name: "备用", mode: .local, kind: .chat,
                                       url: "http://127.0.0.1:11434/v1", modelName: "b"))
        store.draft.defaultModels.fallbackReplyPresetId = "m2"
        store.removePreset(id: "m2")
        XCTAssertNil(store.draft.defaultModels.fallbackReplyPresetId, "删除预设时清除备用模型引用")
        XCTAssertEqual(store.draft.defaultModels.replyPresetId, "m1", "不影响主模型")
    }

    @MainActor
    func testApprovedFallbackPresetKeyIsCarriedToEngine() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = KeychainVault(scope: { _ in throw BridgeFault("keychain-unavailable") }, fileDirectory: root)
        let (runtime, transport) = try connectedRuntime()
        var applied: [String: String]?
        transport.responder = { method, params in
            if method == .settingsApply { applied = params["cloudApiKeys"] as? [String: String] }
            return "true"
        }
        let store = SettingsStore(runtime: runtime, disk: SettingsV2Disk(directory: root), vault: vault)
        try store.load()
        let primary = ModelPreset(id: "primary", name: "主", mode: .cloud, kind: .chat, url: "https://a.example.invalid/v1", modelName: "a")
        let backup = ModelPreset(id: "backup", name: "备", mode: .cloud, kind: .chat, url: "https://b.example.invalid/v1", modelName: "b")
        [primary, backup].forEach(store.upsertPreset)
        store.draft.defaultModels.replyPresetId = "primary"
        store.draft.defaultModels.fallbackReplyPresetId = "backup"
        store.draft.runtime.approvedCloudPresetIds = ["primary", "backup"]
        try vault.save("key-a", for: .model(endpoint: primary.url))
        try vault.save("key-b", for: .model(endpoint: backup.url))
        try await store.save()
        XCTAssertEqual(applied, ["primary": "key-a", "backup": "key-b"])
    }

    @MainActor
    func testPreviewPassesPresetReasoningEffort() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { method, _ in Golden.results[method] }
        let store = SettingsStore(runtime: runtime, disk: SettingsV2Disk(directory: root))
        try store.load()
        store.upsertPreset(ModelPreset(id: "low", name: "低", mode: .local, kind: .chat, url: "http://127.0.0.1:11434/v1",
                                       modelName: "q", reasoningEffort: .low))
        store.upsertPreset(ModelPreset(id: "unset", name: "默认", mode: .local, kind: .chat, url: "http://127.0.0.1:11434/v1", modelName: "q"))
        _ = try await store.preview(presetId: "low", text: "你好")
        XCTAssertEqual((transport.params(of: .modelPreview)?["model"] as? [String: Any])?["reasoningEffort"] as? String, "low")
        _ = try await store.preview(presetId: "unset", text: "你好")
        XCTAssertNil((transport.params(of: .modelPreview)?["model"] as? [String: Any])?["reasoningEffort"])
    }

    @MainActor
    func testHealthCheckForwardsScopeAndDecodesSteps() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { method, _ in Golden.results[method] }
        let store = SettingsStore(runtime: runtime, disk: SettingsV2Disk(directory: root))
        let result = try await store.runHealthCheck(presetId: "m1", conversationId: "wxid_a")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.steps.map(\.id), HealthCheckStep.StepID.allCases)
        XCTAssertEqual(result.steps.last?.durationMs, 4200)
        XCTAssertEqual(transport.params(of: .systemHealthCheck)?["presetId"] as? String, "m1")
        XCTAssertEqual(transport.params(of: .systemHealthCheck)?["conversationId"] as? String, "wxid_a")

        _ = try await store.runHealthCheck()
        XCTAssertEqual(transport.params(of: .systemHealthCheck)?.count, 0, "未指定时不传字段")
    }

    @MainActor
    func testEngineRejectionLeavesDiskAndDraftUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, transport) = try connectedRuntime()
        let disk = SettingsV2Disk(directory: root)
        let store = SettingsStore(runtime: runtime, disk: disk)
        try store.load()
        try disk.save(store.saved)
        let before = try String(contentsOfFile: disk.settingsPath, encoding: .utf8)
        transport.responder = { _, _ in "!invalid-configuration" }
        store.draft.xiaohe.accountLabel = "新"
        await assertFault("invalid-configuration") { try await store.save() }
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOfFile: disk.settingsPath, encoding: .utf8), before)
    }

    @MainActor
    func testDiskFailureRollsEngineBack() async throws {
        let root = try temporaryDirectory()
        defer {
            chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { _, _ in "true" }
        let store = SettingsStore(runtime: runtime, disk: SettingsV2Disk(directory: root))
        try store.load()
        store.draft.xiaohe.accountLabel = "新"
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        await assertFault("storage-unavailable") { try await store.save() }
        XCTAssertEqual(transport.count(.settingsApply), 2, "落盘失败后恢复引擎配置")
        let restored = transport.params(of: .settingsApply)?["settings"] as? [String: Any]
        XCTAssertEqual((restored?["xiaohe"] as? [String: Any])?["accountLabel"] as? String, "")
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    @available(macOS, deprecated: 12.0, message: "Uses an isolated classic Keychain.")
    @MainActor
    func testPreviewConsentGatesKeychainAndEngine() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = try TemporaryKeychain(directory: root)
        defer { isolated.destroy() }
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { method, _ in Golden.results[method] }
        let store = SettingsStore(runtime: runtime, disk: SettingsV2Disk(directory: root), vault: isolated.vault)
        try store.load()
        let cloud = ModelPreset(id: "c", name: "云", mode: .cloud, kind: .chat, url: "https://api.example.invalid/v1", modelName: "m")
        let local = ModelPreset(id: "l", name: "本机", mode: .local, kind: .chat, url: "http://127.0.0.1:11434/v1", modelName: "q")
        let speech = ModelPreset(id: "s", name: "转写", mode: .cloud, kind: .stt, url: "https://api.example.invalid/v1", modelName: "w")
        [cloud, local, speech].forEach(store.upsertPreset)

        await assertFault("cloud-not-approved") { _ = try await store.preview(presetId: "c", text: "你好") }
        await assertFault("missing-key") { _ = try await store.preview(presetId: "c", text: "你好", cloudApproved: true) }
        await assertFault("invalid-configuration") { _ = try await store.preview(presetId: "s", text: "你好", cloudApproved: true) }
        XCTAssertEqual(transport.count(.modelPreview), 0)

        try isolated.vault.save("cloud-key", for: .model(endpoint: cloud.url))
        _ = try await store.preview(presetId: "c", text: " 你好 ", cloudApproved: true)
        var model = transport.params(of: .modelPreview)?["model"] as? [String: Any]
        XCTAssertEqual(model?["apiKey"] as? String, "cloud-key")
        XCTAssertEqual(model?["cloudApproved"] as? Bool, true)
        XCTAssertEqual(transport.params(of: .modelPreview)?["text"] as? String, "你好")

        _ = try await store.preview(presetId: "l", text: "你好", cloudApproved: true)
        model = transport.params(of: .modelPreview)?["model"] as? [String: Any]
        XCTAssertNil(model?["apiKey"], "本机试拟绝不携带密钥")
        XCTAssertEqual(model?["cloudApproved"] as? Bool, false)
    }

    // MARK: SessionsStore

    @MainActor
    private func sessionHarness(vault: KeychainVault = KeychainVault(scope: { _ in throw BridgeFault("keychain-unavailable") }),
                                sendConversations: [String]? = ["wxid_a", "wxid_b", "g@chatroom"]) async throws
        -> (BridgeRuntime, MockTransport, SettingsStore, SessionsStore, URL) {
        let root = try temporaryDirectory()
        let (runtime, transport) = try connectedRuntime()
        let settings = SettingsStore(runtime: runtime, disk: SettingsV2Disk(directory: root), vault: vault)
        try settings.load()
        settings.draft.xiaohe = .init(mcpUrl: "http://127.0.0.1:21454/mcp", accountId: "acct", accountLabel: "小禾")
        settings.upsertPreset(ModelPreset(id: "local", name: "本机", mode: .local, kind: .chat, url: "http://127.0.0.1:11434/v1", modelName: "q"))
        settings.upsertPreset(ModelPreset(id: "cloud", name: "云", mode: .cloud, kind: .chat, url: "https://api.example.invalid/v1", modelName: "m"))
        settings.draft.defaultModels.replyPresetId = "local"
        for (id, type) in [("wxid_a", ScopeType.direct), ("wxid_b", .direct), ("wxid_x", .direct), ("g@chatroom", .group), ("gh_news", .service)] {
            settings.draft.conversations[id] = ConversationPolicy(conversationId: id, label: id, type: type, enabled: true)
        }
        transport.responder = { method, _ in
            if method == .xiaoheAccounts {
                let list = try? JSONEncoder().encode([XiaoheAccountOption(id: "acct", label: "账号", canRead: true, canSend: true, sendConversations: sendConversations)])
                return list.flatMap { String(data: $0, encoding: .utf8) }
            }
            return "true"
        }
        try await settings.save()
        let sessions = SessionsStore(runtime: runtime, settings: settings, vault: vault)
        try await sessions.refreshAccount()
        return (runtime, transport, settings, sessions, root)
    }

    private func update(_ id: String, _ phase: SessionRuntimeState.Phase, reason: String? = nil) -> String {
        let extra = reason.map { #","reason":"\#($0)""# } ?? ""
        return Golden.frame("session.updated", #"{"conversationId":"\#(id)","status":{"phase":"\#(phase.rawValue)","replyMode":"off"\#(extra)}}"#)
    }

    @MainActor
    func testSessionFaultsStayIsolated() async throws {
        let (_, transport, _, sessions, root) = try await sessionHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(sessions.blocker(for: "wxid_a", action: .auto))
        XCTAssertNil(sessions.blocker(for: "wxid_b", action: .auto))

        transport.feed(update("wxid_a", .blockedUnknown, reason: "send-unknown"))
        for action in [SessionAction.draft, .auto, .oneShot] {
            XCTAssertEqual(sessions.blocker(for: "wxid_a", action: action), .sendUnknown)
            XCTAssertNil(sessions.blocker(for: "wxid_b", action: action), "A 的 send-unknown 不能阻塞 B")
        }
        transport.feed(update("wxid_b", .lockedOptOut, reason: "peer-stopped"))
        XCTAssertEqual(sessions.blocker(for: "wxid_b", action: .oneShot), .peerStopped)
        XCTAssertEqual(sessions.blocker(for: "wxid_a", action: .auto), .sendUnknown)
        XCTAssertNil(sessions.blocker(for: "g@chatroom", action: .draft))

        await assertFault("send-unknown") { try await sessions.sendOneShot("wxid_a", text: "你好", consent: true) }
        await assertFault("peer-stopped") { try await sessions.arm("wxid_b", mode: .auto, consent: true) }
        XCTAssertEqual(transport.count(.sessionSendOneShot) + transport.count(.sessionArm), 0)
        try await sessions.arm("g@chatroom", mode: .draft, consent: true)
        XCTAssertEqual(transport.count(.sessionArm), 1)
    }

    @MainActor
    func testGroupAndAuthorizationBlockers() async throws {
        let (_, transport, _, sessions, root) = try await sessionHarness(sendConversations: ["wxid_a", "g@chatroom"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(sessions.blocker(for: "g@chatroom", action: .auto), .groupUnconfirmed)
        XCTAssertEqual(sessions.blocker(for: "g@chatroom", action: .oneShot), .groupUnconfirmed)
        XCTAssertNil(sessions.blocker(for: "g@chatroom", action: .draft), "只拟稿不发信")
        XCTAssertNil(sessions.blocker(for: "g@chatroom", action: .auto, groupConfirmed: true))

        XCTAssertEqual(sessions.blocker(for: "wxid_b", action: .auto), .sendNotAuthorized)
        XCTAssertEqual(sessions.blocker(for: "wxid_b", action: .oneShot), .sendNotAuthorized)
        XCTAssertNil(sessions.blocker(for: "wxid_b", action: .draft), "未授权发信时仍可拟稿")
        XCTAssertNil(sessions.blocker(for: "wxid_a", action: .auto))

        for action in [SessionAction.draft, .auto, .oneShot] {
            XCTAssertEqual(sessions.blocker(for: "gh_news", action: action), .serviceUnavailable)
        }
        XCTAssertEqual(sessions.blocker(for: "wxid_unknown", action: .auto), .notManaged)

        await assertFault("invalid-configuration") { try await sessions.arm("g@chatroom", mode: .auto, consent: true) }
        await assertFault("send-not-authorized") { try await sessions.arm("wxid_b", mode: .auto, consent: true) }
        XCTAssertEqual(transport.count(.sessionArm), 0)
        try await sessions.arm("g@chatroom", mode: .auto, consent: true, groupConfirmed: true)
        XCTAssertEqual(transport.params(of: .sessionArm)?["groupConfirmed"] as? Bool, true)
        XCTAssertEqual(transport.params(of: .sessionArm)?["consent"] as? Bool, true)
        XCTAssertNil(transport.params(of: .sessionArm)?["apiKey"], "本机模型绝不携带密钥")
        XCTAssertNil(transport.params(of: .sessionArm)?["cloudApproved"])
    }

    @MainActor
    func testUnsavedSettingsAndOneShotConcurrencyRules() async throws {
        let (_, transport, settings, sessions, root) = try await sessionHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        sessions.updatePolicy("wxid_a") { $0.groupTrigger = .all }
        XCTAssertEqual(sessions.blocker(for: "wxid_b", action: .auto), .unsavedSettings)
        settings.discardChanges()
        XCTAssertNil(sessions.blocker(for: "wxid_b", action: .auto))

        // 单次发送不与本会话的监听互斥，只与正在提交或已排定的发信互斥。
        transport.feed(update("wxid_a", .listening))
        XCTAssertEqual(sessions.blocker(for: "wxid_a", action: .auto), .running)
        XCTAssertNil(sessions.blocker(for: "wxid_a", action: .oneShot))
        transport.feed(update("wxid_a", .scheduled))
        XCTAssertEqual(sessions.blocker(for: "wxid_a", action: .oneShot), .oneShotPending)
        transport.feed(update("wxid_a", .sending))
        XCTAssertEqual(sessions.blocker(for: "wxid_a", action: .oneShot), .inFlight)
        XCTAssertNil(sessions.blocker(for: "wxid_b", action: .oneShot))

        transport.feed(update("wxid_b", .paused, reason: "event-gap"))
        XCTAssertEqual(sessions.blocker(for: "wxid_b", action: .auto), .read("event-gap"))
        XCTAssertNil(sessions.blocker(for: "wxid_b", action: .oneShot), "手写单条不依赖读游标")

        try await sessions.sendOneShot("wxid_b", text: " 你好 ", at: Date(timeIntervalSince1970: 100), consent: true)
        let params = try XCTUnwrap(transport.params(of: .sessionSendOneShot))
        XCTAssertEqual(params["text"] as? String, "你好")
        XCTAssertEqual(params["at"] as? Int, 100_000)
        XCTAssertNotNil(UUID(uuidString: params["request"] as? String ?? ""))
        await assertFault("invalid-configuration") { try await sessions.sendOneShot("wxid_b", text: "a\u{7}b", consent: true) }
        await assertFault("invalid-configuration") { try await sessions.sendOneShot("wxid_b", text: "你好", consent: false) }
    }

    @available(macOS, deprecated: 12.0, message: "Uses an isolated classic Keychain.")
    @MainActor
    func testCloudArmReadsKeyOnlyAfterApprovalAndSleepRevokesIt() async throws {
        let keys = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: keys) }
        let isolated = try TemporaryKeychain(directory: keys)
        defer { isolated.destroy() }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let gate = GateFlag()
        let vault = KeychainVault(scope: { [isolated] inserting in
            if gate.enabled {
                entered.signal()
                release.wait()
            }
            return isolated.scope(inserting)
        })
        let (runtime, transport, settings, sessions, root) = try await sessionHarness(vault: vault)
        defer { try? FileManager.default.removeItem(at: root) }
        try vault.save("cloud-key", for: .model(endpoint: "https://api.example.invalid/v1"))
        sessions.updatePolicy("wxid_a") { $0.replyPresetId = "cloud" }
        try await settings.save()

        await assertFault("cloud-not-approved") { try await sessions.arm("wxid_a", mode: .auto, consent: true) }
        XCTAssertFalse(sessions.authorizing.contains("wxid_a"))

        gate.enabled = true
        let pending = Task { try await sessions.arm("wxid_a", mode: .auto, consent: true, cloudApproved: true) }
        try await eventually { entered.wait(timeout: .now()) == .success }
        XCTAssertEqual(sessions.blocker(for: "wxid_a", action: .auto), .authorizing)
        XCTAssertNil(sessions.blocker(for: "wxid_b", action: .auto), "授权中的会话不影响其他会话")
        runtime.handle(.willSleep)
        release.signal()
        await assertFault("stopped") { try await pending.value }
        XCTAssertEqual(transport.count(.sessionArm), 0, "休眠后不得继续授权")
        XCTAssertFalse(sessions.authorizing.contains("wxid_a"))

        gate.enabled = false
        try await sessions.arm("wxid_a", mode: .auto, consent: true, cloudApproved: true)
        XCTAssertEqual(transport.params(of: .sessionArm)?["apiKey"] as? String, "cloud-key")
        XCTAssertEqual(transport.params(of: .sessionArm)?["cloudApproved"] as? Bool, true)
    }

    @MainActor
    func testAccountSwitchDropsPreviousSendPermission() async throws {
        let (_, _, settings, sessions, root) = try await sessionHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(sessions.blocker(for: "wxid_a", action: .oneShot))
        settings.draft.xiaohe.accountId = "other-account"
        try await settings.save()
        XCTAssertEqual(sessions.blocker(for: "wxid_a", action: .oneShot), .accountUnverified)
    }

    @available(macOS, deprecated: 12.0, message: "Uses an isolated classic Keychain.")
    @MainActor
    func testPeerStopDuringKeychainWaitCancelsArm() async throws {
        let keys = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: keys) }
        let isolated = try TemporaryKeychain(directory: keys)
        defer { isolated.destroy() }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let gate = GateFlag()
        let vault = KeychainVault(scope: { [isolated] inserting in
            if gate.enabled {
                entered.signal()
                release.wait()
            }
            return isolated.scope(inserting)
        })
        let (_, transport, settings, sessions, root) = try await sessionHarness(vault: vault)
        defer { try? FileManager.default.removeItem(at: root) }
        try vault.save("cloud-key", for: .model(endpoint: "https://api.example.invalid/v1"))
        sessions.updatePolicy("wxid_a") { $0.replyPresetId = "cloud" }
        try await settings.save()
        gate.enabled = true
        let pending = Task { try await sessions.arm("wxid_a", mode: .auto, consent: true, cloudApproved: true) }
        try await eventually { entered.wait(timeout: .now()) == .success }
        transport.feed(update("wxid_a", .lockedOptOut, reason: "peer-stopped"))
        release.signal()
        await assertFault("peer-stopped") { try await pending.value }
        XCTAssertEqual(transport.count(.sessionArm), 0)
    }

    @MainActor
    func testSessionRecoveryReceiptAndBackfill() async throws {
        let (_, transport, _, sessions, root) = try await sessionHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        transport.feed(update("wxid_a", .blockedUnknown, reason: "send-unknown"))
        transport.responder = { method, _ in Golden.results[method] }
        try await sessions.refreshReceipt("wxid_a")
        XCTAssertEqual(sessions.sessions["wxid_a"]?.receipt?.delivery, .delivered)
        try await sessions.recover("wxid_a", action: .acknowledge)
        XCTAssertEqual(transport.params(of: .sessionRecover)?["action"] as? String, "acknowledge")
        XCTAssertEqual(transport.params(of: .sessionRecover)?["confirmed"] as? Bool, true)
        try await sessions.pause("wxid_a")
        XCTAssertEqual(transport.params(of: .sessionPause)?["reason"] as? String, "user-paused")

        await assertFault("invalid-configuration") {
            try await sessions.startBackfill(BackfillRequest(conversationId: "wxid_a", recentCount: 5, startTime: 1, endTime: 2, purpose: .plugin))
        }
        transport.feed(Golden.frame("backfill.progress", #"{"conversationId":"wxid_a","done":false,"fetched":9,"jobId":"job-1"}"#))
        let job = try await sessions.startBackfill(BackfillRequest(conversationId: "wxid_a", recentCount: 20, purpose: .plugin))
        XCTAssertEqual(sessions.backfills[job]?.fetched, 9, "响应不得覆盖先到的进度")
        try await sessions.cancelBackfill(jobId: job)
        XCTAssertEqual(transport.params(of: .sessionBackfill)?["action"] as? String, "cancel")
    }

    private func traceFrame(_ id: String, at: Int64, conversation: String = "wxid_a") -> String {
        Golden.frame("session.trace", #"{"entry":{"at":\#(at),"conversationId":"\#(conversation)","id":"\#(id)","level":"info","stage":"inbound","summary":"收到来信"}}"#)
    }

    @MainActor
    func testTracePushesDedupeKeepNewestFirstAndCapAt40() async throws {
        let (_, transport, _, sessions, root) = try await sessionHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...45 { transport.feed(traceFrame("t\(index)", at: Int64(index))) }
        transport.feed(traceFrame("t45", at: 45))
        transport.feed(traceFrame("other", at: 99, conversation: "wxid_b"))
        let rows = try XCTUnwrap(sessions.traces["wxid_a"])
        XCTAssertEqual(rows.count, SessionsStore.maxTraces)
        XCTAssertEqual(rows.first?.id, "t45")
        XCTAssertEqual(rows.last?.id, "t6")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "重复推送不重复入列")
        XCTAssertEqual(sessions.traces["wxid_b"]?.map(\.id), ["other"], "轨迹按会话隔离")
    }

    @MainActor
    func testLoadTracesMergesWithEntriesPushedEarlier() async throws {
        let (_, transport, _, sessions, root) = try await sessionHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        transport.feed(traceFrame("pushed", at: 200))
        transport.responder = { method, _ in
            guard method == .sessionTraces else { return "true" }
            return #"{"items":[{"at":100,"conversationId":"wxid_a","id":"old","level":"error","stage":"send","summary":"提交失败"},{"at":200,"conversationId":"wxid_a","id":"pushed","level":"info","stage":"inbound","summary":"收到来信"},{"at":150,"conversationId":"wxid_b","id":"foreign","level":"info","stage":"state","summary":"不属于此会话"}]}"#
        }
        try await sessions.loadTraces(for: "wxid_a")
        XCTAssertEqual(sessions.traces["wxid_a"]?.map(\.id), ["pushed", "old"])
        XCTAssertEqual(transport.params(of: .sessionTraces)?["conversationId"] as? String, "wxid_a")
        XCTAssertEqual(transport.params(of: .sessionTraces)?["limit"] as? Int, 40)
    }

    @MainActor
    func testResumeCooldownTargetsOnlyThatSession() async throws {
        let (_, transport, _, sessions, root) = try await sessionHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        transport.feed(update("wxid_a", .cooldown))
        let resumed = try await sessions.resumeCooldown("wxid_a")
        XCTAssertTrue(resumed)
        XCTAssertEqual(transport.count(.sessionResumeCooldown), 1)
        XCTAssertEqual(transport.params(of: .sessionResumeCooldown)?["conversationId"] as? String, "wxid_a")
        transport.responder = { _, _ in "!invalid-command" }
        await assertFault("invalid-command") { try await sessions.resumeCooldown("wxid_b") }
    }

    // MARK: PluginsStore / MemoryStore

    @MainActor
    func testPluginApprovalBindsReviewedManifest() async throws {
        let (runtime, transport) = try connectedRuntime()
        var list = Golden.results[.pluginsList]!
        transport.responder = { method, _ in method == .pluginsList ? list : Golden.results[method] }
        let plugins = PluginsStore(runtime: runtime)
        try await plugins.refresh()
        XCTAssertEqual(plugins.plugins.count, 2)

        await assertFault("plugin-permission") {
            try await plugins.approve(pluginId: "p1", permissions: [.readEvents], reviewedManifestHash: "stale")
        }
        await assertFault("plugin-permission") {
            try await plugins.approve(pluginId: "p1", permissions: [.webhookFetch], reviewedManifestHash: "hash-1")
        }
        XCTAssertEqual(transport.count(.pluginsSetEnabled), 0)
        try await plugins.approve(pluginId: "p1", permissions: [.readEvents, .sendWechat], reviewedManifestHash: "hash-1")
        let params = try XCTUnwrap(transport.params(of: .pluginsSetEnabled))
        XCTAssertEqual(params["manifestHash"] as? String, "hash-1")
        XCTAssertEqual(params["approvedPermissions"] as? [String], ["read_events", "send_wechat"])

        list = list.replacingOccurrences(of: #""approvedPermissions":["read_events","call_model"]"#, with: #""approvedPermissions":[]"#)
        try await plugins.refresh()
        await assertFault("plugin-permission") { try await plugins.setEnabled(pluginId: "p1", enabled: true) }
        try await plugins.setEnabled(pluginId: "p1", enabled: false)

        try await plugins.loadRuns(pluginId: "p1")
        XCTAssertEqual(plugins.runs["p1"]?.first?.triggerKind, .windowCount)
        XCTAssertEqual(plugins.runCursors["p1"], "c2")
    }

    @available(macOS, deprecated: 12.0, message: "Uses an isolated classic Keychain.")
    @MainActor
    func testDeletingPluginRemovesItsWebhookSecret() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let isolated = try TemporaryKeychain(directory: dir)
        defer { isolated.destroy() }
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { method, _ in method == .pluginsList ? Golden.results[.pluginsList] : "true" }
        let plugins = PluginsStore(runtime: runtime, vault: isolated.vault)
        try await plugins.refresh()
        try plugins.saveWebhookSecret("Bearer token", pluginId: "p2", sinkId: "s4")
        try plugins.saveWebhookSecret("other", pluginId: "p1", sinkId: "s4")
        try await plugins.deleteDeclarative(pluginId: "p2")
        XCTAssertThrowsError(try isolated.vault.read(.webhook(pluginId: "p2", sinkId: "s4")))
        XCTAssertEqual(try isolated.vault.read(.webhook(pluginId: "p1", sinkId: "s4")), "other")
        XCTAssertNil(plugins.states["p2"])
    }

    @MainActor
    func testMemoryStoreEditsRollsBackAndDecidesProposals() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, transport) = try connectedRuntime()
        transport.responder = { method, _ in Golden.results[method] }
        let memory = MemoryStore(runtime: runtime, stateDirectory: root)
        let target = MemoryTarget.scope(conversationId: "wxid_a")

        try await memory.load(target)
        XCTAssertEqual(memory.documents[target]?.text, "# 人格")
        try await memory.setEntryLock(target, entryId: "e1", locked: true)
        try await memory.setEntryVisibility(target, entryId: "e1", visibility: .cloudSafe)
        XCTAssertEqual(transport.params(of: .memorySetEntryVisibility)?["visibility"] as? String, "cloud-safe")
        try await memory.rollback(target, revId: "rev-1")
        XCTAssertEqual(memory.revisions[target]?.map(\.revId), ["rev-1"])
        let result = try await memory.consolidateNow(conversationId: "wxid_a")
        XCTAssertNil(result, "无可整理内容时返回 null")
        await assertFault("invalid-configuration") {
            try await memory.save(target, text: String(repeating: "字", count: IPCv3.maxInlineDocumentBytes))
        }

        try await memory.loadProposals()
        XCTAssertEqual(memory.proposals.first?.status, .pending)
        try await memory.decide(.accept(proposalId: "pr-1"))
        XCTAssertEqual(transport.params(of: .personaDecide)?["decision"] as? String, "accept")
        XCTAssertEqual(memory.proposals.first?.status, .accepted)
        XCTAssertNotNil(memory.documents[.persona], "采纳后刷新人格内容")
    }

    @MainActor
    func testProposalDocumentStaysInsideProposalDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, _) = try connectedRuntime()
        let memory = MemoryStore(runtime: runtime, stateDirectory: root)
        let directory = root.appendingPathComponent("memory/proposals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writePrivate(#"{"diff":"+x"}"#, to: directory.appendingPathComponent("a.json").path)
        try writePrivate("secret", to: root.appendingPathComponent("secret.json").path)
        func proposal(_ path: String) -> PersonaProposal {
            PersonaProposal(proposalId: "a", status: .pending, filePath: path, sampleCount: 1, summary: "", createdAt: 1)
        }
        XCTAssertEqual(try memory.proposalDocument(proposal("a.json")), #"{"diff":"+x"}"#)
        XCTAssertEqual(try memory.proposalDocument(proposal(directory.appendingPathComponent("a.json").path)), #"{"diff":"+x"}"#)
        XCTAssertThrowsError(try memory.proposalDocument(proposal("../../secret.json")))
        XCTAssertThrowsError(try memory.proposalDocument(proposal(root.appendingPathComponent("secret.json").path)))
    }

    // MARK: FeedStore

    @MainActor
    func testFeedNotifiesThroughInjectedDeliveryAndCountsUnread() async throws {
        let (runtime, transport) = try connectedRuntime(hello: Golden.pushes[.hello]!)
        let notes = MockNotifications()
        let feed = FeedStore(runtime: runtime, notifications: notes)
        transport.feed(Golden.idleHello.replacingOccurrences(of: #""unreadFeedCount":0"#, with: #""unreadFeedCount":0"#))
        XCTAssertEqual(feed.unreadCount, 0, "重复 hello 已断开，未读保持初值")

        let (live, liveTransport) = try connectedRuntime(hello: Golden.idleHello)
        let liveNotes = MockNotifications()
        let liveFeed = FeedStore(runtime: live, notifications: liveNotes)
        liveTransport.feed(Golden.pushes[.feedAdded]!)
        XCTAssertEqual(liveFeed.unreadCount, 1)
        XCTAssertEqual(liveNotes.delivered.map(\.id), ["feed-1"])
        XCTAssertEqual(liveNotes.delivered.first?.title, "群聊摘要")
        XCTAssertEqual(liveNotes.delivered.first?.conversationId, "g@chatroom")

        liveTransport.feed(Golden.pushes[.feedAdded]!)
        XCTAssertEqual(liveFeed.unreadCount, 1, "重复推送不重复计数")
        XCTAssertEqual(liveNotes.delivered.count, 1, "重复推送不重复弹窗")

        let silent = Golden.frame("feed.added", #"{"item":\#(Golden.feed.replacingOccurrences(of: "feed-1", with: "feed-2")),"notifyDesktop":false}"#)
        liveTransport.feed(silent)
        XCTAssertEqual(liveFeed.unreadCount, 2)
        XCTAssertEqual(liveNotes.delivered.count, 1)
        XCTAssertEqual(liveFeed.items.map(\.id), ["feed-2", "feed-1"])

        liveTransport.responder = { _, _ in "true" }
        try await liveFeed.markRead(ids: ["feed-1", "feed-2"])
        XCTAssertEqual(liveFeed.unreadCount, 0)
        XCTAssertTrue(liveFeed.items.allSatisfy(\.read))
    }

    @MainActor
    func testFeedMarkReadUsesEngineCountForUnloadedItems() async throws {
        let (runtime, transport) = try connectedRuntime(hello: Golden.pushes[.hello]!)
        let feed = FeedStore(runtime: runtime, notifications: MockNotifications())
        feed.apply(.hello(HelloPayload(status: try JSONDecoder().decode(SystemStatus.self, from: Data(Golden.status.utf8)))))
        XCTAssertEqual(feed.unreadCount, 3)
        transport.responder = { method, _ in
            method == .systemStatus ? Golden.status.replacingOccurrences(of: #""unreadFeedCount":3"#, with: #""unreadFeedCount":2"#) : "true"
        }
        try await feed.markRead(ids: ["not-loaded"])
        XCTAssertEqual(feed.unreadCount, 2)
    }

    @MainActor
    func testNotificationCenterIsOnlyUsedInsideRealAppBundle() {
        XCTAssertFalse(FeedNotifications.canUseSystemCenter(bundleURL: URL(fileURLWithPath: "/usr/bin"), nativeQA: false))
        XCTAssertFalse(FeedNotifications.canUseSystemCenter(bundleURL: URL(fileURLWithPath: "/tmp/x.xctest"), nativeQA: false))
        XCTAssertFalse(FeedNotifications.canUseSystemCenter(bundleURL: URL(fileURLWithPath: "/Applications/A.app"), nativeQA: true))
        XCTAssertTrue(FeedNotifications.canUseSystemCenter(bundleURL: URL(fileURLWithPath: "/Applications/A.app"), nativeQA: false))
        // 当前 XCTest 进程没有 .app 包，默认实现必须降级，否则会触发系统断言崩溃。
        XCTAssertTrue(FeedNotifications.makeDefault() is NullNotificationDelivery)
    }

    @available(macOS, deprecated: 12.0, message: "Uses an isolated classic Keychain.")
    @MainActor
    func testUnifiedCloudApprovalCarriesKeyInMemoryAndRevokesOnEndpointChange() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = try TemporaryKeychain(directory: root)
        defer { isolated.destroy() }
        let vault = isolated.vault
        let (runtime, transport) = try connectedRuntime(hello: Golden.pushes[.hello]!)
        let disk = SettingsV2Disk(directory: root)
        let settings = SettingsStore(runtime: runtime, disk: disk, vault: vault)
        try settings.load()

        let endpoint = "https://cloud.example.invalid/v1/chat/completions"
        let preset = ModelPreset(id: "cloud-1", name: "云模型", mode: .cloud, kind: .chat, url: endpoint, modelName: "gpt-test")
        settings.upsertPreset(preset)
        settings.draft.runtime.approvedCloudPresetIds = ["cloud-1"]

        // 未存钥匙串密钥前拒绝保存授权。
        do {
            try await settings.save()
            XCTFail("Expected missing-key")
        } catch let fault as BridgeFault {
            XCTAssertEqual(fault.code, "missing-key")
        }

        try vault.save("secret-cloud-token", for: try KeychainEntry.model(endpoint: endpoint, kind: .chat))
        var appliedKeys: [String: String]?
        transport.responder = { method, params in
            if method == .settingsApply { appliedKeys = params["cloudApiKeys"] as? [String: String] }
            return "true"
        }
        try await settings.save()
        XCTAssertEqual(appliedKeys?["cloud-1"], "secret-cloud-token")
        let diskJSON = try String(contentsOfFile: disk.settingsPath, encoding: .utf8)
        XCTAssertFalse(diskJSON.contains("secret-cloud-token"), "API key must never be persisted to settings.json")

        // 修改云端地址必须自动撤销统一授权。
        var changed = preset
        changed.url = "https://other.example.invalid/v1/chat/completions"
        settings.upsertPreset(changed)
        XCTAssertTrue(settings.draft.runtime.approvedCloudPresetIds.isEmpty)
    }

    func testKeychainVaultFileModeStoresPrivateSecretsWithoutTouchingKeychain() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let touched = GateFlag()
        let vault = KeychainVault(scope: { _ in
            touched.enabled = true
            return [:]
        }, fileDirectory: root)
        let entry = try KeychainEntry.model(endpoint: "https://cloud.example.invalid/v1/chat/completions", kind: .chat)

        try vault.save("sk-file-secret-123", for: entry)
        XCTAssertEqual(try vault.read(entry), "sk-file-secret-123")
        XCTAssertFalse(touched.enabled, "File-backed vault must not query macOS Keychain when key is present in secrets.json")

        let secretsURL = root.appendingPathComponent("secrets.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: secretsURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        try vault.remove(entry)
        let remaining = try String(contentsOf: secretsURL, encoding: .utf8)
        XCTAssertFalse(remaining.contains("sk-file-secret-123"))
    }
}

private final class GateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var enabled: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

// MARK: - 在线更新

final class UpdateURLProtocol: URLProtocol {
    struct Route { var status = 200; var body = Data(); var redirect: String? = nil }
    private static let lock = NSLock()
    private static var routes: [String: Route] = [:]

    static func set(_ url: String, _ route: Route) { lock.withLock { routes[url] = route } }
    static func reset() { lock.withLock { routes = [:] } }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let route = Self.lock.withLock({ Self.routes[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        if let redirect = route.redirect, let target = URL(string: redirect) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(route.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private enum UpdateFixture {
    static let identifier = "local.wechatmenubridge"
    static let stays = "#include <unistd.h>\nint main(void) { sleep(25); return 0; }\n"
    static let crashes = "int main(void) { return 1; }\n"

    @discardableResult
    static func tool(_ path: String, _ arguments: [String], input: String? = nil) throws -> Int32 {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = input == nil ? FileHandle.nullDevice : pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let input {
            pipe.fileHandleForWriting.write(Data(input.utf8))
            pipe.fileHandleForWriting.closeFile()
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func makeApp(at app: URL, short: String, build: String, identifier: String = identifier,
                        source: String = stays) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "app", "CFBundlePackageType": "APPL",
                                   "CFBundleShortVersionString": short, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let status = try tool("/usr/bin/clang", ["-x", "c", "-o", macOS.appendingPathComponent("app").path, "-"], input: source)
        XCTAssertEqual(status, 0, "clang")
        XCTAssertEqual(try tool("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path]), 0, "codesign")
    }

    static func zip(_ app: URL, to archive: URL) throws -> Data {
        XCTAssertEqual(try tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path]), 0, "ditto")
        return try Data(contentsOf: archive)
    }
}

@MainActor
final class AppUpdaterTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var spawned: [URL] = []

    private let feed = "https://updates.example.invalid/appcast.xml"
    private let package = "https://updates.example.invalid/WeChatMenuBridge-2.1.0.zip"

    override func setUp() async throws {
        directory = try temporaryDirectory().resolvingSymlinksInPath()
        suite = "wmb.updater.\(UUID().uuidString)"
        UpdateURLProtocol.reset()
    }

    override func tearDown() async throws {
        for file in spawned {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                for pid in text.split(separator: "\n").compactMap({ Int32($0) }) { kill(pid, SIGKILL) }
            }
        }
        UpdateURLProtocol.reset()
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private static let sparkleXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>微信桥</title>
        <item>
          <title>版本 2.1.0</title>
          <description><![CDATA[<ul><li>快速回复</li><li>在线更新 &amp; 校验</li></ul>]]></description>
          <pubDate>Tue, 24 Nov 2026 10:00:00 +0800</pubDate>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <enclosure url="https://updates.example.invalid/a-2.1.0.zip" length="1234" type="application/octet-stream"
                     sparkle:version="21" sparkle:shortVersionString="2.1.0" sparkle:edSignature="c2lnbmF0dXJl" sha256="abc" />
          <sparkle:deltas>
            <enclosure url="https://updates.example.invalid/delta.zip" length="1" sparkle:version="21" sparkle:deltaFrom="20" />
          </sparkle:deltas>
        </item>
        <item>
          <title>版本 2.2.0 测试版</title>
          <sparkle:channel>beta</sparkle:channel>
          <sparkle:version>22</sparkle:version>
          <sparkle:shortVersionString>2.2.0-beta.1</sparkle:shortVersionString>
          <enclosure url="https://updates.example.invalid/a-2.2.0.zip" length="99" sparkle:edSignature="YmV0YQ==" />
        </item>
      </channel>
    </rss>
    """

    func testAppcastParserReadsSparkleXML() throws {
        let releases = try AppcastParser.parse(Data(Self.sparkleXML.utf8))
        XCTAssertEqual(releases.count, 2)
        let stable = releases[0]
        XCTAssertEqual(stable.title, "版本 2.1.0")
        XCTAssertEqual(stable.notes, "• 快速回复\n• 在线更新 & 校验")
        XCTAssertEqual(stable.version, SemanticVersion("2.1.0", build: "21"))
        XCTAssertEqual(stable.downloadURL.absoluteString, "https://updates.example.invalid/a-2.1.0.zip", "增量包不能覆盖完整包")
        XCTAssertEqual(stable.length, 1234)
        XCTAssertEqual(stable.edSignature, "c2lnbmF0dXJl")
        XCTAssertEqual(stable.sha256, "abc")
        XCTAssertEqual(stable.minimumSystemVersion, "13.0")
        XCTAssertNil(stable.channel)
        XCTAssertEqual(stable.publishedAt?.timeIntervalSince1970, 1_795_485_600)
        XCTAssertEqual(releases[1].channel, "beta")
        XCTAssertEqual(releases[1].version, SemanticVersion("2.2.0-beta.1", build: "22"))
    }

    func testAppcastParserResolvesCustomNamespacePrefix() throws {
        let xml = Self.sparkleXML.replacingOccurrences(of: "sparkle:", with: "su:").replacingOccurrences(of: "xmlns:sparkle", with: "xmlns:su")
        let releases = try AppcastParser.parse(Data(xml.utf8))
        XCTAssertEqual(releases.first?.version, SemanticVersion("2.1.0", build: "21"))
        XCTAssertEqual(releases.last?.channel, "beta")
    }

    func testAppcastParserReadsJSON() throws {
        let json = #"""
        {"items":[
          {"title":"版本 2.1.0","description":"<p>修复</p>","pubDate":"2026-11-24T02:00:00Z","url":"https://updates.example.invalid/a.zip",
           "length":4096,"shortVersionString":"2.1.0","version":"21","edSignature":"c2ln","sha256":"def"},
          {"title":"测试","channel":"beta","enclosure":{"url":"https://updates.example.invalid/b.zip","length":"10"},
           "shortVersionString":"2.2.0-rc.1","version":22}
        ]}
        """#
        let releases = try AppcastParser.parse(Data(json.utf8))
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases[0].notes, "修复")
        XCTAssertEqual(releases[0].length, 4096)
        XCTAssertEqual(releases[0].version.buildNumber, 21)
        XCTAssertEqual(releases[0].publishedAt?.timeIntervalSince1970, 1_795_485_600)
        XCTAssertEqual(releases[1].downloadURL.lastPathComponent, "b.zip")
        XCTAssertEqual(releases[1].length, 10)
        XCTAssertEqual(releases[1].version.buildNumber, 22)
    }

    func testAppcastParserRejectsGarbageButAcceptsEmptyFeed() throws {
        for bad in ["<html><body>404</body></html>", "not a feed", #"{"foo":1}"#, #"{"items":[{"title":"缺版本"}]}"#] {
            XCTAssertThrowsError(try AppcastParser.parse(Data(bad.utf8)), bad)
        }
        XCTAssertEqual(try AppcastParser.parse(Data(#"{"items":[]}"#.utf8)).count, 0)
    }

    func testChannelFilteringAndMinimumSystem() throws {
        let releases = try AppcastParser.parse(Data(Self.sparkleXML.utf8))
        let current = try XCTUnwrap(SemanticVersion("2.0.0", build: "20"))
        let system = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(AppcastParser.newest(in: releases, channel: .stable, current: current, system: system)?.version.minor, 1)
        XCTAssertEqual(AppcastParser.newest(in: releases, channel: .beta, current: current, system: system)?.version.minor, 2)
        let old = OperatingSystemVersion(majorVersion: 12, minorVersion: 6, patchVersion: 0)
        XCTAssertEqual(AppcastParser.newest(in: releases, channel: .stable, current: current, system: old)?.version.minor, nil)
        XCTAssertNil(AppcastParser.newest(in: releases, channel: .stable, current: try XCTUnwrap(SemanticVersion("2.1.0", build: "21")), system: system))
        XCTAssertFalse(UpdateChannel.stable.accepts("nightly"))
        XCTAssertFalse(UpdateChannel.beta.accepts("nightly"))
    }

    func testSemanticVersionOrdering() throws {
        func v(_ text: String, _ build: String? = nil) throws -> SemanticVersion { try XCTUnwrap(SemanticVersion(text, build: build), text) }
        XCTAssertGreaterThan(try v("2.1.0"), try v("2.0.0"))
        XCTAssertGreaterThan(try v("2.0.1"), try v("2.0.0"))
        XCTAssertGreaterThan(try v("3.0.0"), try v("2.9.9"))
        XCTAssertGreaterThan(try v("2.10.0"), try v("2.9.0"), "按数字比较，不按字符串")
        XCTAssertGreaterThan(try v("2.0.0", "21"), try v("2.0.0", "20"), "同版本比较构建号")
        XCTAssertGreaterThan(try v("2.0.0", "100"), try v("2.0.0", "20"))
        XCTAssertLessThan(try v("2.0.0", "99"), try v("2.0.1", "1"), "构建号不能盖过版本号")
        XCTAssertEqual(try v("v2.1"), try v("2.1.0"))
        XCTAssertEqual(try v("2.1.0+meta"), try v("2.1.0"))
        let ordered = try ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"].map { try v($0) }
        for (low, high) in zip(ordered, ordered.dropFirst()) { XCTAssertLessThan(low, high, "\(low) < \(high)") }
        for bad in ["", "2", "2.x.0", "2.01.0", "2.0.0.0", "2.0.0-", "2.0.0-01", "-1.0.0", "２.0.0"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testVerifierAcceptsValidSignatureAndDigest() throws {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("安装包内容".utf8)
        let signature = try key.signature(for: archive).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let digest = UpdateVerifier.sha256Hex(archive)
        XCTAssertNoThrow(try UpdateVerifier.verify(archive: archive, sha256: digest, signature: signature, publicKey: publicKey))
        XCTAssertNoThrow(try UpdateVerifier.verify(archive: archive, sha256: digest.uppercased(), signature: signature, publicKey: publicKey))
        XCTAssertNoThrow(try UpdateVerifier.verify(archive: archive, sha256: nil, signature: signature, publicKey: publicKey))
        XCTAssertNoThrow(try UpdateVerifier.verify(archive: archive, sha256: digest, signature: nil, publicKey: nil))
        XCTAssertTrue(UpdateVerifier.isValidPublicKey(publicKey))
    }

    func testVerifierRejectsTamperingAndMissingMaterial() throws {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("安装包内容".utf8)
        var tampered = archive
        tampered[0] ^= 0xFF
        let signature = try key.signature(for: archive).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let digest = UpdateVerifier.sha256Hex(archive)
        let otherSignature = try Curve25519.Signing.PrivateKey().signature(for: archive).base64EncodedString()

        func assertRejected(_ expected: UpdateError, sha: String?, sig: String?, pub: String?, data: Data? = nil, line: UInt = #line) {
            XCTAssertThrowsError(try UpdateVerifier.verify(archive: data ?? archive, sha256: sha, signature: sig, publicKey: pub), line: line) {
                XCTAssertEqual($0 as? UpdateError, expected, line: line)
            }
        }
        assertRejected(.invalidSignature, sha: nil, sig: signature, pub: publicKey, data: tampered)
        assertRejected(.digestMismatch, sha: digest, sig: signature, pub: publicKey, data: tampered)
        assertRejected(.invalidSignature, sha: digest, sig: otherSignature, pub: publicKey)
        assertRejected(.invalidSignature, sha: nil, sig: "不是base64", pub: publicKey)
        assertRejected(.invalidSignature, sha: nil, sig: Data(repeating: 1, count: 32).base64EncodedString(), pub: publicKey)
        assertRejected(.missingSignature, sha: digest, sig: nil, pub: publicKey)
        assertRejected(.missingSignature, sha: digest, sig: "  ", pub: publicKey)
        assertRejected(.invalidPublicKey, sha: digest, sig: signature, pub: "短")
        assertRejected(.invalidPublicKey, sha: digest, sig: signature, pub: Data(repeating: 1, count: 16).base64EncodedString())
        assertRejected(.missingVerification, sha: nil, sig: signature, pub: nil)
        assertRejected(.invalidDigest, sha: "abc", sig: nil, pub: nil)
    }

    func testOnlyHTTPSSourcesAreAllowed() throws {
        XCTAssertNoThrow(try UpdateVerifier.requireSecure(XCTUnwrap(URL(string: "https://updates.example.invalid/a.xml"))))
        for bad in ["http://updates.example.invalid/a.xml", "file:///tmp/a.xml", "ftp://x/a", "https:///a",
                    "https://user:pw@updates.example.invalid/a.xml", "http://127.0.0.1:8080/a.xml"] {
            XCTAssertThrowsError(try UpdateVerifier.requireSecure(XCTUnwrap(URL(string: bad))), bad)
        }
    }

    // MARK: 流程

    private func makeUpdater(current: String = "2.0.0", build: String = "20", bundle: URL? = nil, source: BuiltInUpdateSource? = nil,
                             relaunch: ((UpdateInstallPlan) throws -> Void)? = nil) throws -> AppUpdater {
        let root = directory.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let environment = UpdateEnvironment(bundleURL: bundle ?? directory.appendingPathComponent("Installed.app"),
                                            bundleIdentifier: UpdateFixture.identifier,
                                            version: try XCTUnwrap(SemanticVersion(current, build: build)), processIdentifier: 1,
                                            builtInSource: source)
        return AppUpdater(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), environment: environment,
                          session: UpdateURLProtocol.session(), workRoot: root, relaunch: relaunch)
    }

    private func publish(short: String = "2.1.0", build: String = "21", identifier: String = UpdateFixture.identifier,
                         key: Curve25519.Signing.PrivateKey, tamper: Bool = false, declaredShort: String? = nil) throws {
        let folder = directory.appendingPathComponent("release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let app = folder.appendingPathComponent("WeChatMenuBridge.app", isDirectory: true)
        try UpdateFixture.makeApp(at: app, short: short, build: build, identifier: identifier)
        let bytes = try UpdateFixture.zip(app, to: folder.appendingPathComponent("update.zip"))
        let signature = try key.signature(for: bytes).base64EncodedString()
        var served = bytes
        if tamper { served[served.count / 2] ^= 0xFF }
        let json = #"{"items":[{"title":"新版本","description":"修复","url":"\#(package)","length":\#(served.count),"shortVersionString":"\#(declaredShort ?? short)","version":"\#(build)","edSignature":"\#(signature)","sha256":"\#(UpdateVerifier.sha256Hex(bytes))"}]}"#
        UpdateURLProtocol.set(feed, .init(body: Data(json.utf8)))
        UpdateURLProtocol.set(package, .init(body: served))
    }

    private func installedBundle() throws -> URL {
        let app = directory.appendingPathComponent("Installed.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app
    }

    func testBuiltInSourceReusesItsPinnedKeyAndPreservesCustomSettings() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let source = try XCTUnwrap(BuiltInUpdateSource(feed: feed, publicKey: key))
        XCTAssertNil(BuiltInUpdateSource(feed: feed, publicKey: nil))
        XCTAssertNil(BuiltInUpdateSource(feed: "http://updates.example.invalid/appcast.json", publicKey: key))
        let updater = try makeUpdater(source: source)
        XCTAssertEqual(updater.feedURL, feed)
        XCTAssertEqual(updater.requiredPublicKey, key)
        updater.ed25519PublicKey = "不应覆盖发布公钥"
        updater.feedURL = feed + "?channel=stable"
        XCTAssertTrue(updater.hasValidPublicKey)
        XCTAssertEqual(updater.requiredPublicKey, key)
        let custom = "https://custom.example.invalid/appcast.json"
        updater.feedURL = custom
        let restarted = try makeUpdater(source: source)
        XCTAssertEqual(restarted.feedURL, custom)
        XCTAssertNil(restarted.requiredPublicKey)
        XCTAssertFalse(restarted.hasValidPublicKey)
        restarted.restoreBuiltInFeed()
        XCTAssertEqual(restarted.feedURL, feed)
        XCTAssertEqual(restarted.requiredPublicKey, key)
    }

    func testBuiltInSourceRejectsZipSignedByConfiguredCustomKey() async throws {
        let official = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let source = try XCTUnwrap(BuiltInUpdateSource(feed: feed, publicKey: official.publicKey.rawRepresentation.base64EncodedString()))
        try publish(key: other)
        var relaunched = false
        let updater = try makeUpdater(bundle: try installedBundle(), source: source) { _ in relaunched = true }
        updater.ed25519PublicKey = other.publicKey.rawRepresentation.base64EncodedString()
        await updater.checkForUpdates()
        await updater.downloadAndInstall()
        XCTAssertEqual(updater.state, .failed(UpdateError.invalidSignature.errorDescription ?? ""))
        XCTAssertFalse(relaunched)

        try publish(key: official)
        await updater.checkForUpdates()
        await updater.downloadAndInstall()
        XCTAssertTrue(relaunched)
    }

    func testCheckDownloadVerifyAndRelaunch() async throws {
        let key = Curve25519.Signing.PrivateKey()
        try publish(key: key)
        let bundle = try installedBundle()
        var plans: [UpdateInstallPlan] = []
        let updater = try makeUpdater(bundle: bundle) { plans.append($0) }
        updater.feedURL = feed
        updater.ed25519PublicKey = key.publicKey.rawRepresentation.base64EncodedString()

        await updater.checkForUpdates()
        guard case .available(let release) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertEqual(release.version, SemanticVersion("2.1.0", build: "21"))

        await updater.downloadAndInstall()
        guard case .readyToInstall(_, let staged) = updater.state else { return XCTFail("\(updater.state)") }
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plan.target, bundle)
        XCTAssertEqual(plan.staged, staged)
        XCTAssertEqual(plan.executable, "app")
        XCTAssertEqual(plan.arguments.first, "1")
        XCTAssertEqual(try fileMode(plan.workDirectory.path) & 0o777, 0o700, "工作目录必须私有")
    }

    func testTamperedPackageIsRejectedAndNeverRelaunches() async throws {
        let key = Curve25519.Signing.PrivateKey()
        try publish(key: key, tamper: true)
        var relaunched = false
        let updater = try makeUpdater(bundle: try installedBundle()) { _ in relaunched = true }
        updater.feedURL = feed
        updater.ed25519PublicKey = key.publicKey.rawRepresentation.base64EncodedString()
        await updater.checkForUpdates()
        await updater.downloadAndInstall()
        guard case .failed(let message) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertEqual(message, UpdateError.digestMismatch.errorDescription)
        XCTAssertFalse(relaunched)
        XCTAssertNotNil(updater.latestRelease, "失败后可以重试")
    }

    func testPackageWithWrongIdentityOrVersionIsRejected() async throws {
        let key = Curve25519.Signing.PrivateKey()
        for (identifier, declared, expected) in [("evil.example", "2.1.0", UpdateError.invalidBundle),
                                                 (UpdateFixture.identifier, "2.2.0", UpdateError.versionMismatch)] {
            try publish(identifier: identifier, key: key, declaredShort: declared)
            var relaunched = false
            let updater = try makeUpdater(bundle: try installedBundle()) { _ in relaunched = true }
            updater.feedURL = feed
            updater.ed25519PublicKey = key.publicKey.rawRepresentation.base64EncodedString()
            await updater.checkForUpdates()
            await updater.downloadAndInstall()
            XCTAssertEqual(updater.state, .failed(expected.errorDescription ?? ""))
            XCTAssertFalse(relaunched)
            updater.feedURL = ""
        }
    }

    func testRedirectToPlainHTTPIsRejected() async throws {
        UpdateURLProtocol.set(feed, .init(redirect: "http://updates.example.invalid/appcast.xml"))
        UpdateURLProtocol.set("http://updates.example.invalid/appcast.xml", .init(body: Data(#"{"items":[]}"#.utf8)))
        let updater = try makeUpdater()
        updater.feedURL = feed
        await updater.checkForUpdates()
        XCTAssertEqual(updater.state, .failed(UpdateError.insecureURL.errorDescription ?? ""))
    }

    func testUpToDateAndSettingChangeInvalidatesRelease() async throws {
        let json = #"{"items":[{"url":"\#(package)","shortVersionString":"2.1.0","version":"21","sha256":"\#(String(repeating: "a", count: 64))"}]}"#
        UpdateURLProtocol.set(feed, .init(body: Data(json.utf8)))
        let same = try makeUpdater(current: "2.1.0", build: "21")
        same.feedURL = feed
        await same.checkForUpdates()
        guard case .upToDate = same.state else { return XCTFail("\(same.state)") }

        let updater = try makeUpdater()
        updater.feedURL = feed
        await updater.checkForUpdates()
        XCTAssertNotNil(updater.latestRelease)
        updater.channel = .beta
        XCTAssertNil(updater.latestRelease, "切换通道后旧结果作废")
        XCTAssertEqual(updater.state, .idle)
        let restored = try makeUpdater()
        XCTAssertEqual(restored.channel, .beta)
        XCTAssertEqual(restored.feedURL, feed)
    }

    func testBackgroundCheckIsThrottledAndSilent() async throws {
        UpdateURLProtocol.set(feed, .init(status: 500))
        let updater = try makeUpdater()
        updater.feedURL = feed
        await updater.checkIfDue()
        XCTAssertEqual(updater.state, .idle, "后台检查失败不打扰用户")

        UpdateURLProtocol.set(feed, .init(body: Data(#"{"items":[]}"#.utf8)))
        await updater.checkIfDue()
        guard case .upToDate = updater.state else { return XCTFail("\(updater.state)") }
        let second = try makeUpdater()
        UpdateURLProtocol.set(feed, .init(status: 500))
        await second.checkIfDue()
        XCTAssertEqual(second.state, .idle)
        await second.checkIfDue(now: Date().addingTimeInterval(25 * 3600))
        XCTAssertEqual(second.state, .idle)
    }

    func testInstallGateHoldsVerifiedUpdate() async throws {
        let key = Curve25519.Signing.PrivateKey()
        try publish(key: key)
        var plans = 0
        let updater = try makeUpdater(bundle: try installedBundle()) { _ in plans += 1 }
        updater.feedURL = feed
        updater.ed25519PublicKey = key.publicKey.rawRepresentation.base64EncodedString()
        var blocker: String? = "请先保存"
        updater.installGate = { blocker }
        await updater.checkForUpdates()
        await updater.downloadAndInstall()
        guard case .readyToInstall = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertEqual(updater.installNotice, "请先保存")
        XCTAssertEqual(plans, 0)
        blocker = nil
        await updater.downloadAndInstall()
        XCTAssertEqual(plans, 1)
        XCTAssertNil(updater.installNotice)
    }

    func testDevelopmentBuildCannotInstall() async throws {
        let json = #"{"items":[{"url":"\#(package)","shortVersionString":"2.1.0","version":"21","sha256":"\#(String(repeating: "a", count: 64))"}]}"#
        UpdateURLProtocol.set(feed, .init(body: Data(json.utf8)))
        let updater = try makeUpdater(bundle: directory.appendingPathComponent("debug"))
        updater.feedURL = feed
        await updater.checkForUpdates()
        await updater.downloadAndInstall()
        guard case .failed(let message) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertTrue(message.contains("开发构建"), message)
    }

    // MARK: 安装脚本

    private struct ScriptRun {
        let status: Int32
        let target: URL
        let work: URL
        let openLog: URL
    }

    private func runInstallScript(newSource: String) throws -> ScriptRun {
        let root = directory.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent("微信 桥's.app", isDirectory: true)
        try UpdateFixture.makeApp(at: target, short: "2.0.0", build: "20")
        let staged = work.appendingPathComponent("unpacked/New.app", isDirectory: true)
        try UpdateFixture.makeApp(at: staged, short: "2.1.0", build: "21", source: newSource)

        let openLog = root.appendingPathComponent("open.log"), pids = root.appendingPathComponent("pids")
        spawned.append(pids)
        let opener = root.appendingPathComponent("fake-open")
        try """
        #!/bin/bash
        [ "$1" = "-n" ] && shift
        echo "$1" >> '\(openLog.path)'
        "$1/Contents/MacOS/app" >/dev/null 2>&1 &
        echo $! >> '\(pids.path)'
        """.write(to: opener, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(opener.path, 0o700), 0)
        let script = root.appendingPathComponent("install.sh")
        try UpdateInstallScript.render(openCommand: opener.path, probeSeconds: 3).write(to: script, atomically: true, encoding: .utf8)

        // 用已退出的进程号模拟“旧 App 已退出”。
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let plan = UpdateInstallPlan(processIdentifier: gone.processIdentifier, target: target, staged: staged, workDirectory: work, executable: "app")
        let status = try UpdateFixture.tool("/bin/bash", [script.path] + plan.arguments)
        return ScriptRun(status: status, target: target, work: work, openLog: openLog)
    }

    private func installedVersion(_ app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }

    private func leftovers(beside app: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
            .filter { $0.contains(".update.") || $0.contains(".backup.") }
    }

    func testInstallScriptReplacesAppAndCleansUp() throws {
        let run = try runInstallScript(newSource: UpdateFixture.stays)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(try installedVersion(run.target), "2.1.0")
        XCTAssertEqual(try leftovers(beside: run.target), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.work.path), "成功后清理工作目录")
        XCTAssertEqual(try UpdateFixture.tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", run.target.path]), 0)
    }

    func testInstallScriptRollsBackWhenNewVersionCrashes() throws {
        let run = try runInstallScript(newSource: UpdateFixture.crashes)
        XCTAssertEqual(run.status, 1)
        XCTAssertEqual(try installedVersion(run.target), "2.0.0", "新版本起不来必须换回旧版本")
        XCTAssertEqual(try leftovers(beside: run.target), [])
        let opens = try String(contentsOf: run.openLog, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(opens.count, 2, "先试新版本，回滚后重新打开旧版本")
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.work.appendingPathComponent("install.log").path), "失败时保留日志")
    }

    func testInstallScriptLeavesAppUntouchedWhileOldProcessRuns() throws {
        // 真实旧进程仍在运行时脚本不能动文件；缩短等待后验证不做替换。
        let script = UpdateInstallScript.render(openCommand: "/usr/bin/false", probeSeconds: 1)
            .replacingOccurrences(of: "{1..300}", with: "{1..3}")
        let root = directory.appendingPathComponent("busy", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("App.app", isDirectory: true)
        try UpdateFixture.makeApp(at: target, short: "2.0.0", build: "20")
        let staged = work.appendingPathComponent("New.app", isDirectory: true)
        try UpdateFixture.makeApp(at: staged, short: "2.1.0", build: "21")
        let path = root.appendingPathComponent("install.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        let status = try UpdateFixture.tool("/bin/bash", [path.path, String(getpid()), target.path, staged.path, work.path, "app"])
        XCTAssertEqual(status, 1)
        XCTAssertEqual(try installedVersion(target), "2.0.0")
    }
}
