import Foundation

/// İçerik kartı türü (ADR-0082). Bilinmeyen tür klasik sayılır (sunucu ileride yeni tür eklerse uygulama bozulmaz).
public enum HSContentCardType: String, Equatable {
    case classic
    case captionedImage = "captioned_image"
    case imageOnly = "image_only"
}

/// İçerik kartı (ADR-0082). Akış sunucuda sabitlenmiş → öncelik → yeni sırasıyla gelir.
public struct HSContentCard: Equatable {
    public let id: String
    public let messageId: String?
    public let type: HSContentCardType
    public let title: String?
    public let body: String?
    public let url: String?
    public let imageUrl: String?
    public let buttonText: String?
    public let data: [String: String]
    public let pinned: Bool
    public let priority: Int
    public let viewed: Bool
    public let clicked: Bool
    public let expiresAt: Date?
    public let createdAt: Date?
}

/// Kart akışı ve görülmemiş kart sayısı.
public struct HSContentCardFeed: Equatable {
    public let cards: [HSContentCard]
    public let unviewedCount: Int
}

public enum HSContentCardParser {
    public static func parseFeed(_ json: [String: Any]) -> HSContentCardFeed {
        let cards = (json["data"] as? [[String: Any]] ?? []).compactMap(parseCard)
        return HSContentCardFeed(
            cards: cards,
            unviewedCount: (json["unviewed_count"] as? NSNumber)?.intValue ?? cards.filter { !$0.viewed }.count
        )
    }

    public static func parseCard(_ json: [String: Any]) -> HSContentCard? {
        guard let id = json["id"] as? String else { return nil }
        func date(_ key: String) -> Date? { HSInAppParser.nonEmpty(json[key]).flatMap(HSIsoTime.parse) }
        return HSContentCard(
            id: id,
            messageId: HSInAppParser.nonEmpty(json["message_id"]),
            type: HSInAppParser.nonEmpty(json["type"]).flatMap(HSContentCardType.init(rawValue:)) ?? .classic,
            title: HSInAppParser.nonEmpty(json["title"]),
            body: HSInAppParser.nonEmpty(json["body"]),
            url: HSInAppParser.nonEmpty(json["url"]),
            imageUrl: HSInAppParser.nonEmpty(json["image_url"]),
            buttonText: HSInAppParser.nonEmpty(json["button_text"]),
            data: (json["data"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String },
            pinned: json["pinned"] as? Bool ?? false,
            priority: (json["priority"] as? NSNumber)?.intValue ?? 0,
            viewed: json["viewed"] as? Bool ?? false,
            clicked: json["clicked"] as? Bool ?? false,
            expiresAt: date("expires_at"),
            createdAt: date("created_at")
        )
    }
}
