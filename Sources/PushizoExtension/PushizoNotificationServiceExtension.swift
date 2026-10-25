import Foundation
// SPM: ayrı modül; CocoaPods alt spec'leri tek "Pushizo" modülünde derlenir. Çekirdek tipler yeniden dışa aktarılır:
// widget extension `import PushizoExtension` ile Live Activity tiplerine (`PushizoActivityData` vb.) erişir.
#if canImport(PushizoCore)
@_exported import PushizoCore
#endif
import UserNotifications

/**
 Notification Service Extension yardımcısı: zengin medya (resim) indirir, aksiyon kategorisini mevcut kategorileri
 silmeden kaydeder, rozet artışını (`hs.badge_inc`) App Group'taki sayaçla uygular ve `received` (confirmed delivery)
 bildirir. Kendi NSE sınıfınızdan çağırın:

 ```swift
 class NotificationService: UNNotificationServiceExtension {
   let hs = PushizoNotificationServiceExtension(appId: "app_…", apiUrl: "https://api.pushizo.com", appGroup: "group.com.pushizo.app")
   override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
     hs.didReceive(request, withContentHandler: handler)
   }
   override func serviceExtensionTimeWillExpire() { hs.serviceExtensionTimeWillExpire() }
 }
 ```
 App Group verilmezse Info.plist `PushizoAppGroup` anahtarı, o da yoksa `group.<uygulama bundle id>.pushizo` kullanılır
 (rozet sayacının uygulama ile paylaşılması için App Group yetkisi her iki hedefte de açık olmalıdır).

 Gizlilik onayı: uygulama `requiresPrivacyConsent` ve onay durumunu `appGroup` ile paylaşılan depolamaya yazar; NSE
 `received` göndermeden önce bunu okur. Onay yoksa ağ çağrısı yapılmaz, kayıt `pendingReceived` listesinde kalır ve
 onay verilince uygulama gönderir. App Group paylaşılmıyorsa `requiresPrivacyConsent: true` verin (NSE onayı göremediği
 için gönderim yapmaz).
 */
public final class PushizoNotificationServiceExtension {
    /// `received` isteği için en uzun bekleme (saniye); dolarsa kayıt `pendingReceived` listesinde kalır, uygulama gönderir.
    public static let receivedTimeout: TimeInterval = 5
    private let api: HSApi
    private let storage: HSStorage
    private let badges: HSBadgeStore
    private let requiresPrivacyConsent: Bool
    private let lock = NSLock()
    private var pendingHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    public init(appId: String, apiUrl: String, appGroup: String? = nil, requiresPrivacyConsent: Bool = false) {
        let storage = HSStorage(appId: appId, appGroup: appGroup)
        // Uygulamanın App Group'a yazdığı bölgesel API kökü (ADR-0032 §4) aynı başlangıç kökü için kullanılır.
        let api = HSApi(apiUrl: storage.resolvedApiUrl(seed: apiUrl), appId: appId, sdkVersion: "0.1.2")
        api.onApiUrlChange = { [weak storage] url in storage?.saveRegionalApi(seed: apiUrl, url: url) }
        // Uygulamanın App Group'a yazdığı kimlik JWT'si NSE isteklerinde de `Authorization` başlığıyla gider (ADR-0023 §9).
        api.identityToken = { [weak storage] in storage?.identityJwt }
        self.api = api
        self.storage = storage
        self.badges = HSBadgeStore(appGroup: HSAppGroup.resolve(appGroup))
        self.requiresPrivacyConsent = requiresPrivacyConsent
    }

    public func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        // `mutableCopy` sistemin `aps` alanlarından doldurduğu threadIdentifier (`thread-id`), relevanceScore
        // (`relevance-score`) ve targetContentIdentifier (`target-content-id`) değerlerini korur; NSE bunları değiştirmez.
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else { handler(request.content); return }
        lock.lock()
        pendingHandler = handler
        content = mutable
        lock.unlock()
        guard let n = HSNotification(userInfo: request.content.userInfo) else { finish(); return }

