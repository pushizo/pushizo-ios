import Foundation
// SPM: ayrı modül (uygulamalar `import HeroSignal` ile çekirdek tiplere de erişsin diye yeniden dışa aktarılır);
// CocoaPods alt spec'leri tek "HeroSignal" modülünde derlenir.
#if canImport(HeroSignalCore)
@_exported import HeroSignalCore
#endif
import UIKit
import UserNotifications

/// Bildirim tıklaması bilgisi.
public struct HSClickEvent {
    public let notification: HSNotification
    public let actionId: String?
    public let url: String?
}

/**
 Ön planda gelen bildirim; `preventDefault()` gösterimi engeller. Karar sonradan verilecekse (ör. Flutter/Dart)
 önce `preventDefault()`, ardından 25 sn içinde gerekirse `display()` çağrılır.
 */
public final class HSForegroundEvent {
    /// `preventDefault()` sonrası `display()` için bekleme süresi; dolunca bildirim gösterilmeden kapanır.
    public static let displayTimeout: TimeInterval = 25
    public let notification: HSNotification
    public private(set) var prevented = false
    private let lock = NSLock()
    private var completion: ((Bool) -> Void)?

    init(notification: HSNotification, completion: ((Bool) -> Void)? = nil) {
        self.notification = notification
        self.completion = completion
    }

    public func preventDefault() { prevented = true }

    /// Bildirimi şimdi gösterir (yalnızca bir kez; `preventDefault()` sonrasında da çalışır).
    public func display() { complete(true) }

    func complete(_ show: Bool) {
        lock.lock()
        let handler = completion
        completion = nil
        lock.unlock()
        handler?(show)
    }
}

/// SDK kullanım hataları (bildirim kutusu vb.).
public enum HSError: Error, Equatable {
    /// `HeroSignal.initialize` çağrılmadı.
    case notInitialized
    /// Push veya e-posta/SMS aboneliği henüz kaydedilmedi (ya da gizlilik onayı bekleniyor).
    case noSubscription
    /// Kullanıcı kimliği henüz yok.
    case noUser
    case invalidArgument(String)
    case invalidResponse
}

public struct HSPushSubscriptionState {
    public let id: String?
    public let token: String?
    public let optedIn: Bool
    public let permission: UNAuthorizationStatus
}

/// SDK yapılandırması.
public struct HSOptions {
    public var apiUrl: String = "https://api.herosignal.dev"
    /// KVKK/GDPR: onay verilene kadar ağ çağrısı yapılmaz.
    public var requiresPrivacyConsent = false
    /// APNs ortamı ("sandbox"/"development" veya "production"); nil ise DEBUG derlemesi ya da gömülü
    /// provisioning profilindeki `aps-environment` ile tespit edilir (`device.push_environment`).
    public var apnsEnvironment: String?
    /// NSE ile durum paylaşımı için App Group (ör. "group.com.example.app"). Rozet sayacı için verilmezse
    /// Info.plist `HeroSignalAppGroup`, o da yoksa `group.<bundle id>.herosignal` kullanılır.
    public var appGroup: String?
    /// Provisional (sessiz) izin ile başla.
    public var provisionalAuthorization = false
    public var logLevel: HSLog.Level = .warn
    public init() {}
}

public enum HSLog {
    public enum Level: Int { case none = 0, error, warn, info, debug }
    public static var level: Level = .warn
    static func log(_ l: Level, _ message: @autoclosure () -> String) {
        guard level.rawValue >= l.rawValue else { return }
        print("[HeroSignal] \(message())")
    }
}

/**
 HeroSignal iOS SDK (eski sağlayıcı v5 yüzeyiyle uyumlu).

 ```swift
 HeroSignal.initialize("app_…", launchOptions: launchOptions) { $0.apiUrl = "https://api.example.com" }
 HeroSignal.Notifications.requestPermission { accepted in }
 HeroSignal.login("user_42")
 HeroSignal.User.addTag("plan", "pro")
 HeroSignal.User.addEmail("ali@example.com")
 HeroSignal.InAppMessages.addTrigger("level", "gold")
 let page = try await HeroSignal.Inbox.list(limit: 20)
 ```
 */
public enum HeroSignal {
    public static let sdkVersion = "0.1.0"
    static var appId = ""
    static var options = HSOptions()
    static var storage: HSStorage?
    static var api: HSApi?
    static var queue: HSQueue?
    static var badgeStore: HSBadgeStore?
    static var errorReporter: HSErrorReporter?
    static var errorFlushScheduled = false
    static var identityVerificationRequired = false
    static var sessionStartedAt: Date?
    static var clickListeners: [(HSClickEvent) -> Void] = []
    static var foregroundListeners: [(HSForegroundEvent) -> Void] = []
    static var subscriptionObservers: [(HSPushSubscriptionState) -> Void] = []
    static var pendingClick: HSClickEvent?
    static let delegate = HSNotificationDelegate()
    static let inApp = HSInAppController()
    static var observers: [NSObjectProtocol] = []

    public static var isInitialized: Bool { storage != nil }

