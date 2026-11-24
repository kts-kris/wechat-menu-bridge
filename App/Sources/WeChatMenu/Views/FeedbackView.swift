import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 版本

enum AppVersion {
    // swift test 的 Bundle.main 是测试运行器，不能把它的版本号当成 App 版本。
    static let fallbackShort = "2.1.0"
    static let fallbackBuild = "21"

    private static var info: [String: Any]? {
        let value = Bundle.main.infoDictionary
        return value?["CFBundleExecutable"] as? String == "WeChatMenuBridge" ? value : nil
    }

    static var short: String { info?["CFBundleShortVersionString"] as? String ?? fallbackShort }
    static var build: String { info?["CFBundleVersion"] as? String ?? fallbackBuild }
    static var display: String { "\(short) (\(build))" }
}

// MARK: - 诊断数据

enum FeedbackCategory: String, CaseIterable, Identifiable {
    case malfunction, model, experience

    var id: String { rawValue }

    var title: String {
        switch self {
        case .malfunction: return "功能故障"
        case .model: return "模型与回复"
        case .experience: return "界面与体验"
        }
    }
}

struct FeedbackDraft: Equatable {
    var category = FeedbackCategory.malfunction
    var title = ""
    var details = ""
}

// 只保存结构化状态。这里没有昵称、草稿、模型地址和模型名的字段，报告也就无从带出它们。
struct DiagnosticSnapshot: Equatable {
    struct Session: Equatable {
        let tail: String
        let type: ScopeType
        let phase: SessionRuntimeState.Phase
        let replyMode: SessionReplyMode
        let reason: String?
    }

    struct Model: Equatable {
        let mode: ModelMode
        let kind: ModelKind
        let reasoningEffort: ReasoningEffort?
    }

    var appVersion = AppVersion.display
    var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var architecture = DiagnosticBundleBuilder.architecture
    var generatedAt = Date()
    var backendReady = false
    var globalPhase = GlobalPhase.idle
    var xiaoheConfigured = false
    var accountBound = false
    var capabilities: XiaoheCapabilities?
    var sessions: [Session] = []
    var models: [Model] = []

    @MainActor
    static func capture(_ workspace: V2Workspace) -> Self {
        let saved = workspace.settings.saved
        let states = workspace.sessions.sessions
        let sessions = saved.conversations.values.map { policy in
            let state = states[policy.conversationId]
            return Session(tail: DiagnosticBundleBuilder.conversationTail(policy.conversationId), type: policy.type,
                           phase: state?.phase ?? .idle, replyMode: state?.replyMode ?? .off, reason: state?.reason?.rawValue)
        }.sorted { $0.tail < $1.tail }
        return Self(backendReady: workspace.runtime.ready, globalPhase: workspace.runtime.globalPhase,
                    xiaoheConfigured: !saved.xiaohe.mcpUrl.isEmpty, accountBound: !saved.xiaohe.accountId.isEmpty,
                    capabilities: workspace.runtime.capabilities, sessions: sessions,
                    models: saved.models.map { Model(mode: $0.mode, kind: $0.kind, reasoningEffort: $0.reasoningEffort) })
    }
}

// MARK: - 报告构建

enum DiagnosticBundleBuilder {
    static let logLineLimit = 120
    private static let maxLogBytes = 512 * 1024
    private static let maxIssueBodyCharacters = 1500

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    // 过短的 ID 取后 6 位等于完整暴露，改为只留一半。
    static func conversationTail(_ id: String) -> String {
        "…" + id.suffix(id.count > 6 ? 6 : max(1, id.count / 2))
    }

    // MARK: 脱敏

