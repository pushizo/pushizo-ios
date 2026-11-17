import Foundation

/**
 İstemci olay kimliği (`event_id`): olay kuyruğa alınırken bir kez belirlenir ve yeniden denemelerde aynı kalır; sunucu
 aynı `event_id` + `occurred_at` ikilisini ikinci kez kaydetmez. Uygulama kendi kimliğini verebilir
 (`Session.sendEvent(..., eventId:)`); biçim Web ve Android SDK'larıyla aynıdır: 8-64 karakter, harf, rakam ve `._:-`.
 */
public enum HSEventId {
    private static let pattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:-]{8,64}$")

    /// Uygulamanın verdiği kimlik geçerliyse kendisi, değilse nil (SDK kendi kimliğini üretir).
    public static func valid(_ given: String?) -> String? {
        guard let given, HSContacts.fullMatch(pattern, given) else { return nil }
        return given
    }

    /// Kuyruğa yazılacak kimlik: geçerli `given`, yoksa yeni rastgele UUID (küçük harf).
    public static func resolve(_ given: String?) -> String {
        valid(given) ?? UUID().uuidString.lowercased()
    }
}
