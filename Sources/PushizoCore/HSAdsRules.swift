import Foundation

/// Rıza amaçları (ADR-0037): tercih API'sinde ayrılmış kategori anahtarları.
public enum HSConsentPurpose {
    /// Kullanıcının e-posta/telefon SHA-256 özetinin reklam platformu kitlelerine gönderilmesine açık onay.
    public static let adsPersonalization = "ads_personalization"
}

/**
 Rıza kaydı (ADR-0037). Varsayılan rıza yoktur; yalnızca açık onay `granted == true` olur. `source` kaydı yazan taraf
 (sdk, api, preference_center, dashboard).
 */
public struct HSUserConsent: Equatable {
    public let purpose: String
    public let granted: Bool
    public let source: String?
    public let updatedAt: Date?
}

/**
 Mobil reklam kimliği (IDFA) kuralları (saf mantık). SDK `AdSupport`/ATT içermez: uygulama ATT izni aldıysa
 `ASIdentifierManager` ile okuduğu kimliği verir. Sıfır kimlik (ATT reddi) ve geçersiz biçim silme sayılır. Gönderim
 `PATCH /subscriptions/{id}` (`advertising_id`), kalıcı kuyruk üzerinden; son işlem kazanır.
 */
public enum HSAdsRules {
    public static let operationType = "advertising_id"
    private static let zero = "00000000-0000-0000-0000-000000000000"

    /// Geçerli, sıfır olmayan UUID küçük harfle; aksi halde nil.
    public static func normalize(_ id: String?) -> String? {
        guard let raw = id?.trimmingCharacters(in: .whitespacesAndNewlines), let uuid = UUID(uuidString: raw) else { return nil }
        let value = uuid.uuidString.lowercased()
        return value == zero ? nil : value
    }

    /// Kuyruk işlemi (UserDefaults'a yazılabilir; `NSNull` içermez): kimlik yoksa `clear`.
    public static func operation(advertisingId: String?, at: TimeInterval = Date().timeIntervalSince1970) -> [String: Any] {
        if let id = normalize(advertisingId) { return ["type": operationType, "advertising_id": id, "at": at] }
        return ["type": operationType, "clear": true, "at": at]
    }

    /// `PATCH /subscriptions/{id}` gövdesi ve sahiplik kanıtı (`token_hash`).
    public static func body(for op: [String: Any], registeredToken: String?) -> [String: Any] {
        let value: Any = (op["clear"] as? Bool == true) ? NSNull() : (normalize(op["advertising_id"] as? String).map { $0 as Any } ?? NSNull())
        return HSOwnership.withProof(["advertising_id": value], registeredToken: registeredToken)
    }

    /// Kuyrukta bu işlemden sonra yazılmış bir reklam kimliği işlemi varsa bu işlem gönderilmez.
    public static func isSuperseded(_ op: [String: Any], queue: [[String: Any]]) -> Bool {
        guard let index = queue.lastIndex(where: { NSDictionary(dictionary: $0).isEqual(to: op) }) else { return false }
        return queue[(index + 1)...].contains { $0["type"] as? String == operationType }
    }
}
