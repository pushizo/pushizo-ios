import Foundation

/// Değerlendirmeyi başlatan durum: anlık (oturum başı, olay) veya durum değişimi (ekran, trigger).
public enum HSInAppCause: Equatable {
    case sessionStart
    case event(String)
    case screen(String)
    case triggerChange(Set<String>)
}

/// Değerlendirme anındaki durum: geçerli ekran ve `addTrigger` değerleri.
public struct HSInAppState: Equatable {
    public var screen: String?
    public var triggers: [String: String]
    public init(screen: String? = nil, triggers: [String: String] = [:]) {
        self.screen = screen
        self.triggers = triggers
    }
}

/// Son listeden bu yana yereldeki gösterimler ve etkileşim (tıklama/kapatma); sunucu bir sonraki yenilemede günceller.
public struct HSLocalImpressions: Equatable {
    public var count: Int
    public var lastAt: Date?
    public var interacted: Bool
    public init(count: Int = 0, lastAt: Date? = nil, interacted: Bool = false) {
        self.count = count
        self.lastAt = lastAt
        self.interacted = interacted
    }
}

/**
 In-app tetik ve sıklık kuralları (Android `HsInAppRules` ile aynı; ortak vektörler `sdk/testdata/messaging-vectors.json`).

 - Mesaj yalnızca tetiklerinden birini "ateşleyen" değerlendirmede adaydır: oturum başı → `session_start`, olay → aynı
   adlı `event`, ekran → yeni ekranla eşleşen `screen`, trigger değişimi → değişen anahtarlı `trigger`. Tetiksiz mesaj
   oturum başında adaydır.
 - Aday mesajın tüm koşulları sağlanmalıdır: `session_start` oturum boyunca; `event` yalnızca o olay anında; `screen`
   geçerli ekran; `trigger` karşılaştırması. Tanınmayan tür hiç sağlanmaz.
 - Karşılaştırma: iki taraf da düz ondalık sayıysa sayısal, değilse metin (büyük/küçük harf duyarlı). `neq` anahtar
   yoksa sağlanır; `gt`/`lt` sayısal olmayan değerde sağlanmaz.
 */
