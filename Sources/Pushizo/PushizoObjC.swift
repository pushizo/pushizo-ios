import Foundation
#if canImport(PushizoCore)
import PushizoCore
#endif
import UIKit
import UserNotifications

/*
 Objective-C cephesi (plan 13 Faz 29, "PushizoObjC" katmanı). Swift API'si (`enum Pushizo`, struct'lar, async/await)
 Objective-C'ye açık değildir; bu dosya aynı yüzeyi `PZ` önekli NSObject sınıfları, sınıf metotları ve completion
 block'larıyla sunar. Objective-C projesi yalnızca `@import Pushizo;` ile kullanır. Mantık burada yeniden yazılmaz:
 her çağrı Swift API'sine devreder. Completion block'ları ana iş parçacığında çağrılır. Swift'e özgü kalanlar (Live
 Activities ActivityKit genelleri, özel in-app çizici) Swift API'sinden kullanılır.
 */

/// Hata alanı ve kodları (`NSError.domain` = `PZErrorDomain`).
@objc(PZErrorCode)
public enum PZErrorCode: Int {
    case notInitialized = 1
    case noSubscription = 2
    case noUser = 3
    case invalidArgument = 4
    case invalidResponse = 5
    /// Platform ya da iOS sürümü özelliği desteklemiyor (ör. Mac Catalyst'te Live Activities).
    case notSupported = 6
    /// Sistem isteği yerine getiremedi (ör. Live Activity başlatılamadı).
    case requestFailed = 7
}

@objc(PZErrors)
public final class PZErrors: NSObject {
    @objc public static let domain = "PZErrorDomain"
    /// Live Activity hatalarında çapraz platform hata kodu (`NSString`; ör. `PLATFORM_NOT_SUPPORTED`).
    @objc public static let codeKey = "PZErrorCode"

    /// Swift hatasını Objective-C'ye uygun `NSError`'a çevirir; SDK dışı hatalar olduğu gibi döner.
    static func bridge(_ error: Error) -> NSError {
        func make(_ code: PZErrorCode, _ message: String, _ extra: [String: Any] = [:]) -> NSError {
            NSError(domain: domain, code: code.rawValue, userInfo: extra.merging([NSLocalizedDescriptionKey: message]) { _, new in new })
        }
        if let chat = error as? HSChatError, case let .invalidArgument(message) = chat { return make(.invalidArgument, message) }
        if let live = error as? HSLiveActivityError {
            switch live {
            case let .notSupported(message): return make(.notSupported, message, [codeKey: live.code])
            case .notInitialized: return make(.notInitialized, "Pushizo.initialize önce çağrılmalı.", [codeKey: live.code])
            case let .invalidArgument(message): return make(.invalidArgument, message, [codeKey: live.code])
            case let .requestFailed(message): return make(.requestFailed, message, [codeKey: live.code])
            }
        }
        guard let e = error as? HSError else { return error as NSError }
        switch e {
        case .notInitialized: return make(.notInitialized, "Pushizo.initialize önce çağrılmalı.")
        case .noSubscription: return make(.noSubscription, "Abonelik henüz kaydedilmedi veya gizlilik onayı bekleniyor.")
        case .noUser: return make(.noUser, "Kullanıcı kimliği henüz yok.")
        case let .invalidArgument(message): return make(.invalidArgument, message)
        case .invalidResponse: return make(.invalidResponse, "Sunucu yanıtı çözülemedi.")
        }
    }
}

@objc(PZLogLevel)
public enum PZLogLevel: Int {
    case none = 0, error, warn, info, debug

    var native: HSLog.Level { HSLog.Level(rawValue: rawValue) ?? .warn }
}

/// Ana iş parçacığında çağırır (zaten ana iş parçacığındaysa hemen).
private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
}

/// Async Swift çağrısını completion block'una bağlar; sonuç ve hata ana iş parçacığında döner.
private func complete<T>(_ completion: @escaping (T?, NSError?) -> Void, _ work: @escaping () async throws -> T) {
    Task {
        do {
            let value = try await work()
            onMain { completion(value, nil) }
        } catch {
            let bridged = PZErrors.bridge(error)
            onMain { completion(nil, bridged) }
        }
    }
}

// MARK: - Modeller

/// SDK yapılandırması (`HSOptions` karşılığı).
@objc(PZOptions)
public final class PZOptions: NSObject {
    /// Boş bırakılırsa varsayılan global kök; SDK bölgesel adresi kendisi öğrenir.
    @objc public var apiUrl: String?
    @objc public var requiresPrivacyConsent = false
    @objc public var apnsEnvironment: String?
    @objc public var appGroup: String?
    @objc public var provisionalAuthorization = false
    @objc public var installsNotificationDelegate = true
    @objc public var logLevel: PZLogLevel = .warn

    func apply(to options: inout HSOptions) {
        if let apiUrl, !apiUrl.isEmpty { options.apiUrl = apiUrl }
        options.requiresPrivacyConsent = requiresPrivacyConsent
        options.apnsEnvironment = apnsEnvironment
        options.appGroup = appGroup
        options.provisionalAuthorization = provisionalAuthorization
        options.installsNotificationDelegate = installsNotificationDelegate
        options.logLevel = logLevel.native
    }
}

/// Eklenen dinleyiciyi kaldırır; birden çok kez çağrılması zararsızdır.
@objc(PZListenerToken)
public final class PZListenerToken: NSObject {
    private let lock = NSLock()
    private var removal: (() -> Void)?

    init(_ removal: @escaping () -> Void) { self.removal = removal }

    @objc public func remove() {
        lock.lock()
        let r = removal
        removal = nil
        lock.unlock()
        r?()
    }
}

@objc(PZNotificationAction)
public final class PZNotificationAction: NSObject {
    @objc public let actionId: String
    @objc public let title: String
    @objc public let url: String?
    @objc public let icon: String?

    init(_ a: HSAction) {
        actionId = a.id
        title = a.title
        url = a.url
        icon = a.icon
    }
}

@objc(PZNotification)
public final class PZNotification: NSObject {
    @objc public let title: String?
    @objc public let body: String?
    @objc public let imageUrl: String?
    @objc public let url: String?
    @objc public let deliveryId: String?
    @objc public let messageId: String?
    @objc public let actions: [PZNotificationAction]
    @objc public let data: [String: String]
    @objc public let carousel: [String]
    /// Bildirim isteğinin kimliği (`UNNotificationRequest.identifier`); `[PZNotifications removeNotification:]` ile kullanılır.
    @objc public let identifier: String?

    init(_ n: HSNotification) {
        identifier = n.identifier
        title = n.title
        body = n.body
        imageUrl = n.imageUrl
        url = n.url
        deliveryId = n.deliveryId
        messageId = n.messageId
        actions = n.actions.map(PZNotificationAction.init)
        data = n.data
        carousel = n.carousel
    }
}

@objc(PZClickEvent)
public final class PZClickEvent: NSObject {
    @objc public let notification: PZNotification
    /// Düğmeye basıldıysa düğme kimliği.
    @objc public let actionId: String?
    @objc public let url: String?

    init(_ e: HSClickEvent) {
        notification = PZNotification(e.notification)
        actionId = e.actionId
        url = e.url
    }
}

