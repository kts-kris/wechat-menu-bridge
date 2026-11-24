import Foundation

@MainActor
protocol BridgeTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    func send(_ frame: Data)
    func sendUrgent(_ frame: Data)
    func close()
}

extension BridgeTransport {
    func sendUrgent(_ frame: Data) { send(frame) }
}

private struct FrameHead: Decodable {
    let v: Int?
    let kind: String
    let id: Int?
    let code: String?
}

private struct RequestFrame<Params: Encodable>: Encodable {
    let v = IPCv3.version
    let id: Int
    let method: String
    let params: Params
}

@MainActor
final class BridgeClientV3 {
    private var transport: BridgeTransport?
    private var generation = UUID()
    private var seq = 0
    private var buffer = Data()
    private var pending: [Int: (Result<Data, BridgeFault>) -> Void] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]
    private var helloTimer: DispatchWorkItem?
    private let helloTimeout: TimeInterval
    private let replyTimeout: ((RPCMethod) -> TimeInterval)
    private(set) var ready = false
    private(set) var finalFault: String?

    var onEvent: ((PushEvent) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    init(helloTimeout: TimeInterval = 4, replyTimeout: @escaping (RPCMethod) -> TimeInterval = BridgeClientV3.defaultTimeout) {
        self.helloTimeout = helloTimeout
        self.replyTimeout = replyTimeout
    }

    nonisolated static func defaultTimeout(_ method: RPCMethod) -> TimeInterval {
        switch method {
        case .systemPauseAll, .sessionPause: return 2
        // 模型以 reasoning_effort=max 推理时首包可能很慢，体检还要串行跑完其余三步。
        case .modelPreview, .systemHealthCheck: return 95
        case .memoryConsolidateNow, .pluginsRunNow: return 120
        default: return 26
        }
    }

    var connected: Bool { transport != nil }

    func connect(_ next: BridgeTransport) throws {
        guard transport == nil else { throw BridgeFault("busy") }
        let token = UUID()
        generation = token
        finalFault = nil
        ready = false
        buffer.removeAll()
        transport = next
        next.onData = { [weak self] data in
            guard let self, self.generation == token else { return }
            self.consume(data, token)
        }
        next.onClosed = { [weak self] in
            guard let self, self.generation == token else { return }
            self.fail("engine-exited")
        }
        helloTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, !self.ready, self.finalFault == nil else { return }
            self.fail("engine-timeout")
        }
        helloTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + helloTimeout, execute: item)
    }

    func shutdown() { fail("stopped", notify: false) }

    // MARK: 通用调用

    func call<Params: Encodable, Output: Codable>(_ method: RPCMethod, _ params: Params, as: Output.Type = Output.self) async throws -> Output {
        guard ready else { throw BridgeFault(finalFault ?? "engine-not-ready") }
        let id = nextID()
        let frame = try encode(method, id: id, params: params)
        let token = generation
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = { continuation.resume(with: $0.mapError { $0 as Error }) }
            transport?.send(frame)
            armTimeout(id: id, method: method, token: token)
        }
        // continuation 恢复后可能已经重连换代，绝不用旧连接的回复污染新连接。
        guard generation == token else { throw BridgeFault("engine-exited") }
        let reply: IPCReply<Output>
        do { reply = try IPCv3.decodeStrict(IPCReply<Output>.self, from: bytes) }
        catch {
            fail("engine-protocol")
            throw BridgeFault("engine-protocol")
        }
        switch reply.outcome {
        case .success(let value): return value
        case .failure(let code): throw BridgeFault(code.rawValue)
        }
    }

    // 休眠回调不能排在普通写入之后，必须同步抢占并清空未发出的普通帧；若遇到半帧或背压无法及时写出则立即断管撤权。
    func firePauseAll(scope: PauseScope, reason: IPCErrorCode) {
        guard ready else { return }
        let id = nextID()
        guard let frame = try? encode(.systemPauseAll, id: id, params: RPCParams.PauseAll(scope: scope, reason: reason)) else {
            fail("engine-protocol")
            return
        }
        pending[id] = { [weak self] response in
            guard let self, self.ready, case let .success(bytes) = response else { return }
            switch (try? IPCv3.decodeStrict(IPCReply<IPCAck>.self, from: bytes))?.outcome {
            case .success: break
            case .failure(let code): self.fail(code.rawValue)
            case nil: self.fail("engine-protocol")
            }
        }
        transport?.sendUrgent(frame)
        armTimeout(id: id, method: .systemPauseAll, token: generation)
    }

    private func nextID() -> Int {
        seq += 1
        return seq
    }

    private func encode<Params: Encodable>(_ method: RPCMethod, id: Int, params: Params) throws -> Data {
        var data = try IPCv3.encoder().encode(RequestFrame(id: id, method: method.rawValue, params: params))
        guard data.count <= IPCv3.maxFrameBytes else { throw BridgeFault("invalid-configuration") }
        data.append(10)
        return data
    }

    private func armTimeout(id: Int, method: RPCMethod, token: UUID) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.timers.removeValue(forKey: id)
            guard let completion = self.pending.removeValue(forKey: id) else { return }
            completion(.failure(BridgeFault("engine-timeout")))
            // 关闭管道会撤销本地授权，绝不留下可能仍在发信的后台。
            self.fail("engine-timeout")
        }
        timers[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + replyTimeout(method), execute: item)
    }

    // MARK: 帧解析

    private func consume(_ data: Data, _ token: UUID) {
        guard finalFault == nil else { return }
        buffer.append(data)
        var cursor = buffer.startIndex
        while let end = buffer[cursor...].firstIndex(of: 10) {
            guard end - cursor <= IPCv3.maxFrameBytes else { fail("engine-protocol"); return }
            let line = Data(buffer[cursor..<end])
            cursor = buffer.index(after: end)
            handle(line)
            guard generation == token, finalFault == nil else { return }
        }
        buffer = Data(buffer[cursor...])
        if buffer.count > IPCv3.maxFrameBytes { fail("engine-protocol") }
    }

    private func handle(_ line: Data) {
        guard let head = try? JSONDecoder().decode(FrameHead.self, from: line) else { fail("engine-protocol"); return }
        if head.kind == "fatal" {
            guard !ready || head.v == IPCv3.version else { fail("engine-protocol"); return }
            fail(head.code.flatMap(IPCErrorCode.init(rawValue:))?.rawValue ?? "engine-protocol")
            return
        }
        guard head.v == IPCv3.version else { fail("engine-protocol"); return }
        if head.kind == "error" {
            fail(head.code.flatMap(IPCErrorCode.init(rawValue:))?.rawValue ?? "engine-protocol")
            return
        }
        switch head.kind {
        case "event":
            guard let event = try? IPCv3.decodeStrict(PushEvent.self, from: line) else { fail("engine-protocol"); return }
            if case .hello = event {
                guard !ready else { fail("engine-protocol"); return }
                helloTimer?.cancel()
                helloTimer = nil
                ready = true
                onEvent?(event)
                onReady?(true)
            } else {
                guard ready else { fail("engine-protocol"); return }
                onEvent?(event)
            }
        case "reply":
            guard ready, let id = head.id, let completion = pending.removeValue(forKey: id) else {
                fail("engine-protocol")
                return
            }
            timers.removeValue(forKey: id)?.cancel()
            completion(.success(line))
        default:
            fail("engine-protocol")
        }
    }

    private func fail(_ code: String, notify: Bool = true) {
        guard finalFault == nil, let current = transport else { return }
        finalFault = code
        ready = false
        generation = UUID()
        helloTimer?.cancel()
        helloTimer = nil
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        transport = nil
        buffer.removeAll()
        current.onData = nil
        current.onClosed = nil
        current.close()
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0(.failure(BridgeFault(code))) }
        onReady?(false)
        if notify { onFailure?(code) }
    }
}

