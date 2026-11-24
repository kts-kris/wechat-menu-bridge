import AppKit
import Darwin
import Foundation

// 256 KiB 帧远大于管道缓冲区，单次非阻塞 write 必然短写。
// 按帧边界入队并同步计入字节上限；紧急暂停可立刻清空未开始写的普通帧，遇到半帧则直接断管撤权。
final class PipeFrameWriter: @unchecked Sendable {
    static let maxBacklogBytes = 8 * IPCv3.maxFrameBytes

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.wechatmenubridge.ipc.writer")
    private let handle: FileHandle
    private let onFailure: @Sendable () -> Void
    private var activeFrame: Data?
    private var activeOffset = 0
    private var pendingFrames: [Data] = []
    private var queuedBytes = 0
    private var source: DispatchSourceWrite?
    private var closed = false
    private var urgentDraining = false

    init(handle: FileHandle, onFailure: @escaping @Sendable () -> Void) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw BridgeFault("engine-exited")
        }
        self.handle = handle
        self.onFailure = onFailure
    }

    func send(_ frame: Data) {
        lock.lock()
        guard !closed, !urgentDraining else { lock.unlock(); return }
        guard queuedBytes + frame.count <= Self.maxBacklogBytes else {
            let notify = stopLocked()
            lock.unlock()
            if notify { onFailure() }
            return
        }
        pendingFrames.append(frame)
        queuedBytes += frame.count
        let needsDrain = source == nil
        lock.unlock()
        if needsDrain { queue.async { [self] in drain() } }
    }

    // 同步抢占：丢弃全部未开始写出的普通帧；无半帧时立即同步尝试写出暂停帧，有半帧则立即断管由引擎撤权。
    func sendUrgent(_ frame: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        urgentDraining = true
        pendingFrames.removeAll()
        if let active = activeFrame, activeOffset > 0 && activeOffset < active.count {
            let notify = stopLocked()
            lock.unlock()
            if notify { onFailure() }
            return
        }
        activeFrame = frame
        activeOffset = 0
        queuedBytes = frame.count
        let failed = drainLocked()
        lock.unlock()
        if failed { onFailure() }
    }

    func close() {
        lock.lock()
        _ = stopLocked()
        lock.unlock()
    }

    private func drain() {
        lock.lock()
        let failed = drainLocked()
        lock.unlock()
        if failed { onFailure() }
    }

    private func drainLocked() -> Bool {
        guard !closed else { return false }
        let fd = handle.fileDescriptor
        while true {
            if activeFrame == nil {
                guard !pendingFrames.isEmpty else {
                    source?.cancel()
                    source = nil
                    urgentDraining = false
                    return false
                }
                activeFrame = pendingFrames.removeFirst()
                activeOffset = 0
            }
            guard let frame = activeFrame else { continue }
            while activeOffset < frame.count {
                let written = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + activeOffset, $0.count - activeOffset) }
                if written > 0 {
                    activeOffset += written
                    queuedBytes = max(0, queuedBytes - written)
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                if written < 0 && errno == EAGAIN {
                    waitForCapacityLocked(fd)
                    return false
                }
                return stopLocked()
            }
            activeFrame = nil
            activeOffset = 0
        }
    }

    private func waitForCapacityLocked(_ fd: Int32) {
        guard source == nil else { return }
        let next = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        next.setEventHandler { [weak self] in self?.drain() }
        source = next
        next.resume()
    }

    private func stopLocked() -> Bool {
        guard !closed else { return false }
        closed = true
        activeFrame = nil
        activeOffset = 0
        pendingFrames.removeAll()
        queuedBytes = 0
        let handle = self.handle
        if let source {
            source.setCancelHandler { try? handle.close() }
            source.cancel()
            self.source = nil
        } else {
            try? handle.close()
        }
        return true
    }
}

@MainActor
final class ProcessBridgeTransport: BridgeTransport {
    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?

    private let child = Process()
    private let output: FileHandle
    private let writer: PipeFrameWriter
    private var finished = false

