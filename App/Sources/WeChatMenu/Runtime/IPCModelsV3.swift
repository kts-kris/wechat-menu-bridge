import Foundation

// 本文件逐字对齐 Engine/src/contracts/*.ts。字段名与 rawValue 不得单侧修改。
enum IPCv3 {
    static let version = 3
    static let maxFrameBytes = 256 * 1024
    static let maxInlineDocumentBytes = 64 * 1024

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // 契约使用 strictObject：未知字段和 optional 字段上的 null 都必须拒绝。
    static func decodeStrict<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let value = try JSONDecoder().decode(T.self, from: data)
        let input = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let output = try JSONSerialization.jsonObject(with: encoder().encode(value), options: .fragmentsAllowed)
        guard covers(input, output) else { throw BridgeFault("engine-protocol") }
        return value
    }

    private static func covers(_ input: Any, _ output: Any) -> Bool {
        if let input = input as? [String: Any] {
            guard let output = output as? [String: Any] else { return false }
            return input.allSatisfy { key, value in output[key].map { covers(value, $0) } ?? false }
        }
        if let input = input as? [Any] {
            guard let output = output as? [Any], input.count == output.count else { return false }
            return zip(input, output).allSatisfy { covers($0, $1) }
        }
        return true
    }
}

struct IPCCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer {
    // zod 的 default 只填补缺失字段；显式 null 仍是错误。
    func defaulted<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        contains(key) ? try decode(T.self, forKey: key) : fallback()
    }
}

private func contractError(_ decoder: Decoder, _ message: String) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
}

// MARK: - errors.ts

enum IPCErrorCode: String, Codable, CaseIterable, Sendable {
    case activeLimit = "active-limit", backlogLimit = "backlog-limit", busy, busyChat = "busy-chat"
    case clockChanged = "clock-changed", cloudNotApproved = "cloud-not-approved", cloudProfile = "cloud-profile"
    case configUnreadable = "config-unreadable", draftReady = "draft-ready", duplicateAttempt = "duplicate-attempt"
    case engineExited = "engine-exited", engineMissing = "engine-missing", engineNotReady = "engine-not-ready"
    case engineProtocol = "engine-protocol", engineTimeout = "engine-timeout", eventGap = "event-gap", expired
    case internalError = "internal-error", invalidCommand = "invalid-command"
    case invalidConfiguration = "invalid-configuration", invalidEndpoint = "invalid-endpoint"
    case invalidExpiry = "invalid-expiry", invalidFrame = "invalid-frame", invalidKey = "invalid-key"
    case keychainUnavailable = "keychain-unavailable", manualReview = "manual-review"
    case manualTakeover = "manual-takeover", mcpContract = "mcp-contract", mcpOffline = "mcp-offline"
    case missingKey = "missing-key", modelAuth = "model-auth", modelFormat = "model-format", modelLimit = "model-limit"
    case modelSkip = "model-skip", modelTimeout = "model-timeout", modelUnavailable = "model-unavailable"
    case noAnchor = "no-anchor", noOperation = "no-operation", oneShotComplete = "one-shot-complete"
    case peerStopped = "peer-stopped", pluginCircuitOpen = "plugin-circuit-open", pluginLimit = "plugin-limit"
    case pluginPermission = "plugin-permission", pluginTimeout = "plugin-timeout"
    case previewLocalOnly = "preview-local-only", profileUnreadable = "profile-unreadable", sendFence = "send-fence"
    case sendNotAuthorized = "send-not-authorized", sendRejected = "send-rejected", sendUnknown = "send-unknown"
    case settingsChanged = "settings-changed", stopped, storageInUse = "storage-in-use"
    case storageUnavailable = "storage-unavailable", systemSleep = "system-sleep", turnObsolete = "turn-obsolete"
    case userPaused = "user-paused", wechatChanged = "wechat-changed", wechatPermission = "wechat-permission"
    case wrongAnchor = "wrong-anchor"
}

// MARK: - events.ts

enum ScopeType: String, Codable, CaseIterable, Sendable { case direct, group, service }
enum MessageKind: String, Codable, CaseIterable, Sendable { case text, image, voice, link, file, recall, system }

struct XiaoheCapabilities: Codable, Equatable, Sendable {
    var accountWideEvents: Bool
    var listConversations: Bool
    var groupMembers: Bool
    var historyQuery: Bool
    var historySearch: Bool
    var readMedia: Bool
    var nativeReply: Bool
    var mentionSend: Bool
    var canSendText: Bool
}

struct BackfillRequest: Codable, Equatable, Sendable {
    enum Purpose: String, Codable, CaseIterable, Sendable { case context, plugin, memory }
    var conversationId: String
    var recentCount: Int? = nil
    var startTime: Int64? = nil
    var endTime: Int64? = nil
    var purpose: Purpose

    var isValid: Bool {
        if let recentCount, !(1...500).contains(recentCount) { return false }
        if startTime == nil && endTime == nil { return true }
        guard recentCount == nil, let startTime, let endTime else { return false }
        return startTime >= 0 && endTime >= startTime
    }
}

// ipc.ts 将 backfill.progress 的 error 收窄为错误码。
struct BackfillProgress: Codable, Equatable, Sendable {
    var jobId: String
    var conversationId: String
    var fetched: Int
    var done: Bool
    var error: IPCErrorCode? = nil
}

// MARK: - settings.ts

enum ModelKind: String, Codable, CaseIterable, Sendable { case chat, vision, stt }
enum ReasoningEffort: String, Codable, CaseIterable, Sendable { case `default`, low, medium, high, max }

enum ModelEndpoint {
    // 对齐 settings.ts 的 modelEndpoint：保留端口和路径前缀，使既有钥匙串索引继续生效。
    static func canonical(_ value: String, kind: ModelKind) -> String {
        var base = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        guard base.hasSuffix("/v1") else { return base }
        return base + (kind == .stt ? "/audio/transcriptions" : "/chat/completions")
    }

    static func isAddress(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    // 钥匙串索引只接受可发往云端的完整端点。
    static func keychainAccount(_ value: String, kind: ModelKind) throws -> String {
        guard kind == .stt else {
            guard let endpoint = Configuration.modelEndpoint(value, mode: .cloud) else { throw BridgeFault("invalid-endpoint") }
            return endpoint
        }
        let endpoint = canonical(value, kind: .stt)
        let suffix = "/audio/transcriptions"
        guard endpoint.hasSuffix(suffix),
              Configuration.modelEndpoint(String(endpoint.dropLast(suffix.count)) + "/chat/completions", mode: .cloud) != nil else {
            throw BridgeFault("invalid-endpoint")
        }
        return endpoint
    }
}

struct ModelPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var mode: ModelMode
    var kind: ModelKind
    var url: String
    var modelName: String
    var maxTokens = 320
    var temperature = 0.35
    // nil 时编码省略，既有 settings.json 不产生差异。
    var reasoningEffort: ReasoningEffort? = nil

    private enum CodingKeys: String, CodingKey { case id, name, mode, kind, url, modelName, maxTokens, temperature, reasoningEffort }

    init(id: String, name: String, mode: ModelMode, kind: ModelKind, url: String, modelName: String,
         maxTokens: Int = 320, temperature: Double = 0.35, reasoningEffort: ReasoningEffort? = nil) {
        self.id = id; self.name = name; self.mode = mode; self.kind = kind
        self.url = ModelEndpoint.canonical(url, kind: kind)
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxTokens = maxTokens; self.temperature = temperature; self.reasoningEffort = reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  mode: try c.decode(ModelMode.self, forKey: .mode), kind: try c.decode(ModelKind.self, forKey: .kind),
                  url: try c.decode(String.self, forKey: .url), modelName: try c.decode(String.self, forKey: .modelName),
                  maxTokens: try c.defaulted(.maxTokens, 320), temperature: try c.defaulted(.temperature, 0.35),
                  reasoningEffort: try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort))
    }
}

