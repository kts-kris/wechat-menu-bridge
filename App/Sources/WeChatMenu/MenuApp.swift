import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
@MainActor
enum WeChatMenuBridgeApp {
    static func main() {
        let app = NSApplication.shared
        let entry = BridgeEntry()
        app.delegate = entry
        withExtendedLifetime(entry) { app.run() }
    }
}

@MainActor private final class BridgeEntry: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private let workspace = V2Workspace()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var statusUpdates: AnyCancellable?
    private var readyUpdates: AnyCancellable?
    private var controls: NSWindow?
    private var panelMonitors: [Any] = []
    private var statusRightClick: Any?
    private var forceCloseControls = false

    private var engineExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bridge-engine")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        workspace.presentConsole = { [weak self] in self?.showControls() }
        if Bundle.main.bundleURL.pathExtension == "app" && !NativeQA.active {
            UNUserNotificationCenter.current().delegate = self
        }
        startBackend()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "WeChatBridge"
        statusItem = item
        popover.delegate = self
        if #available(macOS 27.0, *) {
            // 生命周期交给展开会话，避免 .transient 与会话重复关闭。
            popover.behavior = .applicationDefined
            item.expandedInterfaceDelegate = self
        } else {
            popover.behavior = .transient
        }
        statusRightClick = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
            guard let self, let window = self.statusItem?.button?.window, event.window === window else { return event }
            self.showControls()
            return nil
        }
        if let button = item.button {
            // Distinguish the disposable copy when macOS hosts status items in
            // a system process shared with other apps and the installed bridge.
            let qaID = NativeQA.home == nil ? nil : Bundle.main.bundleIdentifier
            button.setAccessibilityIdentifier(qaID.map { "bridge-status-\($0)" } ?? "bridge-status")
            if #unavailable(macOS 27.0) {
                button.target = self
                button.action = #selector(togglePanel(_:))
            }
            statusUpdates = Publishers.CombineLatest3(workspace.runtime.$globalPhase, workspace.sessions.$sessions, workspace.plugins.$states)
                .sink { [weak self, weak button] phase, sessions, plugins in
                    guard let self else { return }
                    let counts = RuntimeCounts(global: self.workspace.runtime.global, sessions: sessions, plugins: plugins)
                    let active = counts.activeAuto > 0 || counts.activePlugins > 0 || phase == .running
                    let summary = counts.activeAuto > 0 ? "自动回复 \(counts.activeAuto)" :
                        counts.activePlugins > 0 ? "插件 \(counts.activePlugins)" :
                        self.workspace.runtime.ready ? "未开启" : "后台未就绪"
                    let label = "\(qaID.map { "微信桥验收 \($0)" } ?? "微信桥") · \(summary)"
                    let symbol = active ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
                    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                    image?.isTemplate = true
                    button?.image = image
                    button?.toolTip = label
                    button?.setAccessibilityLabel(label)
                }
        }
        if ProcessInfo.processInfo.arguments.contains("--controls") {
            // Window ordering happens after AppKit has processed its launch event.
            DispatchQueue.main.async { self.showControls() }
        }
        if let home = NativeQA.home, home.lastPathComponent == "home-first" { diagnose(home, attempts: 100) }
        Task { await workspace.checkForUpdatesIfDue() }
    }

    private func startBackend() {
        workspace.runtime.startObservingSystemEvents()
        readyUpdates = workspace.runtime.$ready.removeDuplicates().sink { [weak self] ready in
            guard let self, ready else { return }
            Task { await self.workspace.refreshAll() }
        }
        do {
            if NativeQA.active && NativeQA.home == nil { throw BridgeFault("storage-unavailable") }
            try workspace.loadSettings()
            try workspace.runtime.start(engine: engineExecutable, directory: SettingsV2Disk.standard.directory)
        } catch {
            workspace.capture(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspace.runtime.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showControls()
        return false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let feedId = info["feedId"] as? String
        let kind = info["kind"] as? String
        let conversationId = info["conversationId"] as? String
        let pluginId = info["pluginId"] as? String
        Task { @MainActor [weak self] in
            var forwarded: [AnyHashable: Any] = [:]
            if let feedId { forwarded["feedId"] = feedId }
            if let kind { forwarded["kind"] = kind }
            if let conversationId { forwarded["conversationId"] = conversationId }
            if let pluginId { forwarded["pluginId"] = pluginId }
            self?.workspace.openNotification(userInfo: forwarded)
            completionHandler()
        }
    }

    private var wantsConsole: Bool {
        let type = NSApp.currentEvent?.type
        return type == .rightMouseDown || type == .rightMouseUp || NSEvent.modifierFlags.contains(.control)
    }

    @objc private func togglePanel(_ button: NSStatusBarButton) {
        if wantsConsole { showControls(); return }
        if popover.isShown { popover.performClose(nil); return }
        showPanel(relativeTo: button)
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        let view = MenuPopoverView(workspace: workspace, quit: { [weak self] in
            self?.workspace.runtime.stop()
            NSApplication.shared.terminate(nil)
        }, resize: { [weak self] in self?.resizePanel($0) })
        let host = NSHostingController(rootView: view)
        // 尺寸只由 PreferenceKey 回传驱动，不与 SwiftUI 的自动尺寸同时生效。
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = MenuPanelMetrics.size(contentHeight: max(220, host.view.fittingSize.height))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // LSUIElement 应用未激活时，气泡内的首次点击会被吞掉。
        NSApp.activate(ignoringOtherApps: true)
        host.view.window?.makeKey()
        watchPanelDismissal()
        if let home = NativeQA.home, home.lastPathComponent == "home-first" {
            let detail = "Isolated status button received a click; popover shown: \(popover.isShown)"
            try? detail.write(to: home.appendingPathComponent("status-click.txt"), atomically: true, encoding: .utf8)
        }
    }

    // .applicationDefined 不会自动关闭，系统头文件要求 App 自行检测外部点击。
    private func watchPanelDismissal() {
        guard #available(macOS 27.0, *), panelMonitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53, event.window === self.popover.contentViewController?.view.window else { return event }
                self.popover.performClose(nil)
                return nil
            }
            self.dismissPanel(forClickIn: event.window)
            return event
        }) { panelMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.dismissPanel(forClickIn: nil)
        }) { panelMonitors.append(global) }
    }

    private func dismissPanel(forClickIn window: NSWindow?) {
        guard popover.isShown, window == nil || window !== popover.contentViewController?.view.window else { return }
        // 点状态项本身由系统结束会话；这里抢先关闭会让同一次点击重新打开气泡。
        if let button = statusItem?.button, let host = button.window,
           host.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation) { return }
        popover.performClose(nil)
    }

    private func resizePanel(_ size: NSSize) {
        if popover.contentSize != size { popover.contentSize = size }
    }

    func popoverDidClose(_ notification: Notification) {
        panelMonitors.forEach(NSEvent.removeMonitor)
        panelMonitors = []
        if #available(macOS 27.0, *) { statusItem?.expandedInterfaceSession?.cancel() }
        // 真正关闭时才销毁视图及其待确认状态；关闭可能发生在按钮回调内，所以延后一拍。
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.contentViewController = nil
        }
    }

    private func showControls() {
        if controls == nil {
            let host = NSHostingController(rootView: ConsoleView(workspace: workspace))
            // 让 SwiftUI 的 navigationTitle 和 toolbar 落到真实窗口标题栏。
            if #available(macOS 14.0, *) { host.sceneBridgingOptions = [.title, .toolbars] }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: ConsoleView.defaultSize),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.toolbarStyle = .unified
            window.minSize = ConsoleView.minimumSize
            window.contentViewController = host
            window.setContentSize(ConsoleView.defaultSize)
            window.title = "微信桥控制台"
            // 标题会随页面变化，原生 UI 测试靠固定标识定位控制台窗口。
            window.setAccessibilityIdentifier("微信桥控制台")
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            controls = window
        }
        present(controls)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === controls, !forceCloseControls else { return true }
        return workspace.requestClose { [weak self, weak sender] in
            self?.forceCloseControls = true
            sender?.close()
            self?.forceCloseControls = false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === controls { controls = nil }
    }

    private func present(_ window: NSWindow?) {
        if popover.isShown { popover.close() }
        NSApp.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    private func installMainMenu() {
        // Route standard editing shortcuts to the active text field, including
        // when the bridge is an accessory app with no Dock icon.
        let menu = NSMenu()
        let application = NSMenu(title: "微信桥")
        application.addItem(withTitle: "退出微信桥", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editing = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"),
                                     ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editing.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        for submenu in [application, editing] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        NSApp.mainMenu = menu
    }

    private func diagnose(_ home: URL, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let item = self.statusItem, let button = item.button, let anchor = button.window else {
                if attempts > 0 { self.diagnose(home, attempts: attempts - 1) }
                return
            }
            let screens = NSScreen.screens
            let barWindows = NSApp.windows.filter { $0.level == anchor.level && $0.isVisible }
            let position = screens.lazy.compactMap { screen in
                barWindows.first { window in
                    let r = window.frame
                    return r.width == anchor.frame.width && abs(r.maxY - screen.frame.maxY) < 1 &&
                        screen.frame.contains(CGPoint(x: r.midX, y: r.midY))
                }?.frame
            }.first
            let file = home.appendingPathComponent("status-anchor.json")
            if let position, let main = screens.first {
                let point = CGPoint(x: position.midX, y: main.frame.maxY - position.midY)
                if let data = try? JSONEncoder().encode(point) {
                    try? data.write(to: file, options: .atomic)
                }
            } else if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: file)
            }
            let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            let own = all.compactMap { row -> String? in
                guard row[kCGWindowOwnerPID as String] as? Int32 == ProcessInfo.processInfo.processIdentifier else { return nil }
                return "\(row[kCGWindowNumber as String] ?? "?") layer \(row[kCGWindowLayer as String] ?? "?") onscreen \(row[kCGWindowIsOnscreen as String] ?? false)"
            }
            let text = "Active: \(NSApp.isActive); item visible flag: \(item.isVisible); item: \(anchor.frame) id \(anchor.windowNumber); AX frame: \(button.accessibilityFrame()); screen active: \(anchor.isOnActiveSpace); occlusion: \(anchor.occlusionState.rawValue); own status windows: \(barWindows.map { "\($0.windowNumber):\($0.frame)" }); WindowServer: \(own); displays: \(screens.map(\.frame))"
            try? text.write(to: home.appendingPathComponent("anchor-diagnostic"), atomically: true, encoding: .utf8)
            if attempts > 0 { self.diagnose(home, attempts: attempts - 1) }
        }
    }
}

