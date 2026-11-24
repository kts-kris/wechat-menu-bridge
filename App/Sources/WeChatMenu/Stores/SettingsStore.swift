import Darwin
import Foundation

// 与 Engine/src/storage/fs-safe.ts 相同的私有文件约束。
enum PrivateFile {
    static func validateDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o700 else { throw BridgeFault("storage-unavailable") }
    }

    private static func validFile(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_nlink == 1 && info.st_uid == getuid()
            && info.st_mode & 0o7777 == 0o600
    }

    static func exists(_ path: String) throws -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw BridgeFault("storage-unavailable")
        }
        guard validFile(info) else { throw BridgeFault("storage-unavailable") }
        return true
    }

    static func read(_ path: String, maxBytes: Int) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw BridgeFault("storage-unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, validFile(info), info.st_size <= off_t(maxBytes) else {
            throw BridgeFault("storage-unavailable")
        }
        // 多读一个字节，检测检查文件长度后发生的追加。
        let size = Int(info.st_size)
        var data = Data(count: size + 1)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + offset, $0.count - offset, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw BridgeFault("storage-unavailable") }
            if count == 0 { break }
            offset += count
        }
        guard offset == size else { throw BridgeFault("storage-unavailable") }
        return data.prefix(size)
    }

    static func atomicWrite(_ path: String, _ data: Data) throws {
        let target = URL(fileURLWithPath: path)
        let directory = target.deletingLastPathComponent().path
        try validateDirectory(directory)
        _ = try exists(path)
        let temporary = (directory as NSString).appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw BridgeFault("storage-unavailable") }
        var renamed = false
        defer { if !renamed { unlink(temporary) } }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard fchmod(fd, 0o600) == 0 else { throw BridgeFault("storage-unavailable") }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch { throw BridgeFault("storage-unavailable") }
        guard rename(temporary, path) == 0 else { throw BridgeFault("storage-unavailable") }
        renamed = true
        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw BridgeFault("storage-unavailable") }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw BridgeFault("storage-unavailable") }
    }
}

// 对齐 settings.ts 的 legacySettingsSchema：非严格，丢弃已废弃字段，缺失字段取默认值。
private struct LegacySettings: Decodable {
    struct Contact: Decodable { let id: String; let label: String }
    let mcp: String
    let account: String
    let accountLabel: String
    let contact: Contact?
    let mode: ModelMode
    let modelURL: String
    let modelName: String
    let stylePath: String?
    let memoryPath: String?

    private enum CodingKeys: String, CodingKey { case mcp, account, accountLabel, contact, mode, modelURL, modelName, stylePath, memoryPath }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mcp = try c.defaulted(.mcp, "")
        account = try c.defaulted(.account, "")
        accountLabel = try c.defaulted(.accountLabel, "")
        contact = try c.decodeIfPresent(Contact.self, forKey: .contact)
        mode = try c.defaulted(.mode, .local)
        modelURL = try c.defaulted(.modelURL, "").trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = try c.defaulted(.modelName, "").trimmingCharacters(in: .whitespacesAndNewlines)
        stylePath = try c.contains(.stylePath) ? c.decode(String.self, forKey: .stylePath) : nil
        memoryPath = try c.contains(.memoryPath) ? c.decode(String.self, forKey: .memoryPath) : nil
    }

    var migrated: SettingsV2 {
        var value = SettingsV2()
        value.xiaohe = .init(mcpUrl: mcp, accountId: account, accountLabel: accountLabel)
        if !modelURL.isEmpty, !modelName.isEmpty {
            let preset = ModelPreset(id: "preset-legacy-default", name: modelName, mode: mode, kind: .chat, url: modelURL, modelName: modelName)
            value.models = [preset]
            value.defaultModels.replyPresetId = preset.id
        }
        if let contact {
            // 绝不继承自动回复开启状态。
            value.conversations[contact.id] = ConversationPolicy(conversationId: contact.id, label: contact.label, type: .direct,
                                                                  riskProfile: RiskProfile(level: nil))
        }
        value.memory = .init(legacyStylePath: stylePath, legacyMemoryPath: memoryPath)
        return value
    }
}

struct SettingsV2Disk: Sendable {
    static let maxBytes = 256 * 1024
    let directory: URL

    static var standard: Self { Self(directory: SettingsDisk.standard.directory) }

    var settingsPath: String { directory.appendingPathComponent("settings.json").path }
    var backupPath: String { directory.appendingPathComponent("settings.v1.bak.json").path }

    private func prepare() throws {
        try SettingsDisk(directory: directory).prepare()
        try PrivateFile.validateDirectory(directory.path)
    }

