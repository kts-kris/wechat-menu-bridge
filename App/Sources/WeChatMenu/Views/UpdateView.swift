import SwiftUI

// MARK: - 软件更新与热更新资产

struct UpdateSettingsCard: View {
    static let anchor = "update-settings-section"

    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var updater: AppUpdater
    @ObservedObject private var runtime: BridgeRuntime

    @State private var bundles: HotBundlesStatus?
    @State private var bundlesBusy = false
    @State private var bundlesFault: String?

    init(workspace: V2Workspace) {
        self.workspace = workspace
        updater = workspace.updater
        runtime = workspace.runtime
    }

    private var feedIsEmpty: Bool { updater.feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var keyIsEmpty: Bool { updater.ed25519PublicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Section("软件更新与热更新资产") {
            LabeledContent("当前版本") {
                Text("v\(AppVersion.display)").monospacedDigit().textSelection(.enabled)
            }
            Picker("更新通道", selection: $updater.channel) {
                ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
            }
            .disabled(updater.isBusy)
            .accessibilityIdentifier("update-channel")
            TextField("更新源地址", text: $updater.feedURL, prompt: Text("https://example.com/appcast.xml 或 appcast.json"))
                .font(.callout.monospaced())
                .disabled(updater.isBusy)
                .accessibilityIdentifier("update-feed-url")
            if !feedIsEmpty && !updater.hasValidFeed {
                InlineNotice(text: "更新源必须是 HTTPS 地址。", tone: .warning)
            }
            if let key = updater.requiredPublicKey {
                LabeledContent("内置发布公钥") {
                    Text(key).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                TextField("Ed25519 公钥（可选）", text: $updater.ed25519PublicKey, prompt: Text("Base64 公钥，配置后强制校验签名"))
                    .font(.callout.monospaced())
                    .disabled(updater.isBusy)
                    .accessibilityIdentifier("update-public-key")
                if !updater.hasValidPublicKey {
                    InlineNotice(text: "公钥格式不正确，需要 32 字节的 Base64。", tone: .warning)
                } else if keyIsEmpty && !feedIsEmpty {
                    InlineNotice(text: "未配置公钥时只能校验文件完整性，无法确认安装包来自发布者。", tone: .warning)
                }
                if updater.environment.builtInSource != nil {
                    Button("恢复内置更新源", action: updater.restoreBuiltInFeed).disabled(updater.isBusy)
                }
            }
            statusRow
            details
            HotBundlesRow(status: bundles, busy: bundlesBusy, fault: bundlesFault, ready: runtime.ready, reload: reloadBundles)
        }
        .id(Self.anchor)
        .task(id: runtime.ready) { await loadBundles() }
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 10) {
            statusText
            Spacer()
            if case .downloading = updater.state {
                Button("取消", action: updater.cancelDownload).accessibilityIdentifier("update-cancel")
            }
            Button {
                Task { await updater.checkForUpdates() }
            } label: {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(updater.isBusy || !updater.hasValidFeed || isReady)
            .accessibilityIdentifier("update-check")
        }
    }

    private var isReady: Bool {
        if case .readyToInstall = updater.state { return true }
        return false
    }

    @ViewBuilder private var statusText: some View {
        switch updater.state {
        case .idle:
            Text(feedIsEmpty ? "填写更新源后可检查更新" : "尚未检查").font(.callout).foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
            Text("正在检查更新…").font(.callout).foregroundStyle(.secondary)
        case .upToDate(let checkedAt):
            StatusPill(text: "已是最新版本", tone: .active, symbol: "checkmark.circle.fill")
            Text("检查于 \(checkedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        case .available(let release):
            StatusPill(text: "发现新版本 v\(release.version)", tone: .active, symbol: "arrow.down.circle.fill")
        case .downloading(let progress):
            ProgressView(value: progress).frame(maxWidth: 220).accessibilityLabel("下载进度")
            Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        case .verifying:
            ProgressView().controlSize(.small)
            Text("正在校验安装包…").font(.callout).foregroundStyle(.secondary)
        case .readyToInstall(let release, _):
            StatusPill(text: "v\(release.version) 已通过校验", tone: .active, symbol: "checkmark.seal.fill")
        case .failed(let message):
            InlineNotice(text: message, tone: .critical)
        }
    }

    @ViewBuilder private var details: some View {
        if let release = updater.latestRelease {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(release.title.isEmpty ? "v\(release.version)" : release.title).font(.callout.weight(.medium))
                    if release.channel == UpdateChannel.beta.rawValue { StatusPill(text: "测试版", tone: .warning) }
                    if let date = release.publishedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !release.notes.isEmpty {
                    Text(release.notes).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(8).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let notice = updater.installNotice { InlineNotice(text: notice, tone: .warning) }
            HStack {
                Spacer()
                Button {
                    Task { await updater.downloadAndInstall() }
                } label: {
                    Label(isReady ? "立即重启更新" : "下载并重启更新", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(updater.isBusy)
                .accessibilityIdentifier("update-install")
            }
        }
    }

    private func loadBundles() async {
        guard runtime.ready else {
            bundles = nil
            return
        }
        await callBundles("status")
    }

    private func reloadBundles() {
        Task { await callBundles("reload") }
    }

    private func callBundles(_ action: String) async {
        guard !bundlesBusy else { return }
        bundlesBusy = true
        bundlesFault = nil
        defer { bundlesBusy = false }
        do { bundles = try await runtime.client.systemBundles(action: action) }
        catch { bundlesFault = V2Workspace.code(error) }
    }
}

struct HotBundlesRow: View {
    let status: HotBundlesStatus?
    let busy: Bool
    let fault: String?
    let ready: Bool
    let reload: () -> Void

    private var summary: String {
        guard let status else { return ready ? "正在读取…" : "引擎未就绪" }
        var parts = ["已加载 \(status.loadedCount) 项"]
        if let version = status.version { parts.append("版本 \(version)") }
        if let at = status.lastReloadAt { parts.append("更新于 \(V2Format.clock(at))") }
        return parts.joined(separator: " · ")
    }

    private var unverified: Int { status?.items.filter { !$0.verified }.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("引擎热更新资产")
                    Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("重新加载热更新资产", action: reload)
                    .disabled(!ready || busy)
                    .accessibilityIdentifier("hot-bundles-reload")
            }
            if unverified > 0 { InlineNotice(text: "\(unverified) 项未通过校验。", tone: .warning) }
            if let fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
        }
        .accessibilityIdentifier("hot-bundles-status")
    }
}
