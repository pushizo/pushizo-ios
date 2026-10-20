import Foundation
// SPM: ayrı modül (uygulamalar `import Pushizo` ile çekirdek tiplere de erişsin diye yeniden dışa aktarılır);
// CocoaPods alt spec'leri tek "Pushizo" modülünde derlenir.
#if canImport(PushizoCore)
@_exported import PushizoCore
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
    /// `Pushizo.initialize` çağrılmadı.
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
    /// API kökü. Varsayılan (global) değerde bırakılırsa SDK app yapılandırmasındaki bölgesel adresi (`api_url`) öğrenip
    /// kullanır; başka bir değer verilirse korunur (yalnızca sunucu 421 `HS_WRONG_CELL` ile başka bölgeyi gösterirse oraya
    /// geçilir). Ayrıntı: docs/sdk/ios.md.
    public var apiUrl: String = HSCellRouting.defaultApiUrl
    /// KVKK/GDPR: onay verilene kadar ağ çağrısı yapılmaz.
    public var requiresPrivacyConsent = false
    /// APNs ortamı ("sandbox"/"development" veya "production"); nil ise DEBUG derlemesi ya da gömülü
    /// provisioning profilindeki `aps-environment` ile tespit edilir (`device.push_environment`).
    public var apnsEnvironment: String?
    /// NSE ile durum paylaşımı için App Group (ör. "group.com.example.app"). Rozet sayacı için verilmezse
    /// Info.plist `PushizoAppGroup`, o da yoksa `group.<bundle id>.pushizo` kullanılır.
    public var appGroup: String?
    /// Provisional (sessiz) izin ile başla.
    public var provisionalAuthorization = false
    /**
     true (varsayılan): SDK `UNUserNotificationCenter.current().delegate` olarak kendi delegesini atar; önceki delege zayıf
     referansla tutulur ve Pushizo dışı bildirimler ona iletilir. false: delegeyi uygulama yönetir ve
     `Pushizo.Notifications.handleWillPresent` / `handleDidReceive` çağrılarını kendi delegesinden yapar.
     */
    public var installsNotificationDelegate = true
    public var logLevel: HSLog.Level = .warn
    public init() {}
}

public enum HSLog {
    public enum Level: Int { case none = 0, error, warn, info, debug }
    public static var level: Level = .warn
    static func log(_ l: Level, _ message: @autoclosure () -> String) {
        guard level.rawValue >= l.rawValue else { return }
        print("[Pushizo] \(message())")
    }
}

/**
 Pushizo iOS SDK (eski sağlayıcı v5 yüzeyiyle uyumlu).

 ```swift
 Pushizo.initialize("app_…", launchOptions: launchOptions) { $0.apiUrl = "https://api.example.com" }
 Pushizo.Notifications.requestPermission { accepted in }
 let token = Pushizo.Notifications.addPermissionObserver { granted in }
 Pushizo.login("user_42")
 Pushizo.User.addTag("plan", "pro")
 Pushizo.User.addEmail("ali@example.com")
 Pushizo.InAppMessages.addTrigger("level", "gold")
 let page = try await Pushizo.Inbox.list(limit: 20)
 ```
 */
public enum Pushizo {
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
    /// `/config` `identity_verification_mode` (ADR-0023 §9); alan yoksa `hmac`.
    static var identityVerificationMode: HSIdentityVerificationMode = .hmac
    static var sessionTracker: HSSessionTracker?
    /// Arka planda oturum penceresi (30 sn) dolunca oturumu kapatan zamanlayıcı; ön plana dönüşte iptal edilir.
    static var sessionExpiryWork: DispatchWorkItem?
    static let clickListeners = HSListenerRegistry<HSClickEvent>()
    static let foregroundListeners = HSListenerRegistry<HSForegroundEvent>()
    static let permissionTracker = HSPermissionTracker()
    static let subscriptionObservers = HSListenerRegistry<HSPushSubscriptionState>()
    private static let authorizationLock = NSLock()
    private static var cachedAuthorizationStatus: UNAuthorizationStatus?
    static var pendingClick: HSClickEvent?
    static let delegate = HSNotificationDelegate()
    static let inApp = HSInAppController()
    static var observers: [NSObjectProtocol] = []

    public static var isInitialized: Bool { storage != nil }