/// Ön planda gelen bildirim: `preventDefault` gösterimi engeller, `display` sonradan gösterir (25 sn içinde).
@objc(PZForegroundEvent)
public final class PZForegroundEvent: NSObject {
    private let event: HSForegroundEvent
    @objc public let notification: PZNotification

    init(_ e: HSForegroundEvent) {
        event = e
        notification = PZNotification(e.notification)
    }

    @objc public func preventDefault() { event.preventDefault() }
    @objc public func display() { event.display() }
}

@objc(PZPushSubscriptionState)
public final class PZPushSubscriptionState: NSObject {
    @objc public let subscriptionId: String?
    @objc public let token: String?
    @objc public let optedIn: Bool
    @objc public let permission: UNAuthorizationStatus

    init(_ s: HSPushSubscriptionState) {
        subscriptionId = s.id
        token = s.token
        optedIn = s.optedIn
        permission = s.permission
    }
}

@objc(PZInboxItem)
public final class PZInboxItem: NSObject {
    @objc public let itemId: String
    @objc public let messageId: String?
    @objc public let title: String?
    @objc public let body: String?
    @objc public let url: String?
    @objc public let imageUrl: String?
    @objc public let data: [String: String]
    @objc public let read: Bool
    @objc public let readAt: Date?
    @objc public let archivedAt: Date?
    @objc public let expiresAt: Date?
    @objc public let createdAt: Date?

    init(_ i: HSInboxItem) {
        itemId = i.id
        messageId = i.messageId
        title = i.title
        body = i.body
        url = i.url
        imageUrl = i.imageUrl
        data = i.data
        read = i.read
        readAt = i.readAt
        archivedAt = i.archivedAt
        expiresAt = i.expiresAt
        createdAt = i.createdAt
    }
}

/// `PZInbox.addObserver` olayı; `type`: `listed`, `read`, `read_all`, `archived` veya `count`.
@objc(PZInboxChangeEvent)
public final class PZInboxChangeEvent: NSObject {
    @objc public let type: String
    @objc public let itemId: String?
    @objc public let unreadCount: Int

    init(_ e: HSInboxChangeEvent) {
        type = e.type.rawValue
        itemId = e.itemId
        unreadCount = e.unreadCount
    }
}

/// Girişle birlikte ayarlanan profil (`HSUserProfile` karşılığı).
@objc(PZUserProfile)
public final class PZUserProfile: NSObject {
    @objc public var email: String?
    @objc public var sms: String?
    @objc public var tags: [String: String] = [:]
    @objc public var aliases: [String: String] = [:]

    var native: HSUserProfile { HSUserProfile(email: email, sms: sms, tags: tags, aliases: aliases) }
}

@objc(PZInboxPage)
public final class PZInboxPage: NSObject {
    @objc public let items: [PZInboxItem]
    @objc public let unreadCount: Int
    @objc public let nextCursor: String?
    @objc public let hasMore: Bool

    init(_ p: HSInboxPage) {
        items = p.items.map(PZInboxItem.init)
        unreadCount = p.unreadCount
        nextCursor = p.nextCursor
        hasMore = p.hasMore
    }
}

/// İçerik kartı (ADR-0082); `type`: `classic`, `captioned_image`, `image_only`.
@objc(PZContentCard)
public final class PZContentCard: NSObject {
    @objc public let cardId: String
    @objc public let messageId: String?
    @objc public let type: String
    @objc public let title: String?
    @objc public let body: String?
    @objc public let url: String?
    @objc public let imageUrl: String?
    @objc public let buttonText: String?
    @objc public let data: [String: String]
    @objc public let pinned: Bool
    @objc public let priority: Int
    @objc public let viewed: Bool
    @objc public let clicked: Bool
    @objc public let expiresAt: Date?
    @objc public let createdAt: Date?

    init(_ c: HSContentCard) {
        cardId = c.id
        messageId = c.messageId
        type = c.type.rawValue
        title = c.title
        body = c.body
        url = c.url
        imageUrl = c.imageUrl
        buttonText = c.buttonText
        data = c.data
        pinned = c.pinned
        priority = c.priority
        viewed = c.viewed
        clicked = c.clicked
        expiresAt = c.expiresAt
        createdAt = c.createdAt
    }
}

@objc(PZContentCardFeed)
public final class PZContentCardFeed: NSObject {
    @objc public let cards: [PZContentCard]
    @objc public let unviewedCount: Int

    init(_ f: HSContentCardFeed) {
        cards = f.cards.map(PZContentCard.init)
        unviewedCount = f.unviewedCount
    }
}

@objc(PZPreference)
public final class PZPreference: NSObject {
    @objc public let category: String
    /// `nil` = tüm kanallar; aksi halde `ios_push`, `android_push`, `web_push`, `email`, `sms`.
    @objc public let channel: String?
    @objc public let optedIn: Bool
    @objc public let explicit: Bool
    @objc public let source: String?
    @objc public let updatedAt: Date?

    init(_ p: HSPreference) {
        category = p.category
        channel = p.channel
        optedIn = p.optedIn
        explicit = p.explicit
        source = p.source
        updatedAt = p.updatedAt
    }
}

@objc(PZMessageCategory)
public final class PZMessageCategory: NSObject {
    @objc public let key: String
    @objc public let name: [String: String]
    @objc public let categoryDescription: [String: String]
    @objc public let channels: [String]?
    @objc public let defaultOptedIn: Bool

    init(_ c: HSMessageCategory) {
        key = c.key
        name = c.name
        categoryDescription = c.description
        channels = c.channels
        defaultOptedIn = c.defaultOptedIn
    }

    /// Verilen dilde ad; yoksa İngilizce, o da yoksa ilk tanımlı dil.
    @objc public func localizedName(_ language: String) -> String {
        name[language] ?? name["en"] ?? name.values.first ?? key
    }
}

@objc(PZUserConsent)
public final class PZUserConsent: NSObject {
    @objc public let purpose: String
    @objc public let granted: Bool
    @objc public let source: String?
    @objc public let updatedAt: Date?

    init(_ c: HSUserConsent) {
        purpose = c.purpose
        granted = c.granted
        source = c.source
        updatedAt = c.updatedAt
    }
}

@objc(PZPreferencesResult)
public final class PZPreferencesResult: NSObject {
    @objc public let preferences: [PZPreference]
    @objc public let categories: [PZMessageCategory]
    @objc public let consents: [PZUserConsent]

    init(_ r: HSPreferencesResult) {
        preferences = r.preferences.map(PZPreference.init)
        categories = r.categories.map(PZMessageCategory.init)
        consents = r.consents.map(PZUserConsent.init)
    }
}

/// `setPreferences` girdisi; `channel` nil ise tüm kanallar.
@objc(PZPreferenceInput)
public final class PZPreferenceInput: NSObject {
    @objc public let category: String
    @objc public let channel: String?
    @objc public let optedIn: Bool

    @objc public init(category: String, channel: String?, optedIn: Bool) {
        self.category = category
        self.channel = channel
        self.optedIn = optedIn
    }

    var native: HSPreferenceInput { HSPreferenceInput(category: category, channel: channel, optedIn: optedIn) }
}

@objc(PZInAppClickEvent)
public final class PZInAppClickEvent: NSObject {
    @objc public let messageId: String
    @objc public let actionId: String
    @objc public let url: String?

