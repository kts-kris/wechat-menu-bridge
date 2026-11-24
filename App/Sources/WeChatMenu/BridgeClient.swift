import Darwin
import Foundation

private let bridgeProtocolVersion = 2

struct BridgeFault: Error, Equatable {
    let code: String
    init(_ code: String) { self.code = code }
}

struct EngineState: Decodable {
    struct Receipt: Decodable {
        let status: String
        let delivery: String
        let hasOperation: Bool
        let pending: Bool

        var caption: String {
            if pending { return "正在等待小禾返回" }
            if status == "rejected" { return "已拒绝" }
            if delivery == "delivered" { return "已送达（小禾回执）" }
            if delivery == "failed" { return "回执报告失败" }
            return status == "submitted" ? "已提交 · 送达未知" : "提交结果未知 · 不会重发"
        }
    }
    struct Quantiles: Decodable { let p50: Int; let p95: Int }
    struct Statistics: Decodable {
        let count: Int
        let ingest: Quantiles, batch: Quantiles, model: Quantiles, rpc: Quantiles, total: Quantiles
    }

    var phase = "idle"
    var reason: String? = nil
    var running = false
    var autoReply = false
    var scheduledAt: Int64? = nil
    var draft: String? = nil
    var dryRun = false
    var inFlight = false
    var peerStopped = false
    var uncertain = false
    var receipt: Receipt? = nil
    var statistics: Statistics? = nil

    var title: String {
        switch phase {
        case "connecting": return "正在连接小禾"
        case "listening": return dryRun ? "只拟稿 · 不发送" : "自动回复中"
        case "generating": return "正在拟稿"
        case "retrying": return "连接中断，正在重连"
        case "scheduled": return "一次发送待提交"
        case "checking": return "正在核验发送权限"
        case "sending": return "正在提交"
        case "paused": return "已暂停"
        default: return "未开启"
        }
    }
}

private struct EventFrame: Decodable {
    let kind: String
    let v: Int?
    let id: Int?
    let code: String?
    let status: EngineState?
}

private struct ReplyFrame<T: Decodable>: Decodable {
    let ok: Bool
    let code: String?
    let result: T?
}

@MainActor
final class BridgeClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var generation = UUID()
    private var seq = 0
    private var buffer = Data()
    private var pending: [Int: (Result<Data, BridgeFault>) -> Void] = [:]
    private var finalFault: String?
    private(set) var ready = false
    private let decode = JSONDecoder()
    var onState: ((EngineState) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    func start(engine: URL, directory: URL) throws {
        guard process == nil else { throw BridgeFault("busy") }
        guard FileManager.default.isExecutableFile(atPath: engine.path) else { throw BridgeFault("engine-missing") }
        _ = signal(SIGPIPE, SIG_IGN)
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        let token = UUID()
        generation = token
        finalFault = nil
        buffer.removeAll()
        child.executableURL = engine
        child.arguments = ["--state-dir", directory.path, "--legacy-v2"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = directory
        // Don't pass credentials, user shell settings, proxies, or Bun configuration to the helper.
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": NativeQA.home?.path ?? NSHomeDirectory()]
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.process = nil
                // Give the stdout consumer a chance to read a final structured fault before EOF.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.generation == token, self.finalFault == nil else { return }
                    self.fail("engine-exited")
                }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                if data.isEmpty { self.fail("engine-exited") } else { self.consume(data) }
            }
        }
        input = stdin.fileHandleForWriting
        let flags = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            fail("engine-exited")
            throw BridgeFault("engine-exited")
        }
        output = stdout.fileHandleForReading
        process = child
        do { try child.run() }
        catch {
            process = nil
            fail("engine-missing")
            throw BridgeFault("engine-missing")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == token, !self.ready, self.finalFault == nil else { return }
            self.fail("engine-timeout")
        }
    }

    func request<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        guard ready else { throw BridgeFault(finalFault ?? "engine-not-ready") }
        seq += 1
        let id = seq
        var data = try JSONSerialization.data(withJSONObject: ["v": bridgeProtocolVersion, "id": id, "method": method, "params": params])
        data.append(10)
        guard data.count <= 24_576 else { throw BridgeFault("invalid-configuration") }
        let response: Data = try await withCheckedThrowingContinuation { c in
            pending[id] = { c.resume(with: $0.mapError { $0 as Error }) }
            writeFrame(data)
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + (method == "pause" ? 2 : 26)) { [weak self] in
                guard let self, self.generation == token, let cb = self.pending.removeValue(forKey: id) else { return }
                cb(.failure(BridgeFault("engine-timeout")))
                // Closing the pipe revokes all local grants; never leave a possibly armed helper orphaned.
                self.fail("engine-timeout")
            }
        }
        let envelope: ReplyFrame<T>
        do { envelope = try decode.decode(ReplyFrame<T>.self, from: response) }
        catch { fail("engine-protocol"); throw BridgeFault("engine-protocol") }
        guard envelope.ok, let result = envelope.result else { throw BridgeFault(envelope.code ?? "engine-protocol") }
        return result
    }

    func shutdown() { fail("stopped", notify: false) }

    func pause(_ reason: String) {
        guard ready else { return }
        seq += 1
        let id = seq
        guard var data = try? JSONSerialization.data(withJSONObject: ["v": bridgeProtocolVersion, "id": id, "method": "pause", "params": ["reason": reason]]) else {
            fail("engine-protocol"); return
        }
        data.append(10)
        pending[id] = { [weak self] response in
            guard let self, self.ready, case let .success(bytes) = response else { return }
            if (try? self.decode.decode(ReplyFrame<Bool>.self, from: bytes).result) != true { self.fail("engine-protocol") }
        }
        writeFrame(data)
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == token, self.pending[id] != nil else { return }
            self.fail("engine-timeout")
        }
    }

    private func writeFrame(_ data: Data) {
        guard let input else { fail("engine-exited"); return }
        let n = data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
        if n != data.count { fail("engine-exited") }
    }

    private func consume(_ data: Data) {
        guard finalFault == nil else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard line.count <= 32_768, let frame = try? decode.decode(EventFrame.self, from: line) else {
                fail("engine-protocol"); return
            }
            if let state = frame.status { onState?(state) }
            switch frame.kind {
            case "hello":
                guard frame.v == bridgeProtocolVersion, !ready else { fail("engine-protocol"); return }
                ready = true; onReady?(true)
            case "reply":
                if let id = frame.id { pending.removeValue(forKey: id)?(.success(line)) }
            case "fatal": fail(frame.code ?? "engine-exited"); return
            case "state": break
            default: fail("engine-protocol"); return
            }
        }
        if buffer.count > 32_768 { fail("engine-protocol") }
    }

    private func fail(_ code: String, notify: Bool = true) {
        if finalFault != nil { return }
        finalFault = code
        ready = false
        output?.readabilityHandler = nil
        try? output?.close()
        try? input?.close()
        output = nil; input = nil
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0(.failure(BridgeFault(code))) }
        onReady?(false)
        if notify { onFailure?(code) }
        // If a wedged helper never processes EOF, stop that exact child; journal recovery holds its unknown sends.
        if let child = process, child.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) {
                if child.isRunning { child.terminate() }
            }
        }
    }
}
