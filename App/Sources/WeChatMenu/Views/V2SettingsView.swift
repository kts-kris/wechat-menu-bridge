import SwiftUI

// MARK: - 模型预设表单

struct PresetForm: Equatable, Identifiable {
    var id: String
    var name: String
    var mode: ModelMode
    var kind: ModelKind
    var url: String
    var modelName: String
    var maxTokens: Int
    var temperature: Double
    var reasoningEffort: ReasoningEffort?

    init() {
        id = "preset-\(UUID().uuidString.lowercased())"
        name = ""
        mode = .local
        kind = .chat
        url = "http://127.0.0.1:11434/v1"
        modelName = ""
        maxTokens = 320
        temperature = 0.35
        reasoningEffort = nil
    }

    init(_ preset: ModelPreset) {
        id = preset.id
        name = preset.name
        mode = preset.mode
        kind = preset.kind
        url = preset.url
        modelName = preset.modelName
        maxTokens = preset.maxTokens
        temperature = preset.temperature
        reasoningEffort = preset.reasoningEffort
    }

    // 语音转写端点按对应的 chat 端点复用同一套地址校验。
    var endpoint: String? {
        guard kind == .stt else { return Configuration.modelEndpoint(url, mode: mode) }
        let canonical = ModelEndpoint.canonical(url, kind: .stt)
        let suffix = "/audio/transcriptions"
        guard canonical.hasSuffix(suffix),
              Configuration.modelEndpoint(String(canonical.dropLast(suffix.count)) + "/chat/completions", mode: mode) != nil else {
            return nil
        }
        return canonical
    }

    var issues: [String] {
        var result: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("请填写预设名称。") }
        if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("请填写模型名。") }
        if endpoint == nil {
            result.append(mode == .local ? "本机地址需为 http://127.0.0.1:端口/…/v1。" : "云端地址需为 HTTPS，且以 /v1 或完整接口路径结尾。")
        }
        if maxTokens <= 0 { result.append("最大 Token 必须大于 0。") }
        if !(0...2).contains(temperature) { result.append("温度需在 0 到 2 之间。") }
        return result
    }

    func build() -> ModelPreset {
        ModelPreset(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode, kind: kind,
                    url: endpoint ?? url, modelName: modelName, maxTokens: maxTokens, temperature: temperature,
                    reasoningEffort: kind == .chat ? reasoningEffort : nil)
    }
}

extension ModelKind {
    var title: String {
        switch self {
        case .chat: return "对话"
        case .vision: return "视觉"
        case .stt: return "语音转写"
        }
    }
}

extension ReasoningEffort {
    static let displayOrder: [ReasoningEffort] = [.max, .high, .medium, .low, .default]

    var title: String {
        switch self {
        case .max: return "最高 (max，默认)"
        case .high: return "高 (high)"
        case .medium: return "中 (medium)"
        case .low: return "低 (low)"
        case .default: return "不传此参数 (default)"
        }
    }
}

extension HealthCheckStep.StepID {
    var title: String {
        switch self {
        case .xiaohe: return "小禾连接"
        case .whitelist: return "发信白名单"
        case .credentials: return "本机凭据读取"
        case .model: return "云端模型 SSE + 推理 + JSON 实测"
        }
    }
}

// MARK: - 设置页

