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
            PerformanceMonitorSection(workspace: workspace)
            feedSection
        }
        .formStyle(.grouped)
        .task(id: runtime.ready) {
            guard runtime.ready else { return }
            try? await sessions.loadMetrics()
        }
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

// MARK: - 长期全链路性能监控与瓶颈归因（#28）

extension PerfStage {
    var title: String {
        switch self {
        case .ingest: return "入站感知"
        case .debounce: return "防抖等待"
        case .prompt: return "记忆与提示词"
        case .modelTtft: return "模型首包 (TTFT)"
        case .modelGen: return "模型续写生成"
        case .send: return "发信校验与提交"
        }
    }

    var shortTitle: String {
        switch self {
        case .ingest: return "入站"
        case .debounce: return "防抖"
        case .prompt: return "提示词"
        case .modelTtft: return "首包"
        case .modelGen: return "生成"
        case .send: return "发信"
        }
    }

    var color: Color {
        switch self {
        case .ingest: return .gray
        case .debounce: return .cyan
        case .prompt: return .indigo
        case .modelTtft: return .orange
        case .modelGen: return .purple
        case .send: return .blue
        }
    }
}

extension TurnPerfOutcome {
    var title: String {
        switch self {
        case .sent: return "已发"
        case .draft: return "拟稿"
        case .identity: return "身份"
        case .skipped: return "跳过"
        case .failed: return "失败"
        }
    }

    var tone: SessionPresentation.Tone {
        switch self {
        case .sent, .identity: return .active
        case .draft, .skipped: return .warning
        case .failed: return .critical
        }
    }
}

enum PerfFormat {
    static func duration(_ ms: Int) -> String {
        if ms >= 1000 { return String(format: "%.2fs", Double(ms) / 1000.0) }
        return "\(ms)ms"
    }
}