@available(macOS 27.0, *)
extension BridgeEntry: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        if wantsConsole {
            session.cancel()
            showControls()
            return
        }
        if let button = statusItem.button { showPanel(relativeTo: button) }
        if !popover.isShown { session.cancel() }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        if popover.isShown { popover.animates = animated; popover.close(); popover.animates = true }
    }
}

enum MenuPanelMetrics {
    static let width: CGFloat = 336
    static let maxHeight: CGFloat = 560

    static func size(contentHeight: CGFloat) -> NSSize {
        NSSize(width: width, height: min(contentHeight.rounded(.up), maxHeight))
    }
}

// 滚动内容与底栏各上报一次，求和得到气泡的自然高度。
private struct MenuPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private extension View {
    func reportsPanelHeight() -> some View {
        background(GeometryReader { Color.clear.preference(key: MenuPanelHeightKey.self, value: $0.size.height) })
    }
}

struct MenuPanel: View {
    private struct ReplyReview {
        let mode: ReplyMode
        let configuration: Configuration
    }

    @ObservedObject var store: AppStore
    let inMenuBar: Bool
    let showSettings: () -> Void
    let showCompose: () -> Void
    var resize: ((NSSize) -> Void)? = nil
    @State private var recovery: String?
    @State private var review: ReplyReview?