    /// Uygulama başlangıcında (AppDelegate `didFinishLaunching` veya SwiftUI `init`) çağrılır.
    public static func initialize(_ appId: String, launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil, configure: ((inout HSOptions) -> Void)? = nil) {
        precondition(!appId.isEmpty, "Pushizo.initialize: appId gerekli")
        var opts = HSOptions()
        configure?(&opts)
        self.appId = appId
        self.options = opts
        HSLog.level = opts.logLevel
        let store = HSStorage(appId: appId, appGroup: opts.appGroup)
        storage = store
        // Daha önce öğrenilen bölgesel kök aynı başlangıç kökü için kullanılır (ADR-0032 §4).
        let client = HSApi(apiUrl: store.resolvedApiUrl(seed: opts.apiUrl), appId: appId, sdkVersion: sdkVersion)
        // Kimlik JWT'si her istekte depodan okunur (login/updateUserJwt/logout sonrası güncel değer).
        client.identityToken = { [weak store] in store?.identityJwt }
        let seed = opts.apiUrl
        client.onApiUrlChange = { [weak store] url in store?.saveRegionalApi(seed: seed, url: url) }
        api = client
        queue = HSQueue(defaults: store.defaults, appId: appId)
        sessionTracker = HSSessionTracker(defaults: store.defaults, appId: appId)
        // NSE `received` göndermeden önce onay zorunluluğunu paylaşılan depodan okur.
        store.privacyConsentRequired = opts.requiresPrivacyConsent
        // Config gelene kadar son bilinen app geneli in-app aralığı uygulanır.
        inApp.globalMinIntervalSeconds = store.inAppMinIntervalSeconds
        badgeStore = HSBadgeStore(appGroup: HSAppGroup.resolve(opts.appGroup))
        errorReporter = HSErrorReporter(platform: "ios", sdkVersion: sdkVersion)
        if opts.installsNotificationDelegate { installNotificationDelegate() }
        // Düğmesiz bildirimlerin kapatılma (dismissed) geri bildirimi için; mevcut kategoriler korunur.
        Task { await HSCategories.register(HSCategories.category(identifier: HSCategories.defaultIdentifier, actions: [])) }
        observeLifecycle()
        // İzin gözlemcileri için temel değer (yalnızca sonraki değişiklikler bildirilir).
        checkPermissionChange()
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

    /**
     Gizlilik onayı. Verilince kuyrukta bekleyen işlemler, NSE'nin bekleyen `received` kayıtları ve onay beklerken yerelde
     yapılan login/logout/opt-in değişiklikleri gönderilir.
     Geri çekilince (`false`): ağ çağrıları hemen durur (işlenmekte olan kuyruk bir sonraki işlemde durur); gönderilmemiş
     işlemler ve bekleyen `received` kayıtları silinir, cihazdaki kullanıcı kimliği temizlenir. Push aboneliği kimliği,
     token ve opt-in tercihi cihazda kalır, sunucudaki abonelik silinmez. Sonraki çağrılar yeniden onay verilene kadar kuyrukta bekler.
     */
    public static func setConsentGiven(_ given: Bool) {
        guard let store = storage else { return }
        store.consentGiven = given
        if given {
            start()
        } else {
            queue?.clear()
            _ = store.takePendingReceived()
            store.clearIdentity()
            Chat.onLogout()
            // Onay yeniden verildiğinde konum paylaşımı kendiliğinden sürmez (yeniden `Location.setShared(true)` gerekir).
            store.locationShared = false
            store.locationLastSentAt = nil
        }
    }

    /// Ağ çağrısı yapılabilir mi (`requiresPrivacyConsent` açıkken onay verilmiş olmalı).
    static var networkAllowed: Bool {
        guard let store = storage else { return false }
        return HSConsent.allowsNetwork(required: options.requiresPrivacyConsent, given: store.consentGiven)
    }

    /// SDK delegesini atar; önceki delege (uygulamanınki) Pushizo dışı bildirimler için zayıf referansla saklanır.
    static func installNotificationDelegate() {
        let center = UNUserNotificationCenter.current()
        guard center.delegate !== delegate else { return }
        delegate.previous = center.delegate
        center.delegate = delegate
    }

    static func start() {
        Task {
            do {
                if let config = try await api?.request("GET", "/config") { await applyConfig(config) }
            } catch {
                HSLog.log(.warn, "config alınamadı: \(error)")
                reportError("config_failed", "app yapılandırması alınamadı", error: error)
            }
            // Onay beklerken yerelde yapılan login/logout sunucuya iletilir.
            await resumePendingIdentityOperation()
            // Daha önce alınmış token varsa kaydı eşitle; izin verildiyse APNs kaydı yenilenir.
            if let token = storage?.deviceToken { await registerIfNeeded(token: token) }
            await syncPendingOptedIn()
            // İzin uygulama kapalıyken Ayarlar'dan değişmiş olabilir: `push_capable` sunucuyla eşitlenir.
            await syncPushCapableIfNeeded()
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
            await flushPendingReceived()
            await flushQueue()
            // Oturum başında konum (yalnızca paylaşım açık, izin verilmiş ve uygulama ön plandaysa).
            Location.refresh()
        }
    }

    /// `/config` yanıtı: kimlik doğrulama zorunluluğu ve app geneli in-app aralığı (kalıcı; ADR-0019 §7).
    static func applyConfig(_ config: [String: Any]) async {
        adoptRegionalApiUrl(config["api_url"])
        identityVerificationRequired = config["identity_verification_required"] as? Bool ?? false
        identityVerificationMode = HSIdentityVerificationMode(config: config["identity_verification_mode"])
        let interval = max(((config["in_app"] as? [String: Any])?["min_interval_seconds"] as? NSNumber)?.intValue ?? 0, 0)
        storage?.inAppMinIntervalSeconds = interval
        await MainActor.run { inApp.globalMinIntervalSeconds = interval }
    }

    /// Config `api_url`: `HSOptions.apiUrl` varsayılan (global) kökteyse app'in bölgesel API kökü benimsenir ve saklanır.
    /// Geliştiricinin verdiği özel kök (kendi alan adı/vekil sunucu) korunur.
    static func adoptRegionalApiUrl(_ candidate: Any?) {
        guard let api, HSCellRouting.trimSlash(options.apiUrl) == HSCellRouting.defaultApiUrl,
              let next = HSCellRouting.acceptApiUrl(candidate, current: api.apiUrl), next != api.apiUrl
        else { return }
        HSLog.log(.info, "bölgesel API kökü kullanılıyor: \(next)")
        api.updateApiUrl(next)
        storage?.saveRegionalApi(seed: options.apiUrl, url: next)
    }

    /// Kuyruğu işler; kalıcı olarak reddedilen işlemler hata raporuna eklenir. Onay bekleniyorsa işlemler kuyrukta kalır.
    static func flushQueue() async {
        guard networkAllowed else { return }
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
            let device = await deviceInfo()
            let result = try await sync.sync(subscriptionId: store.subscriptionId, registeredToken: store.registeredToken, token: token, device: device, user: user)
            switch result {
            case .unchanged:
                return
            case .updated:
                store.registeredToken = token
                store.syncedPushCapable = device["push_capable"] as? Bool
            case let .created(subscriptionId, userId, externalId):
                store.syncedPushCapable = device["push_capable"] as? Bool
                store.subscriptionId = subscriptionId
                store.userId = userId
                store.externalId = externalId
                store.registeredToken = token
                store.pendingIdentityHash = nil
                if !store.optedIn {
                    _ = try? await api.request("PATCH", "/subscriptions/\(subscriptionId)", body: HSOwnership.withProof(["opted_in": false], registeredToken: token))
                }
                store.optedInSyncPending = false
                inApp.onSubscriptionChanged()
            }
            notifySubscription()
            await flushQueue()
            // Push aboneliği/token değişti: sohbet ziyaretçisinin abonelik bağı (çevrimdışı mesaj bildirimi) yenilenir.
            Chat.onIdentityChanged()
        } catch {
            HSLog.log(.warn, "abonelik kaydı başarısız: \(error)")
            reportError("registration_failed", "push aboneliği kaydedilemedi", error: error)
        }
    }

