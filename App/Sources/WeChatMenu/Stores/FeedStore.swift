import Foundation
import UserNotifications

struct FeedNotification: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let kind: FeedItem.Kind
    let conversationId: String?
    let pluginId: String?

    init(_ item: FeedItem) {
        id = item.id
        title = item.title
        body = String(item.body.prefix(240))
        kind = item.kind
        conversationId = item.conversationId
        pluginId = item.pluginId
    }
}

@MainActor
protocol NotificationDelivering: AnyObject {
    func deliver(_ notification: FeedNotification)
}

final class NullNotificationDelivery: NotificationDelivering {
    func deliver(_ notification: FeedNotification) {}
}

// UNUserNotificationCenter.current() 在无 Bundle 进程中会抛异常，所以延迟到首次派发才取用。
final class SystemNotificationDelivery: NotificationDelivering {
    func deliver(_ notification: FeedNotification) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        var info: [String: String] = ["feedId": notification.id, "kind": notification.kind.rawValue]
        info["conversationId"] = notification.conversationId
        info["pluginId"] = notification.pluginId
        content.userInfo = info
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        Task {
            // 系统只提示一次；不缓存结果，用户之后在系统设置中开启即可生效。
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }
}

enum FeedNotifications {
    static func canUseSystemCenter(bundleURL: URL = Bundle.main.bundleURL, nativeQA: Bool = NativeQA.active) -> Bool {
        bundleURL.pathExtension == "app" && !nativeQA
    }

    @MainActor
    static func makeDefault() -> NotificationDelivering {
        canUseSystemCenter() ? SystemNotificationDelivery() : NullNotificationDelivery()
    }
}

@MainActor
final class FeedStore: ObservableObject, BridgeEventConsumer {
    static let maxItems = 500

    @Published private(set) var items: [FeedItem] = []
    @Published private(set) var unreadCount = 0
    @Published private(set) var nextCursor: String?

    private let runtime: BridgeRuntime
    private let notifications: NotificationDelivering
    private var seen: Set<String> = []

    init(runtime: BridgeRuntime, notifications: NotificationDelivering? = nil) {
        self.runtime = runtime
        self.notifications = notifications ?? FeedNotifications.makeDefault()
        runtime.register(self)
    }

    func apply(_ event: PushEvent) {
        switch event {
        case .hello(let payload): unreadCount = payload.status.unreadFeedCount
        case .feedAdded(let added): receive(added)
        default: break
        }
    }

    // 动态流保留到下次刷新；未读数以重连后的 hello 为准。
    func bridgeDisconnected() {}

    // 重复推送既不重复计未读，也不重复弹通知。
    private func receive(_ added: FeedAdded) {
        guard seen.insert(added.item.id).inserted else { return }
        items.insert(added.item, at: 0)
        trim()
        if !added.item.read { unreadCount += 1 }
        if added.notifyDesktop && !added.item.read { notifications.deliver(FeedNotification(added.item)) }
    }

    func refresh(unreadOnly: Bool = false, limit: Int = 100) async throws {
        let page = try await runtime.client.feedList(.init(limit: limit, unreadOnly: unreadOnly ? true : nil))
        items = page.items
        // 保留已见 ID，刷新后重复推送也不会再次弹通知。
        seen.formUnion(page.items.map(\.id))
        nextCursor = page.nextCursor
    }

    func loadMore(unreadOnly: Bool = false, limit: Int = 100) async throws {
        guard let cursor = nextCursor else { return }
        let page = try await runtime.client.feedList(.init(cursor: cursor, limit: limit, unreadOnly: unreadOnly ? true : nil))
        let fresh = page.items.filter { seen.insert($0.id).inserted }
        items.append(contentsOf: fresh)
        trim()
        nextCursor = page.nextCursor
    }

    func markRead(ids: [String]) async throws {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return }
        try await runtime.client.feedMarkRead(ids: unique)
        let targets = Set(unique)
        var cleared = 0
        for index in items.indices where targets.contains(items[index].id) && !items[index].read {
            items[index].read = true
            cleared += 1
        }
        unreadCount = max(0, unreadCount - cleared)
        // 未加载到列表的未读项无法在本地计数，向引擎取权威值。已读已生效，刷新失败不算操作失败。
        if cleared != unique.count, let status = try? await runtime.client.systemStatus() {
            unreadCount = status.unreadFeedCount
        }
    }

    private func trim() {
        guard items.count > Self.maxItems else { return }
        items.removeLast(items.count - Self.maxItems)
        seen = Set(items.map(\.id))
    }
}