// MARK: - 35 个强类型 RPC

extension BridgeClientV3 {
    func systemStatus() async throws -> SystemStatus { try await call(.systemStatus, RPCParams.Empty()) }

    func systemPauseAll(scope: PauseScope, reason: IPCErrorCode) async throws {
        let _: IPCAck = try await call(.systemPauseAll, RPCParams.PauseAll(scope: scope, reason: reason))
    }

    func systemHealthCheck(presetId: String? = nil, conversationId: String? = nil) async throws -> HealthCheckResult {
        try await call(.systemHealthCheck, RPCParams.HealthCheck(presetId: presetId, conversationId: conversationId))
    }

    func systemBundles(action: String) async throws -> HotBundlesStatus {
        try await call(.systemBundles, RPCParams.Bundles(action: action))
    }

    func xiaoheAccounts(mcpUrl: String? = nil) async throws -> [XiaoheAccountOption] {
        try await call(.xiaoheAccounts, RPCParams.Accounts(mcpUrl: mcpUrl))
    }

    func xiaoheConversations(_ params: RPCParams.Conversations = .init()) async throws -> XiaoheConversationPage {
        try await call(.xiaoheConversations, params)
    }

    func xiaoheGroupMembers(conversationId: String) async throws -> [GroupMember] {
        try await call(.xiaoheGroupMembers, RPCParams.Session(conversationId: conversationId))
    }

    func xiaoheCapabilities() async throws -> XiaoheCapabilities { try await call(.xiaoheCapabilities, RPCParams.Empty()) }

    func settingsApply(_ settings: SettingsV2, cloudApiKeys: [String: String]? = nil) async throws {
        let keys = cloudApiKeys.flatMap { $0.isEmpty ? nil : $0 }
        let _: IPCAck = try await call(.settingsApply, RPCParams.ApplySettings(settings: settings, cloudApiKeys: keys))
    }

