import Foundation

/// App'in kabul ettiği kimlik kanıtı (ADR-0023 §9): HMAC `identity_hash`, ES256 JWT veya ikisinden biri.
public enum HSIdentityVerificationMode: String {
    case hmac
    case jwt
    case both

    /// `/config` yanıtındaki `identity_verification_mode`; alan yoksa veya tanınmıyorsa `hmac` (eski sunucular).
    public init(config value: Any?) {
        self = (value as? String).flatMap(HSIdentityVerificationMode.init(rawValue:)) ?? .hmac
    }
}

/// Login öncesi kimlik kanıtı kuralları (web SDK `login` ile aynı).
public enum HSIdentityVerification {
    /// Doğrulama zorunluysa verilen kanıtın app moduna uyup uymadığını denetler; uymuyorsa hata mesajı döner.
    public static func loginError(required: Bool, mode: HSIdentityVerificationMode, identityHash: String?, jwt: String?) -> String? {
        guard required else { return nil }
        let hasHash = !(identityHash ?? "").isEmpty
        let hasJwt = !(jwt ?? "").isEmpty
        switch mode {
        case .jwt where !hasJwt: return "Bu app için kimlik JWT'si (login(_:jwt:)) zorunlu."
        case .hmac where !hasHash: return "Bu app için identityHash zorunlu."
        case .both where !hasHash && !hasJwt: return "Bu app için identityHash veya JWT zorunlu."
        default: return nil
        }
    }
}
