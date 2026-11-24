import AppKit
import SwiftUI

enum ReplyMode: Hashable { case automatic, draft }

struct PreviewResult: Decodable, Equatable {
    let action: String
    let text: String?
    var caption: String {
        if let text { return text }
        return action == "skip" ? "这句可以不回。" : action == "stop" ? "识别为停止请求。" : "建议本人回复。"
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var configuration = Configuration()
    @Published private(set) var state = EngineState()
    @Published private(set) var ready = false
    @Published private(set) var startingReply: ReplyMode?
    @Published private var savingSettings = false
    @Published var error: String?
    @Published private(set) var sleepRevision = 0

    let client = BridgeClient()
    private let disk: SettingsDisk
    private let executable: URL
    private let keychain: ModelKeychain
    private var authToken: UUID?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(disk: SettingsDisk = .standard, executable: URL? = nil, keychain: ModelKeychain = .standard) {
        self.disk = disk
        self.executable = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bridge-engine")
        self.keychain = keychain
        client.onState = { [weak self] state in self?.state = state }
        client.onFailure = { [weak self] code in
            self?.state = EngineState(); self?.error = code; self?.invalidateAuth()
        }
        client.onReady = { [weak self] ready in
            guard let self else { return }
            self.ready = ready
            if ready, let target = self.configuration.target {
                Task { await self.perform { let _: Bool = try await self.client.request("inspect", target) } }
            }
        }
    }

    var authorizing: Bool { startingReply != nil }
    var automaticReplyOn: Bool { state.autoReply || startingReply == .automatic }
    var beginBlocker: BeginBlocker? {
        BeginBlocker.evaluate(ready: ready, state: state, authorizing: authorizing, savingSettings: savingSettings)
    }
    var canBegin: Bool { beginBlocker == nil }

    func start() {
        guard !started else { return }
        started = true
        load()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pause("system-sleep")
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.client.shutdown() }
        })
    }

    func load() {
        guard !ready else { return }
        do {
            if NativeQA.active && NativeQA.home == nil { throw BridgeFault("storage-unavailable") }
            let loaded = try disk.load()
            try NativeQA.check(loaded)
            configuration = loaded
            try client.start(engine: executable, directory: disk.directory)
            error = nil
        } catch { capture(error) }
    }

    func save(_ value: Configuration) async throws {
        guard ready, !state.inFlight, !authorizing, !savingSettings else { throw BridgeFault("busy") }
        guard value.addressesValid else { throw BridgeFault("invalid-endpoint") }
        try NativeQA.check(value)
        savingSettings = true
        defer { savingSettings = false }
        // Revoke the old scope before saving. Never leave a hidden session running behind new settings.
        let _: Bool = try await client.request("pause", ["reason": "settings-changed"])
        try disk.save(value)
        configuration = value
        if let target = value.target { let _: Bool = try await client.request("inspect", target) }
        else { state = EngineState() }
    }

    func accounts(_ url: String) async throws -> [AccountOption] {
        try NativeQA.checkMCP(url)
        return try await client.request("accounts", ["mcp": url])
    }

    func contacts(_ url: String, account: String, query: String) async throws -> [ContactOption] {
        try NativeQA.checkMCP(url)
        return try await client.request("contacts", ["mcp": url, "account": account, "query": query])
    }

    func saveKey(_ key: String, for url: String) async throws {
        let storage = keychain
        try await Task.detached(priority: .userInitiated) { try storage.save(key, for: url) }.value
    }

    func removeKey(for url: String) async throws {
        guard !state.running && !authorizing else { throw BridgeFault("busy") }
        let storage = keychain
        try await Task.detached(priority: .userInitiated) { try storage.remove(url) }.value
    }

    func arm(_ mode: ReplyMode, consent: Bool, cloud: Bool, confirmed c: Configuration) throws {
        guard configuration == c, canBegin, consent, let target = c.target, c.modelComplete else { throw BridgeFault("invalid-configuration") }
        guard c.mode != .cloud || cloud else { throw BridgeFault("cloud-not-approved") }
        let token = UUID()
        authToken = token
        startingReply = mode
        error = nil
        Task { @MainActor in
            guard authToken == token else { return }
            defer { if authToken == token { invalidateAuth() } }
            do {
                let key: String?
                if c.mode == .cloud {
                    let storage = keychain
                    key = try await Task.detached(priority: .userInitiated) { try storage.read(c.modelURL) }.value
                } else { key = nil }
                guard authToken == token, configuration == c else { return }
                let _: Bool = try await client.request("arm", ["target": target, "model": try c.model(approved: cloud, key: key),
                    "consent": true, "dryRun": mode == .draft])
            } catch {
                if authToken == token { capture(error) }
            }
        }
    }

    func send(_ text: String, at: Date?, confirmed c: Configuration) async throws {
        guard canBegin, configuration == c, let target = c.target else { throw BridgeFault("invalid-configuration") }
        var args: [String: Any] = ["target": target, "text": text, "consent": true, "request": UUID().uuidString]
        if let at { args["at"] = epoch(at) }
        let _: Bool = try await client.request("active", args)
    }

    func preview(_ c: Configuration, text: String, cloudApproved: Bool = false) async throws -> PreviewResult {
        // 先判同意：未确认的云端请求不读钥匙串，也不进入后台。
        guard c.mode != .cloud || cloudApproved else { throw BridgeFault("cloud-not-approved") }
        guard c.modelComplete else { throw BridgeFault("invalid-configuration") }
        try requirePreviewIdle()
        try NativeQA.check(c)
        var key: String?
        if c.mode == .cloud {
            let revision = sleepRevision, storage = keychain, url = c.modelURL
            key = try await Task.detached(priority: .userInitiated) { try storage.read(url) }.value
            // 读钥匙串可能等待系统授权；期间暂停或休眠即作废这次确认。
            guard revision == sleepRevision else { throw BridgeFault("stopped") }
            try requirePreviewIdle()
        }
        return try await client.request("preview", ["model": try c.model(approved: c.mode == .cloud, key: key), "text": text])
    }

    private func requirePreviewIdle() throws {
        guard ready else { throw BridgeFault("engine-not-ready") }
        guard !state.running && !state.inFlight && !authorizing else { throw BridgeFault("busy") }
    }

    func pause(_ reason: String = "user-paused") {
        invalidateAuth()
        sleepRevision += 1
        guard ready else { return }
        error = nil
        client.pause(reason)
    }

    func recovery(_ command: String) {
        guard let target = configuration.target else { return }
        Task {
            await perform {
                let args: [String: Any] = command == "refresh" ? target : ["target": target, "confirmed": true]
                let _: Bool = try await client.request(command, args)
            }
        }
    }

    func perform(_ run: () async throws -> Void) async {
        error = nil
        do { try await run() } catch { capture(error) }
    }

    func capture(_ thrown: Error) {
        let code = (thrown as? BridgeFault)?.code ?? "internal-error"
        if code != "stopped" { error = code }
    }

    private func invalidateAuth() { authToken = nil; startingReply = nil }
}

