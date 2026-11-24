import SwiftUI

// MARK: - 会话目录规则

enum ConversationCatalog {
    // 对齐 Engine/src/mcp/ingest.ts 的 conversationType；引擎按此校验策略类型。
    static func engineType(for id: String) -> ScopeType {
        id.hasSuffix("@chatroom") ? .group : id.hasPrefix("gh_") ? .service : .direct
    }

    // 小禾类型与 ID 规则不一致时不纳管：写入会使整份设置被拒，按私聊处理还可能向服务号发信。
    static func managedType(_ row: XiaoheConversation) -> ScopeType? {
        row.type == engineType(for: row.conversationId) ? row.type : nil
    }

    static func makePolicy(_ row: XiaoheConversation) -> ConversationPolicy? {
        guard let type = managedType(row) else { return nil }
        return ConversationPolicy(conversationId: row.conversationId, label: row.displayName, type: type, enabled: true,
                                  replyMode: .off, groupTrigger: .mentionOnly, memoryEnabled: type == .direct)
    }

    static func sendPermission(_ conversationId: String, account: XiaoheAccountOption?) -> (text: String, tone: SessionPresentation.Tone) {
        guard let account else { return ("尚未核验小禾发信权限", .warning) }
        guard account.canSend else { return ("当前账号没有发信权限", .warning) }
        guard let list = account.sendConversations else { return ("账号级发信权限", .neutral) }
        if list.contains("*") { return ("小禾已放行全部会话发信", .active) }
        return list.contains(conversationId) ? ("在小禾发信白名单内", .active) : ("不在小禾发信白名单内", .warning)
    }
}

extension SessionTraceEntry.Stage {
    var title: String {
        switch self {
        case .inbound: return "来信"
        case .policy: return "策略"
        case .model: return "模型"
        case .send: return "发信"
        case .state: return "状态"
        }
    }
}

extension SessionTraceEntry.Level {
    var title: String {
        switch self {
        case .info: return "信息"
        case .warn: return "警告"
        case .error: return "错误"
        }
    }

    var color: Color {
        switch self {
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }
}

extension RiskProfile.TakeoverAction {
    // 只有静默冷却才需要配置时长。
    var usesCooldownDuration: Bool { self == .cooldown }
}

extension RiskProfile.Level {
    var title: String {
        switch self {
        case .recommended: return "日常推荐"
        case .strict: return "严格"
        case .minimal: return "极简"
        }
    }

    var detail: String {
        switch self {
        case .recommended: return "命中资金、凭据、隐私等高风险规则的来信不进入回复模型；其他一般内容由模型判断。"
        case .strict: return "来信或草稿命中保守规则、模型建议转人工、刷屏或媒体无法解析时，暂停会话。"
        case .minimal: return "来信主要交由模型判断，敏感来信也可能发给所选模型。叫停、身份披露和防重发仍生效。"
        }
    }
}

// 列表和菜单栏共用的紧凑状态：蓝=自动回复、青=拟稿、橙=冷静期、红=需处理、灰=未开启。
enum ConversationStatusDot: Equatable {
    case autoReply, drafting, cooldown, attention, off

    init(state: SessionRuntimeState?) {
        let presentation = SessionPresentation(state: state)
        if presentation.recovery != nil { self = .attention }
        else if state?.phase == .cooldown { self = .cooldown }
        else if presentation.isArmed { self = state?.replyMode == .draft ? .drafting : .autoReply }
        else { self = .off }
    }

    var color: Color {
        switch self {
        case .autoReply: return .blue
        case .drafting: return .cyan
        case .cooldown: return .orange
        case .attention: return .red
        case .off: return .gray
        }
    }
}

enum CooldownPresentation {
    static func notice(until: Int64?) -> String {
        guard let until else { return "本人刚插话，当前处于冷静期，到期后自动恢复监听。" }
        return "本人刚插话，当前处于冷静期，自动回复暂停至 \(V2Format.clockWithSeconds(until))，到期后自动恢复监听。"
    }
}

// 记录某份草稿最近一次一键发送的结果。
struct DraftSendOutcome: Equatable {
    let text: String
    let fault: String?

    // 已提交或结果未知的同一份草稿不能再发，避免重复发信。
    func locks(_ draft: String) -> Bool {
        text == draft && (fault.map(OneShotFaultPolicy.locksResend) ?? true)
    }
}

struct BackfillPresentation: Equatable {
    let fraction: Double?
    let text: String
    let isRunning: Bool

