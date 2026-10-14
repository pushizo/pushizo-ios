import Foundation

/**
 Oturum penceresi: uygulama arka planda en az `backgroundTimeout` (30 sn) kalırsa oturum biter; daha kısa arka plan
 geçişleri aynı oturumu sürdürür. Durum UserDefaults'ta kalıcıdır; arka plandayken süreç sonlansa da önceki oturumun
 sonu bir sonraki ön plana geçişte üretilir. Süre (`duration_seconds`, `usage_seconds`) yalnızca ön planda geçen zamandır.
 */
public final class HSSessionTracker {
    /// Oturumun bitmesi için gereken kesintisiz arka plan süresi (saniye).
    public static let backgroundTimeout: TimeInterval = 30

    public enum Transition: Equatable {
        case start
        case end(durationSeconds: Int)
    }

    private let defaults: UserDefaults
    private let prefix: String
    private let lock = NSLock()
    /// Bu süreçte ön plana geçiş görüldü mü; önceki süreçten arka plan kaydı olmadan kalan oturumu ayırt etmek için.
    private var foregroundSeenInProcess = false

    public init(defaults: UserDefaults, appId: String) {
        self.defaults = defaults
        self.prefix = "hs.session.\(appId)."
    }

    private func date(_ name: String) -> Date? {
        (defaults.object(forKey: prefix + name) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    private func setDate(_ value: Date?, _ name: String) {
        defaults.set(value.map { NSNumber(value: $0.timeIntervalSince1970) }, forKey: prefix + name)
    }

    /// Son ön plana geçiş anı; arka planda nil.
    private var resumedAt: Date? {
        get { date("resumed_at") }
        set { setDate(newValue, "resumed_at") }
    }

    /// Arka plana geçiş anı; ön planda nil.
    private var backgroundAt: Date? {
        get { date("background_at") }
        set { setDate(newValue, "background_at") }
    }

    /// Önceki ön plan aralıklarında biriken süre (saniye).
    private var activeSeconds: Double {
        get { defaults.double(forKey: prefix + "active_seconds") }
        set { defaults.set(newValue, forKey: prefix + "active_seconds") }
    }

    /// Açık (ön planda veya pencere dolmamış arka planda) oturum var mı.
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return resumedAt != nil || backgroundAt != nil
    }

    /// Ön plana geçiş; üretilen geçişler sırasıyla döner (önceki oturumun sonu, ardından yeni oturumun başı).
    public func enterForeground(at now: Date) -> [Transition] {
        lock.lock(); defer { lock.unlock() }
        var transitions: [Transition] = []
        if let background = backgroundAt {
            if now.timeIntervalSince(background) < HSSessionTracker.backgroundTimeout {
                // Kısa arka plan: aynı oturum sürer.
                backgroundAt = nil
                resumedAt = now
                foregroundSeenInProcess = true
                return []
            }
            transitions.append(.end(durationSeconds: Int(activeSeconds)))
        } else if resumedAt != nil {
            // Arka plana geçmeden yeniden etkinleşme (ör. Denetim Merkezi, sistem uyarısı): oturum sürer.
            if foregroundSeenInProcess { return [] }
            // Önceki süreç ön plandayken sonlandı (çökme vb.): son aralığın süresi bilinmez, bilinen süreyle kapatılır.
            transitions.append(.end(durationSeconds: Int(activeSeconds)))
        }
        backgroundAt = nil
        resumedAt = now
        activeSeconds = 0
        foregroundSeenInProcess = true
        transitions.append(.start)
        return transitions
    }

    /// Arka plana geçiş: ön plan süresi biriktirilir ve geçiş anı kalıcı olarak yazılır.
    public func enterBackground(at now: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let resumed = resumedAt else { return }
        activeSeconds += max(0, now.timeIntervalSince(resumed))
        resumedAt = nil
        backgroundAt = now
    }

    /// Arka plan penceresi dolduysa oturumu kapatır (uygulama arka planda çalışmayı sürdürürse zamanlayıcıyla çağrılır).
    public func expire(at now: Date) -> Transition? {
        lock.lock(); defer { lock.unlock() }
        guard let background = backgroundAt, now.timeIntervalSince(background) >= HSSessionTracker.backgroundTimeout else { return nil }
        let duration = Int(activeSeconds)
        backgroundAt = nil
        resumedAt = nil
        activeSeconds = 0
        return .end(durationSeconds: duration)
    }
}