struct V2SettingsView: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var settings: SettingsStore
    @State private var editingPreset: PresetForm?
    @State private var pendingPresetRemoval: ModelPreset?

    init(workspace: V2Workspace) {
        self.workspace = workspace
        settings = workspace.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Form {
                    XiaoheConnectionCard(workspace: workspace)
                    HealthCheckCard(workspace: workspace)
                    DefaultModelsCard(workspace: workspace)
                    ModelPresetsCard(workspace: workspace, editing: $editingPreset, pendingRemoval: $pendingPresetRemoval)
                    CloudAuthorizationCard(workspace: workspace)
                    ModelPreviewCard(workspace: workspace)
                    UpdateSettingsCard(workspace: workspace)
                    LegacyProfileNoticeCard(workspace: workspace)
                }
                .formStyle(.grouped)
                // 菜单栏的更新提示跳到本页后，等表单完成布局再滚动。
                .task(id: workspace.updateSectionRequested) {
                    guard workspace.updateSectionRequested else { return }
                    workspace.updateSectionRequested = false
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation { proxy.scrollTo(UpdateSettingsCard.anchor, anchor: .top) }
                }
            }
            UnsavedChangesBar(workspace: workspace)
        }
        // 放在表单外层：分组表单的行可能被回收，弹窗不能挂在行上。
        .sheet(item: $editingPreset) { form in
            PresetEditor(workspace: workspace, initial: form) { editingPreset = nil }
        }
        .confirmationDialog("删除预设「\(pendingPresetRemoval?.name ?? "")」？", isPresented: removalDialog,
                            titleVisibility: .visible, presenting: pendingPresetRemoval) { preset in
            Button("删除", role: .destructive) { settings.removePreset(id: preset.id) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("使用它的默认项和会话会回到未指定。保存设置后生效，钥匙串中的密钥不会被删除。")
        }
    }

    private var removalDialog: Binding<Bool> {
        Binding(get: { pendingPresetRemoval != nil }, set: { if !$0 { pendingPresetRemoval = nil } })
    }
}

// MARK: - 小禾连接

