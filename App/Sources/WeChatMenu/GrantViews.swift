import SwiftUI

struct ReplyConsentView: View {
    let mode: ReplyMode
    let value: Configuration
    let canStart: Bool
    let cancel: () -> Void
    let confirm: (Bool, Bool) -> Void
    @State private var agreed = false
    @State private var cloud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(mode == .automatic ? "确认开启自动回复" : "确认开启只拟稿").font(.headline)
            ScopeLabel(value: value)
            if mode == .draft {
                Notice(text: "只用新来信生成临时草稿，不发送。")
            } else {
                Notice(text: "确认后，新的普通闲聊不用逐条确认。识别到承诺、隐私、拿不准的内容、本人发信或对方叫停时会暂停。")
                Notice(text: "可能漏判；检查后收到的叫停可能来不及阻止本次提交，已发出的请求无法撤回。", important: true)
            }
            Toggle(isOn: $agreed) {
                Text(mode == .automatic ? "我确认对方知道普通闲聊会由模型代回，并同意。" : "我确认对方知道这里会用模型拟稿，并同意。")
                    .fixedSize(horizontal: false, vertical: true)
            }.toggleStyle(.checkbox).accessibilityIdentifier("peer-consent")
            if value.mode == .cloud, let endpoint = value.modelEndpoint {
                Text(endpoint).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Toggle(isOn: $cloud) {
                    Text("我同意把必要文字、少量临时上下文和已标记的脱敏片段发给以上端点。")
                        .fixedSize(horizontal: false, vertical: true)
                }.toggleStyle(.checkbox).accessibilityIdentifier("cloud-consent")
            }
            HStack {
                Spacer()
                Button("取消", action: cancel)
                Button("确认开启") { confirm(agreed, cloud) }.buttonStyle(.borderedProminent)
                    .disabled(!canStart || !agreed || (value.mode == .cloud && !cloud))
            }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// A new composer owns a fresh session; a task from a closed window cannot
// dismiss a new composer or submit after its approval was invalidated.
@MainActor final class ComposeSession: ObservableObject {
    let revision: Int
    @Published var busy = false
    private(set) var closed = false

    init(revision: Int) { self.revision = revision }

    func close(using store: AppStore) {
        closed = true
        if busy && revision == store.sleepRevision { store.pause() }
    }
}

struct ComposeView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ComposeSession
    let reviewed: Configuration
    let dismiss: () -> Void
    @State private var text = ""
    @State private var at = Date.now.addingTimeInterval(120)
    @State private var scheduled = false
    @State private var consent = false
    @State private var confirmation = false
    @State private var fault: String?

    private var busy: Bool { session.busy }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var acceptable: Bool {
        !trimmed.isEmpty && trimmed.utf16.count <= 500 && !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) &&
            (!scheduled || (at > .now && at < nextMidnight()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("一次主动发送").font(.title2.weight(.semibold))
            ScopeLabel(value: reviewed)
            Notice(text: "只提交你确认的这一条。不开启自动回，不追发。休眠、退出或未能核验权限时取消。")
            Notice(text: "检查后收到的叫停可能来不及阻止本次提交；已发出的请求无法撤回。", important: true)
            TextField("输入一条纯文字", text: $text, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder).accessibilityLabel("将发送的消息")
                .accessibilityIdentifier("compose-text")
                .disabled(confirmation || busy)
            Toggle("今天定时发送", isOn: $scheduled).accessibilityIdentifier("scheduled-once").disabled(confirmation || busy)
            if scheduled {
                DatePicker("时间", selection: $at, displayedComponents: [.hourAndMinute]).disabled(confirmation || busy)
                    .onChange(of: at) { changed in
                        let cal = Calendar.autoupdatingCurrent
                        let t = cal.dateComponents([.hour, .minute], from: changed)
                        if let h = t.hour, let m = t.minute, let value = cal.date(bySettingHour: h, minute: m, second: 0, of: .now), value != changed { at = value }
                    }
                Text("必须是今天尚未到的时间。保留 App 运行、Mac 清醒、微信登录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("我确认这是知情且同意接收的指定联系人。", isOn: $consent)
                .accessibilityIdentifier("one-shot-consent").disabled(confirmation || busy)
            if confirmation { Notice(text: "将向 \(reviewed.contact?.label ?? "该联系人")\(scheduled ? "于 \(at.formatted(date: .omitted, time: .shortened))" : "现在")提交上方文字。", important: true) }
            if let fault { Notice(text: explanation(fault), important: true) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(busy ? "暂停" : confirmation ? "返回编辑" : "取消") {
                    if confirmation && !busy { confirmation = false }
                    else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button(confirmation ? "确认单次发送" : "核对内容…") {
                    if confirmation { send() } else { confirmation = true }
                }.buttonStyle(.borderedProminent)
                    .disabled(busy || !consent || !acceptable || reviewed != store.configuration || !store.canBegin)
            }
        }.padding(20).frame(width: 450)
            .onChange(of: store.sleepRevision) { _ in dismiss() }
            .onChange(of: store.configuration) { _ in dismiss() }
    }

    private func send() {
        let value = trimmed, date = scheduled ? at : nil
        session.busy = true; fault = nil
        Task { @MainActor in
            guard !session.closed, session.revision == store.sleepRevision else { return }
            defer { session.busy = false }
            do {
                try await store.send(value, at: date, confirmed: reviewed)
                if !session.closed { session.busy = false; dismiss() }
            } catch {
                if !session.closed { fault = (error as? BridgeFault)?.code ?? "internal-error" }
            }
        }
    }
}

private struct ScopeLabel: View {
    let value: Configuration
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.contact?.label ?? "未绑定联系人").font(.headline)
            Text("账号：\(value.accountLabel) · 私聊尾号 …\(value.contact?.id.suffix(7) ?? "")")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
