import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/**
 Sunucunun uzaktan başlattığı (push-to-start) etkinliğin `attributes` içine eklediği HeroSignal verisi
 (`"herosignal": { "activity_id": "…" }`, ADR-0024). SDK etkinlik başlayınca güncelleme belirtecini bu kimlikle kaydeder;
 yerelde (`Activity.request`) başlatılan etkinliklerde kimliği geliştirici verir.
 */
public struct HeroSignalActivityData: Codable, Hashable {
    public let activityId: String

    public init(activityId: String) {
        self.activityId = activityId
    }

    enum CodingKeys: String, CodingKey {
        case activityId = "activity_id"
    }
}

/**
 HeroSignal ile izlenecek `ActivityAttributes` tiplerinin uyduğu protokol. Alan adı `herosignal` olmalıdır (sunucu
 start payload'ındaki anahtar); yerel başlatmada `HeroSignalActivityData(activityId:)` verilir, uzaktan başlatmada sunucu
 doldurur.

 ```swift
 struct DeliveryAttributes: ActivityAttributes, HeroSignalLiveActivityAttributes {
     struct ContentState: Codable, Hashable { var status: String; var eta: Int }
     var orderNo: String
     var herosignal: HeroSignalActivityData?
 }
 ```
 */
public protocol HeroSignalLiveActivityAttributes {
    var herosignal: HeroSignalActivityData? { get }
}

/// Live Activity alan değeri: metin, sayı veya mantıksal değer (sunucu şemasındaki ilkel türler).
public enum HeroSignalLiveActivityValue: Codable, Hashable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Sıra önemlidir: JSON `true` sayı olarak, `1` mantıksal değer olarak çözülmez.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// Tam sayıya kayıpsız çevrilebilen sayı; değilse nil.
    public var intValue: Int? {
        guard case let .number(value) = self, value.rounded() == value, abs(value) < 9.0e15 else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// Görüntülenecek metin: tam sayılar ondalıksız (`3`), diğer sayılar olduğu gibi (`2.5`).
    public var description: String {
        switch self {
        case let .string(value): return value
        case let .bool(value): return value ? "true" : "false"
        case let .number(value): return intValue.map(String.init) ?? String(value)
        }
    }

    /**
     Köprülerden gelen değeri çevirir: `String`, `Bool` ve sonlu sayılar kabul edilir; iç içe nesne, dizi, `NSNull` ve
     NaN/sonsuz reddedilir (nil).
     */
    public init?(any value: Any) {
        if let text = value as? String {
            self = .string(text)
            return
        }
        guard let number = value as? NSNumber else { return nil }
        // `NSNumber(1)` Swift'te `Bool`'a da dönüşür; mantıksal değer CF tür kimliğinden ayırt edilir.
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
            return
        }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        self = .number(double)
    }

    /// Alan anahtarı kuralı (sunucu: en çok 64 karakter).
    public static let maxKeyLength = 64
    /// Metin değeri üst sınırı (sunucu: 4000 karakter).
    public static let maxStringLength = 4000

    /**
     `[String: Any]` sözlüğünü doğrulayıp çevirir. `nil` girdi boş sözlüktür; sözlük olmayan girdi, 1-64 karakter dışı
     anahtar, 4000 karakteri aşan metin veya ilkel olmayan değer varsa nil döner.
     */
    public static func dictionary(from raw: Any?) -> [String: HeroSignalLiveActivityValue]? {
        guard let raw, !(raw is NSNull) else { return [:] }
        guard let map = raw as? [String: Any] else { return nil }
        var out: [String: HeroSignalLiveActivityValue] = [:]
        for (key, item) in map {
            guard (1...maxKeyLength).contains(key.count), let value = HeroSignalLiveActivityValue(any: item) else { return nil }
            if case let .string(text) = value, text.count > maxStringLength { return nil }
            out[key] = value
        }
        return out
    }
}

/// Düz JSON nesnesinin her anahtarı için dinamik kodlama anahtarı.
struct HSDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private enum HSFlatValues {
    /// Düz nesnedeki ilkel değerler; `excluding` anahtarları ve ilkel olmayan/null değerler atlanır.
    static func decode(from decoder: Decoder, excluding: Set<String> = []) throws -> [String: HeroSignalLiveActivityValue] {
        let container = try decoder.container(keyedBy: HSDynamicCodingKey.self)
        var out: [String: HeroSignalLiveActivityValue] = [:]
        for key in container.allKeys where !excluding.contains(key.stringValue) {
            if let value = try? container.decode(HeroSignalLiveActivityValue.self, forKey: key) { out[key.stringValue] = value }
        }
        return out
    }

