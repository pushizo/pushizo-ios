import Foundation

/**
 Kullanıcı tercihi (ADR-0019 §4): kategori × kanal (`nil` = tüm kanallar) → opt-in. `explicit` false ise değer kategori
 varsayılanından türetilmiştir; `source` kaydı yazan taraf (sdk, api, preference_center…).
 */
public struct HSPreference: Equatable {
    public let category: String
    /// `nil` | `ios_push` | `android_push` | `web_push` | `email` | `sms`.
    public let channel: String?
    public let optedIn: Bool
    public let explicit: Bool
    public let source: String?
    /// Türetilmiş değerde nil.
    public let updatedAt: Date?
}

/// Mesaj kategorisi: çok dilli ad/açıklama (`dil kodu → metin`), kanal kısıtı (`nil` = tümü) ve varsayılan opt-in.
public struct HSMessageCategory: Equatable {
    public let key: String
    public let name: [String: String]
    public let description: [String: String]
    public let channels: [String]?
    public let defaultOptedIn: Bool

    /// Verilen dilde ad; yoksa İngilizce, o da yoksa ilk tanımlı dil.
    public func localizedName(_ language: String) -> String {
        name[language] ?? name["en"] ?? name.sorted { $0.key < $1.key }.first?.value ?? key
    }
}

/// `GET/PUT /preferences` sonucu: kullanıcının tercihleri, app'in kategorileri ve rıza kayıtları (ADR-0037).
public struct HSPreferencesResult: Equatable {
    public let preferences: [HSPreference]
    public let categories: [HSMessageCategory]
    public let consents: [HSUserConsent]
}

/// `User.setPreferences` girdisi; `channel` nil ise tüm kanallar.
public struct HSPreferenceInput: Equatable {
    public let category: String
    public let channel: String?
    public let optedIn: Bool

    public init(category: String, channel: String? = nil, optedIn: Bool) {
        self.category = category
        self.channel = channel
        self.optedIn = optedIn
    }

    public var json: [String: Any] {
        var out: [String: Any] = ["category": category, "opted_in": optedIn]
        out["channel"] = channel.map { $0 as Any } ?? NSNull()
        return out
    }
}

public enum HSPreferencesParser {
    private static let channels: Set<String> = ["ios_push", "android_push", "web_push", "email", "sms"]

    public static func parseResult(_ json: [String: Any]) -> HSPreferencesResult {
        HSPreferencesResult(
            preferences: (json["data"] as? [[String: Any]] ?? []).compactMap(parsePreference),
            categories: (json["categories"] as? [[String: Any]] ?? []).compactMap(parseCategory),
            consents: (json["consents"] as? [[String: Any]] ?? []).compactMap(parseConsent)
        )
    }

    /// Rıza kaydı; amaçsız kayıt atlanır (eski API sürümlerinde `consents` yoktur).
    public static func parseConsent(_ json: [String: Any]) -> HSUserConsent? {
        guard let purpose = HSInAppParser.nonEmpty(json["purpose"]) else { return nil }
        return HSUserConsent(
            purpose: purpose,
            granted: json["granted"] as? Bool ?? false,
            source: HSInAppParser.nonEmpty(json["source"]),
            updatedAt: HSInAppParser.nonEmpty(json["updated_at"]).flatMap(HSIsoTime.parse)
        )
    }

    public static func parsePreference(_ json: [String: Any]) -> HSPreference? {
        guard let category = json["category"] as? String else { return nil }
        return HSPreference(
            category: category,
            channel: HSInAppParser.nonEmpty(json["channel"]),
            optedIn: json["opted_in"] as? Bool ?? false,
            explicit: json["explicit"] as? Bool ?? false,
            source: HSInAppParser.nonEmpty(json["source"]),
            updatedAt: HSInAppParser.nonEmpty(json["updated_at"]).flatMap(HSIsoTime.parse)
        )
    }

    /// Anahtarsız kategori atlanır; `channels` nil ise kısıt yok.
    public static func parseCategory(_ json: [String: Any]) -> HSMessageCategory? {
        guard let key = HSInAppParser.nonEmpty(json["key"]) else { return nil }
        return HSMessageCategory(
            key: key,
            name: strings(json["name"]),
            description: strings(json["description"]),
            channels: (json["channels"] as? [Any]).map { $0.compactMap { $0 as? String }.filter { !$0.isEmpty } },
            defaultOptedIn: json["default_opted_in"] as? Bool ?? true
        )
    }

    /// Girdi geçerli mi: 1-100 kayıt, kategori 1-64 karakter, kanal bilinen bir anahtar.
    public static func isValid(_ inputs: [HSPreferenceInput]) -> Bool {
        guard !inputs.isEmpty, inputs.count <= 100 else { return false }
        return inputs.allSatisfy { (1...64).contains($0.category.count) && ($0.channel.map(channels.contains) ?? true) }
    }

    private static func strings(_ value: Any?) -> [String: String] {
        (value as? [String: Any] ?? [:]).compactMapValues { HSInAppParser.nonEmpty($0) }
    }
}