enum CustomizableRuleId: String, Codable, CaseIterable, Identifiable, Hashable, CodingKeyRepresentable, Sendable {
    case credentials, finance, privacy, legal, health
    case instructions, link, commitment, schedule, delegation
    case sensitiveTopic = "sensitive-topic"
    case numbers

    var id: String { rawValue }
}

enum RuleOverrideAction: String, Codable, CaseIterable, Equatable, Sendable {
    case inherit
    case allow
    case skipTurn = "skip_turn"
    case draftOnly = "draft_only"
    case pauseSession = "pause_session"
}

enum CustomBlockAction: String, Codable, CaseIterable, Equatable, Sendable {
    case skipTurn = "skip_turn"
    case draftOnly = "draft_only"
    case pauseSession = "pause_session"
}

struct RiskProfile: Codable, Equatable, Sendable {
    enum Level: String, Codable, CaseIterable, Sendable { case recommended, strict, minimal }
    enum TurnAction: String, Codable, CaseIterable, Sendable { case skipTurn = "skip_turn", pauseSession = "pause_session" }
    enum TakeoverAction: String, Codable, CaseIterable, Sendable { case pauseSession = "pause_session", cooldown, ignore }
    var busyChatAction = TurnAction.skipTurn
    var unparsedMediaAction = TurnAction.skipTurn
    var takeoverAction = TakeoverAction.pauseSession
    var takeoverCooldownMinutes = 15
    private var strictLegacyRules: Bool
    private var level: Level?
    // v2.3.0：按内置类目覆盖动作（12 类非铁律规则）与自定义必拦词。旧 settings.json 缺省为 {} / [] / pause_session。
    var ruleOverrides: [CustomizableRuleId: RuleOverrideAction] = [:]
    var customBlockKeywords: [String] = []
    var customBlockAction: CustomBlockAction = .pauseSession

    // nil 表示旧版本的「保守规则只跳过本轮」，保留到用户主动切换。
    var selectedLevel: Level? {
        get { level ?? (strictLegacyRules ? .strict : nil) }
        set {
            level = newValue
            strictLegacyRules = newValue == .strict
        }
    }

    private static let highRiskRules: Set<CustomizableRuleId> = [.credentials, .finance, .privacy, .legal, .health]

    func defaultAction(for rule: CustomizableRuleId) -> RuleOverrideAction {
        switch selectedLevel {
        case .strict: return .pauseSession
        case .recommended: return Self.highRiskRules.contains(rule) ? .skipTurn : .allow
        case .minimal: return .allow
        case nil: return .skipTurn
        }
    }

    func effectiveAction(for rule: CustomizableRuleId) -> RuleOverrideAction {
        if let override = ruleOverrides[rule], override != .inherit { return override }
        return defaultAction(for: rule)
    }

    var activeOverrideCount: Int {
        ruleOverrides.values.filter { $0 != .inherit }.count
    }

    private enum CodingKeys: String, CodingKey {
        case busyChatAction, unparsedMediaAction, takeoverAction, takeoverCooldownMinutes, strictLegacyRules, level
        case ruleOverrides, customBlockKeywords, customBlockAction
    }

    init(level: Level? = .recommended, ruleOverrides: [CustomizableRuleId: RuleOverrideAction] = [:],
         customBlockKeywords: [String] = [], customBlockAction: CustomBlockAction = .pauseSession) {
        self.level = level
        strictLegacyRules = level == .strict
        self.ruleOverrides = ruleOverrides
        self.customBlockKeywords = customBlockKeywords
        self.customBlockAction = customBlockAction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        busyChatAction = try c.defaulted(.busyChatAction, .skipTurn)
        unparsedMediaAction = try c.defaulted(.unparsedMediaAction, .skipTurn)
        takeoverAction = try c.defaulted(.takeoverAction, .pauseSession)
        takeoverCooldownMinutes = try c.defaulted(.takeoverCooldownMinutes, 15)
        strictLegacyRules = try c.defaulted(.strictLegacyRules, false)
        level = c.contains(.level) ? try c.decode(Level.self, forKey: .level) : nil
        ruleOverrides = try c.defaulted(.ruleOverrides, [:])
        customBlockKeywords = try c.defaulted(.customBlockKeywords, [])
        customBlockAction = try c.defaulted(.customBlockAction, .pauseSession)
    }
}

enum SessionReplyMode: String, Codable, CaseIterable, Sendable { case off, draft, auto }

struct ConversationPolicy: Codable, Equatable, Identifiable, Sendable {
    enum GroupTrigger: String, Codable, CaseIterable, Sendable { case mentionOnly = "mention_only", all }
    var conversationId: String
    var label: String
    var type: ScopeType
    var enabled: Bool
    var replyMode: SessionReplyMode
    var replyPresetId: String?
    var groupTrigger: GroupTrigger
    var riskProfile: RiskProfile
    var backfillOnArmCount: Int
    var memoryEnabled: Bool
    var pluginIds: [String]
    // v2.2.0：优先引用原消息回复；群聊回复时 @ 提问成员。旧 settings.json 缺省为 false。
    var useNativeReply = false
    var mentionReplySender = false
    // v2.3.0：豁免全局勿扰时段；关键词触发白名单与忽略黑名单。旧 settings.json 缺省为 false / []。
    var ignoreQuietHours = false
    var triggerKeywords: [String] = []
    var ignoreKeywords: [String] = []

    var id: String { conversationId }

    private enum CodingKeys: String, CodingKey {
        case conversationId, label, type, enabled, replyMode, replyPresetId, groupTrigger, riskProfile
        case backfillOnArmCount, memoryEnabled, pluginIds, useNativeReply, mentionReplySender, ignoreQuietHours
        case triggerKeywords, ignoreKeywords
    }

    init(conversationId: String, label: String, type: ScopeType, enabled: Bool = false, replyMode: SessionReplyMode = .off,
         replyPresetId: String? = nil, groupTrigger: GroupTrigger = .mentionOnly, riskProfile: RiskProfile = RiskProfile(),
         backfillOnArmCount: Int = 10, memoryEnabled: Bool? = nil, pluginIds: [String] = [],
         useNativeReply: Bool = false, mentionReplySender: Bool = false, ignoreQuietHours: Bool = false,
         triggerKeywords: [String] = [], ignoreKeywords: [String] = []) {
        self.conversationId = conversationId; self.label = label; self.type = type; self.enabled = enabled
        self.replyMode = replyMode; self.replyPresetId = replyPresetId; self.groupTrigger = groupTrigger
        self.riskProfile = riskProfile; self.backfillOnArmCount = backfillOnArmCount
        self.memoryEnabled = memoryEnabled ?? (type == .direct); self.pluginIds = pluginIds
        self.useNativeReply = useNativeReply; self.mentionReplySender = mentionReplySender
        self.ignoreQuietHours = ignoreQuietHours
        self.triggerKeywords = triggerKeywords; self.ignoreKeywords = ignoreKeywords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(ScopeType.self, forKey: .type)
        self.init(conversationId: try c.decode(String.self, forKey: .conversationId),
                  label: try c.decode(String.self, forKey: .label), type: type,
                  enabled: try c.decode(Bool.self, forKey: .enabled),
                  replyMode: try c.decode(SessionReplyMode.self, forKey: .replyMode),
                  replyPresetId: try c.contains(.replyPresetId) ? c.decode(String.self, forKey: .replyPresetId) : nil,
                  groupTrigger: try c.defaulted(.groupTrigger, .mentionOnly),
                  riskProfile: try c.defaulted(.riskProfile, RiskProfile(level: nil)),
                  backfillOnArmCount: try c.defaulted(.backfillOnArmCount, 10),
                  memoryEnabled: try c.defaulted(.memoryEnabled, type == .direct),
                  pluginIds: try c.defaulted(.pluginIds, []),
                  useNativeReply: try c.defaulted(.useNativeReply, false),
                  mentionReplySender: try c.defaulted(.mentionReplySender, false),
                  ignoreQuietHours: try c.defaulted(.ignoreQuietHours, false),
                  triggerKeywords: try c.defaulted(.triggerKeywords, []),
                  ignoreKeywords: try c.defaulted(.ignoreKeywords, []))
    }

