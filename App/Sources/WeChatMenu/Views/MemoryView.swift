import SwiftUI

// MARK: - 文档解析

struct MemoryEntryRow: Identifiable, Equatable {
    let id: String
    let section: String
    let content: String
    let visibility: MemoryVisibility
    let locked: Bool
    // 手写行没有 mem 标记，引擎按锁定、仅本机处理，界面不提供切换。
    let managed: Bool
    var source: String? = nil
    var updated: String? = nil
    var expires: String? = nil
}

// 展示层解析，规则对齐 Engine/src/memory/store.ts 的 parseMemoryMarkdown。
enum MemoryDocumentParser {
    private static let heading = try! NSRegularExpression(pattern: #"^ {0,3}#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$"#)
    private static let marker = try! NSRegularExpression(pattern: #"^<!-- mem:(\S+(?: +\S+)*) -->$"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^- +(.+)$"#)
    private static let listPrefix = try! NSRegularExpression(pattern: #"^ {0,3}(?:[-*+]|\d+[.)]) +"#)
    private static let entryId = try! NSRegularExpression(pattern: #"^(?!hand_)[A-Za-z0-9_-]{2,32}$"#)
    private static let schemaField = try! NSRegularExpression(pattern: #"^(?:schema|scopeType|conversationId|updatedAt|revision):"#)

    private static func capture(_ regex: NSRegularExpression, _ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[group])
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func validDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return DateComponents(calendar: calendar, year: year, month: month, day: day).isValidDate
    }

    private static func fields(_ line: String) -> [String: String]? {
        guard let body = capture(marker, line) else { return nil }
        var result: [String: String] = [:]
        for token in body.split(separator: " ") {
            let pair = token.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[1].isEmpty, ["id", "vis", "locked", "src", "updated", "expires"].contains(String(pair[0])),
                  result[String(pair[0])] == nil else { return nil }
            result[String(pair[0])] = String(pair[1])
        }
        guard let id = result["id"], matches(entryId, id), let vis = result["vis"], MemoryVisibility(rawValue: vis) != nil,
              result["locked"] == "true" || result["locked"] == "false",
              result["updated"].map(validDate) ?? true, result["expires"].map(validDate) ?? true else { return nil }
        if let source = result["src"], source.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil { return nil }
        return result
    }

    private static func nextFence(_ line: String, _ fence: String?) -> String? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return fence }
        let rest = line.dropFirst(indent)
        guard let mark = rest.first, mark == "`" || mark == "~" else { return fence }
        let run = rest.prefix { $0 == mark }
        guard run.count >= 3 else { return fence }
        guard let fence else { return String(run) }
        let tail = rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        return run.hasPrefix(fence) && tail.isEmpty ? nil : fence
    }

    private static func frontmatterEnd(_ lines: [String]) -> Int? {
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return nil }
        let body = lines[1..<end]
        let yamlLike = body.allSatisfy { $0.isEmpty || $0.range(of: #"^[\w-]+:"#, options: .regularExpression) != nil }
        return body.contains(where: { matches(schemaField, $0) }) || yamlLike ? end : nil
    }

    static func parse(_ text: String) -> [MemoryEntryRow] {
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = source.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var rows: [MemoryEntryRow] = []
        var section = "", fence: String?, comment = false
        var index = frontmatterEnd(lines).map { $0 + 1 } ?? 0

        func handwritten(_ content: String) {
            rows.append(MemoryEntryRow(id: "hand-\(rows.count)", section: section, content: content, visibility: .localOnly,
                                       locked: true, managed: false))
        }

        while index < lines.count {
            let line = lines[index]
            let boundary = comment ? nil : nextFence(line, fence)
            if fence != nil || boundary != nil {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { handwritten(line) }
                fence = boundary
                index += 1
                continue
            }
            if !comment, let title = capture(heading, line) {
                section = title
                index += 1
                continue
            }
            if !comment, let meta = fields(line), index + 1 < lines.count,
               let content = capture(bullet, lines[index + 1])?.trimmingCharacters(in: .whitespaces), !content.isEmpty {
                rows.append(MemoryEntryRow(id: meta["id"]!, section: section, content: content,
                                           visibility: MemoryVisibility(rawValue: meta["vis"]!)!, locked: meta["locked"] == "true",
                                           managed: true, source: meta["src"], updated: meta["updated"], expires: meta["expires"]))
                index += 2
                continue
            }
            var scan = line[...]
            while let open = comment ? scan.range(of: "-->") : scan.range(of: "<!--") {
                comment.toggle()
                scan = scan[open.upperBound...]
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let range = NSRange(line.startIndex..., in: line)
                handwritten(listPrefix.stringByReplacingMatches(in: line, range: range, withTemplate: ""))
            }
            index += 1
        }
        // 重复 ID 无法明确指向条目，引擎把每个副本都降级为手写块。
        let counts = Dictionary(rows.map { ($0.id, 1) }, uniquingKeysWith: +)
        return rows.enumerated().map { offset, row in
            guard row.managed, counts[row.id, default: 0] > 1 else { return row }
            return MemoryEntryRow(id: "hand-dup-\(offset)", section: row.section, content: row.content, visibility: .localOnly,
                                  locked: true, managed: false)
        }
    }
}

// MARK: - Unified Diff

struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case header, hunk, added, removed, context, meta }
    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

enum UnifiedDiff {
    private static let hunk = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)

    private static func number(_ match: NSTextCheckingResult, _ group: Int, in line: String) -> Int? {
        Range(match.range(at: group), in: line).flatMap { Int(line[$0]) }
    }

    // 只有在 hunk 行数耗尽后才把 ---/+++ 当文件头，否则「--- x」是被删除的正文。
    static func parse(_ text: String) -> [DiffLine] {
        var raw = text.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        var result: [DiffLine] = []
        var old = 0, new = 0, oldLeft = 0, newLeft = 0

        func add(_ kind: DiffLine.Kind, _ value: String, _ oldNumber: Int? = nil, _ newNumber: Int? = nil) {
            result.append(DiffLine(id: result.count, kind: kind, text: value, oldNumber: oldNumber, newNumber: newNumber))
        }

        for source in raw {
            let line = source.hasSuffix("\r") ? String(source.dropLast()) : source
            if oldLeft == 0 && newLeft == 0 {
                let range = NSRange(line.startIndex..., in: line)
                if let match = hunk.firstMatch(in: line, range: range) {
                    old = number(match, 1, in: line) ?? 0
                    oldLeft = number(match, 2, in: line) ?? 1
                    new = number(match, 3, in: line) ?? 0
                    newLeft = number(match, 4, in: line) ?? 1
                    add(.hunk, line)
                } else if line.hasPrefix("\\") {
                    add(.meta, line)
                } else {
                    add(.header, line)
                }
                continue
            }
            switch line.first {
            case "+":
                add(.added, String(line.dropFirst()), nil, new)
                new += 1; newLeft = max(0, newLeft - 1)
            case "-":
                add(.removed, String(line.dropFirst()), old, nil)
                old += 1; oldLeft = max(0, oldLeft - 1)
            case "\\":
                add(.meta, line)
            default:
                add(.context, line.isEmpty ? "" : String(line.dropFirst()), old, new)
                old += 1; new += 1
                oldLeft = max(0, oldLeft - 1); newLeft = max(0, newLeft - 1)
            }
        }
        return result
    }
}

struct DiffTextView: View {
    let lines: [DiffLine]

