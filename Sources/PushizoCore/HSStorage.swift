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
    /// Login'de veya `updateUserJwt` ile verilen kimlik JWT'si (ADR-0023 §9); `Authorization` başlığına eklenir, logout ile silinir.
    public var identityJwt: String? { get { defaults.string(forKey: key("identity_jwt")) } set { defaults.set(newValue, forKey: key("identity_jwt")) } }
    public var deviceToken: String? { get { defaults.string(forKey: key("device_token")) } set { defaults.set(newValue, forKey: key("device_token")) } }
    public var registeredToken: String? { get { defaults.string(forKey: key("registered_token")) } set { defaults.set(newValue, forKey: key("registered_token")) } }
    public var optedIn: Bool { get { defaults.object(forKey: key("opted_in")) as? Bool ?? true } set { defaults.set(newValue, forKey: key("opted_in")) } }
    public var consentGiven: Bool { get { defaults.bool(forKey: key("consent")) } set { defaults.set(newValue, forKey: key("consent")) } }
    /// Uygulamanın `requiresPrivacyConsent` seçeneği; NSE onay kontrolü için App Group'a yazılır.
    public var privacyConsentRequired: Bool { get { defaults.bool(forKey: key("consent_required")) } set { defaults.set(newValue, forKey: key("consent_required")) } }
    /// Onay beklerken yerelde yapılan kimlik işlemi (`login`/`logout`); onay verilince sunucuya iletilir.
    public var pendingIdentityOperation: String? { get { defaults.string(forKey: key("pending_identity_op")) } set { defaults.set(newValue, forKey: key("pending_identity_op")) } }
    /// `optIn`/`optOut` sunucuya iletilemedi (onay bekleniyordu); onay verilince `opted_in` PATCH edilir.
    public var optedInSyncPending: Bool { get { defaults.bool(forKey: key("opted_in_sync_pending")) } set { defaults.set(newValue, forKey: key("opted_in_sync_pending")) } }
    /// Sunucudaki aboneliğe en son yazılan `device.push_capable`; güncel izinden farklıysa yeniden PATCH edilir.
    public var syncedPushCapable: Bool? { get { defaults.object(forKey: key("synced_push_capable")) as? Bool } set { defaults.set(newValue, forKey: key("synced_push_capable")) } }
    public var tags: [String: String] { get { defaults.dictionary(forKey: key("tags")) as? [String: String] ?? [:] } set { defaults.set(newValue, forKey: key("tags")) } }
    /// `Location.setShared`: konum paylaşımı açık mı (varsayılan kapalı; v2 Faz 17b).
    public var locationShared: Bool { get { defaults.bool(forKey: key("location_shared")) } set { defaults.set(newValue, forKey: key("location_shared")) } }
    /// Son konum işleminin kuyruğa yazıldığı an (epoch saniye); 5 dakika aralığı için.
    public var locationLastSentAt: TimeInterval? {
        get { (defaults.object(forKey: key("location_last_sent_at")) as? NSNumber)?.doubleValue }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: key("location_last_sent_at")) }
    }
    /// Herhangi bir in-app mesajın bu cihazdaki son gösterimi; app geneli aralık için (ADR-0019 §7).
    public var lastInAppImpressionAt: Date? {
        get { (defaults.object(forKey: key("in_app_last_impression_at")) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        set { defaults.set(newValue.map { NSNumber(value: $0.timeIntervalSince1970) }, forKey: key("in_app_last_impression_at")) }
    }
    /// Config'den gelen `in_app.min_interval_seconds`; config alınamazsa son bilinen değer kullanılır.
    public var inAppMinIntervalSeconds: Int { get { defaults.integer(forKey: key("in_app_min_interval_seconds")) } set { defaults.set(newValue, forKey: key("in_app_min_interval_seconds")) } }
    /// Öğrenilen bölgesel API kökü (ADR-0032 §4; config `api_url` veya 421 `HS_WRONG_CELL`) ve öğrenildiği başlangıç
    /// kökü (`HSOptions.apiUrl`). App Group ile NSE'ye de geçer; başlangıç kökü değişirse kullanılmaz.
    public var regionalApiUrl: String? { get { defaults.string(forKey: key("regional_api_url")) } set { defaults.set(newValue, forKey: key("regional_api_url")) } }
    public var regionalApiSeed: String? { get { defaults.string(forKey: key("regional_api_seed")) } set { defaults.set(newValue, forKey: key("regional_api_seed")) } }

    /// Bölgesel kökü başlangıç köküyle birlikte saklar.
    public func saveRegionalApi(seed: String, url: String) {
        regionalApiSeed = HSCellRouting.trimSlash(seed)
        regionalApiUrl = url
    }

    /// Başlangıç kökü için kullanılacak API kökü (kayıtlı geçerli bölgesel kök veya `seed`).
    public func resolvedApiUrl(seed: String) -> String {
        HSCellRouting.initialBase(seed: seed, savedSeed: regionalApiSeed, savedUrl: regionalApiUrl)
    }

    /// NSE: uygulama kapalıyken gönderilemeyen `received` bildirimleri.
    public var pendingReceived: [String] { get { defaults.stringArray(forKey: key("pending_received")) ?? [] } set { defaults.set(newValue, forKey: key("pending_received")) } }

    /// `pendingReceived` oku-değiştir-yaz işlemleri için (aynı süreçteki NSE örnekleri ve uygulama).
    private static let pendingReceivedLock = NSLock()
    /// En fazla bu kadar bekleyen `received` kaydı tutulur (en eskiler atılır).
    public static let pendingReceivedMax = 100

    /// Teslimat kimliğini bekleyen `received` listesine ekler (tekrarı eklenmez).
    public func addPendingReceived(_ deliveryId: String) {
        HSStorage.pendingReceivedLock.lock(); defer { HSStorage.pendingReceivedLock.unlock() }
        var list = pendingReceived
        guard !list.contains(deliveryId) else { return }
        list.append(deliveryId)
        pendingReceived = Array(list.suffix(HSStorage.pendingReceivedMax))
    }

    /// `received` gönderildi: kimlik bekleyen listeden çıkarılır.
    public func removePendingReceived(_ deliveryId: String) {
        HSStorage.pendingReceivedLock.lock(); defer { HSStorage.pendingReceivedLock.unlock() }
        let list = pendingReceived
        guard list.contains(deliveryId) else { return }
        pendingReceived = list.filter { $0 != deliveryId }
    }

    /// Bekleyen tüm `received` kayıtlarını alır ve listeyi boşaltır.
    public func takePendingReceived() -> [String] {
        HSStorage.pendingReceivedLock.lock(); defer { HSStorage.pendingReceivedLock.unlock() }
        let list = pendingReceived
        if !list.isEmpty { pendingReceived = [] }
        return list
    }

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

    // MARK: - Canlı sohbet (ADR-0040 §2)

    /// Sohbet ziyaretçi kimliği (gizli değil; UserDefaults).
    public var chatVisitorId: String? { get { defaults.string(forKey: key("chat_visitor_id")) } set { defaults.set(newValue, forKey: key("chat_visitor_id")) } }
    /**
     Sohbet ziyaretçi belirteci (gizli): Keychain'de (`AfterFirstUnlockThisDeviceOnly`) saklanır; Keychain kullanılamazsa
     (ör. imzasız test ortamı) uygulamanın UserDefaults'una düşülür. Loglanmaz; sunucu yalnızca SHA-256 özetini tutar.
     */
    public var chatVisitorToken: String? {
        get { HSKeychain.read(account: key("chat_visitor_token")) ?? defaults.string(forKey: key("chat_visitor_token")) }
        set {
            if HSKeychain.write(newValue, account: key("chat_visitor_token")) {
                defaults.removeObject(forKey: key("chat_visitor_token"))
            } else {
                defaults.set(newValue, forKey: key("chat_visitor_token"))
            }
        }
    }
    /// Uygulama sohbeti başlattı mı; kapalıyken login/abonelik değişiminde sohbet uçları çağrılmaz.
    public var chatEnabled: Bool { get { defaults.bool(forKey: key("chat_enabled")) } set { defaults.set(newValue, forKey: key("chat_enabled")) } }
    /// Son başarılı `chat/identify` girdisinin özeti (değişmediyse istek tekrarlanmaz).
    public var chatIdentifyKey: String? { get { defaults.string(forKey: key("chat_identify_key")) } set { defaults.set(newValue, forKey: key("chat_identify_key")) } }
    /// Görülen en büyük mesaj sıra numarası (akış yeniden kurulunca `Last-Event-ID`).
    public var chatLastSeq: Int { get { defaults.integer(forKey: key("chat_last_seq")) } set { defaults.set(newValue, forKey: key("chat_last_seq")) } }
    /// Sunucuya bildirilen son teslim işaretçisi.
    public var chatDeliveredSeq: Int { get { defaults.integer(forKey: key("chat_delivered_seq")) } set { defaults.set(newValue, forKey: key("chat_delivered_seq")) } }
    /// Son bilinen okunmamış mesaj sayısı.
    public var chatUnreadCount: Int { get { defaults.integer(forKey: key("chat_unread_count")) } set { defaults.set(newValue, forKey: key("chat_unread_count")) } }

    /// Ziyaretçiyi sıfırlar (logout / gizlilik onayının geri alınması); sonraki sohbet yeni kimlikle başlar.
    public func clearChatVisitor() {
        _ = HSKeychain.write(nil, account: key("chat_visitor_token"))
        for name in ["chat_visitor_id", "chat_visitor_token", "chat_identify_key", "chat_last_seq", "chat_delivered_seq", "chat_unread_count"] {
            defaults.removeObject(forKey: key(name))
        }
    }

    /// Kimlik temizliği; e-posta/SMS abonelikleri önceki kullanıcıda kalır, cihazdaki eşlemeleri silinir.
    public func clearIdentity() {
        for name in ["user_id", "external_id", "identity_hash", "user_identity_hash", "identity_jwt", "tags", "contacts_email", "contacts_sms", "pending_identity_op"] { defaults.removeObject(forKey: key(name)) }
    }
}