    static let maxKeywordCount = 64
    static let maxKeywordLength = 64

    static func isValidKeyword(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxKeywordLength else { return false }
        return !trimmed.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// 将用户以逗号、分号或换行分隔的关键词文本解析为去重、受限的词条数组。
    static func parseKeywords(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，;；\r\n")
        var seen = Set<String>()
        var result: [String] = []
        for token in raw.components(separatedBy: separators) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clipped = String(trimmed.prefix(maxKeywordLength))
            guard isValidKeyword(clipped) else { continue }
            let key = clipped.precomposedStringWithCompatibilityMapping.lowercased()
            if seen.insert(key).inserted {
                result.append(clipped)
                if result.count >= maxKeywordCount { break }
            }
        }
        return result
    }

    static func formatKeywords(_ items: [String]) -> String {
        items.joined(separator: "，")
    }
}

struct SettingsV2: Codable, Equatable, Sendable {
    struct Xiaohe: Codable, Equatable, Sendable {
        var mcpUrl = ""
        var hasAuthToken = false
        var accountId = ""
        var accountLabel = ""

        private enum CodingKeys: String, CodingKey { case mcpUrl, hasAuthToken, accountId, accountLabel }
        init(mcpUrl: String = "", hasAuthToken: Bool = false, accountId: String = "", accountLabel: String = "") {
            self.mcpUrl = mcpUrl; self.hasAuthToken = hasAuthToken; self.accountId = accountId; self.accountLabel = accountLabel
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mcpUrl = try c.decode(String.self, forKey: .mcpUrl)
            hasAuthToken = try c.defaulted(.hasAuthToken, false)
            accountId = try c.decode(String.self, forKey: .accountId)
            accountLabel = try c.decode(String.self, forKey: .accountLabel)
        }
    }

    struct DefaultModels: Codable, Equatable, Sendable {
        var replyPresetId: String? = nil
        var fallbackReplyPresetId: String? = nil
        var pluginPresetId: String? = nil
        var memoryPresetId: String? = nil
        var visionPresetId: String? = nil
        var sttPresetId: String? = nil
    }

    struct Memory: Codable, Equatable, Sendable {
        var baseDir = ""
        var legacyStylePath: String? = nil
        var legacyMemoryPath: String? = nil
        var workingMaxMessages = 16
        var workingTtlMinutes = 30
        var autoConsolidateIdleMinutes = 10
        var autoConsolidateTurnThreshold = 12
        var autoMergePersona = false

        private enum CodingKeys: String, CodingKey {
            case baseDir, legacyStylePath, legacyMemoryPath, workingMaxMessages, workingTtlMinutes
            case autoConsolidateIdleMinutes, autoConsolidateTurnThreshold, autoMergePersona
        }
        init(legacyStylePath: String? = nil, legacyMemoryPath: String? = nil) {
            self.legacyStylePath = legacyStylePath; self.legacyMemoryPath = legacyMemoryPath
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            baseDir = try c.defaulted(.baseDir, "")
            legacyStylePath = try c.contains(.legacyStylePath) ? c.decode(String.self, forKey: .legacyStylePath) : nil
            legacyMemoryPath = try c.contains(.legacyMemoryPath) ? c.decode(String.self, forKey: .legacyMemoryPath) : nil
            workingMaxMessages = try c.defaulted(.workingMaxMessages, 16)
            workingTtlMinutes = try c.defaulted(.workingTtlMinutes, 30)
            autoConsolidateIdleMinutes = try c.defaulted(.autoConsolidateIdleMinutes, 10)
            autoConsolidateTurnThreshold = try c.defaulted(.autoConsolidateTurnThreshold, 12)
            autoMergePersona = try c.defaulted(.autoMergePersona, false)
        }
    }

    struct QuietHours: Codable, Equatable, Sendable {
        enum Action: String, Codable, CaseIterable, Equatable, Sendable {
            case skipTurn = "skip_turn"
            case draftOnly = "draft_only"
        }

        var enabled = false
        var start = "23:00"
        var end = "08:00"
        var action: Action = .skipTurn

        private enum CodingKeys: String, CodingKey { case enabled, start, end, action }
        init(enabled: Bool = false, start: String = "23:00", end: String = "08:00", action: Action = .skipTurn) {
            self.enabled = enabled; self.start = start; self.end = end; self.action = action
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.defaulted(.enabled, false)
            start = try c.defaulted(.start, "23:00")
            end = try c.defaulted(.end, "08:00")
            action = try c.defaulted(.action, .skipTurn)
        }

        static func isValidClock(_ value: String) -> Bool {
            value.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
        }
    }

    struct Runtime: Codable, Equatable, Sendable {
        var autoResumeReadOnlyPlugins = false
        var pinnedConversationIds: [String] = []
        var approvedCloudPresetIds: [String] = []
        var maxConcurrentLlmCalls = 3
        var fastReplyMode = false
        var quietHours = QuietHours()

        private enum CodingKeys: String, CodingKey {
            case autoResumeReadOnlyPlugins, pinnedConversationIds, approvedCloudPresetIds, maxConcurrentLlmCalls, fastReplyMode, quietHours
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            autoResumeReadOnlyPlugins = try c.defaulted(.autoResumeReadOnlyPlugins, false)
            pinnedConversationIds = try c.defaulted(.pinnedConversationIds, [])
            approvedCloudPresetIds = try c.defaulted(.approvedCloudPresetIds, [])
            maxConcurrentLlmCalls = try c.defaulted(.maxConcurrentLlmCalls, 3)
            fastReplyMode = try c.defaulted(.fastReplyMode, false)
            quietHours = try c.defaulted(.quietHours, QuietHours())
        }
    }

    var schemaVersion = 2
    var xiaohe = Xiaohe()
    var models: [ModelPreset] = []
    var defaultModels = DefaultModels()
    var conversations: [String: ConversationPolicy] = [:]
    var memory = Memory()
    var runtime = Runtime()

    func preset(_ id: String?) -> ModelPreset? { id.flatMap { id in models.first { $0.id == id } } }

