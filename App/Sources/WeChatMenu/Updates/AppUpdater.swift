import AppKit
import CryptoKit
import Darwin
import Foundation

// MARK: - 错误

enum UpdateError: LocalizedError, Equatable {
    case insecureURL, invalidFeed, http(Int), tooLarge, sizeMismatch
    case missingVerification, invalidDigest, digestMismatch
    case invalidPublicKey, missingSignature, invalidSignature
    case extractFailed, invalidBundle, versionMismatch, codesignFailed
    case notInstallable(String)

    var errorDescription: String? {
        switch self {
        case .insecureURL: return "更新源和下载地址必须是 HTTPS。"
        case .invalidFeed: return "更新源内容无法解析，请确认是 appcast.xml 或 appcast.json。"
        case .http(let code): return "更新服务器返回 HTTP \(code)。"
        case .tooLarge: return "更新内容超过允许的大小。"
        case .sizeMismatch: return "下载大小与更新源声明不一致，已丢弃。"
        case .missingVerification: return "这个版本没有 SHA-256，也未配置 Ed25519 公钥，无法校验，已拒绝安装。"
        case .invalidDigest: return "更新源里的 SHA-256 格式不正确。"
        case .digestMismatch: return "安装包 SHA-256 不匹配，已丢弃。"
        case .invalidPublicKey: return "Ed25519 公钥不是有效的 Base64 公钥。"
        case .missingSignature: return "已配置公钥，但这个版本没有 Ed25519 签名，已拒绝安装。"
        case .invalidSignature: return "Ed25519 签名校验失败，已丢弃。"
        case .extractFailed: return "安装包解压失败。"
        case .invalidBundle: return "安装包不是有效的微信桥应用。"
        case .versionMismatch: return "安装包内的版本与更新源声明不一致，已丢弃。"
        case .codesignFailed: return "新版本代码签名校验失败，已丢弃。"
        case .notInstallable(let reason): return reason
        }
    }
}

// MARK: - 语义化版本

struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]
    let buildNumber: Int?

    // 接受 2.1、2.1.0、v2.1.0-beta.1；+ 后的构建元数据不参与比较。
    init?(_ text: String, build: String? = nil) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        if let plus = body.firstIndex(of: "+") { body = body[..<plus] }
        var tags: [String] = []
        if let dash = body.firstIndex(of: "-") {
            tags = body[body.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard tags.allSatisfy(Self.isValidTag) else { return nil }
            body = body[..<dash]
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap(Self.strictNumber)
        guard numbers.count == parts.count else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers.count == 3 ? numbers[2] : 0
        prerelease = tags
        buildNumber = build.flatMap { value in
            let digits = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.isDigits(digits) ? Int(digits) : nil
        }
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
        return buildNumber.map { "\(core) (\($0))" } ?? core
    }

    // 主次修订号相同且未声明构建号时，只比较语义版本部分。
    func matchesRelease(_ release: SemanticVersion) -> Bool {
        guard (major, minor, patch) == (release.major, release.minor, release.patch), prerelease == release.prerelease else { return false }
        return release.buildNumber == nil || release.buildNumber == buildNumber
    }

    static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        let order = comparePrerelease(a.prerelease, b.prerelease)
        if order != 0 { return order < 0 }
        // 没有构建号的排在最前，保持全序。
        return (a.buildNumber ?? -1) < (b.buildNumber ?? -1)
    }

    private static func comparePrerelease(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty || b.isEmpty { return a.isEmpty == b.isEmpty ? 0 : (a.isEmpty ? 1 : -1) }
        for (x, y) in zip(a, b) where x != y {
            switch (isDigits(x) ? Int(x) : nil, isDigits(y) ? Int(y) : nil) {
            case let (l?, r?): return l < r ? -1 : 1
            case (.some, nil): return -1
            case (nil, .some): return 1
            case (nil, nil): return x < y ? -1 : 1
            }
        }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    private static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func strictNumber(_ value: String) -> Int? {
        guard isDigits(value), value == "0" || !value.hasPrefix("0") else { return nil }
        return Int(value)
    }

    private static func isValidTag(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            return false
        }
        return !isDigits(value) || value == "0" || !value.hasPrefix("0")
    }
}

// MARK: - Appcast

enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable, beta

    var id: String { rawValue }
    var title: String { self == .stable ? "稳定版" : "测试版" }

    // 与 Sparkle 一致：未标记通道的条目对所有人可见，测试版用户同时接收稳定版。
    func accepts(_ channel: String?) -> Bool {
        guard let channel, channel != UpdateChannel.stable.rawValue else { return true }
        return self == .beta && channel == UpdateChannel.beta.rawValue
    }
}

struct ReleaseInfo: Equatable, Identifiable, Sendable {
    var id: String { "\(version)|\(downloadURL.absoluteString)" }
    var title: String
    var notes: String
    var publishedAt: Date?
    var version: SemanticVersion
    var downloadURL: URL
    var length: Int64?
    var edSignature: String?
    var sha256: String?
    var channel: String?
    var minimumSystemVersion: String?
}

// JSON 字段名与 Sparkle 对应：
// {"items":[{"title","description","pubDate","url","length","shortVersionString","version","edSignature","channel","sha256"}]}
enum AppcastParser {
    fileprivate struct Draft {
        var title = ""
        var notes = ""
        var pubDate: String?
        var url: String?
        var length: String?
        var shortVersion: String?
        var build: String?
        var signature: String?
        var channel: String?
        var sha256: String?
        var minimumSystem: String?

        func release() -> ReleaseInfo? {
            guard let url = url.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }), url.scheme != nil,
                  let version = shortVersion.flatMap({ SemanticVersion($0, build: build) }) ?? build.flatMap({ SemanticVersion($0) }) else {
                return nil
            }
            let size = length.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 > 0 ? $0 : nil }
            return ReleaseInfo(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                               notes: AppcastParser.plainText(notes), publishedAt: pubDate.flatMap(AppcastParser.date),
                               version: version, downloadURL: url, length: size,
                               edSignature: Self.clean(signature), sha256: Self.clean(sha256),
                               channel: Self.clean(channel)?.lowercased(), minimumSystemVersion: Self.clean(minimumSystem))
        }

        private static func clean(_ value: String?) -> String? {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
    }

    static func parse(_ data: Data) throws -> [ReleaseInfo] {
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        let first = bytes.first { ![9, 10, 13, 32].contains($0) }
        let drafts = first == UInt8(ascii: "{") || first == UInt8(ascii: "[") ? try parseJSON(Data(bytes)) : try parseXML(Data(bytes))
        let releases = drafts.compactMap { $0.release() }
        // 全部条目都无效说明格式不对，不能当成“已是最新”。
        guard drafts.isEmpty || !releases.isEmpty else { throw UpdateError.invalidFeed }
        return releases
    }

    static func newest(in releases: [ReleaseInfo], channel: UpdateChannel, current: SemanticVersion,
                       system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> ReleaseInfo? {
        releases.filter { release in
            channel.accepts(release.channel) && release.version > current && supports(release.minimumSystemVersion, system)
        }.max { $0.version < $1.version }
    }

    private static func supports(_ minimum: String?, _ system: OperatingSystemVersion) -> Bool {
        guard let minimum else { return true }
        // 写不规范的最低系统要求按不满足处理，不冒险安装。
        guard let required = SemanticVersion(minimum) else { return false }
        return (system.majorVersion, system.minorVersion, system.patchVersion) >= (required.major, required.minor, required.patch)
    }

    private static func parseXML(_ data: Data) throws -> [Draft] {
        let parser = XMLParser(data: data)
        let delegate = SparkleFeedDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.sawRSS else { throw UpdateError.invalidFeed }
        return delegate.drafts
    }

    private static func parseJSON(_ data: Data) throws -> [Draft] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw UpdateError.invalidFeed }
        let rows: [[String: Any]]
        if let list = root as? [[String: Any]] { rows = list }
        else if let object = root as? [String: Any],
                let list = (object["items"] ?? object["releases"]) as? [[String: Any]] { rows = list }
        else { throw UpdateError.invalidFeed }
        return rows.map { row in
            let enclosure = row["enclosure"] as? [String: Any] ?? [:]
            func text(_ key: String) -> String? {
                let value = row[key] ?? row["sparkle:\(key)"] ?? enclosure[key] ?? enclosure["sparkle:\(key)"]
                if let string = value as? String { return string }
                return (value as? NSNumber).map(\.stringValue)
            }
            return Draft(title: text("title") ?? "", notes: text("description") ?? "", pubDate: text("pubDate"),
                         url: text("url"), length: text("length"), shortVersion: text("shortVersionString"),
                         build: text("version"), signature: text("edSignature"), channel: text("channel"),
                         sha256: text("sha256"), minimumSystem: text("minimumSystemVersion"))
        }
    }

    fileprivate static func date(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }

    // 更新说明可能是 HTML，界面只展示纯文本，不渲染远端标记。
    static func plainText(_ html: String) -> String {
        var text = html
        let rules = [("<br\\s*/?>|</p>|</li>|</h[1-6]>", "\n"), ("<li[^>]*>", "• "), ("<[^>]+>", "")]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class SparkleFeedDelegate: NSObject, XMLParserDelegate {
    private static let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    private(set) var drafts: [AppcastParser.Draft] = []
    private(set) var sawRSS = false
    private var prefix = "sparkle"
    private var stack: [String] = []
    private var current: AppcastParser.Draft?
    private var hasEnclosure = false
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if stack.isEmpty, name == "rss" {
            sawRSS = true
            if let key = attributes.first(where: { $0.key.hasPrefix("xmlns:") && $0.value == Self.namespace })?.key {
                prefix = String(key.dropFirst("xmlns:".count))
            }
        }
        // 只读 item 的直接子元素：sparkle:deltas 里的增量包 enclosure 不能当成完整安装包。
        if name == "item", stack.last == "channel" {
            current = AppcastParser.Draft()
            hasEnclosure = false
        } else if name == "enclosure", stack.last == "item", var draft = current, !hasEnclosure {
            hasEnclosure = true
            draft.url = attributes["url"]
            draft.length = attributes["length"]
            draft.shortVersion = attributes["\(prefix):shortVersionString"] ?? draft.shortVersion
            draft.build = attributes["\(prefix):version"] ?? draft.build
            draft.signature = attributes["\(prefix):edSignature"] ?? draft.signature
            draft.sha256 = attributes["\(prefix):sha256"] ?? attributes["sha256"] ?? draft.sha256
            current = draft
        }
        stack.append(name)
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { buffer += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
        if name == "item", stack.last == "channel" {
            if let current { drafts.append(current) }
            current = nil
        } else if stack.last == "item", current != nil {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title": current?.title = text
            case "description": current?.notes = text
            case "pubDate": current?.pubDate = text
            case "sha256", "\(prefix):sha256": current?.sha256 = text
            case "\(prefix):shortVersionString": current?.shortVersion = text
            case "\(prefix):version": current?.build = text
            case "\(prefix):channel": current?.channel = text
            case "\(prefix):minimumSystemVersion": current?.minimumSystem = text
            default: break
            }
        }
        buffer = ""
    }
}

