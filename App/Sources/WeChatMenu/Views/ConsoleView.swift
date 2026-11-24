import SwiftUI

// MARK: - 共用组件

extension SessionPresentation.Tone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .active: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

extension ScopeType {
    var title: String {
        switch self {
        case .direct: return "私聊"
        case .group: return "群聊"
        case .service: return "服务号"
        }
    }

    var symbol: String {
        switch self {
        case .direct: return "person.fill"
        case .group: return "person.3.fill"
        case .service: return "megaphone.fill"
        }
    }

    var tint: Color {
        switch self {
        case .direct: return .blue
        case .group: return .green
        case .service: return .orange
        }
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

// 首字头像：颜色区分私聊、群聊和服务号。
struct ConversationAvatar: View {
    let label: String
    let type: ScopeType
    var size: CGFloat = 30

    private var initial: String? {
        label.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(type.tint.opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                if let initial {
                    Text(initial).font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: type.symbol).font(.system(size: size * 0.42))
                }
            }
            .foregroundStyle(type.tint)
            .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let text: String
    var tone: SessionPresentation.Tone = .neutral
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tone.color.opacity(0.13), in: Capsule())
    }
}

struct ScopeBadge: View {
    let type: ScopeType
    var body: some View { StatusPill(text: type.title, symbol: type.symbol) }
}

struct InlineNotice: View {
    let text: String
    var tone: SessionPresentation.Tone = .neutral

