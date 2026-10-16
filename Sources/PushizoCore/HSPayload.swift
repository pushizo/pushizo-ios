import Foundation

/// Bildirim aksiyon düğmesi (`buttons`).
public struct HSAction: Equatable {
    public let id: String
    public let title: String
    public let url: String?
    public let icon: String?

    public init(id: String, title: String, url: String?, icon: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.icon = icon
    }
}

/// APNs payload'ından ayrıştırılan Pushizo bildirimi (`aps` + `hs` alanları).
public struct HSNotification: Equatable {
    public let title: String?
    public let body: String?
    public let imageUrl: String?
    public let url: String?
    public let deliveryId: String?
    public let messageId: String?
    public let actions: [HSAction]
    public let data: [String: String]
    /// `hs.badge_inc`: rozet artış miktarı (ios_badge_type=Increase); NSE uygular.
    public let badgeIncrement: Int?
    /// `aps.badge`: rozetin ayarlanacağı değer (SetTo).
    public let badgeSet: Int?

    /// `userInfo` sözlüğünden ayrıştırır; Pushizo dışı payload'larda nil döner.
    /// Yeni biçim `hs.dlv`/`hs.msg`/`hs.buttons`; eski `delivery_id`/`message_id`/`actions` alanlarına geri düşer.
    public init?(userInfo: [AnyHashable: Any]) {
        let aps = userInfo["aps"] as? [String: Any] ?? [:]
        let hs = userInfo["hs"] as? [String: Any]
        var title: String?
        var body: String?
        if let alert = aps["alert"] as? [String: Any] {
            title = alert["title"] as? String
            body = alert["body"] as? String
        } else if let text = aps["alert"] as? String {
            body = text
        }
        if hs == nil && title == nil && body == nil { return nil }
        self.title = title
        self.body = body
        self.imageUrl = HSNotification.string(hs?["image"])
        self.url = HSNotification.string(hs?["url"])
        self.deliveryId = HSNotification.string(hs?["dlv"]) ?? HSNotification.string(hs?["delivery_id"])
        self.messageId = HSNotification.string(hs?["msg"]) ?? (userInfo["hs_message_id"] as? String) ?? HSNotification.string(hs?["message_id"])
        let rawButtons = (hs?["buttons"] as? [[String: Any]]) ?? (hs?["actions"] as? [[String: Any]]) ?? []
        self.actions = rawButtons.compactMap { item in
            guard let id = HSNotification.string(item["id"]) else { return nil }
            return HSAction(id: id, title: HSNotification.string(item["title"]) ?? id, url: HSNotification.string(item["url"]), icon: HSNotification.string(item["icon"]))
        }
        self.badgeIncrement = (hs?["badge_inc"] as? NSNumber)?.intValue
        self.badgeSet = (aps["badge"] as? NSNumber)?.intValue
        var custom: [String: String] = [:]
        for (key, value) in userInfo {
            guard let k = key as? String, k != "aps", k != "hs", !k.hasPrefix("hs_"), let v = value as? String else { continue }
            custom[k] = v
        }
        self.data = custom
    }

    /// Tıklanan düğmenin URL'si; yoksa bildirim URL'si.
    public func url(forAction actionId: String?) -> String? {
        if let actionId, let action = actions.first(where: { $0.id == actionId }), let url = action.url { return url }
        return url
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}
