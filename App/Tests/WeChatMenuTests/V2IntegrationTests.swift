import Foundation
import XCTest
@testable import WeChatMenu

final class V2IntegrationTests: XCTestCase {
    @MainActor
    func testSwiftV2WorkspaceThroughBundledV3EngineEndToEnd() async throws {
        guard let enginePath = ProcessInfo.processInfo.environment["WMB_TEST_ENGINE"] else {
            throw XCTSkip("run bash scripts/selftest.sh")
        }
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WMB_TEST_TEMP"] ?? NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("wmb-v2-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        let disk = SettingsV2Disk(directory: dir)
        let workspace = V2Workspace(disk: disk, notifications: NoopNotifications())
        defer { workspace.runtime.stop() }

        try workspace.loadSettings()
        try workspace.runtime.start(engine: URL(fileURLWithPath: enginePath), directory: dir)
        try await waitUntil { workspace.runtime.ready }

        // 1. 下发多会话 v2 配置（含非 wxid 私聊、@chatroom 群聊、gh_ 服务号）
        workspace.settings.draft.xiaohe = .init(mcpUrl: "http://127.0.0.1:21454/mcp", accountId: "acc_e2e", accountLabel: "测试号")
        workspace.settings.draft.models = [
            ModelPreset(id: "local-chat", name: "本机模型", mode: .local, kind: .chat,
                        url: "http://127.0.0.1:11434/v1/chat/completions", modelName: "qwen3"),
        ]
        workspace.settings.draft.defaultModels.replyPresetId = "local-chat"
        workspace.settings.draft.defaultModels.pluginPresetId = "local-chat"
        workspace.addConversation(ConversationPolicy(conversationId: "custom_friend_01", label: "老号好友", type: .direct, enabled: true))
        workspace.addConversation(ConversationPolicy(conversationId: "dev_team@chatroom", label: "研发群", type: .group, enabled: true))
        workspace.addConversation(ConversationPolicy(conversationId: "gh_service_01", label: "推送服务号", type: .service, enabled: true))
        XCTAssertTrue(workspace.settings.hasUnsavedChanges)
        try await workspace.settings.save()
        XCTAssertFalse(workspace.settings.hasUnsavedChanges)

        // 2. 通过真实引擎保存声明式「群聊信息提炼与归集」插件并拉取验证
        let digest = DeclarativePluginConfig(
            id: "e2e-group-digest",
            name: "群聊信息提炼与归集",
            description: "端到端集成测试插件",
            enabled: false,
            builtinTemplate: .groupDigest,
            scope: .init(conversationIds: ["dev_team@chatroom"], includeTypes: [.group]),
            trigger: .windowTime(cron: nil, everyMinutes: 120, timesOfDay: ["12:30", "21:00"], minMessages: 5),
            processor: .init(modelPresetId: "local-chat", systemPrompt: "提炼群聊关键信息",
                             userPromptTemplate: "{{messages_markdown}}", outputFormat: .structuredDigestJSON,
                             skipWhenNoValue: true, maxInputChars: 24_000),
            sinks: [.appFeed(id: "feed-1", notifyDesktop: true),
                    .markdownFile(id: "md-1", directory: nil, filenameTemplate: "{{date}}-digest.md", mode: .append)],
            rateLimit: .init(maxRunsPerHour: 10, maxWeChatSendsPerDay: 20)
        )
        try await workspace.plugins.saveDeclarative(digest)
        try await workspace.plugins.refresh()
        XCTAssertTrue(workspace.plugins.plugins.contains { $0.pluginId == "e2e-group-digest" })

        // 3. 通过真实引擎读写 L3 人格并完成字节级版本回滚
        let v1Text = "## 表达风格\n- 简短自然，少客套。\n"
        let v2Text = "## 表达风格\n- 简短自然，少客套。\n- 尽量用口语短句。\n"
        _ = try await workspace.memory.save(.persona, text: v1Text)
        let savedV1 = try await workspace.memory.load(.persona)
        let rev2 = try await workspace.memory.save(.persona, text: v2Text)
        let savedV2 = try await workspace.memory.load(.persona)
        XCTAssertNotEqual(savedV1, savedV2)

        try await workspace.memory.loadRevisions(.persona)
        XCTAssertGreaterThanOrEqual(workspace.memory.revisions[.persona]?.count ?? 0, 2)
        _ = try await workspace.memory.rollback(.persona, revId: rev2.revId)
        let restored = try await workspace.memory.load(.persona)
        XCTAssertEqual(restored, savedV1)

        // 4. 全局紧急暂停应立即被真实 v3 引擎确认
        try await workspace.runtime.pauseAll(scope: .all, reason: .userPaused)
        try await waitUntil { workspace.runtime.globalPhase == .paused }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeFault("test-timeout") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class NoopNotifications: NotificationDelivering {
    func deliver(_ notification: FeedNotification) {}
}
