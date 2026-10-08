import Foundation

/// App başına kalıcı SDK durumu. App Group verilirse NSE ile paylaşılır.
public final class HSStorage {
    public let defaults: UserDefaults
    private let prefix: String

    public init(appId: String, appGroup: String? = nil) {
        self.defaults = appGroup.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.prefix = "hs.\(appId)."
    }

    private func key(_ name: String) -> String { prefix + name }

    public var subscriptionId: String? { get { defaults.string(forKey: key("subscription_id")) } set { defaults.set(newValue, forKey: key("subscription_id")) } }
    public var userId: String? { get { defaults.string(forKey: key("user_id")) } set { defaults.set(newValue, forKey: key("user_id")) } }
    public var externalId: String? { get { defaults.string(forKey: key("external_id")) } set { defaults.set(newValue, forKey: key("external_id")) } }
    public var pendingIdentityHash: String? { get { defaults.string(forKey: key("identity_hash")) } set { defaults.set(newValue, forKey: key("identity_hash")) } }
    /// Login'de verilen kimlik doğrulama hash'i; kullanıcı çağrılarına (tag, alias) eklenir, logout ile silinir.
    public var userIdentityHash: String? { get { defaults.string(forKey: key("user_identity_hash")) } set { defaults.set(newValue, forKey: key("user_identity_hash")) } }
    public var deviceToken: String? { get { defaults.string(forKey: key("device_token")) } set { defaults.set(newValue, forKey: key("device_token")) } }
    public var registeredToken: String? { get { defaults.string(forKey: key("registered_token")) } set { defaults.set(newValue, forKey: key("registered_token")) } }
    public var optedIn: Bool { get { defaults.object(forKey: key("opted_in")) as? Bool ?? true } set { defaults.set(newValue, forKey: key("opted_in")) } }
    public var consentGiven: Bool { get { defaults.bool(forKey: key("consent")) } set { defaults.set(newValue, forKey: key("consent")) } }
    public var tags: [String: String] { get { defaults.dictionary(forKey: key("tags")) as? [String: String] ?? [:] } set { defaults.set(newValue, forKey: key("tags")) } }
    /// Herhangi bir in-app mesajın bu cihazdaki son gösterimi; app geneli aralık için (ADR-0019 §7).
    public var lastInAppImpressionAt: Date? {
        get { (defaults.object(forKey: key("in_app_last_impression_at")) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        set { defaults.set(newValue.map { NSNumber(value: $0.timeIntervalSince1970) }, forKey: key("in_app_last_impression_at")) }
    }
    /// Config'den gelen `in_app.min_interval_seconds`; config alınamazsa son bilinen değer kullanılır.
    public var inAppMinIntervalSeconds: Int { get { defaults.integer(forKey: key("in_app_min_interval_seconds")) } set { defaults.set(newValue, forKey: key("in_app_min_interval_seconds")) } }
    /// NSE: uygulama kapalıyken gönderilemeyen `received` bildirimleri.
    public var pendingReceived: [String] { get { defaults.stringArray(forKey: key("pending_received")) ?? [] } set { defaults.set(newValue, forKey: key("pending_received")) } }

    /// E-posta/SMS abonelikleri: kanal (`email`/`sms`) → normalize adres → abonelik kimliği.
    public func contacts(_ channel: String) -> [String: String] {
        defaults.dictionary(forKey: key("contacts_\(channel)")) as? [String: String] ?? [:]
    }

    public func putContact(_ channel: String, address: String, subscriptionId: String) {
        var map = contacts(channel)
        map[address] = subscriptionId
        defaults.set(map, forKey: key("contacts_\(channel)"))
    }

    public func removeContact(_ channel: String, address: String) {
        var map = contacts(channel)
        map.removeValue(forKey: address)
        defaults.set(map, forKey: key("contacts_\(channel)"))
    }

    /// Kimlik temizliği; e-posta/SMS abonelikleri önceki kullanıcıda kalır, cihazdaki eşlemeleri silinir.
    public func clearIdentity() {
        for name in ["user_id", "external_id", "identity_hash", "user_identity_hash", "tags", "contacts_email", "contacts_sms"] { defaults.removeObject(forKey: key(name)) }
    }
}
