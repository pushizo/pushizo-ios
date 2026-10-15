import Foundation

/**
 Konum paylaşımının CoreLocation'dan bağımsız kuralları (v2 Faz 17b; birim testli). Konum yalnızca kullanıcı paylaşımı
 açtıysa (`HeroSignal.Location.setShared(true)`), gizlilik onayı varsa (veya gerekmiyorsa), konum izni verilmişse ve
 uygulama ön plandaysa en sık `minInterval` aralıkla toplanır. Gönderim `PATCH /subscriptions/{id}` gövdesindeki
 `location` alanıyla, kalıcı kuyruk üzerinden yapılır; kapatmada `location: null` gider ve sunucu konumu ile KVKK rıza
 kaydını hemen siler. İlk konum gönderimi sunucuda açık rıza kaydı sayılır.
 */
public enum HSLocationRules {
    /// Kuyruk işlemi türü.
    public static let operationType = "location"
    /// İki konum gönderimi arasındaki en kısa süre (5 dakika).
    public static let minInterval: TimeInterval = 5 * 60
    /// Sunucu sınırı (`accuracy_m` 0..100000 metre).
    public static let maxAccuracyMeters: Double = 100_000

    /// Konum şimdi alınıp gönderilmeli mi: paylaşım açık, ağ (onay) serbest, izin var ve aralık dolmuş (veya `force`).
    public static func isDue(shared: Bool, networkAllowed: Bool, permissionGranted: Bool, lastSentAt: TimeInterval?, now: TimeInterval, force: Bool = false) -> Bool {
        guard shared, networkAllowed, permissionGranted else { return false }
        guard !force, let last = lastSentAt else { return true }
        // Cihaz saati geri alındıysa (now < last) bekleme kilitlenmesin diye gönderilir.
        return now < last || now - last >= minInterval
    }

    /**
     `{ lat, lng, accuracy_m? }`: enlem -90..90, boylam -180..180 (aralık dışı veya sonlu olmayan değerde nil). Koordinatlar
     6 ondalığa (~11 cm) yuvarlanır; doğruluk 100 km'ye kırpılır, negatifse (CoreLocation: geçersiz) gönderilmez.
     */
    public static func payload(latitude: Double, longitude: Double, accuracy: Double?) -> [String: Any]? {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        var location: [String: Any] = ["lat": round6(latitude), "lng": round6(longitude)]
        if let accuracy, accuracy.isFinite, accuracy >= 0 {
            location["accuracy_m"] = min(maxAccuracyMeters, (accuracy * 10).rounded() / 10)
        }
        return location
    }

    private static func round6(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }

    /// Konum gönderme işlemi (UserDefaults'a yazılabilir; `NSNull` içermez).
    public static func operation(location: [String: Any], at: TimeInterval = Date().timeIntervalSince1970) -> [String: Any] {
        ["type": operationType, "location": location, "at": at]
    }

    /// Paylaşım kapatıldı: sunucudaki konum ve rıza kaydı silinir (`location: null`).
    public static func clearOperation(at: TimeInterval = Date().timeIntervalSince1970) -> [String: Any] {
        ["type": operationType, "clear": true, "at": at]
    }

    /// Silme işlemi mi.
    public static func isClear(_ op: [String: Any]) -> Bool { op["clear"] as? Bool == true }

    /**
     `PATCH /subscriptions/{id}` gövdesi: `location` (silmede `NSNull` → JSON `null`) ve `opted_in` güncellemesiyle aynı
     sahiplik kanıtı (`token_hash`). Bozuk işlemde nil (atılır).
     */
    public static func body(for op: [String: Any], registeredToken: String?) -> [String: Any]? {
        if isClear(op) { return HSOwnership.withProof(["location": NSNull()], registeredToken: registeredToken) }
        guard let location = op["location"] as? [String: Any],
              let lat = (location["lat"] as? NSNumber)?.doubleValue,
              let lng = (location["lng"] as? NSNumber)?.doubleValue,
              let checked = payload(latitude: lat, longitude: lng, accuracy: (location["accuracy_m"] as? NSNumber)?.doubleValue) else { return nil }
        return HSOwnership.withProof(["location": checked], registeredToken: registeredToken)
    }

    /**
     Kuyrukta bu işlemden sonra yazılmış bir konum işlemi varsa bu işlem gönderilmez: son durum kazanır (paylaşım kapatılınca
     henüz gönderilmemiş konum da hiç gönderilmez). İşlemler yerinde bırakılır; kuyruk sırası korunur.
     */
    public static func isSuperseded(_ op: [String: Any], queue: [[String: Any]]) -> Bool {
        guard let index = queue.lastIndex(where: { NSDictionary(dictionary: $0).isEqual(to: op) }) else { return false }
        return queue[(index + 1)...].contains { $0["type"] as? String == operationType }
    }
}
