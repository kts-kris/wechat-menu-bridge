import Foundation
import Security

enum KeychainNamespace: String, CaseIterable, Sendable {
    case model = "local.wechatmenubridge.model"
    case mcp = "local.wechatmenubridge.mcp"
    case webhook = "local.wechatmenubridge.webhook"
    case github = "local.wechatmenubridge.github"
}

// 只能经由工厂方法生成规范账户名，避免同一凭据落到不同索引。
struct KeychainEntry: Equatable, Sendable {
    let namespace: KeychainNamespace
    let account: String

    init(namespace: KeychainNamespace, account: String) {
        self.namespace = namespace
        self.account = account
    }

    static func model(endpoint: String, kind: ModelKind = .chat) throws -> Self {
        Self(namespace: .model, account: try ModelEndpoint.keychainAccount(endpoint, kind: kind))
    }

    static func mcp(url: String) throws -> Self {
        guard Configuration.validURL(url, kind: "mcp") else { throw BridgeFault("invalid-endpoint") }
        return Self(namespace: .mcp, account: url)
    }

    // ID 含冒号时账户名会产生歧义，可能读到其他插件的密钥，因此直接拒绝。
    static func webhook(pluginId: String, sinkId: String) throws -> Self {
        guard SettingsV2.identifier(pluginId), SettingsV2.identifier(sinkId),
              !pluginId.contains(":"), !sinkId.contains(":") else { throw BridgeFault("invalid-configuration") }
        return Self(namespace: .webhook, account: "plugin:\(pluginId):sink:\(sinkId)")
    }

    static func github(host: String = "github.com") -> Self {
        Self(namespace: .github, account: host)
    }
}

struct KeychainVault: Sendable {
    private static let fileLock = NSLock()
    var scope: (@Sendable (Bool) throws -> [String: Any])? = nil
    var fileDirectory: URL? = nil

    // 正式自用版默认使用 0600 私有凭据文件（与 settings.json 分离），避免 ad-hoc 重签名每次启动反复弹出 macOS 钥匙串密码框；
    // NativeQA 隔离测试仍沿用 nativeqa.keychain-db。
    static var standard: Self {
        if NativeQA.active { return Self(scope: ModelKeychain.standard.scope, fileDirectory: nil) }
        return Self(scope: ModelKeychain.standard.scope, fileDirectory: SettingsV2Disk.standard.directory)
    }

    private func query(_ entry: KeychainEntry, inserting: Bool = false) throws -> [String: Any] {
        let base = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: entry.namespace.rawValue,
                    kSecAttrAccount as String: entry.account] as [String: Any]
        return base.merging(try scope?(inserting) ?? [:]) { original, _ in original }
    }

    private static func validSecret(_ data: Data, in namespace: KeychainNamespace) -> Bool {
        // Webhook 鉴权头可含空格（如 "Bearer x"）；模型与 MCP 令牌沿用旧版字符集。
        let lowest: UInt8 = namespace == .webhook ? 32 : 33
        return (1...4096).contains(data.count) && data.allSatisfy { (lowest...126).contains($0) }
    }

    private func fileKey(_ entry: KeychainEntry) -> String { "\(entry.namespace.rawValue)\u{1F}\(entry.account)" }

    private func secretsPath(_ directory: URL) -> String { directory.appendingPathComponent("secrets.json").path }

    private func loadFileMap(_ directory: URL) throws -> [String: String] {
        try SettingsDisk(directory: directory).prepare()
        let path = secretsPath(directory)
        guard try PrivateFile.exists(path) else { return [:] }
        let data = try PrivateFile.read(path, maxBytes: 256 * 1024)
        guard let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw BridgeFault("keychain-unavailable")
        }
        return map
    }

    private func saveFileMap(_ map: [String: String], in directory: URL) throws {
        try SettingsDisk(directory: directory).prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(map)
        data.append(10)
        try PrivateFile.atomicWrite(secretsPath(directory), data)
    }

    func save(_ secret: String, for entry: KeychainEntry) throws {
        let data = Data(secret.utf8)
        guard Self.validSecret(data, in: entry.namespace) else { throw BridgeFault("invalid-key") }
        if let directory = fileDirectory {
            try Self.fileLock.withLock {
                var map = try loadFileMap(directory)
                map[fileKey(entry)] = secret
                try saveFileMap(map, in: directory)
            }
            return
        }
        var item = try query(entry, inserting: true)
        item[kSecValueData as String] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        let status = added == errSecDuplicateItem
            ? SecItemUpdate(try query(entry) as CFDictionary, [kSecValueData as String: data] as CFDictionary) : added
        guard status == errSecSuccess else { throw BridgeFault("keychain-unavailable") }
    }

    func read(_ entry: KeychainEntry) throws -> String {
        if let directory = fileDirectory {
            if let cached = try Self.fileLock.withLock({ try loadFileMap(directory)[fileKey(entry)] }) {
                return cached
            }
            // GitHub Token 为新增凭据命名空间，从未写入旧版 macOS 钥匙串，直接返回缺失以避免无谓查询钥匙串。
            if entry.namespace == .github { throw BridgeFault("missing-key") }
            // 首次从旧钥匙串平滑迁入本地 0600 凭据文件，后续启动与升级均不再弹窗。
            let legacy = try readKeychain(entry)
            _ = try? Self.fileLock.withLock {
                var map = try loadFileMap(directory)
                map[fileKey(entry)] = legacy
                try saveFileMap(map, in: directory)
            }
            return legacy
        }
        return try readKeychain(entry)
    }

    private func readKeychain(_ entry: KeychainEntry) throws -> String {
        var request = try query(entry)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { throw BridgeFault("missing-key") }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw BridgeFault("keychain-unavailable")
        }
        return secret
    }

    func remove(_ entry: KeychainEntry) throws {
        if let directory = fileDirectory {
            try Self.fileLock.withLock {
                var map = try loadFileMap(directory)
                if map.removeValue(forKey: fileKey(entry)) != nil {
                    try saveFileMap(map, in: directory)
                }
            }
            // 顺带清理可能残留的旧钥匙串条目，避免再次读回。
            if let q = try? query(entry) { _ = SecItemDelete(q as CFDictionary) }
            return
        }
        let status = SecItemDelete(try query(entry) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BridgeFault("keychain-unavailable") }
    }
}
