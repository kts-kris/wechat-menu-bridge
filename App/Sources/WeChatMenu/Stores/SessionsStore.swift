import Foundation

enum SessionAction: Equatable, Sendable { case draft, auto, oneShot }

// 单会话门禁：只读取该会话自身的状态，其他会话的故障不会进入判断。
enum SessionReplyBlocker: Equatable {
    case backend, peerStopped, sendUnknown, inFlight, savingSettings, unsavedSettings, authorizing
    case notManaged, notEnabled, serviceUnavailable, running, oneShotPending, cooldown
    case read(String), capabilityMissing, accountUnverified, sendNotAuthorized, model, groupUnconfirmed

    struct Input {
        var ready: Bool
        var action: SessionAction
        var policy: ConversationPolicy?
        var state: SessionRuntimeState?
        var capabilities: XiaoheCapabilities?
        var account: XiaoheAccountOption?
        var modelReady: Bool
        var authorizing: Bool
        var savingSettings: Bool
        var unsavedSettings: Bool
        var groupConfirmed: Bool
    }

    static func evaluate(_ input: Input) -> Self? {
        guard input.ready else { return .backend }
        let phase = input.state?.phase ?? .idle
        let reason = input.state?.reason
        if phase == .lockedOptOut || reason == .peerStopped { return .peerStopped }
        if phase == .blockedUnknown || reason == .sendUnknown || input.state?.receipt?.status == .unknown { return .sendUnknown }
        if phase == .checking || phase == .sending || input.state?.receipt?.status == .trying { return .inFlight }
        if input.savingSettings { return .savingSettings }
        if input.unsavedSettings { return .unsavedSettings }
        if input.authorizing { return .authorizing }
        guard let policy = input.policy else { return .notManaged }
        if policy.type == .service { return .serviceUnavailable }
        let sends = input.action != .draft

        if input.action == .oneShot {
            // 单次发送只与本会话正在提交或已排定的发信互斥。
            if phase == .scheduled { return .oneShotPending }
        } else {
            guard policy.enabled else { return .notEnabled }
            if phase == .cooldown { return .cooldown }
            if [.connecting, .listening, .retrying, .generating, .scheduled].contains(phase) { return .running }
            if let reason, ReplyBlocker.blockedRead.contains(reason.rawValue) { return .read(reason.rawValue) }
        }
        if sends {
            guard input.capabilities?.canSendText == true else { return .capabilityMissing }
            guard let account = input.account else { return .accountUnverified }
            guard account.maySend(to: policy.conversationId) else { return .sendNotAuthorized }
        }
        if input.action != .oneShot && !input.modelReady { return .model }
        if sends && policy.type == .group && !input.groupConfirmed { return .groupUnconfirmed }
        return nil
    }

    var guidance: String {
        switch self {
        case .backend: return "后台尚未就绪，请稍候；如后台已退出，请重启后台。"
        case .peerStopped: return "对方已要求停止，只有确认对方重新同意后才能恢复。"
        case .sendUnknown: return "上次提交结果未知，请先在微信核对，再解除阻塞。"
        case .inFlight: return "这个会话的上一条提交尚未返回，请等待结果。"
        case .savingSettings: return "设置正在保存，请稍候。"
        case .unsavedSettings: return "设置页有未保存修改，请先保存。"
        case .authorizing: return "正在准备这个会话的另一项操作，请稍候。"
        case .notManaged: return "请先把这个会话加入管理列表。"
        case .notEnabled: return "请先在会话策略中启用监听。"
        case .serviceUnavailable: return "服务号不支持拟稿和发信，只能用于信息归集。"
        case .running: return "这个会话已在运行，请先暂停。"
        case .oneShotPending: return "这个会话已有待提交的定时消息，请先取消定时发送。"
        case .cooldown: return "这个会话正在静默冷却，到期后恢复，或先手动暂停。"
        case .read(let reason): return explanation(reason)
        case .capabilityMissing: return "当前小禾连接不具备发信能力。"
        case .accountUnverified: return "尚未核验小禾账号的发信权限，请先刷新账号。"
        case .sendNotAuthorized: return "小禾未授权向这个会话发信。"
        case .model: return "请为这个会话选择有效的回复模型。手写单条不需要模型。"
        case .groupUnconfirmed: return "向群聊发信需要二次风险确认。"
        }
    }
}

@MainActor
final class SessionsStore: ObservableObject, BridgeEventConsumer {
    @Published private(set) var sessions: [String: SessionRuntimeState] = [:]
    @Published private(set) var backfills: [String: BackfillProgress] = [:]
    // 每会话最多 40 条，最新在前。
    @Published private(set) var traces: [String: [SessionTraceEntry]] = [:]
    @Published private(set) var authorizing: Set<String> = []
    @Published private(set) var account: XiaoheAccountOption?

