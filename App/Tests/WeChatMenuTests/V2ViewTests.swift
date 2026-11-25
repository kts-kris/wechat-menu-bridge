import AppKit
import SwiftUI
import XCTest
@testable import WeChatMenu

@MainActor
private final class ViewMockTransport: BridgeTransport {
    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    private(set) var methods: [String] = []
    private(set) var params: [String: [String: Any]] = [:]
    var results: [String: String] = [:]

    func send(_ frame: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let id = value["id"] as? Int, let method = value["method"] as? String else { return }
        methods.append(method)
        params[method] = value["params"] as? [String: Any] ?? [:]
        let result = results[method] ?? "true"
        feed(result.hasPrefix("!")
            ? #"{"code":"\#(result.dropFirst())","id":\#(id),"kind":"reply","ok":false,"v":3}"#
            : #"{"id":\#(id),"kind":"reply","ok":true,"result":\#(result),"v":3}"#)
    }

    func close() {}
    func feed(_ line: String) { onData?(Data((line + "\n").utf8)) }
}

private let capabilitiesJSON = #"{"accountWideEvents":true,"canSendText":true,"groupMembers":true,"historyQuery":true,"historySearch":true,"listConversations":true,"mentionSend":true,"nativeReply":true,"readMedia":true}"#
private let helloFrame = #"{"kind":"event","payload":{"capabilities":\#(capabilitiesJSON),"globalPhase":"running","pendingProposalCount":2,"plugins":{},"sessions":{"wxid_a":{"phase":"blocked-unknown","replyMode":"off","reason":"send-unknown"},"g@chatroom":{"phase":"listening","replyMode":"auto"}},"unreadFeedCount":3,"v":3},"topic":"hello","v":3}"#

private let hotBundlesJSON = #"{"items":[{"name":"policy.json","sha256":"\#(String(repeating: "a", count: 64))","verified":true}],"lastReloadAt":1764000000000,"loadedCount":1,"version":"2026.11.24"}"#

private let personaMarkdown = """
---
schema: 2
updatedAt: 2026-11-23T10:00:00+08:00
revision: 5
---

## 表达风格
<!-- mem:id=p_01 vis=cloud-safe locked=true -->
- 简短自然，少用感叹号。

## 从本人发言习得的习惯
<!-- mem:id=p_02 vis=local-only locked=false src=proposal_accepted updated=2026-11-22 expires=2026-12-07 -->
- 同意时常用“确实”。
这行是手写内容
"""

private let proposalDiff = """
--- a/persona.md
+++ b/persona.md
@@ -1,2 +1,3 @@
 ## 表达风格
--- 旧条目
+- 新条目
+- 第二条
"""

private func proposalJSON(id: String = "11111111-1111-4111-8111-111111111111", extra: String = "") -> String {
    let diff = String(data: try! JSONEncoder().encode(proposalDiff), encoding: .utf8)!
    return ###"{"proposalId":"\###(id)","baseDigest":"\###(String(repeating: "a", count: 64))","summary":"更短的句式","patch":{"summary":"更短的句式","operations":[{"op":"add","section":"表达风格","content":"少用敬语","suggestedVisibility":"cloud-safe"}]},"proposedContent":"## 表达风格\n- 新条目\n","diff":\###(diff),"sampleCount":25,"createdAt":1764000000000\###(extra)}"###
}

private func temporaryDirectory() throws -> URL {
    let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WMB_TEST_TEMP"] ?? NSTemporaryDirectory(), isDirectory: true)
    let path = base.appendingPathComponent("wmb-view-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return path
}

@MainActor
final class V2ViewTests: XCTestCase {
    private var directory: URL!
    private var suite: String!

    override func setUp() async throws {
        directory = try temporaryDirectory()
        suite = "wmb.viewtests.\(UUID().uuidString)"
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        UpdateURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    // 钥匙串作用域直接报错，确保视图测试不可能碰到真实钥匙串。
    private func makeWorkspace(connected: Bool = false, updater: AppUpdater? = nil) throws -> (V2Workspace, ViewMockTransport) {
        let transport = ViewMockTransport()
        let vault = KeychainVault(scope: { _ in throw BridgeFault("keychain-unavailable") })
        let workspace = V2Workspace(runtime: BridgeRuntime(), disk: SettingsV2Disk(directory: directory), vault: vault,
                                    notifications: NullNotificationDelivery(),
                                    reviewLedger: PluginReviewLedger(defaults: UserDefaults(suiteName: suite)!),
                                    updater: updater ?? AppUpdater(defaults: UserDefaults(suiteName: suite)!, workRoot: directory))
        try workspace.loadSettings()
        if connected {
            try workspace.runtime.connect(transport)
            let document = String(data: try JSONEncoder().encode(personaMarkdown), encoding: .utf8)!
            let diff = String(data: try JSONEncoder().encode(proposalDiff), encoding: .utf8)!
            let revision = ###"{"createdAt":1764000000000,"diffPreview":\###(diff),"revId":"rev-1","scopeKey":"global","snapshotPath":"/x/rev-1.md","source":"auto","summary":"更新表达风格","targetKind":"persona"}"###
            transport.results = ["feed.list": #"{"items":[],"nextCursor":null}"#, "plugins.list": "[]",
                                 "persona.proposals": #"{"items":[],"nextCursor":null}"#, "xiaohe.accounts": "[]",
                                 "session.traces": #"{"items":[]}"#, "system.bundles": hotBundlesJSON, "memory.get": "{\"text\":\(document)}",
                                 "memory.revisions": "{\"items\":[\(revision)],\"nextCursor\":null}"]
            transport.feed(helloFrame)
            XCTAssertTrue(workspace.runtime.ready)
        }
        return (workspace, transport)
    }

    private func seededSettings(_ workspace: V2Workspace) {
        var value = workspace.settings.draft
        value.xiaohe = .init(mcpUrl: "http://127.0.0.1:21454/mcp", accountId: "acct", accountLabel: "小禾")
        value.models = [ModelPreset(id: "local", name: "本机", mode: .local, kind: .chat, url: "http://127.0.0.1:11434/v1", modelName: "qwen"),
                        ModelPreset(id: "cloud", name: "云端", mode: .cloud, kind: .chat, url: "https://api.example.invalid/v1", modelName: "m")]
        value.defaultModels.replyPresetId = "local"
        for (id, label, type) in [("wxid_a", "甲", ScopeType.direct), ("g@chatroom", "项目群", .group), ("gh_news", "资讯号", .service)] {
            value.conversations[id] = ConversationPolicy(conversationId: id, label: label, type: type, enabled: true)
        }
        value.runtime.pinnedConversationIds = ["wxid_a", "g@chatroom", "gh_news"]
        workspace.settings.draft = value
    }

    private func render<V: View>(_ view: V, size: CGSize) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        XCTAssertNotNil(bitmap)
        if let bitmap { host.cacheDisplay(in: host.bounds, to: bitmap) }
        return host
    }

    // 放进真实窗口后截图：SwiftUI 只有在窗口内才会运行 .task 并完成完整布局。
    private func hosted<V: View>(_ view: V, size: CGSize = CGSize(width: 820, height: 2000)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.orderBack(nil)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return window
    }

    private func snapshot<V: View>(_ view: V) throws -> Data {
        let window = hosted(view)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func settle(until condition: () -> Bool) {
        for _ in 0..<100 where !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func pushSession(_ transport: ViewMockTransport, _ status: String, id: String = "wxid_a") {
        transport.feed(#"{"kind":"event","payload":{"conversationId":"\#(id)","status":\#(status)},"topic":"session.updated","v":3}"#)
    }

    private func connectedSeeded(sessionStatus: String, id: String = "wxid_a") async throws -> (V2Workspace, ViewMockTransport) {
        let (workspace, transport) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        transport.results["xiaohe.accounts"] = #"[{"canRead":true,"canSend":true,"id":"acct","label":"小禾"}]"#
        transport.results["settings.apply"] = "true"
        try await workspace.settings.save()
        try await workspace.sessions.refreshAccount()
        pushSession(transport, sessionStatus, id: id)
        workspace.selectedConversationId = id
        return (workspace, transport)
    }

    // MARK: 路由

    func testFeedRoutesLandOnTheRightTab() {
        func route(_ kind: FeedItem.Kind, conversation: String? = nil, plugin: String? = nil, ref: String? = nil) -> ConsoleRoute {
            ConsoleRoute.forFeed(kind: kind, id: "f", conversationId: conversation, pluginId: plugin, refPath: ref)
        }
        XCTAssertEqual(route(.pluginDigest, plugin: "p").tab, .plugins)
        XCTAssertEqual(route(.pluginDigest).tab, .overview)
        let proposal = route(.personaProposal, ref: "/x/memory/proposals/abc.json")
        XCTAssertEqual(proposal.tab, .memory)
        XCTAssertEqual(proposal.memorySection, .proposals)
        XCTAssertEqual(proposal.proposalId, "abc")
        XCTAssertEqual(route(.personaProposal, ref: "abc").proposalId, "abc")
        XCTAssertEqual(route(.memoryUpdated, conversation: "c").memorySection, .scopes)
        XCTAssertEqual(route(.memoryUpdated).memorySection, .persona)
        XCTAssertEqual(route(.alert, conversation: "c").tab, .conversations)
        XCTAssertEqual(route(.alert, plugin: "p").tab, .plugins)
        XCTAssertEqual(route(.alert).tab, .overview)
        XCTAssertEqual(route(.scheduleCancelled, conversation: "c").conversationId, "c")
    }

    func testWorkspaceOpensRouteAndNotification() throws {
        let (workspace, _) = try makeWorkspace()
        var presented = 0
        workspace.presentConsole = { presented += 1 }
        workspace.open(ConsoleRoute(tab: .conversations, conversationId: "wxid_a", feedId: "f1"))
        XCTAssertEqual(workspace.tab, .conversations)
        XCTAssertEqual(workspace.selectedConversationId, "wxid_a")
        XCTAssertEqual(workspace.highlightedFeedId, "f1")

        XCTAssertTrue(workspace.openNotification(userInfo: ["feedId": "f2", "kind": "plugin_digest", "pluginId": "p1"]))
        XCTAssertEqual(workspace.tab, .plugins)
        XCTAssertEqual(workspace.selectedPluginId, "p1")
        XCTAssertFalse(workspace.openNotification(userInfo: ["feedId": "f3", "kind": "nonsense"]))
        XCTAssertEqual(presented, 2)

        workspace.requestOneShot("wxid_b")
        XCTAssertEqual(workspace.tab, .conversations)
        XCTAssertEqual(workspace.oneShotRequest?.conversationId, "wxid_b")
    }

    func testPinLimitAndRemovalClearPin() throws {
        XCTAssertEqual(PinnedConversations.toggled(["a"], id: "a"), [])
        XCTAssertEqual(PinnedConversations.toggled(["a"], id: "b"), ["a", "b"])
        XCTAssertNil(PinnedConversations.toggled(["a", "b", "c", "d"], id: "e"))

        let (workspace, _) = try makeWorkspace()
        seededSettings(workspace)
        workspace.selectedConversationId = "wxid_a"
        workspace.removeConversation("wxid_a")
        XCTAssertNil(workspace.settings.draft.conversations["wxid_a"])
        XCTAssertFalse(workspace.settings.draft.runtime.pinnedConversationIds.contains("wxid_a"))
        XCTAssertNil(workspace.selectedConversationId)
    }

    func testCloseGuardRequiresDecisionWhenDirty() throws {
        let (workspace, _) = try makeWorkspace()
        var closed = 0
        XCTAssertTrue(workspace.requestClose { closed += 1 })
        seededSettings(workspace)
        XCTAssertFalse(workspace.requestClose { closed += 1 })
        XCTAssertTrue(workspace.closeConfirmationVisible)
        workspace.cancelClose()
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(workspace.settings.hasUnsavedChanges)
        XCTAssertFalse(workspace.requestClose { closed += 1 })
        workspace.resolveClose(save: false)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(workspace.settings.hasUnsavedChanges)
    }

    func testPresetKindChangeClearsMismatchedDefaults() throws {
        let (workspace, _) = try makeWorkspace()
        seededSettings(workspace)
        workspace.settings.draft.conversations["wxid_a"]?.replyPresetId = "local"
        workspace.upsertPreset(ModelPreset(id: "local", name: "本机", mode: .local, kind: .vision,
                                           url: "http://127.0.0.1:11434/v1", modelName: "qwen"))
        XCTAssertNil(workspace.settings.draft.defaultModels.replyPresetId)
        XCTAssertNil(workspace.settings.draft.conversations["wxid_a"]?.replyPresetId)
    }

    func testVisionDefaultAcceptsChatAndVisionButNotSTT() throws {
        let (workspace, _) = try makeWorkspace()
        seededSettings(workspace)
        func change(to kind: ModelKind) {
            workspace.upsertPreset(ModelPreset(id: "cloud", name: "云端", mode: .cloud, kind: kind,
                                               url: "https://api.example.invalid/v1", modelName: "m"))
        }
        workspace.settings.draft.defaultModels.visionPresetId = "cloud"
        change(to: .chat)
        XCTAssertEqual(workspace.settings.draft.defaultModels.visionPresetId, "cloud", "多模态对话模型可用于图片理解")
        change(to: .vision)
        XCTAssertEqual(workspace.settings.draft.defaultModels.visionPresetId, "cloud")
        change(to: .stt)
        XCTAssertNil(workspace.settings.draft.defaultModels.visionPresetId, "语音转写预设不能理解图片")
    }

    func testSwitchingPrimaryModelKeepsFollowersAndExplicitOverrides() throws {
        let (workspace, _) = try makeWorkspace()
        seededSettings(workspace)
        workspace.settings.draft.models.append(ModelPreset(id: "third", name: "第三", mode: .local, kind: .chat,
                                                           url: "http://127.0.0.1:11434/v1", modelName: "x"))
        workspace.settings.draft.defaultModels.pluginPresetId = "local"
        workspace.settings.draft.defaultModels.memoryPresetId = nil
        workspace.settings.draft.defaultModels.visionPresetId = "third"
        workspace.settings.draft.defaultModels.fallbackReplyPresetId = "third"

        workspace.setPrimaryModel("cloud")
        var models = workspace.settings.draft.defaultModels
        XCTAssertEqual(models.replyPresetId, "cloud")
        XCTAssertNil(models.pluginPresetId, "指向旧主模型的场景回到跟随")
        XCTAssertNil(models.memoryPresetId, "空值继续跟随")
        XCTAssertEqual(models.visionPresetId, "third", "用户显式覆盖的场景不能被改掉")
        XCTAssertEqual(models.fallbackReplyPresetId, "third", "备用模型独立于主模型")

        workspace.setPrimaryModel("third")
        workspace.setPrimaryModel("local")
        models = workspace.settings.draft.defaultModels
        XCTAssertNil(models.visionPresetId, "覆盖值与旧主模型相同时同样回到跟随")
    }

    func testToolbarHealthCheckRequestRoutesToSettings() throws {
        let (workspace, _) = try makeWorkspace()
        var presented = 0
        workspace.presentConsole = { presented += 1 }
        workspace.requestHealthCheck()
        XCTAssertEqual(workspace.tab, .settings)
        XCTAssertTrue(workspace.healthCheckRequested)
        workspace.openFeedback()
        XCTAssertTrue(workspace.feedbackPresented)
        XCTAssertEqual(presented, 2)
    }

    func testQuickArmRoutesUnapprovedCloudToConfirmation() async throws {
        let (workspace, transport) = try await connectedSeeded(sessionStatus: #"{"phase":"idle","replyMode":"off"}"#)
        workspace.settings.draft.conversations["wxid_a"]?.replyPresetId = "cloud"
        transport.results["settings.apply"] = "true"
        try await workspace.settings.save()
        XCTAssertFalse(workspace.canFastArm("wxid_a"))
        workspace.tab = .overview
        workspace.quickArm("wxid_a", mode: .auto)
        XCTAssertEqual(workspace.pendingGrant, GrantRequest(conversationId: "wxid_a", mode: .auto))
        XCTAssertEqual(workspace.tab, .conversations)
        XCTAssertEqual(workspace.selectedConversationId, "wxid_a")
        XCTAssertFalse(transport.methods.contains("session.arm"), "未授权的云模型不能绕过确认")
    }

    // MARK: 反馈与诊断

    private func diagnosticSnapshot() -> DiagnosticSnapshot {
        DiagnosticSnapshot(appVersion: "2.0.0 (20)", osVersion: "Version 27.3", architecture: "arm64",
                           generatedAt: Date(timeIntervalSince1970: 1_764_000_000), backendReady: true, globalPhase: .running,
                           xiaoheConfigured: true, accountBound: true,
                           capabilities: try! JSONDecoder().decode(XiaoheCapabilities.self, from: Data(capabilitiesJSON.utf8)),
                           sessions: [.init(tail: DiagnosticBundleBuilder.conversationTail("wxid_private_friend"), type: .direct,
                                            phase: .blockedUnknown, replyMode: .off, reason: "send-unknown")],
                           models: [.init(mode: .cloud, kind: .chat, reasoningEffort: .max)])
    }

    private func logLine(_ summary: String, session: String = "private1", code: String? = nil) -> String {
        var row: [String: Any] = ["at": 1_764_000_000_000, "session": session, "stage": "model", "level": "warn", "summary": summary]
        if let code { row["code"] = code }
        return String(data: try! JSONSerialization.data(withJSONObject: row), encoding: .utf8)!
    }

    func testDiagnosticReportRedactsEverySecretShape() {
        let secrets = ["sk-secret1234567890", "tok_abc", "hunter2value", "abcdEFGH1234abcdEFGH1234abcdEFGH",
                       "ghp_abcdefghijklmnop1234", "cookievalue99", "user:pass", "query-secret"]
        let lines = [
            logLine("请求失败 sk-secret1234567890"),
            logLine("Authorization: Bearer tok_abc"),
            logLine(#"{"api_key":"hunter2value"}"#),
            logLine("password=hunter2value&token=hunter2value"),
            logLine("长令牌 abcdEFGH1234abcdEFGH1234abcdEFGH 结束"),
            logLine("github ghp_abcdefghijklmnop1234"),
            logLine("cookie: cookievalue99"),
            logLine("调用 https://user:pass@api.example.invalid/v1?key=query-secret 失败", code: "model-timeout"),
            "这是一行无法解析的聊天正文 sk-secret1234567890 Bearer tok_abc",
        ]
        let report = DiagnosticBundleBuilder.buildReport(snapshot: diagnosticSnapshot(), logLines: lines)
        for secret in secrets { XCTAssertFalse(report.contains(secret), secret) }
        XCTAssertFalse(report.contains("这是一行无法解析的聊天正文"), "非结构化日志行必须整行省略")
        XCTAssertFalse(report.contains("api.example.invalid"), "模型地址不能进入报告")
        XCTAssertTrue(report.contains("2.0.0 (20)"))
        XCTAssertTrue(report.contains("9/9"), "应包含小禾能力摘要")
        XCTAssertTrue(report.contains("model-timeout"), "标准错误码要保留")
        XCTAssertTrue(report.contains("已省略 1 行"))
    }

    func testDiagnosticSnapshotExcludesChatContentAndCredentials() async throws {
        let (workspace, transport) = try await connectedSeeded(
            sessionStatus: #"{"draft":"周末一起吃饭的私密草稿","phase":"listening","replyMode":"draft"}"#)
        XCTAssertTrue(transport.methods.contains("settings.apply"))
        let report = DiagnosticBundleBuilder.buildReport(snapshot: .capture(workspace), logLines: [])
        for forbidden in ["周末一起吃饭", "甲", "项目群", "资讯号", "api.example.invalid", "127.0.0.1", "wxid_a", "g@chatroom", "qwen"] {
            XCTAssertFalse(report.contains(forbidden), forbidden)
        }
        XCTAssertTrue(report.contains("## 会话（3）"))
        XCTAssertTrue(report.contains("## 模型（2）"))
        XCTAssertTrue(report.contains("cloud · chat"))
        XCTAssertTrue(report.contains("listening · draft"))
    }

    func testConversationTailNeverExposesShortIds() {
        XCTAssertEqual(DiagnosticBundleBuilder.conversationTail("wxid_private_friend"), "…friend")
        XCTAssertEqual(DiagnosticBundleBuilder.conversationTail("wxid_a"), "…d_a")
        XCTAssertEqual(DiagnosticBundleBuilder.conversationTail("a"), "…a")
    }

    func testLogTailKeepsLast120LinesAndIgnoresNeighbouringSecrets() throws {
        let log = directory.appendingPathComponent("engine.log")
        let rows = (0..<200).map { logLine("第 \($0) 行") }.joined(separator: "\n") + "\n"
        try Data(rows.utf8).write(to: log)
        try Data(#"{"key":"sk-from-secrets-file-123456"}"#.utf8).write(to: directory.appendingPathComponent("secrets.json"))
        let lines = DiagnosticBundleBuilder.readLogTail(at: log)
        XCTAssertEqual(lines.count, DiagnosticBundleBuilder.logLineLimit)
        XCTAssertTrue(try XCTUnwrap(lines.first).contains("第 80 行"))
        XCTAssertTrue(try XCTUnwrap(lines.last).contains("第 199 行"))
        XCTAssertFalse(DiagnosticBundleBuilder.buildReport(snapshot: diagnosticSnapshot(), logLines: lines).contains("sk-from-secrets"))

        let link = directory.appendingPathComponent("linked.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("secrets.json"))
        XCTAssertEqual(DiagnosticBundleBuilder.readLogTail(at: link), [], "符号链接不能被跟随")
        XCTAssertEqual(DiagnosticBundleBuilder.readLogTail(at: directory.appendingPathComponent("missing.log")), [])
    }

    func testFeedbackTextIsRedactedInReportAndIssueURL() throws {
        let feedback = FeedbackDraft(category: .model, title: "模型 sk-secret1234567890 报错", details: "Bearer tok_abc 失败 C++ 100%")
        let report = DiagnosticBundleBuilder.buildReport(snapshot: diagnosticSnapshot(), logLines: [], feedback: feedback)
        XCTAssertFalse(report.contains("sk-secret1234567890"))
        XCTAssertFalse(report.contains("tok_abc"))
        XCTAssertTrue(report.contains("模型与回复"))

        let url = try XCTUnwrap(DiagnosticBundleBuilder.issueURL(repository: "https://github.com/acme/bridge.git",
                                                                 snapshot: diagnosticSnapshot(), feedback: feedback))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/acme/bridge/issues/new")
        XCTAssertFalse(url.absoluteString.contains("sk-secret"))
        XCTAssertFalse(url.absoluteString.contains("tok_abc"))
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"), "加号必须转义，否则 GitHub 会读成空格")
        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value
        XCTAssertEqual(body?.contains("2.0.0 (20)"), true)
        XCTAssertEqual(body?.contains("send-unknown"), false, "Issue 预填内容不带运行细节")
    }

    func testRepositorySlugParsing() {
        for input in ["acme/bridge", " https://github.com/acme/bridge/ ", "git@github.com:acme/bridge.git", "github.com/acme/bridge"] {
            XCTAssertEqual(DiagnosticBundleBuilder.repositorySlug(input), "acme/bridge", input)
        }
        for input in ["", "acme", "a/b/c", "../evil", "https://evil.example/acme/bridge", "acme/bri dge", "acme/.."] {
            XCTAssertNil(DiagnosticBundleBuilder.repositorySlug(input), input)
        }
    }

    func testBundleVersionAndBuiltInUpdateSource() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist))
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, AppVersion.fallbackShort)
        XCTAssertEqual(info["CFBundleVersion"] as? String, AppVersion.fallbackBuild)
        let source = try XCTUnwrap(BuiltInUpdateSource(feed: info["SUFeedURL"] as? String, publicKey: info["SUPublicEDKey"] as? String))
        XCTAssertEqual(source.feedURL.absoluteString, "https://github.com/kts-kris/wechat-menu-bridge/releases/latest/download/appcast.json")
    }

    func testFeedbackSheetRenders() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        let host = render(FeedbackSheet(workspace: workspace) {}, size: CGSize(width: 600, height: 640))
        XCTAssertLessThanOrEqual(host.fittingSize.width, 600)
        XCTAssertEqual(DiagnosticBundleBuilder.defaultRepository, "kts-kris/wechat-menu-bridge")
        let defaultURL = try XCTUnwrap(DiagnosticBundleBuilder.issueURL(
            repository: DiagnosticBundleBuilder.defaultRepository,
            snapshot: diagnosticSnapshot(),
            feedback: FeedbackDraft(category: .model, title: "默认仓库测试", details: "验证默认预填")
        ))
        XCTAssertEqual(defaultURL.path, "/kts-kris/wechat-menu-bridge/issues/new")
        let light = try snapshot(FeedbackSheet(workspace: workspace, submitter: GitHubIssueSubmitter(vault: KeychainVault(fileDirectory: directory), ghSearchPaths: [])) {}, appearance: .aqua, size: CGSize(width: 600, height: 640))
        let dark = try snapshot(FeedbackSheet(workspace: workspace, submitter: GitHubIssueSubmitter(vault: KeychainVault(fileDirectory: directory), ghSearchPaths: [])) {}, appearance: .darkAqua, size: CGSize(width: 600, height: 640))
        XCTAssertNotEqual(light, dark)
    }

    func testGitHubIssuePayloadRedactsSecretsAndIncludesDiagnostics() throws {
        let feedback = FeedbackDraft(category: .model, title: "模型调用 sk-secret123456 报错", details: "ghp_1234567890abcdef1234567890 失败")
        let payload = try XCTUnwrap(DiagnosticBundleBuilder.issuePayload(
            repository: "https://github.com/kts-kris/wechat-menu-bridge.git",
            snapshot: diagnosticSnapshot(),
            logLines: [#"{"at":1700000000000,"stage":"model","level":"error","summary":"api_key=abc123456789 timeout","code":"model-timeout"}"#],
            feedback: feedback,
            includeDiagnostics: true
        ))
        XCTAssertEqual(payload.repository, "kts-kris/wechat-menu-bridge")
        XCTAssertEqual(payload.labels, ["bug", "bug/llm"])
        XCTAssertTrue(payload.title.hasPrefix("[模型与回复] "))
        XCTAssertFalse(payload.title.contains("sk-secret123456"))
        XCTAssertFalse(payload.body.contains("ghp_1234567890"))
        XCTAssertFalse(payload.body.contains("abc123456789"))
        XCTAssertTrue(payload.body.contains("<details>"))
        XCTAssertTrue(payload.body.contains("model-timeout"))

        let withoutDiag = try XCTUnwrap(DiagnosticBundleBuilder.issuePayload(
            repository: DiagnosticBundleBuilder.defaultRepository,
            snapshot: diagnosticSnapshot(),
            logLines: [],
            feedback: FeedbackDraft(category: .experience, title: "界面优化建议", details: "详情"),
            includeDiagnostics: false
        ))
        XCTAssertEqual(withoutDiag.labels, ["enhancement", "bug/ui"])
        XCTAssertFalse(withoutDiag.body.contains("<details>"))

        // 标题为空或仓库不合法时拒绝构造自动提交载荷。
        XCTAssertNil(DiagnosticBundleBuilder.issuePayload(repository: DiagnosticBundleBuilder.defaultRepository,
                                                          snapshot: diagnosticSnapshot(), logLines: [],
                                                          feedback: FeedbackDraft(category: .malfunction, title: "   ", details: "x")))
        XCTAssertNil(DiagnosticBundleBuilder.issuePayload(repository: "not-a-repo",
                                                          snapshot: diagnosticSnapshot(), logLines: [],
                                                          feedback: FeedbackDraft(category: .malfunction, title: "标题", details: "x")))
    }

    func testGitHubIssueSubmitterPostsViaRESTAPIAndRetriesWithoutUnknownLabels() async throws {
        final class Box<T>: @unchecked Sendable {
            private let lock = NSLock()
            var value: T
            init(_ value: T) { self.value = value }
            func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
        }
        let vault = KeychainVault(fileDirectory: directory)
        let captured = Box<[URLRequest]>([])
        let submitter = GitHubIssueSubmitter(
            vault: vault,
            ghSearchPaths: [],
            httpTransport: { request in
                let attempt = captured.withLock { list -> Int in
                    list.append(request)
                    return list.count
                }
                let url = request.url!
                if attempt == 1 {
                    let body = Data(#"{"message":"Validation Failed","errors":[{"field":"labels","code":"invalid"}]}"#.utf8)
                    return (body, HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)!)
                }
                let body = Data(#"{"number":42,"html_url":"https://github.com/kts-kris/wechat-menu-bridge/issues/42","title":"[模型与回复] 测试标题"}"#.utf8)
                return (body, HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!)
            }
        )
        try submitter.saveToken("ghp_local_test_token_123456")
        XCTAssertEqual(submitter.detectAvailability(), .savedToken)

        // Token 仅存入 0600 secrets.json，绝不写入 settings.json。
        let secretsPath = directory.appendingPathComponent("secrets.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretsPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: secretsPath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path))

        let payload = try XCTUnwrap(DiagnosticBundleBuilder.issuePayload(
            repository: DiagnosticBundleBuilder.defaultRepository,
            snapshot: diagnosticSnapshot(), logLines: [],
            feedback: FeedbackDraft(category: .model, title: "测试标题", details: "测试复现")
        ))
        let created = try await submitter.submit(payload)
        let requests = captured.withLock { $0 }
        XCTAssertEqual(created.number, 42)
        XCTAssertEqual(created.url.absoluteString, "https://github.com/kts-kris/wechat-menu-bridge/issues/42")
        XCTAssertEqual(created.via, .token)
        XCTAssertEqual(requests.count, 2, "标签校验失败时自动去掉 labels 重试一次")
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.github.com/repos/kts-kris/wechat-menu-bridge/issues")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer ghp_local_test_token_123456")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(firstJSON["labels"] as? [String], ["bug", "bug/llm"])
        XCTAssertNil(secondJSON["labels"])

        try submitter.removeToken()
        XCTAssertEqual(submitter.detectAvailability(), .unavailable)
    }

    func testGitHubIssueSubmitterFallsBackToGHCLIAndRejectsRedirects() async throws {
        final class Box<T>: @unchecked Sendable {
            private let lock = NSLock()
            var value: T
            init(_ value: T) { self.value = value }
            func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
        }
        let fakeGH = directory.appendingPathComponent("fake-gh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeGH)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeGH.path)

        let invocations = Box<[([String], Data?)]>([])
        let cliSubmitter = GitHubIssueSubmitter(
            vault: KeychainVault(fileDirectory: directory),
            ghSearchPaths: [fakeGH.path],
            processRunner: { _, args, stdin in
                invocations.withLock { $0.append((args, stdin)) }
                if args.first == "auth" {
                    return .init(exitCode: 0, stdout: Data("Logged in".utf8), stderr: Data())
                }
                let ok = Data(#"{"number":99,"html_url":"https://github.com/kts-kris/wechat-menu-bridge/issues/99","title":"[功能故障] CLI 提交"}"#.utf8)
                return .init(exitCode: 0, stdout: ok, stderr: Data())
            }
        )
        XCTAssertEqual(cliSubmitter.detectAvailability(), .ghCLI(path: fakeGH.path))
        let payload = try XCTUnwrap(DiagnosticBundleBuilder.issuePayload(
            repository: DiagnosticBundleBuilder.defaultRepository,
            snapshot: diagnosticSnapshot(), logLines: [],
            feedback: FeedbackDraft(category: .malfunction, title: "CLI 提交", details: "自动走 gh api")
        ))
        let created = try await cliSubmitter.submit(payload)
        let calls = invocations.withLock { $0 }
        XCTAssertEqual(created.number, 99)
        XCTAssertEqual(created.via, .ghCLI)
        XCTAssertEqual(calls.last?.0.contains("repos/kts-kris/wechat-menu-bridge/issues"), true)
        XCTAssertEqual(calls.last?.0.contains("--input"), true)
        let stdinJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(calls.last?.1)) as? [String: Any])
        XCTAssertEqual(stdinJSON["labels"] as? [String], ["bug"])

        // 显式 Token 遇到 302 重定向必须拒绝，避免凭证外泄。
        let redirectSubmitter = GitHubIssueSubmitter(
            vault: KeychainVault(fileDirectory: directory),
            ghSearchPaths: [],
            httpTransport: { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example/"])!)
            }
        )
        do {
            _ = try await redirectSubmitter.submit(payload, explicitToken: "ghp_token_should_not_redirect")
            XCTFail("302 重定向必须被拒绝")
        } catch let error as GitHubIssueSubmitter.SubmitError {
            if case .networkFailure(let detail) = error {
                XCTAssertTrue(detail.contains("重定向"))
            } else {
                XCTFail("意外错误类型: \(error)")
            }
        }
    }

    func testConversationStatusDotPriority() {
        func dot(_ phase: SessionRuntimeState.Phase, _ mode: SessionReplyMode, _ reason: IPCErrorCode? = nil) -> ConversationStatusDot {
            ConversationStatusDot(state: .init(phase: phase, replyMode: mode, reason: reason))
        }
        XCTAssertEqual(ConversationStatusDot(state: nil), .off)
        XCTAssertEqual(dot(.listening, .auto), .autoReply)
        XCTAssertEqual(dot(.generating, .draft), .drafting)
        XCTAssertEqual(dot(.cooldown, .auto), .cooldown)
        XCTAssertEqual(dot(.blockedUnknown, .off), .attention)
        XCTAssertEqual(dot(.lockedOptOut, .off), .attention)
        XCTAssertEqual(dot(.paused, .off, .eventGap), .attention)
        XCTAssertEqual(dot(.paused, .off, .userPaused), .off)
    }

    // MARK: 状态展示

    func testSessionPresentationRecoveryPriority() {
        XCTAssertEqual(SessionPresentation(state: .init(phase: .blockedUnknown, replyMode: .off)).recovery, .acknowledge)
        XCTAssertEqual(SessionPresentation(state: .init(phase: .lockedOptOut, replyMode: .off)).recovery, .restoreConsent)
        XCTAssertEqual(SessionPresentation(state: .init(phase: .paused, replyMode: .off, reason: .eventGap)).recovery, .resetRead)
        XCTAssertNil(SessionPresentation(state: .init(phase: .paused, replyMode: .off, reason: .userPaused)).recovery)
        XCTAssertTrue(SessionPresentation(state: .init(phase: .listening, replyMode: .auto)).isArmed)
        XCTAssertFalse(SessionPresentation(state: .init(phase: .scheduled, replyMode: .off)).isArmed)
        XCTAssertFalse(SessionPresentation(state: nil).isArmed)
    }

    func testRuntimeCountsFallBackBeforeFirstGlobalUpdate() {
        let sessions: [String: SessionRuntimeState] = ["a": .init(phase: .listening, replyMode: .auto),
                                                       "b": .init(phase: .sending, replyMode: .auto),
                                                       "c": .init(phase: .paused, replyMode: .auto)]
        let plugin = PluginRuntimeState(kind: .declarative, enabled: true, approvedPermissions: [], consecutiveFailures: 0, circuitOpen: false)
        var tripped = plugin
        tripped.circuitOpen = true
        let derived = RuntimeCounts(global: nil, sessions: sessions, plugins: ["p": plugin, "q": tripped])
        XCTAssertEqual(derived.activeAuto, 2)
        XCTAssertEqual(derived.activePlugins, 1)
        XCTAssertEqual(derived.inFlight, 1)
        let global = GlobalRuntimeState(phase: .running, activeAutoCount: 9, activePluginCount: 8, inFlightCount: 7)
        XCTAssertEqual(RuntimeCounts(global: global, sessions: sessions, plugins: [:]).activeAuto, 9)
    }

    func testPopoverSummaryIgnoresUnmanagedAndCountsUnreadDigests() {
        var value = SettingsV2()
        value.conversations["a"] = ConversationPolicy(conversationId: "a", label: "甲", type: .direct)
        value.runtime.pinnedConversationIds = ["ghost", "a"]
        let feed = [FeedItem(id: "1", kind: .pluginDigest, title: "t", body: "b", createdAt: 1, read: false),
                    FeedItem(id: "2", kind: .pluginDigest, title: "t", body: "b", createdAt: 2, read: true),
                    FeedItem(id: "3", kind: .alert, title: "t", body: "b", createdAt: 3, read: false)]
        let summary = MenuPopoverSummary(settings: value, sessions: ["a": .init(phase: .blockedUnknown, replyMode: .off),
                                                                     "ghost": .init(phase: .lockedOptOut, replyMode: .off)],
                                         feed: feed, pendingProposals: 4)
        XCTAssertEqual(summary.pinnedIds, ["a"])
        XCTAssertEqual(summary.unreadDigests, 1)
        XCTAssertEqual(summary.pendingProposals, 4)
        XCTAssertEqual(summary.blockedIds, ["a"])
    }

    // MARK: 授权

    func testGrantRequirements() {
        let group = ConversationPolicy(conversationId: "g@chatroom", label: "群", type: .group)
        let direct = ConversationPolicy(conversationId: "wxid_a", label: "甲", type: .direct)
        let cloud = ModelPreset(id: "c", name: "c", mode: .cloud, kind: .chat, url: "https://api.example.invalid/v1", modelName: "m")
        let local = ModelPreset(id: "l", name: "l", mode: .local, kind: .chat, url: "http://127.0.0.1:11434/v1", modelName: "m")

        let groupCloud = ArmGrantRequirement(policy: group, preset: cloud, mode: .auto)
        XCTAssertFalse(groupCloud.isSatisfied(consent: true, cloud: true, group: false))
        XCTAssertFalse(groupCloud.isSatisfied(consent: true, cloud: false, group: true))
        XCTAssertFalse(groupCloud.isSatisfied(consent: false, cloud: true, group: true))
        XCTAssertTrue(groupCloud.isSatisfied(consent: true, cloud: true, group: true))
        XCTAssertTrue(ArmGrantRequirement(policy: direct, preset: local, mode: .auto).isSatisfied(consent: true, cloud: false, group: false))

        // 只拟稿不发信，群聊不要求二次确认，但云端同意不能省。
        let groupDraft = ArmGrantRequirement(policy: group, preset: cloud, mode: .draft)
        XCTAssertFalse(groupDraft.needsGroupConfirmation)
        XCTAssertFalse(groupDraft.isSatisfied(consent: true, cloud: false, group: false))
        XCTAssertTrue(groupDraft.isSatisfied(consent: true, cloud: true, group: false))
    }

    func testUnknownOutcomesLockResend() {
        for code in ["send-unknown", "engine-timeout", "engine-exited", "engine-protocol", "internal-error"] {
            XCTAssertTrue(OneShotFaultPolicy.locksResend(code), code)
        }
        for code in ["send-rejected", "send-fence", "invalid-expiry", "active-limit", "busy"] {
            XCTAssertFalse(OneShotFaultPolicy.locksResend(code), code)
        }
    }

    // MARK: 会话目录

    func testConversationCatalogFailsClosedOnTypeMismatch() {
        let plain = XiaoheConversation(conversationId: "custom_user", type: .direct, displayName: "老号")
        XCTAssertEqual(ConversationCatalog.makePolicy(plain)?.type, .direct)
        XCTAssertEqual(ConversationCatalog.makePolicy(plain)?.memoryEnabled, true)
        XCTAssertEqual(ConversationCatalog.makePolicy(plain)?.enabled, true)

        let group = ConversationCatalog.makePolicy(XiaoheConversation(conversationId: "1@chatroom", type: .group, displayName: "群"))
        XCTAssertEqual(group?.replyMode, .off)
        XCTAssertEqual(group?.groupTrigger, .mentionOnly)
        XCTAssertEqual(group?.memoryEnabled, false)
        XCTAssertEqual(ConversationCatalog.makePolicy(XiaoheConversation(conversationId: "gh_x", type: .service, displayName: "号"))?.memoryEnabled, false)

        // 不符合 ID 规则的服务号绝不能落成私聊策略。
        XCTAssertNil(ConversationCatalog.makePolicy(XiaoheConversation(conversationId: "official_x", type: .service, displayName: "号")))
    }

    func testSendPermissionHint() {
        XCTAssertEqual(ConversationCatalog.sendPermission("a", account: nil).tone, .warning)
        let listed = XiaoheAccountOption(id: "x", label: "x", canRead: true, canSend: true, sendConversations: ["a"])
        XCTAssertEqual(ConversationCatalog.sendPermission("a", account: listed).text, "在小禾发信白名单内")
        XCTAssertEqual(ConversationCatalog.sendPermission("b", account: listed).text, "不在小禾发信白名单内")
        let open = XiaoheAccountOption(id: "x", label: "x", canRead: true, canSend: true)
        XCTAssertEqual(ConversationCatalog.sendPermission("b", account: open).text, "账号级发信权限")
        let wildcard = XiaoheAccountOption(id: "x", label: "x", canRead: true, canSend: true, sendConversations: ["*"])
        XCTAssertTrue(wildcard.maySend(to: "wxid_any"))
        XCTAssertEqual(ConversationCatalog.sendPermission("wxid_any", account: wildcard).text, "小禾已放行全部会话发信")
        XCTAssertEqual(ConversationCatalog.sendPermission("wxid_any", account: wildcard).tone, .active)
    }

    func testBackfillPresentation() {
        let running = BackfillPresentation(progress: .init(jobId: "j", conversationId: "c", fetched: 25, done: false), target: 100)
        XCTAssertEqual(running.fraction, 0.25)
        XCTAssertTrue(running.isRunning)
        let over = BackfillPresentation(progress: .init(jobId: "j", conversationId: "c", fetched: 150, done: false), target: 100)
        XCTAssertEqual(over.fraction, 1)
        XCTAssertNil(BackfillPresentation(progress: .init(jobId: "j", conversationId: "c", fetched: 5, done: false), target: nil).fraction)
        let failed = BackfillPresentation(progress: .init(jobId: "j", conversationId: "c", fetched: 5, done: true, error: .mcpOffline), target: 100)
        XCTAssertNil(failed.fraction)
        XCTAssertFalse(failed.isRunning)
    }

    func testPickerSkipsEmptyFilteredPages() async {
        var cursors: [String?] = []
        let row = XiaoheConversation(conversationId: "1@chatroom", type: .group, displayName: "群")
        let model = ConversationPickerModel(accountId: "acct") { params in
            cursors.append(params.cursor)
            XCTAssertEqual(params.type, .group)
            XCTAssertEqual(params.accountId, "acct")
            switch params.cursor {
            case nil: return XiaoheConversationPage(items: [], nextCursor: "p2")
            case "p2": return XiaoheConversationPage(items: [row], nextCursor: "p3")
            default: return XiaoheConversationPage(items: [row], nextCursor: nil)
            }
        }
        await model.reload(query: " 群 ", type: .group)
        XCTAssertEqual(cursors, [nil, "p2"])
        XCTAssertEqual(model.items.map(\.conversationId), ["1@chatroom"])
        XCTAssertEqual(model.nextCursor, "p3")
        await model.loadMore()
        XCTAssertEqual(model.items.count, 1)
        XCTAssertNil(model.nextCursor)
    }

    // MARK: 人格提案与 Diff

    func testProposalFileDecodesExactEngineShape() throws {
        let file = try PersonaProposalFile.decode(proposalJSON())
        XCTAssertEqual(file.summary, "更短的句式")
        XCTAssertEqual(file.sampleCount, 25)
        XCTAssertEqual(file.proposedContent, "## 表达风格\n- 新条目\n")
        XCTAssertEqual(file.diff, proposalDiff)
        XCTAssertThrowsError(try PersonaProposalFile.decode(proposalJSON(extra: #","unexpected":1"#)))
        XCTAssertThrowsError(try PersonaProposalFile.decode("{}"))
    }

    func testUnifiedDiffRendersLineKinds() throws {
        let file = try PersonaProposalFile.decode(proposalJSON())
        let lines = UnifiedDiff.parse(file.diff)
        XCTAssertEqual(lines.map(\.kind), [.header, .header, .hunk, .context, .removed, .added, .added])
        // hunk 内以 --- 开头的是被删除的正文，不是文件头。
        XCTAssertEqual(lines[4].text, "-- 旧条目")
        XCTAssertEqual(lines[4].oldNumber, 2)
        XCTAssertNil(lines[4].newNumber)
        XCTAssertEqual(lines[5].newNumber, 2)
        XCTAssertEqual(lines[6].newNumber, 3)
        XCTAssertEqual(lines[3].text, "## 表达风格")
    }

    func testUnifiedDiffHandlesNoNewlineMarkerAndSecondHunk() {
        let text = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n@@ -9,0 +10 @@\n+tail\n"
        let lines = UnifiedDiff.parse(text)
        XCTAssertEqual(lines.map(\.kind), [.header, .header, .hunk, .removed, .meta, .added, .hunk, .added])
        XCTAssertEqual(lines.last?.newNumber, 10)
    }

    func testProposalDocumentReachesViewModel() async throws {
        let (workspace, transport) = try makeWorkspace(connected: true)
        let proposals = directory.appendingPathComponent("memory/proposals", isDirectory: true)
        try FileManager.default.createDirectory(at: proposals, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.appendingPathComponent("memory").path, 0o700)
        let path = proposals.appendingPathComponent("11111111-1111-4111-8111-111111111111.json").path
        try Data(proposalJSON().utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0o600)
        transport.results["persona.proposals"] = #"{"items":[{"createdAt":1764000000000,"filePath":"\#(path)","proposalId":"11111111-1111-4111-8111-111111111111","sampleCount":25,"status":"pending","summary":"更短的句式"}],"nextCursor":null}"#
        try await workspace.memory.loadProposals()
        let proposal = try XCTUnwrap(workspace.memory.proposals.first)
        let file = try PersonaProposalFile.decode(try workspace.memory.proposalDocument(proposal))
        XCTAssertEqual(UnifiedDiff.parse(file.diff).filter { $0.kind == .added }.count, 2)

        workspace.memorySection = .proposals
        workspace.selectedProposalId = proposal.proposalId
        _ = render(MemoryView(workspace: workspace), size: CGSize(width: 780, height: 640))
        XCTAssertTrue(workspace.runtime.ready)
    }

    // MARK: 记忆文档

    func testMemoryParserReadsStructuredEntries() {
        let rows = MemoryDocumentParser.parse(personaMarkdown)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].id, "p_01")
        XCTAssertEqual(rows[0].section, "表达风格")
        XCTAssertTrue(rows[0].locked)
        XCTAssertEqual(rows[0].visibility, .cloudSafe)
        XCTAssertEqual(rows[1].visibility, .localOnly)
        XCTAssertFalse(rows[1].locked)
        XCTAssertEqual(rows[1].source, "proposal_accepted")
        XCTAssertEqual(rows[1].expires, "2026-12-07")
        // 手写行按锁定且仅本机处理，防止被模型改写或出境。
        XCTAssertFalse(rows[2].managed)
        XCTAssertTrue(rows[2].locked)
        XCTAssertEqual(rows[2].visibility, .localOnly)
    }

    func testMemoryParserTreatsAmbiguousContentAsPrivate() {
        let duplicate = "<!-- mem:id=dup vis=cloud-safe locked=false -->\n- 一\n<!-- mem:id=dup vis=cloud-safe locked=false -->\n- 二\n"
        XCTAssertTrue(MemoryDocumentParser.parse(duplicate).allSatisfy { !$0.managed && $0.visibility == .localOnly })

        let fenced = "```\n<!-- mem:id=code vis=cloud-safe locked=false -->\n- 示例\n```\n"
        XCTAssertTrue(MemoryDocumentParser.parse(fenced).allSatisfy { !$0.managed })

        let commented = "<!--\n<!-- mem:id=hide vis=cloud-safe locked=false -->\n- 被注释\n-->\n"
        XCTAssertFalse(MemoryDocumentParser.parse(commented).contains { $0.managed })

        let badDate = "<!-- mem:id=bad vis=cloud-safe locked=false expires=2026-13-40 -->\n- 内容\n"
        XCTAssertFalse(MemoryDocumentParser.parse(badDate).contains { $0.managed })

        let reserved = "<!-- mem:id=hand_x vis=cloud-safe locked=false -->\n- 内容\n"
        XCTAssertFalse(MemoryDocumentParser.parse(reserved).contains { $0.managed })
    }

    // MARK: 插件表单

    func testGroupDigestTemplateDefaultsAreValid() {
        let config = PluginTemplates.groupDigest(id: "plugin-digest")
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.builtinTemplate, .groupDigest)
        XCTAssertEqual(config.scope.includeTypes, [.group])
        XCTAssertEqual(config.trigger, .windowTime(cron: nil, everyMinutes: nil, timesOfDay: ["12:30", "21:00"], minMessages: 5))
        XCTAssertEqual(config.processor.outputFormat, .structuredDigestJSON)
        XCTAssertTrue(config.processor.skipWhenNoValue)
        XCTAssertEqual(config.sinks.count, 2)
        XCTAssertTrue(PluginForm(config).issues(presets: []).isEmpty)
        // 表单往返不能丢字段。
        XCTAssertEqual(PluginForm(config).build(), config)

        let wechat = PluginTemplates.groupDigest(id: "plugin-digest", sendToFileHelper: true)
        XCTAssertTrue(wechat.sinks.contains(.wechat(id: "sink-wechat", targetConversationId: "filehelper", approved: true)))
        XCTAssertEqual(PluginForm(wechat).build(), wechat)
    }

    func testPluginFormRejectsInvalidInput() {
        func issues(_ change: (inout PluginForm) -> Void) -> [String] {
            var form = PluginForm(PluginTemplates.groupDigest(id: "p"))
            change(&form)
            return form.issues(presets: [])
        }
        XCTAssertFalse(issues { $0.name = "  " }.isEmpty)
        XCTAssertFalse(issues { $0.includeTypes = [] }.isEmpty)
        XCTAssertFalse(issues { $0.timesOfDay = "25:00" }.isEmpty)
        XCTAssertFalse(issues { $0.timesOfDay = "" }.isEmpty)
        XCTAssertTrue(issues { $0.timesOfDay = ""; $0.everyMinutes = 60 }.isEmpty)
        XCTAssertFalse(issues { $0.userPromptTemplate = "没有占位符" }.isEmpty)
        XCTAssertFalse(issues { $0.modelPresetId = "missing" }.isEmpty)
        XCTAssertFalse(issues { $0.feedOn = false; $0.markdownOn = false }.isEmpty)
        XCTAssertFalse(issues { $0.filenameTemplate = "../evil.md" }.isEmpty)
        XCTAssertFalse(issues { $0.triggerType = .realtime; $0.regex = "(" }.isEmpty)
        XCTAssertFalse(issues { $0.wechatOn = true; $0.wechatApproved = false }.isEmpty)
        XCTAssertFalse(issues { $0.wechatOn = true; $0.wechatApproved = true; $0.wechatTarget = "gh_news" }.isEmpty)
        XCTAssertTrue(issues { $0.wechatOn = true; $0.wechatApproved = true }.isEmpty)
        XCTAssertFalse(issues { $0.webhookOn = true; $0.webhookURL = "http://example.com/x" }.isEmpty)
        XCTAssertFalse(issues { $0.webhookOn = true; $0.webhookURL = "https://169.254.169.254/x" }.isEmpty)
        XCTAssertTrue(issues { $0.webhookOn = true; $0.webhookURL = "http://127.0.0.1:9000/hook" }.isEmpty)
        XCTAssertTrue(issues { $0.webhookOn = true; $0.webhookURL = "https://hooks.example.com/x" }.isEmpty)
    }

    func testPluginFormKeepsExtraSinksAndSecretFlag() {
        var config = PluginTemplates.blank(id: "p")
        config.name = "x"
        config.sinks = [.webhook(id: "a", url: "https://a.example.com", hasSecret: true),
                        .webhook(id: "b", url: "https://b.example.com", hasSecret: false)]
        var form = PluginForm(config)
        XCTAssertEqual(form.build().sinks, config.sinks)
        form.removeSecret = true
        XCTAssertEqual(form.build().sinks.first, .webhook(id: "a", url: "https://a.example.com", hasSecret: false))
    }

    func testModuleReviewFailsClosed() {
        let manifest = PluginManifest(id: "m", name: "m", version: "1", entry: "index.ts", permissions: [.readEvents, .sendWechat])
        func state(_ hash: String?, _ approved: [PluginPermission]) -> PluginRuntimeState {
            PluginRuntimeState(kind: .module, enabled: false, approvedPermissions: approved, manifestHash: hash, consecutiveFailures: 0, circuitOpen: false)
        }
        XCTAssertEqual(ModuleReviewStatus.evaluate(manifest: manifest, state: state(nil, []), reviewedHash: "h"), .missingHash)
        XCTAssertEqual(ModuleReviewStatus.evaluate(manifest: manifest, state: state("h", [.readEvents, .sendWechat]), reviewedHash: nil), .unreviewed)
        XCTAssertEqual(ModuleReviewStatus.evaluate(manifest: manifest, state: state("new", [.readEvents, .sendWechat]), reviewedHash: "old"), .changed)
        XCTAssertEqual(ModuleReviewStatus.evaluate(manifest: manifest, state: state("h", [.readEvents]), reviewedHash: "h"), .permissionsExpanded)
        XCTAssertEqual(ModuleReviewStatus.evaluate(manifest: manifest, state: state("h", [.readEvents, .sendWechat]), reviewedHash: "h"), .approved)
    }

    func testReviewLedgerPersistsHash() {
        let defaults = UserDefaults(suiteName: suite)!
        PluginReviewLedger(defaults: defaults).record(pluginId: "m", hash: "abc")
        XCTAssertEqual(PluginReviewLedger(defaults: defaults).reviewedHash(pluginId: "m"), "abc")
        XCTAssertNil(PluginReviewLedger(defaults: defaults).reviewedHash(pluginId: "n"))
    }

    // MARK: 模型预设

    func testPresetFormValidatesEndpointsPerKind() {
        var form = PresetForm()
        form.name = "本机"
        form.modelName = "qwen"
        XCTAssertTrue(form.issues.isEmpty)
        XCTAssertEqual(form.build().url, "http://127.0.0.1:11434/v1/chat/completions")

        form.kind = .stt
        XCTAssertTrue(form.issues.isEmpty)
        XCTAssertEqual(form.build().url, "http://127.0.0.1:11434/v1/audio/transcriptions")

        form.kind = .chat
        form.mode = .cloud
        XCTAssertFalse(form.issues.isEmpty)
        form.url = "https://api.example.com/v1"
        XCTAssertTrue(form.issues.isEmpty)
        form.url = "http://api.example.com/v1"
        XCTAssertFalse(form.issues.isEmpty)
    }

    func testPresetFormKeepsReasoningEffortOnlyForChat() {
        XCTAssertEqual(ReasoningEffort.displayOrder, [.max, .high, .medium, .low, .default])
        XCTAssertEqual(Set(ReasoningEffort.displayOrder), Set(ReasoningEffort.allCases))
        XCTAssertEqual(ReasoningEffort.max.title, "最高 (max，默认)")
        XCTAssertEqual(ReasoningEffort.default.title, "不传此参数 (default)")

        var form = PresetForm()
        form.name = "本机"
        form.modelName = "qwen"
        XCTAssertNil(form.build().reasoningEffort, "未选择时不写入配置")
        form.reasoningEffort = .low
        XCTAssertEqual(form.build().reasoningEffort, .low)
        XCTAssertEqual(PresetForm(form.build()).reasoningEffort, .low)
        form.kind = .vision
        XCTAssertNil(form.build().reasoningEffort, "非对话模型不携带推理强度")
    }

    func testPresetKindChangeClearsFallbackReference() throws {
        let (workspace, _) = try makeWorkspace()
        seededSettings(workspace)
        workspace.settings.draft.defaultModels.fallbackReplyPresetId = "cloud"
        workspace.upsertPreset(ModelPreset(id: "cloud", name: "云端", mode: .cloud, kind: .vision,
                                           url: "https://api.example.invalid/v1", modelName: "m"))
        XCTAssertNil(workspace.settings.draft.defaultModels.fallbackReplyPresetId)
    }

    // MARK: 运行轨迹与草稿

    func testTracePresentationLabels() {
        XCTAssertEqual(SessionTraceEntry.Stage.allCases.map(\.title), ["来信", "策略", "模型", "发信", "状态"])
        XCTAssertEqual(SessionTraceEntry.Level.info.color, .blue)
        XCTAssertEqual(SessionTraceEntry.Level.warn.color, .orange)
        XCTAssertEqual(SessionTraceEntry.Level.error.color, .red)

        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 11, 24, 15, 4, 9)
        let date = try! XCTUnwrap(Calendar.current.date(from: parts))
        let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
        XCTAssertEqual(V2Format.clockWithSeconds(milliseconds), "15:04:09")
        XCTAssertTrue(CooldownPresentation.notice(until: milliseconds).contains("15:04:09"))
        XCTAssertFalse(CooldownPresentation.notice(until: nil).contains("暂停至"))
    }

    func testDraftOutcomeLocksResendOfSameDraft() {
        XCTAssertTrue(DraftSendOutcome(text: "a", fault: nil).locks("a"), "已提交的草稿不能再发")
        XCTAssertFalse(DraftSendOutcome(text: "a", fault: nil).locks("b"), "新草稿不受影响")
        XCTAssertTrue(DraftSendOutcome(text: "a", fault: "send-unknown").locks("a"), "结果未知不能重发")
        XCTAssertTrue(DraftSendOutcome(text: "a", fault: "engine-timeout").locks("a"))
        XCTAssertFalse(DraftSendOutcome(text: "a", fault: "send-rejected").locks("a"), "明确被拒绝时允许重试")
        XCTAssertNil(SessionsStore.sendableText("第一行\n第二行"), "含换行的草稿不能一键发送")
        XCTAssertNil(SessionsStore.sendableText(String(repeating: "字", count: 501)))
        XCTAssertEqual(SessionsStore.sendableText("  你好 "), "你好")
    }

    func testCooldownNoticeRendersItsDeadline() async throws {
        let first = Int64(Date().addingTimeInterval(600).timeIntervalSince1970 * 1000)
        let second = first + 3_600_000
        let (workspace, transport) = try await connectedSeeded(
            sessionStatus: #"{"cooldownUntil":\#(first),"phase":"cooldown","replyMode":"auto"}"#)
        let before = try snapshot(ConversationsView(workspace: workspace))
        // 截止时间只出现在冷静期提示里，画面变化即证明提示已渲染。
        pushSession(transport, #"{"cooldownUntil":\#(second),"phase":"cooldown","replyMode":"auto"}"#)
        let after = try snapshot(ConversationsView(workspace: workspace))
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(workspace.runtime.ready)
    }

    func testDraftBlockRendersOnlyWithDraft() async throws {
        let (workspace, transport) = try await connectedSeeded(sessionStatus: #"{"phase":"listening","replyMode":"draft"}"#)
        let empty = try snapshot(ConversationsView(workspace: workspace))
        pushSession(transport, #"{"draft":"周末有空，一起吃饭吧","phase":"listening","replyMode":"draft"}"#)
        let drafted = try snapshot(ConversationsView(workspace: workspace))
        XCTAssertNotEqual(empty, drafted)
        // 含换行、无法一键发送的草稿要走另一条提示分支。
        pushSession(transport, #"{"draft":"第一行\n第二行","phase":"listening","replyMode":"draft"}"#)
        XCTAssertNotEqual(try snapshot(ConversationsView(workspace: workspace)), drafted)
        XCTAssertFalse(transport.methods.contains("session.sendOneShot"), "渲染不得触发发送")
        XCTAssertTrue(workspace.runtime.ready)
    }

    func testGroupDraftAndServiceDetailRender() async throws {
        let (workspace, transport) = try await connectedSeeded(
            sessionStatus: #"{"draft":"收到","phase":"listening","replyMode":"draft"}"#, id: "g@chatroom")
        _ = try snapshot(ConversationsView(workspace: workspace))
        workspace.selectedConversationId = "gh_news"
        _ = try snapshot(ConversationsView(workspace: workspace))
        XCTAssertFalse(transport.methods.contains("session.sendOneShot"))
        XCTAssertTrue(workspace.runtime.ready)
    }

    func testTraceCardLoadsOnSelectionAndRendersPushes() async throws {
        let (workspace, transport) = try await connectedSeeded(sessionStatus: #"{"phase":"listening","replyMode":"auto"}"#)
        let window = hosted(ConversationsView(workspace: workspace))
        settle { transport.methods.contains("session.traces") }
        window.close()
        XCTAssertEqual(transport.params["session.traces"]?["conversationId"] as? String, "wxid_a")
        XCTAssertEqual(transport.params["session.traces"]?["limit"] as? Int, SessionsStore.maxTraces)

        let empty = try snapshot(ConversationsView(workspace: workspace))
        for (index, level) in SessionTraceEntry.Level.allCases.enumerated() {
            transport.feed(#"{"kind":"event","payload":{"entry":{"at":\#(1764000000000 + Int64(index)),"conversationId":"wxid_a","detail":"对方连发 3 条","id":"t\#(index)","level":"\#(level.rawValue)","stage":"policy","summary":"跳过本轮"}},"topic":"session.trace","v":3}"#)
        }
        XCTAssertEqual(workspace.sessions.traces["wxid_a"]?.count, 3)
        XCTAssertNotEqual(try snapshot(ConversationsView(workspace: workspace)), empty)
        XCTAssertTrue(workspace.runtime.ready)
    }

    func testTakeoverOptionsControlCooldownDuration() async throws {
        XCTAssertTrue(RiskProfile.TakeoverAction.cooldown.usesCooldownDuration)
        XCTAssertFalse(RiskProfile.TakeoverAction.ignore.usesCooldownDuration)
        XCTAssertFalse(RiskProfile.TakeoverAction.pauseSession.usesCooldownDuration)

        let (workspace, _) = try await connectedSeeded(sessionStatus: #"{"phase":"idle","replyMode":"off"}"#)
        var frames: [Data] = []
        for action in RiskProfile.TakeoverAction.allCases {
            workspace.sessions.updatePolicy("wxid_a") { $0.riskProfile.takeoverAction = action }
            frames.append(try snapshot(ConversationsView(workspace: workspace)))
        }
        XCTAssertEqual(Set(frames).count, RiskProfile.TakeoverAction.allCases.count)
        XCTAssertTrue(workspace.runtime.ready)
    }

    // MARK: 全链路体检与模型设置

    func testHealthCheckRowsRenderPassAndFail() throws {
        let pass = HealthCheckStep(id: .model, label: HealthCheckStep.StepID.model.title, ok: true, durationMs: 4200, detail: "SSE、推理与 JSON 均正常")
        var fail = pass
        fail.ok = false
        XCTAssertNotEqual(try snapshot(HealthCheckRow(step: pass)), try snapshot(HealthCheckRow(step: fail)))
        XCTAssertEqual(HealthCheckStep.StepID.allCases.map(\.title),
                       ["小禾连接", "发信白名单", "本机凭据读取", "云端模型 SSE + 推理 + JSON 实测"])
        // 长错误说明要换行，不能撑破设置页宽度。
        fail.detail = String(repeating: "模型返回内容无法解析为 JSON。", count: 12)
        let host = render(HealthCheckRow(step: fail).frame(width: 520), size: CGSize(width: 520, height: 240))
        XCTAssertLessThanOrEqual(host.fittingSize.width, 520)
    }

    func testHealthCheckClientPathThroughSettingsStore() async throws {
        let (workspace, transport) = try makeWorkspace(connected: true)
        transport.results["system.healthCheck"] = #"{"ok":true,"steps":[{"detail":"已连接","durationMs":12,"id":"xiaohe","label":"小禾连接","ok":true}]}"#
        let result = try await workspace.settings.runHealthCheck()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.params["system.healthCheck"]?.count, 0)
        _ = try snapshot(V2SettingsView(workspace: workspace))
        XCTAssertTrue(workspace.runtime.ready)
    }

    func testDefaultModelsCardRendersFallbackWarning() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        let none = try snapshot(V2SettingsView(workspace: workspace))
        workspace.settings.draft.defaultModels.fallbackReplyPresetId = "cloud"
        let unapproved = try snapshot(V2SettingsView(workspace: workspace))
        XCTAssertNotEqual(none, unapproved)
        workspace.settings.draft.runtime.approvedCloudPresetIds = ["cloud"]
        XCTAssertNotEqual(try snapshot(V2SettingsView(workspace: workspace)), unapproved, "授权后警告消失")
    }

    func testPresetEditorShowsReasoningOnlyForChat() throws {
        let (workspace, _) = try makeWorkspace()
        var form = PresetForm()
        let size = CGSize(width: 520, height: 560)
        let chat = render(PresetEditor(workspace: workspace, initial: form) {}, size: size).fittingSize.height
        form.kind = .vision
        let vision = render(PresetEditor(workspace: workspace, initial: form) {}, size: size).fittingSize.height
        XCTAssertGreaterThan(chat, vision, "对话模型多出推理强度选择器")
    }

    // MARK: 快速回复与软件更新

    private func snapshot<V: View>(_ view: V, appearance: NSAppearance.Name, size: CGSize = CGSize(width: 820, height: 2000)) throws -> Data {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.orderBack(nil)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func availableUpdater() async throws -> AppUpdater {
        let feed = "https://updates.example.invalid/view-appcast.json"
        let json = #"{"items":[{"title":"版本 2.1.0","description":"<ul><li>快速回复</li><li>在线更新</li></ul>","url":"https://updates.example.invalid/a.zip","shortVersionString":"2.1.0","version":"21","sha256":"\#(String(repeating: "a", count: 64))"}]}"#
        UpdateURLProtocol.set(feed, .init(body: Data(json.utf8)))
        let environment = UpdateEnvironment(bundleURL: directory.appendingPathComponent("Installed.app"), bundleIdentifier: "local.wechatmenubridge",
                                            version: try XCTUnwrap(SemanticVersion("2.0.0", build: "20")), processIdentifier: 1)
        let updater = AppUpdater(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), environment: environment,
                                 session: UpdateURLProtocol.session(), workRoot: directory, relaunch: { _ in })
        updater.feedURL = feed
        await updater.checkForUpdates()
        guard case .available = updater.state else {
            XCTFail("\(updater.state)")
            return updater
        }
        return updater
    }

    func testFastReplyToggleRendersInLightAndDark() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            workspace.settings.draft.runtime.fastReplyMode = false
            let off = try snapshot(V2SettingsView(workspace: workspace), appearance: appearance)
            workspace.settings.draft.runtime.fastReplyMode = true
            let on = try snapshot(V2SettingsView(workspace: workspace), appearance: appearance)
            XCTAssertNotEqual(off, on, appearance.rawValue)
        }
        XCTAssertTrue(workspace.settings.hasUnsavedChanges, "开关走草稿，保存后才生效")
        XCTAssertNotEqual(try snapshot(V2SettingsView(workspace: workspace), appearance: .aqua),
                          try snapshot(V2SettingsView(workspace: workspace), appearance: .darkAqua))
        XCTAssertTrue(workspace.runtime.ready)
    }

    func testUpdateCardRendersEveryStateInLightAndDark() async throws {
        let updater = try await availableUpdater()
        let (workspace, transport) = try makeWorkspace(connected: true, updater: updater)
        let form = Form { UpdateSettingsCard(workspace: workspace) }.formStyle(.grouped)
        let size = CGSize(width: 680, height: 620)
        let light = try snapshot(form, appearance: .aqua, size: size)
        let dark = try snapshot(form, appearance: .darkAqua, size: size)
        XCTAssertNotEqual(light, dark)
        XCTAssertEqual(transport.params["system.bundles"]?["action"] as? String, "status", "进入设置页读取资产状态")
        updater.feedURL = "http://insecure.example.invalid/appcast.xml"
        XCTAssertFalse(updater.hasValidFeed)
        XCTAssertNotEqual(try snapshot(form, appearance: .aqua, size: size), light, "无效地址显示提示")
        let host = render(form, size: size)
        XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
        XCTAssertTrue(workspace.runtime.ready)
    }

    func testHotBundlesRowStates() throws {
        let item = HotBundleItem(name: "policy.json", sha256: String(repeating: "a", count: 64), verified: true)
        let ok = HotBundlesStatus(loadedCount: 1, version: "2026.11.24", lastReloadAt: 1_764_000_000_000, items: [item])
        var bad = ok
        bad.items[0].verified = false
        func row(_ status: HotBundlesStatus?, fault: String? = nil) -> some View {
            HotBundlesRow(status: status, busy: false, fault: fault, ready: true, reload: {}).frame(width: 520).padding()
        }
        let base = try snapshot(row(ok))
        XCTAssertNotEqual(base, try snapshot(row(bad)), "未通过校验要提示")
        XCTAssertNotEqual(base, try snapshot(row(ok, fault: "invalid-command")))
        XCTAssertNotEqual(base, try snapshot(row(nil)))
    }

    func testPopoverUpdateBadgeRoutesToSettingsSection() async throws {
        let updater = try await availableUpdater()
        let (workspace, _) = try makeWorkspace(connected: true, updater: updater)
        var withBadge: [NSSize] = []
        _ = render(MenuPopoverView(workspace: workspace, quit: {}, resize: { withBadge.append($0) }),
                   size: CGSize(width: MenuPanelMetrics.width, height: MenuPanelMetrics.maxHeight))
        let (plain, _) = try makeWorkspace(connected: true)
        var withoutBadge: [NSSize] = []
        _ = render(MenuPopoverView(workspace: plain, quit: {}, resize: { withoutBadge.append($0) }),
                   size: CGSize(width: MenuPanelMetrics.width, height: MenuPanelMetrics.maxHeight))
        XCTAssertGreaterThan(try XCTUnwrap(withBadge.last).height, try XCTUnwrap(withoutBadge.last).height)

        var presented = 0
        workspace.presentConsole = { presented += 1 }
        workspace.openUpdates()
        XCTAssertEqual(workspace.tab, .settings)
        XCTAssertEqual(presented, 1)
        XCTAssertTrue(workspace.updateSectionRequested)
        let window = hosted(V2SettingsView(workspace: workspace), size: CGSize(width: 820, height: 560))
        defer { window.close() }
        settle { !workspace.updateSectionRequested }
        XCTAssertFalse(workspace.updateSectionRequested, "设置页消费跳转请求")
        try await Task.sleep(nanoseconds: 500_000_000)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let offset = scrollViews(try XCTUnwrap(window.contentView)).map(\.contentView.bounds.origin.y).max() ?? 0
        XCTAssertGreaterThan(offset, 100, "表单应滚动到更新区")
    }

    func testInstallGateBlocksRestartWithUnsavedSettings() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        XCTAssertNil(workspace.updater.installGate())
        workspace.settings.draft.runtime.fastReplyMode = true
        XCTAssertEqual(workspace.updater.installGate(), "请先保存或放弃设置修改，再重启更新。")
    }

    // MARK: 离屏渲染

    func testPopoverRendersWithinFixedWidth() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        let saved = workspace.settings.draft
        try workspace.settings.disk.save(saved)
        try workspace.loadSettings()
        var reported: [NSSize] = []
        let view = MenuPopoverView(workspace: workspace, quit: {}, resize: { reported.append($0) })
        let host = render(view, size: CGSize(width: MenuPanelMetrics.width, height: MenuPanelMetrics.maxHeight))
        XCTAssertLessThanOrEqual(host.fittingSize.width, MenuPanelMetrics.width)
        let size = try XCTUnwrap(reported.last)
        XCTAssertEqual(size.width, MenuPanelMetrics.width)
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertLessThanOrEqual(size.height, MenuPanelMetrics.maxHeight)
    }

    func testEveryConsoleTabRendersWithoutOverflow() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        try workspace.settings.disk.save(workspace.settings.draft)
        try workspace.loadSettings()
        workspace.selectedConversationId = "g@chatroom"
        workspace.selectedMemoryConversationId = "wxid_a"
        let size = ConsoleView.minimumSize
        for tab in ConsoleTab.allCases {
            workspace.tab = tab
            let host = render(ConsoleView(workspace: workspace), size: size)
            XCTAssertEqual(host.frame.size, size, tab.rawValue)
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1, tab.rawValue)
        }
    }

    func testDetailPagesRenderAtContentWidth() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        try workspace.settings.disk.save(workspace.settings.draft)
        try workspace.loadSettings()
        let size = CGSize(width: ConsoleView.minimumSize.width - 200, height: ConsoleView.minimumSize.height)
        for id in ["wxid_a", "g@chatroom", "gh_news"] {
            workspace.selectedConversationId = id
            _ = render(ConversationsView(workspace: workspace), size: size)
        }
        _ = render(OverviewView(workspace: workspace), size: size)
        _ = render(V2SettingsView(workspace: workspace), size: size)
        for section in MemorySection.allCases {
            workspace.memorySection = section
            _ = render(MemoryView(workspace: workspace), size: size)
        }
        XCTAssertTrue(workspace.runtime.ready, "渲染期间后台不能因协议错误断开")
        XCTAssertNotNil(workspace.memory.documents[.persona]?.text)
        let sheet = render(OneShotSheet(workspace: workspace, conversationId: "wxid_a") {}, size: CGSize(width: 460, height: 560))
        XCTAssertLessThanOrEqual(sheet.fittingSize.height, 560)
        let form = render(SessionGrantForm(workspace: workspace, conversationId: "g@chatroom", mode: .auto) {}, size: CGSize(width: 370, height: 420))
        XCTAssertLessThanOrEqual(form.fittingSize.height, 420)
        XCTAssertTrue(workspace.runtime.ready)
    }

    func testPluginPagesRenderForBothKinds() async throws {
        let (workspace, transport) = try makeWorkspace(connected: true)
        let config = PluginTemplates.groupDigest(id: "plugin-digest")
        let encoded = String(data: try IPCv3.encoder().encode(config), encoding: .utf8)!
        let declarativeState = #"{"approvedPermissions":[],"circuitOpen":false,"consecutiveFailures":0,"enabled":false,"kind":"declarative"}"#
        let moduleState = #"{"approvedPermissions":[],"circuitOpen":true,"consecutiveFailures":3,"enabled":false,"kind":"module","lastError":"plugin-timeout","manifestHash":"hash-1"}"#
        let manifest = #"{"entry":"index.ts","id":"mod-1","name":"缺陷归集","permissions":["read_events","send_wechat"],"version":"1.0.0"}"#
        transport.results["plugins.list"] = "[{\"config\":\(encoded),\"kind\":\"declarative\",\"pluginId\":\"plugin-digest\",\"state\":\(declarativeState)},{\"kind\":\"module\",\"manifest\":\(manifest),\"pluginId\":\"mod-1\",\"state\":\(moduleState)}]"
        transport.results["plugins.runs"] = #"{"items":[{"itemCount":12,"outputPaths":["/tmp/x.md"],"pluginId":"mod-1","runId":"r1","startedAt":1764000000000,"status":"error","errorCode":"plugin-timeout","triggerKind":"manual"}],"nextCursor":null}"#
        try await workspace.plugins.refresh()
        XCTAssertEqual(workspace.plugins.plugins.count, 2)
        let size = CGSize(width: ConsoleView.minimumSize.width - 200, height: ConsoleView.minimumSize.height)
        for id in ["plugin-digest", "mod-1"] {
            workspace.selectedPluginId = id
            _ = render(PluginsView(workspace: workspace), size: size)
        }
    }

    func testClickingSidebarSwitchesConsoleTab() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        try workspace.settings.disk.save(workspace.settings.draft)
        try workspace.loadSettings()

        let host = NSHostingController(rootView: ConsoleView(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 980, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let found = findTable(in: child) { return found }
            }
            return nil
        }

        func detailSnapshot(_ view: NSView) throws -> Data {
            let bounds = NSRect(x: 240, y: 0, width: max(1, view.bounds.width - 240), height: view.bounds.height)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
            view.cacheDisplay(in: bounds, to: rep)
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }

        let contentView = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(findTable(in: contentView), "Sidebar NSTableView not found")
        XCTAssertEqual(table.numberOfRows, ConsoleTab.allCases.count)

        let order: [(Int, ConsoleTab)] = [
            (4, .settings),
            (1, .conversations),
            (2, .plugins),
            (3, .memory),
            (0, .overview),
        ]
        var snapshots: [ConsoleTab: Data] = [:]
        for (row, expectedTab) in order {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            window.layoutIfNeeded()
            XCTAssertEqual(workspace.tab, expectedTab, "Selecting sidebar row \(row) must switch workspace.tab to \(expectedTab)")
            snapshots[expectedTab] = try detailSnapshot(contentView)
        }
        // 5 个分栏点击后右侧主界面渲染内容必须两两不同，防止只高亮左侧而右侧不切换。
        let uniqueBitmaps = Set(snapshots.values)
        XCTAssertEqual(uniqueBitmaps.count, ConsoleTab.allCases.count, "Every sidebar click must visibly change the detail pane")

        // 反向路由同步：外部调用 workspace.open(tab:) 时左侧选中行也要跟着更新。
        workspace.open(tab: .plugins)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(table.selectedRow, 2)
        window.close()
    }

    func testDetailListsSwitchSelectionsInteractively() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        try workspace.settings.disk.save(workspace.settings.draft)
        try workspace.loadSettings()

        func hostWindow<V: View>(_ view: V) -> (NSWindow, NSView) {
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 820, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view)
            window.orderBack(nil)
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            return (window, window.contentView!)
        }

        func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let found = findTable(in: child) { return found }
            }
            return nil
        }

        // 会话列表点击切换右侧策略详情
        let (convWin, convRoot) = hostWindow(ConversationsView(workspace: workspace))
        let convTable = try XCTUnwrap(findTable(in: convRoot))
        XCTAssertEqual(convTable.numberOfRows, 3)
        convTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertNotNil(workspace.selectedConversationId)
        let firstPicked = workspace.selectedConversationId
        convTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertNotNil(workspace.selectedConversationId)
        XCTAssertNotEqual(workspace.selectedConversationId, firstPicked)
        convWin.close()

        // 记忆专档列表点击切换右侧专档
        workspace.memorySection = .scopes
        let (memWin, memRoot) = hostWindow(MemoryView(workspace: workspace))
        let memTable = try XCTUnwrap(findTable(in: memRoot))
        XCTAssertEqual(memTable.numberOfRows, 3)
        memTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertNotNil(workspace.selectedMemoryConversationId)
        memWin.close()
    }

    // MARK: v2.2.0 精选模板（#6）

    func testFeaturedTemplatesAreValidAndRoundTrip() {
        for template in PluginTemplates.Featured.allCases {
            let config = PluginTemplates.featured(template, id: "p-\(template.rawValue)")
            XCTAssertFalse(config.enabled, "模板默认不启用")
            XCTAssertEqual(config.builtinTemplate, template.builtinTemplate)
            XCTAssertEqual(config.scope.includeTypes, template.scopeTypes, "没有预选会话时退回类型通配")
            XCTAssertTrue(PluginForm(config).issues(presets: []).isEmpty, template.rawValue)
            XCTAssertEqual(PluginForm(config).build(), config, template.rawValue)
            XCTAssertNoThrow(try IPCv3.decodeStrict(DeclarativePluginConfig.self, from: IPCv3.encoder().encode(config)))
        }
        let digest = PluginTemplates.featured(.dailyDigest, id: "d")
        XCTAssertEqual(digest.builtinTemplate, .groupDigest)
        XCTAssertEqual(digest.trigger, .windowTime(cron: nil, everyMinutes: nil, timesOfDay: ["21:00"], minMessages: 5))
        XCTAssertEqual(digest.processor.outputFormat, .structuredDigestJSON)
        XCTAssertEqual(digest.sinks, [.appFeed(id: "sink-feed", notifyDesktop: false)], "投递到动态流")

        let alert = PluginTemplates.featured(.keywordAlert, id: "k")
        XCTAssertEqual(alert.trigger, .realtime(keywords: PluginTemplates.defaultAlertKeywords, regex: nil, mentionSelfOnly: nil))
        XCTAssertEqual(alert.sinks, [.appFeed(id: "sink-feed", notifyDesktop: true)], "实时提醒带桌面通知")
        XCTAssertEqual(alert.scope.excludeSelf, true, "自己发的关键词不提醒自己")

        let briefing = PluginTemplates.featured(.dailyBriefing, id: "b")
        XCTAssertEqual(briefing.builtinTemplate, .dailyBriefing)
        XCTAssertEqual(briefing.trigger, .windowTime(cron: nil, everyMinutes: nil, timesOfDay: ["09:00"], minMessages: 1))
        XCTAssertEqual(briefing.processor.outputFormat, .markdown)
        XCTAssertTrue(briefing.processor.userPromptTemplate.contains("{{messages_markdown}}"))
        XCTAssertFalse(briefing.sinks.contains { if case .wechat = $0 { return true } else { return false } }, "模板不会默认向微信发信")
        XCTAssertEqual(Set(PluginTemplates.Featured.allCases.map(\.accessibilityId)).count, 3)
        XCTAssertEqual(PluginTemplates.Featured.dailyDigest.accessibilityId, "plugin-create-digest", "原生 UI 测试依赖的入口标识不变")
    }

    func testFeaturedTemplatesPreselectEnabledConversations() throws {
        let (workspace, _) = try makeWorkspace()
        seededSettings(workspace)
        var settings = workspace.settings.draft
        settings.conversations["wxid_off"] = ConversationPolicy(conversationId: "wxid_off", label: "停用", type: .direct, enabled: false)
        XCTAssertEqual(PluginTemplates.activeConversationIds(settings, for: .dailyDigest), ["g@chatroom"])
        XCTAssertEqual(PluginTemplates.activeConversationIds(settings, for: .keywordAlert), ["g@chatroom", "wxid_a"],
                       "服务号与未启用会话不预选")
        XCTAssertEqual(PluginTemplates.activeConversationIds(settings, for: .dailyBriefing), ["g@chatroom", "wxid_a"])

        let ids = PluginTemplates.activeConversationIds(settings, for: .keywordAlert)
        let config = PluginTemplates.featured(.keywordAlert, id: "k", conversationIds: ids, modelPresetId: "local")
        XCTAssertEqual(config.scope.conversationIds, ["g@chatroom", "wxid_a"])
        XCTAssertNil(config.scope.includeTypes, "已预选会话时不再类型通配")
        XCTAssertTrue(PluginForm(config).issues(presets: settings.models).isEmpty)
    }

    func testPluginListShowsFeaturedEntriesInLightAndDark() async throws {
        let (workspace, transport) = try makeWorkspace(connected: true)
        transport.results["plugins.list"] = "[]"
        try await workspace.plugins.refresh()
        let size = CGSize(width: ConsoleView.minimumSize.width - 200, height: ConsoleView.minimumSize.height)
        let light = try snapshot(PluginsView(workspace: workspace), appearance: .aqua, size: size)
        let dark = try snapshot(PluginsView(workspace: workspace), appearance: .darkAqua, size: size)
        XCTAssertNotEqual(light, dark)
    }

    // MARK: v2.2.0 通知出口向导（#8）

    private func webhookForm(_ platform: PluginSinkConfig.WebhookPlatform, url: String, secret: String = "") -> PluginForm {
        var form = PluginForm(PluginTemplates.featured(.dailyDigest, id: "p"))
        form.webhookOn = true
        form.webhookPlatform = platform
        form.webhookURL = url
        form.webhookSecret = secret
        return form
    }

    func testWebhookPlatformWizardValidatesPerPlatform() {
        let valid: [(PluginSinkConfig.WebhookPlatform, String, String)] = [
            (.generic, "https://hooks.example.com/x", ""),
            (.feishu, "https://open.feishu.cn/open-apis/bot/v2/hook/abc", ""),
            (.feishu, "https://open.larksuite.com/open-apis/bot/v2/hook/abc", "sign"),
            (.wecom, "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc", ""),
            (.telegram, "https://api.telegram.org/bot123456:ABC/sendMessage?chat_id=42", ""),
            (.notion, "https://api.notion.com/v1/blocks/abc123/children", "secret_x"),
        ]
        for (platform, url, secret) in valid {
            let form = webhookForm(platform, url: url, secret: secret)
            XCTAssertTrue(form.issues(presets: []).isEmpty, "\(platform.rawValue): \(form.issues(presets: []))")
            XCTAssertNotNil(form.webhookTestParams, platform.rawValue)
            guard case .webhook(_, _, let hasSecret, let encoded)? = form.build().sinks.last else { return XCTFail("缺少 webhook 出口") }
            XCTAssertEqual(encoded, platform == .generic ? nil : platform, "通用平台编码时省略 platform")
            XCTAssertEqual(hasSecret, !secret.isEmpty)
        }
        let invalid: [(PluginSinkConfig.WebhookPlatform, String, String)] = [
            (.feishu, "https://hooks.example.com/x", ""),
            (.wecom, "https://open.feishu.cn/x", ""),
            (.telegram, "https://api.telegram.org/sendMessage?chat_id=42", ""),
            (.telegram, "https://hooks.example.com/bot1:A/sendMessage", ""),
            (.notion, "https://api.notion.com/v1/blocks/abc123/children", ""),
            (.notion, "https://api.notion.com/v1/pages", "secret_x"),
            (.generic, "http://hooks.example.com/x", ""),
        ]
        for (platform, url, secret) in invalid {
            let form = webhookForm(platform, url: url, secret: secret)
            XCTAssertFalse(form.issues(presets: []).isEmpty, "\(platform.rawValue) \(url)")
            XCTAssertNil(form.webhookTestParams, "无效配置不能发送测试通知")
        }
        XCTAssertTrue(PluginSinkConfig.WebhookPlatform.allCases.allSatisfy { !$0.guidance.isEmpty && !$0.urlPrompt.isEmpty })

        // 平台往返：从已保存配置读回表单后不丢失所选平台。
        let saved = webhookForm(.wecom, url: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc").build()
        XCTAssertEqual(PluginForm(saved).webhookPlatform, .wecom)
        XCTAssertEqual(PluginForm(saved).build(), saved)
    }

    func testWebhookTestParamsCarryOnlyTypedSecret() {
        var form = webhookForm(.feishu, url: "https://open.feishu.cn/open-apis/bot/v2/hook/abc", secret: "new sign")
        var params = form.webhookTestParams
        XCTAssertEqual(params?.secret, "new sign", "新填写的密钥只随本次 IPC 帧发送")
        XCTAssertEqual(params?.platform, .feishu)
        XCTAssertEqual(params?.sinkId, form.webhookId)
        form.webhookSecret = ""
        form.hadSecret = true
        params = form.webhookTestParams
        XCTAssertNil(params?.secret, "留空时由引擎读取已存密钥")
        XCTAssertNotNil(params)
        form.webhookPlatform = .notion
        form.webhookURL = "https://api.notion.com/v1/blocks/abc123/children"
        form.removeSecret = true
        XCTAssertNil(form.webhookTestParams, "Notion 移除密钥后无法测试")

        XCTAssertEqual(WebhookTestResult(ok: true, statusCode: 200, detail: "").message, "测试通知已送达 · HTTP 200")
        XCTAssertEqual(WebhookTestResult(ok: false, detail: "连接超时").message, "测试通知发送失败 · 连接超时")
    }

    func testWebhookTestRoundTripsThroughClient() async throws {
        let (workspace, transport) = try makeWorkspace(connected: true)
        transport.results["plugins.testWebhook"] = #"{"detail":"签名校验失败","ok":false,"statusCode":403}"#
        let params = try XCTUnwrap(webhookForm(.feishu, url: "https://open.feishu.cn/open-apis/bot/v2/hook/abc", secret: "s").webhookTestParams)
        let result = try await workspace.runtime.client.pluginsTestWebhook(params)
        XCTAssertEqual(result, WebhookTestResult(ok: false, statusCode: 403, detail: "签名校验失败"))
        XCTAssertEqual(transport.params["plugins.testWebhook"]?["platform"] as? String, "feishu")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("secrets.json").path), "测试通知不写入凭据库")
    }

