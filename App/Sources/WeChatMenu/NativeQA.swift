import Darwin
import Foundation

// Set only on the re-signed, unpacked test copy. The production bundle cannot
// select a different store or credential source via a launch environment flag.
enum NativeQA {
    private static let prefix = "local.wechatmenubridge.nativeqa."
    static let active = Bundle.main.bundleIdentifier?.hasPrefix(prefix) == true
    private static let fixtureMCP = ProcessInfo.processInfo.environment["WMB_QA_MCP"]
    private static let fixtureModel = ProcessInfo.processInfo.environment["WMB_QA_MODEL"]
    static let home: URL? = {
        guard active, let id = Bundle.main.bundleIdentifier, UUID(uuidString: String(id.dropFirst(prefix.count))) != nil else { return nil }
        let stage = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        let name = ProcessInfo.processInfo.environment["WMB_QA_HOME"] ?? "home"
        guard stage.lastPathComponent.hasPrefix(".uitest."),
              name.range(of: #"^home(?:-[a-z0-9-]+)?$"#, options: .regularExpression) != nil else { return nil }
        let path = stage.appendingPathComponent(name, isDirectory: true)
        guard path.resolvingSymlinksInPath().path == path.path else { return nil }
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o077 == 0 else { return nil }
        return path
    }()

    static func checkMCP(_ url: String) throws {
        guard !active || (url == fixtureMCP && Configuration.validURL(url, kind: "mcp")) else {
            throw BridgeFault("invalid-endpoint")
        }
    }

    static func check(_ value: Configuration) throws {
        guard active else { return }
        if !value.mcp.isEmpty { try checkMCP(value.mcp) }
        guard value.stylePath.isEmpty, value.memoryPath.isEmpty else { throw BridgeFault("profile-unreadable") }
        if let model = value.modelEndpoint, value.modelComplete {
            if value.mode == .cloud {
                // Only the non-routable display destination used by the consent test.
                guard model == "https://wechat-bridge.invalid/v1/chat/completions" else { throw BridgeFault("invalid-endpoint") }
            } else {
                guard model == fixtureModel else { throw BridgeFault("invalid-endpoint") }
            }
        }
    }
}