    init(progress: BackfillProgress, target: Int?) {
        isRunning = !progress.done
        if let error = progress.error {
            fraction = nil
            text = "已拉取 \(progress.fetched) 条后中断：\(v2Explanation(error.rawValue))"
        } else if progress.done {
            fraction = 1
            text = "补扫完成，共 \(progress.fetched) 条"
        } else if let target, target > 0 {
            fraction = min(Double(progress.fetched) / Double(target), 1)
            text = "已拉取 \(progress.fetched) / \(target) 条"
        } else {
            fraction = nil
            text = "已拉取 \(progress.fetched) 条"
        }
    }
}

@MainActor
final class ConversationPickerModel: ObservableObject {
    private static let maxEmptyPages = 8

    @Published private(set) var items: [XiaoheConversation] = []
    @Published private(set) var loading = false
    @Published private(set) var nextCursor: String?
    @Published private(set) var syncStatus: String?
    @Published private(set) var fault: String?

    private let fetch: (RPCParams.Conversations) async throws -> XiaoheConversationPage
    private let accountId: String?
    private var generation = 0
    private var query = ""
    private var type: ScopeType?

    init(accountId: String?, fetch: @escaping (RPCParams.Conversations) async throws -> XiaoheConversationPage) {
        self.accountId = accountId
        self.fetch = fetch
    }

    func reload(query: String, type: ScopeType?) async {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.type = type
        items = []
        nextCursor = nil
        await load(cursor: nil)
    }

    func loadMore() async {
        guard let nextCursor, !loading else { return }
        await load(cursor: nextCursor)
    }

    // 引擎按类型过滤单页结果，可能出现空页但仍有后续，需要继续翻页。
    private func load(cursor start: String?) async {
        generation += 1
        let token = generation
        loading = true
        fault = nil
        defer { if token == generation { loading = false } }
        var cursor = start
        for _ in 0..<Self.maxEmptyPages {
            do {
                let page = try await fetch(.init(accountId: accountId, query: query.isEmpty ? nil : query, type: type,
                                                 cursor: cursor, limit: 50))
                guard token == generation else { return }
                let known = Set(items.map(\.conversationId))
                items.append(contentsOf: page.items.filter { !known.contains($0.conversationId) })
                nextCursor = page.nextCursor
                syncStatus = page.syncStatus
                cursor = page.nextCursor
                if !page.items.isEmpty || cursor == nil { return }
            } catch {
                guard token == generation else { return }
                fault = V2Workspace.code(error)
                return
            }
        }
    }
}

// MARK: - 主视图

struct ConversationsView: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var sessions: SessionsStore

    @State private var search = ""
    @State private var filter: ScopeType?
    @State private var adding = false
    @State private var pendingRemoval: ConversationPolicy?

    init(workspace: V2Workspace) {
        self.workspace = workspace
        settings = workspace.settings
        sessions = workspace.sessions
    }