private struct XiaoheConnectionCard: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var settings: SettingsStore

    @State private var token = ""
    @State private var accounts: [XiaoheAccountOption] = []
    @State private var probed: XiaoheCapabilities?
    @State private var busy = false
    @State private var message: String?
    @State private var fault: String?

    init(workspace: V2Workspace) {
        self.workspace = workspace
        runtime = workspace.runtime
        settings = workspace.settings
    }

    private var url: String { settings.draft.xiaohe.mcpUrl }
    private var validURL: Bool { Configuration.validURL(url, kind: "mcp") }
    private var capabilities: XiaoheCapabilities? { probed ?? runtime.capabilities }

    // 令牌按完整地址存放；换地址后不能沿用旧地址的令牌状态。
    private var urlBinding: Binding<String> {
        Binding(get: { settings.draft.xiaohe.mcpUrl }, set: { value in
            let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.draft.xiaohe.mcpUrl = next
            settings.draft.xiaohe.hasAuthToken = next == settings.saved.xiaohe.mcpUrl && settings.saved.xiaohe.hasAuthToken
            accounts = []
            probed = nil
        })
    }

    private var accountBinding: Binding<String> {
        Binding(get: { settings.draft.xiaohe.accountId }, set: { id in
            settings.draft.xiaohe.accountId = id
            settings.draft.xiaohe.accountLabel = accounts.first { $0.id == id }?.label ?? ""
        })
    }

    var body: some View {
        Section("小禾连接") {
            TextField("MCP 地址", text: urlBinding, prompt: Text("http://127.0.0.1:21454/mcp"))
                .font(.callout.monospaced())
                .accessibilityIdentifier("mcp-url")
            if !url.isEmpty && !validURL {
                InlineNotice(text: "地址需为 http://127.0.0.1:端口/mcp。", tone: .warning)
            }
            SecureField("访问令牌", text: $token, prompt: Text(settings.draft.xiaohe.hasAuthToken ? "已存入钥匙串" : "Bearer Token（可选）"))
                .accessibilityIdentifier("mcp-token")
            HStack(spacing: 8) {
                if !settings.draft.xiaohe.accountLabel.isEmpty {
                    StatusPill(text: settings.draft.xiaohe.accountLabel, symbol: "person.crop.circle")
                }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("存入钥匙串", action: saveToken).disabled(token.isEmpty || !validURL || busy)
                Button("移除令牌", action: removeToken).disabled(!settings.draft.xiaohe.hasAuthToken || !validURL || busy)
                Button("读取账号与能力探测", action: probe)
                    .disabled(!validURL || !runtime.ready || busy)
                    .accessibilityIdentifier("mcp-probe")
            }
            if !accounts.isEmpty {
                Picker("账号", selection: accountBinding) {
                    if !accounts.contains(where: { $0.id == settings.draft.xiaohe.accountId }) {
                        Text("请选择账号").tag(settings.draft.xiaohe.accountId)
                    }
                    ForEach(accounts) { account in
                        Text("\(account.label)\(account.canSend ? "" : "（只读）")").tag(account.id)
                    }
                }
            }
            if let message { InlineNotice(text: message, tone: .active) }
            if let fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
            if let capabilities {
                LabeledContent("连接能力") { capabilityGrid(capabilities) }
            }
        }
    }

    private func capabilityGrid(_ value: XiaoheCapabilities) -> some View {
        let rows: [(String, Bool)] = [
            ("账号级事件流", value.accountWideEvents), ("会话列表", value.listConversations), ("群成员", value.groupMembers),
            ("历史查询", value.historyQuery), ("历史搜索", value.historySearch), ("媒体读取", value.readMedia),
            ("原生引用回复", value.nativeReply), ("群内 @", value.mentionSend), ("发送文字", value.canSendText),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 5) {
            ForEach(rows, id: \.0) { row in
                Label(row.0, systemImage: row.1 ? "checkmark.circle.fill" : "minus.circle")
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(row.1 ? Color.green : Color.secondary)
            }
        }
    }

    private func saveToken() {
        let secret = token, address = url, vault = workspace.vault
        guard let entry = try? KeychainEntry.mcp(url: address) else {
            fault = "invalid-endpoint"
            return
        }
        busy = true
        fault = nil
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) { try vault.save(secret, for: entry) }.value
                token = ""
                if settings.draft.xiaohe.mcpUrl == address { settings.draft.xiaohe.hasAuthToken = true }
                message = "令牌已存入钥匙串，保存设置后生效。"
            } catch {
                fault = V2Workspace.code(error)
            }
        }
    }

    private func removeToken() {
        let address = url, vault = workspace.vault
        guard let entry = try? KeychainEntry.mcp(url: address) else {
            fault = "invalid-endpoint"
            return
        }
        busy = true
        fault = nil
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) { try vault.remove(entry) }.value
                if settings.draft.xiaohe.mcpUrl == address { settings.draft.xiaohe.hasAuthToken = false }
                message = "令牌已从钥匙串移除，请保存设置。"
            } catch {
                fault = V2Workspace.code(error)
            }
        }
    }

    private func probe() {
        let address = url, client = runtime.client
        busy = true
        fault = nil
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let rows = try await client.xiaoheAccounts(mcpUrl: address)
                guard settings.draft.xiaohe.mcpUrl == address else { return }
                accounts = rows
                if rows.count == 1, settings.draft.xiaohe.accountId != rows[0].id {
                    settings.draft.xiaohe.accountId = rows[0].id
                    settings.draft.xiaohe.accountLabel = rows[0].label
                }
                // 能力探测走已生效的连接，草稿与运行配置不一致时结果不代表新地址。
                let current = settings.draft.xiaohe, active = settings.saved.xiaohe
                if current.mcpUrl == active.mcpUrl, current.accountId == active.accountId, !active.accountId.isEmpty {
                    probed = try await runtime.refreshCapabilities()
                    message = "已读取 \(rows.count) 个账号并完成能力探测。"
                } else {
                    message = "已读取 \(rows.count) 个账号。保存设置后再次探测可获取能力清单。"
                }
            } catch {
                fault = V2Workspace.code(error)
            }
        }
    }
}

// MARK: - 全链路体检

