import AppKit
import SwiftUI

// MARK: - 导航路由

enum ConsoleTab: String, CaseIterable, Identifiable, Hashable {
    case overview, conversations, plugins, memory, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览与动态"
        case .conversations: return "会话与策略"
        case .plugins: return "后链路插件"
        case .memory: return "人格与记忆"
        case .settings: return "连接与设置"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .conversations: return "bubble.left.and.bubble.right"
        case .plugins: return "puzzlepiece.extension"
        case .memory: return "brain.head.profile"
        case .settings: return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "运行状态、异常恢复和插件产出"
        case .conversations: return "每个会话独立管理回复与风控"
        case .plugins: return "只读消息的提炼与归集"
        case .memory: return "人格档案、联系人专档与待审建议"
        case .settings: return "修改保存后才会生效"
        }
    }
}

enum MemorySection: String, CaseIterable, Identifiable, Hashable {
    case persona, scopes, proposals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .persona: return "通用人格 (L3)"
        case .scopes: return "联系人/群专档 (L2)"
        case .proposals: return "待审人格建议"
        }
    }
}

struct ConsoleRoute: Equatable {
    var tab: ConsoleTab
    var conversationId: String? = nil
    var pluginId: String? = nil
    var memorySection: MemorySection? = nil
    var proposalId: String? = nil
    var feedId: String? = nil

    // 动态卡片与系统通知共用同一张路由表，点击后落到同一位置。
    static func forFeed(kind: FeedItem.Kind, id: String, conversationId: String?, pluginId: String?, refPath: String?) -> Self {
        switch kind {
        case .pluginDigest:
            guard let pluginId else { return Self(tab: .overview, feedId: id) }
            return Self(tab: .plugins, pluginId: pluginId, feedId: id)
        case .personaProposal:
            return Self(tab: .memory, memorySection: .proposals, proposalId: refPath.map(proposalId(fromRef:)), feedId: id)
        case .memoryUpdated:
            guard let conversationId else { return Self(tab: .memory, memorySection: .persona, feedId: id) }
            return Self(tab: .memory, conversationId: conversationId, memorySection: .scopes, feedId: id)
        case .alert:
            if let conversationId { return Self(tab: .conversations, conversationId: conversationId, feedId: id) }
            if let pluginId { return Self(tab: .plugins, pluginId: pluginId, feedId: id) }
            return Self(tab: .overview, feedId: id)
        case .scheduleCancelled:
            guard let conversationId else { return Self(tab: .overview, feedId: id) }
            return Self(tab: .conversations, conversationId: conversationId, feedId: id)
        }
    }

    static func forFeed(_ item: FeedItem) -> Self {
        forFeed(kind: item.kind, id: item.id, conversationId: item.conversationId, pluginId: item.pluginId, refPath: item.refPath)
    }

