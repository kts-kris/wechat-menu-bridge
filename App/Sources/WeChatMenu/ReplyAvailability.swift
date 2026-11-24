import Foundation

// The same gate is used for the actual action and for its visible explanation.
// It does not grant permission or consult the model, keychain, or network.
enum BeginBlocker: Equatable {
    case backend, running, inFlight, uncertain, peerStopped, authorizing, savingSettings

    static func evaluate(ready: Bool, state: EngineState, authorizing: Bool, savingSettings: Bool) -> Self? {
        if !ready { return .backend }
        if state.peerStopped { return .peerStopped }
        if state.uncertain { return .uncertain }
        if state.inFlight { return .inFlight }
        if savingSettings { return .savingSettings }
        if authorizing { return .authorizing }
        if state.running { return .running }
        return nil
    }

    var guidance: String {
        switch self {
        case .backend: return "后台尚未就绪，请稍候；如后台已退出，请点“重启后台”。"
        case .running: return "已有任务运行中，请先暂停，再开启自动回复。"
        case .inFlight: return "上一条提交尚未返回，请等待结果后再开启。"
        case .uncertain: return "上次提交结果未知，请先在微信核对，再解除阻塞。"
        case .peerStopped: return "对方已要求停止，只有确认对方重新同意后才能恢复。"
        case .authorizing: return "正在准备另一项操作，请稍候。"
        case .savingSettings: return "设置正在保存，请稍候。"
        }
    }
}

enum ReplyBlocker: Equatable {
    case begin(BeginBlocker), target, model, read(String)

    static let blockedRead: Set<String> = ["event-gap", "wechat-changed", "mcp-contract", "wrong-anchor", "backlog-limit"]

    static func evaluate(begin: BeginBlocker?, configuration: Configuration, reason: String?) -> Self? {
        if let begin { return .begin(begin) }
        if configuration.target == nil { return .target }
        if !configuration.modelComplete { return .model }
        if let reason, blockedRead.contains(reason) { return .read(reason) }
        return nil
    }

    var guidance: String {
        switch self {
        case .begin(let blocker): return blocker.guidance
        case .target: return "请在设置中检查小禾地址，并选定账号和一个私聊。"
        case .model: return "请在设置中填写有效的模型地址和模型名。手写单条不需要模型。"
        case .read(let reason): return explanation(reason)
        }
    }
}