    init(_ text: String) { lines = UnifiedDiff.parse(text) }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: 0) {
                        Text(line.oldNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                        Text(line.newNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                        Text(sign(line.kind)).frame(width: 18)
                        Text(line.text.isEmpty ? " " : line.text).fixedSize()
                        Spacer(minLength: 0)
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(foreground(line.kind))
                    .padding(.vertical, 1)
                    .background(background(line.kind))
                }
            }
            .textSelection(.enabled)
            .frame(minWidth: 420, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func sign(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        default: return ""
        }
    }

    private func foreground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .hunk: return .accentColor
        case .header, .meta: return .secondary
        default: return .primary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.18)
        case .removed: return Color.red.opacity(0.18)
        case .hunk: return Color.accentColor.opacity(0.1)
        default: return .clear
        }
    }
}

// MARK: - 提案文件

// 精确对齐 Engine/src/memory/persona.ts 的 PersonaProposalFile，未知字段按损坏处理。
struct PersonaProposalFile: Codable, Equatable {
    var proposalId: String
    var baseDigest: String
    var summary: String
    var patch: JSONValue
    var proposedContent: String
    var diff: String
    var sampleCount: Int
    var createdAt: Int64

    static func decode(_ text: String) throws -> Self {
        do { return try IPCv3.decodeStrict(Self.self, from: Data(text.utf8)) }
        catch { throw BridgeFault("storage-unavailable") }
    }
}