private struct HealthCheckCard: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var settings: SettingsStore

    @State private var busy = false
    @State private var result: HealthCheckResult?
    @State private var fault: String?

    init(workspace: V2Workspace) {
        self.workspace = workspace
        runtime = workspace.runtime
        settings = workspace.settings
    }

    var body: some View {
        Section("全链路体检") {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("正在体检，模型实测可能需要一分钟以上。").font(.callout).foregroundStyle(.secondary)
                } else if let result {
                    StatusPill(text: result.ok ? "全部通过" : "存在失败项", tone: result.ok ? .active : .critical)
                } else {
                    Text("依次检查小禾、白名单、凭据和模型").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: run) { Label("开始体检", systemImage: "play.fill") }
                    .disabled(busy || !runtime.ready)
                    .accessibilityIdentifier("health-check-run")
            }
            // 工具栏的体检入口跳到本页后，由这里接手执行。
            .task(id: workspace.healthCheckRequested) {
                guard workspace.healthCheckRequested else { return }
                workspace.healthCheckRequested = false
                if !busy && runtime.ready { run() }
            }
            if settings.hasUnsavedChanges {
                InlineNotice(text: "体检使用已保存的配置，当前未保存的修改不会参与。", tone: .warning)
            }
            if let fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
            if let result {
                ForEach(result.steps) { HealthCheckRow(step: $0) }
            }
        }
    }

    private func run() {
        busy = true
        result = nil
        fault = nil
        Task { @MainActor in
            defer { busy = false }
            do { result = try await settings.runHealthCheck() }
            catch { fault = V2Workspace.code(error) }
        }
    }
}

struct HealthCheckRow: View {
    let step: HealthCheckStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: step.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(step.ok ? Color.green : Color.red)
                .accessibilityLabel(step.ok ? "通过" : "失败")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(step.label).font(.callout.weight(.medium))
                    Text("\(step.durationMs) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("health-step-\(step.id.rawValue)")
    }
}

// MARK: - 模型预设

private struct ModelPresetsCard: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var settings: SettingsStore
    @Binding var editing: PresetForm?
    @Binding var pendingRemoval: ModelPreset?

    init(workspace: V2Workspace, editing: Binding<PresetForm?>, pendingRemoval: Binding<ModelPreset?>) {
        self.workspace = workspace
        settings = workspace.settings
        _editing = editing
        _pendingRemoval = pendingRemoval
    }

    var body: some View {
        Section {
            if settings.draft.models.isEmpty {
                Text("还没有模型预设。回复、插件和记忆整理都需要至少一个对话模型。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(ModelKind.allCases, id: \.self) { kind in
                ForEach(settings.draft.models.filter { $0.kind == kind }) { preset in row(preset) }
            }
        } header: {
            HStack {
                Text("模型预设")
                Spacer()
                Button { editing = PresetForm() } label: { Label("新增预设", systemImage: "plus") }
                    .controlSize(.small)
                    .accessibilityIdentifier("preset-add")
            }
        }
    }

    private func row(_ preset: ModelPreset) -> some View {
        HStack(spacing: 10) {
            Image(systemName: preset.mode == .cloud ? "cloud.fill" : "desktopcomputer")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(preset.mode == .cloud ? Color.blue : Color.secondary)
                .frame(width: 20)
                .help(preset.mode == .cloud ? "云端" : "本机")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(preset.name).font(.body.weight(.medium)).lineLimit(1)
                    StatusPill(text: preset.kind.title)
                }
                Text("\(preset.modelName) · \(preset.url)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button("编辑") { editing = PresetForm(preset) }.controlSize(.small)
            Button(role: .destructive) { pendingRemoval = preset } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .controlSize(.small).accessibilityLabel("删除预设 \(preset.name)")
        }
    }
}

struct PresetEditor: View {
    @ObservedObject var workspace: V2Workspace
    let dismiss: () -> Void
    @State private var form: PresetForm
    @State private var key = ""
    @State private var busy = false
    @State private var message: String?
    @State private var fault: String?