    init(engine: URL, directory: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: engine.path) else { throw BridgeFault("engine-missing") }
        _ = signal(SIGPIPE, SIG_IGN)
        let stdin = Pipe(), stdout = Pipe()
        output = stdout.fileHandleForReading
        let relay = ClosedRelay()
        writer = try PipeFrameWriter(handle: stdin.fileHandleForWriting) { relay.fire() }
        relay.target = self
        child.executableURL = engine
        child.arguments = ["--state-dir", directory.path]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = directory
        // 不向后台传递凭据、用户 shell 设置、代理或 Bun 配置。
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": NativeQA.home?.path ?? NSHomeDirectory()]
        child.terminationHandler = { _ in
            // 给 stdout 留出时间，先读完最后一条结构化错误。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { relay.fire() }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.finished else { return }
                if data.isEmpty { self.finish() } else { self.onData?(data) }
            }
        }
        do { try child.run() }
        catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            writer.close()
            throw BridgeFault("engine-missing")
        }
    }

    func send(_ frame: Data) { writer.send(frame) }
    func sendUrgent(_ frame: Data) { writer.sendUrgent(frame) }

    func close() {
        guard !finished else { return }
        finished = true
        teardown()
    }

    fileprivate func finish() {
        guard !finished else { return }
        finished = true
        teardown()
        onClosed?()
    }

    private func teardown() {
        // 读端随传输对象释放而关闭；此处显式 close 可能与正在执行的 availableData 竞争并抛异常。
        output.readabilityHandler = nil
        writer.close()
        // 后台卡死、不处理 EOF 时只结束这个子进程；日志恢复机制继续保留未知发送。
        let process = child
        if process.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

private final class ClosedRelay: @unchecked Sendable {
    weak var target: ProcessBridgeTransport?
    func fire() {
        DispatchQueue.main.async { [weak self] in self?.target?.finish() }
    }
}

@MainActor
protocol BridgeEventConsumer: AnyObject {
    func apply(_ event: PushEvent)
    func bridgeDisconnected()
}

enum BridgeSystemEvent: Sendable { case willSleep, didWake, sessionResigned }

@MainActor
final class BridgeRuntime: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var starting = false
    @Published private(set) var globalPhase: GlobalPhase = .idle
    @Published private(set) var global: GlobalRuntimeState?
    @Published private(set) var capabilities: XiaoheCapabilities?
    @Published private(set) var fault: String?
    // 任何暂停都会递增。等待钥匙串的授权流程据此作废。
    @Published private(set) var pauseRevision = 0

    let client: BridgeClientV3
    private var consumers: [WeakConsumer] = []
    private var observers: [NSObjectProtocol] = []

    private struct WeakConsumer { weak var value: BridgeEventConsumer? }

    init(client: BridgeClientV3? = nil) {
        let client = client ?? BridgeClientV3()
        self.client = client
        client.onEvent = { [weak self] in self?.dispatch($0) }
        client.onReady = { [weak self] ready in
            guard let self else { return }
            self.ready = ready
            self.starting = false
            if ready { self.fault = nil } else { self.reset() }
        }
        client.onFailure = { [weak self] code in self?.fault = code }
    }

    func register(_ consumer: BridgeEventConsumer) {
        consumers.removeAll { $0.value == nil }
        consumers.append(WeakConsumer(value: consumer))
    }

    // MARK: 子进程生命周期

    func start(engine: URL, directory: URL) throws {
        guard !client.connected else { throw BridgeFault("busy") }
        try connect(ProcessBridgeTransport(engine: engine, directory: directory))
    }

    func connect(_ transport: BridgeTransport) throws {
        guard !client.connected else { throw BridgeFault("busy") }
        fault = nil
        starting = true
        try client.connect(transport)
    }

    func stop() {
        pauseRevision += 1
        client.shutdown()
        starting = false
    }

    // 系统事件和全局暂停都不会自动恢复；只有用户重新授权才能继续。
    func startObservingSystemEvents() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, BridgeSystemEvent)] = [
            (NSWorkspace.willSleepNotification, .willSleep), (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
        ]
        for (name, event) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(event) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    func stopObservingSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach {
            center.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers.removeAll()
    }

    func handle(_ event: BridgeSystemEvent) {
        pauseRevision += 1
        client.firePauseAll(scope: .all, reason: .systemSleep)
    }

    // MARK: 全局控制

    func pauseAll(scope: PauseScope = .all, reason: IPCErrorCode = .userPaused) async throws {
        pauseRevision += 1
        try await client.systemPauseAll(scope: scope, reason: reason)
    }

    func resynchronize() async throws {
        dispatch(.hello(HelloPayload(status: try await client.systemStatus())))
    }

    @discardableResult
    func refreshCapabilities() async throws -> XiaoheCapabilities {
        let caps = try await client.xiaoheCapabilities()
        capabilities = caps
        return caps
    }

    // MARK: 事件分发

    private func dispatch(_ event: PushEvent) {
        switch event {
        case .hello(let payload):
            capabilities = payload.status.capabilities
            globalPhase = payload.status.globalPhase
            global = nil
        case .globalUpdated(let state):
            global = state
            globalPhase = state.phase
        default: break
        }
        consumers.forEach { $0.value?.apply(event) }
    }

    private func reset() {
        pauseRevision += 1
        globalPhase = .idle
        global = nil
        capabilities = nil
        consumers.forEach { $0.value?.bridgeDisconnected() }
    }
}