    private var s: EngineState { store.state }
    private var c: Configuration { store.configuration }
    private let blockedRead = ReplyBlocker.blockedRead
    private var replyBlocker: ReplyBlocker? { ReplyBlocker.evaluate(begin: store.beginBlocker, configuration: c, reason: s.reason) }
    private var canStartReply: Bool { replyBlocker == nil }
    private var automatic: Bool { store.automaticReplyOn || review?.mode == .automatic }

    var body: some View {
        Group {
            if inMenuBar { menuBarLayout } else { consoleLayout }
        }
        .onChange(of: c) { _ in review = nil }
        .onChange(of: store.sleepRevision) { _ in review = nil }
    }

    private var consoleLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            sections
            Divider()
            footer
        }
        .padding(15)
        .frame(width: 396)
    }

    // 底栏固定在滚动区外，确认区再长也不会把「退出」挤出气泡。
    private var menuBarLayout: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    sections.padding(.horizontal, 15).padding(.top, 15).padding(.bottom, 12).reportsPanelHeight()
                }
                Divider()
                footer.padding(.horizontal, 15).padding(.vertical, 10).reportsPanelHeight()
            }
            .onChange(of: review?.mode) { mode in
                guard let mode else { return }
                // 等确认区完成布局后再滚动，保证确认按钮可见。
                DispatchQueue.main.async { proxy.scrollTo(mode, anchor: .bottom) }
            }
        }
        .frame(width: MenuPanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(MenuPanelHeightKey.self) { height in
            // 加 1 是分隔线的高度。
            resize?(MenuPanelMetrics.size(contentHeight: height + 1))
        }
    }

    private var footer: some View {
        HStack {
            Button(action: showSettings) { Label("设置", systemImage: "gearshape") }.buttonStyle(.borderless)
            Spacer()
            Button("退出") { store.client.shutdown(); NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
                .accessibilityIdentifier(inMenuBar ? "menu-exit" : "console-exit")
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("微信桥", systemImage: "bubble.left.and.bubble.right").font(.headline)
                Spacer()
                Text(store.ready ? (store.authorizing && !s.running ? "正在准备" : s.title) : "后台未就绪")
                    .font(.caption.weight(.semibold)).foregroundStyle(s.running ? Color.accentColor : Color.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.contact?.label ?? "尚未绑定私聊").font(.body.weight(.medium)).lineLimit(1)
                    Text(c.contact == nil ? "先在设置里选择一个知情的联系人" : "\(c.accountLabel) · 单一私聊 · 纯文字")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            Toggle(isOn: Binding(get: { automatic }, set: toggleAutomatic)) {
                HStack {
                    Text("自动回复").font(.body.weight(.medium))
                    if review?.mode == .automatic { Text("待确认").font(.caption).foregroundStyle(.secondary) }
                }
            }.toggleStyle(.switch).accessibilityIdentifier("automatic-reply").disabled(!automatic && !canStartReply)
            if !automatic, let blocker = replyBlocker {
                Notice(text: blocker.guidance).accessibilityIdentifier("reply-unavailable")
            }
            if let reason = store.error ?? s.reason, automatic || replyBlocker?.guidance != explanation(reason) {
                Notice(text: explanation(reason), important: store.error != nil || s.uncertain || s.peerStopped)
            }
            if let at = s.scheduledAt {
                Label("计划 \(Date(timeIntervalSince1970: Double(at) / 1000).formatted(date: .omitted, time: .shortened)) · 仅此一次", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let draft = s.draft {
                VStack(alignment: .leading, spacing: 5) {
                    Text("临时草稿 · 未发送").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(draft).textSelection(.disabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if let receipt = s.receipt {
                HStack {
                    Label(receipt.caption, systemImage: "checkmark.bubble").font(.caption)
                    Spacer()
                    if receipt.hasOperation && !s.running && !s.inFlight { Button("查回执") { store.recovery("refresh") }.controlSize(.small) }
                }
            }
            if let stats = s.statistics {
                DisclosureGroup("提交耗时 · \(stats.count) 次 · P50 \(stats.total.p50) ms") {
                    VStack(alignment: .leading, spacing: 5) {
                        metric("事件观察延迟", stats.ingest); metric("合并及排队", stats.batch)
                        metric("模型", stats.model); metric("发送 RPC", stats.rpc); metric("观察至提交", stats.total)
                    }.padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let review {
                ReplyConsentView(mode: review.mode, value: review.configuration, canStart: canStartReply && c == review.configuration,
                                 cancel: { self.review = nil }, confirm: { agreed, cloud in
                    self.review = nil
                    do { try store.arm(review.mode, consent: agreed, cloud: cloud, confirmed: review.configuration) }
                    catch { store.capture(error) }
                }).id(review.mode)
            } else if s.running || s.inFlight || store.authorizing {
                if (s.running || store.authorizing) && !store.automaticReplyOn {
                    Button { store.pause() } label: { Label("立即暂停", systemImage: "pause.circle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
                if s.inFlight {
                    Text("已经开始提交的请求不能撤回。关闭后不会开始新的自动发送。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if store.ready {
                if s.peerStopped || s.uncertain || blockedRead.contains(s.reason ?? "") {
                    if s.peerStopped { Button("对方重新同意后恢复") { recovery = "restore-consent" } }
                    if s.uncertain { Button("已在微信核对，不重发") { recovery = "acknowledge" } }
                    if !s.peerStopped && !s.uncertain {
                        Button(s.reason == "backlog-limit" ? "核对身份并继续读取" : "核对身份并建立新起点") { recovery = "reset-read" }
                    }
                } else if c.target != nil {
                    HStack {
                        Button { review = ReplyReview(mode: .draft, configuration: c) } label: { Label("只拟稿…", systemImage: "text.bubble") }
                            .disabled(!canStartReply)
                        Button(action: showCompose) { Label("发送一条…", systemImage: "paperplane") }
                            .disabled(!store.canBegin)
                    }
                } else { Button("去设置…", action: showSettings).buttonStyle(.borderedProminent) }
            } else { Button("重启后台") { store.load() } }

            if let command = recovery {
                VStack(alignment: .leading, spacing: 7) {
                    Text(recoveryDescription(command)).font(.caption)
                    HStack {
                        Button("取消") { recovery = nil }
                        Button("确认") { recovery = nil; store.recovery(command) }.buttonStyle(.borderedProminent)
                    }
                }.padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func toggleAutomatic(_ enabled: Bool) {
        if enabled {
            guard canStartReply else { return }
            review = ReplyReview(mode: .automatic, configuration: c)
        } else if review?.mode == .automatic {
            review = nil
        } else {
            store.pause()
        }
    }

    private func metric(_ name: String, _ q: EngineState.Quantiles) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("P50 \(q.p50) · P95 \(q.p95) ms").monospacedDigit()
        }
    }

    private func recoveryDescription(_ command: String) -> String {
        switch command {
        case "restore-consent": return "仅在对方已明确重新同意时使用。此操作不会直接启动自动回复或发送。"
        case "acknowledge": return "仅解除未知提交的阻塞；不会重试原消息。"
        default:
            if s.reason == "backlog-limit" {
                return "确认账号和联系人仍正确。将从已记录的位置继续读取，不追答旧消息；积压仍过多会再次暂停。需重新开启。"
            }
            return "确认账号和联系人仍正确。旧事件不回复，也不会补扫历史。需重新开启。"
        }
    }
}

struct Notice: View {
    let text: String
    var important = false
    var body: some View {
        Label(text, systemImage: important ? "exclamationmark.circle" : "info.circle")
            .font(.callout).foregroundStyle(important ? Color.primary : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
