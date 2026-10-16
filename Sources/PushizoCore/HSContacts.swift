import Foundation

/// E-posta/SMS adresi normalizasyonu; kurallar sunucu (`packages/shared` messaging) ve Android SDK ile aynıdır.
public enum HSContacts {
    // ICU `\d`/`\s` Unicode rakam/boşluklarını da kapsadığından ASCII sınıfları açıkça yazılır.
    private static let email = try! NSRegularExpression(
        pattern: #"^[^ \t\r\n\f\v@"(),:;<>\[\\\]]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$"#
    )
    private static let e164 = try! NSRegularExpression(pattern: #"^\+[1-9][0-9]{6,14}$"#)

    /// Boşluk kırpma + küçük harf (yerel ayardan bağımsız); geçersizse nil.
    public static func normalizeEmail(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard v.count <= 320, fullMatch(email, v) else { return nil }
        return v
    }

    /// E.164 biçimi: boşluk, tire, parantez ve nokta atılır, `00` öneki `+` olur; geçersizse nil.
    public static func normalizePhone(_ value: String) -> String? {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        v = v.replacingOccurrences(of: #"[ \t\r\n().-]"#, with: "", options: .regularExpression)
        if v.hasPrefix("00") { v = "+" + v.dropFirst(2) }
        return fullMatch(e164, v) ? v : nil
    }

    /// E-posta/SMS kaydındaki `user`: kimlikli kullanıcıda `external_id` (+ `identity_hash`); anonimde cihazın mevcut
    /// aboneliği (`subscription_id`: push, yoksa önceki e-posta/SMS) ile aynı kullanıcıya bağlanır; hiçbiri yoksa nil.
    public static func registrationUser(externalId: String?, identityHash: String?, subscriptionId: String?) -> [String: String]? {
        if let externalId {
            var user = ["external_id": externalId]
            if let identityHash { user["identity_hash"] = identityHash }
            return user
        }
        if let subscriptionId { return ["subscription_id": subscriptionId] }
        return nil
    }

    static func fullMatch(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range) else { return false }
        return match.range == range
    }
}