    static func encode(_ values: [String: HeroSignalLiveActivityValue], to container: inout KeyedEncodingContainer<HSDynamicCodingKey>) throws {
        for (key, value) in values {
            try container.encode(value, forKey: HSDynamicCodingKey(key))
        }
    }
}

/**
 Genel amaçlı Live Activity türü: çapraz platform köprüleri (Flutter, React Native, Capacitor, Cordova, MAUI, Unity)
 tip-güvenli `ActivityAttributes` oluşturamadığından bu tür kullanılır. Sunucuda tür adı
 `HeroSignalDefaultLiveActivityAttributes` olarak tanımlanır; `attributes` ve `content_state` alanları düz nesnedir ve
 değerleri `data` sözlüğünden okunur (`context.attributes.data["title"]`, `context.state.data["status"]`).
 */
public struct HeroSignalDefaultLiveActivityAttributes: HeroSignalLiveActivityAttributes, Codable {
    /// Dashboard/API'de tanımlanacak tür adı (Swift tip adı).
    public static let activityType = "HeroSignalDefaultLiveActivityAttributes"

    /// İçerik durumu: sunucunun `content_state` nesnesindeki tüm ilkel alanlar.
    public struct ContentState: Codable, Hashable {
        public var data: [String: HeroSignalLiveActivityValue]

        public init(data: [String: HeroSignalLiveActivityValue] = [:]) {
            self.data = data
        }

        public init(from decoder: Decoder) throws {
            data = try HSFlatValues.decode(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: HSDynamicCodingKey.self)
            try HSFlatValues.encode(data, to: &container)
        }
    }

    /// Etkinlik boyunca değişmeyen alanlar (`herosignal` hariç).
    public var data: [String: HeroSignalLiveActivityValue]
    public var herosignal: HeroSignalActivityData?

    public init(data: [String: HeroSignalLiveActivityValue] = [:], herosignal: HeroSignalActivityData? = nil) {
        self.data = data
        self.herosignal = herosignal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: HSDynamicCodingKey.self)
        // Bozuk `herosignal` alanı etkinliği düşürmez; kimlik `Activity.id`'ye döner.
        herosignal = (try? container.decodeIfPresent(HeroSignalActivityData.self, forKey: HSDynamicCodingKey("herosignal"))) ?? nil
        data = try HSFlatValues.decode(from: decoder, excluding: ["herosignal"])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: HSDynamicCodingKey.self)
        try HSFlatValues.encode(data, to: &container)
        try container.encodeIfPresent(herosignal, forKey: HSDynamicCodingKey("herosignal"))
    }
}

#if canImport(ActivityKit) && os(iOS)
@available(iOS 16.1, *)
extension HeroSignalDefaultLiveActivityAttributes: ActivityAttributes {}
#endif

/// Live Activity belirteci türü (`POST /live-activities/tokens` `kind`).
public enum HSLiveActivityTokenKind: String {
    /// Türün uzaktan başlatma belirteci (iOS 17.2+); abonelik × tür başına tek kayıt.
    case pushToStart = "push_to_start"
    /// Çalışan etkinliğin güncelleme belirteci; `activity_id` ile kaydedilir.
    case update
}

/// Live Activities hataları; `code` köprülerin ortak hata kodudur.
public enum HSLiveActivityError: Error, Equatable {
    /// iOS 16.1 öncesi, ActivityKit'siz platform (Android/web köprülerinde aynı kod).
    case notSupported(String)
    /// `HeroSignal.initialize` çağrılmadı.
    case notInitialized
    case invalidArgument(String)
    /// Sistem etkinliği başlatamadı (Live Activities kapalı, `NSSupportsLiveActivities` yok, üst sınır aşıldı vb.).
    case requestFailed(String)

    public var code: String {
        switch self {
        case .notSupported: return "PLATFORM_NOT_SUPPORTED"
        case .notInitialized: return "NOT_READY"
        case .invalidArgument: return "INVALID_ARGUMENT"
        case .requestFailed: return "LIVE_ACTIVITY_FAILED"
        }
    }

