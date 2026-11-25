import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 版本

enum AppVersion {
    // swift test 的 Bundle.main 是测试运行器，不能把它的版本号当成 App 版本。
    static let fallbackShort = "2.4.0"
    static let fallbackBuild = "25"

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

    var githubLabels: [String] {
        switch self {
        case .malfunction: return ["bug"]
        case .model: return ["bug", "bug/llm"]
        case .experience: return ["enhancement", "bug/ui"]
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

    struct PerfSummary: Equatable {
        struct PresetRow: Equatable {
            let mode: ModelMode?
            let turns: Int
            let p50TotalMs: Int
            let p50TtftMs: Int
            let kvCacheHitRate: Int
            let totalTokens: Int
            let estimatedCostUsd: Double
        }

        let windowHours: Int
        let sampleCount: Int
        let slowCount: Int
        let p50Ms: Int
        let p95Ms: Int
        let maxMs: Int
        let primaryBottleneck: PerfStage?
        let stageShares: [(stage: PerfStage, sharePercent: Int, p50Ms: Int, p95Ms: Int)]
        var promptTokens: Int = 0
        var cachedTokens: Int = 0
        var completionTokens: Int = 0
        var kvCacheHitRate: Int = 0
        var estimatedCostUsd: Double = 0
        var presets: [PresetRow] = []

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.windowHours == rhs.windowHours && lhs.sampleCount == rhs.sampleCount && lhs.slowCount == rhs.slowCount
                && lhs.p50Ms == rhs.p50Ms && lhs.p95Ms == rhs.p95Ms && lhs.maxMs == rhs.maxMs
                && lhs.primaryBottleneck == rhs.primaryBottleneck
                && lhs.promptTokens == rhs.promptTokens && lhs.cachedTokens == rhs.cachedTokens
                && lhs.completionTokens == rhs.completionTokens && lhs.kvCacheHitRate == rhs.kvCacheHitRate
                && lhs.estimatedCostUsd == rhs.estimatedCostUsd && lhs.presets == rhs.presets
                && lhs.stageShares.count == rhs.stageShares.count
                && zip(lhs.stageShares, rhs.stageShares).allSatisfy {
                    $0.stage == $1.stage && $0.sharePercent == $1.sharePercent && $0.p50Ms == $1.p50Ms && $0.p95Ms == $1.p95Ms
                }
        }
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
    var perfSummary: PerfSummary? = nil

    @MainActor
    static func capture(_ workspace: V2Workspace) -> Self {
        let saved = workspace.settings.saved
        let states = workspace.sessions.sessions
        let sessions = saved.conversations.values.map { policy in
            let state = states[policy.conversationId]
            return Session(tail: DiagnosticBundleBuilder.conversationTail(policy.conversationId), type: policy.type,
                           phase: state?.phase ?? .idle, replyMode: state?.replyMode ?? .off, reason: state?.reason?.rawValue)
        }.sorted { $0.tail < $1.tail }
        let perf = workspace.sessions.metrics.flatMap { m -> PerfSummary? in
            guard m.sampleCount > 0 else { return nil }
            return PerfSummary(
                windowHours: m.windowHours, sampleCount: m.sampleCount, slowCount: m.slowCount,
                p50Ms: m.total.p50Ms, p95Ms: m.total.p95Ms, maxMs: m.total.maxMs,
                primaryBottleneck: m.primaryBottleneck,
                stageShares: m.stages.map { ($0.stage, $0.sharePercent, $0.p50Ms, $0.p95Ms) },
                promptTokens: m.tokens.promptTokens, cachedTokens: m.tokens.cachedTokens,
                completionTokens: m.tokens.completionTokens, kvCacheHitRate: m.tokens.kvCacheHitRate,
                estimatedCostUsd: m.tokens.estimatedCostUsd,
                presets: m.byPreset.map {
                    .init(mode: $0.mode, turns: $0.turns, p50TotalMs: $0.p50TotalMs, p50TtftMs: $0.p50TtftMs,
                          kvCacheHitRate: $0.kvCacheHitRate, totalTokens: $0.promptTokens + $0.completionTokens,
                          estimatedCostUsd: $0.estimatedCostUsd)
                }
            )
        }
        return Self(backendReady: workspace.runtime.ready, globalPhase: workspace.runtime.globalPhase,
                    xiaoheConfigured: !saved.xiaohe.mcpUrl.isEmpty, accountBound: !saved.xiaohe.accountId.isEmpty,
                    capabilities: workspace.runtime.capabilities, sessions: sessions,
                    models: saved.models.map { Model(mode: $0.mode, kind: $0.kind, reasoningEffort: $0.reasoningEffort) },
                    perfSummary: perf)
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
        if let perf = snapshot.perfSummary {
            out += ["", "## 性能画像（最近 \(perf.windowHours) 小时，\(perf.sampleCount) 轮）",
                    "- 端到端耗时：P50 \(perf.p50Ms)ms · P95 \(perf.p95Ms)ms · Max \(perf.maxMs)ms · 慢轮次 \(perf.slowCount)"]
            if let bottleneck = perf.primaryBottleneck {
                out.append("- 当前主瓶颈：\(bottleneck.title)（\(bottleneck.rawValue)）")
            }
            for item in perf.stageShares {
                out.append("- \(item.stage.title)：占比 \(item.sharePercent)% · P50 \(item.p50Ms)ms · P95 \(item.p95Ms)ms")
            }
            if perf.promptTokens > 0 || perf.completionTokens > 0 {
                let costPart = perf.estimatedCostUsd > 0 ? " · 估算费用 \(PerfFormat.costUsd(perf.estimatedCostUsd))" : ""
                out.append("- Token 用量：输入 \(perf.promptTokens)（KV 缓存命中 \(perf.cachedTokens) / \(perf.kvCacheHitRate)%）· 输出 \(perf.completionTokens)\(costPart)")
            }
            for (idx, preset) in perf.presets.enumerated() {
                let modeLabel = preset.mode?.rawValue ?? "unknown"
                let costPart = preset.estimatedCostUsd > 0 ? " · \(PerfFormat.costUsd(preset.estimatedCostUsd))" : ""
                out.append("- 预设 #\(idx + 1)（\(modeLabel)）：\(preset.turns) 轮 · 首包 P50 \(preset.p50TtftMs)ms · 总耗 P50 \(preset.p50TotalMs)ms · KV \(preset.kvCacheHitRate)% · Token \(preset.totalTokens)\(costPart)")
            }
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

    static let defaultRepository = "kts-kris/wechat-menu-bridge"
    private static let maxDirectIssueBodyCharacters = 32_000

    struct GitHubIssuePayload: Equatable, Sendable {
        let repository: String
        let title: String
        let body: String
        let labels: [String]
    }

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

    /// 构造用于自动提交到 GitHub Issues API 的完整脱敏载荷；要求标题非空且仓库合法。
    static func issuePayload(repository: String, snapshot: DiagnosticSnapshot, logLines: [String],
                             feedback: FeedbackDraft, includeDiagnostics: Bool = true) -> GitHubIssuePayload? {
        guard let slug = repositorySlug(repository) else { return nil }
        let cleanTitle = redact(feedback.title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanTitle.isEmpty else { return nil }
        let cleanDetails = redact(feedback.details.trimmingCharacters(in: .whitespacesAndNewlines))
        var sections: [String] = [
            """
            ### 问题描述
            \(cleanDetails.isEmpty ? "（用户未填写详细复现步骤）" : cleanDetails)

            ### 环境
            - 分类：\(feedback.category.title)
            - App 版本：\(snapshot.appVersion)
            - macOS：\(snapshot.osVersion) · \(snapshot.architecture)
            - 提交方式：微信桥应用内自动提交
            """
        ]
        if includeDiagnostics {
            let fullReport = buildReport(snapshot: snapshot, logLines: logLines, feedback: feedback)
            let clipped = fullReport.count > maxDirectIssueBodyCharacters - 2000
                ? String(fullReport.prefix(maxDirectIssueBodyCharacters - 2000)) + "\n…（诊断报告已截断）"
                : fullReport
            sections.append("""
            <details>
            <summary>脱敏诊断报告（已自动移除密钥、令牌与聊天正文）</summary>

            \(clipped)
            </details>
            """)
        }
        let body = String(sections.joined(separator: "\n\n").prefix(maxDirectIssueBodyCharacters))
        return GitHubIssuePayload(repository: slug, title: "[\(feedback.category.title)] \(String(cleanTitle.prefix(200)))",
                                  body: body, labels: feedback.category.githubLabels)
    }

    static func exportFilename(at date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "WeChatMenuBridge-diagnostic-%04d%02d%02d-%02d%02d.md",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - GitHub Issue 自动提交

/// 禁止 API 请求跟随任何 HTTP 重定向，防止 Authorization 头泄漏到非目标域名。
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GitHubIssueSubmitter: Sendable {
    enum Method: String, Equatable, Sendable {
        case token = "GitHub Token"
        case ghCLI = "本机 gh CLI"
    }

    struct CreatedIssue: Equatable, Sendable {
        let number: Int
        let url: URL
        let title: String
        let via: Method
    }

    enum AuthAvailability: Equatable, Sendable {
        case savedToken
        case ghCLI(path: String)
        case unavailable
    }

    struct ProcessOutput: Equatable, Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    enum SubmitError: LocalizedError, Equatable {
        case invalidPayload
        case missingAuth
        case unauthorized
        case forbidden(String)
        case notFound
        case httpFailure(Int, String)
        case networkFailure(String)
        case cliFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidPayload: return "请先填写问题标题和有效的 GitHub 仓库。"
            case .missingAuth: return "未配置 GitHub Token 且本机未检测到已登录的 gh CLI。请填写 Token，或改用「浏览器打开」。"
            case .unauthorized: return "GitHub 认证失败（401），请检查 Token 是否有效或重新执行 gh auth login。"
            case .forbidden(let detail): return detail.isEmpty ? "没有该仓库的 Issue 写入权限（403），请确认 Token 具备 Issues: Write 权限。" : "权限不足（403）：\(detail)"
            case .notFound: return "未找到目标仓库或该仓库未开启 Issues（404）。"
            case .httpFailure(let code, let detail): return detail.isEmpty ? "GitHub 返回错误（HTTP \(code)）。" : "GitHub 返回错误（HTTP \(code)）：\(detail)"
            case .networkFailure(let detail): return "无法连接 GitHub API：\(detail)"
            case .cliFailure(let detail): return detail.isEmpty ? "通过本机 gh CLI 提交失败。" : "通过本机 gh CLI 提交失败：\(detail)"
            }
        }
    }

    typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias ProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ stdin: Data?) throws -> ProcessOutput

    let vault: KeychainVault
    let apiBaseURL: URL
    let ghSearchPaths: [String]
    let httpTransport: HTTPTransport
    let processRunner: ProcessRunner

    init(vault: KeychainVault = .standard,
         apiBaseURL: URL = URL(string: "https://api.github.com")!,
         ghSearchPaths: [String] = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"],
         httpTransport: @escaping HTTPTransport = { try await GitHubIssueSubmitter.defaultHTTPTransport($0) },
         processRunner: @escaping ProcessRunner = { try GitHubIssueSubmitter.defaultProcessRunner($0, $1, $2) }) {
        self.vault = vault
        self.apiBaseURL = apiBaseURL
        self.ghSearchPaths = ghSearchPaths
        self.httpTransport = httpTransport
        self.processRunner = processRunner
    }

    static func defaultHTTPTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        let delegate = NoRedirectSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SubmitError.networkFailure("收到非 HTTP 响应")
            }
            return (data, http)
        } catch let error as SubmitError {
            throw error
        } catch {
            throw SubmitError.networkFailure(error.localizedDescription)
        }
    }

    static func defaultProcessRunner(_ executable: String, _ arguments: [String], _ stdin: Data?) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }
        try process.run()
        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutput(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    func savedToken() -> String? {
        let raw = try? vault.read(.github())
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try vault.save(trimmed, for: .github())
    }

    func removeToken() throws {
        try vault.remove(.github())
    }

    func detectGHExecutable() -> String? {
        ghSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func detectAvailability() -> AuthAvailability {
        if savedToken() != nil { return .savedToken }
        if let gh = detectGHExecutable(),
           let status = try? processRunner(gh, ["auth", "status", "--hostname", "github.com"], nil),
           status.exitCode == 0 {
            return .ghCLI(path: gh)
        }
        return .unavailable
    }

    func submit(_ payload: DiagnosticBundleBuilder.GitHubIssuePayload, explicitToken: String? = nil) async throws -> CreatedIssue {
        guard let slug = DiagnosticBundleBuilder.repositorySlug(payload.repository), !payload.title.isEmpty else {
            throw SubmitError.invalidPayload
        }
        let typed = explicitToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty {
            return try await submitViaAPI(slug: slug, payload: payload, token: typed)
        }
        if let stored = savedToken() {
            return try await submitViaAPI(slug: slug, payload: payload, token: stored)
        }
        if let gh = detectGHExecutable() {
            return try submitViaGH(executable: gh, slug: slug, payload: payload)
        }
        throw SubmitError.missingAuth
    }

    private func encodeIssueBody(_ payload: DiagnosticBundleBuilder.GitHubIssuePayload, includeLabels: Bool) throws -> Data {
        var json: [String: Any] = ["title": payload.title, "body": payload.body]
        if includeLabels && !payload.labels.isEmpty { json["labels"] = payload.labels }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func submitViaAPI(slug: String, payload: DiagnosticBundleBuilder.GitHubIssuePayload, token: String) async throws -> CreatedIssue {
        var endpoint = apiBaseURL
        for component in ["repos"] + slug.split(separator: "/").map(String.init) + ["issues"] {
            endpoint.appendPathComponent(component)
        }
        func post(includeLabels: Bool) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = try encodeIssueBody(payload, includeLabels: includeLabels)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("WeChatMenuBridge/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
            return try await httpTransport(request)
        }
        var (data, response) = try await post(includeLabels: !payload.labels.isEmpty)
        if response.statusCode == 422 && !payload.labels.isEmpty && Self.isLabelError(data) {
            (data, response) = try await post(includeLabels: false)
        }
        switch response.statusCode {
        case 200...299:
            return try Self.parseCreatedIssue(data, via: .token)
        case 300...399:
            throw SubmitError.networkFailure("拒绝跟随非预期的重定向（HTTP \(response.statusCode)）")
        case 401:
            throw SubmitError.unauthorized
        case 403:
            throw SubmitError.forbidden(Self.extractGitHubMessage(data))
        case 404:
            throw SubmitError.notFound
        default:
            throw SubmitError.httpFailure(response.statusCode, Self.extractGitHubMessage(data))
        }
    }

    private func submitViaGH(executable: String, slug: String, payload: DiagnosticBundleBuilder.GitHubIssuePayload) throws -> CreatedIssue {
        func invoke(includeLabels: Bool) throws -> ProcessOutput {
            let input = try encodeIssueBody(payload, includeLabels: includeLabels)
            return try processRunner(executable, [
                "api", "--method", "POST",
                "-H", "Accept: application/vnd.github+json",
                "-H", "X-GitHub-Api-Version: 2022-11-28",
                "repos/\(slug)/issues",
                "--input", "-",
            ], input)
        }
        var result = try invoke(includeLabels: !payload.labels.isEmpty)
        if result.exitCode != 0 && !payload.labels.isEmpty &&
            (Self.isLabelError(result.stdout) || Self.isLabelError(result.stderr)) {
            result = try invoke(includeLabels: false)
        }
        guard result.exitCode == 0 else {
            let errText = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if errText.localizedCaseInsensitiveContains("not logged") || errText.localizedCaseInsensitiveContains("401") {
                throw SubmitError.unauthorized
            }
            if errText.localizedCaseInsensitiveContains("403") {
                throw SubmitError.forbidden(Self.extractGitHubMessage(result.stdout).isEmpty ? String(errText.prefix(160)) : Self.extractGitHubMessage(result.stdout))
            }
            if errText.localizedCaseInsensitiveContains("404") {
                throw SubmitError.notFound
            }
            let message = Self.extractGitHubMessage(result.stdout)
            throw SubmitError.cliFailure(message.isEmpty ? String(errText.prefix(200)) : message)
        }
        return try Self.parseCreatedIssue(result.stdout, via: .ghCLI)
    }

    private static func isLabelError(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("label")
    }

    private static func extractGitHubMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String {
            return String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        }
        return ""
    }

    private static func parseCreatedIssue(_ data: Data, via: Method) throws -> CreatedIssue {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["number"] as? Int,
              let urlString = object["html_url"] as? String,
              let url = URL(string: urlString),
              url.scheme == "https" else {
            throw SubmitError.networkFailure("无法解析 GitHub 返回的 Issue 信息")
        }
        let title = (object["title"] as? String) ?? "#\(number)"
        return CreatedIssue(number: number, url: url, title: title, via: via)
    }
}

// MARK: - 反馈面板

struct FeedbackSheet: View {
    private static let repositoryKey = "v2.feedbackRepository"

    @ObservedObject var workspace: V2Workspace
    let submitter: GitHubIssueSubmitter
    let dismiss: () -> Void

    @AppStorage(Self.repositoryKey) private var repository = DiagnosticBundleBuilder.defaultRepository
    @State private var draft = FeedbackDraft()
    @State private var snapshot: DiagnosticSnapshot
    @State private var logLines: [String] = []
    @State private var includeDiagnostics = true
    @State private var previewExpanded = false
    @State private var authExpanded = false
    @State private var tokenInput = ""
    @State private var authAvailability: GitHubIssueSubmitter.AuthAvailability = .unavailable
    @State private var submitting = false
    @State private var submittedIssue: GitHubIssueSubmitter.CreatedIssue?
    @State private var notice: (text: String, tone: SessionPresentation.Tone)?

    init(workspace: V2Workspace, submitter: GitHubIssueSubmitter = GitHubIssueSubmitter(), dismiss: @escaping () -> Void) {
        self.workspace = workspace
        self.submitter = submitter
        self.dismiss = dismiss
        _snapshot = State(initialValue: DiagnosticSnapshot.capture(workspace))
    }

    private var report: String {
        DiagnosticBundleBuilder.buildReport(snapshot: snapshot, logLines: logLines, feedback: draft)
    }

    private var effectiveRepository: String {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? DiagnosticBundleBuilder.defaultRepository : trimmed
    }

    private var issueURL: URL? {
        DiagnosticBundleBuilder.issueURL(repository: effectiveRepository, snapshot: snapshot, feedback: draft)
    }

    private var issuePayload: DiagnosticBundleBuilder.GitHubIssuePayload? {
        DiagnosticBundleBuilder.issuePayload(repository: effectiveRepository, snapshot: snapshot,
                                             logLines: logLines, feedback: draft, includeDiagnostics: includeDiagnostics)
    }

    private var repositoryInvalid: Bool {
        !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && DiagnosticBundleBuilder.repositorySlug(repository) == nil
    }

    private var hasTypedToken: Bool {
        !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canAutoSubmit: Bool {
        issuePayload != nil && (hasTypedToken || authAvailability != .unavailable)
    }

    private var authStatusText: String {
        if hasTypedToken { return "将使用当前输入的 GitHub Token 直连 API 自动提交。" }
        switch authAvailability {
        case .savedToken: return "已配置本机 GitHub Token（0600 凭据库），点击「提交 Issue」即可自动创建。"
        case .ghCLI: return "已检测到本机已登录 gh CLI，点击「提交 Issue」即可自动创建到 GitHub。"
        case .unavailable: return "未检测到本机 gh 登录且未保存 Token。可展开下方填入 Token 实现自动提交，或改用「浏览器打开」。"
        }
    }

    private var submitHelpText: String {
        if issuePayload == nil { return "请先填写问题标题和有效的 GitHub 仓库" }
        if !canAutoSubmit { return "请先在下方配置 GitHub Token 或在本机登录 gh CLI" }
        return "直接向 GitHub 仓库自动创建脱敏 Issue 并返回链接"
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
                    TextField("标题", text: $draft.title, prompt: Text("一句话概括问题（自动提交必填）"))
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
                    Toggle("自动提交时附带完整脱敏诊断摘要", isOn: $includeDiagnostics)
                        .accessibilityIdentifier("feedback-include-diagnostics")
                    DisclosureGroup("预览脱敏诊断摘要", isExpanded: $previewExpanded) {
                        if previewExpanded {
                            ScrollView {
                                Text(report)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 200)
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
                    TextField("仓库", text: $repository, prompt: Text(DiagnosticBundleBuilder.defaultRepository))
                        .font(.callout.monospaced())
                        .accessibilityIdentifier("feedback-repository")
                    if repositoryInvalid {
                        InlineNotice(text: "请填写 owner/repo 或 GitHub 仓库地址。", tone: .warning)
                    }
                    Text(authStatusText)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("feedback-auth-status")
                    DisclosureGroup("GitHub Token 设置（可选，仅存本机 0600 凭据库）", isExpanded: $authExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("GitHub Token", text: $tokenInput,
                                        prompt: Text(authAvailability == .savedToken ? "已存本机凭据库，输入新 Token 可覆盖" : "Fine-grained PAT（需 Issues: Write）"))
                                .accessibilityIdentifier("feedback-github-token")
                            HStack(spacing: 8) {
                                Button("保存 Token", action: saveToken)
                                    .disabled(!hasTypedToken)
                                    .accessibilityIdentifier("feedback-save-token")
                                if authAvailability == .savedToken {
                                    Button("移除已保存 Token", role: .destructive, action: removeToken)
                                        .accessibilityIdentifier("feedback-remove-token")
                                }
                                Spacer()
                            }
                        }
                        .padding(.top, 4)
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
            let currentSubmitter = submitter
            async let loadedLogs = Task.detached(priority: .userInitiated) { DiagnosticBundleBuilder.readLogTail(at: url) }.value
            async let availability = Task.detached(priority: .userInitiated) { currentSubmitter.detectAvailability() }.value
            logLines = await loadedLogs
            authAvailability = await availability
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let submittedIssue {
                HStack(spacing: 8) {
                    InlineNotice(text: "已自动提交 Issue #\(submittedIssue.number)（\(submittedIssue.via.rawValue)）", tone: .active)
                        .accessibilityIdentifier("feedback-submitted-notice")
                    Spacer(minLength: 4)
                    Button("查看 #\(submittedIssue.number)") { NSWorkspace.shared.open(submittedIssue.url) }
                        .accessibilityIdentifier("feedback-view-created")
                    Button("复制链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(submittedIssue.url.absoluteString, forType: .string)
                        notice = ("已复制 Issue #\(submittedIssue.number) 链接。", .active)
                    }
                }
            } else if let notice {
                InlineNotice(text: notice.text, tone: notice.tone)
            }
            HStack(spacing: 8) {
                Button(action: copy) { Label("复制摘要", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("feedback-copy")
                Button(action: export) { Label("导出…", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("feedback-export")
                Spacer(minLength: 8)
                Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
                Button(action: openIssue) { Label("浏览器打开", systemImage: "arrow.up.right.square") }
                    .disabled(issueURL == nil)
                    .help(issueURL == nil ? "请先填写 GitHub 仓库" : "在浏览器中打开预填好的 Issue，提交前可再修改")
                    .accessibilityIdentifier("feedback-open-issue")
                if submitting { ProgressView().controlSize(.small) }
                Button(action: submitDirectly) { Label("提交 Issue", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting || !canAutoSubmit)
                    .help(submitHelpText)
                    .accessibilityIdentifier("feedback-submit-issue")
            }
        }
    }

    private func saveToken() {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try submitter.saveToken(trimmed)
            tokenInput = ""
            authAvailability = .savedToken
            submittedIssue = nil
            notice = ("GitHub Token 已安全保存到本机 0600 凭据库。", .active)
        } catch {
            notice = ("保存 Token 失败：Token 仅允许可见 ASCII 字符。", .critical)
        }
    }

    private func removeToken() {
        do {
            try submitter.removeToken()
            let currentSubmitter = submitter
            Task {
                authAvailability = await Task.detached(priority: .userInitiated) { currentSubmitter.detectAvailability() }.value
            }
            notice = ("已移除本机保存的 GitHub Token。", .neutral)
        } catch {
            notice = ("移除 Token 失败。", .critical)
        }
    }

    private func submitDirectly() {
        guard let payload = issuePayload else {
            notice = ("请先填写问题标题和有效的 GitHub 仓库。", .warning)
            return
        }
        submitting = true
        submittedIssue = nil
        notice = nil
        let typed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSubmitter = submitter
        Task {
            defer { submitting = false }
            do {
                let created = try await currentSubmitter.submit(payload, explicitToken: typed.isEmpty ? nil : typed)
                submittedIssue = created
                draft.title = ""
                draft.details = ""
            } catch {
                notice = (error.localizedDescription, .critical)
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