    init(_ e: HSInAppClickEvent) {
        messageId = e.messageId
        actionId = e.actionId
        url = e.url
    }
}

/// In-app düğmesi. `actionType`: `dismiss`, `url`, `deeplink`, `tags`, `push_prompt`, `outcome`.
@objc(PZInAppButton)
public final class PZInAppButton: NSObject {
    @objc public let buttonId: String
    @objc public let text: String
    @objc public let actionType: String
    /// `url`/`deeplink` adresi veya `outcome` adı; diğer türlerde nil.
    @objc public let actionValue: String?
    /// `tags` eyleminin etiketleri; diğer türlerde boş.
    @objc public let actionTags: [String: String]
    @objc public let backgroundColor: String?
    @objc public let textColor: String?

    init(_ b: HSInAppButton) {
        buttonId = b.id
        text = b.text
        backgroundColor = b.backgroundColor
        textColor = b.textColor
        switch b.action {
        case .dismiss: (actionType, actionValue, actionTags) = ("dismiss", nil, [:])
        case let .url(u): (actionType, actionValue, actionTags) = ("url", u, [:])
        case let .deeplink(u): (actionType, actionValue, actionTags) = ("deeplink", u, [:])
        case let .tags(t): (actionType, actionValue, actionTags) = ("tags", nil, t)
        case .pushPrompt: (actionType, actionValue, actionTags) = ("push_prompt", nil, [:])
        case let .outcome(name, _): (actionType, actionValue, actionTags) = ("outcome", name, [:])
        }
    }
}

@objc(PZInAppCarouselCard)
public final class PZInAppCarouselCard: NSObject {
    @objc public let cardId: String
    @objc public let title: String
    @objc public let body: String?
    @objc public let imageUrl: String?
    @objc public let imageAlt: String?
    @objc public let button: PZInAppButton?

    init(_ c: HSInAppCarouselCard) {
        cardId = c.id
        title = c.title
        body = c.body
        imageUrl = c.imageUrl
        imageAlt = c.imageAlt
        button = c.button.map(PZInAppButton.init)
    }
}

/// İçerik bloğu. `kind`: `image` (url, alt), `title` ve `body` (text), `button` (button), `carousel` (cards).
@objc(PZInAppBlock)
public final class PZInAppBlock: NSObject {
    @objc public let kind: String
    @objc public let text: String?
    @objc public let url: String?
    @objc public let alt: String?
    @objc public let button: PZInAppButton?
    @objc public let cards: [PZInAppCarouselCard]

    init(_ b: HSInAppBlock) {
        switch b {
        case let .image(url, alt): (kind, text, self.url, self.alt, button, cards) = ("image", nil, url, alt, nil, [])
        case let .title(t): (kind, text, url, alt, button, cards) = ("title", t, nil, nil, nil, [])
        case let .body(t): (kind, text, url, alt, button, cards) = ("body", t, nil, nil, nil, [])
        case let .button(btn): (kind, text, url, alt, button, cards) = ("button", nil, nil, nil, PZInAppButton(btn), [])
        case let .carousel(c): (kind, text, url, alt, button, cards) = ("carousel", nil, nil, nil, nil, c.cards.map(PZInAppCarouselCard.init))
        }
    }
}

/// Gömülü yerleşim içeriği. Çizim uygulamanındır; içerik görününce `reportImpression` çağrılır.
@objc(PZInAppMessage)
public final class PZInAppMessage: NSObject {
    let native: HSInAppMessage
    @objc public let messageId: String
    @objc public let variantId: String?
    /// `modal`, `banner_top`, `banner_bottom`, `fullscreen`.
    @objc public let layout: String
    /// `blocks` veya `html`.
    @objc public let contentType: String
    @objc public let html: String?
    @objc public let backgroundColor: String?
    @objc public let textColor: String?
    @objc public let dismissible: Bool
    @objc public let blocks: [PZInAppBlock]

    init(_ m: HSInAppMessage) {
        native = m
        messageId = m.id
        variantId = m.variantId
        layout = m.display.layout.rawValue
        contentType = m.display.contentType.rawValue
        html = m.display.html
        backgroundColor = m.display.backgroundColor
        textColor = m.display.textColor
        dismissible = m.display.dismissible
        blocks = m.display.blocks.map(PZInAppBlock.init)
    }
}

// MARK: - Cephe

@objc(PZPushizo)
public final class PZPushizo: NSObject {
    @objc public static var isInitialized: Bool { Pushizo.isInitialized }
    @objc public static var sdkVersion: String { Pushizo.sdkVersion }

    @objc(initializeWithAppId:launchOptions:options:)
    public static func initialize(appId: String, launchOptions: [UIApplication.LaunchOptionsKey: Any]?, options: PZOptions?) {
        Pushizo.initialize(appId, launchOptions: launchOptions) { native in options?.apply(to: &native) }
    }