    public var message: String {
        switch self {
        case let .notSupported(message), let .invalidArgument(message), let .requestFailed(message): return message
        case .notInitialized: return "HeroSignal.initialize çağrılmadı"
        }
    }
}

/**
 Live Activity belirteç kaydının ActivityKit'ten bağımsız kısmı (birim testli): belirteç onaltılığa çevrilir, kalıcı
 kuyruğa yazılacak işlem ve `POST /sdk/v1/apps/{appId}/live-activities/tokens[/delete]` gövdesi (sahiplik kanıtıyla) üretilir.
 */
public enum HSLiveActivities {
    public static let tokenOperationType = "live_activity_token"
    public static let deleteOperationType = "live_activity_token_delete"
    public static let tokensPath = "/live-activities/tokens"
    public static let deleteTokensPath = "/live-activities/tokens/delete"

    /// APNs belirteci (Data) → küçük harf onaltılık.
    public static func hexToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Tür adı: Swift tip adı kuralı (harf/alt çizgiyle başlar; harf, rakam, alt çizgi; en çok 100). Sunucuyla aynı.
    public static func isValidActivityType(_ name: String) -> Bool {
        name.count <= 100 && name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// Etkinlik kimliği: 1-100 karakter; harf, rakam ve `_ . : -` (sunucudaki start kuralı; `Activity.id` UUID'si de uyar).
    public static func isValidActivityId(_ id: String) -> Bool {
        id.count <= 100 && id.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil
    }

    /// Onaltılık APNs belirteci (sunucu: 32-200 karakter).
    public static func isValidToken(_ token: String) -> Bool {
        token.count <= 200 && token.range(of: "^[0-9a-fA-F]{32,}$", options: .regularExpression) != nil
    }

    /// Belirteç kaydı kuyruk işlemi (`update` türünde `activityId` zorunlu, `push_to_start`'ta yok sayılır).
    public static func tokenOperation(activityType: String, kind: HSLiveActivityTokenKind, activityId: String?, token: String, at: TimeInterval = Date().timeIntervalSince1970) -> [String: Any] {
        var op: [String: Any] = ["type": tokenOperationType, "activity_type": activityType, "kind": kind.rawValue, "token": token, "at": at]
        if kind == .update, let activityId { op["activity_id"] = activityId }
        return op
    }

    /// Belirteç silme kuyruk işlemi (etkinlik bitti/kapatıldı).
    public static func deleteOperation(activityType: String, kind: HSLiveActivityTokenKind, activityId: String?, at: TimeInterval = Date().timeIntervalSince1970) -> [String: Any] {
        var op: [String: Any] = ["type": deleteOperationType, "activity_type": activityType, "kind": kind.rawValue, "at": at]
        if kind == .update, let activityId { op["activity_id"] = activityId }
        return op
    }

    /**
     Kuyruk işleminden istek yolu ve gövdesi. Gövdeye push aboneliği kimliği ve sahiplik kanıtı (kayıtlı push token'ının
     SHA-256 özeti `token_hash`, kimlikli kullanıcıda `identity_hash`) eklenir; JWT `HSApi` tarafından başlıkta gönderilir.
     Geçersiz işlemde (bilinmeyen tür, `update`'te eksik `activity_id`, bozuk belirteç) nil.
     */
    public static func request(for op: [String: Any], subscriptionId: String, registeredToken: String?, identityHash: String?) -> (path: String, body: [String: Any])? {
        guard let type = op["type"] as? String,
              let activityType = op["activity_type"] as? String, isValidActivityType(activityType),
              let kind = (op["kind"] as? String).flatMap(HSLiveActivityTokenKind.init(rawValue:)) else { return nil }
        var body: [String: Any] = ["subscription_id": subscriptionId, "activity_type": activityType, "kind": kind.rawValue]
        if kind == .update {
            guard let activityId = op["activity_id"] as? String, isValidActivityId(activityId) else { return nil }
            body["activity_id"] = activityId
        }
        body = HSOwnership.withProof(body, registeredToken: registeredToken, identityHash: identityHash)
        switch type {
        case tokenOperationType:
            guard let token = op["token"] as? String, isValidToken(token) else { return nil }
            body["token"] = token.lowercased()
            return (tokensPath, body)
        case deleteOperationType:
            return (deleteTokensPath, body)
        default:
            return nil
        }
    }
}
