import SwiftUI

struct OverviewView: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var sessions: SessionsStore
    @ObservedObject private var feed: FeedStore
    @ObservedObject private var plugins: PluginsStore

    @State private var unreadOnly = false

    init(workspace: V2Workspace) {
        self.workspace = workspace
        runtime = workspace.runtime
        settings = workspace.settings
        sessions = workspace.sessions
        feed = workspace.feed
        plugins = workspace.plugins
    }

    private var counts: RuntimeCounts {
        RuntimeCounts(global: runtime.global, sessions: sessions.sessions, plugins: plugins.states)
    }

    private var visibleFeed: [FeedItem] { unreadOnly ? feed.items.filter { !$0.read } : feed.items }

    private var blocked: [(id: String, label: String, presentation: SessionPresentation)] {
        sessions.sessions.compactMap { id, state in
            let presentation = SessionPresentation(state: state)
            guard presentation.recovery != nil else { return nil }
            return (id, settings.saved.conversations[id]?.label ?? V2Format.tail(id), presentation)
        }.sorted { $0.label < $1.label }
    }

    var body: some View {
        Form {
            Section { stats }
            if !blocked.isEmpty { alerts }
            feedSection
        }
        .formStyle(.grouped)
    }

    private var status: RuntimeStatusPresentation {
        RuntimeStatusPresentation(ready: runtime.ready, starting: runtime.starting, phase: runtime.globalPhase)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat("运行状态", status.title, symbol: "waveform.path.ecg", tint: status.tone.color)
            Divider().frame(height: 34)
            stat("自动回复", "\(counts.activeAuto)", symbol: "arrowshape.turn.up.left", tint: .blue)
            Divider().frame(height: 34)
            stat("活跃插件", "\(counts.activePlugins)", symbol: "puzzlepiece.extension", tint: .purple)
            Divider().frame(height: 34)
            stat("提交中", "\(counts.inFlight)", symbol: "paperplane", tint: .teal)
        }
        .padding(.vertical, 2)
    }

    private func stat(_ title: String, _ value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .symbolRenderingMode(.hierarchical)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(value == "0" ? Color.secondary : tint == .secondary ? Color.primary : tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }

    private var alerts: some View {
        Section {
            ForEach(blocked, id: \.id) { row in
                HStack(spacing: 8) {
                    StatusDot(color: row.presentation.tone.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Button(row.label) { workspace.open(ConsoleRoute(tab: .conversations, conversationId: row.id)) }
                            .buttonStyle(.link).lineLimit(1)
                        Text(sessions.sessions[row.id]?.reason.map { v2Explanation($0.rawValue) } ?? row.presentation.title)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let recovery = row.presentation.recovery {
                        SessionRecoveryControl(workspace: workspace, conversationId: row.id, action: recovery)
                            .controlSize(.small)
                    }
                }
            }
        } header: {
            Label("需要处理", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } footer: {
            Text("只影响对应会话的发信通道，其他会话和只读插件继续运行。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var feedSection: some View {
        Section {
            if visibleFeed.isEmpty {
                Text(unreadOnly ? "没有未读动态。" : "暂无动态。插件摘要、记忆更新和告警会显示在这里。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 14)
            } else {
                ForEach(visibleFeed) { item in
                    FeedRow(item: item, highlighted: workspace.highlightedFeedId == item.id) {
                        workspace.open(feedItem: item)
                    }
                }
                if feed.nextCursor != nil {
                    Button("加载更多") {
                        let feed = feed, unread = unreadOnly
                        workspace.run { try await feed.loadMore(unreadOnly: unread) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text("最新动态")
                if feed.unreadCount > 0 { StatusPill(text: "\(feed.unreadCount) 未读", tone: .active) }
                Spacer()
                Toggle("只看未读", isOn: $unreadOnly).toggleStyle(.checkbox).controlSize(.small)
                Button("全部标为已读", action: markAllRead)
                    .controlSize(.small)
                    .disabled(!runtime.ready || !feed.items.contains { !$0.read })
            }
        }
    }

    private func markAllRead() {
        let feed = feed, ids = feed.items.filter { !$0.read }.map(\.id)
        workspace.run { try await feed.markRead(ids: ids) }
    }
}

private struct FeedRow: View {
    let item: FeedItem
    let highlighted: Bool
    let open: () -> Void

    private var symbol: String {
        switch item.kind {
        case .pluginDigest: return "doc.text"
        case .personaProposal: return "brain.head.profile"
        case .memoryUpdated: return "clock.arrow.circlepath"
        case .alert: return "exclamationmark.triangle"
        case .scheduleCancelled: return "calendar.badge.exclamationmark"
        }
    }

    private var tone: SessionPresentation.Tone {
        switch item.kind {
        case .alert: return .critical
        case .scheduleCancelled: return .warning
        default: return .active
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(tone.color).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if !item.read { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                        Text(item.title).font(.callout.weight(item.read ? .regular : .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(V2Format.time(item.createdAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(highlighted ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