    // 启动入口：先保全旧文件的原始字节，再原子写回新结构。
    func load() throws -> SettingsV2 {
        try prepare()
        guard try PrivateFile.exists(settingsPath) else { return SettingsV2() }
        let original = try PrivateFile.read(settingsPath, maxBytes: Self.maxBytes)
        guard String(data: original, encoding: .utf8) != nil,
              let raw = try? JSONSerialization.jsonObject(with: original, options: .fragmentsAllowed) else {
            throw BridgeFault("config-unreadable")
        }
        guard Self.isLegacy(raw) else {
            var settings: SettingsV2
            do { settings = try IPCv3.decodeStrict(SettingsV2.self, from: original) }
            catch { throw BridgeFault("invalid-configuration") }
            try settings.validate()
            for key in settings.conversations.keys where settings.conversations[key]?.replyMode == .auto {
                settings.conversations[key]?.replyMode = .off
            }
            return settings
        }
        let settings: SettingsV2
        do { settings = try JSONDecoder().decode(LegacySettings.self, from: original).migrated }
        catch { throw BridgeFault("invalid-configuration") }
        try settings.validate()
        let data = try Self.encoded(settings)
        if try PrivateFile.exists(backupPath) {
            guard try PrivateFile.read(backupPath, maxBytes: Self.maxBytes) == original else {
                throw BridgeFault("storage-unavailable")
            }
        } else {
            try PrivateFile.atomicWrite(backupPath, original)
        }
        try PrivateFile.atomicWrite(settingsPath, data)
        return settings
    }

    func save(_ settings: SettingsV2) throws {
        try settings.validate()
        try prepare()
        try PrivateFile.atomicWrite(settingsPath, try Self.encoded(settings))
    }

    private static func encoded(_ settings: SettingsV2) throws -> Data {
        var data = try IPCv3.encoder().encode(settings)
        data.append(10)
        guard data.count <= maxBytes else { throw BridgeFault("invalid-configuration") }
        return data
    }

