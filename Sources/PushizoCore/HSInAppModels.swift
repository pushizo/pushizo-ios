import Foundation

/// Trigger koşulundaki karşılaştırma değeri (sunucu: metin veya sayı).
public enum HSTriggerValue: Equatable {
    case string(String)
    case number(Double)
}

/// In-app mesaj tetik koşulu (`docs/messaging.md` §7).
public enum HSInAppTrigger: Equatable {
    /// Uygulama oturumu başladığında.
    case sessionStart
    /// `Session.sendEvent(name)` çağrıldığında.
    case event(String)
    /// `InAppMessages.setScreen(name)` ile bildirilen ekran.
    case screen(String)
    /// `InAppMessages.addTrigger(key, value)` değerleri; `op`: eq | neq | exists | gt | lt.
    case condition(key: String, op: String, value: HSTriggerValue?)
    /// Geçerli ön plan oturumu en az `seconds` saniye sürdüğünde (ADR-0019 §7); SDK süre dolunca yeniden değerlendirir.
    case sessionDuration(Int)
    /// Bu SDK sürümünün tanımadığı tetik türü: mesaj gösterilmez.
    case unsupported(String)
}

/// Düğme aksiyonu.
public enum HSInAppAction: Equatable {
    case dismiss
    /// http/https adresi; tarayıcıda açılır.
    case url(String)
    /// Uygulama şeması (ör. `myapp://cart`); uygulama içinde açılır.
    case deeplink(String)
    /// Kullanıcıya etiket yazar (`User.addTags`).
    case tags([String: String])
    /// Yerel bildirim izni istemini açar (`UNUserNotificationCenter.requestAuthorization`), ardından mesaj kapanır.
    case pushPrompt
    /// `Session.sendEvent(name, value:)` ile outcome olayı gönderir (dönüşüm atribüsyonu), ardından mesaj kapanır.
    case outcome(name: String, value: Double?)
}

public struct HSInAppButton: Equatable {
    public let id: String
    public let text: String
    public let action: HSInAppAction
    public let backgroundColor: String?
    public let textColor: String?
}

/// Carousel kartı; `button` geçersiz aksiyonlu ise nil (kart yine gösterilir).
public struct HSInAppCarouselCard: Equatable {
    public let id: String
    public let title: String
    public let body: String?
    public let imageUrl: String?
    public let imageAlt: String?
    public let button: HSInAppButton?
}

/// Yatay kaydırmalı kartlar (v2 Faz 18); kart düğmeleri `HSInAppDisplay.buttons` içinde yer alır.
public struct HSInAppCarousel: Equatable {
    public let id: String
    public let cards: [HSInAppCarouselCard]
}

/// Mesaj içerik bloğu; metinler sunucuda kullanıcının dilinde çözülmüş düz dizedir.
public enum HSInAppBlock: Equatable {
    case image(url: String, alt: String?)
    case title(String)
    case body(String)
    case button(HSInAppButton)
    case carousel(HSInAppCarousel)
}

/// Mesaj içeriğinin biçimi: yerel bloklar veya yalıtılmış WKWebView'da çizilen HTML (ADR-0027).
public enum HSInAppContentType: String, Equatable {
    case blocks
    case html
}

public enum HSInAppLayout: String, Equatable {
    case modal
    case bannerTop = "banner_top"
    case bannerBottom = "banner_bottom"
    case fullscreen
}

public struct HSInAppDisplay: Equatable {
    public let layout: HSInAppLayout
    public let backgroundColor: String?
    public let textColor: String?
    public let dismissible: Bool
    public let autoDismissSeconds: Int?
    public let blocks: [HSInAppBlock]
    /// `.html` ise `blocks` boştur ve içerik `html` alanındadır.
    public let contentType: HSInAppContentType
    /// Kullanıcının dilinde, kişiselleştirilmiş HTML (yalnızca HTML içerikte).
    public let html: String?
    /// Banner/modal için ilk yükseklik (CSS px ≙ pt); köprünün `resize` bildirimiyle güncellenir.
    public let htmlHeight: Int?

    /// Düğme blokları ve carousel kartlarının düğmeleri (tıklama bildirimi bu listeden çözülür).
    public var buttons: [HSInAppButton] {
        blocks.flatMap { block -> [HSInAppButton] in
            switch block {
            case let .button(b): return [b]
            case let .carousel(c): return c.cards.compactMap(\.button)
            default: return []
            }
        }
    }

    public var isHtml: Bool { contentType == .html }
}

