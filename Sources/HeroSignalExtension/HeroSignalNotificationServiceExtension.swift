import Foundation
// SPM: ayrı modül; CocoaPods alt spec'leri tek "HeroSignal" modülünde derlenir.
#if canImport(HeroSignalCore)
import HeroSignalCore
#endif
import UserNotifications

/**
 Notification Service Extension yardımcısı: zengin medya (resim) indirir, aksiyon kategorisini mevcut kategorileri
 silmeden kaydeder, rozet artışını (`hs.badge_inc`) App Group'taki sayaçla uygular ve `received` (confirmed delivery)
 bildirir. Kendi NSE sınıfınızdan çağırın:

 ```swift
 class NotificationService: UNNotificationServiceExtension {
   let hs = HeroSignalNotificationServiceExtension(appId: "app_…", apiUrl: "https://api.example.com", appGroup: "group.com.example.app")
   override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
     hs.didReceive(request, withContentHandler: handler)
   }
   override func serviceExtensionTimeWillExpire() { hs.serviceExtensionTimeWillExpire() }
 }
 ```
 App Group verilmezse Info.plist `HeroSignalAppGroup` anahtarı, o da yoksa `group.<uygulama bundle id>.herosignal` kullanılır
 (rozet sayacının uygulama ile paylaşılması için App Group yetkisi her iki hedefte de açık olmalıdır).
 */
public final class HeroSignalNotificationServiceExtension {
    private let api: HSApi
    private let storage: HSStorage
    private let badges: HSBadgeStore
    private let lock = NSLock()
    private var pendingHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    public init(appId: String, apiUrl: String, appGroup: String? = nil) {
        self.api = HSApi(apiUrl: apiUrl, appId: appId, sdkVersion: "0.1.0")
        self.storage = HSStorage(appId: appId, appGroup: appGroup)
        self.badges = HSBadgeStore(appGroup: HSAppGroup.resolve(appGroup))
    }

    public func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else { handler(request.content); return }
        lock.lock()
        pendingHandler = handler
        content = mutable
        lock.unlock()
        guard let n = HSNotification(userInfo: request.content.userInfo) else { finish(); return }

        if let id = n.deliveryId {
            let api = self.api
            let storage = self.storage
            Task {
                do { try await api.request("POST", "/deliveries/\(id)/received", body: [:]) }
                catch { storage.pendingReceived = Array((storage.pendingReceived + [id]).suffix(100)) }
            }
        }

        // Rozet: Increase → paylaşılan sayaç + artış; SetTo → sayaç sunucu değerine eşitlenir.
        if let badge = badges.apply(n) { mutable.badge = NSNumber(value: badge) }

        Task { [weak self] in
            guard let self else { return }
            await self.registerCategory(for: n, content: mutable)
            await self.attachImage(for: n, content: mutable)
            self.finish()
        }
    }

    public func serviceExtensionTimeWillExpire() { finish() }

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
