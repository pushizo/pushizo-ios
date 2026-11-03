import Foundation
import Security

/// Özellik bayrağı kuralları (ADR-0066; birim testli).
public enum HSFeatureFlagRules {
    /// Sunucu yanıtından önbelleğe yazılacak `{ anahtar: { enabled, value } }`; yanıt bozuksa nil (son değerler korunur).
    public static func parse(_ response: [String: Any]) -> [String: [String: Any]]? {
        guard let flags = response["flags"] as? [String: Any] else { return nil }
        var out: [String: [String: Any]] = [:]
        for (key, raw) in flags {
            guard let item = raw as? [String: Any], let enabled = item["enabled"] as? Bool else { continue }
            var entry: [String: Any] = ["enabled": enabled]
            if let value = item["value"], !(value is NSNull) { entry["value"] = value }
            out[key] = entry
        }
        return out
    }

    public static func isEnabled(_ cache: [String: [String: Any]]?, key: String, default fallback: Bool) -> Bool {
        (cache?[key]?["enabled"] as? Bool) ?? fallback
    }

    public static func value(_ cache: [String: [String: Any]]?, key: String) -> Any? {
        cache?[key]?["value"]
    }

    public static func newSubject() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return "anon_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Abonelik varsa kimliği ve sahiplik kanıtı, yoksa kalıcı rastgele kimlik gönderilir.
    public static func body(subscriptionId: String?, subject: String, registeredToken: String?, identityHash: String?) -> [String: Any] {
        guard let subscriptionId else { return ["subject": subject] }
        return HSOwnership.withProof(["subscription_id": subscriptionId], registeredToken: registeredToken, identityHash: identityHash)
    }
}
