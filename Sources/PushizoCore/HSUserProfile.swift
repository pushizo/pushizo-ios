import Foundation

/**
 Girişle birlikte ayarlanan profil: `try Pushizo.login("user_42", profile: HSUserProfile(email: "ali@ornek.com"))`.
 Geçersiz e-posta veya telefon girişten önce reddedilir; yarım kalmış bir kimlik değişimi olmaz (Android
 `HsUserProfile` ile aynı).
 */
public struct HSUserProfile: Equatable {
    public var email: String?
    public var sms: String?
    public var tags: [String: String]
    public var aliases: [String: String]

    public init(email: String? = nil, sms: String? = nil, tags: [String: String] = [:], aliases: [String: String] = [:]) {
        self.email = email
        self.sms = sms
        self.tags = tags
        self.aliases = aliases
    }

    /// Profil geçersizse hata mesajı; geçerliyse nil. E-posta, telefon (E.164) ve alias kuralları tekil çağrılarla aynıdır.
    public var validationError: String? {
        if let email, HSContacts.normalizeEmail(email) == nil { return "Geçersiz e-posta adresi" }
        if let sms, HSContacts.normalizePhone(sms) == nil { return "Geçersiz telefon numarası" }
        if !aliases.isEmpty, HSAliases.normalize(aliases) == nil { return "Geçersiz alias" }
        return nil
    }

    /// Girişten sonra sırayla kuyruğa yazılacak işlemler (e-posta, SMS, tag, alias); profil geçersizse boş.
    public func operations(at: TimeInterval = Date().timeIntervalSince1970) -> [[String: Any]] {
        guard validationError == nil else { return [] }
        var ops: [[String: Any]] = []
        if let address = email.flatMap(HSContacts.normalizeEmail) {
            ops.append(["type": "contact_add", "channel": "email", "address": address, "at": at])
        }
        if let address = sms.flatMap(HSContacts.normalizePhone) {
            ops.append(["type": "contact_add", "channel": "sms", "address": address, "at": at])
        }
        if !tags.isEmpty { ops.append(["type": "tags", "tags": tags, "at": at]) }
        if !aliases.isEmpty, let normalized = HSAliases.normalize(aliases) {
            ops.append(["type": "alias_add", "aliases": normalized, "at": at])
        }
        return ops
    }
}

/**
 Kullanıcı özelliği (`User.setProperty`) kuyruk işlemi. UserDefaults `NSNull` saklayamadığından silinecek anahtar
 `properties` içinde değil `remove` listesinde tutulur ve istek gövdesi kurulurken `null` olur (tag silmeyle aynı kalıp).
 */
public enum HSUserProperties {
    public static let maxKeyLength = 64

    /// Değer JSON'a ve property list'e yazılabilir mi (metin, sayı, mantıksal; bunların dizisi/sözlüğü).
    public static func isSupported(_ value: Any) -> Bool {
        switch value {
        case is String, is NSNumber: return true
        case let array as [Any]: return array.allSatisfy(isSupported)
        case let dict as [String: Any]: return dict.values.allSatisfy(isSupported)
        default: return false
        }
    }

    /// Kuyruk işlemi; anahtar boş/uzunsa veya değer desteklenmiyorsa nil. `value` nil ise özellik silinir.
    public static func operation(key: String, value: Any?, at: TimeInterval = Date().timeIntervalSince1970) -> [String: Any]? {
        let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxKeyLength else { return nil }
        guard let value, !(value is NSNull) else {
            return ["type": "properties", "properties": [String: Any](), "remove": [name], "at": at]
        }
        guard isSupported(value) else { return nil }
        return ["type": "properties", "properties": [name: value], "at": at]
    }

    /// Kuyruktaki işlemden `PATCH /users/{id}` `properties` gövdesi: `remove` anahtarları `null` olur.
    public static func body(_ op: [String: Any]) -> [String: Any] {
        var properties = op["properties"] as? [String: Any] ?? [:]
        for key in op["remove"] as? [String] ?? [] { properties[key] = NSNull() }
        return properties
    }
}