    // 与 settingsV2Schema 的取值约束一致；在写盘或下发前失败，不留下引擎无法读取的文件。
    func validate() throws {
        let invalid = BridgeFault("invalid-configuration")
        guard schemaVersion == 2, Self.identifier(xiaohe.accountId) || xiaohe.accountId.isEmpty else { throw invalid }
        guard xiaohe.mcpUrl.isEmpty || ModelEndpoint.isAddress(xiaohe.mcpUrl) else { throw BridgeFault("invalid-endpoint") }
        for preset in models {
            guard Self.identifier(preset.id), !preset.name.isEmpty, !preset.modelName.isEmpty, preset.maxTokens > 0,
                  (0...2).contains(preset.temperature) else { throw invalid }
            guard ModelEndpoint.isAddress(preset.url) else { throw BridgeFault("invalid-endpoint") }
        }
        let presets = [defaultModels.replyPresetId, defaultModels.fallbackReplyPresetId, defaultModels.pluginPresetId, defaultModels.memoryPresetId,
                       defaultModels.visionPresetId, defaultModels.sttPresetId].compactMap { $0 }
        guard presets.allSatisfy(Self.identifier) else { throw invalid }
        for (key, policy) in conversations {
            guard key == policy.conversationId, Self.identifier(key), policy.riskProfile.takeoverCooldownMinutes > 0,
                  (0...500).contains(policy.backfillOnArmCount), policy.pluginIds.allSatisfy(Self.identifier),
                  policy.replyPresetId.map(Self.identifier) ?? true,
                  policy.triggerKeywords.count <= ConversationPolicy.maxKeywordCount,
                  policy.triggerKeywords.allSatisfy(ConversationPolicy.isValidKeyword),
                  policy.ignoreKeywords.count <= ConversationPolicy.maxKeywordCount,
                  policy.ignoreKeywords.allSatisfy(ConversationPolicy.isValidKeyword),
                  policy.riskProfile.customBlockKeywords.count <= ConversationPolicy.maxKeywordCount,
                  policy.riskProfile.customBlockKeywords.allSatisfy(ConversationPolicy.isValidKeyword) else { throw invalid }
        }
        guard (4...64).contains(memory.workingMaxMessages), (3...240).contains(memory.workingTtlMinutes),
              memory.autoConsolidateIdleMinutes > 0, memory.autoConsolidateTurnThreshold > 0,
              runtime.pinnedConversationIds.count <= 4, runtime.pinnedConversationIds.allSatisfy(Self.identifier),
              runtime.approvedCloudPresetIds.allSatisfy(Self.identifier),
              runtime.maxConcurrentLlmCalls > 0,
              QuietHours.isValidClock(runtime.quietHours.start),
              QuietHours.isValidClock(runtime.quietHours.end) else { throw invalid }
    }

    // 对齐 contracts.ts 的 id：1...2048 个字符且不含控制字符。
    static func identifier(_ value: String) -> Bool {
        (1...2048).contains(value.utf16.count) && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

// MARK: - plugins.ts

enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

enum PluginPermission: String, Codable, CaseIterable, Sendable {
    case readEvents = "read_events", readHistory = "read_history", callModel = "call_model", kvStore = "kv_store"
    case notify, writeOutputFile = "write_output_file", sendWechat = "send_wechat", webhookFetch = "webhook_fetch"
}

enum PluginSinkConfig: Codable, Equatable, Sendable {
    enum MarkdownMode: String, Codable, CaseIterable, Sendable { case append, overwrite }
    enum WebhookPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
        case generic, feishu, wecom, telegram, notion
        var id: String { rawValue }
    }
    case appFeed(id: String, notifyDesktop: Bool)
    case markdownFile(id: String, directory: String?, filenameTemplate: String, mode: MarkdownMode)
    case wechat(id: String, targetConversationId: String, approved: Bool)
    // platform 为 nil 时编码省略，旧配置不产生差异。
    case webhook(id: String, url: String, hasSecret: Bool, platform: WebhookPlatform? = nil)

    var id: String {
        switch self {
        case .appFeed(let id, _), .markdownFile(let id, _, _, _), .wechat(let id, _, _), .webhook(let id, _, _, _): return id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, notifyDesktop, directory, filenameTemplate, mode, targetConversationId, approved, url, hasSecret, platform
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        switch try c.decode(String.self, forKey: .type) {
        case "app_feed": self = .appFeed(id: id, notifyDesktop: try c.decode(Bool.self, forKey: .notifyDesktop))
        case "markdown_file":
            self = .markdownFile(id: id, directory: try c.contains(.directory) ? c.decode(String.self, forKey: .directory) : nil,
                                 filenameTemplate: try c.decode(String.self, forKey: .filenameTemplate),
                                 mode: try c.decode(MarkdownMode.self, forKey: .mode))
        case "wechat":
            self = .wechat(id: id, targetConversationId: try c.decode(String.self, forKey: .targetConversationId),
                           approved: try c.decode(Bool.self, forKey: .approved))
        case "webhook":
            self = .webhook(id: id, url: try c.decode(String.self, forKey: .url), hasSecret: try c.decode(Bool.self, forKey: .hasSecret),
                            platform: try c.contains(.platform) ? c.decode(WebhookPlatform.self, forKey: .platform) : nil)
        default: throw contractError(decoder, "Unknown sink type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch self {
        case .appFeed(_, let notify):
            try c.encode("app_feed", forKey: .type); try c.encode(notify, forKey: .notifyDesktop)
        case .markdownFile(_, let directory, let template, let mode):
            try c.encode("markdown_file", forKey: .type); try c.encodeIfPresent(directory, forKey: .directory)
            try c.encode(template, forKey: .filenameTemplate); try c.encode(mode, forKey: .mode)
        case .wechat(_, let target, let approved):
            try c.encode("wechat", forKey: .type); try c.encode(target, forKey: .targetConversationId)
            try c.encode(approved, forKey: .approved)
        case .webhook(_, let url, let hasSecret, let platform):
            try c.encode("webhook", forKey: .type); try c.encode(url, forKey: .url); try c.encode(hasSecret, forKey: .hasSecret)
            try c.encodeIfPresent(platform, forKey: .platform)
        }
    }
}

enum PluginTrigger: Codable, Equatable, Sendable {
    case realtime(keywords: [String]?, regex: String?, mentionSelfOnly: Bool?)
    case windowTime(cron: String?, everyMinutes: Int?, timesOfDay: [String]?, minMessages: Int)
    case windowCount(count: Int, maxWaitMinutes: Int, minMessages: Int)
    case manualOnly

    private enum CodingKeys: String, CodingKey {
        case type, keywords, regex, mentionSelfOnly, cron, everyMinutes, timesOfDay, minMessages, count, maxWaitMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "realtime":
            self = .realtime(keywords: try c.decodeIfPresent([String].self, forKey: .keywords),
                             regex: try c.decodeIfPresent(String.self, forKey: .regex),
                             mentionSelfOnly: try c.decodeIfPresent(Bool.self, forKey: .mentionSelfOnly))
        case "window_time":
            self = .windowTime(cron: try c.decodeIfPresent(String.self, forKey: .cron),
                               everyMinutes: try c.decodeIfPresent(Int.self, forKey: .everyMinutes),
                               timesOfDay: try c.decodeIfPresent([String].self, forKey: .timesOfDay),
                               minMessages: try c.decode(Int.self, forKey: .minMessages))
        case "window_count":
            self = .windowCount(count: try c.decode(Int.self, forKey: .count),
                                maxWaitMinutes: try c.decode(Int.self, forKey: .maxWaitMinutes),
                                minMessages: try c.decode(Int.self, forKey: .minMessages))
        case "manual_only": self = .manualOnly
        default: throw contractError(decoder, "Unknown trigger type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .realtime(let keywords, let regex, let mentionSelfOnly):
            try c.encode("realtime", forKey: .type); try c.encodeIfPresent(keywords, forKey: .keywords)
            try c.encodeIfPresent(regex, forKey: .regex); try c.encodeIfPresent(mentionSelfOnly, forKey: .mentionSelfOnly)
        case .windowTime(let cron, let everyMinutes, let timesOfDay, let minMessages):
            try c.encode("window_time", forKey: .type); try c.encodeIfPresent(cron, forKey: .cron)
            try c.encodeIfPresent(everyMinutes, forKey: .everyMinutes); try c.encodeIfPresent(timesOfDay, forKey: .timesOfDay)
            try c.encode(minMessages, forKey: .minMessages)
        case .windowCount(let count, let maxWaitMinutes, let minMessages):
            try c.encode("window_count", forKey: .type); try c.encode(count, forKey: .count)
            try c.encode(maxWaitMinutes, forKey: .maxWaitMinutes); try c.encode(minMessages, forKey: .minMessages)
        case .manualOnly: try c.encode("manual_only", forKey: .type)
        }
    }
}

struct DeclarativePluginConfig: Codable, Equatable, Identifiable, Sendable {
    enum BuiltinTemplate: String, Codable, CaseIterable, Sendable {
        case groupDigest = "group-digest", keywordAlert = "keyword-alert", dailyBriefing = "daily-briefing", custom
    }
    enum OutputFormat: String, Codable, CaseIterable, Sendable { case markdown, structuredDigestJSON = "structured_digest_json" }

    struct Scope: Codable, Equatable, Sendable {
        var conversationIds: [String]
        var includeTypes: [ScopeType]? = nil
        var excludeSelf: Bool? = nil
        var kinds: [MessageKind]? = nil
    }

    struct Processor: Codable, Equatable, Sendable {
        var modelPresetId: String?
        var systemPrompt: String
        var userPromptTemplate: String
        var outputFormat: OutputFormat
        var skipWhenNoValue: Bool
        var maxInputChars: Int

        private enum CodingKeys: String, CodingKey {
            case modelPresetId, systemPrompt, userPromptTemplate, outputFormat, skipWhenNoValue, maxInputChars
        }
        init(modelPresetId: String? = nil, systemPrompt: String, userPromptTemplate: String, outputFormat: OutputFormat,
             skipWhenNoValue: Bool, maxInputChars: Int = 24_000) {
            self.modelPresetId = modelPresetId; self.systemPrompt = systemPrompt; self.userPromptTemplate = userPromptTemplate
            self.outputFormat = outputFormat; self.skipWhenNoValue = skipWhenNoValue; self.maxInputChars = maxInputChars
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modelPresetId = try c.contains(.modelPresetId) ? c.decode(String.self, forKey: .modelPresetId) : nil
            systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
            userPromptTemplate = try c.decode(String.self, forKey: .userPromptTemplate)
            outputFormat = try c.decode(OutputFormat.self, forKey: .outputFormat)
            skipWhenNoValue = try c.decode(Bool.self, forKey: .skipWhenNoValue)
            maxInputChars = try c.defaulted(.maxInputChars, 24_000)
        }
    }

    struct RateLimit: Codable, Equatable, Sendable {
        var maxRunsPerHour: Int
        var maxWeChatSendsPerDay: Int

        private enum CodingKeys: String, CodingKey { case maxRunsPerHour, maxWeChatSendsPerDay }
        init(maxRunsPerHour: Int, maxWeChatSendsPerDay: Int = 20) {
            self.maxRunsPerHour = maxRunsPerHour; self.maxWeChatSendsPerDay = maxWeChatSendsPerDay
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            maxRunsPerHour = try c.decode(Int.self, forKey: .maxRunsPerHour)
            maxWeChatSendsPerDay = try c.defaulted(.maxWeChatSendsPerDay, 20)
        }
    }

    var id: String
    var name: String
    var description: String
    var enabled: Bool
    var builtinTemplate: BuiltinTemplate? = nil
    var scope: Scope
    var trigger: PluginTrigger
    var processor: Processor
    var sinks: [PluginSinkConfig]
    var rateLimit: RateLimit
}

struct PluginManifest: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var version: String
    var entry: String
    var permissions: [PluginPermission]
    var configSchema: [String: JSONValue]? = nil
}

// MARK: - ipc.ts 运行时状态

struct SessionReceipt: Codable, Equatable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable { case trying, submitted, unknown, rejected }
    enum Delivery: String, Codable, CaseIterable, Sendable { case delivered, failed, unknown }
    var status: Status
    var delivery: Delivery
    var operationId: String? = nil
}

struct SessionRuntimeState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, CaseIterable, Sendable {
        case idle, connecting, listening, retrying, generating, scheduled, checking, sending, paused, cooldown
        case blockedUnknown = "blocked-unknown", lockedOptOut = "locked-opt-out"
    }
    var phase: Phase
    var replyMode: SessionReplyMode
    var reason: IPCErrorCode? = nil
    var draft: String? = nil
    var scheduledAt: Int64? = nil
    var cooldownUntil: Int64? = nil
    var receipt: SessionReceipt? = nil
}