    private let runtime: BridgeRuntime
    private let settings: SettingsStore
    private let vault: KeychainVault
    private var tokens: [String: UUID] = [:]

    static let maxTraces = 40

    init(runtime: BridgeRuntime, settings: SettingsStore, vault: KeychainVault = .standard) {
        self.runtime = runtime
        self.settings = settings
        self.vault = vault
        runtime.register(self)
    }

    // MARK: 推送

    func apply(_ event: PushEvent) {
        switch event {
        case .hello(let payload): sessions = payload.status.sessions
        case .sessionUpdated(let update): sessions[update.conversationId] = update.status
        case .backfillProgress(let progress): backfills[progress.jobId] = progress
        case .sessionTrace(let entry): mergeTraces([entry], for: entry.conversationId)
        default: break
        }
    }

    func bridgeDisconnected() {
        sessions = [:]
        backfills = [:]
        traces = [:]
        tokens = [:]
        authorizing = []
        account = nil
    }

    // MARK: 门禁

    func blocker(for conversationId: String, action: SessionAction, groupConfirmed: Bool = false) -> SessionReplyBlocker? {
        gate(conversationId, action, groupConfirmed: groupConfirmed, authorizing: authorizing.contains(conversationId))
    }

    private func gate(_ conversationId: String, _ action: SessionAction, groupConfirmed: Bool, authorizing: Bool) -> SessionReplyBlocker? {
        let saved = settings.saved
        let policy = saved.conversations[conversationId]
        // 换账号后，旧账号的发信权限不能继续生效。
        let verified = account?.id == saved.xiaohe.accountId ? account : nil
        return SessionReplyBlocker.evaluate(.init(
            ready: runtime.ready, action: action, policy: policy, state: sessions[conversationId],
            capabilities: runtime.capabilities, account: verified,
            modelReady: policy.flatMap(replyPreset) != nil, authorizing: authorizing,
            savingSettings: settings.saving, unsavedSettings: settings.hasUnsavedChanges, groupConfirmed: groupConfirmed))
    }

    private func replyPreset(_ policy: ConversationPolicy) -> ModelPreset? {
        let saved = settings.saved
        guard let preset = saved.preset(policy.replyPresetId ?? saved.defaultModels.replyPresetId),
              preset.kind == .chat, !preset.modelName.isEmpty else { return nil }
        return preset
    }

    private func require(_ conversationId: String, _ action: SessionAction, groupConfirmed: Bool) throws {
        if let blocker = blocker(for: conversationId, action: action, groupConfirmed: groupConfirmed) {
            throw BridgeFault(Self.code(for: blocker))
        }
    }

    private static func code(for blocker: SessionReplyBlocker) -> String {
        switch blocker {
        case .backend: return "engine-not-ready"
        case .peerStopped: return "peer-stopped"
        case .sendUnknown: return "send-unknown"
        case .sendNotAuthorized, .capabilityMissing, .accountUnverified: return "send-not-authorized"
        case .read(let reason): return reason
        case .inFlight, .savingSettings, .authorizing, .running, .oneShotPending, .cooldown: return "busy"
        default: return "invalid-configuration"
        }
    }

    // MARK: 账号与策略

    func refreshAccount() async throws {
        let value = settings.saved.xiaohe
        guard !value.mcpUrl.isEmpty else {
            account = nil
            return
        }
        try NativeQA.checkMCP(value.mcpUrl)
        let rows = try await runtime.client.xiaoheAccounts(mcpUrl: value.mcpUrl)
        account = rows.first { $0.id == value.accountId }
    }

    // 只写入草稿；保存时由 settings.apply 按差异重载受影响的会话。
    func updatePolicy(_ conversationId: String, _ change: (inout ConversationPolicy) -> Void) {
        guard var policy = settings.draft.conversations[conversationId] else { return }
        change(&policy)
        policy.conversationId = conversationId
        settings.draft.conversations[conversationId] = policy
    }

    func upsertPolicy(_ policy: ConversationPolicy) {
        settings.draft.conversations[policy.conversationId] = policy
    }

    // MARK: 单会话控制