    init(workspace: V2Workspace, initial: PresetForm, dismiss: @escaping () -> Void) {
        self.workspace = workspace
        self.dismiss = dismiss
        _form = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(form.name.isEmpty ? "新增模型预设" : form.name).font(.title2.weight(.semibold))
            TextField("预设名称，如 本机 Qwen", text: $form.name).textFieldStyle(.roundedBorder)
            HStack(spacing: 14) {
                Picker("位置", selection: $form.mode) {
                    Text("本机").tag(ModelMode.local)
                    Text("云端").tag(ModelMode.cloud)
                }
                .pickerStyle(.segmented)
                Picker("用途", selection: $form.kind) {
                    ForEach(ModelKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            TextField(form.mode == .local ? "http://127.0.0.1:11434/v1" : "https://api.example.com/v1", text: $form.url)
                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
            TextField("模型名", text: $form.modelName).textFieldStyle(.roundedBorder)
            HStack(spacing: 18) {
                Stepper("最大 Token \(form.maxTokens)", value: $form.maxTokens, in: 16...16_000, step: 64)
                Stepper("温度 \(form.temperature, specifier: "%.2f")", value: $form.temperature, in: 0...2, step: 0.05)
            }
            if form.kind == .chat {
                // 未设置时按引擎默认的 max 展示，不选择就不写入配置。
                Picker("推理强度", selection: Binding(get: { form.reasoningEffort ?? .max },
                                                  set: { form.reasoningEffort = $0 })) {
                    ForEach(ReasoningEffort.displayOrder, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("preset-reasoning-effort")
            }
            if form.mode == .cloud { keySection }
            if let issue = form.issues.first { InlineNotice(text: issue, tone: .warning) }
            if let message { InlineNotice(text: message, tone: .active) }
            if let fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
            HStack {
                Spacer()
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                Button("应用到草稿") {
                    workspace.upsertPreset(form.build())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!form.issues.isEmpty)
                .accessibilityIdentifier("preset-apply")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                SecureField("API Key（按端点存入钥匙串）", text: $key).textFieldStyle(.roundedBorder)
                Button("存入") { updateKey(save: true) }.disabled(key.isEmpty || form.endpoint == nil || busy)
                Button("移除") { updateKey(save: false) }.disabled(form.endpoint == nil || busy)
            }
            Text("密钥只保存在 macOS 钥匙串，不写入设置文件。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func updateKey(save: Bool) {
        guard let endpoint = form.endpoint, let entry = try? KeychainEntry.model(endpoint: endpoint, kind: form.kind) else {
            fault = "invalid-endpoint"
            return
        }
        let vault = workspace.vault, secret = key
        busy = true
        fault = nil
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    if save { try vault.save(secret, for: entry) } else { try vault.remove(entry) }
                }.value
                key = ""
                message = save ? "密钥已存入钥匙串。" : "密钥已移除。"
            } catch {
                fault = V2Workspace.code(error)
            }
        }
    }
}

// MARK: - 云端统一授权

private struct CloudAuthorizationCard: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var settings: SettingsStore

    init(workspace: V2Workspace) {
        self.workspace = workspace
        settings = workspace.settings
    }

    private var cloudPresets: [ModelPreset] { settings.draft.models.filter { $0.mode == .cloud } }

    var body: some View {
        if !cloudPresets.isEmpty {
            Section {
                ForEach(cloudPresets) { preset in
                    Toggle(isOn: binding(for: preset.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(preset.name)
                                StatusPill(text: preset.kind.title)
                            }
                            Text(preset.url).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("cloud-approve-\(preset.id)")
                }
            } header: {
                Text("云端模型统一授权")
            } footer: {
                Text("授权后，记忆整理、人格进化、后链路插件与图片/语音解析可使用该云端点，会话开启确认也会默认勾选。私密（仅本机）记忆绝不发往云端；API Key 仅从钥匙串读入内存，不落盘；修改地址后需重新授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for presetId: String) -> Binding<Bool> {
        Binding(
            get: { settings.draft.runtime.approvedCloudPresetIds.contains(presetId) },
            set: { allow in
                var list = settings.draft.runtime.approvedCloudPresetIds
                if allow {
                    if !list.contains(presetId) { list.append(presetId) }
                } else {
                    list.removeAll { $0 == presetId }
                }
                settings.draft.runtime.approvedCloudPresetIds = list
            }
        )
    }
}

// MARK: - 默认模型

private struct DefaultModelsCard: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var settings: SettingsStore
    @State private var advancedExpanded = false

    init(workspace: V2Workspace) {
        self.workspace = workspace
        settings = workspace.settings
    }

    private var chatPresets: [ModelPreset] { settings.draft.models.filter { $0.kind == .chat } }
    private var visionPresets: [ModelPreset] { settings.draft.models.filter { $0.kind == .chat || $0.kind == .vision } }
    private var sttPresets: [ModelPreset] { settings.draft.models.filter { $0.kind == .stt } }

    private var overrideCount: Int {
        let models = settings.draft.defaultModels
        return [models.pluginPresetId, models.memoryPresetId, models.visionPresetId, models.sttPresetId].compactMap { $0 }.count
    }

    private var primary: Binding<String?> {
        Binding(get: { settings.draft.defaultModels.replyPresetId }, set: { workspace.setPrimaryModel($0) })
    }

    var body: some View {
        Section("默认模型") {
            Picker(selection: primary) {
                Text("未指定").tag(String?.none)
                ForEach(chatPresets) { Text($0.name).tag(String?.some($0.id)) }
            } label: {
                rowLabel("默认主模型", "默认同时用于自动回复、后链路插件、记忆人格整理与图片理解")
            }
            .accessibilityIdentifier("default-primary-model")
            Picker(selection: binding(\.fallbackReplyPresetId)) {
                Text("不启用").tag(String?.none)
                ForEach(chatPresets) { Text($0.name).tag(String?.some($0.id)) }
            } label: {
                rowLabel("备用模型", "主模型超时或故障时自动切换")
            }
            .accessibilityIdentifier("default-fallback-model")
            if let fallbackNotice { InlineNotice(text: fallbackNotice, tone: .warning) }
            Toggle(isOn: $settings.draft.runtime.fastReplyMode) {
                rowLabel("快速回复模式", "实时聊天使用低档推理加速响应，后台记忆整理与插件仍保持最高推理强度")
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("fast-reply-mode")
            DisclosureGroup(isExpanded: $advancedExpanded) {
                override("后链路提炼", presets: chatPresets, path: \.pluginPresetId, noneTitle: "跟随主模型")
                override("记忆与人格整理", presets: chatPresets, path: \.memoryPresetId, noneTitle: "跟随主模型")
                override("图片理解", presets: visionPresets, path: \.visionPresetId, noneTitle: "跟随主模型")
                override("语音转写", presets: sttPresets, path: \.sttPresetId, noneTitle: "未指定")
            } label: {
                HStack(spacing: 6) {
                    Text("高级：按场景单独覆盖（可选）")
                    if overrideCount > 0 { StatusPill(text: "已覆盖 \(overrideCount) 项", tone: .warning) }
                }
            }
            .accessibilityIdentifier("default-models-advanced")
        }
    }

    private func rowLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fallbackNotice: String? {
        let models = settings.draft.defaultModels
        guard let id = models.fallbackReplyPresetId else { return nil }
        if id == models.replyPresetId { return "备用模型与主模型相同，主模型失败时不会切换到其他模型。" }
        guard settings.draft.preset(id)?.mode == .cloud, !settings.draft.runtime.approvedCloudPresetIds.contains(id) else { return nil }
        return "备用模型是云端预设，需先在「云端模型统一授权」中开启，否则无法自动切换。"
    }

    private func binding(_ path: WritableKeyPath<SettingsV2.DefaultModels, String?>) -> Binding<String?> {
        Binding(get: { settings.draft.defaultModels[keyPath: path] },
                set: { settings.draft.defaultModels[keyPath: path] = $0 })
    }

    private func override(_ title: String, presets: [ModelPreset], path: WritableKeyPath<SettingsV2.DefaultModels, String?>,
                          noneTitle: String) -> some View {
        Picker(title, selection: binding(path)) {
            Text(noneTitle).tag(String?.none)
            ForEach(presets) { Text($0.name).tag(String?.some($0.id)) }
        }
    }
}

// MARK: - 模型试拟

private struct ModelPreviewCard: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var runtime: BridgeRuntime
    @ObservedObject private var settings: SettingsStore

    @State private var presetId: String?
    @State private var sample = "周末要不要一起吃个饭？"
    @State private var busy = false
    @State private var result: ModelPreviewResult?
    @State private var fault: String?
    @State private var confirmingCloud = false

    init(workspace: V2Workspace) {
        self.workspace = workspace
        runtime = workspace.runtime
        settings = workspace.settings
    }

    private var presets: [ModelPreset] { settings.draft.models.filter { $0.kind == .chat } }
    private var selected: ModelPreset? { presets.first { $0.id == presetId } ?? presets.first }
    private var validSample: Bool {
        (1...400).contains(sample.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count)
    }

    var body: some View {
        Section {
            Picker("预设", selection: Binding(get: { selected?.id }, set: { presetId = $0 })) {
                if presets.isEmpty { Text("没有对话模型").tag(String?.none) }
                ForEach(presets) { Text($0.name).tag(String?.some($0.id)) }
            }
            TextField("合成例句", text: $sample, axis: .vertical)
                .lineLimit(2...4)
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(selected?.mode == .cloud ? "云端试拟…" : "本机试拟") {
                    if selected?.mode == .cloud { confirmingCloud = true } else { run(cloudApproved: false) }
                }
                .disabled(selected == nil || !validSample || !runtime.ready || busy)
                .accessibilityIdentifier("model-preview")
                .confirmationDialog("确认本次云端试拟", isPresented: $confirmingCloud, titleVisibility: .visible) {
                    Button("发送这一次") { run(cloudApproved: true) }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("本次将把当前合成例句（不含真实聊天）和允许出境的脱敏片段发往：\n\(selected?.url ?? "")")
                }
            }
            if let result { resultView(result) }
            if let fault { InlineNotice(text: v2Explanation(fault), tone: .critical) }
        } header: {
            Text("模型试拟")
        } footer: {
            Text("不发送微信消息。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func resultView(_ value: ModelPreviewResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            StatusPill(text: actionTitle(value.action), tone: value.action == .reply ? .active : .warning)
            if let text = value.text { Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func actionTitle(_ action: ModelPreviewResult.Action) -> String {
        switch action {
        case .reply: return "会回复"
        case .skip: return "跳过本轮"
        case .manual: return "转人工"
        case .stop: return "识别为叫停"
        case .identity: return "身份询问"
        }
    }

    private func run(cloudApproved: Bool) {
        guard let id = selected?.id else { return }
        let text = sample
        busy = true
        result = nil
        fault = nil
        Task { @MainActor in
            defer { busy = false }
            do { result = try await settings.preview(presetId: id, text: text, cloudApproved: cloudApproved) }
            catch { fault = V2Workspace.code(error) }
        }
    }
}

private struct LegacyProfileNoticeCard: View {
    @ObservedObject var workspace: V2Workspace
    @ObservedObject private var settings: SettingsStore

    init(workspace: V2Workspace) {
        self.workspace = workspace
        settings = workspace.settings
    }

    private var hasLegacy: Bool {
        !(settings.draft.memory.legacyStylePath ?? "").isEmpty || !(settings.draft.memory.legacyMemoryPath ?? "").isEmpty
    }

    var body: some View {
        if hasLegacy {
            Section("旧版外部档案路径（v1 迁移）") {
                if let style = settings.draft.memory.legacyStylePath, !style.isEmpty {
                    Text("风格档案：\(style)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let mem = settings.draft.memory.legacyMemoryPath, !mem.isEmpty {
                    Text("记忆档案：\(mem)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Button("清除旧版档案绑定") {
                    settings.draft.memory.legacyStylePath = nil
                    settings.draft.memory.legacyMemoryPath = nil
                }
                .controlSize(.small)
            }
        }
    }
}
