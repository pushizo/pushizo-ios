import Foundation

/// Kalıcı işlem kuyruğu (UserDefaults); ardışık tag yamaları birleştirilir.
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

    /// Sırayla işler; ardışık olaylar tek `event_batch` işlemi olarak gönderilir. Geçici hatada durur (false); 4xx'te atılır.
    /// - Parameter onRejected: Kalıcı olarak reddedilip atılan işlem (SDK hata raporu için).
    public func flush(_ handler: ([String: Any]) async throws -> Void, onRejected: (([String: Any], Error) -> Void)? = nil) async -> Bool {
        while let head = items.first {
            let events = HSQueue.leadingEvents(items)
            let unit: [String: Any] = events.count > 1 ? ["type": "event_batch", "events": events, "at": head["at"] ?? 0] : head
            let consumed = events.count > 1 ? events.count : 1
            do {
                try await handler(unit)
            } catch let error as HSApiError where error.isRetryable {
                return false
            } catch {
                // kalıcı hata: atla
                onRejected?(unit, error)
            }
            lock.lock(); items = Array(items.dropFirst(consumed)); lock.unlock()
        }
        return true
    }

    public func clear() { items = [] }

    public static func mergeTail(_ queue: [[String: Any]]) -> [[String: Any]] {
        guard queue.count >= 2 else { return queue }
        let last = queue[queue.count - 1]
        let prev = queue[queue.count - 2]
        guard last["type"] as? String == "tags", prev["type"] as? String == "tags",
              var merged = prev["tags"] as? [String: Any], let lastTags = last["tags"] as? [String: Any] else { return queue }
        for (k, v) in lastTags { merged[k] = v }
        var result = Array(queue.dropLast(2))
        result.append(["type": "tags", "tags": merged, "at": last["at"] ?? Date().timeIntervalSince1970])
        return result
    }
}
