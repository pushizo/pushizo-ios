import Foundation
#if canImport(PushizoCore)
import PushizoCore
#endif
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

extension Pushizo {
    /**
     iOS Live Activities (ADR-0024). SDK, kaydedilen `ActivityAttributes` türlerinin push-to-start belirtecini (iOS 17.2+)
     ve başlayan her etkinliğin güncelleme belirtecini sunucuya kaydeder; etkinlik bitince (`ended`/`dismissed`) belirteç
     silinir. Belirteçler kalıcı kuyruğa yazılır: push aboneliği henüz yoksa kuyrukta bekler, gizlilik onayı ve ağ
     hatalarında diğer işlemler gibi yeniden denenir.

     ```swift
     // initialize'dan sonra, uygulama her açıldığında:
     if #available(iOS 16.1, *) { Pushizo.LiveActivities.register(DeliveryAttributes.self) }
     ```

     Tür adı Swift tip adıdır (`String(describing: T.self)`) ve dashboard/API'de aynı adla tanımlanmalıdır.

     Mac Catalyst: Live Activities Mac'te gösterilmez. `register`/`startTracking` derlenir ama etkisizdir (uyarı yazılır);
     `setupDefaultLiveActivity`/`startDefaultLiveActivity` `HSLiveActivityError.notSupported` (`PLATFORM_NOT_SUPPORTED`) fırlatır.
     */
    public enum LiveActivities {
        /// Çapraz platform köprülerinin kullandığı genel tür adı (sunucuda bu adla tanımlanır).
        public static var defaultActivityType: String { PushizoDefaultLiveActivityAttributes.activityType }

        /// Mac Catalyst'te `PLATFORM_NOT_SUPPORTED` hatasının mesajı.
        static let catalystUnsupportedMessage = "Live Activities Mac Catalyst'te desteklenmez"

        #if canImport(ActivityKit) && os(iOS)
        /**
         Türü izlemeye alır: push-to-start belirteci (iOS 17.2+) kaydedilir; zaten çalışan ve sonradan başlayan (uzaktan
         veya yerel) her etkinliğin güncelleme belirteci `attributes.pushizo?.activityId ?? activity.id` kimliğiyle
         kaydedilir. Aynı tür için tekrar çağrı etkisizdir. `Pushizo.initialize`'dan sonra çağrılmalıdır.
         */
        @available(iOS 16.1, *)
        public static func register<T: ActivityAttributes & PushizoLiveActivityAttributes>(_ type: T.Type) {
            guard isInitialized else {
                HSLog.log(.error, "LiveActivities.register: önce Pushizo.initialize çağrılmalı")
                return
            }
            #if targetEnvironment(macCatalyst)
            HSLog.log(.warn, "\(catalystUnsupportedMessage); LiveActivities.register etkisiz")
            #else
            HSLiveActivityTracker.shared.register(type)
            #endif
        }

        /**
         `PushizoLiveActivityAttributes`'a uymayan bir türün yerelde (`Activity.request`) başlatılan etkinliğini verilen
         kimlikle izler. Protokole uyan türlerde gerekmez: `pushizo: PushizoActivityData(activityId:)` ile başlatılan
         etkinlik `register` tarafından bu kimlikle izlenir. Etkinlik zaten izleniyorsa çağrı etkisizdir.
         */
        @available(iOS 16.1, *)
        public static func startTracking<T: ActivityAttributes>(activity: Activity<T>, activityId: String) {
            guard isInitialized else {
                HSLog.log(.error, "LiveActivities.startTracking: önce Pushizo.initialize çağrılmalı")
                return
            }
            guard HSLiveActivities.isValidActivityId(activityId) else {
                HSLog.log(.error, "geçersiz activityId: 1-100 karakter; harf, rakam ve _ . : -")
                return
            }
            #if targetEnvironment(macCatalyst)
            HSLog.log(.warn, "\(catalystUnsupportedMessage); LiveActivities.startTracking etkisiz")
            #else
            HSLiveActivityTracker.shared.track(activity, activityType: String(describing: T.self), activityId: activityId)
            #endif
        }
        #endif

