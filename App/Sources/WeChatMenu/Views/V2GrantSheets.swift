import SwiftUI

// MARK: - 授权规则

// 开启前必须勾选的确认项。只拟稿不发信，群聊二次确认只针对自动回复。
struct ArmGrantRequirement: Equatable {
    let needsGroupConfirmation: Bool
    let cloudEndpoint: String?

    init(policy: ConversationPolicy?, preset: ModelPreset?, mode: ArmReplyMode) {
        needsGroupConfirmation = mode == .auto && policy?.type == .group
        cloudEndpoint = preset?.mode == .cloud ? preset?.url : nil
    }

    func isSatisfied(consent: Bool, cloud: Bool, group: Bool) -> Bool {
        consent && (cloudEndpoint == nil || cloud) && (!needsGroupConfirmation || group)
    }
}

enum OneShotFaultPolicy {
    // 这些错误表示请求可能已到达引擎。窗口锁定重发，只能去微信核对。
    private static let unknownOutcome: Set<String> = [
        "send-unknown", "engine-timeout", "engine-exited", "engine-protocol", "internal-error",
    ]

    static func locksResend(_ code: String) -> Bool { unknownOutcome.contains(code) }
}

// MARK: - 开启确认

struct SessionGrantForm: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var sessions: SessionsStore
    let conversationId: String
    let mode: ArmReplyMode
    let close: () -> Void

    @State private var consent = false
    @State private var cloud = false
    @State private var group = false
    @State private var busy = false
    @State private var fault: String?

    init(workspace: V2Workspace, conversationId: String, mode: ArmReplyMode, close: @escaping () -> Void) {
        self.workspace = workspace
        runtime = workspace.runtime
        settings = workspace.settings
        sessions = workspace.sessions
        self.conversationId = conversationId
        self.mode = mode
        self.close = close
        let saved = workspace.settings.saved
        let presetId = saved.conversations[conversationId]?.replyPresetId ?? saved.defaultModels.replyPresetId
        let approved = presetId.map { saved.runtime.approvedCloudPresetIds.contains($0) } ?? false
        _cloud = State(initialValue: approved)
    }

    private var policy: ConversationPolicy? { settings.saved.conversations[conversationId] }

    private var preset: ModelPreset? {
        let saved = settings.saved
        return saved.preset(policy?.replyPresetId ?? saved.defaultModels.replyPresetId)
    }

    private var requirement: ArmGrantRequirement { ArmGrantRequirement(policy: policy, preset: preset, mode: mode) }

    // 确认框由本表单收集，这里只判断其余门禁。
    private var blocker: SessionReplyBlocker? {
        sessions.blocker(for: conversationId, action: mode == .auto ? .auto : .draft, groupConfirmed: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(mode == .auto ? "确认开启自动回复" : "确认开启只拟稿").font(.headline)
            if let policy {
                HStack(spacing: 6) {
                    ScopeBadge(type: policy.type)
                    Text(policy.label).font(.callout.weight(.medium)).lineLimit(1)
                    Text(V2Format.tail(policy.conversationId)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            if mode == .draft {
                InlineNotice(text: "只用新来信生成临时草稿，不发送。")
            } else {
                InlineNotice(text: "确认后，普通闲聊不再逐条确认。识别到承诺、隐私、拿不准的内容、本人发信或对方叫停时会暂停。")
                InlineNotice(text: "可能漏判；检查后收到的叫停可能来不及阻止本次提交，已发出的请求无法撤回。", tone: .warning)
            }
            Toggle(isOn: $consent) {
                Text(mode == .auto ? "我确认对方知道普通闲聊会由模型代回，并同意。" : "我确认对方知道这里会用模型拟稿，并同意。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox).accessibilityIdentifier("peer-consent")
            if requirement.needsGroupConfirmation, let policy {
                Toggle(isOn: $group) {
                    Text(groupText(policy)).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox).accessibilityIdentifier("group-consent")
            }
            if let endpoint = requirement.cloudEndpoint {
                Text(endpoint).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $cloud) {
                    Text("我同意把必要文字、少量临时上下文和已标记的脱敏片段发给以上端点。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox).accessibilityIdentifier("cloud-consent")
            }
            if let blocker { InlineNotice(text: blocker.guidance, tone: .warning) }
            if let fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("取消", action: close)
                Button("确认开启", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || blocker != nil || !requirement.isSatisfied(consent: consent, cloud: cloud, group: group))
                    .accessibilityIdentifier("grant-confirm")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        // 确认只对看到的配置有效：暂停、休眠或改配置后作废。
        .onChange(of: runtime.pauseRevision) { _ in close() }
        .onChange(of: settings.saved) { _ in close() }
    }

    private func groupText(_ policy: ConversationPolicy) -> String {
        let scope = policy.groupTrigger == .mentionOnly ? "仅在我被 @ 时触发" : "对群内全部消息触发"
        return "我已了解群聊风险：回复会被所有成员看到（当前\(scope)）。"
    }

    private func confirm() {
        busy = true
        fault = nil
        let id = conversationId, mode = mode, agreed = consent, cloudApproved = cloud, groupConfirmed = group
        Task { @MainActor in
            defer { busy = false }
            do {
                try await sessions.arm(id, mode: mode, consent: agreed, cloudApproved: cloudApproved, groupConfirmed: groupConfirmed)
                close()
            } catch {
                fault = V2Workspace.code(error)
            }
        }
    }
}

// MARK: - 恢复确认

struct SessionRecoveryControl: View {
    @ObservedObject var workspace: V2Workspace
    let conversationId: String
    let action: SessionRecoverAction
    @State private var confirming = false

    var body: some View {
        Button(SessionPresentation.recoveryTitle(action)) { confirming = true }
            .accessibilityIdentifier("session-recover")
            .confirmationDialog(SessionPresentation.recoveryTitle(action), isPresented: $confirming, titleVisibility: .visible) {
                Button("确认") {
                    let sessions = workspace.sessions, id = conversationId, action = action
                    workspace.run { try await sessions.recover(id, action: action) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(SessionPresentation.recoveryDetail(action))
            }
    }
}

// MARK: - 单次发送

// 只与目标会话自身的提交互斥，不要求停掉其他会话的自动回复或只读插件。
struct OneShotSheet: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var sessions: SessionsStore
    let conversationId: String
    let dismiss: () -> Void

    @State private var text = ""
    @State private var scheduled = false
    @State private var at = Date.now.addingTimeInterval(120)
    @State private var busy = false
    @State private var fault: String?
    @State private var cancelling = false

    init(workspace: V2Workspace, conversationId: String, dismiss: @escaping () -> Void) {
        self.workspace = workspace
        runtime = workspace.runtime
        settings = workspace.settings
        sessions = workspace.sessions
        self.conversationId = conversationId
        self.dismiss = dismiss
    }

    private var policy: ConversationPolicy? { settings.saved.conversations[conversationId] }
    private var state: SessionRuntimeState? { sessions.sessions[conversationId] }
    private var isGroup: Bool { policy?.type == .group }
    private var pending: Bool { state?.phase == .scheduled }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var locked: Bool { fault.map(OneShotFaultPolicy.locksResend) ?? false }

    private var blocker: SessionReplyBlocker? {
        sessions.blocker(for: conversationId, action: .oneShot, groupConfirmed: true)
    }

    private var acceptable: Bool {
        !trimmed.isEmpty && trimmed.utf16.count <= 500
            && !trimmed.unicodeScalars.contains { $0.properties.generalCategory == .control }
            && (!scheduled || (at > .now && at < nextMidnight()))
    }

    private var canContinue: Bool {
        !busy && !locked && blocker == nil && acceptable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("单独发送一条").font(.title2.weight(.semibold))
            target
            if pending { pendingSchedule } else { composer }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: runtime.pauseRevision) { _ in if !busy { dismiss() } }
        .onChange(of: settings.saved) { _ in if !busy { dismiss() } }
    }

    private var target: some View {
        HStack(spacing: 6) {
            if let policy { ScopeBadge(type: policy.type) }
            Text(policy?.label ?? "未加入管理的会话").font(.headline).lineLimit(1)
            Text(V2Format.tail(conversationId)).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(9)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var pendingSchedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let at = state?.scheduledAt {
                InlineNotice(text: "已排定在 \(V2Format.clock(at)) 发送一次，尚未提交。", tone: .active)
            }
            if state?.replyMode != .off {
                InlineNotice(text: "取消定时发送会同时暂停这个会话的自动回复或拟稿，之后需要重新开启。", tone: .warning)
            }
            if let fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
            HStack {
                Spacer()
                Button("关闭", action: dismiss).keyboardShortcut(.cancelAction)
                Button("取消定时发送", role: .destructive, action: cancelSchedule)
                    .disabled(cancelling)
                    .accessibilityIdentifier("cancel-scheduled-send")
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("输入一条纯文字", text: $text, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("compose-text")
                .disabled(busy || locked)
            Toggle("今天定时发送", isOn: $scheduled)
                .accessibilityIdentifier("scheduled-once").disabled(busy || locked)
            if scheduled {
                DatePicker("时间", selection: $at, displayedComponents: [.hourAndMinute])
                    .disabled(busy || locked)
                Text("必须是今天尚未到的时间。保持 App 运行、Mac 清醒、微信登录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let blocker { InlineNotice(text: blocker.guidance, tone: .warning) }
            if let fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
            if locked {
                InlineNotice(text: "这条消息的结果未知，App 不会重发。请先到微信核对。", tone: .critical)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("关闭", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button(scheduled ? "排定发送" : "立即发送", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                    .accessibilityIdentifier("one-shot-confirm")
            }
        }
    }

    // 每次点击由 Store 生成新的幂等键；失败后不自动重试。
    private func send() {
        let id = conversationId, body = trimmed, date = scheduled ? at : nil, isGroup = isGroup
        busy = true
        fault = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await sessions.sendOneShot(id, text: body, at: date, consent: true, groupConfirmed: isGroup)
                dismiss()
            } catch {
                fault = V2Workspace.code(error)
            }
        }
    }

    private func cancelSchedule() {
        cancelling = true
        fault = nil
        let id = conversationId
        Task { @MainActor in
            defer { cancelling = false }
            do {
                try await sessions.pause(id)
                dismiss()
            } catch {
                fault = V2Workspace.code(error)
            }
        }
    }
}