    func testWebhookWizardRendersPerPlatformInLightAndDark() throws {
        let size = CGSize(width: 640, height: 420)
        var shots: [PluginSinkConfig.WebhookPlatform: Data] = [:]
        for platform in PluginSinkConfig.WebhookPlatform.allCases {
            let view = Form {
                Section("反馈出口") {
                    WebhookSinkFields(form: .constant(webhookForm(platform, url: "")), ready: true) { _ in
                        WebhookTestResult(ok: true, statusCode: 200, detail: "")
                    }
                }
            }
            .formStyle(.grouped)
            let light = try snapshot(view, appearance: .aqua, size: size)
            XCTAssertNotEqual(light, try snapshot(view, appearance: .darkAqua, size: size), platform.rawValue)
            shots[platform] = light
        }
        XCTAssertEqual(Set(shots.values).count, shots.count, "不同平台展示不同的地址占位与鉴权说明")
    }

    // MARK: v2.2.0 记忆云端可见性（#6）

    func testMemoryVisibilitySummaryAndBulkTargets() {
        let rows = MemoryDocumentParser.parse(personaMarkdown)
        let summary = MemoryVisibilitySummary(rows: rows)
        XCTAssertEqual(summary, { var s = MemoryVisibilitySummary(rows: []); s.cloudSafe = 1; s.localOnly = 2; s.locked = 2; return s }())
        XCTAssertEqual(summary.text, "云端可用 1 条 · 仅本机 2 条 · 已锁定 2 条")
        XCTAssertEqual(MemoryVisibilitySummary.bulkTargets(rows, to: .cloudSafe), ["p_02"], "锁定条目与手写行不参与批量切换")
        XCTAssertEqual(MemoryVisibilitySummary.bulkTargets(rows, to: .localOnly), [], "已锁定的云端条目保持原状")

        let privateOnly = MemoryVisibilitySummary(rows: rows.filter { $0.visibility == .localOnly })
        XCTAssertEqual(privateOnly.cloudNotice(usesCloud: true), "当前没有设为云端可用的条目，云模型回复不会读取此档案。")
        XCTAssertNil(privateOnly.cloudNotice(usesCloud: false), "本机模型不需要提示")
        XCTAssertNil(summary.cloudNotice(usesCloud: true))
        XCTAssertNil(MemoryVisibilitySummary(rows: []).cloudNotice(usesCloud: true), "空档案不提示")
    }

