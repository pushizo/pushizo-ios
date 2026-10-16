import Foundation

/**
 SDK iç hatalarını `POST /sdk/v1/apps/{appId}/errors` uç noktasına toplu ve en iyi çabayla bildirir.
 - Oturum başına en fazla `maxPerSession` rapor; aynı kod+mesaj bir kez gönderilir.
 - Ağ/çevrimdışı hataları raporlanmaz; rapor gönderimi hatası yeniden raporlanmaz (özyineleme yok).
 - Mesajda yalnızca SDK'nın kendi metni ve hata türü/HTTP kodu bulunur; ham hata metni (PII içerebilir) gönderilmez,
   token benzeri uzun diziler maskelenir.
 */
public final class HSErrorReporter {
    public static let maxBatch = 20
    private let platform: String
    private let sdkVersion: String
    private let maxPerSession: Int
    private let lock = NSLock()
    private var pending: [[String: Any]] = []
    private var seen = Set<String>()
    private var accepted = 0

    public init(platform: String = "ios", sdkVersion: String, maxPerSession: Int = 20) {
        self.platform = platform
        self.sdkVersion = sdkVersion
        self.maxPerSession = maxPerSession
    }

    public static func isNetworkError(_ error: Error) -> Bool {
        if let api = error as? HSApiError { return api.status == 0 }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// Token/anahtar benzeri uzun dizileri maskeler.
    public static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "[A-Za-z0-9_\\-+/=:]{32,}", with: "[redacted]", options: .regularExpression)
    }

    private static func describe(_ error: Error) -> String {
        if let api = error as? HSApiError { return "HTTP \(api.status) \(api.code)" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    /// - Returns: Kayıt kuyruğa alındıysa true.
    @discardableResult
    public func record(code: String, message: String, error: Error? = nil, subscriptionId: String? = nil, context: [String: Any] = [:], level: String = "error") -> Bool {
        if let error, HSErrorReporter.isNetworkError(error) { return false }
        let raw = error.map { "\(message): \(HSErrorReporter.describe($0))" } ?? message
        let text = String(HSErrorReporter.sanitize(raw).prefix(2000))
        guard !text.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard accepted < maxPerSession, seen.insert("\(code)|\(text)").inserted else { return false }
        accepted += 1
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var item: [String: Any] = [
            "level": level == "warning" ? "warning" : "error",
            "platform": platform,
            "sdk_version": sdkVersion,
            "code": String(code.prefix(100)),
            "message": text,
            "occurred_at": formatter.string(from: Date()),
        ]
        if let subscriptionId { item["subscription_id"] = subscriptionId }
        if !context.isEmpty {
            var ctx: [String: Any] = [:]
            for (k, v) in context { ctx[String(k.prefix(64))] = (v as? String).map { String(HSErrorReporter.sanitize($0).prefix(256)) } ?? v }
            if JSONSerialization.isValidJSONObject(ctx), let data = try? JSONSerialization.data(withJSONObject: ctx), data.count <= 4096 { item["context"] = ctx }
        }
        pending.append(item)
        return true
    }

    /// Sıradaki toplu gövde (en fazla 20 kayıt); bekleyen yoksa nil.
    public func drain() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let batch = Array(pending.prefix(HSErrorReporter.maxBatch))
        pending.removeFirst(batch.count)
        return ["errors": batch]
    }

    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
}