    // refPath 可能是提案 ID，也可能是 proposals/<id>.json。
    private static func proposalId(fromRef value: String) -> String {
        guard value.hasSuffix(".json") else { return value }
        return ((value as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

struct OneShotRequest: Identifiable, Equatable {
    let conversationId: String
    var id: String { conversationId }
}

// 右键菜单发起、但必须回到详情页完成确认的开启请求。
struct GrantRequest: Equatable {
    let conversationId: String
    let mode: ArmReplyMode
}

// MARK: - 文案与状态

func v2Explanation(_ code: String) -> String {
    switch code {
    case "plugin-circuit-open": return "插件连续失败已熔断，请排查后重新启用。"
    case "plugin-limit": return "插件已达到运行或发信频率上限。"
    case "plugin-permission": return "插件权限未审批，或清单已变化，请重新确认权限。"
    case "plugin-timeout": return "插件运行超时，已中止。"
    case "event-gap": return "小禾事件缓存有缺口；核对身份后可建立新起点。"
    case "send-not-authorized": return "小禾未授权向这个会话发信，或尚未完成所需确认。"
    case "stopped": return "操作被暂停或设置变更打断，请重新确认。"
    case "turn-obsolete": return "这个操作已过期，请刷新后重试。"
    case "pin-limit": return "菜单栏最多置顶 \(PinnedConversations.limit) 个会话，请先取消一个。"
    default: return explanation(code)
    }
}

enum V2Format {
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    static func time(_ milliseconds: Int64) -> String {
        date(milliseconds).formatted(date: .abbreviated, time: .shortened)
    }

    static func clock(_ milliseconds: Int64) -> String {
        date(milliseconds).formatted(date: .omitted, time: .shortened)
    }

    // 轨迹需要秒级精度，且不随系统 12/24 小时制变化。
    static func clockWithSeconds(_ milliseconds: Int64) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date(milliseconds))
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    static func tail(_ id: String) -> String { id.count > 10 ? "…" + id.suffix(9) : id }
}

struct SessionPresentation: Equatable {
    enum Tone: Equatable { case neutral, active, warning, critical }

    let title: String
    let tone: Tone
    let isArmed: Bool
    let recovery: SessionRecoverAction?

    private static let armedPhases: Set<SessionRuntimeState.Phase> = [
        .connecting, .listening, .retrying, .generating, .scheduled, .checking, .sending, .cooldown,
    ]

    init(state: SessionRuntimeState?) {
        let phase = state?.phase ?? .idle
        let reason = state?.reason
        isArmed = state.map { $0.replyMode != .off && Self.armedPhases.contains($0.phase) } ?? false
        // 恢复动作的优先级与 SessionReplyBlocker 的门禁顺序一致。
        if phase == .lockedOptOut || reason == .peerStopped { recovery = .restoreConsent }
        else if phase == .blockedUnknown || reason == .sendUnknown { recovery = .acknowledge }
        else if let reason, ReplyBlocker.blockedRead.contains(reason.rawValue) { recovery = .resetRead }
        else { recovery = nil }

        switch phase {
        case .idle: title = "未开启"; tone = .neutral
        case .connecting: title = "连接中"; tone = .active
        case .listening:
            title = state?.replyMode == .draft ? "只拟稿中" : state?.replyMode == .auto ? "自动回复中" : "监听中"
            tone = .active
        case .retrying: title = "重连中"; tone = .warning
        case .generating: title = "生成中"; tone = .active
        case .scheduled: title = "已排定单次发送"; tone = .active
        case .checking: title = "发送前核对"; tone = .active
        case .sending: title = "提交中"; tone = .active
        case .paused: title = "已暂停"; tone = recovery == nil ? .neutral : .warning
        case .cooldown: title = "静默冷却"; tone = .warning
        case .blockedUnknown: title = "提交结果未知"; tone = .critical
        case .lockedOptOut: title = "对方已叫停"; tone = .critical
        }
    }

    static func recoveryTitle(_ action: SessionRecoverAction) -> String {
        switch action {
        case .acknowledge: return "已在微信核对，不重发"
        case .restoreConsent: return "对方重新同意后恢复"
        case .resetRead: return "核对身份并建立新起点"
        }
    }

    static func recoveryDetail(_ action: SessionRecoverAction) -> String {
        switch action {
        case .acknowledge: return "仅解除这个会话的未知提交阻塞，不会重试原消息。请先在微信确认原消息的实际状态。"
        case .restoreConsent: return "仅在对方已明确重新同意时使用。此操作不会直接开启自动回复或发送。"
        case .resetRead: return "确认账号和会话仍正确。旧事件不会被回复，恢复后需重新开启。"
        }
    }
}

struct RuntimeStatusPresentation: Equatable {
    let title: String
    let tone: SessionPresentation.Tone

    init(ready: Bool, starting: Bool, phase: GlobalPhase) {
        guard ready else {
            title = starting ? "正在启动" : "后台未就绪"
            tone = .warning
            return
        }
        switch phase {
        case .idle: title = "空闲"; tone = .neutral
        case .connecting: title = "连接中"; tone = .active
        case .running: title = "运行中"; tone = .active
        case .paused: title = "已暂停"; tone = .warning
        case .error: title = "异常"; tone = .critical
        }
    }
}

// hello 之后、首个 global.updated 之前没有全局计数，用会话和插件状态推算。
struct RuntimeCounts: Equatable {
    let activeAuto: Int
    let activePlugins: Int
    let inFlight: Int

    init(global: GlobalRuntimeState?, sessions: [String: SessionRuntimeState], plugins: [String: PluginRuntimeState]) {
        activeAuto = global?.activeAutoCount
            ?? sessions.values.filter { $0.replyMode == .auto && SessionPresentation(state: $0).isArmed }.count
        activePlugins = global?.activePluginCount ?? plugins.values.filter { $0.enabled && !$0.circuitOpen }.count
        inFlight = global?.inFlightCount ?? sessions.values.filter { $0.phase == .checking || $0.phase == .sending }.count
    }
}

enum PinnedConversations {
    static let limit = 4

    // 超过上限时返回 nil，由界面提示，不静默挤掉已有置顶。
    static func toggled(_ list: [String], id: String) -> [String]? {
        if list.contains(id) { return list.filter { $0 != id } }
        return list.count < limit ? list + [id] : nil
    }
}

// 记录用户审批过的清单哈希，用来发现磁盘上的代码插件被改动。只存哈希，不含敏感内容。
final class PluginReviewLedger {
    private static let key = "v2.pluginReviewedManifestHashes"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func reviewedHash(pluginId: String) -> String? {
        (defaults.dictionary(forKey: Self.key) as? [String: String])?[pluginId]
    }

    func record(pluginId: String, hash: String) {
        var all = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        all[pluginId] = hash
        defaults.set(all, forKey: Self.key)
    }
}

// MARK: - 根容器

@MainActor
final class V2Workspace: ObservableObject {
    let runtime: BridgeRuntime
    let settings: SettingsStore
    let sessions: SessionsStore
    let plugins: PluginsStore
    let memory: MemoryStore
    let feed: FeedStore
    let vault: KeychainVault
    let reviewLedger: PluginReviewLedger
    let updater: AppUpdater
    // 档案原文草稿放在视图之外，切换分栏或目标时不丢失。
    let memoryDrafts = MemoryDraftBuffer()

    @Published var tab: ConsoleTab = .overview
    @Published var memorySection: MemorySection = .persona
    @Published var selectedConversationId: String?
    @Published var selectedMemoryConversationId: String?
    @Published var selectedPluginId: String?
    @Published var selectedProposalId: String?
    @Published var highlightedFeedId: String?
    @Published var oneShotRequest: OneShotRequest?
    @Published var fault: String?
    @Published var closeConfirmationVisible = false
    @Published var feedbackPresented = false
    @Published var healthCheckRequested = false
    @Published var pendingGrant: GrantRequest?
    @Published var updateSectionRequested = false

    // 由窗口层注入：气泡和通知跳转时负责把控制台提到前台。
    var presentConsole: () -> Void = {}
    private var pendingClose: (() -> Void)?

    init(runtime: BridgeRuntime? = nil, disk: SettingsV2Disk = .standard, vault: KeychainVault = .standard,
         notifications: NotificationDelivering? = nil, reviewLedger: PluginReviewLedger = PluginReviewLedger(),
         updater: AppUpdater? = nil) {
        let runtime = runtime ?? BridgeRuntime()
        let settings = SettingsStore(runtime: runtime, disk: disk, vault: vault)
        self.runtime = runtime
        self.settings = settings
        self.vault = vault
        self.reviewLedger = reviewLedger
        self.updater = updater ?? AppUpdater()
        sessions = SessionsStore(runtime: runtime, settings: settings, vault: vault)
        plugins = PluginsStore(runtime: runtime, vault: vault)
        memory = MemoryStore(runtime: runtime, stateDirectory: disk.directory,
                             memoryBaseDirectory: { [weak settings] in settings?.saved.memory.baseDir ?? "" })
        feed = FeedStore(runtime: runtime, notifications: notifications)
        self.updater.installGate = { [weak self] in self?.updateInstallBlocker }
    }

    // MARK: 路由

    func open(_ route: ConsoleRoute) {
        tab = route.tab
        if let section = route.memorySection { memorySection = section }
        if route.tab == .conversations, let id = route.conversationId { selectedConversationId = id }
        if route.tab == .memory, let id = route.conversationId { selectedMemoryConversationId = id }
        if let id = route.pluginId { selectedPluginId = id }
        if let id = route.proposalId { selectedProposalId = id }
        highlightedFeedId = route.feedId
        presentConsole()
    }

    func open(tab: ConsoleTab) { open(ConsoleRoute(tab: tab)) }

    func open(feedItem item: FeedItem) {
        open(ConsoleRoute.forFeed(item))
        guard !item.read else { return }
        run { [feed] in try await feed.markRead(ids: [item.id]) }
    }

    // 系统通知只携带 FeedNotification 的字段；提案引用从已加载的动态流补齐。
    @discardableResult
    func openNotification(userInfo: [AnyHashable: Any]) -> Bool {
        guard let id = userInfo["feedId"] as? String, let raw = userInfo["kind"] as? String,
              let kind = FeedItem.Kind(rawValue: raw) else { return false }
        let known = feed.items.first { $0.id == id }
        open(ConsoleRoute.forFeed(kind: kind, id: id, conversationId: userInfo["conversationId"] as? String,
                                  pluginId: userInfo["pluginId"] as? String, refPath: known?.refPath))
        if known?.read == false { run { [feed] in try await feed.markRead(ids: [id]) } }
        return true
    }

    func requestOneShot(_ conversationId: String) {
        open(ConsoleRoute(tab: .conversations, conversationId: conversationId))
        oneShotRequest = OneShotRequest(conversationId: conversationId)
    }

    func openFeedback() {
        feedbackPresented = true
        presentConsole()
    }

    // 由设置页的体检区消费，保证工具栏入口和页内按钮走同一条执行路径。
    func requestHealthCheck() {
        healthCheckRequested = true
        open(tab: .settings)
    }

    // 由设置页消费并滚动到更新区。
    func openUpdates() {
        updateSectionRequested = true
        open(tab: .settings)
    }

    func checkForUpdatesIfDue() async {
        guard !NativeQA.active else { return }
        await updater.checkIfDue()
    }

    // 重启会打断提交中的消息并丢弃未保存的草稿，这两种情况要等用户处理完。
    private var updateInstallBlocker: String? {
        if settings.hasUnsavedChanges { return "请先保存或放弃设置修改，再重启更新。" }
        let counts = RuntimeCounts(global: runtime.global, sessions: sessions.sessions, plugins: plugins.states)
        return counts.inFlight > 0 ? "有消息正在提交，请等提交结束后再重启更新。" : nil
    }

    // MARK: 动作

    func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor [weak self] in
            do { try await action() }
            catch { self?.capture(error) }
        }
    }

    func capture(_ error: Error) { fault = Self.code(error) }

    nonisolated static func code(_ error: Error) -> String { (error as? BridgeFault)?.code ?? "internal-error" }

    // 只由应用入口调用：读取设置可能把 v1 文件迁移成 v2，视图不能隐式触发。
    func loadSettings() throws { try settings.load() }

    func refreshAll() async {
        guard runtime.ready else { return }
        let steps: [@MainActor () async throws -> Void] = [
            { [settings] in try await settings.syncApprovedCloudKeys() },
            { [sessions] in try await sessions.refreshAccount() },
            { [runtime, settings] in
                guard !settings.saved.xiaohe.mcpUrl.isEmpty else { return }
                try await runtime.refreshCapabilities()
            },
            { [feed] in try await feed.refresh() },
            { [plugins] in try await plugins.refresh() },
            { [memory] in try await memory.loadProposals() },
        ]
        // 单项失败不阻断其他数据加载。
        for step in steps {
            do { try await step() } catch { capture(error) }
        }
    }

    func saveSettings() async throws {
        try await settings.save()
        // 设置已生效；账号或能力刷新失败不能误报为保存失败。
        try? await sessions.refreshAccount()
        if !settings.saved.xiaohe.mcpUrl.isEmpty {
            _ = try? await runtime.refreshCapabilities()
        }
    }

    func pauseAllSending() {
        run { [runtime] in try await runtime.pauseAll(scope: .sendingOnly) }
    }

    func pauseEverything() {
        run { [runtime] in try await runtime.pauseAll(scope: .all) }
    }

    func togglePin(_ conversationId: String) {
        guard let next = PinnedConversations.toggled(settings.draft.runtime.pinnedConversationIds, id: conversationId) else {
            fault = "pin-limit"
            return
        }
        settings.draft.runtime.pinnedConversationIds = next
    }

    // MARK: 开启回复

    private func replyPreset(for conversationId: String) -> ModelPreset? {
        let saved = settings.saved
        return saved.preset(saved.conversations[conversationId]?.replyPresetId ?? saved.defaultModels.replyPresetId)
    }

    // 本机模型或已统一授权的云模型可一键开启，其余情况必须走确认表单。
    func canFastArm(_ conversationId: String) -> Bool {
        guard let preset = replyPreset(for: conversationId) else { return false }
        return preset.mode == .local || settings.saved.runtime.approvedCloudPresetIds.contains(preset.id)
    }

    func fastArm(_ conversationId: String, mode: ArmReplyMode) {
        let sessions = sessions
        let isCloud = replyPreset(for: conversationId)?.mode == .cloud
        let isGroup = settings.saved.conversations[conversationId]?.type == .group
        run { try await sessions.arm(conversationId, mode: mode, consent: true, cloudApproved: isCloud, groupConfirmed: isGroup) }
    }

    func quickArm(_ conversationId: String, mode: ArmReplyMode) {
        if canFastArm(conversationId) {
            fastArm(conversationId, mode: mode)
        } else {
            pendingGrant = GrantRequest(conversationId: conversationId, mode: mode)
            open(ConsoleRoute(tab: .conversations, conversationId: conversationId))
        }
    }

    func addConversation(_ policy: ConversationPolicy) {
        sessions.upsertPolicy(policy)
        selectedConversationId = policy.conversationId
    }

    func removeConversation(_ conversationId: String) {
        settings.draft.conversations[conversationId] = nil
        settings.draft.runtime.pinnedConversationIds.removeAll { $0 == conversationId }
        if selectedConversationId == conversationId { selectedConversationId = nil }
    }

    // 跟随主模型的场景保持为空；显式指向旧主模型的场景也回到跟随，避免切换后悄悄分叉。
    func setPrimaryModel(_ presetId: String?) {
        var models = settings.draft.defaultModels
        let previous = models.replyPresetId
        guard presetId != previous else { return }
        let followers: [WritableKeyPath<SettingsV2.DefaultModels, String?>] = [\.pluginPresetId, \.memoryPresetId, \.visionPresetId]
        for path in followers where models[keyPath: path] == previous { models[keyPath: path] = nil }
        models.replyPresetId = presetId
        settings.draft.defaultModels = models
    }

    // 引擎按用途校验预设类型；预设改类型后清掉不再匹配的默认项和会话引用。
    func upsertPreset(_ preset: ModelPreset) {
        settings.upsertPreset(preset)
        if preset.kind != .chat {
            if settings.draft.defaultModels.replyPresetId == preset.id { settings.draft.defaultModels.replyPresetId = nil }
            if settings.draft.defaultModels.fallbackReplyPresetId == preset.id { settings.draft.defaultModels.fallbackReplyPresetId = nil }
            if settings.draft.defaultModels.pluginPresetId == preset.id { settings.draft.defaultModels.pluginPresetId = nil }
            if settings.draft.defaultModels.memoryPresetId == preset.id { settings.draft.defaultModels.memoryPresetId = nil }
            for key in settings.draft.conversations.keys where settings.draft.conversations[key]?.replyPresetId == preset.id {
                settings.draft.conversations[key]?.replyPresetId = nil
            }
        }
        // 对齐引擎 supportsModelKind：对话模型也能理解图片，只有语音转写预设不能。
        if preset.kind == .stt, settings.draft.defaultModels.visionPresetId == preset.id {
            settings.draft.defaultModels.visionPresetId = nil
        }
        if preset.kind != .stt, settings.draft.defaultModels.sttPresetId == preset.id {
            settings.draft.defaultModels.sttPresetId = nil
        }
    }

    // MARK: 关闭保护

    // 窗口委托在 windowShouldClose 中调用。返回 false 时由控制台弹窗决定保存或放弃。
    func requestClose(_ close: @escaping () -> Void) -> Bool {
        guard settings.hasUnsavedChanges else { return true }
        pendingClose = close
        closeConfirmationVisible = true
        return false
    }

    func resolveClose(save: Bool) {
        let close = pendingClose
        pendingClose = nil
        closeConfirmationVisible = false
        guard save else {
            settings.discardChanges()
            close?()
            return
        }
        run { [weak self] in
            try await self?.saveSettings()
            close?()
        }
    }

    func cancelClose() {
        pendingClose = nil
        closeConfirmationVisible = false
    }
}