    private var rows: [ConversationPolicy] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return settings.draft.conversations.values
            .filter { filter == nil || $0.type == filter }
            .filter { term.isEmpty || $0.label.lowercased().contains(term) || $0.conversationId.lowercased().contains(term) }
            .sorted { ($0.label, $0.conversationId) < ($1.label, $1.conversationId) }
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 268)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $adding) {
            AddConversationSheet(workspace: workspace) { adding = false }
        }
        .confirmationDialog("把「\(pendingRemoval?.label ?? "")」移出管理列表？", isPresented: removalDialog,
                            titleVisibility: .visible, presenting: pendingRemoval) { policy in
            Button("移出", role: .destructive) { workspace.removeConversation(policy.conversationId) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("保存设置后生效。已沉淀的记忆专档不会被删除。")
        }
    }

    private var removalDialog: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("搜索会话", text: $search).textFieldStyle(.roundedBorder)
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .help("添加会话")
                        .accessibilityLabel("添加会话")
                        .accessibilityIdentifier("conversation-add")
                }
                Picker("类型", selection: $filter) {
                    Text("全部").tag(ScopeType?.none)
                    ForEach(ScopeType.allCases, id: \.self) { Text($0.title).tag(ScopeType?.some($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if rows.isEmpty {
                EmptyStateView(title: settings.draft.conversations.isEmpty ? "还没有管理的会话" : "没有匹配的会话",
                               symbol: "bubble.left.and.bubble.right",
                               detail: settings.draft.conversations.isEmpty ? "点击 + 从小禾选择私聊、群聊或服务号。" : nil)
            } else {
                List(rows, selection: $workspace.selectedConversationId) { policy in
                    ConversationRow(policy: policy, state: sessions.sessions[policy.conversationId],
                                    pinned: settings.draft.runtime.pinnedConversationIds.contains(policy.conversationId),
                                    unsaved: settings.saved.conversations[policy.conversationId] != policy)
                        .tag(policy.conversationId)
                        .contextMenu { rowMenu(policy) }
                }
                .listStyle(.inset)
            }
        }
    }

    // 菜单复用详情页的门禁：被阻塞时不可开启，需确认时跳到详情页完成确认。
    @ViewBuilder private func rowMenu(_ policy: ConversationPolicy) -> some View {
        let id = policy.conversationId
        let armed = SessionPresentation(state: sessions.sessions[id]).isArmed
        if policy.type != .service {
            if armed {
                Button("暂停回复") {
                    let sessions = sessions
                    workspace.run { try await sessions.pause(id) }
                }
            } else {
                Button("开启自动回复") { workspace.quickArm(id, mode: .auto) }
                    .disabled(sessions.blocker(for: id, action: .auto, groupConfirmed: true) != nil)
                Button("开启只拟稿") { workspace.quickArm(id, mode: .draft) }
                    .disabled(sessions.blocker(for: id, action: .draft, groupConfirmed: true) != nil)
            }
            Divider()
        }
        Button(settings.draft.runtime.pinnedConversationIds.contains(id) ? "取消置顶" : "置顶到菜单栏") {
            workspace.togglePin(id)
        }
        Divider()
        Button("移除会话…", role: .destructive) { pendingRemoval = policy }
            .disabled(armed)
    }

    @ViewBuilder private var detail: some View {
        if let id = workspace.selectedConversationId, settings.draft.conversations[id] != nil {
            ConversationDetail(workspace: workspace, conversationId: id).id(id)
        } else {
            EmptyStateView(title: "选择一个会话", symbol: "slider.horizontal.3", detail: "每个会话的策略互相独立，单个会话出错不影响其他会话。")
        }
    }
}

private struct ConversationRow: View {
    let policy: ConversationPolicy
    let state: SessionRuntimeState?
    let pinned: Bool
    let unsaved: Bool

    var body: some View {
        let presentation = SessionPresentation(state: state)
        let dot = ConversationStatusDot(state: state)
        HStack(spacing: 9) {
            ConversationAvatar(label: policy.label, type: policy.type)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(color: dot.color, size: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(policy.label).font(.body.weight(.medium)).lineLimit(1)
                    if pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
                            .accessibilityLabel("已置顶")
                    }
                    if unsaved { StatusDot(color: .orange, size: 6).accessibilityLabel("有未保存更改") }
                }
                Text(policy.enabled ? presentation.title : "\(presentation.title) · 未监听")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 策略详情

private struct ConversationDetail: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var sessions: SessionsStore
    let conversationId: String

    @State private var grantMode: ArmReplyMode?
    @State private var confirmingRemoval = false
    @State private var backfillCount = 50
    @State private var backfillPurpose = BackfillRequest.Purpose.plugin
    @State private var backfillTargets: [String: Int] = [:]
    // 表单行可能被回收；重发锁放在这里，滚动后也不会丢。
    @State private var draftOutcome: DraftSendOutcome?

    init(workspace: V2Workspace, conversationId: String) {
        self.workspace = workspace
        runtime = workspace.runtime
        settings = workspace.settings
        sessions = workspace.sessions
        self.conversationId = conversationId
    }

    // 移出列表时子视图可能先于父视图刷新，这里不能强解包。
    private var policy: ConversationPolicy {
        settings.draft.conversations[conversationId]
            ?? ConversationPolicy(conversationId: conversationId, label: conversationId,
                                  type: ConversationCatalog.engineType(for: conversationId))
    }
    private var state: SessionRuntimeState? { sessions.sessions[conversationId] }
    private var presentation: SessionPresentation { SessionPresentation(state: state) }
    private var isService: Bool { policy.type == .service }

    private func binding<Value>(_ path: WritableKeyPath<ConversationPolicy, Value>) -> Binding<Value> {
        Binding(get: { policy[keyPath: path] },
                set: { value in sessions.updatePolicy(conversationId) { $0[keyPath: path] = value } })
    }

    var body: some View {
        Form {
            identitySection
            if isService { serviceSection } else { replySection }
            policySection
            backfillSection
            SessionTraceSection(workspace: workspace, conversationId: conversationId)
        }
        .formStyle(.grouped)
        .task(id: workspace.pendingGrant) {
            guard let request = workspace.pendingGrant, request.conversationId == conversationId else { return }
            grantMode = request.mode
            workspace.pendingGrant = nil
        }
        .confirmationDialog("把「\(policy.label)」移出管理列表？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("移出", role: .destructive) { workspace.removeConversation(conversationId) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存设置后生效。已沉淀的记忆专档不会被删除。")
        }
    }

    private var identitySection: some View {
        Section {
            HStack(spacing: 11) {
                ConversationAvatar(label: policy.label, type: policy.type, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(policy.label).font(.title3.weight(.semibold)).lineLimit(1)
                        ScopeBadge(type: policy.type)
                    }
                    HStack(spacing: 5) {
                        StatusDot(color: ConversationStatusDot(state: state).color)
                        Text(presentation.title).font(.callout).foregroundStyle(.secondary)
                        Text(V2Format.tail(conversationId)).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .help(conversationId)
                    }
                }
                Spacer(minLength: 6)
                let pinned = settings.draft.runtime.pinnedConversationIds.contains(conversationId)
                Button { workspace.togglePin(conversationId) } label: {
                    Image(systemName: pinned ? "pin.slash" : "pin")
                }
                .help(pinned ? "取消置顶" : "置顶到菜单栏")
                .accessibilityLabel(pinned ? "取消置顶" : "置顶到菜单栏")
                Button(role: .destructive) { confirmingRemoval = true } label: { Image(systemName: "trash") }
                    .help("移出管理列表").accessibilityLabel("移出管理列表")
                    .disabled(presentation.isArmed)
            }
            if !isService {
                let permission = ConversationCatalog.sendPermission(conversationId, account: sessions.account)
                LabeledContent("小禾发信") {
                    StatusPill(text: permission.text, tone: permission.tone, symbol: "checkmark.shield")
                }
            }
            if let reason = state?.reason {
                InlineNotice(text: v2Explanation(reason.rawValue), tone: presentation.recovery == nil ? .neutral : .critical)
            }
            if let recovery = presentation.recovery {
                SessionRecoveryControl(workspace: workspace, conversationId: conversationId, action: recovery)
            }
        }
    }

    private var serviceSection: some View {
        Section("服务号：只读模式") {
            InlineNotice(text: "服务号不支持拟稿、自动回复和单次发信，只用于只读监听和后链路归集插件。")
        }
    }

    private var replySection: some View {
        Section("回复通道") {
            replyToggle("只拟稿", detail: "用新来信生成草稿，由你决定是否发送", mode: .draft)
            replyToggle("自动回复", detail: "普通闲聊由模型代回，风险按会话策略处理", mode: .auto)
            if policy.type == .group {
                Picker("群聊触发", selection: binding(\.groupTrigger)) {
                    Text("仅被 @ 时").tag(ConversationPolicy.GroupTrigger.mentionOnly)
                    Text("全部消息").tag(ConversationPolicy.GroupTrigger.all)
                }
                .pickerStyle(.segmented)
                if policy.groupTrigger == .all {
                    InlineNotice(text: "对群内全部消息触发风险较高，建议保持「仅被 @ 时」。", tone: .warning)
                }
            }
            if presentation.isArmed, state?.replyMode == .draft {
                InlineNotice(text: "当前正在「只拟稿」；如需切换「自动回复」，请先关闭「只拟稿」开关。")
            } else if !presentation.isArmed, let blocker = sessions.blocker(for: conversationId, action: .auto, groupConfirmed: true) {
                InlineNotice(text: blocker.guidance, tone: blocker == .peerStopped || blocker == .sendUnknown ? .critical : .neutral)
            }
            if state?.phase == .cooldown {
                CooldownResumeControl(workspace: workspace, conversationId: conversationId,
                                      until: state?.cooldownUntil, ready: runtime.ready)
            }
            if let draft = state?.draft {
                DraftSendControl(workspace: workspace, conversationId: conversationId, draft: draft,
                                 isGroup: policy.type == .group, blocked: draftBlocker != nil,
                                 guidance: draftGuidance, outcome: $draftOutcome)
            }
            if let mode = grantMode {
                SessionGrantForm(workspace: workspace, conversationId: conversationId, mode: mode) { grantMode = nil }
                    .id(mode)
            }
            LabeledContent("单次发送") {
                if state?.phase == .scheduled {
                    Button("取消定时发送…") { workspace.oneShotRequest = OneShotRequest(conversationId: conversationId) }
                } else {
                    Button { workspace.oneShotRequest = OneShotRequest(conversationId: conversationId) } label: {
                        Label("单独发送一条", systemImage: "paperplane")
                    }
                    .disabled(sessions.blocker(for: conversationId, action: .oneShot, groupConfirmed: true) != nil)
                    .accessibilityIdentifier("conversation-one-shot")
                }
            }
        }
    }

    private var draftBlocker: SessionReplyBlocker? {
        sessions.blocker(for: conversationId, action: .oneShot, groupConfirmed: true)
    }

    // 未开启时上方已展示同一条门禁说明，这里不重复。
    private var draftGuidance: String? {
        let shown = presentation.isArmed ? nil : sessions.blocker(for: conversationId, action: .auto, groupConfirmed: true)
        return draftBlocker == shown ? nil : draftBlocker?.guidance
    }

    private func replyToggle(_ title: String, detail: String, mode: ArmReplyMode) -> some View {
        let reply: SessionReplyMode = mode == .auto ? .auto : .draft
        let on = presentation.isArmed && state?.replyMode == reply
        let action: SessionAction = mode == .auto ? .auto : .draft
        let blocked = sessions.blocker(for: conversationId, action: action, groupConfirmed: true) != nil
        return Toggle(isOn: Binding(get: { on || grantMode == mode }, set: { value in
            if value {
                if workspace.canFastArm(conversationId) {
                    workspace.fastArm(conversationId, mode: mode)
                } else {
                    grantMode = mode
                }
            } else if grantMode == mode {
                grantMode = nil
            } else {
                let sessions = sessions, id = conversationId
                workspace.run { try await sessions.pause(id) }
            }
        })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .disabled(!on && grantMode != mode && blocked)
        .accessibilityIdentifier("conversation-\(mode.rawValue)")
    }

    private var policySection: some View {
        Section("会话与风控策略") {
            Toggle("监听实时事件", isOn: binding(\.enabled)).toggleStyle(.switch)
            Toggle("参与记忆更新", isOn: binding(\.memoryEnabled)).toggleStyle(.switch)
                .disabled(isService)
            if !isService {
                Picker("回复模型", selection: binding(\.replyPresetId)) {
                    Text("跟随主模型").tag(String?.none)
                    ForEach(settings.draft.models.filter { $0.kind == .chat }) { Text($0.name).tag(String?.some($0.id)) }
                }
                LabeledContent("开启时载入上下文") {
                    Stepper(value: binding(\.backfillOnArmCount), in: 0...500, step: 5) {
                        Text("最近 \(policy.backfillOnArmCount) 条").monospacedDigit()
                    }
                }
                Picker("风控策略", selection: riskBinding(\.selectedLevel)) {
                    if policy.riskProfile.selectedLevel == nil {
                        Text("沿用旧版规则").tag(RiskProfile.Level?.none)
                    }
                    ForEach(RiskProfile.Level.allCases, id: \.self) { level in
                        Text(level.title).tag(RiskProfile.Level?.some(level))
                    }
                }
                .accessibilityIdentifier("risk-level")
                if let level = policy.riskProfile.selectedLevel {
                    InlineNotice(text: level.detail, tone: level == .minimal ? .warning : .neutral)
                } else {
                    InlineNotice(text: "升级后保留原有风控：来信或草稿命中规则时跳过本轮。选档并保存后，才切换到新策略。", tone: .neutral)
                }
                Picker("本人插话时", selection: takeoverBinding) {
                    Text("暂停这个会话").tag(RiskProfile.TakeoverAction.pauseSession)
                    Text("静默冷却后恢复").tag(RiskProfile.TakeoverAction.cooldown)
                    Text("继续监听（不暂停）").tag(RiskProfile.TakeoverAction.ignore)
                }
                .accessibilityIdentifier("risk-takeover-action")
                if policy.riskProfile.takeoverAction == .ignore {
                    InlineNotice(text: "你在微信里插话后，模型仍会继续回复对方的新消息。", tone: .warning)
                }
                if policy.riskProfile.takeoverAction.usesCooldownDuration {
                    LabeledContent("冷却时长") {
                        Stepper(value: cooldownBinding, in: 1...240) {
                            Text("\(policy.riskProfile.takeoverCooldownMinutes) 分钟").monospacedDigit()
                        }
                        .accessibilityIdentifier("risk-cooldown-minutes")
                    }
                }
                if policy.riskProfile.selectedLevel != .strict {
                    turnActionRow("对方刷屏时", riskBinding(\.busyChatAction))
                    turnActionRow("图片/语音无法解析时", riskBinding(\.unparsedMediaAction))
                }
            }
        }
    }

    private func turnActionRow(_ title: String, _ selection: Binding<RiskProfile.TurnAction>) -> some View {
        Picker(title, selection: selection) {
            Text("跳过本轮").tag(RiskProfile.TurnAction.skipTurn)
            Text("暂停这个会话").tag(RiskProfile.TurnAction.pauseSession)
        }
    }

    private func riskBinding<Value>(_ path: WritableKeyPath<RiskProfile, Value>) -> Binding<Value> {
        Binding(get: { policy.riskProfile[keyPath: path] },
                set: { value in sessions.updatePolicy(conversationId) { $0.riskProfile[keyPath: path] = value } })
    }

    private var takeoverBinding: Binding<RiskProfile.TakeoverAction> { riskBinding(\.takeoverAction) }
    private var cooldownBinding: Binding<Int> { riskBinding(\.takeoverCooldownMinutes) }

    // MARK: 历史补扫

    private var jobs: [BackfillProgress] {
        sessions.backfills.values.filter { $0.conversationId == conversationId }
            .sorted { ($0.done ? 1 : 0, $0.jobId) < ($1.done ? 1 : 0, $1.jobId) }
    }

    private var backfillSection: some View {
        Section {
            Picker("拉取范围", selection: $backfillCount) {
                ForEach([20, 50, 100, 200, 500], id: \.self) { Text("最近 \($0) 条").tag($0) }
            }
            Picker("用途", selection: $backfillPurpose) {
                Text("后链路插件").tag(BackfillRequest.Purpose.plugin)
                Text("记忆提炼").tag(BackfillRequest.Purpose.memory)
                if !isService { Text("工作上下文").tag(BackfillRequest.Purpose.context) }
            }
            HStack {
                if runtime.capabilities?.historyQuery == false {
                    InlineNotice(text: "当前小禾连接不支持历史查询。", tone: .warning)
                }
                Spacer()
                Button("拉取历史补扫", action: startBackfill)
                    .disabled(!runtime.ready || runtime.capabilities?.historyQuery == false || jobs.contains { !$0.done })
                    .accessibilityIdentifier("conversation-backfill")
            }
            ForEach(jobs, id: \.jobId) { job in
                let view = BackfillPresentation(progress: job, target: backfillTargets[job.jobId])
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        if view.isRunning {
                            if let fraction = view.fraction { ProgressView(value: fraction) }
                            else { ProgressView().progressViewStyle(.linear) }
                        }
                        Text(view.text).font(.caption).foregroundStyle(job.error == nil ? Color.secondary : Color.red)
                    }
                    if view.isRunning {
                        Button("取消") {
                            let sessions = sessions, id = job.jobId
                            workspace.run { try await sessions.cancelBackfill(jobId: id) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("历史补扫")
        } footer: {
            Text("补扫的消息只用于上下文、只读插件和记忆提炼，绝不会触发发信。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func startBackfill() {
        let sessions = sessions, count = backfillCount
        let request = BackfillRequest(conversationId: conversationId, recentCount: count, purpose: backfillPurpose)
        workspace.run {
            let job = try await sessions.startBackfill(request)
            backfillTargets[job] = count
        }
    }
}

// MARK: - 冷静期恢复

private struct CooldownResumeControl: View {
    @ObservedObject var workspace: V2Workspace
    let conversationId: String
    let until: Int64?
    let ready: Bool

    @State private var resuming = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            InlineNotice(text: CooldownPresentation.notice(until: until), tone: .warning)
            if resuming { ProgressView().controlSize(.small) }
            Button(action: resume) { Label("立即恢复", systemImage: "play.fill") }
                .disabled(resuming || !ready)
                .accessibilityIdentifier("conversation-resume-cooldown")
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func resume() {
        let sessions = workspace.sessions, id = conversationId
        resuming = true
        workspace.run {
            defer { resuming = false }
            try await sessions.resumeCooldown(id)
        }
    }
}

// MARK: - 草稿一键发送

private struct DraftSendControl: View {
    @ObservedObject var workspace: V2Workspace
    let conversationId: String
    let draft: String
    let isGroup: Bool
    let blocked: Bool
    let guidance: String?
    @Binding var outcome: DraftSendOutcome?

    @State private var sending = false
    @State private var pendingGroupDraft: String?

    private var sendable: Bool { SessionsStore.sendableText(draft) != nil }
    private var currentOutcome: DraftSendOutcome? { outcome?.text == draft ? outcome : nil }
    private var canSend: Bool { !sending && !blocked && sendable && outcome?.locks(draft) != true }

    private var groupDialog: Binding<Bool> {
        Binding(get: { pendingGroupDraft != nil }, set: { if !$0 { pendingGroupDraft = nil } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(currentOutcome?.fault == nil && currentOutcome != nil ? "临时草稿 · 已提交" : "临时草稿 · 未发送")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(draft).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !sendable {
                InlineNotice(text: "草稿含换行或超过 500 字，无法一键发送；请改写后用「单独发送一条」发送。", tone: .warning)
            }
            if let guidance { InlineNotice(text: guidance, tone: .warning) }
            if let current = currentOutcome {
                if let fault = current.fault {
                    InlineNotice(text: v2Explanation(fault), tone: .critical)
                    if OneShotFaultPolicy.locksResend(fault) {
                        InlineNotice(text: "这条草稿的结果未知，App 不会重发。请先到微信核对。", tone: .critical)
                    }
                } else {
                    InlineNotice(text: "草稿已提交，发送结果见「实时运行轨迹」。", tone: .active)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button(action: request) { Label("立即发送草稿", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                    .accessibilityIdentifier("conversation-send-draft")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .confirmationDialog("把这条草稿发到群聊？", isPresented: groupDialog, titleVisibility: .visible,
                            presenting: pendingGroupDraft) { text in
            Button("发送到群聊") { send(text) }
            Button("取消", role: .cancel) {}
        } message: { text in
            Text("发送后所有群成员都能看到：\n\(text)")
        }
    }

    // 群聊必须二次确认，确认框锁定用户看到的这一版草稿。
    private func request() {
        guard canSend else { return }
        if isGroup { pendingGroupDraft = draft } else { send(draft) }
    }

    // 每次点击由 Store 生成新的幂等键；失败后不自动重试。
    private func send(_ text: String) {
        let sessions = workspace.sessions, id = conversationId, isGroup = isGroup
        sending = true
        Task { @MainActor in
            defer { sending = false }
            do {
                try await sessions.sendOneShot(id, text: text, consent: true, groupConfirmed: isGroup)
                outcome = DraftSendOutcome(text: text, fault: nil)
            } catch {
                outcome = DraftSendOutcome(text: text, fault: V2Workspace.code(error))
            }
        }
    }
}

// MARK: - 实时运行轨迹

private struct SessionTraceSection: View {
    private static let collapsedCount = 6

    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var sessions: SessionsStore
    let conversationId: String

    @State private var loading = false
    @State private var fault: String?
    @State private var expanded = false

    private struct LoadKey: Equatable { let conversationId: String; let ready: Bool }

    init(workspace: V2Workspace, conversationId: String) {
        self.workspace = workspace
        runtime = workspace.runtime
        sessions = workspace.sessions
        self.conversationId = conversationId
    }

    private var entries: [SessionTraceEntry] { sessions.traces[conversationId] ?? [] }

    var body: some View {
        Section {
            timeline
                // 重连后内存轨迹已清空，需要重新拉取。
                .task(id: LoadKey(conversationId: conversationId, ready: runtime.ready)) { await load() }
            if entries.count > Self.collapsedCount {
                Button(expanded ? "收起" : "展开全部 \(entries.count) 条") { expanded.toggle() }
                    .buttonStyle(.link).controlSize(.small)
            }
        } header: {
            HStack(spacing: 8) {
                Text("实时运行轨迹")
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("刷新运行轨迹")
                    .disabled(loading || !runtime.ready)
                    .accessibilityIdentifier("conversation-trace-refresh")
            }
        }
    }

    @ViewBuilder private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
            if entries.isEmpty {
                if fault == nil {
                    Text("还没有运行记录。开启「只拟稿」或「自动回复」后，来信、策略判断、模型调用和发信结果会实时显示在这里。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if expanded {
                // 展开后定高滚动，长轨迹不会把整页撑开。
                ScrollView {
                    rows(entries).padding(.trailing, 10)
                }
                .frame(height: 280)
            } else {
                rows(Array(entries.prefix(Self.collapsedCount)))
            }
        }
    }

    private func rows(_ items: [SessionTraceEntry]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                TraceRow(entry: entry, isLast: index == items.count - 1)
            }
        }
    }

    private func load() async {
        fault = nil
        guard runtime.ready else { return }
        loading = true
        defer { loading = false }
        do { try await sessions.loadTraces(for: conversationId) }
        catch { fault = V2Workspace.code(error) }
    }
}

private struct TraceRow: View {
    let entry: SessionTraceEntry
    let isLast: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(V2Format.clockWithSeconds(entry.at))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            StatusDot(color: entry.level.color)
                .accessibilityLabel(entry.level.title)
                .background(alignment: .top) {
                    if !isLast {
                        Rectangle().fill(.quaternary).frame(width: 1, height: 26).offset(y: 7)
                    }
                }
            Text(entry.stage.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let detail = entry.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 添加会话

private struct AddConversationSheet: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var settings: SettingsStore
    @StateObject private var model: ConversationPickerModel
    let dismiss: () -> Void

    @State private var query = ""
    @State private var type: ScopeType?

    init(workspace: V2Workspace, dismiss: @escaping () -> Void) {
        self.workspace = workspace
        settings = workspace.settings
        self.dismiss = dismiss
        let client = workspace.runtime.client
        let account = workspace.settings.saved.xiaohe.accountId
        _model = StateObject(wrappedValue: ConversationPickerModel(accountId: account.isEmpty ? nil : account) {
            try await client.xiaoheConversations($0)
        })
    }

    private struct SearchKey: Equatable { let query: String; let type: ScopeType? }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加会话").font(.title2.weight(.semibold))
            TextField("搜索昵称、备注或会话 ID", text: $query).textFieldStyle(.roundedBorder)
            Picker("类型", selection: $type) {
                Text("全部").tag(ScopeType?.none)
                ForEach(ScopeType.allCases, id: \.self) { Text($0.title).tag(ScopeType?.some($0)) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if let fault = model.fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
            if model.syncStatus == "unknown" { InlineNotice(text: "小禾同步尚未就绪，列表可能不完整，请稍后重试。", tone: .warning) }
            results
            HStack {
                if model.loading { ProgressView().controlSize(.small) }
                if model.nextCursor != nil {
                    Button("加载更多") { Task { await model.loadMore() } }.disabled(model.loading)
                }
                Spacer()
                Button("完成", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 520)
        .task(id: SearchKey(query: query, type: type)) {
            // 输入停顿后再查询，避免每个字符都打一次小禾。
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            await model.reload(query: query, type: type)
        }
    }

    @ViewBuilder private var results: some View {
        if model.items.isEmpty && !model.loading {
            EmptyStateView(title: "没有找到会话", symbol: "magnifyingglass")
        } else {
            List(model.items) { row in
                PickerRow(row: row, managed: settings.draft.conversations[row.conversationId] != nil) {
                    guard let policy = ConversationCatalog.makePolicy(row) else { return }
                    workspace.addConversation(policy)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct PickerRow: View {
    let row: XiaoheConversation
    let managed: Bool
    let add: () -> Void

    private var supported: Bool { ConversationCatalog.managedType(row) != nil }

    var body: some View {
        HStack(spacing: 8) {
            ScopeBadge(type: row.type)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName).lineLimit(1)
                Text(supported ? V2Format.tail(row.conversationId) : "类型与会话 ID 不一致，暂不能加入")
                    .font(.caption).foregroundStyle(supported ? Color.secondary : Color.orange).lineLimit(1)
            }
            Spacer()
            if managed { StatusPill(text: "已加入", tone: .active) }
            else { Button("加入", action: add).controlSize(.small).disabled(!supported) }
        }
    }
}