struct PerformanceMonitorSection: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var sessions: SessionsStore
    @ObservedObject private var settings: SettingsStore

    private let overrideMetrics: SystemMetricsResult?
    @State private var showRecent = false
    @State private var loading = false

    init(workspace: V2Workspace, overrideMetrics: SystemMetricsResult? = nil, showRecent: Bool = false) {
        self.workspace = workspace
        self.runtime = workspace.runtime
        self.sessions = workspace.sessions
        self.settings = workspace.settings
        self.overrideMetrics = overrideMetrics
        _showRecent = State(initialValue: showRecent)
    }

    private var metrics: SystemMetricsResult? { overrideMetrics ?? sessions.metrics }

    var body: some View {
        Section {
            if let data = metrics, data.sampleCount > 0 {
                kpiStrip(data)
                stackedWaterfall(data)
                stageBreakdown(data)
                recentDisclosure(data)
            } else {
                Text("暂无已完成的回复回合统计。开启任一会话的拟稿或自动回复后，这里将长期记录 6 段耗时与瓶颈归因。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
            }
        } header: {
            HStack(spacing: 8) {
                Label("执行耗时与瓶颈分析", systemImage: "speedometer")
                if let bottleneck = metrics?.primaryBottleneck {
                    StatusPill(text: "主瓶颈：\(bottleneck.title)", tone: (metrics?.slowCount ?? 0) > 0 ? .critical : .warning)
                }
                Spacer()
                Picker("时间窗", selection: Binding(
                    get: { sessions.metricsWindowHours },
                    set: { hours in reload(windowHours: hours) }
                )) {
                    Text("1 小时").tag(1)
                    Text("24 小时").tag(24)
                    Text("7 天").tag(168)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(width: 170)
                .accessibilityIdentifier("perf-window-picker")
                Button { reload(windowHours: sessions.metricsWindowHours) } label: {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(!runtime.ready || loading)
                .help("刷新性能统计")
                .accessibilityIdentifier("perf-refresh")
            }
        } footer: {
            Text("纯数值毫秒埋点，跨重启保存在本机数据库（保留 14 天 / 2000 条），绝不记录聊天正文、昵称或密钥。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("overview-perf-section")
    }

    private func kpiStrip(_ data: SystemMetricsResult) -> some View {
        HStack(spacing: 0) {
            kpi("P50 总耗时", PerfFormat.duration(data.total.p50Ms), tint: .primary)
            Divider().frame(height: 28)
            kpi("P95 总耗时", PerfFormat.duration(data.total.p95Ms), tint: data.total.p95Ms >= data.slowThresholdMs ? .orange : .primary)
            Divider().frame(height: 28)
            kpi("慢轮次 (≥\(data.slowThresholdMs / 1000)s)", "\(data.slowCount) / \(data.sampleCount)", tint: data.slowCount > 0 ? .red : .green)
            Divider().frame(height: 28)
            let hitRate = data.sampleCount > 0 ? Int(round(Double(data.promptCacheHitCount) * 100.0 / Double(data.sampleCount))) : 0
            kpi("提示词缓存命中", "\(hitRate)%", tint: .indigo)
        }
        .padding(.vertical, 2)
    }

    private func kpi(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(tint).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private func stackedWaterfall(_ data: SystemMetricsResult) -> some View {
        let totalAvg = max(1, data.stages.reduce(0) { $0 + $1.avgMs })
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(data.stages) { item in
                        if item.avgMs > 0 {
                            let width = max(4, geo.size.width * CGFloat(item.avgMs) / CGFloat(totalAvg))
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(item.stage.color)
                                .frame(width: width)
                                .help("\(item.stage.title)：均值 \(PerfFormat.duration(item.avgMs))（\(item.sharePercent)%）")
                        }
                    }
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            HStack(spacing: 10) {
                ForEach(data.stages) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.stage.color).frame(width: 7, height: 7)
                        Text("\(item.stage.shortTitle) \(item.sharePercent)%")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func stageBreakdown(_ data: SystemMetricsResult) -> some View {
        VStack(spacing: 5) {
            ForEach(data.stages) { item in
                let isPrimary = data.primaryBottleneck == item.stage
                HStack(spacing: 8) {
                    Circle().fill(item.stage.color).frame(width: 8, height: 8)
                    Text(item.stage.title).font(.caption.weight(isPrimary ? .semibold : .regular))
                    if isPrimary { StatusPill(text: "最慢", tone: .warning) }
                    Spacer()
                    Text("占比 \(item.sharePercent)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
                    Text("P50 \(PerfFormat.duration(item.p50Ms))").font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                    Text("P95 \(PerfFormat.duration(item.p95Ms))").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                }
            }
        }
    }

    private func recentDisclosure(_ data: SystemMetricsResult) -> some View {
        DisclosureGroup(isExpanded: $showRecent) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(data.recent.prefix(12)) { sample in
                    let label = settings.saved.conversations[sample.conversationId]?.label ?? V2Format.tail(sample.conversationId)
                    let isSlow = sample.totalMs >= data.slowThresholdMs
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(V2Format.clockWithSeconds(sample.at)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Text(label).font(.caption.weight(.medium)).lineLimit(1)
                            StatusPill(text: sample.outcome.title, tone: sample.outcome.tone)
                            StatusPill(text: "瓶颈·\(sample.bottleneck.shortTitle)", tone: isSlow ? .critical : .neutral)
                            Spacer()
                            Text(PerfFormat.duration(sample.totalMs))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isSlow ? Color.red : Color.primary)
                        }
                        Text("入站 \(sample.ingestMs) · 防抖 \(sample.debounceMs) · 提示词 \(sample.promptMs)\(sample.promptCacheHit ? "(缓存)" : "") · 首包 \(sample.modelTtftMs) · 生成 \(sample.modelGenMs) · 发信 \(sample.sendTotalMs)ms（校验 \(sample.fenceMs)+提交 \(sample.sendWireMs)）\(sample.effort.map { " · effort=\($0.rawValue)" } ?? "")")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    if sample.id != data.recent.prefix(12).last?.id { Divider() }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("最近 \(min(12, data.recent.count)) 轮分段明细").font(.callout)
        }
        .accessibilityIdentifier("perf-recent-disclosure")
    }

    private func reload(windowHours: Int) {
        guard runtime.ready else {
            sessions.metricsWindowHours = windowHours
            return
        }
        loading = true
        let sessions = sessions
        Task { @MainActor in
            defer { loading = false }
            try? await sessions.loadMetrics(windowHours: windowHours)
        }
    }
}
