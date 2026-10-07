import Foundation
import UserNotifications

/// Dinleyici kaydı belirteci: Swift kapanışları karşılaştırılamadığından `remove…` çağrıları bu değerle yapılır.
public struct HSListenerToken: Hashable {
    let id: UUID

    init() { id = UUID() }
}

/**
 Belirteçli dinleyici listesi (tıklama, ön plan, izin gözlemcileri). İş parçacığı güvenlidir; bildirim sırasında
 liste kopyalanır, böylece dinleyici içinden ekleme/kaldırma güvenlidir.
 */
public final class HSListenerRegistry<Value> {
    private let lock = NSLock()
    private var entries: [(token: HSListenerToken, listener: (Value) -> Void)] = []

    public init() {}

    @discardableResult
    public func add(_ listener: @escaping (Value) -> Void) -> HSListenerToken {
        let token = HSListenerToken()
        lock.lock()
        entries.append((token, listener))
        lock.unlock()
        return token
    }

    /// Belirteçle kaydı kaldırır; kayıt bulunduysa true.
    @discardableResult
    public func remove(_ token: HSListenerToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.token == token }) else { return false }
        entries.remove(at: index)
        return true
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Tüm dinleyicileri eklenme sırasıyla çağırır.
    public func notify(_ value: Value) {
        lock.lock()
        let snapshot = entries.map { $0.listener }
        lock.unlock()
        snapshot.forEach { $0(value) }
    }
}

/**
 Bildirim izni takipçisi (eski sağlayıcı `addPermissionObserver` eşdeğeri): son bilinen etkin izin tutulur, `update`
 yalnızca değer değiştiğinde gözlemcileri çağırır. İlk ölçüm temel değerdir ve gözlemci tetiklemez.
 */
public final class HSPermissionTracker {
    public let observers = HSListenerRegistry<Bool>()
    private let lock = NSLock()
    private var last: Bool?

    public init() {}

    /// Son bilinen izin durumu; henüz ölçülmediyse nil.
    public var lastKnown: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// Güncel durumu kaydeder; önceki bilinen durumdan farklıysa gözlemcileri çağırır ve true döner.
    @discardableResult
    public func update(_ granted: Bool) -> Bool {
        lock.lock()
        let previous = last
        last = granted
        lock.unlock()
        guard let previous, previous != granted else { return false }
        observers.notify(granted)
        return true
    }

    /// Bildirim gösterilebilir mi: tam, geçici (provisional) veya App Clip (ephemeral) izni.
    public static func isGranted(_ status: UNAuthorizationStatus) -> Bool {
        if status == .authorized || status == .provisional { return true }
        #if os(iOS)
        // `.ephemeral` yalnızca iOS'ta tanımlı (macOS'ta `swift test` derlemesi için koşullu).
        if status == .ephemeral { return true }
        #endif
        return false
    }
}