    private static let redactions: [(NSRegularExpression, String)] = [
        // URL 查询串和 userinfo 都可能带凭据，整段替换。
        (#"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>`]+"#, "[URL 已脱敏]"),
        (#"(?i)\b(bearer|basic)\s+[^\s"',;]+"#, "$1 [已脱敏]"),
        (#"(?i)(?<![A-Za-z0-9])(x-api-key|api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|auth[_-]?token|client[_-]?secret|authorization|password|passwd|secret|token|cookie)(["']?\s*[:=]\s*)(["']?)(?!bearer\b|basic\b)[^\s"',;&}]+\3"#, "$1$2[已脱敏]"),
        (#"(?i)(?<![A-Za-z0-9])sk[-_][A-Za-z0-9_-]{4,}"#, "[密钥已脱敏]"),
        (#"(?<![A-Za-z0-9])(?:gh[pousr]|github_pat|xox[abprs])[-_][A-Za-z0-9_-]{8,}"#, "[密钥已脱敏]"),
        (#"[A-Za-z0-9+/_=.-]{24,}"#, "[长令牌已脱敏]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ text: String) -> String {
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for (pattern, template) in redactions {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                      withTemplate: template)
        }
        return result
    }

    // 只放行引擎日志的已知字段；解析不了的行可能含任意内容，直接省略。
    static func sanitizedLogLine(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = (row["at"] as? NSNumber)?.int64Value,
              let stage = (row["stage"] as? String).flatMap(SessionTraceEntry.Stage.init(rawValue:)),
              let level = (row["level"] as? String).flatMap(SessionTraceEntry.Level.init(rawValue:)),
              let summary = row["summary"] as? String else { return nil }
        let time = V2Format.date(at).formatted(.iso8601)
        let session = (row["session"] as? String).map(conversationTail) ?? "-"
        let code = (row["code"] as? String).flatMap { value in
            value.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) == nil ? nil : value
        }
        let text = redact(String(summary.prefix(300))).replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(time) \(stage.rawValue)/\(level.rawValue) \(session) \(text)" + (code.map { " (\($0))" } ?? "")
    }

    // 只读取 engine.log 末尾，且拒绝符号链接，避免被指向其他文件。
    static func readLogTail(at url: URL, limit: Int = logLineLimit) -> [String] {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
        let size = UInt64(max(info.st_size, 0))
        let offset = size > UInt64(maxLogBytes) ? size - UInt64(maxLogBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
        // 从文件中段开始读时，第一行可能不完整。
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.suffix(limit))
    }

    // MARK: 报告

    static func buildReport(snapshot: DiagnosticSnapshot, logLines: [String], feedback: FeedbackDraft = FeedbackDraft()) -> String {
        var out = ["# 微信桥诊断报告", "", "> 已自动脱敏：不含聊天正文、昵称、模型地址、API Key 或访问令牌。", ""]
        out += feedbackSection(feedback)
        out += ["## 环境",
                "- App 版本：\(snapshot.appVersion)",
                "- macOS：\(snapshot.osVersion)",
                "- CPU 架构：\(snapshot.architecture)",
                "- 生成时间：\(snapshot.generatedAt.formatted(.iso8601))", ""]
        out += ["## 运行状态",
                "- 后台就绪：\(yesNo(snapshot.backendReady))",
                "- 全局阶段：\(snapshot.globalPhase.rawValue)",
                "- 小禾已配置：\(yesNo(snapshot.xiaoheConfigured))",
                "- 账号已绑定：\(yesNo(snapshot.accountBound))",
                "- 小禾能力：\(capabilitySummary(snapshot.capabilities))", ""]
        out += ["## 会话（\(snapshot.sessions.count)）"]
        out += snapshot.sessions.isEmpty ? ["- 无"] : snapshot.sessions.map { row in
            "- \(row.tail) · \(row.type.rawValue) · \(row.phase.rawValue) · \(row.replyMode.rawValue)" + (row.reason.map { " · \($0)" } ?? "")
        }
        out += ["", "## 模型（\(snapshot.models.count)）"]
        out += snapshot.models.isEmpty ? ["- 无"] : snapshot.models.map { row in
            "- \(row.mode.rawValue) · \(row.kind.rawValue) · 推理强度 \(row.reasoningEffort?.rawValue ?? "默认")"
        }
        let recent = logLines.suffix(logLineLimit)
        let clean = recent.compactMap(sanitizedLogLine)
        out += ["", "## 引擎日志（最近 \(clean.count) 行）"]
        if recent.count > clean.count { out.append("已省略 \(recent.count - clean.count) 行无法识别的日志。") }
        out += ["```"] + (clean.isEmpty ? ["（无日志）"] : clean) + ["```", ""]
        return out.joined(separator: "\n")
    }

    private static func feedbackSection(_ feedback: FeedbackDraft) -> [String] {
        let title = redact(feedback.title.trimmingCharacters(in: .whitespacesAndNewlines))
        let details = redact(feedback.details.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !title.isEmpty || !details.isEmpty else { return [] }
        var lines = ["## 问题描述", "- 分类：\(feedback.category.title)"]
        if !title.isEmpty { lines.append("- 标题：\(title)") }
        if !details.isEmpty { lines += ["", details] }
        return lines + [""]
    }

    private static func yesNo(_ value: Bool) -> String { value ? "是" : "否" }

    static func capabilitySummary(_ value: XiaoheCapabilities?) -> String {
        guard let value else { return "未探测" }
        let rows: [(String, Bool)] = [
            ("账号级事件流", value.accountWideEvents), ("会话列表", value.listConversations), ("群成员", value.groupMembers),
            ("历史查询", value.historyQuery), ("历史搜索", value.historySearch), ("媒体读取", value.readMedia),
            ("原生引用回复", value.nativeReply), ("群内 @", value.mentionSend), ("发送文字", value.canSendText),
        ]
        let enabled = rows.filter(\.1).map(\.0)
        return "\(enabled.count)/\(rows.count)" + (enabled.isEmpty ? "" : "（\(enabled.joined(separator: "、"))）")
    }

    // MARK: Issue

    // 接受 owner/repo、GitHub 网址和 SSH 地址。
    static func repositorySlug(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:", "github.com/"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            part != "." && part != ".." && part.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil
        }) else { return nil }
        return value
    }

    // 预填内容只放问题描述和版本，完整报告由用户自行附加，避免 URL 过长或带出运行细节。
    static func issueURL(repository: String, snapshot: DiagnosticSnapshot, feedback: FeedbackDraft) -> URL? {
        guard let slug = repositorySlug(repository) else { return nil }
        let title = redact(feedback.title.trimmingCharacters(in: .whitespacesAndNewlines))
        let details = redact(feedback.details.trimmingCharacters(in: .whitespacesAndNewlines))
        let body = """
        ### 问题描述
        \(details.isEmpty ? "（请填写复现步骤）" : String(details.prefix(maxIssueBodyCharacters)))

        ### 环境
        - 分类：\(feedback.category.title)
        - App 版本：\(snapshot.appVersion)
        - macOS：\(snapshot.osVersion) · \(snapshot.architecture)

        > 请把「导出诊断文件」生成的脱敏报告拖到这里作为附件。
        """
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(slug)/issues/new"
        components.queryItems = [URLQueryItem(name: "title", value: "[\(feedback.category.title)] \(title)"),
                                 URLQueryItem(name: "body", value: body)]
        // URLComponents 不转义 +，GitHub 会把它读成空格。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    static func exportFilename(at date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "WeChatMenuBridge-diagnostic-%04d%02d%02d-%02d%02d.md",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - 反馈面板

struct FeedbackSheet: View {
    private static let repositoryKey = "v2.feedbackRepository"

    @ObservedObject var workspace: V2Workspace
    let dismiss: () -> Void

    @AppStorage(Self.repositoryKey) private var repository = ""
    @State private var draft = FeedbackDraft()
    @State private var snapshot: DiagnosticSnapshot
    @State private var logLines: [String] = []
    @State private var previewExpanded = false
    @State private var notice: (text: String, tone: SessionPresentation.Tone)?

    init(workspace: V2Workspace, dismiss: @escaping () -> Void) {
        self.workspace = workspace
        self.dismiss = dismiss
        _snapshot = State(initialValue: DiagnosticSnapshot.capture(workspace))
    }

    private var report: String {
        DiagnosticBundleBuilder.buildReport(snapshot: snapshot, logLines: logLines, feedback: draft)
    }

    private var issueURL: URL? {
        DiagnosticBundleBuilder.issueURL(repository: repository, snapshot: snapshot, feedback: draft)
    }

    private var repositoryInvalid: Bool {
        !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && DiagnosticBundleBuilder.repositorySlug(repository) == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("反馈问题").font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.top, 14).padding(.bottom, 4)
            Form {
                Section {
                    Picker("问题分类", selection: $draft.category) {
                        ForEach(FeedbackCategory.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("feedback-category")
                    TextField("标题", text: $draft.title, prompt: Text("一句话概括问题"))
                        .accessibilityIdentifier("feedback-title")
                    TextField("复现描述", text: $draft.details, prompt: Text("做了什么、期望什么、实际发生了什么"), axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("feedback-details")
                } header: {
                    Text("描述问题")
                } footer: {
                    Text("请不要粘贴聊天内容。文字里的密钥、令牌和网址会被自动脱敏。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("预览脱敏诊断摘要", isExpanded: $previewExpanded) {
                        if previewExpanded {
                            ScrollView {
                                Text(report)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 220)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityIdentifier("feedback-preview")
                        }
                    }
                } header: {
                    Text("诊断摘要")
                } footer: {
                    Text("包含版本、运行状态、脱敏后的会话状态和最近 \(DiagnosticBundleBuilder.logLineLimit) 行引擎日志。不读取密钥文件。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("GitHub Issue") {
                    TextField("仓库", text: $repository, prompt: Text("owner/repo"))
                        .font(.callout.monospaced())
                        .accessibilityIdentifier("feedback-repository")
                    if repositoryInvalid {
                        InlineNotice(text: "请填写 owner/repo 或 GitHub 仓库地址。", tone: .warning)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 600, height: 640)
        .task {
            let url = workspace.settings.disk.directory.appendingPathComponent("engine.log")
            logLines = await Task.detached(priority: .userInitiated) { DiagnosticBundleBuilder.readLogTail(at: url) }.value
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice { InlineNotice(text: notice.text, tone: notice.tone) }
            HStack(spacing: 8) {
                Button(action: copy) { Label("复制诊断摘要", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("feedback-copy")
                Button(action: export) { Label("导出诊断文件…", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("feedback-export")
                Spacer(minLength: 8)
                Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
                Button(action: openIssue) { Label("打开 Issue 提交页", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.borderedProminent)
                    .disabled(issueURL == nil)
                    .help(issueURL == nil ? "请先填写 GitHub 仓库" : "在浏览器中打开预填好的 Issue，提交前可再修改")
                    .accessibilityIdentifier("feedback-open-issue")
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        notice = ("诊断摘要已复制。", .active)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "导出诊断文件"
        panel.nameFieldStringValue = DiagnosticBundleBuilder.exportFilename()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let content = report
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(content.utf8).write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                notice = ("已导出到 \(url.lastPathComponent)。", .active)
            } catch {
                notice = ("导出失败，请换一个位置重试。", .critical)
            }
        }
    }

    private func openIssue() {
        guard let issueURL else { return }
        if NSWorkspace.shared.open(issueURL) {
            notice = ("已在浏览器打开，请在网页上确认后提交。", .active)
        } else {
            notice = ("无法打开浏览器。", .critical)
        }
    }
}