@MainActor
final class MemoryDraftBuffer: ObservableObject {
    @Published var texts: [MemoryTarget: String] = [:]
}

// MARK: - 云端可见性概览

struct MemoryVisibilitySummary: Equatable {
    var cloudSafe = 0
    var localOnly = 0
    var locked = 0

    init(rows: [MemoryEntryRow]) {
        for row in rows {
            if row.visibility == .cloudSafe { cloudSafe += 1 } else { localOnly += 1 }
            if row.locked { locked += 1 }
        }
    }

    var total: Int { cloudSafe + localOnly }
    var text: String { "云端可用 \(cloudSafe) 条 · 仅本机 \(localOnly) 条 · 已锁定 \(locked) 条" }

    // 批量切换只动引擎管理的未锁定条目；手写行与锁定条目保持原状。
    static func bulkTargets(_ rows: [MemoryEntryRow], to visibility: MemoryVisibility) -> [String] {
        rows.filter { $0.managed && !$0.locked && $0.visibility != visibility }.map(\.id)
    }

    // 会话专档看该会话的回复模型（未指定则跟随主模型）；人格档案被所有会话共享，任一会话走云端即算。
    static func usesCloudModel(_ settings: SettingsV2, target: MemoryTarget) -> Bool {
        func cloud(_ presetId: String?) -> Bool {
            guard let presetId else { return false }
            return settings.models.first { $0.id == presetId }?.mode == .cloud
        }
        let main = settings.defaultModels.replyPresetId
        switch target {
        case .persona:
            return cloud(main) || settings.conversations.values.contains { cloud($0.replyPresetId) }
        case .scope(let id):
            return cloud(settings.conversations[id]?.replyPresetId ?? main)
        }
    }

    func cloudNotice(usesCloud: Bool) -> String? {
        usesCloud && cloudSafe == 0 && total > 0 ? "当前没有设为云端可用的条目，云模型回复不会读取此档案。" : nil
    }
}

private struct MemoryVisibilityBar: View {
    let summary: MemoryVisibilitySummary
    let notice: String?
    let toCloud: Int
    let toLocal: Int
    let busy: Bool
    let blocked: Bool
    let apply: (MemoryVisibility) -> Void

    @State private var confirmingCloud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cloud").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("云端可见性概览").font(.callout.weight(.medium))
                    Text(summary.text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("memory-visibility-summary")
                }
                Spacer(minLength: 6)
                if busy { ProgressView().controlSize(.small) }
                Button("未锁定项全部设为云端可用") { confirmingCloud = true }
                    .disabled(busy || blocked || toCloud == 0)
                    .accessibilityIdentifier("memory-bulk-cloud")
                    .confirmationDialog("把 \(toCloud) 条未锁定条目设为云端可用？", isPresented: $confirmingCloud,
                                        titleVisibility: .visible) {
                        Button("设为云端可用") { apply(.cloudSafe) }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("这些条目会随回复请求发送给云端模型。每条都会留下快照，可在历史版本中回滚。")
                    }
                Button("未锁定项全部设为仅本机") { apply(.localOnly) }
                    .disabled(busy || blocked || toLocal == 0)
                    .accessibilityIdentifier("memory-bulk-local")
            }
            if let notice { InlineNotice(text: notice, tone: .warning) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .accessibilityIdentifier("memory-visibility-bar")
    }
}

