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
