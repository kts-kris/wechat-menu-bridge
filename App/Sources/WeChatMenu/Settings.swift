import Darwin
import Foundation
import Security

enum ModelMode: String, Codable, CaseIterable { case local, cloud }
struct AccountOption: Decodable, Identifiable { let id: String; let label: String; let canRead: Bool; let canSend: Bool }
struct ContactOption: Codable, Identifiable, Equatable { let id: String; let label: String }

struct Configuration: Codable, Equatable {
    var mcp = ""
    var account = ""
    var accountLabel = ""
    var contact: ContactOption? = nil
    var mode: ModelMode = .local
    var modelURL = "http://127.0.0.1:11434/v1/chat/completions"
    var modelName = ""
    var stylePath = ""
    var memoryPath = ""

    var target: [String: Any]? {
        guard Self.validURL(mcp, kind: "mcp"), !account.isEmpty, let contact,
              contact.id.range(of: "^wxid_[a-zA-Z0-9_]{1,128}$", options: .regularExpression) != nil else { return nil }
        return ["mcp": mcp, "account": account, "contact": contact.id]
    }

    var modelEndpoint: String? { Self.modelEndpoint(modelURL, mode: mode) }

    var addressesValid: Bool {
        (mcp.isEmpty || Self.validURL(mcp, kind: "mcp")) && (modelURL.isEmpty || modelEndpoint != nil)
    }

    var modelComplete: Bool {
        modelEndpoint != nil && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func model(approved: Bool, key: String? = nil) throws -> [String: Any] {
        guard let modelEndpoint else { throw BridgeFault("invalid-endpoint") }
        var value: [String: Any] = ["mode": mode.rawValue, "url": modelEndpoint, "name": modelName,
          "stylePath": stylePath, "memoryPath": memoryPath, "cloudApproved": approved]
        if let key { value["apiKey"] = key }
        return value
    }

    private static func addressParts(_ value: String) -> URLComponents? {
        guard value.utf8.count <= 512, let u = URLComponents(string: value), u.string == value,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil, !u.percentEncodedPath.contains("%") else { return nil }
        return u
    }

    static func validURL(_ value: String, kind: String) -> Bool {
        if let mode = ModelMode(rawValue: kind) { return modelEndpoint(value, mode: mode) != nil }
        guard kind == "mcp", let u = addressParts(value), u.path == "/mcp" else { return false }
        return u.scheme == "http" && u.host == "127.0.0.1" && (u.port.map { (1...65535).contains($0) && $0 != 80 } ?? false)
    }

    // Keep the exact authority and path prefix. Older keys already use the completed URL as their index.
    static func modelEndpoint(_ input: String, mode: ModelMode) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = addressParts(value), let host = u.host, !host.isEmpty else { return nil }
        let scheme = mode == .cloud ? "https" : "http"
        let defaultPort = mode == .cloud ? 443 : 80
        guard value.hasPrefix("\(scheme)://"), u.scheme == scheme else { return nil }
        let authority = value.dropFirst(scheme.count + 3).prefix { $0 != "/" }
        if let port = u.port {
            guard (1...65535).contains(port), port != defaultPort, authority.hasSuffix(":\(port)") else { return nil }
        } else if authority.contains(":") { return nil }
        if mode == .cloud {
            guard host == host.lowercased(), host != "localhost", host != "127.0.0.1", !host.hasPrefix("["),
                  !authority.contains("%") else { return nil }
        } else {
            guard host == "127.0.0.1", u.port != nil else { return nil }
        }
        let path = u.percentEncodedPath
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), !path.contains("\\") else { return nil }
        let endingInSlash = path.hasSuffix("/")
        let base = endingInSlash ? String(value.dropLast()) : value
        let route = endingInSlash ? String(path.dropLast()) : path
        guard route.hasSuffix("/v1") || route.hasSuffix("/chat/completions") else { return nil }
        let full = route.hasSuffix("/v1") ? base + "/chat/completions" : base
        return full.utf8.count <= 512 ? full : nil
    }
}

