import Foundation

/// Bildirim kutusu öğesi (`docs/messaging.md` §8).
public struct HSInboxItem: Equatable {
    public let id: String
    public let messageId: String?
    public let title: String?
    public let body: String?
    public let url: String?
    public let imageUrl: String?
    public let data: [String: String]
    public let read: Bool
    public let readAt: Date?
    public let archivedAt: Date?
    public let expiresAt: Date?
    public let createdAt: Date?
}

/// Bildirim kutusu sayfası (yeniden eskiye).
public struct HSInboxPage: Equatable {
    public let items: [HSInboxItem]
    public let unreadCount: Int
    public let nextCursor: String?
    public let hasMore: Bool
}

public enum HSInboxParser {
    public static func parsePage(_ json: [String: Any]) -> HSInboxPage {
        let items = (json["data"] as? [[String: Any]] ?? []).compactMap(parseItem)
        return HSInboxPage(
            items: items,
            unreadCount: (json["unread_count"] as? NSNumber)?.intValue ?? items.filter { !$0.read }.count,
            nextCursor: HSInAppParser.nonEmpty(json["next_cursor"]),
            hasMore: json["has_more"] as? Bool ?? false
        )
    }

    public static func parseItem(_ json: [String: Any]) -> HSInboxItem? {
        guard let id = json["id"] as? String else { return nil }
        func date(_ key: String) -> Date? { HSInAppParser.nonEmpty(json[key]).flatMap(HSIsoTime.parse) }
        return HSInboxItem(
            id: id,
            messageId: HSInAppParser.nonEmpty(json["message_id"]),
            title: HSInAppParser.nonEmpty(json["title"]),
            body: HSInAppParser.nonEmpty(json["body"]),
            url: HSInAppParser.nonEmpty(json["url"]),
            imageUrl: HSInAppParser.nonEmpty(json["image_url"]),
            data: (json["data"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String },
            read: json["read"] as? Bool ?? false,
            readAt: date("read_at"),
            archivedAt: date("archived_at"),
            expiresAt: date("expires_at"),
            createdAt: date("created_at")
        )
    }
}

/// `Inbox.addObserver` olayı: okunmamış sayısı veya öğeler değiştiğinde (Web SDK `InboxChangeEvent` ile aynı).
public struct HSInboxChangeEvent: Equatable {
    public enum Kind: String {
        case listed
        case read
        case readAll = "read_all"
        case archived
        case count
    }

    public let type: Kind
    public let itemId: String?
    public let unreadCount: Int

    public init(type: Kind, itemId: String? = nil, unreadCount: Int) {
        self.type = type
        self.itemId = itemId
        self.unreadCount = unreadCount
    }

    public var dictionary: [String: Any] {
        var out: [String: Any] = ["type": type.rawValue, "unreadCount": unreadCount]
        if let itemId { out["itemId"] = itemId }
        return out
    }
}

/**
 Bildirim kutusu değişim takibi (Web SDK `InboxClient` kuralları): bilinen öğelerin okunma durumu ve son okunmamış sayısı
 tutulur. `listed`/`count` yalnızca sayı değiştiğinde, `read`/`read_all`/`archived` her zaman olay üretir. Okundu/arşiv
 sonrası sayı yerelde hesaplanabiliyorsa (öğe biliniyor ve sayı biliniyorsa) sunucuya sorulmaz. İş parçacığı güvenlidir.
 */
public final class HSInboxTracker {
    private let lock = NSLock()
    private var known: [String: Bool] = [:]
    private var unread: Int?

    public init() {}

    /// Son bilinen okunmamış sayısı; henüz ölçülmediyse nil.
    public var lastUnreadCount: Int? {
        lock.lock(); defer { lock.unlock() }
        return unread
    }

    /// Liste sayfası alındı; ilk sayfa (`cursor` yok) önbelleği yeniler.
    public func listed(_ page: HSInboxPage, firstPage: Bool) -> HSInboxChangeEvent? {
        lock.lock(); defer { lock.unlock() }
        if firstPage { known.removeAll() }
        for item in page.items { known[item.id] = item.read }
        return set(page.unreadCount, HSInboxChangeEvent(type: .listed, unreadCount: page.unreadCount))
    }

    /// Okundu işaretlemeden sonraki sayı yerelde biliniyorsa onu, bilinmiyorsa nil döndürür (sunucudan sayılmalı).
    public func countAfterRead(_ id: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let unread, known[id] == false else { return nil }
        return max(0, unread - 1)
    }

    public func read(_ id: String, unreadCount: Int) -> HSInboxChangeEvent? {
        lock.lock(); defer { lock.unlock() }
        known[id] = true
        return set(unreadCount, HSInboxChangeEvent(type: .read, itemId: id, unreadCount: unreadCount))
    }

    public func readAll(unreadCount: Int) -> HSInboxChangeEvent? {
        lock.lock(); defer { lock.unlock() }
        for id in known.keys { known[id] = true }
        return set(unreadCount, HSInboxChangeEvent(type: .readAll, unreadCount: unreadCount))
    }

    /// Arşivden sonraki sayı yerelde biliniyorsa onu, bilinmiyorsa nil döndürür.
    public func countAfterArchive(_ id: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let unread, let wasRead = known[id] else { return nil }
        return max(0, unread - (wasRead ? 0 : 1))
    }

    public func archived(_ id: String, unreadCount: Int) -> HSInboxChangeEvent? {
        lock.lock(); defer { lock.unlock() }
        known.removeValue(forKey: id)
        return set(unreadCount, HSInboxChangeEvent(type: .archived, itemId: id, unreadCount: unreadCount))
    }

    public func counted(_ unreadCount: Int) -> HSInboxChangeEvent? {
        lock.lock(); defer { lock.unlock() }
        return set(unreadCount, HSInboxChangeEvent(type: .count, unreadCount: unreadCount))
    }

    /// Kullanıcı değişince (login/logout) önbellek temizlenir.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        known.removeAll()
        unread = nil
    }

    private func set(_ count: Int, _ event: HSInboxChangeEvent) -> HSInboxChangeEvent? {
        let changed = unread != count
        unread = count
        if !changed && (event.type == .listed || event.type == .count) { return nil }
        return event
    }
}
