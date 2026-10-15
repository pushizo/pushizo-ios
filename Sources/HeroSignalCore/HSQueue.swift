import Foundation

/**
 İşlem henüz gönderilemez (ör. abonelik/kullanıcı kimliği yok): kuyrukta yerinde kalır, sonraki işlemler engellenmeden
 işlenir ve bir sonraki `flush` çağrısında yeniden denenir.
 */
public struct HSQueueDeferred: Error, Equatable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/**
 Kalıcı işlem kuyruğu (UserDefaults); ardışık tag yamaları birleştirilir. UserDefaults yalnızca property list değerleri
 saklar (`NSNull` saklanamaz): silinecek tag anahtarları `tags` içinde değil `remove` listesinde tutulur ve istek
 gövdesi `tagsBody(_:)` ile kurulurken `null`'a çevrilir.
 */
public final class HSQueue {
    public static let maxSize = 500
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults, appId: String) {
        self.defaults = defaults
        self.key = "hs.queue.\(appId)"
    }

    public var items: [[String: Any]] {
        get { (defaults.array(forKey: key) as? [[String: Any]]) ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }

    public var count: Int { items.count }

    public func enqueue(_ op: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var queue = items
        queue.append(op)
        items = Array(HSQueue.mergeTail(queue).suffix(HSQueue.maxSize))
    }

    /// Tek istekte gönderilen en fazla olay (SDK API sınırı).
    public static let eventBatchMax = 100

    /// Kuyruğun başındaki ardışık `event` işlemleri.
    public static func leadingEvents(_ queue: [[String: Any]]) -> [[String: Any]] {
        var run: [[String: Any]] = []
        for op in queue {
            guard op["type"] as? String == "event", run.count < eventBatchMax else { break }
            run.append(op)
        }
        return run
    }

    /**
     Sırayla işler; ardışık olaylar tek `event_batch` işlemi olarak gönderilir. Geçici hatada durur (false); 4xx'te atılır.
     `HSQueueDeferred` fırlatan işlem kuyrukta yerinde bırakılır ve sonrakilerle devam edilir (ertelenen varsa false).
     - Parameter onRejected: Kalıcı olarak reddedilip atılan işlem (SDK hata raporu için).
     */
    public func flush(_ handler: ([String: Any]) async throws -> Void, onRejected: (([String: Any], Error) -> Void)? = nil) async -> Bool {
        // Kuyruğun başında bırakılan (ertelenen) işlem sayısı; işlenecek sıradaki işlem bu konumdadır.
        var deferred = 0
        while true {
            let pending = Array(items.dropFirst(deferred))
            guard let head = pending.first else { break }
            let events = HSQueue.leadingEvents(pending)
            let unit: [String: Any] = events.count > 1 ? ["type": "event_batch", "events": events, "at": head["at"] ?? 0] : head
            let consumed = events.count > 1 ? events.count : 1
            do {
                try await handler(unit)
            } catch is HSQueueDeferred {
                deferred += consumed
                continue
            } catch let error as HSApiError where error.isRetryable {
                return false
            } catch {
                // kalıcı hata: atla
                onRejected?(unit, error)
            }
            lock.lock()
            var current = items
            let end = min(deferred + consumed, current.count)
            if deferred < end { current.removeSubrange(deferred..<end) }
            items = current
            lock.unlock()
        }
        return deferred == 0
    }

    public func clear() { items = [] }

    public static func mergeTail(_ queue: [[String: Any]]) -> [[String: Any]] {
        guard queue.count >= 2 else { return queue }
        let last = queue[queue.count - 1]
        let prev = queue[queue.count - 2]
        guard last["type"] as? String == "tags", prev["type"] as? String == "tags",
              var merged = prev["tags"] as? [String: Any], let lastTags = last["tags"] as? [String: Any] else { return queue }
        var removed = Set(prev["remove"] as? [String] ?? [])
        // Sonraki işlem kazanır: yeni değer önceki silmeyi, yeni silme önceki değeri geçersiz kılar.
        for (k, v) in lastTags {
            merged[k] = v
            removed.remove(k)
        }
        for k in last["remove"] as? [String] ?? [] {
            merged.removeValue(forKey: k)
            removed.insert(k)
        }
        var op: [String: Any] = ["type": "tags", "tags": merged, "at": last["at"] ?? Date().timeIntervalSince1970]
        if !removed.isEmpty { op["remove"] = removed.sorted() }
        var result = Array(queue.dropLast(2))
        result.append(op)
        return result
    }

    /// Kuyruktaki tag işleminden API gövdesi: `remove` anahtarları `null` (sunucuda tag silme) olur.
    public static func tagsBody(_ op: [String: Any]) -> [String: Any] {
        var tags = op["tags"] as? [String: Any] ?? [:]
        for k in op["remove"] as? [String] ?? [] { tags[k] = NSNull() }
        return tags
    }
}