// MARK: - 校验

enum UpdateVerifier {
    static func requireSecure(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            throw UpdateError.insecureURL
        }
    }

    static func isValidPublicKey(_ text: String) -> Bool {
        (try? publicKey(text.trimmingCharacters(in: .whitespacesAndNewlines))) != nil
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // 配了公钥就必须验签；没有公钥时至少要有摘要，两者都没有一律拒绝。
    static func verify(archive: Data, sha256: String?, signature: String?, publicKey keyText: String?) throws {
        let keyValue = keyText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digest = sha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !keyValue.isEmpty || !digest.isEmpty else { throw UpdateError.missingVerification }
        if !digest.isEmpty {
            guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw UpdateError.invalidDigest
            }
            guard sha256Hex(archive) == digest else { throw UpdateError.digestMismatch }
        }
        guard !keyValue.isEmpty else { return }
        let key = try publicKey(keyValue)
        let encoded = signature?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !encoded.isEmpty else { throw UpdateError.missingSignature }
        guard let bytes = Data(base64Encoded: encoded), bytes.count == 64, key.isValidSignature(bytes, for: archive) else {
            throw UpdateError.invalidSignature
        }
    }

    private static func publicKey(_ text: String) throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: text), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw UpdateError.invalidPublicKey
        }
        return key
    }
}

// MARK: - 下载