    private var symbol: String {
        switch tone {
        case .critical, .warning: return "exclamationmark.triangle.fill"
        case .active: return "checkmark.circle.fill"
        case .neutral: return "info.circle"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tone.color)
            Text(text).foregroundStyle(tone == .neutral ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FaultBanner: View {
    let code: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(v2Explanation(code)).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("fault-banner-action")
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }
}

struct EmptyStateView: View {
    let title: String
    let symbol: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// 会话、记忆和设置共用同一份草稿，因此任一页改动都在这里显示并保存。
struct UnsavedChangesBar: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject var settings: SettingsStore

    init(workspace: V2Workspace) {
        self.workspace = workspace
        settings = workspace.settings
    }

    private var dirty: Bool { settings.hasUnsavedChanges }

    private var status: String {
        if !settings.loaded { return "设置尚未加载" }
        if settings.saving { return "正在保存…" }
        return dirty ? "有未保存更改，当前运行的仍是旧配置" : "设置已保存"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: dirty ? "exclamationmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(dirty ? Color.orange : Color.secondary)
            Text(status).font(.callout.weight(dirty ? .semibold : .regular))
                .foregroundStyle(dirty ? Color.primary : Color.secondary)
                .accessibilityIdentifier("settings-dirty-state")
            Spacer(minLength: 8)
            Button("放弃更改") { settings.discardChanges() }
                .disabled(!dirty || settings.saving)
                .accessibilityIdentifier("settings-discard")
            Button("保存设置") { workspace.run { [workspace] in try await workspace.saveSettings() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty || settings.saving || !settings.loaded)
                .accessibilityIdentifier("settings-save")
        }
        .controlSize(.regular)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background {
            ZStack {
                Rectangle().fill(.bar)
                if dirty { Color.orange.opacity(0.1) }
            }
        }
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 控制台外壳

struct ConsoleView: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var settings: SettingsStore
    @State private var confirmingStop = false

    static let minimumSize = CGSize(width: 940, height: 620)
    static let defaultSize = CGSize(width: 1120, height: 740)

    init(workspace: V2Workspace) {
        self.workspace = workspace
        runtime = workspace.runtime
        settings = workspace.settings
    }

    private var selection: Binding<ConsoleTab?> {
        Binding(get: { workspace.tab }, set: { tab in
            guard let tab, tab != workspace.tab else { return }
            DispatchQueue.main.async { workspace.tab = tab }
        })
    }

    private var status: RuntimeStatusPresentation {
        RuntimeStatusPresentation(ready: runtime.ready, starting: runtime.starting, phase: runtime.globalPhase)
    }

    var body: some View {
        NavigationSplitView {
            ConsoleSidebar(workspace: workspace, selection: selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            detail
                .navigationTitle(workspace.tab.title)
                .navigationSubtitle(workspace.tab.subtitle)
                .modifier(ConsoleToolbarHost { commands })
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .task(id: runtime.ready) { await workspace.refreshAll() }
        .sheet(item: $workspace.oneShotRequest) { request in
            OneShotSheet(workspace: workspace, conversationId: request.conversationId) {
                workspace.oneShotRequest = nil
            }
        }
        .sheet(isPresented: $workspace.feedbackPresented) {
            FeedbackSheet(workspace: workspace) { workspace.feedbackPresented = false }
        }
        .confirmationDialog("有未保存的设置更改", isPresented: closeDialog, titleVisibility: .visible) {
            Button("保存并关闭") { workspace.resolveClose(save: true) }
            Button("放弃更改并关闭", role: .destructive) { workspace.resolveClose(save: false) }
            Button("继续编辑", role: .cancel) { workspace.cancelClose() }
        } message: {
            Text("未保存的更改不会生效，当前运行的仍是旧配置。")
        }
        .confirmationDialog("停止全部任务？", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("全部停止", role: .destructive, action: workspace.pauseEverything)
            Button("取消", role: .cancel) {}
        } message: {
            Text("会暂停所有会话的回复、拟稿、定时发送、历史补扫和插件。已发出的请求无法撤回，恢复时需要逐项重新开启。")
        }
    }

    private var closeDialog: Binding<Bool> {
        Binding(get: { workspace.closeConfirmationVisible }, set: { if !$0 { workspace.cancelClose() } })
    }

    private var detail: some View {
        VStack(spacing: 0) {
            // macOS 13 无法把 SwiftUI 工具栏桥接到 AppKit 窗口，紧急操作必须留在页面内。
            if #unavailable(macOS 14.0) {
                HStack(spacing: 10) { Spacer(); commands }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                Divider()
            }
            if !runtime.ready { backendBanner }
            if let fault = workspace.fault {
                FaultBanner(
                    code: fault,
                    actionTitle: fault == "cloud-not-approved" ? "去「连接与设置」统一授权" : nil,
                    action: fault == "cloud-not-approved" ? {
                        workspace.fault = nil
                        workspace.open(tab: .settings)
                    } : nil
                ) { workspace.fault = nil }
            }
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
            // 设置页自带固定底栏，其余页只在有改动时出现。
            if workspace.tab != .settings && settings.hasUnsavedChanges {
                UnsavedChangesBar(workspace: workspace)
            }
        }
    }

    @ViewBuilder private var commands: some View {
        HStack(spacing: 5) {
            StatusDot(color: status.tone.color)
            Text(status.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("运行状态：\(status.title)")
        .accessibilityIdentifier("console-runtime-status")
        Button(action: workspace.pauseAllSending) { Label("暂停发信", systemImage: "pause.circle") }
            .help("暂停全部发信")
            .disabled(!runtime.ready)
            .accessibilityIdentifier("overview-pause-sending")
        Button(role: .destructive) { confirmingStop = true } label: {
            Label("一键全停", systemImage: "stop.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(runtime.ready ? Color.red : Color.secondary)
        }
        .help("停止全部任务")
        .disabled(!runtime.ready)
        .accessibilityIdentifier("overview-stop-all")
        Button(action: workspace.requestHealthCheck) { Label("一键体检", systemImage: "stethoscope") }
            .help("运行全链路体检")
            .disabled(!runtime.ready)
            .accessibilityIdentifier("console-health-check")
        Button(action: workspace.openFeedback) { Label("反馈问题", systemImage: "exclamationmark.bubble") }
            .help("反馈问题并导出脱敏诊断")
            .accessibilityIdentifier("console-feedback")
    }

    @ViewBuilder private var page: some View {
        switch workspace.tab {
        case .overview: OverviewView(workspace: workspace)
        case .conversations: ConversationsView(workspace: workspace)
        case .plugins: PluginsView(workspace: workspace)
        case .memory: MemoryView(workspace: workspace)
        case .settings: V2SettingsView(workspace: workspace)
        }
    }

    private var backendBanner: some View {
        HStack(spacing: 8) {
            if runtime.starting { ProgressView().controlSize(.small) }
            else { Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange) }
            Text(runtime.starting ? "后台正在启动…" : runtime.fault.map(v2Explanation) ?? "后台未就绪，暂时无法读取或修改运行状态。")
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }
}

private struct ConsoleToolbarHost<Commands: View>: ViewModifier {
    @ViewBuilder let commands: () -> Commands

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar {
                ToolbarItemGroup(placement: .primaryAction) { commands() }
            }
        } else {
            content
        }
    }
}

private struct ConsoleSidebar: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var feed: FeedStore
    @ObservedObject private var memory: MemoryStore
    @ObservedObject private var settings: SettingsStore
    @Binding var selection: ConsoleTab?

    init(workspace: V2Workspace, selection: Binding<ConsoleTab?>) {
        self.workspace = workspace
        feed = workspace.feed
        memory = workspace.memory
        settings = workspace.settings
        _selection = selection
    }

    private func badge(_ tab: ConsoleTab) -> Int {
        switch tab {
        case .overview: return feed.unreadCount
        case .memory: return memory.pendingProposalCount
        default: return 0
        }
    }

    var body: some View {
        List(ConsoleTab.allCases, id: \.self, selection: $selection) { tab in
            Label(tab.title, systemImage: tab.symbol)
                .badge(badge(tab))
                .tag(tab)
                .accessibilityIdentifier("console-tab-\(tab.rawValue)")
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.hasUnsavedChanges {
                Label("有未保存更改", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .imageScale(.small)
            }
            Divider()
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("微信桥").font(.caption.weight(.semibold))
                    Text("v\(AppVersion.short)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("sidebar-version")
                }
                Spacer(minLength: 4)
                Button(action: workspace.openFeedback) {
                    Label("反馈问题", systemImage: "exclamationmark.bubble").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("sidebar-feedback")
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}