    static func deviceInfo() async -> [String: Any] {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        cacheAuthorizationStatus(settings.authorizationStatus)
        #if targetEnvironment(macCatalyst)
        // Mac Catalyst: UIDevice "iPad" ve iOS eşdeğeri sürüm döndürür; gerçek macOS sürümü ProcessInfo'dan okunur.
        let model = "Mac"
        let macVersion = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(macVersion.majorVersion).\(macVersion.minorVersion).\(macVersion.patchVersion)"
        let osName = "macOS"
        #else
        let device = await UIDevice.current
        let model = await device.model
        let systemVersion = await device.systemVersion
        let osName = "iOS"
        #endif
        // `push_capable` bildirim iznini yansıtır; false ise sunucu push aboneliğini `pending` tutar.
        return HSDeviceInfo.make(
            model: model,
            os: osName,
            osVersion: systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            sdkVersion: sdkVersion,
            locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            timezone: TimeZone.current.identifier,
            pushCapable: HSPermissionTracker.isGranted(settings.authorizationStatus),
            pushEnvironment: pushEnvironment()
        )
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

    /**
     Gömülü provisioning profilindeki APNs ortamı (App Store derlemelerinde dosya yoktur → nil). iOS: `embedded.mobileprovision`
     ve `aps-environment`; Mac Catalyst: `Contents/embedded.provisionprofile` ve `com.apple.developer.aps-environment`.
     */
    static let provisioningApsEnvironment: String? = {
        #if targetEnvironment(macCatalyst)
        let url: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        let entitlementKey = "com.apple.developer.aps-environment"
        #else
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        let entitlementKey = "aps-environment"
        #endif
        guard let url,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }
        let plistData = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements[entitlementKey] as? String
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

    /// İşlemi kalıcı kuyruğa yazar; onay bekleniyorsa ağ çağrısı yapılmaz, `setConsentGiven(true)` sonrası gönderilir.
    static func enqueue(_ op: [String: Any]) {
        queue?.enqueue(op)
        guard networkAllowed else { return }
        Task { await flushQueue() }
    }

    static func perform(_ op: [String: Any]) async throws {
        guard let store = storage, let api else { return }
        // Onay işleme sırasında geri çekildiyse kuyruk durur (yeniden denenebilir hata işlemi kuyrukta bırakır).
        guard networkAllowed else { throw HSApiError(status: 0, code: "CONSENT_REQUIRED", message: "gizlilik onayı bekleniyor") }
        switch op["type"] as? String {
        case "tags", "properties":
            // Kullanıcı kimliği abonelik kaydıyla gelir; o zamana kadar işlem yerinde bekler, sonrakiler engellenmez.
            guard let userId = store.userId else { throw HSQueueDeferred("kullanıcı yok") }
            var body: [String: Any] = op["type"] as? String == "tags" ? ["tags": HSQueue.tagsBody(op)] : ["properties": op["properties"] ?? [:]]
            if let hash = store.userIdentityHash { body["identity_hash"] = hash }
            let result = try await api.request("PATCH", "/users/\(userId)", body: body)
            store.tags = result["tags"] as? [String: String] ?? store.tags
        case "event", "event_batch":
            // Abonelik (push, yoksa e-posta/SMS) oluşana kadar olaylar kuyrukta bekler.
            guard let subId = engagementSubscriptionId() else { throw HSQueueDeferred("abonelik yok") }
            let ops: [[String: Any]] = op["type"] as? String == "event" ? [op] : (op["events"] as? [[String: Any]] ?? [])
            // Sahiplik kanıtı (ADR-0016 Karar 8): kayıtlı token'ın/kanonik adresin özeti; kimlikli kullanıcıda identity_hash.
            let events = HSOwnership.eventItems(
                ops,
                subscriptionId: subId,
                registeredToken: ownershipToken(store, subscriptionId: subId),
                identityHash: store.externalId != nil ? store.userIdentityHash : nil
            )
            try await api.request("POST", "/events", body: ["events": events])
        case "session_start", "session_end":
            // Push aboneliği oluşana kadar oturum kayıtları kuyrukta bekler.
            guard let subId = store.subscriptionId else { throw HSQueueDeferred("push aboneliği yok") }
            var body: [String: Any] = ["subscription_id": subId, "sdk_version": sdkVersion]
            // Oturumda uygulama sürümü de güncellenir (docs/plan/06 "Token yaşam döngüsü").
            if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { body["app_version"] = appVersion }
            if let d = op["duration_seconds"] { body["duration_seconds"] = d }
            // Oturum cihaz sürümünü de yazdığı için sahiplik kanıtı eklenir (ADR-0016).
            let identityHash = store.externalId != nil ? store.userIdentityHash : nil
            try await api.request("POST", "/sessions", body: HSOwnership.withProof(body, registeredToken: store.registeredToken, identityHash: identityHash))
        case "alias_add":
            guard let userId = store.userId else { throw HSQueueDeferred("kullanıcı yok") }
            var body: [String: Any] = ["identity": op["aliases"] ?? [:]]
            if let hash = store.userIdentityHash { body["identity_hash"] = hash }
            try await api.request("PATCH", "/users/\(userId)/identity", body: body)
        case "alias_remove":
            guard let userId = store.userId else { throw HSQueueDeferred("kullanıcı yok") }
            let label = (op["label"] as? String ?? "").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            var query = ""
            if let hash = store.userIdentityHash?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { query = "?identity_hash=\(hash)" }
            try await api.request("DELETE", "/users/\(userId)/identity/\(label)\(query)")
        case HSAdsRules.operationType:
            // Son reklam kimliği işlemi kazanır; kayıtlı push aboneliği yoksa silinecek kimlik de yoktur.
            if HSAdsRules.isSuperseded(op, queue: queue?.items ?? []) { return }
            guard let subId = store.subscriptionId else {
                if op["clear"] as? Bool == true { return }
                throw HSQueueDeferred("push aboneliği yok")
            }
            try await api.request("PATCH", "/subscriptions/\(subId)", body: HSAdsRules.body(for: op, registeredToken: store.registeredToken))
        case HSLocationRules.operationType:
            // Daha yeni bir konum işlemi kuyruktaysa bu atlanır (son durum kazanır).
            if HSLocationRules.isSuperseded(op, queue: queue?.items ?? []) { return }
            guard let subId = store.subscriptionId else {
                // Kayıtlı push aboneliği yoksa sunucuda silinecek konum da yoktur; konum ise abonelik oluşana kadar bekler.
                if HSLocationRules.isClear(op) { return }
                throw HSQueueDeferred("push aboneliği yok")
            }
            guard let body = HSLocationRules.body(for: op, registeredToken: store.registeredToken) else { return }
            try await api.request("PATCH", "/subscriptions/\(subId)", body: body)
        case "contact_add":
            try await addContact(channel: op["channel"] as? String ?? "", address: op["address"] as? String ?? "")
        case "contact_remove":
            try await removeContact(channel: op["channel"] as? String ?? "", address: op["address"] as? String ?? "")
        case "in_app_event":
            guard let subId = engagementSubscriptionId(), let messageId = op["message_id"] as? String else { return }
            // Kanıt gönderim anındaki abonelikten çözülür (kayıtlı token veya kanonik adres özeti; ADR-0016).
            var body = HSOwnership.subscriptionBody(
                ["type": op["event"] as? String ?? ""],
                subscriptionId: subId,
                registeredToken: ownershipToken(store, subscriptionId: subId)
            )
            if let button = op["button_id"] as? String, !button.isEmpty { body["button_id"] = button }
            if let variant = op["variant_id"] as? String, !variant.isEmpty { body["variant_id"] = variant }
            let path = messageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageId
            try await api.request("POST", "/in-app/\(path)/events", body: body)
        case HSLiveActivities.tokenOperationType, HSLiveActivities.deleteOperationType:
            // Live Activity belirteçleri push aboneliğine bağlanır; abonelik oluşana kadar kuyrukta bekler (ADR-0024 §4).
            guard let subId = store.subscriptionId else { throw HSQueueDeferred("push aboneliği yok") }
            guard let request = HSLiveActivities.request(
                for: op,
                subscriptionId: subId,
                registeredToken: store.registeredToken,
                identityHash: store.externalId != nil ? store.userIdentityHash : nil
            ) else { return }
            try await api.request("POST", request.path, body: request.body)
        case "received":
            try await api.request("POST", "/deliveries/\(op["delivery_id"] ?? "")/received", body: [:])
        case "dismissed":
            try await api.request("POST", "/deliveries/\(op["delivery_id"] ?? "")/dismissed", body: [:])
        case "opened":
            var body: [String: Any] = [:]
            if let button = op["button_id"] as? String, !button.isEmpty { body["button_id"] = button }
            try await api.request("POST", "/deliveries/\(op["delivery_id"] ?? "")/opened", body: body)
        case Chat.sendOperation, Chat.offlineOperation:
            // Canlı sohbet: çevrimdışıyken kuyruğa alınan mesaj aynı `client_message_id` ile gönderilir.
            try await Chat.performQueued(op)
        default:
            break
        }
    }

    /// NSE'nin uygulama kapalıyken kuyruğa yazdığı `received` kayıtları.
    static func flushPendingReceived() async {
        guard let store = storage else { return }
        for id in store.takePendingReceived() { enqueue(["type": "received", "delivery_id": id, "at": Date().timeIntervalSince1970]) }
    }

    // MARK: - Oturum

    static func observeLifecycle() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            sessionExpiryWork?.cancel()
            sessionExpiryWork = nil
            // 30 sn'den kısa arka plan aynı oturumu sürdürür; daha uzunsa önceki oturum kapanır ve yenisi başlar.
            for transition in sessionTracker?.enterForeground(at: Date()) ?? [] { enqueueSession(transition) }
            inApp.onSessionStart()
            if let click = pendingClick, !clickListeners.isEmpty { pendingClick = nil; clickListeners.notify(click) }
            Task { await flushPendingReceived() }
            // Arka planda gelen sohbet bildirimleri: okunmamış sayısı yenilenir.
            Chat.onForeground()
            // Kullanıcı izni Ayarlar'dan değiştirmiş olabilir.
            checkPermissionChange()
            // Ön plana dönüş: paylaşım açıksa konum en sık 5 dakikada bir yenilenir.
            Location.refresh()
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            inApp.onSessionEnd()
            // Arka plan anı kalıcıdır: süreç sonlansa da pencere bir sonraki açılışta değerlendirilir.
            sessionTracker?.enterBackground(at: Date())
            // Uygulama arka planda çalışmayı sürdürürse pencere dolunca oturum kapatılır (askıdaysa açılışta kapanır).
            let work = DispatchWorkItem {
                if let transition = sessionTracker?.expire(at: Date()) { enqueueSession(transition) }
            }
            sessionExpiryWork?.cancel()
            sessionExpiryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + HSSessionTracker.backgroundTimeout, execute: work)
        })
    }

    /// Oturum geçişini kuyruğa yazar; süre (`usage_seconds`, ADR-0019 §8) `POST /sessions { duration_seconds }` ile gider.
    static func enqueueSession(_ transition: HSSessionTracker.Transition) {
        switch transition {
        case .start:
            enqueue(["type": "session_start", "at": Date().timeIntervalSince1970])
        case let .end(durationSeconds):
            enqueue(["type": "session_end", "duration_seconds": durationSeconds, "at": Date().timeIntervalSince1970])
        }
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
        if clickListeners.isEmpty { pendingClick = event } else { clickListeners.notify(event) }
        if let urlString = event.url, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
    }

    static func notifySubscription() {
        Task {
            let s = await User.pushSubscription.state()
            subscriptionObservers.notify(s)
        }
    }

    /**
     Etkin izni yeniden ölçer; değiştiyse izin gözlemcileri ana iş parçacığında çağrılır, izin verildiyse APNs kaydı
     yenilenir, kayıtlı aboneliğin cihaz bilgisi (`push_capable`) güncellenir ve abonelik gözlemcileri bilgilendirilir.
     İlk çağrı yalnızca temel değeri kaydeder.
     */
    static func checkPermissionChange() {
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            cacheAuthorizationStatus(status)
            let granted = HSPermissionTracker.isGranted(status)
            let changed = await MainActor.run { permissionTracker.update(granted) }
            guard changed else {
                // İlk ölçüm: izin uygulama kapalıyken değişmiş olabilir; sunucudaki `push_capable` farklıysa eşitlenir.
                await syncPushCapableIfNeeded()
                return
            }
            if granted { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
            await syncPermissionState()
            notifySubscription()
        }
    }

    /// Sunucuya en son yazılan `push_capable` güncel izinden farklıysa aboneliği PATCH eder.
    static func syncPushCapableIfNeeded() async {
        guard let store = storage, store.subscriptionId != nil else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        cacheAuthorizationStatus(status)
        if store.syncedPushCapable != HSPermissionTracker.isGranted(status) { await syncPermissionState() }
    }

    /// İzin değişikliğini kayıtlı aboneliğe yansıtır (gizlilik onayı bekleniyorsa ağ çağrısı yapılmaz).
    static func syncPermissionState() async {
        guard let store = storage, let api, let subId = store.subscriptionId else { return }
        guard networkAllowed else { return }
        do {
            let device = await deviceInfo()
            _ = try await api.request("PATCH", "/subscriptions/\(subId)", body: HSOwnership.withProof(["device": device], registeredToken: store.registeredToken))
            store.syncedPushCapable = device["push_capable"] as? Bool
        } catch {
            HSLog.log(.warn, "izin sonrası abonelik güncellenemedi: \(error)")
            reportError("subscription_update_failed", "izin sonrası abonelik güncellenemedi", error: error)
        }
    }

    /// Onay beklerken yapılan `optIn`/`optOut` değişikliğini sunucuya iletir.
    static func syncPendingOptedIn() async {
        guard let store = storage, let api, store.optedInSyncPending, let subId = store.subscriptionId else { return }
        guard networkAllowed else { return }
        do {
            _ = try await api.request("PATCH", "/subscriptions/\(subId)", body: HSOwnership.withProof(["opted_in": store.optedIn], registeredToken: store.registeredToken))
            store.optedInSyncPending = false
        } catch {
            HSLog.log(.warn, "opt-in durumu güncellenemedi: \(error)")
            reportError("subscription_update_failed", "opt-in durumu güncellenemedi", error: error)
        }
    }

    /// Son okunan bildirim izni (`pushSubscription.optedIn` için önbellek).
    static func cacheAuthorizationStatus(_ status: UNAuthorizationStatus) {
        authorizationLock.lock()
        cachedAuthorizationStatus = status
        authorizationLock.unlock()
    }

    static var lastAuthorizationStatus: UNAuthorizationStatus? {
        authorizationLock.lock()
        defer { authorizationLock.unlock() }
        return cachedAuthorizationStatus
    }

    // MARK: - Public API

    /**
     Kullanıcıyı kimliklendirir. Kimlik kanıtı app ayarına göre HMAC `identityHash` ve/veya sunucunuzda imzalanmış
     ES256 `jwt`'dir (ADR-0023 §9; `sub` = externalId, `aud` = appId). JWT tüm SDK isteklerinde `Authorization: Bearer`
     başlığıyla gider; süresi dolunca `updateUserJwt(_:)` ile yenilenir.
     */
    public static func login(_ externalId: String, identityHash: String? = nil, jwt: String? = nil) {
        guard let store = storage, api != nil else { return }
        if let message = loginProofError(identityHash: identityHash, jwt: jwt) {
            HSLog.log(.error, message); return
        }
        // JWT bu girişin isteğinde de başlıkta gitmelidir: istekten önce saklanır.
        store.identityJwt = (jwt ?? "").isEmpty ? nil : jwt
        guard networkAllowed else {
            // Onay bekleniyor: kimlik yerelde tutulur, onay verilince `start()` sunucuya bağlar.
            store.externalId = externalId
            store.pendingIdentityHash = identityHash
            store.userIdentityHash = identityHash
            store.pendingIdentityOperation = "login"
            inApp.reset()
            return
        }
        Task { await performLogin(externalId: externalId, identityHash: identityHash) }
    }

    static func performLogin(externalId: String, identityHash: String?) async {
        guard let store = storage, let api else { return }
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
        // Canlı sohbet ziyaretçisi giriş yapan kullanıcıya bağlanır (sohbet kullanılıyorsa).
        Chat.onIdentityChanged()
    }

    public static func logout() {
        guard let store = storage, api != nil else { return }
        // Sohbet ziyaretçisi sıfırlanır: cihazı kullanan sonraki kişi önceki sohbeti görmez.
        Chat.onLogout()
        guard networkAllowed else {
            // Onay bekleniyor: kimlik yerelde silinir; kayıtlı abonelik varsa onay verilince sunucuda da çıkış yapılır.
            let hadSubscription = store.subscriptionId != nil
            store.clearIdentity()
            store.pendingIdentityOperation = hadSubscription ? "logout" : nil
            inApp.reset()
            return
        }
        Task { await performLogout() }
    }

    /// Verilen kanıt app'in kimlik doğrulama kipine (`/config`) uymuyorsa hata mesajı; uyuyorsa nil. `login` bu durumda
    /// isteği göndermez; çapraz platform köprüleri çağrıyı reddetmek için kullanır.
    public static func loginProofError(identityHash: String?, jwt: String?) -> String? {
        HSIdentityVerification.loginError(required: identityVerificationRequired, mode: identityVerificationMode, identityHash: identityHash, jwt: jwt)
    }

    /**
     Süresi dolan veya yenilenen kimlik JWT'sini günceller. Sonraki SDK istekleri yeni belirteci taşır; kuyrukta bekleyen
     işlemler yeniden denenir. Giriş yapılmamışsa `HSError.noUser`, belirteç boşsa `HSError.invalidArgument`.
     */
    public static func updateUserJwt(_ jwt: String) throws {
        guard let store = storage, api != nil else { throw HSError.notInitialized }
        guard !jwt.isEmpty else { throw HSError.invalidArgument("jwt gerekli") }
        guard store.externalId != nil else { throw HSError.noUser }
        store.identityJwt = jwt
        Task { await flushQueue() }
    }

    static func performLogout() async {
        guard let store = storage, let api else { return }
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

    /// Onay beklerken yerelde yapılan login/logout'u sunucuya iletir (`start()` içinden).
    static func resumePendingIdentityOperation() async {
        guard let store = storage, let operation = store.pendingIdentityOperation else { return }
        store.pendingIdentityOperation = nil
        switch operation {
        case "login":
            guard let externalId = store.externalId else { return }
            await performLogin(externalId: externalId, identityHash: store.userIdentityHash)
        case "logout":
            await performLogout()
        default:
            break
        }
    }

    public enum User {
        public static func addTag(_ key: String, _ value: String) { addTags([key: value]) }
        public static func addTags(_ tags: [String: String]) { enqueue(["type": "tags", "tags": tags, "at": Date().timeIntervalSince1970]) }
        public static func removeTag(_ key: String) { removeTags([key]) }
        public static func removeTags(_ keys: [String]) {
            guard !keys.isEmpty else { return }
            // `NSNull` UserDefaults'a yazılamaz; silmeler ayrı listede taşınır (bkz. HSQueue.tagsBody).
            enqueue(["type": "tags", "tags": [String: Any](), "remove": Array(Set(keys)).sorted(), "at": Date().timeIntervalSince1970])
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

        // MARK: Tercihler (ADR-0019 §4): abonelik sahiplik kanıtıyla `GET/PUT /preferences`

        /// Kanıt: etkileşim aboneliği + kayıtlı token'ın (veya kanonik adresin) özeti; kimlikli kullanıcıda identity_hash.
        private static func preferenceProof() throws -> (api: HSApi, subscriptionId: String, tokenHash: String?, identityHash: String?) {
            guard let store = storage, let api else { throw HSError.notInitialized }
            guard let subId = engagementSubscriptionId() else { throw HSError.noSubscription }
            let identityHash = store.externalId != nil ? store.userIdentityHash : nil
            return (api, subId, ownershipToken(store, subscriptionId: subId).map(HSOwnership.tokenHash), identityHash)
        }

        /// Kullanıcının kategori/kanal tercihleri ve app kategorileri. Abonelik yoksa `HSError.noSubscription`.
        public static func getPreferences() async throws -> HSPreferencesResult {
            let (api, subId, tokenHash, identityHash) = try preferenceProof()
            let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0 }
            var query = ["subscription_id=\(enc(subId))"]
            if let tokenHash { query.append("token_hash=\(tokenHash)") }
            if let identityHash { query.append("identity_hash=\(enc(identityHash))") }
            return HSPreferencesParser.parseResult(try await api.request("GET", "/preferences?" + query.joined(separator: "&")))
        }

        /// Tercihleri yazar (1-100 kayıt; `channel` nil = tüm kanallar); güncel listeyi döndürür.
        @discardableResult
        public static func setPreferences(_ preferences: [HSPreferenceInput]) async throws -> HSPreferencesResult {
            guard HSPreferencesParser.isValid(preferences) else {
                throw HSError.invalidArgument("1-100 tercih; kategori 1-64 karakter; kanal ios_push|android_push|web_push|email|sms")
            }
            let (api, subId, tokenHash, identityHash) = try preferenceProof()
            var body: [String: Any] = ["subscription_id": subId, "preferences": preferences.map(\.json)]
            if let tokenHash { body["token_hash"] = tokenHash }
            if let identityHash { body["identity_hash"] = identityHash }
            return HSPreferencesParser.parseResult(try await api.request("PUT", "/preferences", body: body))
        }

        /// Geri çağrı sürümleri (ObjC/köprüler); sonuç ana iş parçacığında döner.
        public static func getPreferences(_ completion: @escaping (Result<HSPreferencesResult, Error>) -> Void) {
            Task {
                let result: Result<HSPreferencesResult, Error>
                do { result = .success(try await getPreferences()) } catch { result = .failure(error) }
                await MainActor.run { completion(result) }
            }
        }

        public static func setPreferences(_ preferences: [HSPreferenceInput], _ completion: ((Result<HSPreferencesResult, Error>) -> Void)? = nil) {
            Task {
                let result: Result<HSPreferencesResult, Error>
                do { result = .success(try await setPreferences(preferences)) } catch {
                    HSLog.log(.warn, "tercihler kaydedilemedi: \(error)")
                    result = .failure(error)
                }
                await MainActor.run { completion?(result) }
            }
        }

        // MARK: Reklam kişiselleştirme rızası (ADR-0037): tercih ucunda ayrılmış anahtar `ads_personalization`

        /**
         Kullanıcı e-posta/telefon özetinin reklam platformu kitlelerine gönderilmesine izin verdi mi. `false` rızayı geri
         alır; kullanıcı bir sonraki kitle senkronunda platformdan çıkarılır.
         */
        @discardableResult
        public static func setAdsPersonalizationConsent(_ granted: Bool) async throws -> HSPreferencesResult {
            try await setPreferences([HSPreferenceInput(category: HSConsentPurpose.adsPersonalization, optedIn: granted)])
        }

        /// Geri çağrı sürümü (ObjC/köprüler); sonuç istenmiyorsa `completion` nil.
        public static func setAdsPersonalizationConsent(_ granted: Bool, _ completion: ((Result<HSPreferencesResult, Error>) -> Void)? = nil) {
            setPreferences([HSPreferenceInput(category: HSConsentPurpose.adsPersonalization, optedIn: granted)], completion)
        }

        /// Rıza kayıtları (`ads_personalization` …). Abonelik yoksa `HSError.noSubscription`.
        public static func getConsents() async throws -> [HSUserConsent] {
            try await getPreferences().consents
        }

        public enum pushSubscription {
            public static var id: String? { storage?.subscriptionId }
            public static var token: String? { storage?.deviceToken }
            public static func state() async -> HSPushSubscriptionState {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                cacheAuthorizationStatus(settings.authorizationStatus)
                return HSPushSubscriptionState(id: id, token: token, optedIn: isOptedIn(settings.authorizationStatus), permission: settings.authorizationStatus)
            }

            /**
             Önbellekten eşzamanlı opt-in durumu: kullanıcı tercihi (`optIn`/`optOut`) ve son okunan bildirim izni.
             İzin henüz okunmadıysa (başlatmanın hemen ardından) false döner; kesin değer için `await state()`.
             */
            public static var optedIn: Bool { lastAuthorizationStatus.map(isOptedIn) ?? false }

            /// `state()` ile aynı kural: tercih açık ve bildirim izni tam (`authorized`).
            static func isOptedIn(_ status: UNAuthorizationStatus) -> Bool {
                (storage?.optedIn ?? false) && status == .authorized
            }

            public static func optIn() {
                guard let store = storage else { return }
                store.optedIn = true
                guard networkAllowed else {
                    // Onay bekleniyor: tercih yerelde tutulur, onay verilince sunucuya iletilir.
                    store.optedInSyncPending = true
                    notifySubscription()
                    return
                }
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
                guard networkAllowed else {
                    store.optedInSyncPending = true
                    notifySubscription()
                    return
                }
                Task {
                    if let subId = store.subscriptionId { _ = try? await api?.request("PATCH", "/subscriptions/\(subId)", body: HSOwnership.withProof(["opted_in": false], registeredToken: store.registeredToken)) }
                    notifySubscription()
                }
            }

            /// Abonelik durumu gözlemcisi; kaldırmak için dönen belirteç `removeObserver` ile verilir.
            @discardableResult
            public static func addObserver(_ observer: @escaping (HSPushSubscriptionState) -> Void) -> HSListenerToken {
                subscriptionObservers.add(observer)
            }

            public static func removeObserver(_ token: HSListenerToken) { _ = subscriptionObservers.remove(token) }
        }
    }

    public enum Notifications {
        /// Sistem izni ister; kabul edilirse APNs kaydı başlar. Durum değiştiyse izin gözlemcileri de çağrılır.
        public static func requestPermission(_ completion: ((Bool) -> Void)? = nil) {
            var optionsSet: UNAuthorizationOptions = [.alert, .badge, .sound]
            if options.provisionalAuthorization { optionsSet.insert(.provisional) }
            UNUserNotificationCenter.current().requestAuthorization(options: optionsSet) { granted, error in
                if let error { HSLog.log(.warn, "izin hatası: \(error.localizedDescription)") }
                if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
                notifySubscription()
                checkPermissionChange()
                completion?(granted)
            }
        }
        public static func permission() async -> UNAuthorizationStatus {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }

        /// Bildirim gösterilebilir mi (tam veya geçici izin); son bilinen değer, henüz ölçülmediyse sistemden okunur.
        public static func isPermissionGranted() async -> Bool {
            if let known = permissionTracker.lastKnown { return known }
            return HSPermissionTracker.isGranted(await permission())
        }

        /**
         İzin gözlemcisi (eski sağlayıcı `addPermissionObserver` eşdeğeri): etkin izin (tam/geçici) değiştiğinde ana iş
         parçacığında `granted` ile çağrılır — `requestPermission` sonrası ve uygulama yeniden etkinleştiğinde
         (`didBecomeActiveNotification`; izin Ayarlar'dan değişmiş olabilir). İlk durum bildirilmez.
         */
        @discardableResult
        public static func addPermissionObserver(_ observer: @escaping (Bool) -> Void) -> HSListenerToken {
            permissionTracker.observers.add(observer)
        }
        public static func removePermissionObserver(_ token: HSListenerToken) { _ = permissionTracker.observers.remove(token) }

        @discardableResult
        public static func addClickListener(_ listener: @escaping (HSClickEvent) -> Void) -> HSListenerToken {
            let token = clickListeners.add(listener)
            if let click = pendingClick { pendingClick = nil; listener(click) }
            return token
        }
        public static func removeClickListener(_ token: HSListenerToken) { _ = clickListeners.remove(token) }

        @discardableResult
        public static func addForegroundLifecycleListener(_ listener: @escaping (HSForegroundEvent) -> Void) -> HSListenerToken {
            foregroundListeners.add(listener)
        }
        public static func removeForegroundLifecycleListener(_ token: HSListenerToken) { _ = foregroundListeners.remove(token) }

        /**
         Delegeyi kendisi yöneten uygulamalar (`HSOptions.installsNotificationDelegate = false`) için: kendi
         `userNotificationCenter(_:willPresent:withCompletionHandler:)` içinden çağırın. Pushizo bildirimiyse işlenir,
         `completion` Pushizo tarafından tam bir kez çağrılır ve true döner; değilse false döner ve `completion` çağrılmaz
         (karar uygulamanındır).
         */
        @discardableResult
        public static func handleWillPresent(_ notification: UNNotification, completion: @escaping (UNNotificationPresentationOptions) -> Void) -> Bool {
            delegate.handleWillPresent(notification, completion: completion)
        }

        /**
         `userNotificationCenter(_:didReceive:withCompletionHandler:)` içinden çağırın. Pushizo bildirimiyse tıklama/kapatma
         işlenir, `completion` tam bir kez çağrılır ve true döner; değilse false döner ve `completion` çağrılmaz.
         */
        @discardableResult
        public static func handleDidReceive(_ response: UNNotificationResponse, completion: @escaping () -> Void) -> Bool {
            delegate.handleDidReceive(response, completion: completion)
        }

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
            var op: [String: Any] = ["type": "event", "name": name, "properties": properties, "occurred_at": ISO8601DateFormatter().string(from: Date()), "event_id": UUID().uuidString.lowercased(), "at": Date().timeIntervalSince1970]
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
        @discardableResult
        public static func addClickListener(_ listener: @escaping (HSInAppClickEvent) -> Void) -> HSListenerToken { inApp.clickListeners.add(listener) }
        public static func removeClickListener(_ token: HSListenerToken) { _ = inApp.clickListeners.remove(token) }
        /// Yaşam döngüsü dinleyicisi (zayıf referansla tutulur).
        public static func addLifecycleListener(_ listener: HSInAppLifecycleListener) { inApp.lifecycleListeners.append(.init(value: listener)) }
        public static func removeLifecycleListener(_ listener: HSInAppLifecycleListener) { inApp.lifecycleListeners.removeAll { $0.value === listener } }

        /// Özel çizim katmanı (ör. Flutter köprüsü); nil varsayılan UIKit çizimine döner.
        public static func setRenderer(_ renderer: HSInAppRenderer?) { inApp.setRenderer(renderer) }
    }

    /// Bildirim kutusu (`add_to_inbox` mesajları). Login'de `identityHash` verildiyse isteklere eklenir.
    public enum Inbox {
        /// `registeredToken`: aboneliğin sahiplik kanıtı kaynağı (push: kayıtlı token, e-posta/SMS: kanonik adres; ADR-0016).
        private struct Ctx { let userId: String; let subscriptionId: String; let registeredToken: String?; let identityHash: String? }

        private static func ctx() throws -> (Ctx, HSApi) {
            guard let store = storage, let api else { throw HSError.notInitialized }
            guard let subId = engagementSubscriptionId() else { throw HSError.noSubscription }
            guard let userId = store.userId else { throw HSError.noUser }
            let c = Ctx(
                userId: userId,
                subscriptionId: subId,
                registeredToken: ownershipToken(store, subscriptionId: subId),
                identityHash: store.userIdentityHash
            )
            return (c, api)
        }

        private static func enc(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value }
        private static func base(_ c: Ctx) -> String { "/users/\(enc(c.userId))/inbox" }
        private static func query(_ c: Ctx) -> String {
            HSOwnership.subscriptionQuery(subscriptionId: c.subscriptionId, registeredToken: c.registeredToken, identityHash: c.identityHash)
        }
        private static func body(_ c: Ctx) -> [String: Any] {
            HSOwnership.subscriptionBody(subscriptionId: c.subscriptionId, registeredToken: c.registeredToken, identityHash: c.identityHash)
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

/**
 UNUserNotificationCenterDelegate: ön plan gösterimi, tıklama → opened + yönlendirme. Pushizo dışı bildirimler,
 SDK delegesi atanmadan önceki delegeye (zayıf referans) iletilir; tamamlama bloğu her durumda tam bir kez çağrılır.
 */
final class HSNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// SDK delegesinden önce atanmış (uygulamanın) delege.
    weak var previous: UNUserNotificationCenterDelegate?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if handleWillPresent(notification, completion: completionHandler) { return }
        // Önceki delege uyguluyorsa karar (ve tamamlama) ona aittir.
        if let previous = self.previous,
           previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) != nil { return }
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if handleDidReceive(response, completion: completionHandler) { return }
        if let previous = self.previous,
           previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler) != nil { return }
        completionHandler()
    }

    /// Uygulama içi bildirim ayarları ekranı isteği Pushizo'yu ilgilendirmez; önceki delegeye iletilir.
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        previous?.userNotificationCenter?(center, openSettingsFor: notification)
    }

    /// Pushizo bildirimiyse ön plan kararını verir (tamamlama tam bir kez) ve true döner; değilse dokunmaz.
    func handleWillPresent(_ notification: UNNotification, completion: @escaping (UNNotificationPresentationOptions) -> Void) -> Bool {
        guard let n = HSNotification(userInfo: notification.request.content.userInfo) else { return false }
        if let id = n.deliveryId { Pushizo.reportReceived(id) }
        // Canlı sohbet bildirimi (`pushizo_chat`): okunmamış sayısı yenilenir.
        Pushizo.Chat.onPushReceived(notification.request.content.userInfo)
        let event = HSForegroundEvent(notification: n) { show in
            completion(show ? [.banner, .sound, .badge, .list] : [])
        }
        Pushizo.foregroundListeners.notify(event)
        if !event.prevented {
            event.complete(true)
        } else {
            // Ertelenmiş karar: süre içinde display() çağrılmazsa gösterilmez.
            DispatchQueue.main.asyncAfter(deadline: .now() + HSForegroundEvent.displayTimeout) { event.complete(false) }
        }
        return true
    }

    /// Pushizo bildirimiyse tıklama/kapatmayı işler, tamamlamayı çağırır ve true döner; değilse dokunmaz.
    func handleDidReceive(_ response: UNNotificationResponse, completion: @escaping () -> Void) -> Bool {
        guard let n = HSNotification(userInfo: response.notification.request.content.userInfo) else { return false }
        switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier:
            Pushizo.reportDismissed(n)
        case UNNotificationDefaultActionIdentifier:
            Pushizo.reportOpened(n, actionId: nil)
        default:
            Pushizo.reportOpened(n, actionId: response.actionIdentifier)
        }
        // Sohbet bildirimi: uygulamanın sohbet ekranını açabilmesi için açma dinleyicilerine iletilir.
        if response.actionIdentifier != UNNotificationDismissActionIdentifier {
            Pushizo.Chat.onNotificationOpened(response.notification.request.content.userInfo)
        }
        completion()
        return true
    }
}