    func arm(_ conversationId: String, mode: ArmReplyMode, consent: Bool, cloudApproved: Bool = false,
             groupConfirmed: Bool = false) async throws {
        guard consent else { throw BridgeFault("invalid-configuration") }
        let action: SessionAction = mode == .auto ? .auto : .draft
        try require(conversationId, action, groupConfirmed: groupConfirmed)
        let snapshot = settings.saved
        guard let policy = snapshot.conversations[conversationId], let preset = replyPreset(policy) else {
            throw BridgeFault("invalid-configuration")
        }
        // 先判同意：未确认的云端请求不读钥匙串。
        guard preset.mode != .cloud || cloudApproved else { throw BridgeFault("cloud-not-approved") }

        let token = UUID(), revision = runtime.pauseRevision
        tokens[conversationId] = token
        authorizing.insert(conversationId)
        defer {
            if tokens[conversationId] == token {
                tokens[conversationId] = nil
                authorizing.remove(conversationId)
            }
        }
        var key: String?
        if preset.mode == .cloud {
            let storage = vault
            let entry = try KeychainEntry.model(endpoint: preset.url, kind: preset.kind)
            key = try await Task.detached(priority: .userInitiated) { try storage.read(entry) }.value
        }
        // 读钥匙串可能等待系统授权；期间暂停、休眠或改配置都使这次授权作废。
        guard tokens[conversationId] == token, revision == runtime.pauseRevision, settings.saved == snapshot else {
            throw BridgeFault("stopped")
        }
        // 等待期间会话可能已被叫停或进入未知发送，必须按最新状态再判一次。
        if let blocker = gate(conversationId, action, groupConfirmed: groupConfirmed, authorizing: false) {
            throw BridgeFault(Self.code(for: blocker))
        }
        try await runtime.client.sessionArm(.init(
            conversationId: conversationId, replyMode: mode, cloudApproved: preset.mode == .cloud ? true : nil,
            groupConfirmed: policy.type == .group && mode == .auto ? true : nil, apiKey: key))
    }

    func pause(_ conversationId: String, reason: IPCErrorCode = .userPaused) async throws {
        tokens[conversationId] = nil
        authorizing.remove(conversationId)
        try await runtime.client.sessionPause(conversationId: conversationId, reason: reason)
    }

    // 每次调用生成新的 request，失败后绝不自动重发。
    func sendOneShot(_ conversationId: String, text: String, at: Date? = nil, consent: Bool,
                     groupConfirmed: Bool = false) async throws {
        guard consent else { throw BridgeFault("invalid-configuration") }
        try require(conversationId, .oneShot, groupConfirmed: groupConfirmed)
        guard let body = Self.sendableText(text) else { throw BridgeFault("invalid-configuration") }
        let isGroup = settings.saved.conversations[conversationId]?.type == .group
        try await runtime.client.sessionSendOneShot(.init(
            conversationId: conversationId, text: body, request: UUID().uuidString, at: at.map(epoch),
            groupConfirmed: isGroup ? true : nil))
    }

    // 单次发信的文本约束：去首尾空白后 1...500 个 UTF-16 单元，且不含控制字符。
    static func sendableText(_ text: String) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...500).contains(body.utf16.count),
              !body.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return body
    }

    func refreshReceipt(_ conversationId: String) async throws {
        let receipt = try await runtime.client.sessionRefreshReceipt(conversationId: conversationId)
        sessions[conversationId]?.receipt = receipt
    }

    func recover(_ conversationId: String, action: SessionRecoverAction) async throws {
        try await runtime.client.sessionRecover(conversationId: conversationId, action: action)
    }

    // MARK: 运行轨迹与冷静期

    func loadTraces(for conversationId: String) async throws {
        let items = try await runtime.client.sessionTraces(conversationId: conversationId, limit: Self.maxTraces)
        mergeTraces(items.filter { $0.conversationId == conversationId }, for: conversationId)
    }

    // 推送可能早于响应到达，这里按 id 合并而不是整体覆盖。
    private func mergeTraces(_ incoming: [SessionTraceEntry], for conversationId: String) {
        var seen = Set<String>()
        let merged = (incoming + (traces[conversationId] ?? []))
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.at > $1.at }
        traces[conversationId] = Array(merged.prefix(Self.maxTraces))
    }

    // 恢复后的会话状态由 session.updated 推送带回。
    @discardableResult
    func resumeCooldown(_ conversationId: String) async throws -> Bool {
        try await runtime.client.sessionResumeCooldown(conversationId: conversationId)
    }

    @discardableResult
    func startBackfill(_ request: BackfillRequest) async throws -> String {
        guard request.isValid else { throw BridgeFault("invalid-configuration") }
        let job = try await runtime.client.sessionBackfill(.start(request))
        // 进度推送可能早于响应到达，不能覆盖已有进度。
        if backfills[job.jobId] == nil {
            backfills[job.jobId] = BackfillProgress(jobId: job.jobId, conversationId: request.conversationId, fetched: 0, done: false)
        }
        return job.jobId
    }

    func cancelBackfill(jobId: String) async throws {
        _ = try await runtime.client.sessionBackfill(.cancel(jobId: jobId))
    }
}