func explanation(_ code: String) -> String {
    switch code {
    case "user-paused": return "已停止监听，不再提交新消息。"
    case "settings-changed": return "设置已更改；需重新开启。"
    case "system-sleep", "clock-changed": return "Mac 休眠、锁定或时间改变；请重新开启。"
    case "expired": return "已过单次发送的有效时间，未提交的消息已取消。"
    case "mcp-offline": return "未连接到小禾；检查本机地址和微信登录。"
    case "wechat-permission": return "小禾没有授予此连接需要的读信或发信权限。"
    case "event-gap": return "小禾事件缓存有缺口；不会补扫聊天。"
    case "backlog-limit": return "事件积压过多，已暂停；核对后可继续读取，仍超限会再次暂停。"
    case "wechat-changed": return "小禾服务或微信登录身份已变化；核对账号和联系人后再建立起点。"
    case "mcp-contract", "wrong-anchor": return "小禾返回了无法核验的格式，已停止处理。"
    case "manual-takeover": return "发现本人发信或无法核对发信来源，已交还给你。"
    case "manual-review": return "这轮不适合自动回，请在微信里亲自处理。"
    case "peer-stopped": return "对方已要求停止。不会再自动回或主动发送。"
    case "send-unknown": return "无法确定是否已提交。请先在微信核对，App 不会重发。"
    case "send-rejected": return "小禾拒绝提交或报告发送失败。"
    case "send-fence": return "发送前出现新事件，无法确认当前状态，这条没有提交。"
    case "duplicate-attempt": return "这次发送已处理过，不重复提交。"
    case "active-limit": return "已到今天的手动单次提交上限。"
    case "busy-chat": return "消息过多，请接手这轮对话。"
    case "draft-ready": return "草稿只在此处短暂显示，没有发信。"
    case "model-skip": return "这轮没有回复。"
    case "one-shot-complete": return "一次发送已完成，未开启自动回复。"
    case "cloud-not-approved": return "尚未同意把所需文字交给所选云模型。"
    case "cloud-profile": return "云端档案须只使用明确标记的脱敏片段；详见使用说明。"
    case "profile-unreadable": return "档案不可读：请选本机普通 UTF-8 文本（不超过 64 KiB）。"
    case "model-timeout": return "模型响应超时，未发信。"
    case "model-format": return "模型未返回可用的 JSON 决定，未发信。"
    case "model-unavailable", "model-auth", "model-limit": return "模型接口不可用；请检查地址、模型、权限或用量。"
    case "keychain-unavailable": return "无法访问 macOS 钥匙串；请确认当前钥匙串已解锁。"
    case "missing-key": return "请在设置中将这个云端点的密钥存入钥匙串。"
    case "invalid-key": return "密钥格式无效。"
    case "preview-local-only": return "当前后台版本仅支持本机模型试拟；云端试拟需要升级后台。"
    case "storage-in-use": return "另一个实例在使用本机状态；请退出另一个实例后重试。"
    case "config-unreadable", "storage-unavailable": return "无法安全读取本机设置或状态；请检查应用目录权限。"
    case "invalid-endpoint": return "地址格式不正确；本机使用 127.0.0.1 及端口，云端使用 HTTPS。"
    case "invalid-expiry": return "时间无效：需在今天内，且尚未到点。"
    case "invalid-configuration": return "请检查账号、指定私聊、模型或输入文字的格式。"
    case "engine-exited", "engine-missing", "engine-not-ready", "engine-timeout", "engine-protocol": return "后台未就绪或已退出；不会继续授权，请重启后台。"
    case "busy": return "请暂停当前任务，等正在提交的请求返回后再试。"
    case "no-operation": return "没有可向小禾查询的操作 ID。"
    default: return "操作未完成；自动发送不会在异常后自行恢复。"
    }
}
