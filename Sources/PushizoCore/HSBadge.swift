import Foundation
import UserNotifications

/// Uygulama ile Notification Service Extension arasında paylaşılan App Group çözümü.
public enum HSAppGroup {
    /// Info.plist anahtarı: uygulama ve NSE Info.plist'lerine aynı değer yazılır (ör. "group.com.example.app.pushizo").
    public static let infoPlistKey = "PushizoAppGroup"

    /**
     Öncelik: açık parametre → Info.plist `PushizoAppGroup` → kural gereği `group.<uygulama bundle id>.pushizo`.
     NSE içinde uygulama bundle id'si, extension bundle id'sinin son bileşeni atılarak bulunur.
     */
    public static func resolve(_ explicit: String?, bundle: Bundle = .main) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        if let fromPlist = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String, !fromPlist.isEmpty { return fromPlist }
        guard var bundleId = bundle.bundleIdentifier else { return nil }
        if bundle.bundleURL.pathExtension == "appex", let dot = bundleId.lastIndex(of: ".") {
            bundleId = String(bundleId[..<dot])
        }
        return "group.\(bundleId).pushizo"
    }
}

/**
 Rozet sayacı (App Group UserDefaults): NSE `badge_inc` geldiğinde artırır, `aps.badge` (SetTo) geldiğinde ayarlar;
 uygulama rozeti değiştirdiğinde/temizlediğinde eşitlenir. App Group yetkisi yoksa yalnızca süreç içinde tutarlıdır.
 */
public final class HSBadgeStore {
    public static let key = "hs.badge_count"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(appGroup: String?) {
        self.defaults = appGroup.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var count: Int {
        get { max(0, defaults.integer(forKey: HSBadgeStore.key)) }
        set { defaults.set(max(0, newValue), forKey: HSBadgeStore.key) }
    }

    /// Bildirimin rozet etkisini uygular; yeni rozet değerini (değişiklik yoksa nil) döndürür.
    @discardableResult
    public func apply(_ notification: HSNotification) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if let set = notification.badgeSet {
            count = set
            return count
        }
        if let inc = notification.badgeIncrement {
            count = count + inc
            return count
        }
        return nil
    }
}

/// Dinamik bildirim kategorileri (aksiyon düğmeleri).
public enum HSCategories {
    /// Düğmesiz Pushizo bildirimlerinin kategorisi (yalnızca kapatma geri bildirimi için).
    public static let defaultIdentifier = "hs_default"

    /// Düğme kimliklerinden kararlı kategori kimliği.
    public static func identifier(for actions: [HSAction]) -> String {
        String("hs_\(actions.map(\.id).joined(separator: "_"))".prefix(60))
    }

    /// Kapatma (`UNNotificationDismissActionIdentifier`) geri bildirimi için `.customDismissAction` ile kategori.
    public static func category(identifier: String, actions: [HSAction]) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: identifier,
            actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground]) },
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// Mevcut kategorilerle birleştirir; aynı kimlikli kategori yenisiyle değiştirilir, diğerleri korunur.
    public static func merge(_ existing: Set<UNNotificationCategory>, adding category: UNNotificationCategory) -> Set<UNNotificationCategory> {
        var result = existing.filter { $0.identifier != category.identifier }
        result.insert(category)
        return result
    }

    /// Kategoriyi sistemdeki kayıtlı kategorileri silmeden ekler (getNotificationCategories → birleşim → set).
    public static func register(_ category: UNNotificationCategory, center: UNUserNotificationCenter = .current()) async {
        let existing = await center.notificationCategories()
        if existing.contains(where: { $0.identifier == category.identifier && $0 == category }) { return }
        center.setNotificationCategories(merge(existing, adding: category))
    }
}