    @objc public static func setConsentGiven(_ given: Bool) { Pushizo.setConsentGiven(given) }

    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` içinden (bildirim delegesi uygulamadaysa).
    @objc public static func setDeviceToken(_ deviceToken: Data) { Pushizo.setDeviceToken(deviceToken) }
    @objc public static func setDeviceTokenError(_ error: Error) { Pushizo.setDeviceTokenError(error) }

    /// Anonim cihazı kullanıcıya bağlar; kimlik doğrulaması açıksa `identityHash` veya `jwt` verilir.
    @objc(loginWithExternalId:identityHash:jwt:)
    public static func login(externalId: String, identityHash: String?, jwt: String?) {
        Pushizo.login(externalId, identityHash: identityHash, jwt: jwt)
    }

    @objc(loginWithExternalId:)
    public static func login(externalId: String) { Pushizo.login(externalId) }

    /// Profille giriş: profil ya da kimlik kanıtı geçersizse giriş yapılmaz, NO döner ve `error` dolar.
    @objc(loginWithExternalId:profile:identityHash:jwt:error:)
    public static func login(externalId: String, profile: PZUserProfile, identityHash: String?, jwt: String?) throws {
        do { try Pushizo.login(externalId, profile: profile.native, identityHash: identityHash, jwt: jwt) } catch { throw PZErrors.bridge(error) }
    }

    @objc public static func logout() { Pushizo.logout() }

    @objc(updateUserJwt:error:)
    public static func updateUserJwt(_ jwt: String) throws {
        do { try Pushizo.updateUserJwt(jwt) } catch { throw PZErrors.bridge(error) }
    }

    @objc public static func setLogLevel(_ level: PZLogLevel) { Pushizo.Debug.setLogLevel(level.native) }
}

@objc(PZUser)
public final class PZUser: NSObject {
    @objc public static var externalId: String? { Pushizo.User.externalId }
    @objc public static var userId: String? { Pushizo.User.id }
    @objc public static var emails: [String] { Pushizo.User.emails }
    @objc public static var smsNumbers: [String] { Pushizo.User.smsNumbers }

    @objc(addTagWithKey:value:)
    public static func addTag(key: String, value: String) { Pushizo.User.addTag(key, value) }
    @objc public static func addTags(_ tags: [String: String]) { Pushizo.User.addTags(tags) }
    @objc public static func removeTag(_ key: String) { Pushizo.User.removeTag(key) }
    @objc public static func removeTags(_ keys: [String]) { Pushizo.User.removeTags(keys) }
    @objc public static func getTags() -> [String: String] { Pushizo.User.getTags() }

    @objc(addAliasWithLabel:aliasId:)
    public static func addAlias(label: String, aliasId: String) { Pushizo.User.addAlias(label, aliasId) }
    @objc public static func addAliases(_ aliases: [String: String]) { Pushizo.User.addAliases(aliases) }
    @objc public static func removeAlias(_ label: String) { Pushizo.User.removeAlias(label) }

    @objc public static func setLanguage(_ code: String) { Pushizo.User.setLanguage(code) }

    /// Kullanıcı özelliği yazar (`NSString`, `NSNumber`, `NSArray`, `NSDictionary`); `nil` özelliği siler.
    @objc(setProperty:value:)
    public static func setProperty(_ key: String, value: Any?) { Pushizo.User.setProperty(key, value) }
    @objc public static func addEmail(_ email: String) { Pushizo.User.addEmail(email) }
    @objc public static func removeEmail(_ email: String) { Pushizo.User.removeEmail(email) }
    @objc public static func addSms(_ phoneNumber: String) { Pushizo.User.addSms(phoneNumber) }
    @objc public static func removeSms(_ phoneNumber: String) { Pushizo.User.removeSms(phoneNumber) }

    @objc(getPreferencesWithCompletion:)
    public static func getPreferences(completion: @escaping (PZPreferencesResult?, NSError?) -> Void) {
        complete(completion) { PZPreferencesResult(try await Pushizo.User.getPreferences()) }
    }

    @objc(setPreferences:completion:)
    public static func setPreferences(_ preferences: [PZPreferenceInput], completion: ((PZPreferencesResult?, NSError?) -> Void)?) {
        let input = preferences.map(\.native)
        complete(completion ?? { _, _ in }) { PZPreferencesResult(try await Pushizo.User.setPreferences(input)) }
    }

    @objc(getConsentsWithCompletion:)
    public static func getConsents(completion: @escaping ([PZUserConsent]?, NSError?) -> Void) {
        complete(completion) { try await Pushizo.User.getConsents().map(PZUserConsent.init) }
    }
}

@objc(PZPushSubscription)
public final class PZPushSubscription: NSObject {
    @objc public static var subscriptionId: String? { Pushizo.User.pushSubscription.id }
    @objc public static var token: String? { Pushizo.User.pushSubscription.token }
    /// Önbellekten eşzamanlı değer; kesin durum için `getStateWithCompletion:`.
    @objc public static var optedIn: Bool { Pushizo.User.pushSubscription.optedIn }

    @objc public static func optIn() { Pushizo.User.pushSubscription.optIn() }
    @objc public static func optOut() { Pushizo.User.pushSubscription.optOut() }

    @objc(getStateWithCompletion:)
    public static func getState(completion: @escaping (PZPushSubscriptionState) -> Void) {
        Task {
            let state = PZPushSubscriptionState(await Pushizo.User.pushSubscription.state())
            onMain { completion(state) }
        }
    }

    @objc(addObserver:)
    @discardableResult
    public static func addObserver(_ observer: @escaping (PZPushSubscriptionState) -> Void) -> PZListenerToken {
        let token = Pushizo.User.pushSubscription.addObserver { observer(PZPushSubscriptionState($0)) }
        return PZListenerToken { Pushizo.User.pushSubscription.removeObserver(token) }
    }
}

@objc(PZNotifications)
public final class PZNotifications: NSObject {
    /// Sistem izni ister; sonuç ana iş parçacığında döner.
    @objc(requestPermissionWithCompletion:)
    public static func requestPermission(completion: ((Bool) -> Void)?) {
        Pushizo.Notifications.requestPermission { granted in onMain { completion?(granted) } }
    }

    @objc(getPermissionStatusWithCompletion:)
    public static func getPermissionStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        Task {
            let status = await Pushizo.Notifications.permission()
            onMain { completion(status) }
        }
    }

    @objc(isPermissionGrantedWithCompletion:)
    public static func isPermissionGranted(completion: @escaping (Bool) -> Void) {
        Task {
            let granted = await Pushizo.Notifications.isPermissionGranted()
            onMain { completion(granted) }
        }
    }

    @objc(addPermissionObserver:)
    @discardableResult
    public static func addPermissionObserver(_ observer: @escaping (Bool) -> Void) -> PZListenerToken {
        let token = Pushizo.Notifications.addPermissionObserver(observer)
        return PZListenerToken { Pushizo.Notifications.removePermissionObserver(token) }
    }

    @objc(addClickListener:)
    @discardableResult
    public static func addClickListener(_ listener: @escaping (PZClickEvent) -> Void) -> PZListenerToken {
        let token = Pushizo.Notifications.addClickListener { listener(PZClickEvent($0)) }
        return PZListenerToken { Pushizo.Notifications.removeClickListener(token) }
    }

    @objc(addForegroundLifecycleListener:)
    @discardableResult
    public static func addForegroundLifecycleListener(_ listener: @escaping (PZForegroundEvent) -> Void) -> PZListenerToken {
        let token = Pushizo.Notifications.addForegroundLifecycleListener { listener(PZForegroundEvent($0)) }
        return PZListenerToken { Pushizo.Notifications.removeForegroundLifecycleListener(token) }
    }

    /// Bildirim delegesi uygulamadaysa `willPresent` içinden; Pushizo bildirimi değilse NO döner ve completion çağrılmaz.
    @objc(handleWillPresent:completion:)
    public static func handleWillPresent(_ notification: UNNotification, completion: @escaping (UNNotificationPresentationOptions) -> Void) -> Bool {
        Pushizo.Notifications.handleWillPresent(notification, completion: completion)
    }

    /// Bildirim delegesi uygulamadaysa `didReceive` içinden; Pushizo bildirimi değilse NO döner ve completion çağrılmaz.
    @objc(handleDidReceive:completion:)
    public static func handleDidReceive(_ response: UNNotificationResponse, completion: @escaping () -> Void) -> Bool {
        Pushizo.Notifications.handleDidReceive(response, completion: completion)
    }

    @objc public static func setBadgeCount(_ count: Int) { Pushizo.Notifications.setBadgeCount(count) }
    @objc public static func clearBadge() { Pushizo.Notifications.clearBadge() }
    @objc public static func clearAll() { Pushizo.Notifications.clearAll() }
    @objc public static func removeGroupedNotifications(_ threadId: String) { Pushizo.Notifications.removeGroupedNotifications(threadId) }
    @objc public static func removeNotification(_ identifier: String) { Pushizo.Notifications.removeNotification(identifier: identifier) }
}

@objc(PZSession)
public final class PZSession: NSObject {
    /// Özel olay; `value` (ör. sipariş tutarı) isteğe bağlıdır.
    @objc(sendEvent:properties:value:)
    public static func sendEvent(_ name: String, properties: [String: Any]?, value: NSNumber?) {
        Pushizo.Session.sendEvent(name, properties: properties ?? [:], value: value?.doubleValue)
    }

    /// `eventId`: tekilleştirme kimliği (8-64 karakter, harf, rakam ve `._:-`); nil ya da geçersizse SDK üretir.
    @objc(sendEvent:properties:value:eventId:)
    public static func sendEvent(_ name: String, properties: [String: Any]?, value: NSNumber?, eventId: String?) {
        Pushizo.Session.sendEvent(name, properties: properties ?? [:], value: value?.doubleValue, eventId: eventId)
    }
}

@objc(PZInAppMessages)
public final class PZInAppMessages: NSObject {
    @objc(addTriggerWithKey:value:)
    public static func addTrigger(key: String, value: String) { Pushizo.InAppMessages.addTrigger(key, value) }
    @objc public static func addTriggers(_ triggers: [String: String]) { Pushizo.InAppMessages.addTriggers(triggers) }
    @objc public static func removeTrigger(_ key: String) { Pushizo.InAppMessages.removeTrigger(key) }
    @objc public static func removeTriggers(_ keys: [String]) { Pushizo.InAppMessages.removeTriggers(keys) }
    @objc public static func clearTriggers() { Pushizo.InAppMessages.clearTriggers() }
    @objc public static func getTriggers() -> [String: String] { Pushizo.InAppMessages.getTriggers() }
    @objc public static func setScreen(_ name: String?) { Pushizo.InAppMessages.setScreen(name) }

    @objc public static var paused: Bool {
        get { Pushizo.InAppMessages.paused }
        set { Pushizo.InAppMessages.paused = newValue }
    }

    @objc(addClickListener:)
    @discardableResult
    public static func addClickListener(_ listener: @escaping (PZInAppClickEvent) -> Void) -> PZListenerToken {
        let token = Pushizo.InAppMessages.addClickListener { listener(PZInAppClickEvent($0)) }
        return PZListenerToken { Pushizo.InAppMessages.removeClickListener(token) }
    }

    private static let lifecycleLock = NSLock()
    private static var lifecycleAdapters: [ObjectIdentifier: PZInAppLifecycleAdapter] = [:]

    /// Yaşam döngüsü dinleyicisi (ana iş parçacığında). Dinleyici zayıf referansla tutulur; aynı nesne bir kez kaydedilir.
    @objc(addLifecycleListener:)
    @discardableResult
    public static func addLifecycleListener(_ listener: PZInAppLifecycleListener) -> PZListenerToken {
        let key = ObjectIdentifier(listener)
        lifecycleLock.lock()
        let existing = lifecycleAdapters[key]
        let adapter = existing ?? PZInAppLifecycleAdapter(listener)
        lifecycleAdapters[key] = adapter
        lifecycleLock.unlock()
        if existing == nil { Pushizo.InAppMessages.addLifecycleListener(adapter) }
        return PZListenerToken { [weak listener] in
            if let listener { removeLifecycleListener(listener) } else { removeLifecycleAdapter(key) }
        }
    }

    @objc(removeLifecycleListener:)
    public static func removeLifecycleListener(_ listener: PZInAppLifecycleListener) {
        removeLifecycleAdapter(ObjectIdentifier(listener))
    }

    private static func removeLifecycleAdapter(_ key: ObjectIdentifier) {
        lifecycleLock.lock()
        let adapter = lifecycleAdapters.removeValue(forKey: key)
        lifecycleLock.unlock()
        if let adapter { Pushizo.InAppMessages.removeLifecycleListener(adapter) }
    }
}

/// In-app yaşam döngüsü dinleyicisi (`HSInAppLifecycleListener` karşılığı); tüm metotlar isteğe bağlıdır.
@objc(PZInAppLifecycleListener)
public protocol PZInAppLifecycleListener: NSObjectProtocol {
    @objc optional func onWillDisplay(_ message: PZInAppMessage)
    @objc optional func onDidDisplay(_ message: PZInAppMessage)
    @objc optional func onWillDismiss(_ message: PZInAppMessage)
    @objc optional func onDidDismiss(_ message: PZInAppMessage)
}

/// Objective-C dinleyicisini Swift protokolüne uyarlar; cephe güçlü tutar, asıl dinleyici zayıf kalır.
final class PZInAppLifecycleAdapter: HSInAppLifecycleListener {
    private weak var listener: PZInAppLifecycleListener?

    init(_ listener: PZInAppLifecycleListener) { self.listener = listener }

    func onWillDisplay(_ message: HSInAppMessage) { listener?.onWillDisplay?(PZInAppMessage(message)) }
    func onDidDisplay(_ message: HSInAppMessage) { listener?.onDidDisplay?(PZInAppMessage(message)) }
    func onWillDismiss(_ message: HSInAppMessage) { listener?.onWillDismiss?(PZInAppMessage(message)) }
    func onDidDismiss(_ message: HSInAppMessage) { listener?.onDidDismiss?(PZInAppMessage(message)) }
}

/// Mobil reklam kimliği (IDFA; ADR-0037). SDK ATT istemi içermez: izni uygulama alır ve kimliği verir.
@objc(PZAds)
public final class PZAds: NSObject {
    /// Reklam kimliğini yazar; `nil` veya sıfır kimlik sunucudaki kaydı siler.
    @objc public static func setAdvertisingId(_ advertisingId: String?) { Pushizo.Ads.setAdvertisingId(advertisingId) }
}

/// Live Activities'in genel türü (köprüler için). ActivityKit genelleri (`register`, `startTracking`) Swift'ten kullanılır.
@objc(PZLiveActivities)
public final class PZLiveActivities: NSObject {
    /// Genel türün `activity_type` değeri.
    @objc public static var defaultActivityType: String { Pushizo.LiveActivities.defaultActivityType }

    /// Genel türü kaydeder. iOS 16.1 öncesinde ve Mac Catalyst'te `PZErrorCodeNotSupported`, başlatılmamış SDK'da
    /// `PZErrorCodeNotInitialized`.
    @objc(setupDefaultLiveActivityAndReturnError:)
    public static func setupDefaultLiveActivity() throws {
        do { try Pushizo.LiveActivities.setupDefaultLiveActivity() } catch { throw PZErrors.bridge(error) }
    }

    /// Genel türle yerel etkinlik başlatır; değerler `NSString` veya `NSNumber` (anahtar 1-64 karakter).
    /// Hata: `PZErrorCodeInvalidArgument`, `NotSupported`, `NotInitialized`, `RequestFailed`.
    @objc(startDefaultLiveActivityWithActivityId:attributes:contentState:error:)
    public static func startDefaultLiveActivity(activityId: String, attributes: [String: Any], contentState: [String: Any]) throws {
        do {
            try Pushizo.LiveActivities.startDefaultLiveActivity(activityId: activityId, attributes: attributes, contentState: contentState)
        } catch { throw PZErrors.bridge(error) }
    }
}

@objc(PZLocation)
public final class PZLocation: NSObject {
    @objc public static var isShared: Bool { Pushizo.Location.isShared }
    @objc public static func setShared(_ shared: Bool) { Pushizo.Location.setShared(shared) }
    /// Konum izni ("kullanırken" veya "her zaman") verilmiş mi; istem göstermez.
    @objc public static var permissionGranted: Bool { Pushizo.Location.permissionGranted }
    /// Arka plan ("her zaman") konum izni verilmiş mi; istem göstermez.
    @objc public static var backgroundPermissionGranted: Bool { Pushizo.Location.backgroundPermissionGranted }

    @objc(requestPermissionWithRationale:completion:)
    public static func requestPermission(rationale: String?, completion: @escaping (Bool) -> Void) {
        Pushizo.Location.requestPermission(rationale: rationale) { granted in onMain { completion(granted) } }
    }

    /// Arka plan bölge izleme (varsayılan kapalı); izinleri ve Info.plist açıklamalarını uygulama ekler.
    @objc public static var isGeofencingEnabled: Bool { Pushizo.Location.isGeofencingEnabled }
    @objc public static func setGeofencingEnabled(_ enabled: Bool) { Pushizo.Location.setGeofencingEnabled(enabled) }

    @objc(requestAlwaysPermissionWithCompletion:)
    public static func requestAlwaysPermission(completion: @escaping (Bool) -> Void) {
        Pushizo.Location.requestAlwaysPermission { granted in onMain { completion(granted) } }
    }
}

@objc(PZInbox)
public final class PZInbox: NSObject {
    /// Öğeler (yeniden eskiye), okunmamış sayısı ve sonraki sayfa imleci; `limit` 1–200.
    @objc(listWithLimit:cursor:completion:)
    public static func list(limit: Int, cursor: String?, completion: @escaping (PZInboxPage?, NSError?) -> Void) {
        complete(completion) { PZInboxPage(try await Pushizo.Inbox.list(limit: limit, cursor: cursor)) }
    }

    @objc(markRead:completion:)
    public static func markRead(_ itemId: String, completion: ((PZInboxItem?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) { PZInboxItem(try await Pushizo.Inbox.markRead(itemId)) }
    }

    /// Okundu işaretlenen öğe sayısı completion'da `NSNumber` olarak döner.
    @objc(markAllReadWithCompletion:)
    public static func markAllRead(completion: ((NSNumber?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) { NSNumber(value: try await Pushizo.Inbox.markAllRead()) }
    }

    @objc(archive:completion:)
    public static func archive(_ itemId: String, completion: ((NSError?) -> Void)?) {
        complete({ (_: Bool?, error: NSError?) in completion?(error) }) {
            try await Pushizo.Inbox.archive(itemId)
            return true
        }
    }

    @objc(unreadCountWithCompletion:)
    public static func unreadCount(completion: @escaping (NSNumber?, NSError?) -> Void) {
        complete(completion) { NSNumber(value: try await Pushizo.Inbox.unreadCount()) }
    }

    /// Kutu değişim gözlemcisi (ana iş parçacığında); `[token remove]` ile kaldırılır.
    @objc(addObserver:)
    @discardableResult
    public static func addObserver(_ observer: @escaping (PZInboxChangeEvent) -> Void) -> PZListenerToken {
        let token = Pushizo.Inbox.addObserver { observer(PZInboxChangeEvent($0)) }
        return PZListenerToken { Pushizo.Inbox.removeObserver(token) }
    }

    /// `[token remove]` ile aynı.
    @objc(removeObserver:)
    public static func removeObserver(_ token: PZListenerToken) { token.remove() }
}

/// İçerik kartları (ADR-0082): gösterimde `logImpression`, tıklamada `logClick`, kapatmada `dismiss`.
@objc(PZContentCards)
public final class PZContentCards: NSObject {
    /// Kart akışı (sabitlenmiş → öncelik → yeni); `limit` 1–100.
    @objc(listWithLimit:completion:)
    public static func list(limit: Int, completion: @escaping (PZContentCardFeed?, NSError?) -> Void) {
        complete(completion) { PZContentCardFeed(try await Pushizo.ContentCards.list(limit: limit)) }
    }

    @objc(logImpression:completion:)
    public static func logImpression(_ cardId: String, completion: @escaping (PZContentCard?, NSError?) -> Void) {
        complete(completion) { PZContentCard(try await Pushizo.ContentCards.logImpression(cardId)) }
    }

    @objc(logClick:completion:)
    public static func logClick(_ cardId: String, completion: @escaping (PZContentCard?, NSError?) -> Void) {
        complete(completion) { PZContentCard(try await Pushizo.ContentCards.logClick(cardId)) }
    }

    @objc(dismiss:completion:)
    public static func dismiss(_ cardId: String, completion: @escaping (PZContentCard?, NSError?) -> Void) {
        complete(completion) { PZContentCard(try await Pushizo.ContentCards.dismiss(cardId)) }
    }
}

@objc(PZFeatureFlags)
public final class PZFeatureFlags: NSObject {
    /// Değerleri hemen yeniler; hata son değerleri korur ve NO döner.
    @objc(refreshWithCompletion:)
    public static func refresh(completion: ((Bool) -> Void)?) {
        Task {
            let ok = await Pushizo.FeatureFlags.refresh()
            onMain { completion?(ok) }
        }
    }

    @objc(isEnabled:defaultValue:)
    public static func isEnabled(_ key: String, defaultValue: Bool) -> Bool {
        Pushizo.FeatureFlags.isEnabled(key, default: defaultValue)
    }

    /// Bayrağın değeri: `NSString`, `NSNumber`, `NSDictionary` veya `NSArray`; değer yoksa `defaultValue`.
    @objc(valueForKey:defaultValue:)
    public static func value(_ key: String, defaultValue: Any?) -> Any? {
        Pushizo.FeatureFlags.value(key, default: defaultValue)
    }

    /// Bayrak değerleri her yenilendiğinde ana iş parçacığında çağrılır; `[token remove]` ile kaldırılır.
    @objc(addObserver:)
    @discardableResult
    public static func addObserver(_ observer: @escaping () -> Void) -> PZListenerToken {
        let token = Pushizo.FeatureFlags.addObserver(observer)
        return PZListenerToken { Pushizo.FeatureFlags.removeObserver(token) }
    }

    /// `[token remove]` ile aynı.
    @objc(removeObserver:)
    public static func removeObserver(_ token: PZListenerToken) { token.remove() }
}

// MARK: - Canlı sohbet

@objc(PZChatAttachment)
public final class PZChatAttachment: NSObject {
    @objc public let attachmentId: String
    @objc public let name: String
    /// MIME türü.
    @objc public let type: String
    @objc public let size: Int

    init(_ a: HSChatAttachment) {
        attachmentId = a.id
        name = a.name
        type = a.type
        size = a.size
    }
}

/// Bot sorusunun hızlı yanıt seçeneği; seçilince `sendMessage:optionId:` ile gönderilir.
@objc(PZChatQuickReply)
public final class PZChatQuickReply: NSObject {
    @objc public let replyId: String
    @objc public let label: String

    init(_ r: HSChatQuickReply) {
        replyId = r.id
        label = r.label
    }
}

@objc(PZChatMessage)
public final class PZChatMessage: NSObject {
    /// Sunucu kimliği; bekleyen yerel mesajda nil.
    @objc public let messageId: String?
    /// Konuşma içi sıra numarası; bekleyen yerel mesajda 0.
    @objc public let seq: Int
    @objc public let clientMessageId: String?
    /// `visitor`, `agent`, `bot` veya `system`.
    @objc public let sender: String
    @objc public let authorName: String?
    @objc public let text: String?
    @objc public let attachments: [PZChatAttachment]
    /// Bot sorusunun seçenekleri (yoksa boş).
    @objc public let quickReplies: [PZChatQuickReply]
    /// `pending` (yerel), `sent`, `delivered` veya `read`.
    @objc public let status: String
    @objc public let createdAt: Date?
    @objc public let isFromVisitor: Bool
    /// Köprüler için sözlük (camelCase; boş değerler `NSNull`, zaman epoch milisaniye).
    @objc public let dictionary: [String: Any]

    init(_ m: HSChatMessage) {
        messageId = m.id
        seq = m.seq
        clientMessageId = m.clientMessageId
        sender = m.sender
        authorName = m.authorName
        text = m.text
        attachments = m.attachments.map(PZChatAttachment.init)
        quickReplies = (m.quickReplies ?? []).map(PZChatQuickReply.init)
        status = m.status
        createdAt = m.createdAt
        isFromVisitor = m.isFromVisitor
        dictionary = m.dictionary
    }
}

@objc(PZChatConversation)
public final class PZChatConversation: NSObject {
    @objc public let conversationId: String
    /// `open`, `pending` veya `resolved`.
    @objc public let status: String
    @objc public let lastSeq: Int
    @objc public let agentLastReadSeq: Int
    @objc public let visitorLastReadSeq: Int
    @objc public let unreadCount: Int
    @objc public let botActive: Bool
    @objc public let assigneeName: String?
    @objc public let createdAt: Date?
    @objc public let dictionary: [String: Any]

    init(_ c: HSChatConversation) {
        conversationId = c.id
        status = c.status
        lastSeq = c.lastSeq
        agentLastReadSeq = c.agentLastReadSeq
        visitorLastReadSeq = c.visitorLastReadSeq
        unreadCount = c.unreadCount
        botActive = c.botActive
        assigneeName = c.assigneeName
        createdAt = c.createdAt
        dictionary = c.dictionary
    }
}

/// Konuşma (henüz yoksa nil) ve okunmamış sayısı.
@objc(PZChatConversationState)
public final class PZChatConversationState: NSObject {
    @objc public let conversation: PZChatConversation?
    @objc public let unreadCount: Int

    init(_ s: HSChatConversationState) {
        conversation = s.conversation.map(PZChatConversation.init)
        unreadCount = s.unreadCount
    }
}

@objc(PZChatMessagePage)
public final class PZChatMessagePage: NSObject {
    /// Kronolojik sırada.
    @objc public let messages: [PZChatMessage]
    @objc public let hasMore: Bool

    init(_ p: HSChatMessagePage) {
        messages = p.messages.map(PZChatMessage.init)
        hasMore = p.hasMore
    }
}

@objc(PZChatIdentifyResult)
public final class PZChatIdentifyResult: NSObject {
    @objc public let userId: String?
    @objc public let conversation: PZChatConversation?

    init(_ r: HSChatIdentifyResult) {
        userId = r.userId
        conversation = r.conversation.map(PZChatConversation.init)
    }
}

/// Sohbet ayarları ve çevrimiçi durumu.
@objc(PZChatConfig)
public final class PZChatConfig: NSObject {
    @objc public let enabled: Bool
    @objc public let online: Bool
    @objc public let withinBusinessHours: Bool
    @objc public let color: String?
    @objc public let textColor: String?
    @objc public let position: String
    @objc public let theme: String
    @objc public let title: String?
    @objc public let greeting: String?
    @objc public let offlineMessage: String?
    @objc public let collectEmailOffline: Bool
    @objc public let requireEmail: Bool
    @objc public let attachmentsEnabled: Bool
    @objc public let attachmentMaxBytes: Int
    @objc public let attachmentTypes: [String]
    @objc public let language: String
    @objc public let dictionary: [String: Any]

    init(_ c: HSChatConfig) {
        enabled = c.enabled
        online = c.online
        withinBusinessHours = c.withinBusinessHours
        color = c.color
        textColor = c.textColor
        position = c.position
        theme = c.theme
        title = c.title
        greeting = c.greeting
        offlineMessage = c.offlineMessage
        collectEmailOffline = c.collectEmailOffline
        requireEmail = c.requireEmail
        attachmentsEnabled = c.attachmentsEnabled
        attachmentMaxBytes = c.attachmentMaxBytes
        attachmentTypes = c.attachmentTypes
        language = c.language
        dictionary = c.dictionary
    }
}

/// Sohbet bildirimindeki işaret (`addOpenListener`).
@objc(PZChatPushInfo)
public final class PZChatPushInfo: NSObject {
    @objc public let conversationId: String
    @objc public let seq: Int

    init(_ i: HSChatPushInfo) {
        conversationId = i.conversationId
        seq = i.seq
    }
}

/**
 Sohbet olayı. `type`: `message` (message), `typing` (typing, name), `read` (seq), `unread` (unreadCount),
 `conversation` (conversationId, status, botActive), `connection` (connected), `error` (code, errorMessage).
 Türe ait olmayan alanlar nil/0/NO'dur; `payload` köprüler için aynı veriyi sözlük olarak taşır.
 */
@objc(PZChatEvent)
public final class PZChatEvent: NSObject {
    @objc public let type: String
    @objc public let payload: [String: Any]
    @objc public let message: PZChatMessage?
    @objc public let typing: Bool
    @objc public let name: String?
    @objc public let seq: Int
    @objc public let unreadCount: Int
    @objc public let conversationId: String?
    @objc public let status: String?
    @objc public let botActive: Bool
    @objc public let connected: Bool
    @objc public let code: String?
    @objc public let errorMessage: String?

    init(_ e: HSChatEvent) {
        type = e.type
        payload = e.payload
        var message: PZChatMessage?
        var typing = false, name: String?, seq = 0, unreadCount = 0
        var conversationId: String?, status: String?, botActive = false, connected = false
        var code: String?, errorMessage: String?
        switch e {
        case let .message(m): message = PZChatMessage(m)
        case let .typing(t, n): (typing, name) = (t, n)
        case let .agentRead(s): seq = s
        case let .unreadCount(c): unreadCount = c
        case let .conversationUpdated(id, s, bot): (conversationId, status, botActive) = (id, s, bot)
        case let .connection(c): connected = c
        case let .error(c, m): (code, errorMessage) = (c, m)
        }
        self.message = message
        self.typing = typing
        self.name = name
        self.seq = seq
        self.unreadCount = unreadCount
        self.conversationId = conversationId
        self.status = status
        self.botActive = botActive
        self.connected = connected
        self.code = code
        self.errorMessage = errorMessage
    }
}

/// Canlı sohbet (ADR-0040): `Pushizo.Chat` yüzeyinin tamamı ve hazır sohbet ekranı (`PZChatViewController`).
/// Completion block'ları ve dinleyiciler ana iş parçacığında çağrılır.
@objc(PZChat)
public final class PZChat: NSObject {
    // MARK: Durum

    /// Bu cihazın ziyaretçi kimliği (sohbet henüz kullanılmadıysa nil).
    @objc public static var visitorId: String? { Pushizo.Chat.visitorId }
    /// Son bilinen okunmamış sohbet mesajı sayısı.
    @objc public static var unreadCount: Int { Pushizo.Chat.unreadCount }
    /// Canlı dinleme açık mı.
    @objc public static var isListening: Bool { Pushizo.Chat.isListening }

    // MARK: Dinleyiciler

    @objc(addListener:)
    @discardableResult
    public static func addListener(_ listener: @escaping (PZChatEvent) -> Void) -> PZListenerToken {
        let token = Pushizo.Chat.addListener { listener(PZChatEvent($0)) }
        return PZListenerToken { Pushizo.Chat.removeListener(token) }
    }

    /// `[token remove]` ile aynı.
    @objc(removeListener:)
    public static func removeListener(_ token: PZListenerToken) { token.remove() }

    /// Sohbet bildirimine tıklama; dinleyici yokken gelen tıklama ilk dinleyiciye iletilir.
    @objc(addOpenListener:)
    @discardableResult
    public static func addOpenListener(_ listener: @escaping (PZChatPushInfo) -> Void) -> PZListenerToken {
        let token = Pushizo.Chat.addOpenListener { listener(PZChatPushInfo($0)) }
        return PZListenerToken { Pushizo.Chat.removeOpenListener(token) }
    }

    @objc(removeOpenListener:)
    public static func removeOpenListener(_ token: PZListenerToken) { token.remove() }

    // MARK: Kimlik ve okuma

    /// Sohbeti etkinleştirir ve ziyaretçiyi kullanıcıya/push aboneliğine bağlar.
    @objc(startWithName:email:language:completion:)
    public static func start(name: String?, email: String?, language: String?, completion: ((PZChatIdentifyResult?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) { PZChatIdentifyResult(try await Pushizo.Chat.start(name: name, email: email, language: language)) }
    }

    /// Ziyaretçi bilgisini (ad, e-posta, dil) günceller.
    @objc(identifyWithName:email:language:completion:)
    public static func identify(name: String?, email: String?, language: String?, completion: ((PZChatIdentifyResult?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) { PZChatIdentifyResult(try await Pushizo.Chat.identify(name: name, email: email, language: language)) }
    }

    @objc(getConfigWithLanguage:completion:)
    public static func getConfig(language: String?, completion: @escaping (PZChatConfig?, NSError?) -> Void) {
        complete(completion) { PZChatConfig(try await Pushizo.Chat.getConfig(language: language)) }
    }

    @objc(getConversationWithCompletion:)
    public static func getConversation(completion: @escaping (PZChatConversationState?, NSError?) -> Void) {
        complete(completion) { PZChatConversationState(try await Pushizo.Chat.getConversation()) }
    }

    /// `afterSeq` / `beforeSeq` nil olabilir (`NSNumber`); `limit` 1-100.
    @objc(getMessagesAfterSeq:beforeSeq:limit:completion:)
    public static func getMessages(afterSeq: NSNumber?, beforeSeq: NSNumber?, limit: Int, completion: @escaping (PZChatMessagePage?, NSError?) -> Void) {
        complete(completion) {
            PZChatMessagePage(try await Pushizo.Chat.getMessages(afterSeq: afterSeq?.intValue, beforeSeq: beforeSeq?.intValue, limit: limit))
        }
    }

    /// Okunmamış sayısını sunucudan yeniler (`NSNumber`).
    @objc(refreshUnreadCountWithCompletion:)
    public static func refreshUnreadCount(completion: ((NSNumber?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) { NSNumber(value: try await Pushizo.Chat.refreshUnreadCount()) }
    }

    // MARK: Gönderim

    /// Mesaj gönderir; `optionId` bot sorusunda seçilen hızlı yanıttır. Ağ yoksa `pending` yerel mesaj döner.
    @objc(sendMessage:optionId:completion:)
    public static func sendMessage(_ text: String, optionId: String?, completion: ((PZChatMessage?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) { PZChatMessage(try await Pushizo.Chat.sendMessage(text, optionId: optionId)) }
    }

    /// Ek gönderir (PNG/JPEG/WebP/GIF/PDF/düz metin, en çok 10 MB).
    @objc(sendAttachmentData:fileName:mimeType:text:completion:)
    public static func sendAttachment(_ data: Data, fileName: String, mimeType: String, text: String?, completion: ((PZChatMessage?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) {
            PZChatMessage(try await Pushizo.Chat.sendAttachment(data, fileName: fileName, mimeType: mimeType, text: text))
        }
    }

    /// Yerel dosya adresinden ek gönderir (ad dosya adından alınır).
    @objc(sendAttachmentFileURL:mimeType:text:completion:)
    public static func sendAttachment(fileURL: URL, mimeType: String, text: String?, completion: ((PZChatMessage?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) {
            PZChatMessage(try await Pushizo.Chat.sendAttachment(fileURL: fileURL, mimeType: mimeType, text: text))
        }
    }

    /// Çevrimdışıyken e-postayla mesaj bırakır.
    @objc(leaveOfflineMessageWithEmail:text:name:completion:)
    public static func leaveOfflineMessage(email: String, text: String, name: String?, completion: ((PZChatMessage?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) { PZChatMessage(try await Pushizo.Chat.leaveOfflineMessage(email: email, text: text, name: name)) }
    }

    /// `seq` numarasına kadar okundu işaretler; kalan okunmamış sayısı `NSNumber` olarak döner.
    @objc(markRead:completion:)
    public static func markRead(_ seq: Int, completion: ((NSNumber?, NSError?) -> Void)?) {
        complete(completion ?? { _, _ in }) { NSNumber(value: try await Pushizo.Chat.markRead(seq)) }
    }

    @objc public static func setTyping(_ typing: Bool) { Pushizo.Chat.setTyping(typing) }

    // MARK: Canlı akış ve ekler

    @objc public static func startListening() { Pushizo.Chat.startListening() }
    @objc public static func stopListening() { Pushizo.Chat.stopListening() }

    /// Ek dosyasının adresi (ziyaretçi belirtecini taşır; loglamayın). SDK başlatılmadıysa nil ve `error`.
    @objc(attachmentUrl:download:error:)
    public static func attachmentUrl(_ attachmentId: String, download: Bool) throws -> URL {
        do { return try Pushizo.Chat.attachmentUrl(attachmentId, download: download) } catch { throw PZErrors.bridge(error) }
    }

    // MARK: Hazır ekran

    /// Sohbet ekranını modal açar; `presenter` nil ise en üstteki görünüm denetleyicisi kullanılır.
    @objc(showFromViewController:animated:)
    public static func show(from presenter: UIViewController?, animated: Bool) { Pushizo.Chat.show(from: presenter, animated: animated) }

    @objc public static func show() { Pushizo.Chat.show() }

    @objc(hideAnimated:)
    public static func hide(animated: Bool) { Pushizo.Chat.hide(animated: animated) }

    @objc public static func hide() { Pushizo.Chat.hide() }

    @objc public static var isPresented: Bool { Pushizo.Chat.isPresented }
}

@objc(PZPlacements)
public final class PZPlacements: NSObject {
    /// Alanın içeriği; abonelik yoksa veya onay bekleniyorsa boş dizi. Anahtar `^[a-z][a-z0-9_.-]{0,63}$`, `limit` 1–10.
    @objc(listWithKey:limit:completion:)
    public static func list(key: String, limit: Int, completion: @escaping ([PZInAppMessage]?, NSError?) -> Void) {
        complete(completion) { try await Pushizo.Placements.list(key, limit: limit).map(PZInAppMessage.init) }
    }

    @objc public static func reportImpression(_ message: PZInAppMessage) { Pushizo.Placements.reportImpression(message.native) }

    @objc(reportClick:buttonId:)
    public static func reportClick(_ message: PZInAppMessage, buttonId: String) {
        Pushizo.Placements.reportClick(message.native, buttonId: buttonId)
    }

    @objc public static func reportDismiss(_ message: PZInAppMessage) { Pushizo.Placements.reportDismiss(message.native) }
}