// 更新源和安装包走同一条下载路径：限制大小、只接受 200、重定向也必须是 HTTPS。
private final class UpdateFileFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let limit: Int64
    private let expected: Int64?
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(destination: URL, limit: Int64, expected: Int64? = nil, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.destination = destination
        self.limit = limit
        self.expected = expected
        self.onProgress = onProgress
    }

    func run(_ url: URL, session: URLSession) async throws {
        try UpdateVerifier.requireSecure(url)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let task = session.downloadTask(with: request)
        task.delegate = self
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func record(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let target = request.url, (try? UpdateVerifier.requireSecure(target)) != nil {
            completionHandler(request)
        } else {
            record(UpdateError.insecureURL)
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit else {
            record(UpdateError.tooLarge)
            downloadTask.cancel()
            return
        }
        let total = expected ?? totalBytesExpectedToWrite
        if total > 0 { onProgress(min(1, Double(totalBytesWritten) / Double(total))) }
    }

    // 系统在此回调返回后就删除临时文件，必须同步移走。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdateError.http(status) }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= limit else { throw UpdateError.tooLarge }
            if let expected, expected != size { throw UpdateError.sizeMismatch }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            record(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiter, stored) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            let waiter = continuation
            continuation = nil
            return (waiter, failure)
        }
        if let problem = stored ?? error { waiter?.resume(throwing: problem) } else { waiter?.resume() }
    }
}

// MARK: - 解包

struct StagedBundle: Equatable, Sendable {
    let appURL: URL
    let executable: String
}

enum UpdateStager {
    static func stage(archive: URL, into directory: URL, release: ReleaseInfo, bundleIdentifier: String?) throws -> StagedBundle {
        let root = directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard runTool("/usr/bin/ditto", ["-x", "-k", archive.path, root.path]) == 0 else { throw UpdateError.extractFailed }
        try rejectEscapingLinks(in: root)

        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
        guard entries.count == 1, let app = entries.first, app.pathExtension == "app",
              let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { throw UpdateError.invalidBundle }

        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let short = info["CFBundleShortVersionString"] as? String,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != "..", executable != "." else {
            throw UpdateError.invalidBundle
        }
        if let bundleIdentifier, identifier != bundleIdentifier { throw UpdateError.invalidBundle }
        guard let version = SemanticVersion(short, build: info["CFBundleVersion"] as? String),
              version.matchesRelease(release.version) else { throw UpdateError.versionMismatch }

        let binary = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard let kind = try? binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              kind.isRegularFile == true, kind.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: binary.path) else { throw UpdateError.invalidBundle }
        guard runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { throw UpdateError.codesignFailed }
        return StagedBundle(appURL: app, executable: executable)
    }

    // 压缩包里的符号链接不能指向解压目录之外。
    private static func rejectEscapingLinks(in root: URL) throws {
        let base = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw UpdateError.extractFailed
        }
        for case let item as URL in walker {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
            guard !link.hasPrefix("/") else { throw UpdateError.invalidBundle }
            let parent = item.deletingLastPathComponent().resolvingSymlinksInPath()
            let target = URL(fileURLWithPath: link, relativeTo: parent).standardizedFileURL.path
            guard target == base || target.hasPrefix(base + "/") else { throw UpdateError.invalidBundle }
        }
    }

    private static func runTool(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : -1
    }
}

// MARK: - 退出后替换

struct UpdateInstallPlan: Equatable, Sendable {
    let processIdentifier: Int32
    let target: URL
    let staged: URL
    let workDirectory: URL
    let executable: String

    var arguments: [String] {
        [String(processIdentifier), target.path, staged.path, workDirectory.path, executable]
    }
}