public enum HSInAppRules {
    private static let decimal = try! NSRegularExpression(pattern: #"^-?[0-9]+(\.[0-9]+)?$"#)

    public static func matches(_ triggers: [HSInAppTrigger], cause: HSInAppCause, state: HSInAppState) -> Bool {
        if triggers.isEmpty { return cause == .sessionStart }
        guard triggers.contains(where: { fires($0, cause, state) }) else { return false }
        return triggers.allSatisfy { holds($0, cause, state) }
    }

    private static func fires(_ t: HSInAppTrigger, _ cause: HSInAppCause, _ state: HSInAppState) -> Bool {
        switch (t, cause) {
        case (.sessionStart, .sessionStart): return true
        case let (.event(name), .event(fired)): return name == fired
        case let (.screen(name), .screen(fired)): return name == fired && state.screen == name
        case let (.condition(key, _, _), .triggerChange(keys)): return keys.contains(key)
        default: return false
        }
    }

    private static func holds(_ t: HSInAppTrigger, _ cause: HSInAppCause, _ state: HSInAppState) -> Bool {
        switch t {
        case .sessionStart: return true
        case let .event(name): return cause == .event(name)
        case let .screen(name): return state.screen == name
        case let .condition(key, op, value): return conditionHolds(key: key, op: op, value: value, triggers: state.triggers)
        case .unsupported: return false
        }
    }

    public static func conditionHolds(key: String, op: String, value: HSTriggerValue?, triggers: [String: String]) -> Bool {
        let actual = triggers[key]
        switch op {
        case "exists":
            return actual != nil
        case "eq":
            guard let actual, let value else { return false }
            return looseEquals(actual, value)
        case "neq":
            guard let actual, let value else { return true }
            return !looseEquals(actual, value)
        case "gt", "lt":
            guard let a = actual.flatMap(number), let e = value.flatMap(numberOf) else { return false }
            return op == "gt" ? a > e : a < e
        default:
            return false
        }
    }

    private static func looseEquals(_ actual: String, _ expected: HSTriggerValue) -> Bool {
        if let a = number(actual), let e = numberOf(expected) { return a == e }
        if case let .string(s) = expected { return actual == s }
        return false
    }

    private static func numberOf(_ value: HSTriggerValue) -> Double? {
        switch value {
        case let .number(n): return n.isFinite ? n : nil
        case let .string(s): return number(s)
        }
    }

    /// Yalnızca düz ondalık gösterim sayı kabul edilir (platformlar arası tutarlılık için).
    public static func number(_ value: String) -> Double? {
        let v = value.trimmingCharacters(in: .whitespaces)
        return HSContacts.fullMatch(decimal, v) ? Double(v) : nil
    }

    /// Sıklık ve geçerlilik: bitiş zamanı, kalan gösterim hakkı ve iki gösterim arası süre.
    public static func canDisplay(_ m: HSInAppMessage, local: HSLocalImpressions, now: Date) -> Bool {
        // Etkileşim sonrası durdurma: yerel tıklama/kapatma, sunucu listesi henüz güncellenmemiş olsa da uygulanır.
        if m.stopAfterInteraction && local.interacted { return false }
        if let end = m.endAt, now >= end { return false }
        if m.remainingImpressions - local.count <= 0 { return false }
        let last = [m.lastImpressionAt, local.lastAt].compactMap { $0 }.max()
        if m.minIntervalSeconds > 0, let last, now.timeIntervalSince(last) < Double(m.minIntervalSeconds) { return false }
        return true
    }

    /// Eşleşen ve gösterilebilir mesajlar arasından en yüksek öncelikli (eşitlikte liste sırası).
    public static func select(_ messages: [HSInAppMessage], cause: HSInAppCause, state: HSInAppState,
                              locals: [String: HSLocalImpressions], now: Date) -> HSInAppMessage? {
        var best: HSInAppMessage?
        for m in messages {
            guard matches(m.triggers, cause: cause, state: state),
                  canDisplay(m, local: locals[m.id] ?? HSLocalImpressions(), now: now) else { continue }
            if best == nil || m.priority > best!.priority { best = m }
        }
        return best
    }
}

/// In-app renk kuralları (ARGB, `0xAARRGGBB`).
public enum HSInAppStyle {
    public static let lightBackground: UInt32 = 0xFFFF_FFFF
    public static let lightText: UInt32 = 0xFF18_181B
    public static let darkBackground: UInt32 = 0xFF18_181B
    public static let darkText: UInt32 = 0xFFFA_FAFA
    public static let lightButton: UInt32 = 0xFF25_63EB
    public static let darkButton: UInt32 = 0xFF3B_82F6
    private static let hex = try! NSRegularExpression(pattern: "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")

    /// CSS biçimli renk: `#RGB`, `#RRGGBB`, `#RRGGBBAA` (alfa sonda) → ARGB; geçersizse nil.
    public static func parseColor(_ value: String?) -> UInt32? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), HSContacts.fullMatch(hex, v) else { return nil }
        var digits = String(v.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard let rgb = UInt32(digits.prefix(6), radix: 16) else { return nil }
        let alpha = digits.count == 8 ? UInt32(digits.suffix(2), radix: 16) ?? 0xFF : 0xFF
        return (alpha << 24) | rgb
    }

    /// Arka plana okunur metin rengi (YIQ parlaklığı ≥ 150 → koyu metin).
    public static func contrastingText(_ background: UInt32) -> UInt32 {
        let r = (background >> 16) & 0xFF, g = (background >> 8) & 0xFF, b = background & 0xFF
        let yiq = (r * 299 + g * 587 + b * 114) / 1000
        return yiq >= 150 ? lightText : darkText
    }

    public static func format(_ color: UInt32) -> String { String(format: "#%08X", color) }
}