    func testMemoryCloudModelDetection() throws {
        let (workspace, _) = try makeWorkspace()
        seededSettings(workspace)
        var settings = workspace.settings.draft
        XCTAssertFalse(MemoryVisibilitySummary.usesCloudModel(settings, target: .persona))
        XCTAssertFalse(MemoryVisibilitySummary.usesCloudModel(settings, target: .scope(conversationId: "wxid_a")))
        settings.conversations["wxid_a"]?.replyPresetId = "cloud"
        XCTAssertTrue(MemoryVisibilitySummary.usesCloudModel(settings, target: .scope(conversationId: "wxid_a")), "会话覆盖为云端模型")
        XCTAssertFalse(MemoryVisibilitySummary.usesCloudModel(settings, target: .scope(conversationId: "g@chatroom")))
        XCTAssertTrue(MemoryVisibilitySummary.usesCloudModel(settings, target: .persona), "人格档案被任一云端会话读取")
        settings.conversations["wxid_a"]?.replyPresetId = nil
        settings.defaultModels.replyPresetId = "cloud"
        XCTAssertTrue(MemoryVisibilitySummary.usesCloudModel(settings, target: .scope(conversationId: "g@chatroom")), "跟随云端主模型")
    }

    func testBulkVisibilityCallsEngineOncePerEntry() async throws {
        let (workspace, transport) = try makeWorkspace(connected: true)
        transport.results["memory.setEntryVisibility"] = #"{"createdAt":1764000000000,"diffPreview":"","revId":"rev-2","scopeKey":"global","snapshotPath":"/x/rev-2.md","source":"manual","summary":"可见性","targetKind":"persona"}"#
        let changed = try await workspace.memory.setEntriesVisibility(.persona, entryIds: ["p_02", "p_03"], visibility: .cloudSafe)
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(transport.methods.filter { $0 == "memory.setEntryVisibility" }.count, 2, "逐条调用，保留每一步的快照与撤销")
        XCTAssertEqual(transport.params["memory.setEntryVisibility"]?["visibility"] as? String, "cloud-safe")
        XCTAssertEqual(transport.params["memory.setEntryVisibility"]?["entryId"] as? String, "p_03")
    }

