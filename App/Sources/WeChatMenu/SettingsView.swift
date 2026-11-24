import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    // 确认区展示的内容就是实际发送的内容，表单之后的改动不会混入这次请求。
    private struct CloudPreviewReview {
        let configuration: Configuration
        let endpoint: String
        let text: String
    }

    @ObservedObject var store: AppStore
    @State private var form = Configuration()
    @State private var accounts: [AccountOption] = []
    @State private var contacts: [ContactOption] = []
    @State private var query = ""
    @State private var key = ""
    @State private var sample = "下楼刚好碰上有太阳"
    @State private var preview: PreviewResult?
    @State private var cloudReview: CloudPreviewReview?
    @State private var busy = false
    @State private var feedback: String?
    @State private var fault: String?
    @State private var loaded = false

    private var hasUnsavedChanges: Bool { loaded && form != store.configuration }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("微信桥").font(.largeTitle.weight(.semibold))
                    Text("一个账号、一个知情的私聊，只处理文字。保存设置不会开启监听或发送。")
                        .foregroundStyle(.secondary)
                }
                if let fault { Notice(text: explanation(fault), important: true) }
                if let feedback { Notice(text: feedback) }
                connection
                model
                profile
                calibration
            }.padding(22)
        }
        .frame(minWidth: 555, minHeight: 490)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    if hasUnsavedChanges {
                        Label(store.state.running ? "有未保存的更改 · 保存会暂停监听及发送" : "有未保存的更改",
                              systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        Button("放弃更改", action: discardChanges).disabled(busy)
                    } else {
                        Text(runtimeHint).font(.caption).foregroundStyle(.secondary)
                    }
                    if !store.ready { Button("重启后台") { store.load() } }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("保存设置") { submit { try await store.save(form); feedback = "设置已保存。" } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !store.ready || store.state.inFlight || store.authorizing || !form.addressesValid)
                }.padding(.horizontal, 22).padding(.vertical, 10).background(.bar)
            }
        }
        .task {
            store.start()
            if !loaded { form = store.configuration; loaded = true }
        }
        .onChange(of: form) { _ in cloudReview = nil }
        .onChange(of: sample) { _ in cloudReview = nil }
        .onChange(of: store.sleepRevision) { _ in cloudReview = nil }
        .onDisappear { key = ""; preview = nil; cloudReview = nil }
    }

    private var runtimeHint: String {
        guard store.ready else { return "后台未就绪" }
        return "当前状态：\(store.state.title)" + (store.state.running ? " · 保存会暂停监听及发送" : "")
    }

    private func discardChanges() {
        form = store.configuration
        // 账号和联系人列表可能来自被放弃的地址，一并清空。
        accounts = []; contacts = []; key = ""; preview = nil; cloudReview = nil
        fault = nil; feedback = "已放弃未保存的更改。"
    }

    private var connection: some View {
        settingsGroup("1  小禾连接与私聊", "link") {
            HStack {
                TextField("http://127.0.0.1:端口/mcp", text: Binding(get: { form.mcp }, set: { value in
                    if value != form.mcp { form.mcp = value; form.account = ""; form.accountLabel = ""; form.contact = nil; contacts = []; accounts = [] }
                })).textFieldStyle(.roundedBorder).accessibilityLabel("小禾 MCP 地址")
                Button("读取账号") {
                    let url = form.mcp
                    submit {
                        let result = try await store.accounts(url)
                        guard url == form.mcp else { return }
                        accounts = result
                        if result.isEmpty { feedback = "没有返回可用账号。" }
                    }
                }.disabled(busy || !store.ready || !Configuration.validURL(form.mcp, kind: "mcp"))
            }
            if !form.mcp.isEmpty && !Configuration.validURL(form.mcp, kind: "mcp") {
                Notice(text: "小禾地址须为 http://127.0.0.1:端口/mcp，不带参数。", important: true)
            }
            if !accounts.isEmpty {
                Picker("微信账号", selection: Binding(get: { form.account }, set: { id in
                    if form.account != id { form.account = id; form.accountLabel = accounts.first(where: { $0.id == id })?.label ?? ""; form.contact = nil; contacts = [] }
                })) {
                    Text("请选择账号").tag("")
                    if !form.account.isEmpty && !accounts.contains(where: { $0.id == form.account }) {
                        Text("已保存 · 未出现在当前列表").tag(form.account)
                    }
                    ForEach(accounts) { row in
                        Text("\(row.label) · \(row.canRead ? (row.canSend ? "可读写" : "仅读") : "未就绪")").tag(row.id)
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("wechat-account")
            } else if !form.account.isEmpty {
                Text("已选账号：\(form.accountLabel)").foregroundStyle(.secondary)
            }
            HStack {
                TextField("输入联系人备注或昵称", text: $query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("搜索私聊联系人")
                    .onSubmit(search)
                Button("查找私聊", action: search).disabled(!canSearch)
            }
            if !contacts.isEmpty {
                Picker("指定私聊", selection: Binding(get: { form.contact?.id ?? "" }, set: { id in form.contact = contacts.first { $0.id == id } })) {
                    Text("请选择一个联系人").tag("")
                    if let c = form.contact, !contacts.contains(where: { $0.id == c.id }) { Text("\(c.label) · 当前绑定").tag(c.id) }
                    ForEach(contacts) { row in Text("\(row.label) · …\(row.id.suffix(7))").tag(row.id) }
                }.pickerStyle(.menu).accessibilityIdentifier("direct-contact")
            } else if let contact = form.contact {
                Label("已选私聊：\(contact.label) · …\(contact.id.suffix(7))", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            Text("从小禾获取本机 MCP 地址，并单独给本 App 授予所需权限。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var canSearch: Bool {
        !busy && store.ready && !form.account.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func search() {
        guard canSearch else { return }
        let url = form.mcp, account = form.account, q = query
        submit {
            let result = try await store.contacts(url, account: account, query: q)
            guard url == form.mcp, account == form.account, q == query else { return }
            contacts = result
            if result.isEmpty { feedback = "未找到匹配的普通私聊联系人。" }
        }
    }

    private var model: some View {
        settingsGroup("2  生成模型", "sparkles") {
            Picker("数据去向", selection: Binding(get: { form.mode }, set: { mode in
                guard form.mode != mode else { return }
                form.mode = mode
                form.modelURL = mode == .local ? Configuration().modelURL : ""
                form.modelName = ""; key = ""; preview = nil
            })) {
                Text("本机（默认）").tag(ModelMode.local)
                Text("云 API").tag(ModelMode.cloud)
            }.pickerStyle(.segmented)
            TextField(form.mode == .local ? "http://127.0.0.1:端口/v1" : "https://…/v1", text: $form.modelURL)
                .accessibilityLabel("模型 API 地址").textFieldStyle(.roundedBorder).onChange(of: form.modelURL) { _ in key = ""; preview = nil }
            if let endpoint = form.modelEndpoint, endpoint != form.modelURL {
                Text("实际请求：\(endpoint)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            } else if !form.modelURL.isEmpty && form.modelEndpoint == nil {
                let origin = form.mode == .cloud ? "HTTPS 云端地址" : "带端口的 http://127.0.0.1"
                Notice(text: "请填\(origin)，以 /v1 或 /chat/completions 结尾，不带账号、密钥或参数。", important: true)
            } else if form.modelURL.isEmpty {
                Text("可填 /v1 基础地址或完整的 /chat/completions 接口地址。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("准确的模型名或模型 ID", text: $form.modelName).accessibilityLabel("模型 ID").textFieldStyle(.roundedBorder)
            if form.mode == .cloud {
                HStack {
                    SecureField("API 密钥（不显示已保存的密钥）", text: $key).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("model-key")
                    Button("存入钥匙串") {
                        let credential = key, url = form.modelURL
                        key = ""
                        submit { try await store.saveKey(credential, for: url); feedback = "密钥已存到当前端点的钥匙串条目。" }
                    }.disabled(busy || key.isEmpty || form.modelEndpoint == nil)
                    Button("移除") {
                        let url = form.modelURL
                        submit { try await store.removeKey(for: url); feedback = "当前端点的钥匙串条目已移除。" }
                    }.disabled(busy || store.state.running || store.authorizing || form.modelEndpoint == nil)
                }
                Notice(text: "云端每次启用须同意数据去向；会发送合并后的必要文字、最近少量上下文与标记的脱敏档案片段。")
            } else {
                Text("先启动支持 Chat Completions 和 JSON 模式的本机服务。请选实际在本机推理、不向外转发的模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var profile: some View {
        settingsGroup("3  风格和记忆（选填）", "doc.text") {
            pathRow("人格 / 通用风格", path: $form.stylePath)
            pathRow("专档 / 脱敏记忆", path: $form.memoryPath)
            Text("选择已有的 UTF-8 .md 或 .txt。仅写经你确认的脱敏规律；App 只读，不自动保存聊天或更新记忆。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pathRow(_ label: String, path: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Text(path.wrappedValue.isEmpty ? "未选择" : URL(fileURLWithPath: path.wrappedValue).lastPathComponent)
                .font(.callout).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(path.wrappedValue)
            Spacer()
            Button("选择…") {
                let dialog = NSOpenPanel()
                dialog.canChooseDirectories = false; dialog.allowsMultipleSelection = false; dialog.resolvesAliases = false
                dialog.allowedContentTypes = [UTType(filenameExtension: "md"), UTType.plainText].compactMap { $0 }
                if dialog.runModal() == .OK, let url = dialog.url { path.wrappedValue = url.path; preview = nil }
            }.disabled(busy)
            if !path.wrappedValue.isEmpty { Button("清除") { path.wrappedValue = ""; preview = nil }.disabled(busy) }
        }
    }

    private var calibration: some View {
        settingsGroup("4  模型试拟", "text.bubble") {
            Text("填合成或脱敏例句；不连接微信、不提交消息。云 API 每次试拟都要单独确认。试过几种语气再考虑开启。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("合成例句", text: $sample).textFieldStyle(.roundedBorder)
                Button("试拟一条", action: requestPreview).disabled(!canPreview)
            }
            if let review = cloudReview { cloudReviewPanel(review) }
            if let preview { Text(preview.caption).textSelection(.disabled) }
        }
    }

    private var canPreview: Bool {
        !busy && store.ready && form.modelComplete && !store.state.running && !sample.isEmpty && sample.utf16.count <= 400
    }

    private func requestPreview() {
        guard canPreview else { return }
        guard form.mode == .cloud else { runPreview(form, text: sample, cloudApproved: false); return }
        guard let endpoint = form.modelEndpoint else { return }
        preview = nil
        cloudReview = CloudPreviewReview(configuration: form, endpoint: endpoint, text: sample)
    }

    private func runPreview(_ value: Configuration, text: String, cloudApproved: Bool) {
        submit {
            preview = nil
            let result = try await store.preview(value, text: text, cloudApproved: cloudApproved)
            // 等待期间表单或例句已改时，不展示旧配置的结果。
            if value == form && text == sample { preview = result }
        }
    }

    private func cloudReviewPanel(_ review: CloudPreviewReview) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("确认单次云端试拟").font(.headline)
            Text(review.endpoint).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).accessibilityIdentifier("cloud-preview-endpoint")
            Text("模型：\(review.configuration.modelName)").font(.caption).foregroundStyle(.secondary)
            Text("例句：\(review.text)").font(.caption).fixedSize(horizontal: false, vertical: true)
            Notice(text: "仅本次把这条例句和档案中明确标记的脱敏片段发给以上端点。不连接微信，不提交消息。")
            HStack {
                Spacer()
                Button("取消") { cloudReview = nil }
                Button("确认发送脱敏例句试拟") {
                    cloudReview = nil
                    runPreview(review.configuration, text: review.text, cloudApproved: true)
                }.buttonStyle(.borderedProminent).disabled(!canPreview)
            }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func settingsGroup<T: View>(_ title: String, _ image: String, @ViewBuilder contents: () -> T) -> some View {
        GroupBox(label: Label(title, systemImage: image).font(.headline)) {
            VStack(alignment: .leading, spacing: 9, content: contents)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }
    }

    private func submit(_ run: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; fault = nil; feedback = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await run() }
            catch { fault = (error as? BridgeFault)?.code ?? "internal-error" }
        }
    }
}