        /**
         Genel türü (`PushizoDefaultLiveActivityAttributes`) `register` eder; köprüler `setupDefaultLiveActivity()` ile
         çağırır. iOS 16.1 öncesinde `HSLiveActivityError.notSupported`, başlatılmamış SDK'da `.notInitialized` fırlatır.
         Widget extension'da `ActivityConfiguration(for: PushizoDefaultLiveActivityAttributes.self)` tanımlanmalıdır.
         Mac Catalyst'te her zaman `.notSupported` (`PLATFORM_NOT_SUPPORTED`).
         */
        public static func setupDefaultLiveActivity() throws {
            guard isInitialized else { throw HSLiveActivityError.notInitialized }
            #if targetEnvironment(macCatalyst)
            throw HSLiveActivityError.notSupported(catalystUnsupportedMessage)
            #else
            #if canImport(ActivityKit) && os(iOS)
            if #available(iOS 16.1, *) {
                HSLiveActivityTracker.shared.register(PushizoDefaultLiveActivityAttributes.self)
                return
            }
            #endif
            throw HSLiveActivityError.notSupported("Live Activities iOS 16.1 veya üstünü gerektirir")
            #endif
        }

        /**
         Genel türle yerel bir etkinlik başlatır (iOS 16.1+) ve güncelleme belirtecini `activityId` ile kaydeder; sunucu
         sonraki `update`/`end` çağrılarını bu kimlikle yapar. `attributes` ve `contentState` değerleri metin, sayı veya
         mantıksal değerdir (anahtar 1-64 karakter; `attributes` içinde `pushizo` anahtarı ayrılmıştır).
         Hata: `.invalidArgument`, `.notSupported`, `.notInitialized`, `.requestFailed` (Live Activities kapalı vb.).
         */
        public static func startDefaultLiveActivity(activityId: String, attributes: [String: Any], contentState: [String: Any]) throws {
            guard isInitialized else { throw HSLiveActivityError.notInitialized }
            guard HSLiveActivities.isValidActivityId(activityId) else {
                throw HSLiveActivityError.invalidArgument("activityId 1-100 karakter olmalı (harf, rakam ve _ . : -)")
            }
            guard attributes["pushizo"] == nil else {
                throw HSLiveActivityError.invalidArgument("attributes içinde 'pushizo' anahtarı ayrılmıştır")
            }
            guard let attributeValues = PushizoLiveActivityValue.dictionary(from: attributes),
                  let stateValues = PushizoLiveActivityValue.dictionary(from: contentState) else {
                throw HSLiveActivityError.invalidArgument("attributes/contentState değerleri metin, sayı veya mantıksal olmalı (anahtar 1-64 karakter)")
            }
            #if targetEnvironment(macCatalyst)
            _ = (attributeValues, stateValues)
            throw HSLiveActivityError.notSupported(catalystUnsupportedMessage)
            #else
            #if canImport(ActivityKit) && os(iOS)
            if #available(iOS 16.1, *) {
                try HSLiveActivityTracker.shared.startDefault(activityId: activityId, attributes: attributeValues, contentState: stateValues)
                return
            }
            #endif
            throw HSLiveActivityError.notSupported("Live Activities iOS 16.1 veya üstünü gerektirir")
            #endif
        }
    }
}

// Mac Catalyst'te ActivityKit derlenebilse de etkinlikler gösterilmez: izleyici yalnızca iOS/iPadOS'ta derlenir.
#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
/**
 ActivityKit akışlarını dinler ve belirteç işlemlerini kalıcı kuyruğa yazar. Aynı belirteç (tür × tür/etkinlik anahtarı)
 süreç ömrü boyunca bir kez gönderilir; her etkinlik `Activity.id` başına tek görevle izlenir.
 */
@available(iOS 16.1, *)
final class HSLiveActivityTracker {
    static let shared = HSLiveActivityTracker()

    private let lock = NSLock()
    private var registeredTypes: Set<String> = []
    /// İzlenen etkinlikler (`Activity.id`).
    private var trackedActivities: Set<String> = []
    /// Son gönderilen belirteç (anahtar: tür + tür/etkinlik).
    private var sentTokens: [String: String] = [:]