    func testMemoryVisibilityBarRendersInLightAndDark() async throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        try await workspace.memory.load(.persona)
        workspace.memorySection = .persona
        let size = CGSize(width: 780, height: 640)
        let light = try snapshot(MemoryView(workspace: workspace), appearance: .aqua, size: size)
        let dark = try snapshot(MemoryView(workspace: workspace), appearance: .darkAqua, size: size)
        XCTAssertNotEqual(light, dark)
        XCTAssertNotNil(workspace.memory.documents[.persona]?.text)
    }

    // MARK: v2.2.0 引用回复与 @ 成员（#7）

    func testReplyStyleHintFollowsCapabilities() throws {
        let none = ReplyStyleHint(capabilities: nil)
        XCTAssertEqual(none.nativeReply, "当前 X1a0HeWeChatPlugin 未开启引用回复能力，将按普通文本回复")
        XCTAssertNotNil(none.mentionSend)
        let caps = try JSONDecoder().decode(XiaoheCapabilities.self, from: Data(capabilitiesJSON.utf8))
        XCTAssertEqual(ReplyStyleHint(capabilities: caps), ReplyStyleHint(capabilities: caps))
        XCTAssertNil(ReplyStyleHint(capabilities: caps).nativeReply)
        XCTAssertNil(ReplyStyleHint(capabilities: caps).mentionSend)
        var partial = caps
        partial.mentionSend = false
        XCTAssertNil(ReplyStyleHint(capabilities: partial).nativeReply)
        XCTAssertNotNil(ReplyStyleHint(capabilities: partial).mentionSend)
    }

    func testReplyStyleTogglesWriteDraftAndRenderInLightAndDark() throws {
        let (workspace, _) = try makeWorkspace(connected: true)
        seededSettings(workspace)
        workspace.selectedConversationId = "g@chatroom"
        let size = CGSize(width: ConsoleView.minimumSize.width - 200, height: 1600)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            workspace.settings.draft.conversations["g@chatroom"]?.useNativeReply = false
            workspace.settings.draft.conversations["g@chatroom"]?.mentionReplySender = false
            let off = try snapshot(ConversationsView(workspace: workspace), appearance: appearance, size: size)
            workspace.settings.draft.conversations["g@chatroom"]?.useNativeReply = true
            workspace.settings.draft.conversations["g@chatroom"]?.mentionReplySender = true
            let on = try snapshot(ConversationsView(workspace: workspace), appearance: appearance, size: size)
            XCTAssertNotEqual(off, on, appearance.rawValue)
        }
        XCTAssertTrue(workspace.settings.hasUnsavedChanges, "开关走草稿，保存后才生效")
        let encoded = String(decoding: try IPCv3.encoder().encode(workspace.settings.draft), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""mentionReplySender":true"#))
        XCTAssertTrue(encoded.contains(#""useNativeReply":true"#))
    }

    // MARK: v2.2.0 远程热更新资产（#5）

    func testHotBundlesManifestValidation() {
        XCTAssertNil(HotBundlesRow.manifestIssue(""), "留空使用官方默认清单")
        XCTAssertNil(HotBundlesRow.manifestIssue(HotBundlesRow.officialManifestURL))
        XCTAssertNil(HotBundlesRow.manifestIssue("  https://mirror.example.com/bundles-manifest.json "))
        for bad in ["http://example.com/m.json", "ftp://example.com/m.json", "https://", "https://user:pw@example.com/m.json", "not a url"] {
            XCTAssertNotNil(HotBundlesRow.manifestIssue(bad), bad)
        }
    }

    func testHotBundlesRowSyncControlsRenderInLightAndDark() throws {
        let item = HotBundleItem(name: "policy.json", sha256: String(repeating: "a", count: 64), verified: true)
        let ok = HotBundlesStatus(loadedCount: 1, version: "2026.11.24", lastReloadAt: 1_764_000_000_000, items: [item])
        var bad = ok
        bad.items[0].verified = false
        func row(_ status: HotBundlesStatus?, url: String = "") -> some View {
            HotBundlesRow(status: status, busy: false, fault: nil, ready: true, reload: {},
                          manifestURL: .constant(url), sync: {}, reset: {}).frame(width: 560).padding()
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let base = try snapshot(row(ok), appearance: appearance, size: CGSize(width: 620, height: 360))
            XCTAssertNotEqual(base, try snapshot(row(bad), appearance: appearance, size: CGSize(width: 620, height: 360)), "未验证要有标签")
            XCTAssertNotEqual(base, try snapshot(row(ok, url: "http://insecure.example.com/m.json"), appearance: appearance,
                                                 size: CGSize(width: 620, height: 360)), "非 HTTPS 清单要提示")
        }
    }

    func testUpdateCardSyncAndResetCallEngine() async throws {
        let (workspace, transport) = try makeWorkspace(connected: true)
        let status = try await workspace.runtime.client.systemBundles(action: .sync, manifestUrl: HotBundlesRow.officialManifestURL)
        XCTAssertEqual(status.loadedCount, 1)
        XCTAssertEqual(transport.params["system.bundles"]?["action"] as? String, "sync")
        XCTAssertEqual(transport.params["system.bundles"]?["manifestUrl"] as? String, HotBundlesRow.officialManifestURL)
        _ = try await workspace.runtime.client.systemBundles(action: .reset)
        XCTAssertEqual(transport.params["system.bundles"]?["action"] as? String, "reset")
        XCTAssertNil(transport.params["system.bundles"]?["manifestUrl"])
    }

    func testModelPreviewDefaultSampleIsSafeCasualChat() {
        XCTAssertEqual(ModelPreviewCard.defaultSample, "下楼刚好碰上有太阳")
        XCTAssertFalse(ModelPreviewCard.defaultSample.contains("周末"))
        XCTAssertFalse(ModelPreviewCard.defaultSample.contains("吃饭"))
    }
}