enum PluginKind: String, Codable, CaseIterable, Sendable { case declarative, module }

struct PluginRuntimeState: Codable, Equatable, Sendable {
    var kind: PluginKind
    var enabled: Bool
    var approvedPermissions: [PluginPermission]
    var manifestHash: String? = nil
    var consecutiveFailures: Int
    var circuitOpen: Bool
    var lastRunAt: Int64? = nil
    var lastError: IPCErrorCode? = nil
}

struct FeedItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case pluginDigest = "plugin_digest", personaProposal = "persona_proposal", memoryUpdated = "memory_updated"
        case alert, scheduleCancelled = "schedule_cancelled"
    }
    var id: String
    var kind: Kind
    var title: String
    var body: String
    var conversationId: String? = nil
    var pluginId: String? = nil
    var refPath: String? = nil
    var createdAt: Int64
    var read: Bool
}

struct PersonaProposal: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable { case pending, accepted, rejected, superseded }
    var proposalId: String
    var status: Status
    var filePath: String
    var sampleCount: Int
    var summary: String
    var createdAt: Int64
    var decidedAt: Int64? = nil
    var id: String { proposalId }

    private enum CodingKeys: String, CodingKey { case proposalId, status, filePath, sampleCount, summary, createdAt, decidedAt }
}

enum GlobalPhase: String, Codable, CaseIterable, Sendable { case idle, connecting, running, paused, error }

struct GlobalRuntimeState: Codable, Equatable, Sendable {
    var phase: GlobalPhase
    var activeAutoCount: Int
    var activePluginCount: Int
    var inFlightCount: Int
    var error: IPCErrorCode? = nil
}

struct SessionTraceEntry: Codable, Equatable, Identifiable, Sendable {
    enum Stage: String, Codable, CaseIterable, Sendable { case inbound, policy, model, send, state }
    enum Level: String, Codable, CaseIterable, Sendable { case info, warn, error }
    var id: String
    var conversationId: String
    var at: Int64
    var stage: Stage
    var level: Level
    var summary: String
    var detail: String? = nil
}

struct HealthCheckStep: Codable, Equatable, Identifiable, Sendable {
    enum StepID: String, Codable, CaseIterable, Sendable { case xiaohe, whitelist, credentials, model }
    var id: StepID
    var label: String
    var ok: Bool
    var durationMs: Int
    var detail: String
}

// system.bundles 的结果，逐字对齐 Engine ipc.ts。
struct HotBundleItem: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var sha256: String
    var verified: Bool
}