    /// Uygulama başlangıcında (AppDelegate `didFinishLaunching` veya SwiftUI `init`) çağrılır.
    public static func initialize(_ appId: String, launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil, configure: ((inout HSOptions) -> Void)? = nil) {
        precondition(!appId.isEmpty, "HeroSignal.initialize: appId gerekli")
        var opts = HSOptions()
        configure?(&opts)
        self.appId = appId
        self.options = opts
        HSLog.level = opts.logLevel
        let store = HSStorage(appId: appId, appGroup: opts.appGroup)
        storage = store
        api = HSApi(apiUrl: opts.apiUrl, appId: appId, sdkVersion: sdkVersion)
        queue = HSQueue(defaults: store.defaults, appId: appId)
        badgeStore = HSBadgeStore(appGroup: HSAppGroup.resolve(opts.appGroup))
        errorReporter = HSErrorReporter(platform: "ios", sdkVersion: sdkVersion)
        UNUserNotificationCenter.current().delegate = delegate
        // Düğmesiz bildirimlerin kapatılma (dismissed) geri bildirimi için; mevcut kategoriler korunur.
        Task { await HSCategories.register(HSCategories.category(identifier: HSCategories.defaultIdentifier, actions: [])) }
        observeLifecycle()
        if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any], let n = HSNotification(userInfo: userInfo) {
            // Uygulama bildirimden açıldı
            reportOpened(n, actionId: nil)
        }
        if opts.requiresPrivacyConsent && !store.consentGiven {
            HSLog.log(.info, "gizlilik onayı bekleniyor")
            return
        }
        start()
    }

    public static func setConsentGiven(_ given: Bool) {
        guard let store = storage else { return }
        store.consentGiven = given
        if given { start() } else { queue?.clear(); store.clearIdentity() }
    }

    static func start() {
        Task {
            do {
                if let config = try await api?.request("GET", "/config") {
                    identityVerificationRequired = config["identity_verification_required"] as? Bool ?? false
                }
            } catch {
                HSLog.log(.warn, "config alınamadı: \(error)")
                reportError("config_failed", "app yapılandırması alınamadı", error: error)
            }
            // Daha önce alınmış token varsa kaydı eşitle; izin verildiyse APNs kaydı yenilenir.
            if let token = storage?.deviceToken { await registerIfNeeded(token: token) }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
            await flushPendingReceived()
            await flushQueue()
        }
    }

    /// Kuyruğu işler; kalıcı olarak reddedilen işlemler hata raporuna eklenir.
    static func flushQueue() async {
        _ = await queue?.flush(perform) { op, error in
            reportError("operation_rejected", "kuyruk işlemi sunucu tarafından reddedildi", error: error, context: ["operation": op["type"] as? String ?? ""])
        }
    }

    // MARK: - SDK hata raporları

    /// SDK iç hatasını toplu hata raporuna ekler (en iyi çaba; ağ hataları ve tekrarlar atlanır, PII içermez).
    static func reportError(_ code: String, _ message: String, error: Error? = nil, context: [String: Any] = [:], level: String = "error") {
        guard let store = storage, let reporter = errorReporter else { return }
        if options.requiresPrivacyConsent && !store.consentGiven { return }
        guard reporter.record(code: code, message: message, error: error, subscriptionId: store.subscriptionId, context: context, level: level) else { return }
        guard !errorFlushScheduled else { return }
        errorFlushScheduled = true
        Task {
            // Kısa bekleme: aynı anda oluşan hatalar tek istekte gider.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            errorFlushScheduled = false
            while let batch = reporter.drain() {
                // Rapor gönderilemezse yeniden raporlanmaz (özyineleme yok).
                _ = try? await api?.request("POST", "/errors", body: batch)
            }
        }
    }

    // MARK: - Token

    /// AppDelegate `didRegisterForRemoteNotificationsWithDeviceToken` içinden çağrılır (swizzling kullanılmaz; açık delegasyon).
    public static func setDeviceToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        storage?.deviceToken = hex
        Task { await registerIfNeeded(token: hex) }
    }

    /// Token alınamadığında (`didFailToRegisterForRemoteNotificationsWithError`).
    public static func setDeviceTokenError(_ error: Error) {
        HSLog.log(.warn, "APNs kaydı başarısız: \(error.localizedDescription)")
        reportError("apns_registration_failed", "APNs kaydı başarısız", error: error)
    }

    /// Token'ı sunucuyla eşitler: kayıt yoksa oluşturur, APNs token'ı değiştiyse mevcut aboneliği PATCH eder.
    static func registerIfNeeded(token: String) async {
        guard let store = storage, let api else { return }
        if options.requiresPrivacyConsent && !store.consentGiven { return }
        if store.registeredToken == token, store.subscriptionId != nil { return }
        var user: [String: Any] = [:]
        if let ext = store.externalId { user["external_id"] = ext }
        if let hash = store.pendingIdentityHash ?? store.userIdentityHash { user["identity_hash"] = hash }
        // Anonim cihazda önce e-posta/SMS eklendiyse push aboneliği de aynı kullanıcıya bağlanır.
        if store.externalId == nil, let contact = store.contacts("email").first ?? store.contacts("sms").first {
            user["subscription_id"] = contact.value
            // Bağlanan e-posta/SMS aboneliğinin sahiplik kanıtı: kanonik adresin özeti (ADR-0016).
            user["token_hash"] = HSOwnership.tokenHash(contact.key)
        }
        let sync = HSTokenSync { method, path, body in try await api.request(method, path, body: body) }
        do {
            let result = try await sync.sync(subscriptionId: store.subscriptionId, registeredToken: store.registeredToken, token: token, device: await deviceInfo(), user: user)
            switch result {
            case .unchanged:
                return
            case .updated:
                store.registeredToken = token
            case let .created(subscriptionId, userId, externalId):
                store.subscriptionId = subscriptionId
                store.userId = userId
                store.externalId = externalId
                store.registeredToken = token
                store.pendingIdentityHash = nil
                if !store.optedIn {
                    _ = try? await api.request("PATCH", "/subscriptions/\(subscriptionId)", body: HSOwnership.withProof(["opted_in": false], registeredToken: token))
                }
                inApp.onSubscriptionChanged()
            }
            notifySubscription()
            await flushQueue()
        } catch {
            HSLog.log(.warn, "abonelik kaydı başarısız: \(error)")
            reportError("registration_failed", "push aboneliği kaydedilemedi", error: error)
        }
    }

    static func deviceInfo() async -> [String: Any] {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let device = await UIDevice.current
        let model = await device.model
        let systemVersion = await device.systemVersion
        return [
            "model": model,
            "os": "iOS",
            "os_version": systemVersion,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? NSNull(),
            "sdk_version": sdkVersion,
            "sdk_platform": "ios",
            "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            "timezone": TimeZone.current.identifier,
            "push_capable": settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
            "push_environment": pushEnvironment(),
        ]
    }

    /// APNs ortamı: açık seçenek → DEBUG derlemesi → gömülü provisioning profilinin `aps-environment` değeri.
    static func pushEnvironment() -> String {
        if let explicit = options.apnsEnvironment?.lowercased() {
            return explicit == "sandbox" || explicit == "development" ? "sandbox" : "production"
        }
        #if DEBUG
        return "sandbox"
        #else
        return provisioningApsEnvironment == "development" ? "sandbox" : "production"
        #endif
    }

    /// `embedded.mobileprovision` içindeki `aps-environment` (App Store derlemelerinde dosya yoktur → nil).
    static let provisioningApsEnvironment: String? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }
        let plistData = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }()

    // MARK: - E-posta / SMS ve etkileşim aboneliği

    /// In-app ve bildirim kutusu çağrılarında kullanılan abonelik: push, yoksa kayıtlı ilk e-posta/SMS. Onay bekleniyorsa nil.
    static func engagementSubscriptionId() -> String? {
        guard let store = storage else { return nil }
        if options.requiresPrivacyConsent && !store.consentGiven { return nil }
        return store.subscriptionId ?? store.contacts("email").values.first ?? store.contacts("sms").values.first
    }

    /// Kuyrukta henüz gönderilmemiş in-app olayı (gösterim/tıklama/kapatma) bulunan mesaj kimlikleri.
    static func pendingInAppMessageIds() -> Set<String> {
        Set((queue?.items ?? []).compactMap { op in
            op["type"] as? String == "in_app_event" ? op["message_id"] as? String : nil
        })
    }

    /// E-posta/SMS aboneliği oluşturur: kimlikli kullanıcıya `external_id`, anonimde cihaz aboneliğine (`subscription_id`) bağlanır.
    static func addContact(channel: String, address: String) async throws {
        guard let store = storage, let api else { return }
        if store.contacts(channel)[address] != nil { return }
        var device: [String: Any] = [
            "sdk_version": sdkVersion,
            "sdk_platform": "ios",
            "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            "timezone": TimeZone.current.identifier,
        ]
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { device["app_version"] = appVersion }
        var body: [String: Any] = ["channel": channel, "token": address, "device": device, "ownership_proof": true]
        if var user = HSContacts.registrationUser(externalId: store.externalId, identityHash: store.userIdentityHash, subscriptionId: engagementSubscriptionId()) {
            // Cihaz aboneliğine bağlamada hedef aboneliğin sahiplik kanıtı (ADR-0016).
            if let linked = user["subscription_id"], let token = ownershipToken(store, subscriptionId: linked) {
                user["token_hash"] = HSOwnership.tokenHash(token)
            }
            body["user"] = user
        }
        let result = try await api.request("POST", "/subscriptions", body: body)
        guard let subId = result["subscription_id"] as? String else { return }
        let hadEngagementSubscription = engagementSubscriptionId() != nil
        store.putContact(channel, address: address, subscriptionId: subId)
        // Push aboneliği yoksa kullanıcı kimliği bu abonelikten alınır (inbox/in-app için).
        if store.subscriptionId == nil, store.userId == nil { store.userId = result["user_id"] as? String }
        if !hadEngagementSubscription { inApp.onSubscriptionChanged() }
    }

    /// Bu cihazdaki aboneliğin kayıtlı token'ı (push) veya kanonik adresi (e-posta/SMS); sahiplik kanıtı için.
    static func ownershipToken(_ store: HSStorage, subscriptionId: String) -> String? {
        if subscriptionId == store.subscriptionId { return store.registeredToken }
        for channel in ["email", "sms"] {
            if let address = store.contacts(channel).first(where: { $0.value == subscriptionId })?.key { return address }
        }
        return nil
    }

    static func removeContact(channel: String, address: String) async throws {
        guard let store = storage, let api, let subId = store.contacts(channel)[address] else { return }
        do {
            // Kanıt: kanonik adresin özeti; kimlikli kullanıcıda identity_hash de (doğrulama zorunlu app'ler).
            let identityHash = store.externalId != nil ? store.userIdentityHash : nil
            try await api.request("DELETE", "/subscriptions/\(subId)" + HSOwnership.query(registeredToken: address, identityHash: identityHash))
        } catch let error as HSApiError where error.status == 404 {
            // Abonelik zaten silinmiş.
        }
        store.removeContact(channel, address: address)
    }

    /// Login sonrası e-posta/SMS abonelikleri de aynı kullanıcıya bağlanır (anonim kullanıcı birleştirilir).
    @discardableResult
    static func linkContacts(externalId: String, identityHash: String?) async -> [String: Any]? {
        guard let store = storage, let api else { return nil }
        var first: [String: Any]?
        for channel in ["email", "sms"] {
            for (address, subId) in store.contacts(channel) {
                // Kanıt: kanonik adresin özeti (ADR-0016).
                let body = HSOwnership.loginBody(externalId: externalId, identityHash: identityHash, registeredToken: address)
                do {
                    let result = try await api.request("POST", "/subscriptions/\(subId)/login", body: body)
                    if first == nil { first = result }
                } catch {
                    HSLog.log(.warn, "e-posta/SMS aboneliği kullanıcıya bağlanamadı: \(error)")
                    reportError("contact_link_failed", "e-posta/SMS aboneliği kullanıcıya bağlanamadı", error: error)
                }
            }
        }
        return first
    }

    // MARK: - Kuyruk

    static func enqueue(_ op: [String: Any]) {
        queue?.enqueue(op)
        Task { await flushQueue() }
    }

    static func perform(_ op: [String: Any]) async throws {
        guard let store = storage, let api else { return }
        switch op["type"] as? String {
        case "tags", "properties":
            guard let userId = store.userId else { throw HSApiError(status: 0, code: "NO_USER", message: "kullanıcı yok") }
            var body: [String: Any] = op["type"] as? String == "tags" ? ["tags": op["tags"] ?? [:]] : ["properties": op["properties"] ?? [:]]
            if let hash = store.userIdentityHash { body["identity_hash"] = hash }
            let result = try await api.request("PATCH", "/users/\(userId)", body: body)
            store.tags = result["tags"] as? [String: String] ?? store.tags
        case "event", "event_batch":
            guard let subId = store.subscriptionId else { return }
            let ops: [[String: Any]] = op["type"] as? String == "event" ? [op] : (op["events"] as? [[String: Any]] ?? [])
            let events: [[String: Any]] = ops.map { e in
                var event: [String: Any] = ["name": e["name"] ?? "", "properties": e["properties"] ?? [:], "occurred_at": e["occurred_at"] ?? "", "subscription_id": subId]
                if let value = e["value"] { event["value"] = value }
                return event
            }
            try await api.request("POST", "/events", body: ["events": events])
        case "session_start", "session_end":
            guard let subId = store.subscriptionId else { return }
            var body: [String: Any] = ["subscription_id": subId, "sdk_version": sdkVersion]
            // Oturumda uygulama sürümü de güncellenir (docs/plan/06 "Token yaşam döngüsü").
            if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { body["app_version"] = appVersion }
            if let d = op["duration_seconds"] { body["duration_seconds"] = d }
            // Oturum cihaz sürümünü de yazdığı için sahiplik kanıtı eklenir (ADR-0016).
            let identityHash = store.externalId != nil ? store.userIdentityHash : nil
            try await api.request("POST", "/sessions", body: HSOwnership.withProof(body, registeredToken: store.registeredToken, identityHash: identityHash))
        case "alias_add":
            guard let userId = store.userId else { throw HSApiError(status: 0, code: "NO_USER", message: "kullanıcı yok") }
            var body: [String: Any] = ["identity": op["aliases"] ?? [:]]
            if let hash = store.userIdentityHash { body["identity_hash"] = hash }
            try await api.request("PATCH", "/users/\(userId)/identity", body: body)
        case "alias_remove":
            guard let userId = store.userId else { throw HSApiError(status: 0, code: "NO_USER", message: "kullanıcı yok") }
            let label = (op["label"] as? String ?? "").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            var query = ""
            if let hash = store.userIdentityHash?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { query = "?identity_hash=\(hash)" }
            try await api.request("DELETE", "/users/\(userId)/identity/\(label)\(query)")
        case "contact_add":
            try await addContact(channel: op["channel"] as? String ?? "", address: op["address"] as? String ?? "")
        case "contact_remove":
            try await removeContact(channel: op["channel"] as? String ?? "", address: op["address"] as? String ?? "")
        case "in_app_event":
            guard let subId = engagementSubscriptionId(), let messageId = op["message_id"] as? String else { return }
            var body: [String: Any] = ["subscription_id": subId, "type": op["event"] as? String ?? ""]
            if let button = op["button_id"] as? String, !button.isEmpty { body["button_id"] = button }
            let path = messageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageId
            try await api.request("POST", "/in-app/\(path)/events", body: body)
        case "received":
            try await api.request("POST", "/deliveries/\(op["delivery_id"] ?? "")/received", body: [:])
        case "dismissed":
            try await api.request("POST", "/deliveries/\(op["delivery_id"] ?? "")/dismissed", body: [:])
        case "opened":
            var body: [String: Any] = [:]
            if let button = op["button_id"] as? String, !button.isEmpty { body["button_id"] = button }
            try await api.request("POST", "/deliveries/\(op["delivery_id"] ?? "")/opened", body: body)
        default:
            break
        }
    }

    /// NSE'nin uygulama kapalıyken kuyruğa yazdığı `received` kayıtları.
    static func flushPendingReceived() async {
        guard let store = storage else { return }
        let pending = store.pendingReceived
        guard !pending.isEmpty else { return }
        store.pendingReceived = []
        for id in pending { enqueue(["type": "received", "delivery_id": id, "at": Date().timeIntervalSince1970]) }
    }

    // MARK: - Oturum

    static func observeLifecycle() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            sessionStartedAt = Date()
            enqueue(["type": "session_start", "at": Date().timeIntervalSince1970])
            inApp.onSessionStart()
            if let click = pendingClick, !clickListeners.isEmpty { pendingClick = nil; clickListeners.forEach { $0(click) } }
            Task { await flushPendingReceived() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            guard let started = sessionStartedAt else { return }
            sessionStartedAt = nil
            enqueue(["type": "session_end", "duration_seconds": Int(Date().timeIntervalSince(started)), "at": Date().timeIntervalSince1970])
        })
    }

    // MARK: - Teslimat geri bildirimi

    static func reportReceived(_ deliveryId: String) {
        enqueue(["type": "received", "delivery_id": deliveryId, "at": Date().timeIntervalSince1970])
    }

    /// Kullanıcı bildirimi kapattı (`.customDismissAction` kategorili bildirimlerde).
    static func reportDismissed(_ n: HSNotification) {
        guard let id = n.deliveryId else { return }
        enqueue(["type": "dismissed", "delivery_id": id, "at": Date().timeIntervalSince1970])
    }

    static func reportOpened(_ n: HSNotification, actionId: String?) {
        if let id = n.deliveryId {
            enqueue(["type": "opened", "delivery_id": id, "button_id": actionId ?? "", "at": Date().timeIntervalSince1970])
        }
        let event = HSClickEvent(notification: n, actionId: actionId, url: n.url(forAction: actionId))
        if clickListeners.isEmpty { pendingClick = event } else { clickListeners.forEach { $0(event) } }
        if let urlString = event.url, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
    }

    static func notifySubscription() {
        Task {
            let s = await User.pushSubscription.state()
            subscriptionObservers.forEach { $0(s) }
        }
    }

    // MARK: - Public API

    public static func login(_ externalId: String, identityHash: String? = nil) {
        guard let store = storage, let api else { return }
        if identityVerificationRequired && identityHash == nil {
            HSLog.log(.error, "Bu app için identityHash zorunlu"); return
        }
        Task {
            if let subId = store.subscriptionId {
                let body = HSOwnership.loginBody(externalId: externalId, identityHash: identityHash, registeredToken: store.registeredToken)
                do {
                    let result = try await api.request("POST", "/subscriptions/\(subId)/login", body: body)
                    store.userId = result["user_id"] as? String
                    store.externalId = result["external_id"] as? String
                    store.userIdentityHash = identityHash
                    store.tags = result["tags"] as? [String: String] ?? [:]
                } catch {
                    HSLog.log(.error, "login başarısız: \(error)")
                    reportError("login_failed", "login başarısız", error: error)
                }
                await linkContacts(externalId: externalId, identityHash: identityHash)
            } else {
                store.externalId = externalId
                store.pendingIdentityHash = identityHash
                store.userIdentityHash = identityHash
                // Push aboneliği yoksa kullanıcı e-posta/SMS aboneliği üzerinden bağlanır.
                if let result = await linkContacts(externalId: externalId, identityHash: identityHash) {
                    store.userId = result["user_id"] as? String
                    store.tags = result["tags"] as? [String: String] ?? [:]
                }
                if let token = store.deviceToken { await registerIfNeeded(token: token) }
            }
            inApp.reset()
            inApp.onSubscriptionChanged()
            await flushQueue()
        }
    }

    public static func logout() {
        guard let store = storage, let api else { return }
        Task {
            let proof = HSOwnership.withProof([:], registeredToken: store.registeredToken, identityHash: store.externalId != nil ? store.userIdentityHash : nil)
            if let subId = store.subscriptionId, let result = try? await api.request("POST", "/subscriptions/\(subId)/logout", body: proof) {
                store.clearIdentity()
                store.userId = result["user_id"] as? String
            } else {
                store.clearIdentity()
            }
            inApp.reset()
            inApp.onSubscriptionChanged()
        }
    }

    public enum User {
        public static func addTag(_ key: String, _ value: String) { addTags([key: value]) }
        public static func addTags(_ tags: [String: String]) { enqueue(["type": "tags", "tags": tags, "at": Date().timeIntervalSince1970]) }
        public static func removeTag(_ key: String) { removeTags([key]) }
        public static func removeTags(_ keys: [String]) {
            var patch: [String: Any] = [:]
            keys.forEach { patch[$0] = NSNull() }
            enqueue(["type": "tags", "tags": patch, "at": Date().timeIntervalSince1970])
        }
        public static func getTags() -> [String: String] { storage?.tags ?? [:] }

        /// Kullanıcıya alias ekler (ör. `addAlias("crm_id", "42")`); çevrimdışıyken kuyrukta bekler.
        public static func addAlias(_ label: String, _ id: String) { addAliases([label: id]) }

        /// Birden çok alias'ı tek istekte ekler (en fazla 20; etiketler küçük harf/rakam/_; external_id/hs_id hariç).
        public static func addAliases(_ aliases: [String: String]) {
            guard let normalized = HSAliases.normalize(aliases) else {
                HSLog.log(.error, "geçersiz alias: etiketler küçük harf/rakam/_ (en fazla 50), değer 1-255 karakter, en fazla 20 alias")
                return
            }
            enqueue(["type": "alias_add", "aliases": normalized, "at": Date().timeIntervalSince1970])
        }

        public static func removeAlias(_ label: String) {
            guard HSAliases.isValidLabel(label) else { HSLog.log(.error, "geçersiz alias etiketi"); return }
            enqueue(["type": "alias_remove", "label": label, "at": Date().timeIntervalSince1970])
        }
        public static func setLanguage(_ code: String) { enqueue(["type": "properties", "properties": ["language": code], "at": Date().timeIntervalSince1970]) }

        /// E-posta aboneliği ekler (küçük harfe çevrilir); geçersiz adres günlüğe yazılıp yok sayılır. Çevrimdışıyken kuyrukta bekler.
        public static func addEmail(_ email: String) {
            guard let address = HSContacts.normalizeEmail(email) else { HSLog.log(.error, "geçersiz e-posta adresi"); return }
            enqueue(["type": "contact_add", "channel": "email", "address": address, "at": Date().timeIntervalSince1970])
        }

        /// E-posta aboneliğini siler (`DELETE /subscriptions/{id}`).
        public static func removeEmail(_ email: String) {
            guard let address = HSContacts.normalizeEmail(email) else { HSLog.log(.error, "geçersiz e-posta adresi"); return }
            enqueue(["type": "contact_remove", "channel": "email", "address": address, "at": Date().timeIntervalSince1970])
        }

        /// SMS aboneliği ekler; numara E.164'e normalize edilir (`+90 (532) 123-45-67` → `+905321234567`, `00` → `+`).
        public static func addSms(_ phoneNumber: String) {
            guard let address = HSContacts.normalizePhone(phoneNumber) else { HSLog.log(.error, "geçersiz telefon numarası (E.164 bekleniyor)"); return }
            enqueue(["type": "contact_add", "channel": "sms", "address": address, "at": Date().timeIntervalSince1970])
        }

        /// SMS aboneliğini siler.
        public static func removeSms(_ phoneNumber: String) {
            guard let address = HSContacts.normalizePhone(phoneNumber) else { HSLog.log(.error, "geçersiz telefon numarası (E.164 bekleniyor)"); return }
            enqueue(["type": "contact_remove", "channel": "sms", "address": address, "at": Date().timeIntervalSince1970])
        }

        /// Bu cihazda kaydedilmiş e-posta adresleri.
        public static var emails: [String] { (storage?.contacts("email") ?? [:]).keys.sorted() }
        /// Bu cihazda kaydedilmiş SMS numaraları.
        public static var smsNumbers: [String] { (storage?.contacts("sms") ?? [:]).keys.sorted() }

        public static var externalId: String? { storage?.externalId }
        public static var id: String? { storage?.userId }

        public enum pushSubscription {
            public static var id: String? { storage?.subscriptionId }
            public static var token: String? { storage?.deviceToken }
            public static func state() async -> HSPushSubscriptionState {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                return HSPushSubscriptionState(id: id, token: token, optedIn: (storage?.optedIn ?? false) && settings.authorizationStatus == .authorized, permission: settings.authorizationStatus)
            }
            public static func optIn() {
                guard let store = storage else { return }
                store.optedIn = true
                Task {
                    if let subId = store.subscriptionId { _ = try? await api?.request("PATCH", "/subscriptions/\(subId)", body: HSOwnership.withProof(["opted_in": true], registeredToken: store.registeredToken)) }
                    else if let token = store.deviceToken { await registerIfNeeded(token: token) }
                    await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
                    notifySubscription()
                }
            }
            public static func optOut() {
                guard let store = storage else { return }
                store.optedIn = false
                Task {
                    if let subId = store.subscriptionId { _ = try? await api?.request("PATCH", "/subscriptions/\(subId)", body: HSOwnership.withProof(["opted_in": false], registeredToken: store.registeredToken)) }
                    notifySubscription()
                }
            }
            public static func addObserver(_ observer: @escaping (HSPushSubscriptionState) -> Void) { subscriptionObservers.append(observer) }
        }
    }

    public enum Notifications {
        /// Sistem izni ister; kabul edilirse APNs kaydı başlar.
        public static func requestPermission(_ completion: ((Bool) -> Void)? = nil) {
            var optionsSet: UNAuthorizationOptions = [.alert, .badge, .sound]
            if options.provisionalAuthorization { optionsSet.insert(.provisional) }
            UNUserNotificationCenter.current().requestAuthorization(options: optionsSet) { granted, error in
                if let error { HSLog.log(.warn, "izin hatası: \(error.localizedDescription)") }
                if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
                notifySubscription()
                completion?(granted)
            }
        }
        public static func permission() async -> UNAuthorizationStatus {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
        public static func addClickListener(_ listener: @escaping (HSClickEvent) -> Void) {
            clickListeners.append(listener)
            if let click = pendingClick { pendingClick = nil; listener(click) }
        }
        public static func addForegroundLifecycleListener(_ listener: @escaping (HSForegroundEvent) -> Void) { foregroundListeners.append(listener) }

        /// Uygulama rozetini ayarlar ve NSE ile paylaşılan sayacı eşitler (`badge_inc` bu değerin üzerine eklenir).
        public static func setBadgeCount(_ count: Int) {
            badgeStore?.count = count
            Task { @MainActor in
                if #available(iOS 16.0, *) {
                    try? await UNUserNotificationCenter.current().setBadgeCount(count)
                } else {
                    UIApplication.shared.applicationIconBadgeNumber = count
                }
            }
        }

        /// Rozeti sıfırlar (paylaşılan sayaç dahil).
        public static func clearBadge() { setBadgeCount(0) }

        /// Bildirim merkezindeki tüm bildirimleri kaldırır ve rozeti sıfırlar.
        public static func clearAll() {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            clearBadge()
        }

        /// Aynı `thread-id`'ye (sunucuda `thread_id` / `android_group`) sahip tüm bildirimleri bildirim merkezinden kaldırır.
        public static func removeGroupedNotifications(_ threadId: String) {
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { delivered in
                let ids = delivered.filter { $0.request.content.threadIdentifier == threadId }.map { $0.request.identifier }
                if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
            }
        }

        /// Tek bir bildirimi istek kimliğiyle (`UNNotificationRequest.identifier`) bildirim merkezinden kaldırır.
        public static func removeNotification(identifier: String) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    public enum Session {
        public static func sendEvent(_ name: String, properties: [String: Any] = [:], value: Double? = nil) {
            var op: [String: Any] = ["type": "event", "name": name, "properties": properties, "occurred_at": ISO8601DateFormatter().string(from: Date()), "at": Date().timeIntervalSince1970]
            if let value { op["value"] = value }
            enqueue(op)
            inApp.onEvent(name)
        }
    }

    /**
     In-app mesajlar: liste oturum başında ve en fazla 5 dakikada bir yenilenir; tetikler yerelde değerlendirilir
     (`session_start`, `Session.sendEvent` adı, `setScreen`, `addTrigger` koşulları). Aynı anda tek mesaj gösterilir.
     */
    public enum InAppMessages {
        public static func addTrigger(_ key: String, _ value: String) { addTriggers([key: value]) }

        public static func addTriggers(_ triggers: [String: String]) {
            guard triggers.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 64 && $0.value.count <= 200 }) else {
                HSLog.log(.error, "geçersiz trigger: anahtar 1-64, değer en fazla 200 karakter"); return
            }
            inApp.addTriggers(triggers)
        }

        public static func removeTrigger(_ key: String) { removeTriggers([key]) }
        public static func removeTriggers(_ keys: [String]) { inApp.removeTriggers(keys) }
        public static func clearTriggers() { inApp.clearTriggers() }
        /// Geçerli trigger değerleri (ana iş parçacığında güncellenir).
        public static func getTriggers() -> [String: String] { inApp.triggers }

        /// Geçerli ekran adı (`screen` tetikleri); ekrandan çıkarken nil. SwiftUI: `.onAppear { setScreen("cart") }`.
        public static func setScreen(_ name: String?) { inApp.setScreen(name.flatMap { $0.isEmpty ? nil : $0 }) }

        /// true iken yeni mesaj gösterilmez (tetikler kaydedilmeye devam eder).
        public static var paused: Bool {
            get { inApp.paused }
            set { inApp.paused = newValue }
        }

        /// Düğme tıklamaları (`messageId`, `actionId`, `url`); ana iş parçacığında çağrılır.
        public static func addClickListener(_ listener: @escaping (HSInAppClickEvent) -> Void) { inApp.clickListeners.append(listener) }
        /// Yaşam döngüsü dinleyicisi (zayıf referansla tutulur).
        public static func addLifecycleListener(_ listener: HSInAppLifecycleListener) { inApp.lifecycleListeners.append(.init(value: listener)) }
        public static func removeLifecycleListener(_ listener: HSInAppLifecycleListener) { inApp.lifecycleListeners.removeAll { $0.value === listener } }

        /// Özel çizim katmanı (ör. Flutter köprüsü); nil varsayılan UIKit çizimine döner.
        public static func setRenderer(_ renderer: HSInAppRenderer?) { inApp.setRenderer(renderer) }
    }

    /// Bildirim kutusu (`add_to_inbox` mesajları). Login'de `identityHash` verildiyse isteklere eklenir.
    public enum Inbox {
        private struct Ctx { let userId: String; let subscriptionId: String; let identityHash: String? }

        private static func ctx() throws -> (Ctx, HSApi) {
            guard let store = storage, let api else { throw HSError.notInitialized }
            guard let subId = engagementSubscriptionId() else { throw HSError.noSubscription }
            guard let userId = store.userId else { throw HSError.noUser }
            return (Ctx(userId: userId, subscriptionId: subId, identityHash: store.userIdentityHash), api)
        }

        private static func enc(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value }
        private static func base(_ c: Ctx) -> String { "/users/\(enc(c.userId))/inbox" }
        private static func query(_ c: Ctx) -> String {
            "subscription_id=\(enc(c.subscriptionId))" + (c.identityHash.map { "&identity_hash=\(enc($0))" } ?? "")
        }
        private static func body(_ c: Ctx) -> [String: Any] {
            var b: [String: Any] = ["subscription_id": c.subscriptionId]
            if let hash = c.identityHash { b["identity_hash"] = hash }
            return b
        }

        /// Öğeler (yeniden eskiye), okunmamış sayısı ve sonraki sayfa imleci (`limit` 1-200).
        public static func list(limit: Int = 50, cursor: String? = nil) async throws -> HSInboxPage {
            guard (1...200).contains(limit) else { throw HSError.invalidArgument("limit 1-200 olmalı") }
            let (c, api) = try ctx()
            let path = "\(base(c))?\(query(c))&limit=\(limit)" + (cursor.map { "&cursor=\(enc($0))" } ?? "")
            return HSInboxParser.parsePage(try await api.request("GET", path))
        }

        /// Okundu işaretler; güncel öğeyi döndürür.
        @discardableResult
        public static func markRead(_ id: String) async throws -> HSInboxItem {
            let (c, api) = try ctx()
            guard let item = HSInboxParser.parseItem(try await api.request("POST", "\(base(c))/\(enc(id))/read", body: body(c))) else {
                throw HSError.invalidResponse
            }
            return item
        }

        /// Tümünü okundu işaretler; kalan okunmamış sayısını döndürür.
        @discardableResult
        public static func markAllRead() async throws -> Int {
            let (c, api) = try ctx()
            return (try await api.request("POST", "\(base(c))/read-all", body: body(c))["unread_count"] as? NSNumber)?.intValue ?? 0
        }

        /// Öğeyi kutudan kaldırır (arşivler).
        public static func archive(_ id: String) async throws {
            let (c, api) = try ctx()
            try await api.request("DELETE", "\(base(c))/\(enc(id))?\(query(c))")
        }

        /// Okunmamış öğe sayısı.
        public static func unreadCount() async throws -> Int { try await list(limit: 1).unreadCount }
    }

    public enum Debug {
        public static func setLogLevel(_ level: HSLog.Level) { HSLog.level = level }
    }
}

/// UNUserNotificationCenterDelegate: ön plan gösterimi, tıklama → opened + yönlendirme.
final class HSNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard let n = HSNotification(userInfo: notification.request.content.userInfo) else { completionHandler([.banner, .sound, .badge]); return }
        if let id = n.deliveryId { HeroSignal.reportReceived(id) }
        let event = HSForegroundEvent(notification: n) { show in
            completionHandler(show ? [.banner, .sound, .badge, .list] : [])
        }
        HeroSignal.foregroundListeners.forEach { $0(event) }
        if !event.prevented {
            event.complete(true)
        } else {
            // Ertelenmiş karar: süre içinde display() çağrılmazsa gösterilmez.
            DispatchQueue.main.asyncAfter(deadline: .now() + HSForegroundEvent.displayTimeout) { event.complete(false) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let n = HSNotification(userInfo: response.notification.request.content.userInfo) {
            switch response.actionIdentifier {
            case UNNotificationDismissActionIdentifier:
                HeroSignal.reportDismissed(n)
            case UNNotificationDefaultActionIdentifier:
                HeroSignal.reportOpened(n, actionId: nil)
            default:
                HeroSignal.reportOpened(n, actionId: response.actionIdentifier)
            }
        }
        completionHandler()
    }
}