    func register<T: ActivityAttributes & PushizoLiveActivityAttributes>(_ type: T.Type) {
        let activityType = String(describing: T.self)
        guard HSLiveActivities.isValidActivityType(activityType) else {
            HSLog.log(.error, "Live Activity türü adı geçersiz: \(activityType) (harf, rakam, alt çizgi)")
            return
        }
        lock.lock()
        let inserted = registeredTypes.insert(activityType).inserted
        lock.unlock()
        guard inserted else { return }

        if #available(iOS 17.2, *) {
            if let token = Activity<T>.pushToStartToken {
                enqueueToken(activityType: activityType, kind: .pushToStart, activityId: nil, token: token)
            }
            Task {
                for await token in Activity<T>.pushToStartTokenUpdates {
                    self.enqueueToken(activityType: activityType, kind: .pushToStart, activityId: nil, token: token)
                }
            }
        }
        for activity in Activity<T>.activities {
            track(activity, activityType: activityType, activityId: Self.activityId(of: activity))
        }
        // Uzaktan (push-to-start) ve yerelde başlayan yeni etkinlikler.
        Task {
            for await activity in Activity<T>.activityUpdates {
                self.track(activity, activityType: activityType, activityId: Self.activityId(of: activity))
            }
        }
    }

    /// Sunucunun verdiği kimlik (`attributes.pushizo.activity_id`); yoksa sistemin etkinlik kimliği.
    static func activityId<T: ActivityAttributes & PushizoLiveActivityAttributes>(of activity: Activity<T>) -> String {
        if let id = activity.attributes.pushizo?.activityId, HSLiveActivities.isValidActivityId(id) { return id }
        return activity.id
    }

    func track<T: ActivityAttributes>(_ activity: Activity<T>, activityType: String, activityId: String) {
        lock.lock()
        let inserted = trackedActivities.insert(activity.id).inserted
        lock.unlock()
        guard inserted else { return }
        Task { await self.observe(activity, activityType: activityType, activityId: activityId) }
    }

    private func observe<T: ActivityAttributes>(_ activity: Activity<T>, activityType: String, activityId: String) async {
        var finished = Self.isFinished(activity.activityState)
        if !finished {
            if let token = activity.pushToken {
                enqueueToken(activityType: activityType, kind: .update, activityId: activityId, token: token)
            }
            let tokenUpdates = Task {
                for await token in activity.pushTokenUpdates {
                    self.enqueueToken(activityType: activityType, kind: .update, activityId: activityId, token: token)
                }
            }
            for await state in activity.activityStateUpdates where Self.isFinished(state) {
                finished = true
                break
            }
            tokenUpdates.cancel()
        }
        let key = Self.tokenKey(activityType: activityType, kind: .update, activityId: activityId)
        lock.lock()
        trackedActivities.remove(activity.id)
        let hadToken = sentTokens.removeValue(forKey: key) != nil
        lock.unlock()
        // Etkinlik bitti veya kapatıldı: güncelleme belirteci artık geçersizdir.
        if finished, hadToken || activity.pushToken != nil {
            Pushizo.enqueue(HSLiveActivities.deleteOperation(activityType: activityType, kind: .update, activityId: activityId))
        }
    }

    func startDefault(activityId: String, attributes: [String: PushizoLiveActivityValue], contentState: [String: PushizoLiveActivityValue]) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw HSLiveActivityError.requestFailed("Live Activities bu cihazda kapalı (Ayarlar veya NSSupportsLiveActivities)")
        }
        let activityAttributes = PushizoDefaultLiveActivityAttributes(data: attributes, pushizo: PushizoActivityData(activityId: activityId))
        let state = PushizoDefaultLiveActivityAttributes.ContentState(data: contentState)
        let activity: Activity<PushizoDefaultLiveActivityAttributes>
        do {
            if #available(iOS 16.2, *) {
                activity = try Activity.request(attributes: activityAttributes, content: ActivityContent(state: state, staleDate: nil), pushType: .token)
            } else {
                activity = try Activity.request(attributes: activityAttributes, contentState: state, pushType: .token)
            }
        } catch {
            throw HSLiveActivityError.requestFailed("Live Activity başlatılamadı: \(error.localizedDescription)")
        }
        track(activity, activityType: PushizoDefaultLiveActivityAttributes.activityType, activityId: activityId)
    }

    private func enqueueToken(activityType: String, kind: HSLiveActivityTokenKind, activityId: String?, token: Data) {
        let hex = HSLiveActivities.hexToken(token)
        guard HSLiveActivities.isValidToken(hex) else { return }
        let key = Self.tokenKey(activityType: activityType, kind: kind, activityId: activityId)
        lock.lock()
        let duplicate = sentTokens[key] == hex
        if !duplicate { sentTokens[key] = hex }
        lock.unlock()
        guard !duplicate else { return }
        Pushizo.enqueue(HSLiveActivities.tokenOperation(activityType: activityType, kind: kind, activityId: activityId, token: hex))
    }

    static func tokenKey(activityType: String, kind: HSLiveActivityTokenKind, activityId: String?) -> String {
        "\(activityType)|\(kind.rawValue)|\(activityId ?? "")"
    }

    static func isFinished(_ state: ActivityState) -> Bool {
        state == .ended || state == .dismissed
    }
}
#endif
