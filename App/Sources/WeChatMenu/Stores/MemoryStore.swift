import Foundation

@MainActor
final class MemoryStore: ObservableObject, BridgeEventConsumer {
    @Published private(set) var documents: [MemoryTarget: MemoryContent] = [:]
    @Published private(set) var revisions: [MemoryTarget: [MemoryRevision]] = [:]
    @Published private(set) var revisionCursors: [MemoryTarget: String] = [:]
    @Published private(set) var proposals: [PersonaProposal] = []
    @Published private(set) var proposalCursor: String?
    @Published private(set) var pendingProposalCount = 0

    private let runtime: BridgeRuntime
    private let stateDirectory: URL
    private let memoryBaseDirectory: () -> String

    init(runtime: BridgeRuntime, stateDirectory: URL = SettingsDisk.standard.directory,
         memoryBaseDirectory: @escaping () -> String = { "" }) {
        self.runtime = runtime
        self.stateDirectory = stateDirectory
        self.memoryBaseDirectory = memoryBaseDirectory
        runtime.register(self)
    }

    func apply(_ event: PushEvent) {
        switch event {
        case .hello(let payload): pendingProposalCount = payload.status.pendingProposalCount
        case .proposalUpdated(let update):
            pendingProposalCount = update.pendingCount
            if let latest = update.latestProposal { merge(latest) }
        default: break
        }
    }

    // 记忆内容保留在磁盘；断线后清掉内存副本，重连后重新读取。
    func bridgeDisconnected() {
        documents = [:]
        revisions = [:]
        revisionCursors = [:]
        proposals = []
        proposalCursor = nil
        pendingProposalCount = 0
    }

    // MARK: L2 / L3 文档

    @discardableResult
    func load(_ target: MemoryTarget) async throws -> MemoryContent {
        let content = try await runtime.client.memoryGet(target)
        documents[target] = content
        return content
    }

    @discardableResult
    func save(_ target: MemoryTarget, text: String) async throws -> MemoryRevision {
        let content = MemoryContent(text: text, path: documents[target]?.path)
        guard content.isValid else { throw BridgeFault("invalid-configuration") }
        return await record(target, try await runtime.client.memorySave(target, content: content))
    }

    @discardableResult
    func setEntryLock(_ target: MemoryTarget, entryId: String, locked: Bool) async throws -> MemoryRevision {
        await record(target, try await runtime.client.memorySetEntryLock(target, entryId: entryId, locked: locked))
    }

    @discardableResult
    func setEntryVisibility(_ target: MemoryTarget, entryId: String, visibility: MemoryVisibility) async throws -> MemoryRevision {
        await record(target, try await runtime.client.memorySetEntryVisibility(target, entryId: entryId, visibility: visibility))
    }

    @discardableResult
    func consolidateNow(conversationId: String, backfill: BackfillRequest? = nil) async throws -> MemoryRevision? {
        if let backfill, !backfill.isValid || backfill.conversationId != conversationId {
            throw BridgeFault("invalid-configuration")
        }
        guard let revision = try await runtime.client.memoryConsolidateNow(conversationId: conversationId, backfill: backfill) else {
            return nil
        }
        return await record(.scope(conversationId: conversationId), revision)
    }

    // MARK: 历史快照

    func loadRevisions(_ target: MemoryTarget, more: Bool = false, limit: Int = 50) async throws {
        let cursor = more ? revisionCursors[target] : nil
        if more && cursor == nil { return }
        let page = try await runtime.client.memoryRevisions(.init(target: target, cursor: cursor, limit: limit))
        var merged = more ? revisions[target] ?? [] : []
        let known = Set(merged.map(\.revId))
        merged.append(contentsOf: page.items.filter { !known.contains($0.revId) })
        revisions[target] = merged
        revisionCursors[target] = page.nextCursor
    }

    @discardableResult
    func rollback(_ target: MemoryTarget, revId: String) async throws -> MemoryRevision {
        await record(target, try await runtime.client.memoryRollback(target, revId: revId))
    }

    // 写入已成功，重新读取失败时只清掉缓存，让界面下次重读，不能显示旧内容或误报写失败。
    private func record(_ target: MemoryTarget, _ revision: MemoryRevision) async -> MemoryRevision {
        revisions[target] = [revision] + (revisions[target] ?? []).filter { $0.revId != revision.revId }
        documents[target] = try? await runtime.client.memoryGet(target)
        return revision
    }

    // MARK: 人格提案

    func loadProposals(more: Bool = false, limit: Int = 50) async throws {
        if more && proposalCursor == nil { return }
        let page = try await runtime.client.personaProposals(.init(cursor: more ? proposalCursor : nil, limit: limit))
        if !more { proposals = [] }
        page.items.forEach(merge)
        proposalCursor = page.nextCursor
    }

    @discardableResult
    func decide(_ decision: PersonaDecision) async throws -> PersonaProposal {
        if case .acceptEdited(_, let content) = decision, !content.isValid { throw BridgeFault("invalid-configuration") }
        let proposal = try await runtime.client.personaDecide(decision)
        merge(proposal)
        if proposal.status == .accepted { documents[.persona] = try? await runtime.client.memoryGet(.persona) }
        return proposal
    }

    // ipc.ts 的提案只给出文件路径。这里只读取 proposals 目录内的私有文件，原文交给 UI 解析。
    func proposalDocument(_ proposal: PersonaProposal) throws -> String {
        let base = memoryBaseDirectory()
        let memory = base.isEmpty ? stateDirectory.appendingPathComponent("memory", isDirectory: true)
            : URL(fileURLWithPath: base, isDirectory: true)
        let directory = memory.appendingPathComponent("proposals", isDirectory: true).standardizedFileURL
        let candidate = proposal.filePath.hasPrefix("/") ? URL(fileURLWithPath: proposal.filePath)
            : directory.appendingPathComponent(proposal.filePath)
        let file = candidate.standardizedFileURL
        guard file.deletingLastPathComponent().path == directory.path, file.pathExtension == "json" else {
            throw BridgeFault("storage-unavailable")
        }
        try PrivateFile.validateDirectory(directory.path)
        // 与 Engine/src/memory/persona.ts 的 MAX_PROPOSAL_BYTES (384 KiB) 对齐。
        let data = try PrivateFile.read(file.path, maxBytes: 384 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { throw BridgeFault("storage-unavailable") }
        return text
    }

    private func merge(_ proposal: PersonaProposal) {
        if let index = proposals.firstIndex(where: { $0.proposalId == proposal.proposalId }) { proposals[index] = proposal }
        else { proposals.append(proposal) }
        proposals.sort { $0.createdAt > $1.createdAt }
    }
}