// MARK: - 主视图

struct MemoryView: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var memory: MemoryStore
    @ObservedObject private var settings: SettingsStore

    init(workspace: V2Workspace) {
        self.workspace = workspace
        memory = workspace.memory
        settings = workspace.settings
    }

    private var autoMerge: Binding<Bool> {
        Binding(get: { settings.draft.memory.autoMergePersona }, set: { settings.draft.memory.autoMergePersona = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("分区", selection: $workspace.memorySection) {
                ForEach(MemorySection.allCases) { section in
                    Text(sectionTitle(section)).tag(section)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sectionTitle(_ section: MemorySection) -> String {
        guard section == .proposals, memory.pendingProposalCount > 0 else { return section.title }
        return "\(section.title) (\(memory.pendingProposalCount))"
    }

    @ViewBuilder private var content: some View {
        switch workspace.memorySection {
        case .persona:
            VStack(spacing: 0) {
                Toggle(isOn: autoMerge) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("允许人格风格自动合并")
                        Text("开启后低风险风格微调自动入库，仍保留快照并可回滚；锁定条目不受影响。保存设置后生效。")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("persona-auto-merge")
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                MemoryDocumentPane(workspace: workspace, target: .persona).id(MemoryTarget.persona)
            }
        case .scopes:
            ScopeMemoryBrowser(workspace: workspace)
        case .proposals:
            ProposalsBrowser(workspace: workspace)
        }
    }
}

private struct ScopeMemoryBrowser: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var drafts: MemoryDraftBuffer

    init(workspace: V2Workspace) {
        self.workspace = workspace
        settings = workspace.settings
        drafts = workspace.memoryDrafts
    }

    private var rows: [ConversationPolicy] {
        settings.saved.conversations.values.sorted { ($0.label, $0.conversationId) < ($1.label, $1.conversationId) }
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if rows.isEmpty {
                    EmptyStateView(title: "还没有管理的会话", symbol: "person.2")
                } else {
                    List(rows, selection: $workspace.selectedMemoryConversationId) { policy in
                        HStack(spacing: 8) {
                            ConversationAvatar(label: policy.label, type: policy.type, size: 24)
                            Text(policy.label).lineLimit(1)
                            if drafts.texts[.scope(conversationId: policy.conversationId)] != nil {
                                StatusDot(color: .orange, size: 6).accessibilityLabel("有未保存修改")
                            }
                            Spacer()
                            if !policy.memoryEnabled {
                                Text("未开启").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .tag(policy.conversationId)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(width: 220)
            Divider()
            if let id = workspace.selectedMemoryConversationId, settings.saved.conversations[id] != nil {
                MemoryDocumentPane(workspace: workspace, target: .scope(conversationId: id)).id(id)
            } else {
                EmptyStateView(title: "选择一个会话查看专档", symbol: "doc.text")
            }
        }
    }
}

// MARK: - 文档面板

private struct MemoryDocumentPane: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case entries, raw
        var id: String { rawValue }
        var title: String { self == .entries ? "结构化条目" : "原始 Markdown" }
    }

    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var memory: MemoryStore
    @ObservedObject private var drafts: MemoryDraftBuffer
    @ObservedObject private var settings: SettingsStore
    let target: MemoryTarget

    @State private var mode = Mode.entries
    @State private var history = false
    @State private var loading = false
    @State private var bulkBusy = false

    init(workspace: V2Workspace, target: MemoryTarget) {
        self.workspace = workspace
        runtime = workspace.runtime
        memory = workspace.memory
        drafts = workspace.memoryDrafts
        settings = workspace.settings
        self.target = target
    }

    private var stored: MemoryContent? { memory.documents[target] }
    private var storedText: String { stored?.text ?? "" }
    private var editable: Bool { stored?.text != nil }
    private var dirty: Bool { drafts.texts[target].map { $0 != storedText } ?? false }
    private var text: String { drafts.texts[target] ?? storedText }
    private var rows: [MemoryEntryRow] { MemoryDocumentParser.parse(text) }

    private var binding: Binding<String> {
        Binding(get: { text }, set: { value in
            if value == storedText { drafts.texts[target] = nil } else { drafts.texts[target] = value }
        })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if editable && !rows.isEmpty {
                    visibilityBar
                    Divider()
                }
                main.frame(maxWidth: .infinity, maxHeight: .infinity)
                if dirty { draftBar }
            }
            if history {
                Divider()
                RevisionDrawer(workspace: workspace, target: target, blocked: dirty).frame(width: 340)
            }
        }
        .task(id: runtime.ready) { await load() }
    }

    private func load() async {
        guard runtime.ready else { return }
        loading = true
        defer { loading = false }
        do { try await memory.load(target) } catch { workspace.capture(error) }
    }

    private var visibilityBar: some View {
        let summary = MemoryVisibilitySummary(rows: rows)
        let notice = summary.cloudNotice(usesCloud: MemoryVisibilitySummary.usesCloudModel(settings.saved, target: target))
        return MemoryVisibilityBar(summary: summary, notice: notice,
                                   toCloud: MemoryVisibilitySummary.bulkTargets(rows, to: .cloudSafe).count,
                                   toLocal: MemoryVisibilitySummary.bulkTargets(rows, to: .localOnly).count,
                                   busy: bulkBusy, blocked: dirty || !runtime.ready, apply: bulkSet)
    }

    private func bulkSet(_ visibility: MemoryVisibility) {
        let ids = MemoryVisibilitySummary.bulkTargets(rows, to: visibility)
        guard !ids.isEmpty, !dirty else { return }
        bulkBusy = true
        let memory = memory, target = target
        workspace.run {
            defer { bulkBusy = false }
            try await memory.setEntriesVisibility(target, entryIds: ids, visibility: visibility)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("视图", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            if case .scope(let id) = target { ScopeActions(workspace: workspace, conversationId: id, blocked: dirty) }
            Toggle(isOn: $history) { Label("历史版本", systemImage: "clock.arrow.circlepath") }
                .toggleStyle(.button)
                .accessibilityIdentifier("memory-history")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    @ViewBuilder private var main: some View {
        if let path = stored?.path, stored?.text == nil {
            EmptyStateView(title: "档案过大，无法在此编辑", symbol: "doc.badge.ellipsis", detail: path)
        } else if mode == .raw {
            TextEditor(text: binding)
                .font(.callout.monospaced())
                .disabled(!editable)
                .accessibilityIdentifier("memory-raw-editor")
        } else if rows.isEmpty {
            EmptyStateView(title: "档案还是空的", symbol: "doc.text", detail: "可切换到原始 Markdown 手写，或等待自动整理。")
        } else {
            entryList
        }
    }

    private var entryList: some View {
        Form {
            if dirty {
                Section {
                    InlineNotice(text: "有未保存的原文修改。保存或放弃后才能切换锁定和云可见性。", tone: .warning)
                }
            }
            ForEach(sections, id: \.name) { section in
                Section(section.name.isEmpty ? "未分组" : section.name) {
                    ForEach(section.rows) { row in
                        MemoryEntryCard(row: row, blocked: dirty || !runtime.ready,
                                        setLock: { locked in
                                            let memory = memory, target = target
                                            workspace.run { try await memory.setEntryLock(target, entryId: row.id, locked: locked) }
                                        },
                                        setVisibility: { visibility in
                                            let memory = memory, target = target
                                            workspace.run { try await memory.setEntryVisibility(target, entryId: row.id, visibility: visibility) }
                                        })
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sections: [(name: String, rows: [MemoryEntryRow])] {
        var order: [String] = []
        var grouped: [String: [MemoryEntryRow]] = [:]
        for row in rows {
            if grouped[row.section] == nil { order.append(row.section) }
            grouped[row.section, default: []].append(row)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private var draftBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text("档案有未保存修改").font(.callout.weight(.semibold))
            Spacer()
            Button("放弃修改") { drafts.texts[target] = nil }
            Button("保存档案", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(!runtime.ready)
                .accessibilityIdentifier("memory-save")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.orange.opacity(0.14))
    }

    private func save() {
        guard let value = drafts.texts[target] else { return }
        let memory = memory, target = target, drafts = drafts
        workspace.run {
            try await memory.save(target, text: value)
            // 保存期间用户继续编辑时，保留更新的草稿。
            if drafts.texts[target] == value { drafts.texts[target] = nil }
        }
    }
}

private struct ScopeActions: View {
    @ObservedObject var workspace: V2Workspace
    let conversationId: String
    let blocked: Bool
    @State private var busy = false
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            Button("立即整理") { consolidate(nil) }
                .disabled(busy || blocked || !workspace.runtime.ready)
            Button("从历史初始化…") { confirming = true }
                .disabled(busy || blocked || !workspace.runtime.ready)
                .confirmationDialog("从最近 200 条历史初始化专档？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("开始") {
                        consolidate(BackfillRequest(conversationId: conversationId, recentCount: 200, purpose: .memory))
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("历史消息只用于提炼记忆，不会触发发信。会使用设置中的记忆整理模型。")
                }
        }
    }

    private func consolidate(_ backfill: BackfillRequest?) {
        busy = true
        let memory = workspace.memory, id = conversationId
        workspace.run {
            defer { busy = false }
            try await memory.consolidateNow(conversationId: id, backfill: backfill)
        }
    }
}

private struct MemoryEntryCard: View {
    let row: MemoryEntryRow
    let blocked: Bool
    let setLock: (Bool) -> Void
    let setVisibility: (MemoryVisibility) -> Void

    private var cloudSafe: Bool { row.visibility == .cloudSafe }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.content).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if !row.managed { Text("手写内容").font(.caption).foregroundStyle(.secondary) }
                    if let source = row.source { Text(sourceTitle(source)).font(.caption).foregroundStyle(.secondary) }
                    if let updated = row.updated { Text("更新 \(updated)").font(.caption).foregroundStyle(.secondary) }
                    if let expires = row.expires { Text("到期 \(expires)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 8)
            Button { setVisibility(cloudSafe ? .localOnly : .cloudSafe) } label: {
                StatusPill(text: cloudSafe ? "cloud-safe" : "local-only", tone: cloudSafe ? .active : .neutral,
                           symbol: cloudSafe ? "cloud" : "desktopcomputer")
            }
            .buttonStyle(.plain)
            .disabled(blocked || !row.managed)
            .help(row.managed ? "切换云端可见性" : "手写内容固定为仅本机")
            .accessibilityLabel(cloudSafe ? "云端可见，点击改为仅本机" : "仅本机，点击改为云端可见")
            Button { setLock(!row.locked) } label: {
                Image(systemName: row.locked ? "lock.fill" : "lock.open")
                    .foregroundStyle(row.locked ? Color.orange : Color.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(blocked || !row.managed)
            .help(row.managed ? "锁定后模型不能改写这一条" : "手写内容固定为锁定")
            .accessibilityLabel(row.locked ? "已锁定，点击解锁" : "未锁定，点击锁定")
        }
        .padding(.vertical, 2)
    }

    private func sourceTitle(_ source: String) -> String {
        switch source {
        case "auto": return "自动整理"
        case "manual": return "手动"
        case "backfill": return "历史初始化"
        case "proposal_accepted": return "采纳建议"
        default: return source
        }
    }
}

// MARK: - 历史抽屉

private struct RevisionDrawer: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var memory: MemoryStore
    let target: MemoryTarget
    let blocked: Bool

    @State private var selection: String?
    @State private var pendingRollback: MemoryRevision?

    init(workspace: V2Workspace, target: MemoryTarget, blocked: Bool) {
        self.workspace = workspace
        memory = workspace.memory
        self.target = target
        self.blocked = blocked
    }

    private var rows: [MemoryRevision] { memory.revisions[target] ?? [] }
    private var selected: MemoryRevision? { rows.first { $0.revId == selection } ?? rows.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("历史版本").font(.headline).padding(10)
            Divider()
            if rows.isEmpty {
                EmptyStateView(title: "暂无历史版本", symbol: "clock")
            } else {
                List(rows, selection: $selection) { revision in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(revision.summary.isEmpty ? sourceTitle(revision.source) : revision.summary)
                            .font(.callout).lineLimit(2)
                        Text("\(sourceTitle(revision.source)) · \(V2Format.time(revision.createdAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(revision.revId)
                }
                .listStyle(.inset)
                .frame(minHeight: 150, maxHeight: 230)
                if memory.revisionCursors[target] != nil {
                    Button("加载更多") {
                        let memory = memory, target = target
                        workspace.run { try await memory.loadRevisions(target, more: true) }
                    }
                    .padding(6)
                }
                Divider()
                if let revision = selected {
                    DiffTextView(revision.diffPreview)
                    Divider()
                    HStack {
                        if blocked { Text("请先处理未保存修改").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("回滚至此版本") { pendingRollback = revision }
                            .disabled(blocked || !workspace.runtime.ready)
                            .accessibilityIdentifier("memory-rollback")
                    }
                    .padding(8)
                }
            }
        }
        .task(id: workspace.runtime.ready) {
            guard workspace.runtime.ready else { return }
            do { try await memory.loadRevisions(target) } catch { workspace.capture(error) }
        }
        .confirmationDialog("回滚至此版本？", isPresented: rollbackDialog, titleVisibility: .visible, presenting: pendingRollback) { revision in
            Button("确认回滚", role: .destructive) {
                let memory = memory, target = target, id = revision.revId
                workspace.run { try await memory.rollback(target, revId: id) }
            }
            Button("取消", role: .cancel) {}
        } message: { revision in
            // 引擎的快照保存的是这次改动之前的内容。
            Text("档案将恢复到 \(V2Format.time(revision.createdAt)) 这次改动之前的内容。当前内容会先保存为新的历史版本。")
        }
    }

    private var rollbackDialog: Binding<Bool> {
        Binding(get: { pendingRollback != nil }, set: { if !$0 { pendingRollback = nil } })
    }

    private func sourceTitle(_ source: MemoryRevision.Source) -> String {
        switch source {
        case .auto: return "自动整理"
        case .backfill: return "历史初始化"
        case .proposalAccepted: return "采纳建议"
        case .manual: return "手动编辑"
        case .rollback: return "回滚"
        }
    }
}

// MARK: - 人格提案

private struct ProposalsBrowser: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var memory: MemoryStore

    init(workspace: V2Workspace) {
        self.workspace = workspace
        memory = workspace.memory
    }

    private var rows: [PersonaProposal] {
        memory.proposals.sorted { ($0.status == .pending ? 0 : 1, -$0.createdAt) < ($1.status == .pending ? 0 : 1, -$1.createdAt) }
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if rows.isEmpty {
                    EmptyStateView(title: "没有人格建议", symbol: "brain.head.profile", detail: "积累足够的本人发言后会在这里出现。")
                } else {
                    List(rows, selection: $workspace.selectedProposalId) { proposal in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proposal.summary).font(.callout.weight(.medium)).lineLimit(2)
                            HStack(spacing: 6) {
                                StatusPill(text: statusTitle(proposal.status), tone: proposal.status == .pending ? .active : .neutral)
                                Text(V2Format.time(proposal.createdAt)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(proposal.proposalId)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(width: 260)
            Divider()
            if let id = workspace.selectedProposalId, let proposal = memory.proposals.first(where: { $0.proposalId == id }) {
                ProposalDetail(workspace: workspace, proposal: proposal).id(id)
            } else {
                EmptyStateView(title: "选择一条建议查看 Diff", symbol: "doc.text.magnifyingglass")
            }
        }
    }

    private func statusTitle(_ status: PersonaProposal.Status) -> String {
        switch status {
        case .pending: return "待审"
        case .accepted: return "已采纳"
        case .rejected: return "已驳回"
        case .superseded: return "已过期"
        }
    }
}

private struct ProposalDetail: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var memory: MemoryStore
    @ObservedObject private var drafts: MemoryDraftBuffer
    let proposal: PersonaProposal

    @State private var file: PersonaProposalFile?
    @State private var loadFault: String?
    @State private var editing = false
    @State private var edited = ""
    @State private var busy = false

    init(workspace: V2Workspace, proposal: PersonaProposal) {
        self.workspace = workspace
        memory = workspace.memory
        drafts = workspace.memoryDrafts
        self.proposal = proposal
    }

    private var pending: Bool { proposal.status == .pending }
    // 采纳会改写 persona.md；保留未保存草稿会在之后覆盖采纳结果。
    private var personaDirty: Bool { drafts.texts[.persona] != nil }
    private var editedValid: Bool {
        !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && edited.utf8.count <= IPCv3.maxInlineDocumentBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(file?.summary ?? proposal.summary).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text("依据 \(file?.sampleCount ?? proposal.sampleCount) 条本人发言 · \(V2Format.time(proposal.createdAt))")
                    .font(.caption).foregroundStyle(.secondary)
                if pending && personaDirty {
                    InlineNotice(text: "通用人格有未保存的原文修改，请先保存或放弃。", tone: .warning)
                }
                if let loadFault { InlineNotice(text: v2Explanation(loadFault), tone: .critical) }
            }
            .padding(12)
            Divider()
            if editing {
                TextEditor(text: $edited).font(.callout.monospaced())
                    .accessibilityIdentifier("proposal-editor")
            } else if let file {
                DiffTextView(file.diff)
            } else if loadFault == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            if pending {
                Divider()
                actions.padding(10)
            }
        }
        .task(id: proposal.proposalId) { load() }
    }

    private var actions: some View {
        HStack {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            if editing {
                Button("取消编辑") { editing = false }
                Button("保存并采纳") { decide(.acceptEdited(proposalId: proposal.proposalId, content: MemoryContent(text: edited))) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || personaDirty || !editedValid)
                    .accessibilityIdentifier("proposal-accept-edited")
            } else {
                Button("驳回", role: .destructive) { decide(.reject(proposalId: proposal.proposalId)) }
                    .disabled(busy)
                    .accessibilityIdentifier("proposal-reject")
                Button("编辑后采纳") {
                    edited = file?.proposedContent ?? ""
                    editing = true
                }
                .disabled(busy || file == nil || personaDirty)
                Button("采纳") { decide(.accept(proposalId: proposal.proposalId)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || file == nil || personaDirty)
                    .accessibilityIdentifier("proposal-accept")
            }
        }
    }

    private func load() {
        do {
            let value = try PersonaProposalFile.decode(try memory.proposalDocument(proposal))
            guard value.proposalId == proposal.proposalId else { throw BridgeFault("storage-unavailable") }
            file = value
            loadFault = nil
        } catch {
            file = nil
            loadFault = V2Workspace.code(error)
        }
    }

    private func decide(_ decision: PersonaDecision) {
        busy = true
        let memory = memory
        workspace.run {
            defer { busy = false }
            try await memory.decide(decision)
            editing = false
        }
    }
}