struct HotBundlesStatus: Codable, Equatable, Sendable {
    var loadedCount: Int
    var version: String? = nil
    var lastReloadAt: Int64? = nil
    var items: [HotBundleItem]
}

// system.bundles 的 action；sync 只接受 HTTPS 清单，并由引擎用内置官方 Ed25519 公钥强制验签。
enum HotBundlesAction: String, Codable, CaseIterable, Sendable { case status, reload, sync, reset }

// plugins.testWebhook 的结果，逐字对齐 Engine ipc.ts。
struct WebhookTestResult: Codable, Equatable, Sendable {
    var ok: Bool
    var statusCode: Int? = nil
    var detail: String
}

struct HealthCheckResult: Codable, Equatable, Sendable {
    var ok: Bool
    var steps: [HealthCheckStep]
}

struct SystemStatus: Codable, Equatable, Sendable {
    var capabilities: XiaoheCapabilities
    var globalPhase: GlobalPhase
    var sessions: [String: SessionRuntimeState]
    var plugins: [String: PluginRuntimeState]
    var unreadFeedCount: Int
    var pendingProposalCount: Int
}

// MARK: - Push topics

enum PushTopic: String, Codable, CaseIterable, Sendable {
    case hello, sessionUpdated = "session.updated", globalUpdated = "global.updated", feedAdded = "feed.added"
    case pluginUpdated = "plugin.updated", proposalUpdated = "proposal.updated", backfillProgress = "backfill.progress"
    case sessionTrace = "session.trace"
}

struct HelloPayload: Codable, Equatable, Sendable {
    var status: SystemStatus
    private enum CodingKeys: String, CodingKey { case v }
    init(status: SystemStatus) { self.status = status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .v) == IPCv3.version else { throw contractError(decoder, "Wrong IPC version") }
        status = try SystemStatus(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try status.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(IPCv3.version, forKey: .v)
    }
}

struct SessionUpdate: Codable, Equatable, Sendable { var conversationId: String; var status: SessionRuntimeState }
struct FeedAdded: Codable, Equatable, Sendable { var item: FeedItem; var notifyDesktop: Bool }
struct PluginUpdate: Codable, Equatable, Sendable { var pluginId: String; var state: PluginRuntimeState }
struct ProposalUpdate: Codable, Equatable, Sendable { var pendingCount: Int; var latestProposal: PersonaProposal? = nil }
private struct SessionTracePayload: Codable { var entry: SessionTraceEntry }

enum PushEvent: Codable, Equatable, Sendable {
    case hello(HelloPayload)
    case sessionUpdated(SessionUpdate)
    case globalUpdated(GlobalRuntimeState)
    case feedAdded(FeedAdded)
    case pluginUpdated(PluginUpdate)
    case proposalUpdated(ProposalUpdate)
    case backfillProgress(BackfillProgress)
    case sessionTrace(SessionTraceEntry)

    private enum CodingKeys: String, CodingKey { case v, kind, topic, payload }

    var topic: PushTopic {
        switch self {
        case .hello: return .hello
        case .sessionUpdated: return .sessionUpdated
        case .globalUpdated: return .globalUpdated
        case .feedAdded: return .feedAdded
        case .pluginUpdated: return .pluginUpdated
        case .proposalUpdated: return .proposalUpdated
        case .backfillProgress: return .backfillProgress
        case .sessionTrace: return .sessionTrace
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .v) == IPCv3.version, try c.decode(String.self, forKey: .kind) == "event" else {
            throw contractError(decoder, "Not a v3 event")
        }
        switch try c.decode(PushTopic.self, forKey: .topic) {
        case .hello: self = .hello(try c.decode(HelloPayload.self, forKey: .payload))
        case .sessionUpdated: self = .sessionUpdated(try c.decode(SessionUpdate.self, forKey: .payload))
        case .globalUpdated: self = .globalUpdated(try c.decode(GlobalRuntimeState.self, forKey: .payload))
        case .feedAdded: self = .feedAdded(try c.decode(FeedAdded.self, forKey: .payload))
        case .pluginUpdated: self = .pluginUpdated(try c.decode(PluginUpdate.self, forKey: .payload))
        case .proposalUpdated: self = .proposalUpdated(try c.decode(ProposalUpdate.self, forKey: .payload))
        case .backfillProgress: self = .backfillProgress(try c.decode(BackfillProgress.self, forKey: .payload))
        case .sessionTrace: self = .sessionTrace(try c.decode(SessionTracePayload.self, forKey: .payload).entry)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(IPCv3.version, forKey: .v)
        try c.encode("event", forKey: .kind)
        try c.encode(topic, forKey: .topic)
        switch self {
        case .hello(let payload): try c.encode(payload, forKey: .payload)
        case .sessionUpdated(let payload): try c.encode(payload, forKey: .payload)
        case .globalUpdated(let payload): try c.encode(payload, forKey: .payload)
        case .feedAdded(let payload): try c.encode(payload, forKey: .payload)
        case .pluginUpdated(let payload): try c.encode(payload, forKey: .payload)
        case .proposalUpdated(let payload): try c.encode(payload, forKey: .payload)
        case .backfillProgress(let payload): try c.encode(payload, forKey: .payload)
        case .sessionTrace(let entry): try c.encode(SessionTracePayload(entry: entry), forKey: .payload)
        }
    }
}

// MARK: - RPC 结果

struct IPCAck: Codable, Equatable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {
        guard try decoder.singleValueContainer().decode(Bool.self) else { throw contractError(decoder, "Expected literal true") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(true)
    }
}

struct IPCPage<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var items: [Item]
    var nextCursor: String?

    private enum CodingKeys: String, CodingKey { case items, nextCursor }

    init(items: [Item], nextCursor: String?) { self.items = items; self.nextCursor = nextCursor }

    // nullable 字段必须存在，且编码时写出 null。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([Item].self, forKey: .items)
        nextCursor = try c.decode(String?.self, forKey: .nextCursor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encode(nextCursor, forKey: .nextCursor)
    }
}

struct XiaoheAccountOption: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var canRead: Bool
    var canSend: Bool
    var sendConversations: [String]? = nil

    // 小禾提供白名单时按白名单判断（"*" 表示放行全部会话）；未提供时退回账号级发信权限。
    func maySend(to conversationId: String) -> Bool {
        guard canSend else { return false }
        guard let list = sendConversations else { return true }
        return list.contains("*") || list.contains(conversationId)
    }
}

struct XiaoheConversation: Codable, Equatable, Identifiable, Sendable {
    var conversationId: String
    var type: ScopeType
    var displayName: String
    var nickname: String? = nil
    var remark: String? = nil
    var isSticky: Bool? = nil
    var id: String { conversationId }

    private enum CodingKeys: String, CodingKey { case conversationId, type, displayName, nickname, remark, isSticky }
}

struct XiaoheConversationPage: Codable, Equatable, Sendable {
    var items: [XiaoheConversation]
    var nextCursor: String?
    var syncStatus: String?

    private enum CodingKeys: String, CodingKey { case items, nextCursor, syncStatus }

    init(items: [XiaoheConversation], nextCursor: String?, syncStatus: String? = nil) {
        self.items = items; self.nextCursor = nextCursor; self.syncStatus = syncStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([XiaoheConversation].self, forKey: .items)
        nextCursor = try c.decode(String?.self, forKey: .nextCursor)
        syncStatus = try c.contains(.syncStatus) ? c.decode(String.self, forKey: .syncStatus) : nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encode(nextCursor, forKey: .nextCursor)
        try c.encodeIfPresent(syncStatus, forKey: .syncStatus)
    }
}

