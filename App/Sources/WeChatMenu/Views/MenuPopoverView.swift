import AppKit
import SwiftUI

// 滚动内容与底栏各上报一次，求和得到气泡的自然高度。
private struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private extension View {
    func reportsPopoverHeight() -> some View {
        background(GeometryReader { Color.clear.preference(key: PopoverHeightKey.self, value: $0.size.height) })
    }
}

struct MenuPopoverSummary: Equatable {
    let pinnedIds: [String]
    let unreadDigests: Int
    let pendingProposals: Int
    let blockedIds: [String]

    init(settings: SettingsV2, sessions: [String: SessionRuntimeState], feed: [FeedItem], pendingProposals: Int) {
        // 只展示仍在管理列表中的置顶会话。
        pinnedIds = Array(settings.runtime.pinnedConversationIds.filter { settings.conversations[$0] != nil }
            .prefix(PinnedConversations.limit))
        unreadDigests = feed.filter { $0.kind == .pluginDigest && !$0.read }.count
        self.pendingProposals = pendingProposals
        blockedIds = sessions.keys.filter { id in
            settings.conversations[id] != nil && SessionPresentation(state: sessions[id]).recovery != nil
        }.sorted()
    }
}

struct MenuPopoverView: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var sessions: SessionsStore
    @ObservedObject private var feed: FeedStore
    @ObservedObject private var memory: MemoryStore
    @ObservedObject private var plugins: PluginsStore
    @ObservedObject private var updater: AppUpdater
    let quit: () -> Void
    var resize: ((NSSize) -> Void)?

    @State private var expanded: String?

    init(workspace: V2Workspace, quit: @escaping () -> Void, resize: ((NSSize) -> Void)? = nil) {
        self.workspace = workspace
        runtime = workspace.runtime
        settings = workspace.settings
        sessions = workspace.sessions
        feed = workspace.feed
        memory = workspace.memory
        plugins = workspace.plugins
        updater = workspace.updater
        self.quit = quit
        self.resize = resize
    }

    private var counts: RuntimeCounts {
        RuntimeCounts(global: runtime.global, sessions: sessions.sessions, plugins: plugins.states)
    }

    private var summary: MenuPopoverSummary {
        MenuPopoverSummary(settings: settings.saved, sessions: sessions.sessions, feed: feed.items,
                           pendingProposals: memory.pendingProposalCount)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    sections.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10).reportsPopoverHeight()
                }
                Divider()
                footer.padding(.horizontal, 12).padding(.vertical, 7).reportsPopoverHeight()
            }
            .onChange(of: expanded) { id in
                guard let id else { return }
                // 等确认区完成布局后再滚动，保证确认按钮可见。
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .frame(width: MenuPanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(PopoverHeightKey.self) { height in
            // 加 1 是分隔线的高度。
            resize?(MenuPanelMetrics.size(contentHeight: height + 1))
        }
        .task(id: runtime.ready) { await workspace.refreshAll() }
        .task { await workspace.checkForUpdatesIfDue() }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let fault = workspace.fault {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    InlineNotice(text: v2Explanation(fault), tone: .critical)
                    Button { workspace.fault = nil } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.borderless).accessibilityLabel("关闭提示")
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            if settings.hasUnsavedChanges {
                reminder("有未保存的设置更改", symbol: "exclamationmark.circle.fill", tone: .warning) {
                    workspace.open(tab: .settings)
                }
            }
            if let release = updater.latestRelease {
                reminder("发现新版本 v\(release.version)", symbol: "arrow.down.circle.fill", tone: .active) {
                    workspace.openUpdates()
                }
                .accessibilityIdentifier("menu-update-available")
            }
            pinned
            reminders
        }
    }

    private var status: RuntimeStatusPresentation {
        RuntimeStatusPresentation(ready: runtime.ready, starting: runtime.starting, phase: runtime.globalPhase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("微信桥").font(.headline)
                StatusPill(text: status.title, tone: status.tone)
                Spacer()
                // 引擎没有全局恢复接口，这里是单向的暂停按钮，不做成开关。
                Button(role: .destructive, action: workspace.pauseAllSending) {
                    Label("暂停发信", systemImage: "pause.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .controlSize(.small)
                .disabled(!runtime.ready)
                .help("暂停全部发信")
                .accessibilityIdentifier("pause-all-sending")
            }
            Text("自动回复 \(counts.activeAuto) · 活跃插件 \(counts.activePlugins)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder private var pinned: some View {
        let ids = summary.pinnedIds
        if ids.isEmpty {
            Text("在控制台的会话页置顶常用会话后，可在这里快速开关。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider().padding(.leading, 42) }
                    PinnedConversationCard(workspace: workspace, conversationId: id, expanded: $expanded).id(id)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder private var reminders: some View {
        let value = summary
        if !value.blockedIds.isEmpty {
            reminder("\(value.blockedIds.count) 个会话需要人工处理", symbol: "exclamationmark.triangle.fill", tone: .critical) {
                workspace.open(ConsoleRoute(tab: .conversations, conversationId: value.blockedIds.first))
            }
        }
        if value.unreadDigests > 0 {
            reminder("\(value.unreadDigests) 条未读插件摘要", symbol: "doc.text.fill", tone: .active) {
                workspace.open(tab: .overview)
            }
        }
        if value.pendingProposals > 0 {
            reminder("\(value.pendingProposals) 条待审人格建议", symbol: "brain.head.profile", tone: .active) {
                workspace.open(ConsoleRoute(tab: .memory, memorySection: .proposals))
            }
        }
    }

    private func reminder(_ title: String, symbol: String, tone: SessionPresentation.Tone,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(tone.color)
                Text(title).font(.callout).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { workspace.open(tab: .overview) } label: { Label("打开控制台", systemImage: "macwindow") }
                .accessibilityIdentifier("menu-open-console")
            Button(action: workspace.openFeedback) { Label("反馈问题", systemImage: "exclamationmark.bubble") }
                .accessibilityIdentifier("menu-feedback")
            Spacer()
            Button { workspace.open(tab: .settings) } label: { Image(systemName: "gearshape") }
                .help("连接与设置")
                .accessibilityLabel("设置")
                .accessibilityIdentifier("menu-settings")
            Button("退出", action: quit).accessibilityIdentifier("menu-exit")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

private struct PinnedConversationCard: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var sessions: SessionsStore
    let conversationId: String
    @Binding var expanded: String?
    @State private var grantMode: ArmReplyMode = .auto

    init(workspace: V2Workspace, conversationId: String, expanded: Binding<String?>) {
        self.workspace = workspace
        settings = workspace.settings
        sessions = workspace.sessions
        self.conversationId = conversationId
        _expanded = expanded
    }

    private var policy: ConversationPolicy? { settings.saved.conversations[conversationId] }
    private var state: SessionRuntimeState? { sessions.sessions[conversationId] }
    private var presentation: SessionPresentation { SessionPresentation(state: state) }
    private var autoOn: Bool { presentation.isArmed && state?.replyMode == .auto }
    private var draftOn: Bool { presentation.isArmed && state?.replyMode == .draft }
    private var isOpen: Bool { expanded == conversationId }

    // 群聊确认在展开区内收集，这里只显示其余阻塞原因。
    private var autoBlocker: SessionReplyBlocker? {
        sessions.blocker(for: conversationId, action: .auto, groupConfirmed: true)
    }

    private var toggle: Binding<Bool> {
        Binding(get: { autoOn || (isOpen && grantMode == .auto) }, set: { value in
            if value {
                if workspace.canFastArm(conversationId) {
                    workspace.fastArm(conversationId, mode: .auto)
                } else {
                    grantMode = .auto
                    expanded = conversationId
                }
            } else if isOpen && !autoOn {
                expanded = nil
            } else {
                pause()
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ConversationAvatar(label: policy?.label ?? conversationId, type: policy?.type ?? .direct, size: 26)
                    .overlay(alignment: .bottomTrailing) {
                        StatusDot(color: ConversationStatusDot(state: state).color, size: 8)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                            .offset(x: 2, y: 2)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(policy?.label ?? conversationId).font(.callout.weight(.medium)).lineLimit(1)
                    Text(presentation.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if policy?.type != .service {
                    actions
                    Toggle("自动回复", isOn: toggle)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .disabled(!autoOn && !isOpen && autoBlocker != nil)
                        .accessibilityLabel("\(policy?.label ?? "") 自动回复")
                        .accessibilityIdentifier("pinned-auto-\(conversationId)")
                }
            }
            if !autoOn && !draftOn && !isOpen, let autoBlocker {
                InlineNotice(text: autoBlocker.guidance, tone: autoBlocker == .peerStopped || autoBlocker == .sendUnknown ? .critical : .neutral)
                    .font(.caption)
                    .accessibilityIdentifier("reply-unavailable")
            }
            if let recovery = presentation.recovery {
                SessionRecoveryControl(workspace: workspace, conversationId: conversationId, action: recovery)
                    .controlSize(.small)
            }
            if let draft = state?.draft {
                VStack(alignment: .leading, spacing: 2) {
                    Text("临时草稿 · 未发送").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(draft).font(.caption).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            if isOpen {
                SessionGrantForm(workspace: workspace, conversationId: conversationId, mode: grantMode) {
                    if expanded == conversationId { expanded = nil }
                }
                .id(grantMode)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    @ViewBuilder private var actions: some View {
        if draftOn {
            Button(action: pause) { Image(systemName: "pause.fill") }
                .buttonStyle(.borderless).controlSize(.small)
                .help("暂停拟稿").accessibilityLabel("暂停拟稿")
        } else if !autoOn {
            Button {
                if workspace.canFastArm(conversationId) {
                    workspace.fastArm(conversationId, mode: .draft)
                } else {
                    grantMode = .draft
                    expanded = conversationId
                }
            } label: { Image(systemName: "text.bubble") }
            .buttonStyle(.borderless).controlSize(.small)
            .help("只拟稿").accessibilityLabel("只拟稿")
            .disabled(sessions.blocker(for: conversationId, action: .draft, groupConfirmed: true) != nil)
        }
        Button { workspace.requestOneShot(conversationId) } label: { Image(systemName: "paperplane") }
            .buttonStyle(.borderless).controlSize(.small)
            .help("单独发送一条")
            .accessibilityLabel("单独发送一条")
    }

    private func pause() {
        let sessions = sessions, id = conversationId
        workspace.run { try await sessions.pause(id) }
    }
}
