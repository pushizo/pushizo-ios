import Foundation

/**
 Bildirim merkezi seçimi (`HeroSignal.Notifications.removeNotification/removeGroupedNotifications`).
 Yalnızca HeroSignal bildirimleri (payload'ı `HSNotification` olarak ayrıştırılabilen) seçilir; uygulamanın
 kendi bildirimleri etkilenmez. Saf mantıktır, `UNUserNotificationCenter` çağrısı uygulama hedefindedir.
 */
public enum HSNotificationTray {
    /// Teslim edilmiş bir bildirimin seçim için gereken özeti.
    public struct Entry: Equatable {
        public let identifier: String
        public let threadIdentifier: String
        public let deliveryId: String?
        public let fromHeroSignal: Bool

        public init(identifier: String, threadIdentifier: String, deliveryId: String?, fromHeroSignal: Bool) {
            self.identifier = identifier
            self.threadIdentifier = threadIdentifier
            self.deliveryId = deliveryId
            self.fromHeroSignal = fromHeroSignal
        }

        /// `UNNotificationRequest` alanlarından özet üretir.
        public init(identifier: String, threadIdentifier: String, userInfo: [AnyHashable: Any]) {
            let n = HSNotification(userInfo: userInfo)
            self.init(identifier: identifier, threadIdentifier: threadIdentifier, deliveryId: n?.deliveryId, fromHeroSignal: n != nil)
        }
    }

    /// Kimlik, istek kimliği (`apns-id`/`apns-collapse-id`) veya HeroSignal teslimat kimliği (`hs.dlv`) ile eşleşenler.
    public static func identifiers(matching id: String, in entries: [Entry]) -> [String] {
        guard !id.isEmpty else { return [] }
        return entries.filter { $0.fromHeroSignal && ($0.identifier == id || $0.deliveryId == id) }.map(\.identifier)
    }

    /// `aps.thread-id` grubu eşleşenler.
    public static func identifiers(inGroup group: String, in entries: [Entry]) -> [String] {
        guard !group.isEmpty else { return [] }
        return entries.filter { $0.fromHeroSignal && $0.threadIdentifier == group }.map(\.identifier)
    }
}
