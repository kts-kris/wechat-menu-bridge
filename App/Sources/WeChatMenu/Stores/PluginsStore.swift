import Foundation

@MainActor
final class PluginsStore: ObservableObject, BridgeEventConsumer {
    @Published private(set) var plugins: [PluginListItem] = []
    @Published private(set) var states: [String: PluginRuntimeState] = [:]
    @Published private(set) var runs: [String: [PluginRun]] = [:]
    @Published private(set) var runCursors: [String: String] = [:]

    private let runtime: BridgeRuntime
    private let vault: KeychainVault

    init(runtime: BridgeRuntime, vault: KeychainVault = .standard) {
        self.runtime = runtime
        self.vault = vault
        runtime.register(self)
    }

    func apply(_ event: PushEvent) {
        switch event {
        case .hello(let payload):
            states = payload.status.plugins
            plugins = plugins.compactMap { item in
                guard let state = states[item.pluginId] else { return nil }
                var next = item
                next.state = state
                return next
            }
        case .pluginUpdated(let update):
            states[update.pluginId] = update.state
            if let index = plugins.firstIndex(where: { $0.pluginId == update.pluginId }) {
                plugins[index].state = update.state
            }
        default: break
        }
    }

    func bridgeDisconnected() {
        plugins = []
        states = [:]
        runs = [:]
        runCursors = [:]
    }

    func refresh() async throws {
        let items = try await runtime.client.pluginsList()
        plugins = items
        states = Dictionary(items.map { ($0.pluginId, $0.state) }, uniquingKeysWith: { _, last in last })
    }

    func saveDeclarative(_ config: DeclarativePluginConfig) async throws {
        try await runtime.client.pluginsSaveDeclarative(config)
        // 配置已保存；刷新失败不能误报为保存失败。
        try? await refresh()
    }

    // 配置删除成功后再清理密钥；清理失败不影响删除结果，但要报告给调用方。
    func deleteDeclarative(pluginId: String) async throws {
        var sinkIds: [String] = []
        if case .declarative(_, let config, _)? = plugins.first(where: { $0.pluginId == pluginId }) {
            sinkIds = config.sinks.compactMap { if case .webhook(let id, _, _, _) = $0 { return id } else { return nil } }
        }
        try await runtime.client.pluginsDeleteDeclarative(pluginId: pluginId)
        plugins.removeAll { $0.pluginId == pluginId }
        states[pluginId] = nil
        runs[pluginId] = nil
        runCursors[pluginId] = nil
        for sinkId in sinkIds { try removeWebhookSecret(pluginId: pluginId, sinkId: sinkId) }
    }

    func setEnabled(pluginId: String, enabled: Bool) async throws {
        // 代码插件的首次启用必须走 approve，不能绕过权限审批。
        if enabled, case .module(_, _, let state)? = plugins.first(where: { $0.pluginId == pluginId }),
           state.manifestHash == nil || state.approvedPermissions.isEmpty {
            throw BridgeFault("plugin-permission")
        }
        try await runtime.client.pluginsSetEnabled(.init(pluginId: pluginId, enabled: enabled))
    }

    // 审批绑定用户看到的清单哈希。清单在审批期间变化时拒绝，不把授权带到新代码上。
    func approve(pluginId: String, permissions: [PluginPermission], reviewedManifestHash: String) async throws {
        guard case .module(_, let manifest, let state)? = plugins.first(where: { $0.pluginId == pluginId }),
              state.manifestHash == reviewedManifestHash,
              Set(permissions).isSubset(of: manifest.permissions) else { throw BridgeFault("plugin-permission") }
        try await runtime.client.pluginsSetEnabled(.init(pluginId: pluginId, enabled: true, approvedPermissions: permissions,
                                                         manifestHash: reviewedManifestHash))
    }

    @discardableResult
    func runNow(pluginId: String, conversationId: String? = nil, range: TimeRange? = nil) async throws -> String {
        if let range, range.startTime > range.endTime { throw BridgeFault("invalid-configuration") }
        return try await runtime.client.pluginsRunNow(.init(pluginId: pluginId, conversationId: conversationId, range: range)).runId
    }

    func loadRuns(pluginId: String, more: Bool = false, limit: Int = 50) async throws {
        let cursor = more ? runCursors[pluginId] : nil
        if more && cursor == nil { return }
        let page = try await runtime.client.pluginsRuns(.init(pluginId: pluginId, cursor: cursor, limit: limit))
        var merged = more ? runs[pluginId] ?? [] : []
        let known = Set(merged.map(\.runId))
        merged.append(contentsOf: page.items.filter { !known.contains($0.runId) })
        runs[pluginId] = merged
        runCursors[pluginId] = page.nextCursor
    }

    // MARK: Webhook 密钥

    func saveWebhookSecret(_ secret: String, pluginId: String, sinkId: String) throws {
        try vault.save(secret, for: try .webhook(pluginId: pluginId, sinkId: sinkId))
    }

    func removeWebhookSecret(pluginId: String, sinkId: String) throws {
        try vault.remove(try .webhook(pluginId: pluginId, sinkId: sinkId))
    }
}