struct GroupMember: Codable, Equatable, Identifiable, Sendable {
    var userId: String
    var displayName: String
    var id: String { userId }
    private enum CodingKeys: String, CodingKey { case userId, displayName }
}

struct ModelPreviewResult: Codable, Equatable, Sendable {
    enum Action: String, Codable, CaseIterable, Sendable { case reply, skip, manual, stop, identity }
    var action: Action
    var text: String? = nil
}

struct PolicyEvaluateStep: Codable, Equatable, Identifiable, Sendable {
    enum Stage: String, Codable, CaseIterable, Sendable {
        case ironRule = "iron_rule"
        case quietHours = "quiet_hours"
        case keywords
        case riskRules = "risk_rules"
        case verdict
    }
    enum Outcome: String, Codable, CaseIterable, Sendable { case pass, hit, skip }
    var stage: Stage
    var title: String
    var outcome: Outcome
    var detail: String
    var id: String { stage.rawValue }

    private enum CodingKeys: String, CodingKey { case stage, title, outcome, detail }
}

struct PolicyEvaluateResult: Codable, Equatable, Sendable {
    enum FinalAction: String, Codable, CaseIterable, Sendable {
        case allow
        case skipTurn = "skip_turn"
        case draftOnly = "draft_only"
        case pauseSession = "pause_session"
        case lockPeer = "lock_peer"
        case identity
    }
    var steps: [PolicyEvaluateStep]
    var finalAction: FinalAction
    var matchedRule: String? = nil
}

struct BackfillJob: Codable, Equatable, Sendable { var jobId: String }
struct SessionTraceList: Codable, Equatable, Sendable { var items: [SessionTraceEntry] }
struct PluginRunStart: Codable, Equatable, Sendable { var runId: String }

enum PluginListItem: Codable, Equatable, Identifiable, Sendable {
    case declarative(pluginId: String, config: DeclarativePluginConfig, state: PluginRuntimeState)
    case module(pluginId: String, manifest: PluginManifest, state: PluginRuntimeState)

    private enum CodingKeys: String, CodingKey { case pluginId, kind, config, manifest, state }

    var id: String { pluginId }
    var pluginId: String {
        switch self { case .declarative(let id, _, _), .module(let id, _, _): return id }
    }
    var state: PluginRuntimeState {
        get { switch self { case .declarative(_, _, let state), .module(_, _, let state): return state } }
        set {
            switch self {
            case .declarative(let id, let config, _): self = .declarative(pluginId: id, config: config, state: newValue)
            case .module(let id, let manifest, _): self = .module(pluginId: id, manifest: manifest, state: newValue)
            }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .pluginId)
        let state = try c.decode(PluginRuntimeState.self, forKey: .state)
        switch try c.decode(PluginKind.self, forKey: .kind) {
        case .declarative: self = .declarative(pluginId: id, config: try c.decode(DeclarativePluginConfig.self, forKey: .config), state: state)
        case .module: self = .module(pluginId: id, manifest: try c.decode(PluginManifest.self, forKey: .manifest), state: state)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pluginId, forKey: .pluginId)
        try c.encode(state, forKey: .state)
        switch self {
        case .declarative(_, let config, _):
            try c.encode(PluginKind.declarative, forKey: .kind); try c.encode(config, forKey: .config)
        case .module(_, let manifest, _):
            try c.encode(PluginKind.module, forKey: .kind); try c.encode(manifest, forKey: .manifest)
        }
    }
}

struct PluginRun: Codable, Equatable, Identifiable, Sendable {
    enum TriggerKind: String, Codable, CaseIterable, Sendable { case realtime, windowTime = "window_time", windowCount = "window_count", manual }
    enum Status: String, Codable, CaseIterable, Sendable { case running, ok, skipped, error }
    var pluginId: String
    var runId: String
    var triggerKind: TriggerKind
    var startedAt: Int64
    var finishedAt: Int64? = nil
    var status: Status
    var itemCount: Int
    var summaryPreview: String? = nil
    var outputPaths: [String]? = nil
    var errorCode: IPCErrorCode? = nil
    var id: String { runId }

    private enum CodingKeys: String, CodingKey {
        case pluginId, runId, triggerKind, startedAt, finishedAt, status, itemCount, summaryPreview, outputPaths, errorCode
    }
}

enum MemoryTarget: Codable, Hashable, Sendable {
    case persona
    case scope(conversationId: String)

    private enum CodingKeys: String, CodingKey { case kind, conversationId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "persona": self = .persona
        case "scope": self = .scope(conversationId: try c.decode(String.self, forKey: .conversationId))
        default: throw contractError(decoder, "Unknown memory target")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .persona: try c.encode("persona", forKey: .kind)
        case .scope(let id):
            try c.encode("scope", forKey: .kind); try c.encode(id, forKey: .conversationId)
        }
    }
}

// 文本不超过 64 KiB 时内联；更长的文档只传路径。
struct MemoryContent: Codable, Equatable, Sendable {
    var text: String?
    var path: String?

    private enum CodingKeys: String, CodingKey { case text, path }

    init(text: String, path: String? = nil) { self.text = text; self.path = path }
    init(path: String) { self.text = nil; self.path = path }

    var isValid: Bool {
        if let text { return text.utf8.count <= IPCv3.maxInlineDocumentBytes }
        return path != nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        guard isValid else { throw contractError(decoder, "Invalid memory content") }
    }
}

enum MemoryVisibility: String, Codable, CaseIterable, Sendable { case localOnly = "local-only", cloudSafe = "cloud-safe" }

struct MemoryRevision: Codable, Equatable, Identifiable, Sendable {
    enum TargetKind: String, Codable, CaseIterable, Sendable { case persona, scope }
    enum Source: String, Codable, CaseIterable, Sendable {
        case auto, backfill, proposalAccepted = "proposal_accepted", manual, rollback
    }
    var revId: String
    var targetKind: TargetKind
    var scopeKey: String
    var snapshotPath: String
    var source: Source
    var summary: String
    var diffPreview: String
    var createdAt: Int64
    var id: String { revId }

    private enum CodingKeys: String, CodingKey {
        case revId, targetKind, scopeKey, snapshotPath, source, summary, diffPreview, createdAt
    }
}

// MARK: - RPC 方法与参数

enum RPCMethod: String, Codable, CaseIterable, Sendable {
    case systemStatus = "system.status", systemPauseAll = "system.pauseAll", systemHealthCheck = "system.healthCheck"
    case systemBundles = "system.bundles"
    case xiaoheAccounts = "xiaohe.accounts", xiaoheConversations = "xiaohe.conversations"
    case xiaoheGroupMembers = "xiaohe.groupMembers", xiaoheCapabilities = "xiaohe.capabilities"
    case settingsApply = "settings.apply", modelPreview = "model.preview", policyEvaluate = "policy.evaluate"
    case sessionArm = "session.arm", sessionPause = "session.pause", sessionSendOneShot = "session.sendOneShot"
    case sessionRefreshReceipt = "session.refreshReceipt", sessionRecover = "session.recover", sessionBackfill = "session.backfill"
    case sessionTraces = "session.traces", sessionResumeCooldown = "session.resumeCooldown"
    case pluginsList = "plugins.list", pluginsSaveDeclarative = "plugins.saveDeclarative"
    case pluginsDeleteDeclarative = "plugins.deleteDeclarative", pluginsSetEnabled = "plugins.setEnabled"
    case pluginsRunNow = "plugins.runNow", pluginsRuns = "plugins.runs", pluginsTestWebhook = "plugins.testWebhook"
    case memoryGet = "memory.get", memorySave = "memory.save", memorySetEntryLock = "memory.setEntryLock"
    case memorySetEntryVisibility = "memory.setEntryVisibility", memoryConsolidateNow = "memory.consolidateNow"
    case memoryRevisions = "memory.revisions", memoryRollback = "memory.rollback"
    case personaProposals = "persona.proposals", personaDecide = "persona.decide"
    case feedList = "feed.list", feedMarkRead = "feed.markRead"
}