/// Sunucunun cihaz için döndürdüğü gösterilebilir in-app mesaj. `triggerGroups` VEYA ile bağlı gruplardır (grup içi VE);
/// `triggers` ilk gruptur (geriye uyum).
public struct HSInAppMessage: Equatable {
    public let id: String
    public let priority: Int
    public let triggers: [HSInAppTrigger]
    public let triggerGroups: [[HSInAppTrigger]]
    /// Sunucunun seçtiği A/B görünüm varyantı; olay bildirimlerinde geri gönderilir.
    public let variantId: String?
    public let display: HSInAppDisplay
    public let remainingImpressions: Int
    public let minIntervalSeconds: Int
    /// true: tıklama/kapatma sonrası bu cihazda (liste yenilenmesini beklemeden) bir daha gösterilmez.
    public let stopAfterInteraction: Bool
    public let lastImpressionAt: Date?
    public let endAt: Date?
    /// Sunucudaki ham JSON (özel çizim katmanları, ör. Flutter köprüsü için).
    public let raw: NSDictionary
    /// Sunucunun içeriği çözdüğü dil (liste yanıtındaki `language`); HTML belgesinin `lang` özniteliği.
    public let language: String?
}

/// In-app mesaj tıklaması: `actionId` düğme kimliği; `url` url/deeplink aksiyonunun adresi.
public struct HSInAppClickEvent: Equatable {
    public let messageId: String
    public let actionId: String
    public let url: String?

    /// Üye başlatıcı modül dışına kapalıdır; `Pushizo` hedefi bu olayı kendisi kurar.
    public init(messageId: String, actionId: String, url: String?) {
        self.messageId = messageId
        self.actionId = actionId
        self.url = url
    }
}

/// `GET /in-app` yanıt ayrıştırıcı; bozuk mesaj atlanır, diğerleri kullanılır.
public enum HSInAppParser {
    public static func parseList(_ json: [String: Any]) -> [HSInAppMessage] {
        let language = nonEmpty(json["language"])
        return (json["data"] as? [[String: Any]] ?? []).compactMap { parseMessage($0, language: language) }
    }

    public static func parseMessage(_ item: [String: Any], language: String? = nil) -> HSInAppMessage? {
        guard let id = item["id"] as? String, let display = item["display"] as? [String: Any] else { return nil }
        let groups = parseTriggerGroups(item["trigger_groups"] as? [[[String: Any]]], triggers: item["triggers"] as? [[String: Any]] ?? [])
        // Alan yoksa veya tanınmıyorsa bloklar (eski sunucu uyumu); içeriksiz HTML mesajı atlanır.
        let contentType: HSInAppContentType = (display["content_type"] as? String) == "html" ? .html : .blocks
        let html = nonEmpty(display["html"])
        if contentType == .html, html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true { return nil }
        let htmlHeight = contentType == .html ? (display["html_height"] as? NSNumber).map(\.intValue).flatMap { $0 > 0 ? $0 : nil } : nil
        return HSInAppMessage(
            id: id,
            priority: (item["priority"] as? NSNumber)?.intValue ?? 0,
            triggers: groups[0],
            triggerGroups: groups,
            variantId: nonEmpty(item["variant_id"]),
            display: HSInAppDisplay(
                layout: HSInAppLayout(rawValue: display["layout"] as? String ?? "") ?? .modal,
                backgroundColor: nonEmpty(display["background_color"]),
                textColor: nonEmpty(display["text_color"]),
                dismissible: (display["dismissible"] as? Bool) ?? true,
                autoDismissSeconds: (display["auto_dismiss_seconds"] as? NSNumber).map(\.intValue).flatMap { $0 > 0 ? $0 : nil },
                blocks: contentType == .html ? [] : (display["blocks"] as? [[String: Any]] ?? []).compactMap(parseBlock),
                contentType: contentType,
                html: contentType == .html ? html : nil,
                htmlHeight: htmlHeight
            ),
            remainingImpressions: (item["remaining_impressions"] as? NSNumber)?.intValue ?? 1,
            minIntervalSeconds: (item["min_interval_seconds"] as? NSNumber)?.intValue ?? 0,
            stopAfterInteraction: item["stop_after_interaction"] as? Bool ?? false,
            lastImpressionAt: nonEmpty(item["last_impression_at"]).flatMap(HSIsoTime.parse),
            endAt: nonEmpty(item["end_at"]).flatMap(HSIsoTime.parse),
            raw: item as NSDictionary,
            language: language
        )
    }

    /// `trigger_groups` (VEYA grupları) yoksa veya boşsa `triggers` tek grup olur; sonuç her zaman en az bir grup içerir.
    public static func parseTriggerGroups(_ groups: [[[String: Any]]]?, triggers: [[String: Any]]) -> [[HSInAppTrigger]] {
        let parsed = (groups ?? []).map(parseTriggers)
        return parsed.isEmpty ? [parseTriggers(triggers)] : parsed
    }

