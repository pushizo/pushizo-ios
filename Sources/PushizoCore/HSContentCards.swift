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

/// Hazır kart görünümünün (HSContentCardsView) arayüzden bağımsız yerleşim kuralları (ADR-0082).
public enum HSContentCardLayout {
    public enum Part: Equatable { case image, text, button }

    /// Klasik kart metin (+düğme); görselli kartta görsel üstte; yalnız görsel kartta metin yok. Görseli olmayan
    /// görsel kartı metne düşer (boş kart gösterilmez).
    public static func parts(_ card: HSContentCard) -> [Part] {
        let hasImage = !(card.imageUrl ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let hasText = !(card.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || !(card.body ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        var result: [Part] = []
        switch card.type {
        case .imageOnly: result.append(hasImage ? .image : .text)
        case .captionedImage:
            if hasImage { result.append(.image) }
            if hasText || !hasImage { result.append(.text) }
        case .classic: result.append(.text)
        }
        if result.contains(.text), !(card.buttonText ?? "").trimmingCharacters(in: .whitespaces).isEmpty { result.append(.button) }
        return result
    }

    /// Kartın en az yarısı görünürse gösterim sayılır.
    public static func countsAsImpression(visibleHeight: Double, totalHeight: Double) -> Bool {
        totalHeight > 0 && visibleHeight * 2 >= totalHeight
    }
}

/// Hazır kart görünümü metinleri (Türkçe veya İngilizce; dil tercihinden seçilir).
public struct HSContentCardStrings: Equatable {
    public let empty: String
    public let error: String
    public let retry: String
    public let dismiss: String
    public let pinned: String

    public static func forLanguage(_ language: String?) -> HSContentCardStrings {
        if (language ?? "en").lowercased().hasPrefix("tr") {
            return HSContentCardStrings(empty: "Henüz kart yok", error: "Kartlar yüklenemedi.", retry: "Tekrar dene", dismiss: "Kartı kapat", pinned: "Sabitlendi")
        }
        return HSContentCardStrings(empty: "No cards yet", error: "Cards could not be loaded.", retry: "Try again", dismiss: "Dismiss card", pinned: "Pinned")
    }
}