enum UpdateInstallScript {
    // 路径只通过位置参数传入，不拼接进脚本。
    static func render(openCommand: String = "/usr/bin/open", probeSeconds: Int = 5) -> String {
        #"""
        #!/bin/bash
        set -u
        app_pid=$1 target=$2 staged=$3 work=$4 executable=$5
        opener='\#(openCommand)'
        exec >>"$work/install.log" 2>&1

        parent=$(/usr/bin/dirname "$target")
        name=$(/usr/bin/basename "$target" .app)
        incoming="$parent/.$name.update.$$.app"
        backup="$parent/.$name.backup.$$.app"
        engine="$target/Contents/MacOS/bridge-engine"
        binary="$target/Contents/MacOS/$executable"

        # 按可执行文件映像判断：ps 在无 UTF-8 locale 时会转义中文路径，不能用来比对。
        running() { /usr/sbin/lsof -a -d txt -t -- "$1" >/dev/null 2>&1; }
        reopen() { "$opener" -n "$target"; }
        abort() { echo "abort: $1"; /bin/rm -rf "$incoming"; reopen; exit 1; }

        # 旧进程没退出就什么都不改，此时不能再启动第二份。
        for _ in {1..300}; do kill -0 "$app_pid" 2>/dev/null || break; /bin/sleep 0.1; done
        if kill -0 "$app_pid" 2>/dev/null; then echo "abort: app still running"; exit 1; fi
        # 引擎收到 EOF 后会自行收尾，等它释放状态目录。
        for _ in {1..150}; do running "$engine" || break; /bin/sleep 0.1; done
        if running "$engine"; then abort "engine still running"; fi

        /usr/bin/ditto "$staged" "$incoming" || abort "copy failed"
        /usr/bin/codesign --verify --deep --strict "$incoming" || abort "codesign failed"
        /bin/mv "$target" "$backup" || abort "backup failed"
        if ! /bin/mv "$incoming" "$target"; then
            /bin/mv "$backup" "$target"
            abort "replace failed"
        fi

        # 新版本必须真的跑起来才删除备份，否则换回旧版本。
        if "$opener" -n "$target"; then
            /bin/sleep \#(probeSeconds)
            if running "$binary"; then
                /bin/rm -rf "$backup" "$work"
                exit 0
            fi
        fi
        echo "rollback: new version did not stay running"
        if /bin/mv "$target" "$incoming" && /bin/mv "$backup" "$target"; then
            /bin/rm -rf "$incoming"
            reopen
        fi
        exit 1
        """#
    }
}

private enum UpdateRelauncher {
    static func launch(_ plan: UpdateInstallPlan) throws {
        let script = plan.workDirectory.appendingPathComponent("install.sh")
        try Data(UpdateInstallScript.render().utf8).write(to: script, options: .atomic)
        guard chmod(script.path, 0o700) == 0 else { throw UpdateError.notInstallable("无法准备安装脚本。") }
        try spawnDetached("/bin/bash", [script.path] + plan.arguments)
        NSApplication.shared.terminate(nil)
    }

    // 新会话 + 关闭继承的描述符：脚本不能随 App 退出，也不能拿着引擎管道让引擎等不到 EOF。
    private static func spawnDetached(_ path: String, _ arguments: [String]) throws {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw UpdateError.notInstallable("无法启动安装程序。") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw UpdateError.notInstallable("无法启动安装程序。") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let home = "HOME=" + NSHomeDirectory()
        let envp: [UnsafeMutablePointer<CChar>?] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", home].map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0 else {
            throw UpdateError.notInstallable("无法启动安装程序。")
        }
    }
}

// MARK: - 更新器

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(ReleaseInfo)
    case downloading(progress: Double)
    case verifying
    case readyToInstall(ReleaseInfo, stagedAppURL: URL)
    case failed(String)
}

struct BuiltInUpdateSource: Sendable {
    let feedURL: URL
    let publicKey: String

    init?(feed: String?, publicKey: String?) {
        guard let feed, let url = URL(string: feed), (try? UpdateVerifier.requireSecure(url)) != nil,
              let publicKey, UpdateVerifier.isValidPublicKey(publicKey) else { return nil }
        feedURL = url
        self.publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct UpdateEnvironment: Sendable {
    var bundleURL: URL
    var bundleIdentifier: String?
    var version: SemanticVersion
    var processIdentifier: Int32
    var builtInSource: BuiltInUpdateSource? = nil

    static var current: UpdateEnvironment {
        UpdateEnvironment(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier,
                          version: SemanticVersion(AppVersion.short, build: AppVersion.build) ?? SemanticVersion("0.0.0")!,
                          processIdentifier: ProcessInfo.processInfo.processIdentifier,
                          builtInSource: BuiltInUpdateSource(feed: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                                             publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String))
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    private enum Keys {
        static let feedURL = "v2.update.feedURL"
        static let channel = "v2.update.channel"
        static let publicKey = "v2.update.ed25519PublicKey"
        static let lastCheckAt = "v2.update.lastCheckAt"
    }

    private static let maxFeedBytes: Int64 = 2 * 1024 * 1024
    private static let maxArchiveBytes: Int64 = 512 * 1024 * 1024
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var latestRelease: ReleaseInfo?
    // 校验已通过但暂时不能重启时的说明，例如还有未保存的设置。
    @Published private(set) var installNotice: String?
    @Published var feedURL: String {
        didSet {
            guard feedURL != oldValue else { return }
            defaults.set(feedURL, forKey: Keys.feedURL)
            invalidate()
        }
    }
    @Published var channel: UpdateChannel {
        didSet {
            guard channel != oldValue else { return }
            defaults.set(channel.rawValue, forKey: Keys.channel)
            invalidate()
        }
    }
    @Published var ed25519PublicKey: String {
        didSet {
            guard ed25519PublicKey != oldValue else { return }
            defaults.set(ed25519PublicKey, forKey: Keys.publicKey)
            invalidate()
        }
    }

    // 返回非空字符串表示现在不能退出重启。
    var installGate: () -> String? = { nil }

    let environment: UpdateEnvironment
    private let defaults: UserDefaults
    private let session: URLSession
    private let workRoot: URL
    private let relaunch: (UpdateInstallPlan) throws -> Void
    private var generation = UUID()
    private var workDirectory: URL?
    private var stagedExecutable: String?
    private var downloadJob: Task<StagedBundle, Error>?

    init(defaults: UserDefaults = .standard, environment: UpdateEnvironment = .current,
         session: URLSession = URLSession(configuration: .ephemeral),
         workRoot: URL = FileManager.default.temporaryDirectory,
         relaunch: ((UpdateInstallPlan) throws -> Void)? = nil) {
        self.defaults = defaults
        self.environment = environment
        self.session = session
        self.workRoot = workRoot
        self.relaunch = relaunch ?? { try UpdateRelauncher.launch($0) }
        feedURL = defaults.string(forKey: Keys.feedURL) ?? environment.builtInSource?.feedURL.absoluteString ?? ""
        channel = defaults.string(forKey: Keys.channel).flatMap(UpdateChannel.init(rawValue:)) ?? .stable
        ed25519PublicKey = defaults.string(forKey: Keys.publicKey) ?? ""
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying: return true
        default: return false
        }
    }

    var hasValidFeed: Bool { validFeed != nil }
    var hasValidPublicKey: Bool { trimmedKey.isEmpty || UpdateVerifier.isValidPublicKey(trimmedKey) }
    var requiredPublicKey: String? {
        guard let source = environment.builtInSource, let url = validFeed,
              url.host?.lowercased() == source.feedURL.host?.lowercased(),
              (url.port ?? 443) == (source.feedURL.port ?? 443),
              url.standardized.path == source.feedURL.path else { return nil }
        return source.publicKey
    }

    func restoreBuiltInFeed() {
        if let source = environment.builtInSource { feedURL = source.feedURL.absoluteString }
    }

    // 官方更新源不能被自定义公钥（包括空值）降级；换用其他更新源仍保留旧设置。
    private var trimmedKey: String { requiredPublicKey ?? ed25519PublicKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validFeed: URL? {
        guard let url = URL(string: feedURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? UpdateVerifier.requireSecure(url)) != nil else { return nil }
        return url
    }

    // MARK: 检查

    func checkForUpdates() async { await performCheck(silent: false) }

    // 后台检查每 24 小时最多一次，失败不打扰用户。
    func checkIfDue(now: Date = Date()) async {
        guard hasValidFeed, state == .idle else { return }
        let last = defaults.object(forKey: Keys.lastCheckAt) as? Date
        guard last.map({ now.timeIntervalSince($0) >= Self.checkInterval || $0 > now }) ?? true else { return }
        await performCheck(silent: true)
    }

    private func performCheck(silent: Bool) async {
        if isBusy { return }
        if case .readyToInstall = state { return }
        guard let url = validFeed else {
            if !silent { state = .failed(UpdateError.insecureURL.errorDescription ?? "") }
            return
        }
        let mark = UUID()
        generation = mark
        if !silent { state = .checking }
        var directory: URL?
        defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
        do {
            let folder = try makePrivateDirectory()
            directory = folder
            let file = folder.appendingPathComponent("appcast")
            try await UpdateFileFetch(destination: file, limit: Self.maxFeedBytes).run(url, session: session)
            guard generation == mark else { return }
            let releases = try AppcastParser.parse(try Data(contentsOf: file))
            let next = AppcastParser.newest(in: releases, channel: channel, current: environment.version)
            if let next { try UpdateVerifier.requireSecure(next.downloadURL) }
            let now = Date()
            defaults.set(now, forKey: Keys.lastCheckAt)
            latestRelease = next
            installNotice = nil
            state = next.map(UpdateState.available) ?? .upToDate(checkedAt: now)
        } catch {
            guard generation == mark, !silent else { return }
            latestRelease = nil
            state = .failed(Self.message(error))
        }
    }

    // MARK: 下载与安装

    func downloadAndInstall() async {
        if case .readyToInstall = state { installNow(); return }
        guard !isBusy, let release = latestRelease else { return }
        let mark = UUID()
        generation = mark
        installNotice = nil
        state = .downloading(progress: 0)
        do {
            try checkInstallLocation()
            removeWorkDirectory()
            let directory = try makePrivateDirectory()
            workDirectory = directory
            let job = Task { @MainActor [weak self] () throws -> StagedBundle in
                guard let self else { throw CancellationError() }
                return try await self.fetchAndStage(release, into: directory, mark: mark)
            }
            downloadJob = job
            let staged = try await job.value
            downloadJob = nil
            guard generation == mark else { return }
            stagedExecutable = staged.executable
            state = .readyToInstall(release, stagedAppURL: staged.appURL)
            installNow()
        } catch {
            guard generation == mark else { return }
            downloadJob = nil
            removeWorkDirectory()
            if Self.isCancellation(error) { state = .available(release) }
            else { state = .failed(Self.message(error)) }
        }
    }

    func cancelDownload() { downloadJob?.cancel() }

    func installNow() {
        guard case .readyToInstall(_, let stagedURL) = state, let workDirectory, let stagedExecutable else { return }
        if let reason = installGate() {
            installNotice = reason
            return
        }
        installNotice = nil
        do {
            try checkInstallLocation()
            try relaunch(UpdateInstallPlan(processIdentifier: environment.processIdentifier, target: environment.bundleURL,
                                           staged: stagedURL, workDirectory: workDirectory, executable: stagedExecutable))
        } catch {
            installNotice = Self.message(error)
        }
    }

    private func fetchAndStage(_ release: ReleaseInfo, into directory: URL, mark: UUID) async throws -> StagedBundle {
        let archive = directory.appendingPathComponent("update.zip")
        let fetch = UpdateFileFetch(destination: archive, limit: Self.maxArchiveBytes, expected: release.length) { [weak self] value in
            Task { @MainActor [weak self] in self?.reportProgress(value, mark: mark) }
        }
        try await fetch.run(release.downloadURL, session: session)
        try Task.checkCancellation()
        guard generation == mark else { throw CancellationError() }
        state = .verifying
        let key = trimmedKey, identifier = environment.bundleIdentifier
        return try await Task.detached(priority: .userInitiated) {
            let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
            try UpdateVerifier.verify(archive: bytes, sha256: release.sha256, signature: release.edSignature,
                                      publicKey: key.isEmpty ? nil : key)
            return try UpdateStager.stage(archive: archive, into: directory, release: release, bundleIdentifier: identifier)
        }.value
    }

    private func reportProgress(_ value: Double, mark: UUID) {
        guard generation == mark, case .downloading(let current) = state, value >= current + 0.01 || value == 1 else { return }
        state = .downloading(progress: value)
    }

    // 下载前就确认能写入，避免用户等完才发现装不了。
    private func checkInstallLocation() throws {
        let target = environment.bundleURL
        guard target.pathExtension == "app" else { throw UpdateError.notInstallable("开发构建不支持自动更新，请使用打包后的应用。") }
        guard !target.path.contains("/AppTranslocation/") else {
            throw UpdateError.notInstallable("应用正在隔离路径运行，请先移到「应用程序」文件夹再更新。")
        }
        guard (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
            throw UpdateError.notInstallable("应用是通过符号链接启动的，请直接从安装位置打开后再更新。")
        }
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: target.path), manager.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.notInstallable("没有写入 \(target.deletingLastPathComponent().path) 的权限，无法替换应用。")
        }
    }

    // 更新源、通道或公钥变化后，旧结果和已暂存的安装包都不再可信。
    private func invalidate() {
        generation = UUID()
        downloadJob?.cancel()
        downloadJob = nil
        removeWorkDirectory()
        latestRelease = nil
        installNotice = nil
        state = .idle
    }

    private func removeWorkDirectory() {
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
        stagedExecutable = nil
    }

    private func makePrivateDirectory() throws -> URL {
        let url = workRoot.appendingPathComponent("wechat-bridge-update-\(UUID().uuidString)", isDirectory: true)
        // withIntermediateDirectories 为 false：路径已存在（含预置符号链接）时直接失败。
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func message(_ error: Error) -> String {
        if let update = error as? UpdateError, let text = update.errorDescription { return text }
        if error is URLError { return "无法连接更新服务器，请检查网络后重试。" }
        return "更新失败，请稍后重试。"
    }
}