struct SettingsDisk {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("settings.json") }
    static var standard: SettingsDisk {
        let home = NativeQA.home ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return SettingsDisk(directory: home
            .appendingPathComponent("Library/Application Support/WeChatMenuBridge", isDirectory: true))
    }

    func prepare() throws {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw BridgeFault("storage-unavailable") }
        try Self.check(directory, isDirectory: true)
    }

    func load() throws -> Configuration {
        try prepare()
        if !(try Self.check(file, missing: true)) { return Configuration() }
        do {
            let data = try Data(contentsOf: file)
            guard data.count < 32_768 else { throw BridgeFault("config-unreadable") }
            // Codable ignores the discontinued v0.1 daily limit. No sending state is restored from disk.
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch { throw BridgeFault("config-unreadable") }
    }

    func save(_ value: Configuration) throws {
        try prepare()
        try Self.check(file, missing: true)
        let data = try JSONEncoder().encode(value)
        guard data.count < 32_768 else { throw BridgeFault("invalid-configuration") }
        let temp = directory.appendingPathComponent(".settings-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw BridgeFault("storage-unavailable") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, file.path) == 0 else { throw BridgeFault("storage-unavailable") }
        } catch { throw BridgeFault("storage-unavailable") }
    }

    @discardableResult
    private static func check(_ path: URL, isDirectory: Bool = false, missing: Bool = false) throws -> Bool {
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            if missing && errno == ENOENT { return false }
            throw BridgeFault("storage-unavailable")
        }
        let expected = mode_t(isDirectory ? S_IFDIR : S_IFREG)
        guard info.st_mode & mode_t(S_IFMT) == expected, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              isDirectory || (info.st_nlink == 1 && info.st_size < 32_768) else { throw BridgeFault("storage-unavailable") }
        return true
    }
}

struct ModelKeychain: Sendable {
    var service = "local.wechatmenubridge.model"
    var scope: (@Sendable (Bool) throws -> [String: Any])? = nil

    static var standard: Self {
        if !NativeQA.active { return Self() }
        // No fallback to the logged-in user's keychain for a QA identity.
        return Self(scope: { inserting in
            guard let home = NativeQA.home else { throw BridgeFault("keychain-unavailable") }
            let path = home.appendingPathComponent("nativeqa.keychain-db").path
            var keychain: SecKeychain?
            guard FileManager.default.fileExists(atPath: path), SecKeychainOpen(path, &keychain) == errSecSuccess,
                  let keychain else { throw BridgeFault("keychain-unavailable") }
            return inserting ? [kSecUseKeychain as String: keychain] : [kSecMatchSearchList as String: [keychain]]
        })
    }

    private func scopedQuery(_ url: String, inserting: Bool = false) throws -> [String: Any] {
        guard let endpoint = Configuration.modelEndpoint(url, mode: .cloud) else { throw BridgeFault("invalid-endpoint") }
        let query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint] as [String: Any]
        return query.merging(try scope?(inserting) ?? [:]) { original, _ in original }
    }

    func save(_ key: String, for url: String) throws {
        let data = Data(key.utf8)
        guard (1...4096).contains(data.count), data.allSatisfy({ (33...126).contains($0) }) else {
            throw BridgeFault("invalid-key")
        }
        var item = try scopedQuery(url, inserting: true)
        item[kSecValueData as String] = data
        let result = SecItemAdd(item as CFDictionary, nil)
        let status = result == errSecDuplicateItem
            ? SecItemUpdate(try scopedQuery(url) as CFDictionary, [kSecValueData as String: data] as CFDictionary) : result
        guard status == errSecSuccess else { throw BridgeFault("keychain-unavailable") }
    }

    func read(_ url: String) throws -> String {
        var q = try scopedQuery(url)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw BridgeFault("missing-key") }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw BridgeFault("keychain-unavailable")
        }
        return key
    }

    func remove(_ url: String) throws {
        let status = SecItemDelete(try scopedQuery(url) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BridgeFault("keychain-unavailable") }
    }
}

func nextMidnight(_ now: Date = .now) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    let start = calendar.startOfDay(for: now)
    return calendar.date(byAdding: .day, value: 1, to: start) ?? now
}

func epoch(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