    public static func parseTriggers(_ items: [[String: Any]]) -> [HSInAppTrigger] {
        items.map { t in
            let kind = t["kind"] as? String ?? ""
            switch kind {
            case "session_start": return .sessionStart
            case "session_duration":
                guard let seconds = (t["seconds"] as? NSNumber)?.intValue else { return .unsupported(kind) }
                return .sessionDuration(seconds)
            case "event": return (t["name"] as? String).map(HSInAppTrigger.event) ?? .unsupported(kind)
            case "screen": return (t["name"] as? String).map(HSInAppTrigger.screen) ?? .unsupported(kind)
            case "trigger":
                guard let key = t["key"] as? String, let op = t["op"] as? String else { return .unsupported(kind) }
                return .condition(key: key, op: op, value: triggerValue(t["value"]))
            default: return .unsupported(kind)
            }
        }
    }

    static func triggerValue(_ raw: Any?) -> HSTriggerValue? {
        if let s = raw as? String { return .string(s) }
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return .number(n.doubleValue) }
        return nil
    }

    private static func parseBlock(_ b: [String: Any]) -> HSInAppBlock? {
        switch b["type"] as? String {
        case "image":
            guard let url = nonEmpty(b["url"]) else { return nil }
            return .image(url: url, alt: nonEmpty(b["alt"]))
        case "title": return .title(b["text"] as? String ?? "")
        case "body": return .body(b["text"] as? String ?? "")
        case "button":
            guard let id = b["id"] as? String, let action = parseAction(b["action"] as? [String: Any]) else { return nil }
            return .button(HSInAppButton(id: id, text: b["text"] as? String ?? "", action: action,
                                         backgroundColor: nonEmpty(b["background_color"]), textColor: nonEmpty(b["text_color"])))
        case "carousel":
            return parseCarousel(b).map(HSInAppBlock.carousel)
        default:
            // Tanınmayan blok türü atlanır (ileri uyumluluk).
            return nil
        }
    }

    /// Kimliksiz veya kartsız carousel atlanır; kimliksiz kart atlanır, geçersiz kart düğmesi yalnızca düğmeyi düşürür.
    private static func parseCarousel(_ b: [String: Any]) -> HSInAppCarousel? {
        guard let id = nonEmpty(b["id"]), let items = b["cards"] as? [[String: Any]] else { return nil }
        let cards = items.compactMap { c -> HSInAppCarouselCard? in
            guard let cardId = nonEmpty(c["id"]) else { return nil }
            var button: HSInAppButton?
            if let btn = c["button"] as? [String: Any], let buttonId = nonEmpty(btn["id"]),
               let action = parseAction(btn["action"] as? [String: Any]) {
                button = HSInAppButton(id: buttonId, text: btn["text"] as? String ?? "", action: action, backgroundColor: nil, textColor: nil)
            }
            return HSInAppCarouselCard(id: cardId, title: c["title"] as? String ?? "", body: nonEmpty(c["body"]),
                                       imageUrl: nonEmpty(c["image_url"]), imageAlt: nonEmpty(c["image_alt"]), button: button)
        }
        return cards.isEmpty ? nil : HSInAppCarousel(id: id, cards: cards)
    }

    private static func parseAction(_ a: [String: Any]?) -> HSInAppAction? {
        guard let a else { return .dismiss }
        switch a["type"] as? String {
        case "url":
            guard let url = nonEmpty(a["url"]), url.hasPrefix("http://") || url.hasPrefix("https://") else { return nil }
            return .url(url)
        case "deeplink":
            return nonEmpty(a["url"]).map(HSInAppAction.deeplink)
        case "tags":
            let tags = (a["tags"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            return .tags(tags)
        case "push_prompt":
            return .pushPrompt
        case "outcome":
            // Adsız outcome düğmesi geçersizdir (atlanır); değer sayı değilse nil.
            guard let name = nonEmpty(a["name"]) else { return nil }
            let value = (a["value"] as? NSNumber).flatMap { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite ? $0.doubleValue : nil }
            return .outcome(name: name, value: value)
        default:
            return .dismiss
        }
    }

    static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}

/// ISO-8601 zaman ayrıştırıcı (kesirli saniye isteğe bağlı; `Z` veya `±hh:mm`).
public enum HSIsoTime {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(Z|[+-][0-9]{2}:?[0-9]{2})$"#
    )

    public static func parse(_ value: String) -> Date? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let range = NSRange(v.startIndex..<v.endIndex, in: v)
        guard let m = pattern.firstMatch(in: v, range: range), m.range == range else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: v) else { return nil }
            return String(v[r])
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = Int(group(1)!)
        components.month = Int(group(2)!)
        components.day = Int(group(3)!)
        components.hour = Int(group(4)!)
        components.minute = Int(group(5)!)
        components.second = Int(group(6)!)
        guard let base = components.date else { return nil }
        let millis = group(7).map { Double(String($0.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))! / 1000 } ?? 0
        let zone = group(8)!
        var offset = 0
        if zone != "Z" {
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            let minutes = Int(digits.prefix(2))! * 60 + Int(digits.suffix(2))!
            offset = zone.hasPrefix("-") ? -minutes : minutes
        }
        return base.addingTimeInterval(millis - Double(offset * 60))
    }
}