    func modelPreview(model: PreviewModel, text: String) async throws -> ModelPreviewResult {
        try await call(.modelPreview, RPCParams.Preview(model: model, text: text))
    }

    func sessionArm(_ params: RPCParams.Arm) async throws {
        let _: IPCAck = try await call(.sessionArm, params)
    }

    func sessionPause(conversationId: String, reason: IPCErrorCode? = nil) async throws {
        let _: IPCAck = try await call(.sessionPause, RPCParams.PauseSession(conversationId: conversationId, reason: reason))
    }

    func sessionSendOneShot(_ params: RPCParams.SendOneShot) async throws {
        let _: IPCAck = try await call(.sessionSendOneShot, params)
    }

    func sessionRefreshReceipt(conversationId: String) async throws -> SessionReceipt {
        try await call(.sessionRefreshReceipt, RPCParams.Session(conversationId: conversationId))
    }

    func sessionRecover(conversationId: String, action: SessionRecoverAction) async throws {
        let _: IPCAck = try await call(.sessionRecover, RPCParams.Recover(conversationId: conversationId, action: action))
    }

    func sessionBackfill(_ command: BackfillCommand) async throws -> BackfillJob { try await call(.sessionBackfill, command) }

    func sessionTraces(conversationId: String, limit: Int? = nil) async throws -> [SessionTraceEntry] {
        let list: SessionTraceList = try await call(.sessionTraces, RPCParams.SessionTraces(conversationId: conversationId, limit: limit))
        return list.items
    }

    func sessionResumeCooldown(conversationId: String) async throws -> Bool {
        try await call(.sessionResumeCooldown, RPCParams.Session(conversationId: conversationId))
    }

    func pluginsList() async throws -> [PluginListItem] { try await call(.pluginsList, RPCParams.Empty()) }

    func pluginsSaveDeclarative(_ config: DeclarativePluginConfig) async throws {
        let _: IPCAck = try await call(.pluginsSaveDeclarative, RPCParams.SaveDeclarative(config: config))
    }

    func pluginsDeleteDeclarative(pluginId: String) async throws {
        let _: IPCAck = try await call(.pluginsDeleteDeclarative, RPCParams.Plugin(pluginId: pluginId))
    }

    func pluginsSetEnabled(_ params: RPCParams.SetEnabled) async throws {
        let _: IPCAck = try await call(.pluginsSetEnabled, params)
    }

    func pluginsRunNow(_ params: RPCParams.RunNow) async throws -> PluginRunStart { try await call(.pluginsRunNow, params) }

    func pluginsRuns(_ params: RPCParams.PluginRuns) async throws -> IPCPage<PluginRun> { try await call(.pluginsRuns, params) }

    func memoryGet(_ target: MemoryTarget) async throws -> MemoryContent { try await call(.memoryGet, RPCParams.Memory(target: target)) }

    func memorySave(_ target: MemoryTarget, content: MemoryContent) async throws -> MemoryRevision {
        try await call(.memorySave, RPCParams.SaveMemory(target: target, content: content))
    }

    func memorySetEntryLock(_ target: MemoryTarget, entryId: String, locked: Bool) async throws -> MemoryRevision {
        try await call(.memorySetEntryLock, RPCParams.EntryLock(target: target, entryId: entryId, locked: locked))
    }

    func memorySetEntryVisibility(_ target: MemoryTarget, entryId: String, visibility: MemoryVisibility) async throws -> MemoryRevision {
        try await call(.memorySetEntryVisibility, RPCParams.EntryVisibility(target: target, entryId: entryId, visibility: visibility))
    }

    func memoryConsolidateNow(conversationId: String, backfill: BackfillRequest? = nil) async throws -> MemoryRevision? {
        try await call(.memoryConsolidateNow, RPCParams.Consolidate(conversationId: conversationId, backfill: backfill))
    }

    func memoryRevisions(_ params: RPCParams.Revisions) async throws -> IPCPage<MemoryRevision> {
        try await call(.memoryRevisions, params)
    }

    func memoryRollback(_ target: MemoryTarget, revId: String) async throws -> MemoryRevision {
        try await call(.memoryRollback, RPCParams.Rollback(target: target, revId: revId))
    }

    func personaProposals(_ params: RPCParams.Page = .init()) async throws -> IPCPage<PersonaProposal> {
        try await call(.personaProposals, params)
    }

    func personaDecide(_ decision: PersonaDecision) async throws -> PersonaProposal { try await call(.personaDecide, decision) }

    func feedList(_ params: RPCParams.FeedList = .init()) async throws -> IPCPage<FeedItem> { try await call(.feedList, params) }

    func feedMarkRead(ids: [String]) async throws {
        let _: IPCAck = try await call(.feedMarkRead, RPCParams.MarkRead(ids: ids))
    }
}
