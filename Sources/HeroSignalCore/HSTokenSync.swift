import CommonCrypto
import Foundation

/**
 Abonelik sahiplik kanıtı (ADR-0016): `PATCH`/`DELETE subscriptions/{id}`, `login`, `logout`, `POST sessions` ve
 `user.subscription_id` ile bağlama isteklerine kayıtlı token'ın SHA-256 özeti (`token_hash`) ve varsa kullanıcının
 `identity_hash`'i eklenir; `ownership_proof: true` ile kaydolan abonelik kanıtsız değiştirilemez/silinemez.
 */
public enum HSOwnership {
    /// UTF-8 metnin SHA-256 özeti (küçük harf hex); sunucudaki `token_hash` ile aynıdır.
    public static func tokenHash(_ token: String) -> String {
        let data = Data(token.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Gövdeye kanıt alanlarını ekler (değer yoksa eklenmez).
    public static func withProof(_ body: [String: Any], registeredToken: String?, identityHash: String? = nil) -> [String: Any] {
        var out = body
        if let registeredToken { out["token_hash"] = tokenHash(registeredToken) }
        if let identityHash { out["identity_hash"] = identityHash }
        return out
    }

    /// `login` gövdesi: `identity_hash` hedef kullanıcıya aittir (yalnızca aynı kullanıcıya yeniden girişte kanıt sayılır);
    /// aboneliğin kanıtı kayıtlı token'ın (e-posta/SMS'te kanonik adresin) özetidir.
    public static func loginBody(externalId: String, identityHash: String?, registeredToken: String?) -> [String: Any] {
        var body: [String: Any] = ["external_id": externalId]
        if let identityHash { body["identity_hash"] = identityHash }
        return withProof(body, registeredToken: registeredToken)
    }

    /**
     `POST /events` öğeleri: her olaya abonelik kimliği ve sahiplik kanıtı eklenir (ADR-0016 Karar 8) — `token_hash`
     kayıtlı token'ın (e-posta/SMS'te kanonik adresin) özeti, `identity_hash` kimlikli kullanıcının hash'i. Değer yoksa
     alan gönderilmez.
     */
    public static func eventItems(_ ops: [[String: Any]], subscriptionId: String, registeredToken: String?, identityHash: String?) -> [[String: Any]] {
        let proofHash = registeredToken.map { HSOwnership.tokenHash($0) }
        return ops.map { e in
            var event: [String: Any] = ["name": e["name"] ?? "", "properties": e["properties"] ?? [String: Any](), "occurred_at": e["occurred_at"] ?? "", "subscription_id": subscriptionId]
            if let value = e["value"] { event["value"] = value }
            // İstemci olay kimliği: yeniden denemede sunucu aynı olayı ikinci kez kaydetmez (eski kuyruk öğelerinde yok).
            if let eventId = e["event_id"] as? String, !eventId.isEmpty { event["event_id"] = eventId }
            if let proofHash { event["token_hash"] = proofHash }
            if let identityHash { event["identity_hash"] = identityHash }
            return event
        }
    }

    /// `DELETE` için sorgu dizesi (`?token_hash=…&identity_hash=…`); kanıt yoksa boş.
    public static func query(registeredToken: String?, identityHash: String? = nil) -> String {
        var params: [String] = []
        if let registeredToken { params.append("token_hash=\(tokenHash(registeredToken))") }
        if let identityHash, let encoded = identityHash.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            params.append("identity_hash=\(encoded)")
        }
        return params.isEmpty ? "" : "?" + params.joined(separator: "&")
    }

    /**
     In-app ve inbox `GET`/`DELETE` sorgusu (başında `?` yok): `subscription_id`, kayıtlı token'ın (e-posta/SMS'te
     kanonik adresin) özeti `token_hash` ve varsa `identity_hash`. Kanıtla kaydolan abonelikler ve e-posta/SMS
     abonelikleri için sunucu kanıtsız isteği reddeder (ADR-0016).
     */
    public static func subscriptionQuery(subscriptionId: String, registeredToken: String?, identityHash: String? = nil) -> String {
        var params = ["subscription_id=\(encodeQueryValue(subscriptionId))"]
        if let registeredToken { params.append("token_hash=\(tokenHash(registeredToken))") }
        if let identityHash { params.append("identity_hash=\(encodeQueryValue(identityHash))") }
        return params.joined(separator: "&")
    }

    /// In-app olayı ve inbox `read`/`read-all` gövdesi: `subscription_id` + sahiplik kanıtı (değer yoksa alan eklenmez).
    public static func subscriptionBody(_ body: [String: Any] = [:], subscriptionId: String, registeredToken: String?, identityHash: String? = nil) -> [String: Any] {
        var out = withProof(body, registeredToken: registeredToken, identityHash: identityHash)
        out["subscription_id"] = subscriptionId
        return out
    }

    /// Sorgu değeri için güvenli karakterler (`&`, `=`, `+`, `?`, `#` kodlanır).
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()

    private static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }
}