    private static func isLegacy(_ raw: Any) -> Bool {
        guard let object = raw as? [String: Any], let version = object["schemaVersion"] else { return true }
        guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number == 1
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var saved = SettingsV2()
    @Published var draft = SettingsV2()
    @Published private(set) var saving = false
    @Published private(set) var loaded = false

    let disk: SettingsV2Disk
    private let runtime: BridgeRuntime
    private let vault: KeychainVault

    init(runtime: BridgeRuntime, disk: SettingsV2Disk = .standard, vault: KeychainVault = .standard) {
        self.runtime = runtime
        self.disk = disk
        self.vault = vault
    }

    var hasUnsavedChanges: Bool { draft != saved }

    func load() throws {
        guard !saving else { throw BridgeFault("busy") }
        if NativeQA.active && NativeQA.home == nil { throw BridgeFault("storage-unavailable") }
        // 读取失败时保持 loaded = false，避免之后用默认值覆盖用户文件。
        loaded = false
        let value = try disk.load()
        try Self.checkQA(value)
        saved = value
        draft = value
        loaded = true
    }

    func discardChanges() { draft = saved }

    // 先让引擎按真实 schema 校验，再落盘；落盘失败时把引擎恢复到旧配置。
    func save() async throws {
        guard loaded else { throw BridgeFault("config-unreadable") }
        guard !saving, !runtime.starting else { throw BridgeFault("busy") }
        let next = draft, previous = saved
        try next.validate()
        try Self.checkQA(next)
        let keys = try await loadApprovedCloudKeys(for: next, strict: true)
        saving = true
        defer { saving = false }
        let applied = runtime.ready
        if applied { try await runtime.client.settingsApply(next, cloudApiKeys: keys) }
        do { try disk.save(next) }
        catch {
            if applied { try? await runtime.client.settingsApply(previous) }
            throw error
        }
        saved = next
    }

    // 启动或重连后把已统一授权的云端点密钥从钥匙串读入引擎内存（不写磁盘）。
    func syncApprovedCloudKeys() async throws {
        guard loaded, runtime.ready, !saved.runtime.approvedCloudPresetIds.isEmpty else { return }
        let keys = try await loadApprovedCloudKeys(for: saved, strict: false)
        guard !keys.isEmpty else { return }
        try await runtime.client.settingsApply(saved, cloudApiKeys: keys)
    }

    private func loadApprovedCloudKeys(for value: SettingsV2, strict: Bool) async throws -> [String: String] {
        let approved = Set(value.runtime.approvedCloudPresetIds)
        let targets = value.models.filter { $0.mode == .cloud && approved.contains($0.id) }
        guard !targets.isEmpty else { return [:] }
        let storage = vault
        return try await Task.detached(priority: .userInitiated) {
            var keys: [String: String] = [:]
            for preset in targets {
                let entry = try KeychainEntry.model(endpoint: preset.url, kind: preset.kind)
                do {
                    keys[preset.id] = try storage.read(entry)
                } catch {
                    if strict { throw error }
                }
            }
            return keys
        }.value
    }

    // MARK: 多模型预设

    func upsertPreset(_ preset: ModelPreset) {
        if let index = draft.models.firstIndex(where: { $0.id == preset.id }) {
            let old = draft.models[index]
            draft.models[index] = preset
            // 修改云端地址或切回本机时，自动撤销该预设的统一云端授权。
            if old.url != preset.url || preset.mode != .cloud {
                draft.runtime.approvedCloudPresetIds.removeAll { $0 == preset.id }
            }
        } else {
            draft.models.append(preset)
        }
    }

    // 同时清除默认模型和会话上的引用，避免留下悬空预设。
    func removePreset(id: String) {
        draft.models.removeAll { $0.id == id }
        draft.runtime.approvedCloudPresetIds.removeAll { $0 == id }
        if draft.defaultModels.replyPresetId == id { draft.defaultModels.replyPresetId = nil }
        if draft.defaultModels.fallbackReplyPresetId == id { draft.defaultModels.fallbackReplyPresetId = nil }
        if draft.defaultModels.pluginPresetId == id { draft.defaultModels.pluginPresetId = nil }
        if draft.defaultModels.memoryPresetId == id { draft.defaultModels.memoryPresetId = nil }
        if draft.defaultModels.visionPresetId == id { draft.defaultModels.visionPresetId = nil }
        if draft.defaultModels.sttPresetId == id { draft.defaultModels.sttPresetId = nil }
        for key in draft.conversations.keys where draft.conversations[key]?.replyPresetId == id {
            draft.conversations[key]?.replyPresetId = nil
        }
    }

    // MARK: 试拟

    func preview(presetId: String, text: String, cloudApproved: Bool = false) async throws -> ModelPreviewResult {
        guard let preset = draft.preset(presetId), preset.kind == .chat else { throw BridgeFault("invalid-configuration") }
        // 先判同意：未确认的云端请求不读钥匙串，也不进入后台。
        guard preset.mode != .cloud || cloudApproved else { throw BridgeFault("cloud-not-approved") }
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...400).contains(sample.utf16.count) else { throw BridgeFault("invalid-configuration") }
        guard runtime.ready else { throw BridgeFault("engine-not-ready") }
        let check = Self.configuration(draft, preset: preset)
        guard check.modelComplete else { throw BridgeFault("invalid-endpoint") }
        try NativeQA.check(check)
        var key: String?
        if preset.mode == .cloud {
            let revision = runtime.pauseRevision, storage = vault
            let entry = try KeychainEntry.model(endpoint: preset.url, kind: preset.kind)
            key = try await Task.detached(priority: .userInitiated) { try storage.read(entry) }.value
            // 读钥匙串可能等待系统授权；期间暂停或休眠即作废这次确认。
            guard revision == runtime.pauseRevision else { throw BridgeFault("stopped") }
            guard runtime.ready else { throw BridgeFault("engine-not-ready") }
        }
        let model = PreviewModel(mode: preset.mode, url: preset.url, name: preset.modelName, stylePath: check.stylePath,
                                 memoryPath: check.memoryPath, cloudApproved: preset.mode == .cloud, apiKey: key,
                                 reasoningEffort: preset.reasoningEffort)
        return try await runtime.client.modelPreview(model: model, text: sample)
    }

    // MARK: 全链路体检

    func runHealthCheck(presetId: String? = nil, conversationId: String? = nil) async throws -> HealthCheckResult {
        try await runtime.client.systemHealthCheck(presetId: presetId, conversationId: conversationId)
    }

    // NativeQA 的端点锁定以 v1 Configuration 为入参，这里逐预设复用同一道闸。
    private static func checkQA(_ value: SettingsV2) throws {
        guard NativeQA.active else { return }
        if value.models.isEmpty { try NativeQA.check(configuration(value, preset: nil)) }
        for preset in value.models { try NativeQA.check(configuration(value, preset: preset)) }
    }

    private static func configuration(_ value: SettingsV2, preset: ModelPreset?) -> Configuration {
        var result = Configuration()
        result.mcp = value.xiaohe.mcpUrl
        result.stylePath = value.memory.legacyStylePath ?? ""
        result.memoryPath = value.memory.legacyMemoryPath ?? ""
        if let preset {
            result.mode = preset.mode
            result.modelURL = preset.url
            result.modelName = preset.modelName
        }
        return result
    }
}