enum PauseScope: String, Codable, CaseIterable, Sendable { case sendingOnly = "sending_only", all }
enum ArmReplyMode: String, Codable, CaseIterable, Sendable { case draft, auto }
enum SessionRecoverAction: String, Codable, CaseIterable, Sendable {
    case resetRead = "reset-read", restoreConsent = "restore-consent", acknowledge
}

// model.preview 使用 Engine/contracts.ts 的 modelSchema；apiKey 只在内存和 IPC 帧中出现。
struct PreviewModel: Encodable, Equatable, Sendable {
    var mode: ModelMode
    var url: String
    var name: String
    var stylePath: String
    var memoryPath: String
    var cloudApproved: Bool
    var apiKey: String? = nil
    var reasoningEffort: ReasoningEffort? = nil
}

struct TimeRange: Codable, Equatable, Sendable { var startTime: Int64; var endTime: Int64 }

enum PersonaDecision: Encodable, Equatable, Sendable {
    case accept(proposalId: String)
    case reject(proposalId: String)
    case acceptEdited(proposalId: String, content: MemoryContent)

    private enum CodingKeys: String, CodingKey { case proposalId, decision, content }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accept(let id): try c.encode(id, forKey: .proposalId); try c.encode("accept", forKey: .decision)
        case .reject(let id): try c.encode(id, forKey: .proposalId); try c.encode("reject", forKey: .decision)
        case .acceptEdited(let id, let content):
            try c.encode(id, forKey: .proposalId); try c.encode("accept_edited", forKey: .decision)
            try c.encode(content, forKey: .content)
        }
    }
}

enum BackfillCommand: Encodable, Equatable, Sendable {
    case start(BackfillRequest)
    case cancel(jobId: String)

    private enum CodingKeys: String, CodingKey { case action, request, jobId }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start(let request): try c.encode("start", forKey: .action); try c.encode(request, forKey: .request)
        case .cancel(let id): try c.encode("cancel", forKey: .action); try c.encode(id, forKey: .jobId)
        }
    }
}

enum RPCParams {
    struct Empty: Encodable {
        func encode(to encoder: Encoder) throws { _ = encoder.container(keyedBy: IPCCodingKey.self) }
    }
    struct PauseAll: Encodable { let scope: PauseScope; let reason: IPCErrorCode }
    struct Bundles: Encodable {
        let action: HotBundlesAction
        var manifestUrl: String? = nil
    }
    struct Accounts: Encodable { var mcpUrl: String? = nil }
    struct Conversations: Encodable {
        var accountId: String? = nil
        var query: String? = nil
        var type: ScopeType? = nil
        var cursor: String? = nil
        var limit: Int? = nil
    }
    struct Session: Encodable { let conversationId: String }
    struct ApplySettings: Encodable {
        let settings: SettingsV2
        var cloudApiKeys: [String: String]? = nil
    }
    struct Preview: Encodable { let model: PreviewModel; let text: String }
    struct PolicyEvaluate: Encodable {
        let text: String
        let policy: ConversationPolicy
        var quietHours: SettingsV2.QuietHours? = nil
        var mentionsSelf: Bool = false
        var inQuietHours: Bool? = nil
    }
    struct Arm: Encodable {
        let conversationId: String
        let replyMode: ArmReplyMode
        let consent = true
        var cloudApproved: Bool? = nil
        var groupConfirmed: Bool? = nil
        var apiKey: String? = nil
    }
    struct PauseSession: Encodable { let conversationId: String; var reason: IPCErrorCode? = nil }
    struct SendOneShot: Encodable {
        let conversationId: String
        let text: String
        let request: String
        var at: Int64? = nil
        let consent = true
        var groupConfirmed: Bool? = nil
    }
    struct Recover: Encodable {
        let conversationId: String
        let action: SessionRecoverAction
        let confirmed = true
    }
    struct SessionTraces: Encodable {
        let conversationId: String
        var limit: Int? = nil
    }
    struct HealthCheck: Encodable {
        var presetId: String? = nil
        var conversationId: String? = nil
    }
    struct SaveDeclarative: Encodable { let config: DeclarativePluginConfig }
    struct Plugin: Encodable { let pluginId: String }
    struct SetEnabled: Encodable {
        let pluginId: String
        let enabled: Bool
        var approvedPermissions: [PluginPermission]? = nil
        var manifestHash: String? = nil
    }
    struct RunNow: Encodable {
        let pluginId: String
        var conversationId: String? = nil
        var range: TimeRange? = nil
    }
    // secret 只在内存和 IPC 帧中出现；留空时引擎读取 pluginId/sinkId 对应的已存密钥。
    struct TestWebhook: Encodable {
        let pluginId: String
        let sinkId: String
        let url: String
        var platform: PluginSinkConfig.WebhookPlatform? = nil
        var secret: String? = nil
    }
    struct PluginRuns: Encodable {
        let pluginId: String
        var cursor: String? = nil
        var limit: Int? = nil
    }
    struct Memory: Encodable { let target: MemoryTarget }
    struct SaveMemory: Encodable { let target: MemoryTarget; let content: MemoryContent }
    struct EntryLock: Encodable { let target: MemoryTarget; let entryId: String; let locked: Bool }
    struct EntryVisibility: Encodable { let target: MemoryTarget; let entryId: String; let visibility: MemoryVisibility }
    struct Consolidate: Encodable { let conversationId: String; var backfill: BackfillRequest? = nil }
    struct Revisions: Encodable {
        let target: MemoryTarget
        var cursor: String? = nil
        var limit: Int? = nil
    }
    struct Rollback: Encodable { let target: MemoryTarget; let revId: String }
    struct Page: Encodable {
        var cursor: String? = nil
        var limit: Int? = nil
    }
    struct FeedList: Encodable {
        var cursor: String? = nil
        var limit: Int? = nil
        var unreadOnly: Bool? = nil
    }
    struct MarkRead: Encodable { let ids: [String] }
}

struct IPCReply<Result: Codable>: Codable {
    enum Outcome {
        case success(Result)
        case failure(IPCErrorCode)
    }
    let id: Int
    let outcome: Outcome

    private enum CodingKeys: String, CodingKey { case v, kind, id, ok, result, code }

    init(id: Int, outcome: Outcome) { self.id = id; self.outcome = outcome }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .v) == IPCv3.version, try c.decode(String.self, forKey: .kind) == "reply" else {
            throw contractError(decoder, "Not a v3 reply")
        }
        id = try c.decode(Int.self, forKey: .id)
        outcome = try c.decode(Bool.self, forKey: .ok)
            ? .success(try c.decode(Result.self, forKey: .result))
            : .failure(try c.decode(IPCErrorCode.self, forKey: .code))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(IPCv3.version, forKey: .v)
        try c.encode("reply", forKey: .kind)
        try c.encode(id, forKey: .id)
        switch outcome {
        case .success(let value): try c.encode(true, forKey: .ok); try c.encode(value, forKey: .result)
        case .failure(let code): try c.encode(false, forKey: .ok); try c.encode(code, forKey: .code)
        }
    }
}