/// Kayıt ve izin PATCH'lerindeki `device` nesnesi.
public enum HSDeviceInfo {
    /// Bilinmeyen değerler (ör. `app_version`) JSON null yerine hiç gönderilmez.
    public static func make(model: String, os: String = "iOS", osVersion: String, appVersion: String?, sdkVersion: String, locale: String, timezone: String, pushCapable: Bool, pushEnvironment: String) -> [String: Any] {
        var info: [String: Any] = [
            "model": model,
            "os": os,
            "os_version": osVersion,
            "sdk_version": sdkVersion,
            "sdk_platform": "ios",
            "locale": locale,
            "timezone": timezone,
            "push_capable": pushCapable,
            "push_environment": pushEnvironment,
        ]
        if let appVersion, !appVersion.isEmpty { info["app_version"] = appVersion }
        return info
    }
}

/// Push token eşitleme sonucu.
public enum HSTokenSyncResult: Equatable {
    /// Token zaten kayıtlı; istek gönderilmedi.
    case unchanged
    /// Mevcut aboneliğin token'ı `PATCH` ile güncellendi.
    case updated
    /// Yeni abonelik oluşturuldu (`POST subscriptions`).
    case created(subscriptionId: String, userId: String?, externalId: String?)
}

/**
 Token yaşam döngüsü (docs/plan/06): kayıtlı abonelik varsa token değişikliğinde yeni abonelik açılmaz,
 `PATCH subscriptions/{id}` ile token yerinde güncellenir; abonelik sunucuda silinmişse (404) yeniden oluşturulur.
 Ağ katmanından bağımsızdır (birim testinde sahte istekçi ile sınanır).
 */
public struct HSTokenSync {
    public typealias Request = (_ method: String, _ path: String, _ body: [String: Any]?) async throws -> [String: Any]
    private let request: Request

    public init(request: @escaping Request) {
        self.request = request
    }

    public func sync(subscriptionId: String?, registeredToken: String?, token: String, device: [String: Any], user: [String: Any], channel: String = "ios_push") async throws -> HSTokenSyncResult {
        guard !token.isEmpty else { throw HSApiError(status: 400, code: "EMPTY_TOKEN", message: "boş token kaydedilemez") }
        if subscriptionId != nil, registeredToken == token { return .unchanged }
        if let subscriptionId {
            do {
                // Kanıt: sunucudaki (eski) token'ın özeti; yeni token bu istekle kaydedilir.
                let body = HSOwnership.withProof(["token": token, "device": device], registeredToken: registeredToken)
                _ = try await request("PATCH", "/subscriptions/\(subscriptionId)", body)
                return .updated
            } catch let error as HSApiError where error.status == 404 {
                // Abonelik sunucuda yok: aşağıda yeniden oluşturulur.
            }
        }
        let result = try await request("POST", "/subscriptions", ["channel": channel, "token": token, "device": device, "user": user, "ownership_proof": true])
        guard let id = result["subscription_id"] as? String else {
            throw HSApiError(status: 502, code: "BAD_RESPONSE", message: "subscription_id yok")
        }
        return .created(subscriptionId: id, userId: result["user_id"] as? String, externalId: result["external_id"] as? String)
    }
}

/// Alias (kullanıcı kimliği etiketi) doğrulaması; kurallar sunucu ile aynıdır.
public enum HSAliases {
    /// Tek istekte en fazla alias (SDK API sınırı).
    public static let maxPerRequest = 20
    private static let reserved: Set<String> = ["external_id", "hs_id"]

    /// Etiket geçerli mi: küçük harf, rakam, alt çizgi (1-50); external_id/hs_id ayrılmıştır.
    public static func isValidLabel(_ label: String) -> Bool {
        guard (1...50).contains(label.count), !reserved.contains(label) else { return false }
        return label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Geçerli alias haritası (değerler kırpılır); geçersiz girdide nil.
    public static func normalize(_ aliases: [String: String]) -> [String: String]? {
        guard !aliases.isEmpty, aliases.count <= maxPerRequest else { return nil }
        var out: [String: String] = [:]
        for (label, raw) in aliases {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidLabel(label), (1...255).contains(value.count) else { return nil }
            out[label] = value
        }
        return out
    }
}