        // `received` önce kalıcı listeye yazılır: NSE süreci yanıt gelmeden sonlansa da kayıt kaybolmaz, uygulama gönderir.
        let deliveryId = n.deliveryId
        if let deliveryId { storage.addPendingReceived(deliveryId) }
        let sendReceived = deliveryId != nil && HSConsent.allowsNetwork(storage: storage, required: requiresPrivacyConsent)

        // Rozet: Increase → paylaşılan sayaç + artış; SetTo → sayaç sunucu değerine eşitlenir.
        if let badge = badges.apply(n) { mutable.badge = NSNumber(value: badge) }

        Task { [weak self] in
            guard let self else { return }
            // `received` (süre sınırıyla) ve içerik hazırlığı paralel yürür; içerik ikisi de bitince teslim edilir.
            await withTaskGroup(of: Void.self) { group in
                if sendReceived, let deliveryId {
                    group.addTask { await self.confirmReceived(deliveryId) }
                }
                group.addTask {
                    await self.registerCategory(for: n, content: mutable)
                    await self.attachImage(for: n, content: mutable)
                }
            }
            self.finish()
        }
    }

    public func serviceExtensionTimeWillExpire() { finish() }

    /// `received` gönderir; başarıda kayıt bekleyen listeden çıkarılır. Süre dolarsa istek iptal edilir, kayıt listede kalır.
    private func confirmReceived(_ deliveryId: String) async {
        let api = self.api
        let storage = self.storage
        await Self.withTimeout(Self.receivedTimeout) {
            do {
                try await api.request("POST", "/deliveries/\(deliveryId)/received", body: [:])
                storage.removePendingReceived(deliveryId)
            } catch {
                // Gönderilemedi: kayıt `pendingReceived` listesinde kalır, uygulama açılınca kuyruktan gönderilir.
            }
        }
    }

    /// İşlemi en fazla `seconds` saniye bekler; süre dolunca iptal eder (URLSession istekleri iptale hemen yanıt verir).
    private static func withTimeout(_ seconds: TimeInterval, _ operation: @escaping () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Düğmeli bildirimde dinamik kategori; düğmesizde kapatma geri bildirimi için varsayılan kategori.
    private func registerCategory(for n: HSNotification, content: UNMutableNotificationContent) async {
        if !n.actions.isEmpty {
            let identifier = HSCategories.identifier(for: n.actions)
            await HSCategories.register(HSCategories.category(identifier: identifier, actions: n.actions))
            content.categoryIdentifier = identifier
        } else if content.categoryIdentifier.isEmpty, n.deliveryId != nil {
            await HSCategories.register(HSCategories.category(identifier: HSCategories.defaultIdentifier, actions: []))
            content.categoryIdentifier = HSCategories.defaultIdentifier
        }
    }

    private func attachImage(for n: HSNotification, content: UNMutableNotificationContent) async {
        guard let imageUrl = n.imageUrl, let url = URL(string: imageUrl) else { return }
        do {
            let (location, response) = try await URLSession.shared.download(from: url)
            let ext = (response.suggestedFilename as NSString?)?.pathExtension.nilIfEmpty ?? url.pathExtension.nilIfEmpty ?? "jpg"
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("hs_\(UUID().uuidString).\(ext)")
            try FileManager.default.moveItem(at: location, to: target)
            let attachment = try UNNotificationAttachment(identifier: "hs_image", url: target)
            lock.lock()
            content.attachments = [attachment]
            lock.unlock()
        } catch {
            // Resim alınamazsa bildirim resimsiz gösterilir.
        }
    }

    private func finish() {
        lock.lock()
        let handler = pendingHandler
        let content = self.content
        pendingHandler = nil
        lock.unlock()
        guard let handler, let content else { return }
        handler(content)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
