import Foundation
// SPM: ayrı modül; CocoaPods alt spec'leri tek "Pushizo" modülünde derlenir.
#if canImport(PushizoCore)
import PushizoCore
#endif
import UIKit
import WebKit

/// In-app yaşam döngüsü dinleyicisi; tüm metotlar isteğe bağlıdır (varsayılan gövdeler boştur). Ana iş parçacığında çağrılır.
public protocol HSInAppLifecycleListener: AnyObject {
    func onWillDisplay(_ message: HSInAppMessage)
    func onDidDisplay(_ message: HSInAppMessage)
    func onWillDismiss(_ message: HSInAppMessage)
    func onDidDismiss(_ message: HSInAppMessage)
}

public extension HSInAppLifecycleListener {
    func onWillDisplay(_ message: HSInAppMessage) {}
    func onDidDisplay(_ message: HSInAppMessage) {}
    func onWillDismiss(_ message: HSInAppMessage) {}
    func onDidDismiss(_ message: HSInAppMessage) {}
}

/// In-app mesajı çizen katman. Varsayılan: UIWindow üstünde UIKit görünümü ([HSInAppWindowRenderer]).
/// Özel çizim (ör. Flutter köprüsü) `Pushizo.InAppMessages.setRenderer` ile kaydedilir. Ana iş parçacığında çağrılır.
/// HTML içerikli mesajlar (`display.isHtml`) özel çizime verilmez: yalıtım ve köprü doğrulaması (ADR-0027) yalnızca
/// varsayılan çizimin WKWebView'ında uygulandığından her zaman varsayılan çizimle gösterilir.
public protocol HSInAppRenderer: AnyObject {
    /// Mesajı gösterir; etkileşimler `handle` ile bildirilir. false → gösterilemedi (mesaj atlanır).
    func show(_ message: HSInAppMessage, handle: HSInAppHandle) -> Bool
    /// SDK mesajın kapatılmasını ister (düğme aksiyonu sonrası). Kapanınca `handle.closed()` çağrılmalıdır.
    func close(messageId: String)
}

/// Gösterilen mesajın etkileşim kanalı. Çizim katmanı: görünür olunca `displayed()`, düğmede `buttonClicked(_:)`,
/// kullanıcı/otomatik kapatmada `dismissed()`, görünüm tamamen kalkınca `closed()` çağırır. Tekrarlar yok sayılır.
public final class HSInAppHandle {
    public let message: HSInAppMessage
    private weak var controller: HSInAppController?
    private var impressionSent = false
    private var interacted = false
    private var closing = false
    private var finished = false
    /// Döngüdeki bir HTML betiği kuyruğu doldurmasın: tek gösterimde en fazla `maxHtmlSideEffects` tag/olay.
    private var sideEffects = 0
    private static let maxHtmlSideEffects = 50

    init(controller: HSInAppController, message: HSInAppMessage) {
        self.controller = controller
        self.message = message
    }

    public func displayed() {
        onMain { [self] in
            guard !impressionSent else { return }
            impressionSent = true
            controller?.onDisplayed(self)
        }
    }

    public func buttonClicked(_ buttonId: String) {
        onMain { [self] in
            guard !finished, !interacted, let button = message.display.buttons.first(where: { $0.id == buttonId }) else { return }
            interacted = true
            controller?.onButtonClicked(self, button: button)
        }
    }

    public func dismissed() {
        onMain { [self] in
            guard !finished, !interacted else { return }
            interacted = true
            controller?.onDismissed(self)
        }
    }

    public func closed() {
        onMain { [self] in
            guard !finished else { return }
            finished = true
            controller?.onClosed(self)
        }
    }

    /// HTML köprüsü `click(actionId, url)`: tıklama olayı (`button_id` = actionId), dinleyiciler, adres açma, kapanış.
    func htmlClicked(_ actionId: String, url: String?) {
        onMain { [self] in
            guard !finished, !interacted else { return }
            interacted = true
            controller?.onHtmlClicked(self, actionId: actionId, url: url)
        }
    }

    /// HTML köprüsü `addTag`; mesaj açık kalır.
    func htmlAddTag(_ key: String, value: String) {
        onMain { [self] in
            guard !finished, allowSideEffect() else { return }
            Pushizo.User.addTags([key: value])
        }
    }

    /// HTML köprüsü `trackEvent`; mesaj açık kalır.
    func htmlTrackEvent(_ name: String, properties: [String: HSBridgeValue]) {
        onMain { [self] in
            guard !finished, allowSideEffect() else { return }
            Pushizo.Session.sendEvent(name, properties: properties.mapValues(\.foundationValue))
        }
    }

    private func allowSideEffect() -> Bool {
        sideEffects += 1
        if sideEffects <= Self.maxHtmlSideEffects { return true }
        HSLog.log(.warn, "HTML in-app köprüsü: gösterim başına tag/olay sınırı aşıldı, istek yok sayıldı")
        return false
    }

    /// willDismiss bir kez; kapatma isteği çizim katmanına iletilir.
    func requestClose() -> Bool {
        guard !closing else { return false }
        closing = true
        return true
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

/**
 In-app akışı: listeyi oturum başında ve en fazla 5 dakikada bir yeniler, tetikleri değerlendirir (`HSInAppRules`),
 `session_duration` eşikleri için zamanlayıcı kurar, app geneli gösterim aralığını uygular, aynı anda tek mesaj gösterir,
 gösterim/tıklama/kapatma olaylarını (varyant kimliğiyle) çevrimdışı kuyruğa yazar ve aksiyonları uygular.
 Durum ana iş parçacığında tutulur.
 */
final class HSInAppController {
    static let refreshInterval: TimeInterval = 5 * 60
    static let sessionRefreshMinAge: TimeInterval = 30
    static let sessionStartWindow: TimeInterval = 60
    /// SDK'nın çizebildiği içerik yetenekleri (`GET /in-app?supports=`).
    static let supports = "html,carousel"

    private var messages: [HSInAppMessage] = []
    private var loaded = false
    private var fetchedAt: Date?
    private var fetching = false
    private var locals: [String: HSLocalImpressions] = [:]
    private var screen: String?
    private(set) var triggers: [String: String] = [:]
    private var sessionStartAt: Date?
    /// Ön plan oturumunun başlangıcı (`session_duration` için); arka planda nil.
    private var sessionBeganAt: Date?
    private var sessionDurationTimer: DispatchWorkItem?
    private var current: HSInAppHandle?
    private lazy var defaultRenderer = HSInAppWindowRenderer()
    private var customRenderer: HSInAppRenderer?

    var paused = false
    /// `in_app.min_interval_seconds` (config): herhangi bir gösterimden sonra bu süre dolmadan yeni mesaj gösterilmez.
    var globalMinIntervalSeconds = 0
    let clickListeners = HSListenerRegistry<HSInAppClickEvent>()
    var lifecycleListeners: [WeakListener] = []

    struct WeakListener { weak var value: HSInAppLifecycleListener? }

    func setRenderer(_ renderer: HSInAppRenderer?) { main { [self] in customRenderer = renderer } }

    /// HTML mesajı her zaman varsayılan (yalıtılmış WKWebView) çizimle gösterilir; diğerleri varsa özel çizimle.
    private func renderer(for message: HSInAppMessage) -> HSInAppRenderer {
        message.display.isHtml ? defaultRenderer : customRenderer ?? defaultRenderer
    }

    private func main(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func notifyLifecycle(_ body: (HSInAppLifecycleListener) -> Void) {
        lifecycleListeners.removeAll { $0.value == nil }
        lifecycleListeners.forEach { if let l = $0.value { body(l) } }
    }

    // MARK: Durum

    func addTriggers(_ values: [String: String]) {
        main { [self] in
            guard !values.isEmpty else { return }
            triggers.merge(values) { _, new in new }
            evaluate(.triggerChange(Set(values.keys)))
        }
    }

    func removeTriggers(_ keys: [String]) {
        main { [self] in
            let removed = Set(keys.filter { triggers.removeValue(forKey: $0) != nil })
            if !removed.isEmpty { evaluate(.triggerChange(removed)) }
        }
    }

    func clearTriggers() {
        main { [self] in
            let removed = Set(triggers.keys)
            triggers.removeAll()
            if !removed.isEmpty { evaluate(.triggerChange(removed)) }
        }
    }

    func setScreen(_ name: String?) {
        main { [self] in
            guard screen != name else { return }
            screen = name
            if let name { evaluate(.screen(name)) }
        }
    }

    func onEvent(_ name: String) { main { [self] in evaluate(.event(name)) } }

    // MARK: Liste

    func onSessionStart() {
        main { [self] in
            sessionStartAt = Date()
            sessionBeganAt = sessionStartAt
            refresh(minAge: Self.sessionRefreshMinAge)
            scheduleSessionDurationTimer()
        }
    }

    /// Uygulama arka plana geçti: oturum süresi sıfırlanır, `session_duration` zamanlayıcısı iptal edilir.
    func onSessionEnd() {
        main { [self] in
            sessionStartAt = nil
            sessionBeganAt = nil
            sessionDurationTimer?.cancel()
            sessionDurationTimer = nil
        }
    }

    /// Geçerli ön plan oturumunun süresi (saniye); arka planda 0.
    private var sessionSeconds: Int { sessionBeganAt.map { Int(Date().timeIntervalSince($0)) } ?? 0 }

    /// Mesajlardaki bir sonraki `session_duration` eşiği için zamanlayıcı kurar (yoksa iptal).
    private func scheduleSessionDurationTimer() {
        sessionDurationTimer?.cancel()
        sessionDurationTimer = nil
        guard let began = sessionBeganAt,
              let next = HSInAppRules.nextSessionDurationSeconds(messages, sessionSeconds: sessionSeconds) else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluate(.sessionDuration)
            self.scheduleSessionDurationTimer()
        }
        sessionDurationTimer = item
        let delay = max(began.addingTimeInterval(Double(next)).timeIntervalSinceNow, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Abonelik ilk kez oluştuğunda veya kullanıcı değiştiğinde (login/logout) liste hemen yenilenir.
    func onSubscriptionChanged() { main { [self] in refresh(minAge: 0) } }

    /// Logout/login: kullanıcı değişti; yerel sayaçlar ve liste sıfırlanır.
    func reset() {
        main { [self] in
            messages = []
            loaded = false
            fetchedAt = nil
            locals = [:]
        }
    }

    private func refresh(minAge: TimeInterval) {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < minAge { runPendingSessionStart(); return }
        guard !fetching, let subId = Pushizo.engagementSubscriptionId(), let api = Pushizo.api else { return }
        fetching = true
        // Sahiplik kanıtı (ADR-0016): kayıtlı token'ın veya kanonik adresin özeti.
        let query = HSOwnership.subscriptionQuery(
            subscriptionId: subId,
            registeredToken: Pushizo.storage.flatMap { Pushizo.ownershipToken($0, subscriptionId: subId) }
        )
        Task {
            var list: [HSInAppMessage]?
            do {
                // İçerik yetenekleri (ADR-0027): bildirilmezse sunucu HTML mesaj ve carousel göndermez.
                list = HSInAppParser.parseList(try await api.request("GET", "/in-app?\(query)&supports=\(Self.supports)"))
            } catch {
                HSLog.log(.warn, "in-app listesi alınamadı: \(error)")
                if (error as? HSApiError)?.isRetryable != true {
                    Pushizo.reportError("in_app_fetch_failed", "in-app listesi alınamadı", error: error)
                }
            }
            let pending = Pushizo.pendingInAppMessageIds()
            await MainActor.run {
                self.fetching = false
                if let list {
                    self.messages = list
                    self.loaded = true
                    self.fetchedAt = Date()
                    // Sunucu gönderilmiş olayları içerir; yalnızca kuyrukta olayı bekleyen mesajların yerel durumu korunur.
                    self.locals = self.locals.filter { pending.contains($0.key) }
                    HSLog.log(.debug, "in-app listesi yenilendi: \(list.count) mesaj")
                    self.scheduleSessionDurationTimer()
                }
                self.runPendingSessionStart()
            }
        }
    }

    /// Oturum başı değerlendirmesi liste yüklendikten sonra (en geç 60 sn içinde) bir kez yapılır.
    private func runPendingSessionStart() {
        guard let started = sessionStartAt, loaded else { return }
        sessionStartAt = nil
        if Date().timeIntervalSince(started) <= Self.sessionStartWindow { evaluate(.sessionStart) }
    }

    private func evaluate(_ cause: HSInAppCause) {
        if fetchedAt.map({ Date().timeIntervalSince($0) > Self.refreshInterval }) ?? true { refresh(minAge: Self.refreshInterval) }
        guard !paused, current == nil else { return }
        let state = HSInAppState(screen: screen, triggers: triggers, sessionSeconds: sessionSeconds)
        guard let message = HSInAppRules.select(messages, cause: cause, state: state, locals: locals, now: Date(),
                                                globalMinIntervalSeconds: globalMinIntervalSeconds,
                                                lastImpressionAt: Pushizo.storage?.lastInAppImpressionAt) else { return }
        present(message)
    }

    private func present(_ message: HSInAppMessage) {
        let handle = HSInAppHandle(controller: self, message: message)
        current = handle
        notifyLifecycle { $0.onWillDisplay(message) }
        if !renderer(for: message).show(message, handle: handle) {
            HSLog.log(.warn, "in-app mesajı gösterilemedi")
            if current === handle { current = nil }
        }
    }

    // MARK: Handle geri çağrıları (ana iş parçacığı)

    func onDisplayed(_ handle: HSInAppHandle) {
        let id = handle.message.id
        var local = locals[id] ?? HSLocalImpressions()
        let now = Date()
        local.count += 1
        local.lastAt = now
        locals[id] = local
        // App geneli aralık herhangi bir mesajın son gösteriminden ölçülür; uygulama yeniden başlasa da korunur.
        Pushizo.storage?.lastInAppImpressionAt = now
        record(handle.message, type: "impression", buttonId: nil)
        notifyLifecycle { $0.onDidDisplay(handle.message) }
    }

    /// Tıklama/kapatma yerelde işaretlenir (`stop_after_interaction`).
    private func markInteracted(_ id: String) {
        var local = locals[id] ?? HSLocalImpressions()
        local.interacted = true
        locals[id] = local
    }

    func onButtonClicked(_ handle: HSInAppHandle, button: HSInAppButton) {
        let message = handle.message
        markInteracted(message.id)
        record(message, type: "click", buttonId: button.id)
        var url: String?
        if case let .url(u) = button.action { url = u }
        if case let .deeplink(u) = button.action { url = u }
        let event = HSInAppClickEvent(messageId: message.id, actionId: button.id, url: url)
        clickListeners.notify(event)
        switch button.action {
        case let .url(u), let .deeplink(u):
            // Uygulama şeması kayıtlıysa iOS bağlantıyı uygulamanın kendisine (onOpenURL / scene delegate) iletir.
            if let target = URL(string: u) {
                UIApplication.shared.open(target) { ok in if !ok { HSLog.log(.warn, "in-app adresi açılamadı") } }
            }
        case let .tags(tags):
            if !tags.isEmpty { Pushizo.User.addTags(tags) }
        case let .outcome(name, value):
            Pushizo.Session.sendEvent(name, value: value)
        case .pushPrompt:
            Pushizo.Notifications.requestPermission()
        case .dismiss:
            break
        }
        close(handle)
    }

    /// HTML köprüsü tıklaması: düğme tıklamasıyla aynı olay ve dinleyiciler; http(s) tarayıcıda, diğer şema deeplink.
    func onHtmlClicked(_ handle: HSInAppHandle, actionId: String, url: String?) {
        let message = handle.message
        markInteracted(message.id)
        record(message, type: "click", buttonId: actionId)
        clickListeners.notify(HSInAppClickEvent(messageId: message.id, actionId: actionId, url: url))
        // Adres köprüde doğrulandı (http(s) veya uygulama şeması); uygulama şeması kayıtlıysa iOS uygulamaya iletir.
        if let url, let target = URL(string: url) {
            UIApplication.shared.open(target) { ok in if !ok { HSLog.log(.warn, "in-app adresi açılamadı") } }
        }
        close(handle)
    }

    func onDismissed(_ handle: HSInAppHandle) {
        markInteracted(handle.message.id)
        record(handle.message, type: "dismiss", buttonId: nil)
        close(handle)
    }

    private func close(_ handle: HSInAppHandle) {
        guard handle.requestClose() else { return }
        notifyLifecycle { $0.onWillDismiss(handle.message) }
        renderer(for: handle.message).close(messageId: handle.message.id)
    }

    func onClosed(_ handle: HSInAppHandle) {
        if current === handle { current = nil }
        notifyLifecycle { $0.onDidDismiss(handle.message) }
        // Mesaj açıkken eşiği dolan `session_duration` tetikleri (zamanlayıcı o anda atlandı) yeniden değerlendirilir.
        evaluate(.sessionDuration)
    }

    private func record(_ message: HSInAppMessage, type: String, buttonId: String?) {
        var op: [String: Any] = ["type": "in_app_event", "message_id": message.id, "event": type, "at": Date().timeIntervalSince1970]
        if let buttonId { op["button_id"] = buttonId }
        // Sunucunun seçtiği A/B varyantı olayla birlikte geri gönderilir.
        if let variantId = message.variantId { op["variant_id"] = variantId }
        Pushizo.enqueue(op)
    }
}

extension CharacterSet {
    /// Sorgu değeri için güvenli karakterler (`&`, `=`, `+`, `?` kodlanır).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}

// MARK: - Varsayılan UIKit çizimi

/**
 Varsayılan in-app çizimi: etkin `UIWindowScene` üstünde ayrı bir `UIWindow` (SwiftUI uygulamalarıyla uyumlu).
 Modal/tam ekran dokunuşları yakalar; banner dışındaki dokunuşlar uygulamaya geçer. Görseller (carousel kartlarınınkiler
 dahil) gösterimden önce indirilir; HTML içerikte gösterim, içerik kural listesinin derlenmesini bekler (`HSHtmlInAppView`).
 */
final class HSInAppWindowRenderer: HSInAppRenderer {
    private var window: UIWindow?
    private var active: (message: HSInAppMessage, handle: HSInAppHandle)?
    private var autoDismiss: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    func show(_ message: HSInAppMessage, handle: HSInAppHandle) -> Bool {
        guard active == nil else { return false }
        active = (message, handle)
        Task {
            let images = await Self.loadImages(message)
            // Kural listesi derlenemezse nil: mesaj CSP ve gezinme denetimiyle gösterilir.
            let rules = message.display.isHtml ? await HSHtmlInAppView.ruleList() : nil
            await MainActor.run {
                guard self.active?.handle === handle else { return }
                self.attach(message, handle: handle, images: images, rules: rules)
            }
        }
        return true
    }

    func close(messageId: String) {
        guard let active, active.message.id == messageId else { return }
        autoDismiss?.cancel()
        autoDismiss = nil
        guard let window, let vc = window.rootViewController as? HSInAppViewController else { finish(active.handle); return }
        vc.animateOut { [weak self] in
            window.isHidden = true
            self?.window = nil
            self?.finish(active.handle)
        }
    }

    private func finish(_ handle: HSInAppHandle) {
        if let observer = activationObserver { NotificationCenter.default.removeObserver(observer) }
        activationObserver = nil
        active = nil
        handle.closed()
    }

    private func attach(_ message: HSInAppMessage, handle: HSInAppHandle, images: [String: UIImage], rules: WKContentRuleList?) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            // Uygulama etkin değil: etkinleşince yeniden denenir.
            activationObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.active?.handle === handle, self.window == nil else { return }
                if let observer = self.activationObserver { NotificationCenter.default.removeObserver(observer) }
                self.activationObserver = nil
                self.attach(message, handle: handle, images: images, rules: rules)
            }
            return
        }
        let banner = message.display.layout == .bannerTop || message.display.layout == .bannerBottom
        let window = HSPassthroughWindow(windowScene: scene)
        window.passthrough = banner
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let vc = HSInAppViewController(message: message, images: images, handle: handle, rules: rules)
        window.rootViewController = vc
        self.window = window
        window.isHidden = false
        vc.animateIn {
            handle.displayed()
            UIAccessibility.post(notification: banner ? .layoutChanged : .screenChanged, argument: vc.accessibilityFocus)
        }
        if let seconds = message.display.autoDismissSeconds {
            let work = DispatchWorkItem { handle.dismissed() }
            autoDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
        }
    }

    /// Görselleri paralel indirir (10 sn zaman aşımı); başarısız görsel atlanır.
    static func loadImages(_ message: HSInAppMessage) async -> [String: UIImage] {
        let urls = Set(message.display.blocks.flatMap { block -> [String] in
            switch block {
            case let .image(url, _): return [url]
            case let .carousel(c): return c.cards.compactMap(\.imageUrl)
            default: return []
            }
        })
        var result: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for url in urls {
                group.addTask {
                    guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else { return (url, nil) }
                    var request = URLRequest(url: u)
                    request.timeoutInterval = 10
                    guard let result = try? await URLSession.shared.data(for: request),
                          ((result.1 as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2 else { return (url, nil) }
                    return (url, UIImage(data: result.0))
                }
            }
            for await (url, image) in group { if let image { result[url] = image } }
        }
        return result
    }
}

/// Banner'da kart dışındaki dokunuşları alttaki uygulama penceresine geçirir.
final class HSPassthroughWindow: UIWindow {
    var passthrough = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if passthrough, hit === rootViewController?.view { return nil }
        return hit
    }
}

/// In-app mesaj görünümü: yerel UIKit bileşenleri veya HTML içerikte yalıtılmış WKWebView (`HSHtmlInAppView`).
final class HSInAppViewController: UIViewController {
    private let message: HSInAppMessage
    private let images: [String: UIImage]
    private let handle: HSInAppHandle
    private let rules: WKContentRuleList?
    private let card = UIView()
    private let scrim = UIView()
    private var web: HSHtmlInAppView?
    private var webHeight: NSLayoutConstraint?
    private(set) var accessibilityFocus: Any?

    /// `html_height` verilmediğinde ilk yükseklik (pt); köprünün `resize` bildirimiyle güncellenir.
    private static let defaultBannerHtmlHeight: CGFloat = 120
    private static let defaultModalHtmlHeight: CGFloat = 360

    private var display: HSInAppDisplay { message.display }
    private var banner: Bool { display.layout == .bannerTop || display.layout == .bannerBottom }
    private var fullscreen: Bool { display.layout == .fullscreen }

    init(message: HSInAppMessage, images: [String: UIImage], handle: HSInAppHandle, rules: WKContentRuleList?) {
        self.message = message
        self.images = images
        self.handle = handle
        self.rules = rules
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmez") }

    /// Verilmeyen renk sistem açık/koyu temasına uyar; yalnızca arka plan verilirse metin kontrasta göre seçilir.
    private func color(_ hex: String?, light: UInt32, dark: UInt32) -> UIColor {
        if let argb = HSInAppStyle.parseColor(hex) { return Self.uiColor(argb) }
        return UIColor { $0.userInterfaceStyle == .dark ? Self.uiColor(dark) : Self.uiColor(light) }
    }

    static func uiColor(_ argb: UInt32) -> UIColor {
        UIColor(red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let background = color(display.backgroundColor, light: HSInAppStyle.lightBackground, dark: HSInAppStyle.darkBackground)
        let textColor: UIColor
        if let explicit = HSInAppStyle.parseColor(display.textColor) {
            textColor = Self.uiColor(explicit)
        } else if let bg = HSInAppStyle.parseColor(display.backgroundColor) {
            textColor = Self.uiColor(HSInAppStyle.contrastingText(bg))
        } else {
            textColor = color(nil, light: HSInAppStyle.lightText, dark: HSInAppStyle.darkText)
        }
        // Kapatılamaz ama düğmesiz ve otomatik kapanmayan mesajda kullanıcı mahsur kalmasın.
        let showClose = display.dismissible || (display.buttons.isEmpty && display.autoDismissSeconds == nil)

        if !banner && !fullscreen {
            scrim.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            scrim.translatesAutoresizingMaskIntoConstraints = false
            scrim.isAccessibilityElement = false
            if display.dismissible { scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissTapped))) }
            view.addSubview(scrim)
            NSLayoutConstraint.activate([
                scrim.topAnchor.constraint(equalTo: view.topAnchor), scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor), scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        card.backgroundColor = background
        card.layer.cornerRadius = fullscreen ? 0 : 16
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = banner ? 0.25 : 0
        card.layer.shadowRadius = 12
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.accessibilityViewIsModal = !banner
        view.addSubview(card)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        let inset: CGFloat = banner ? 16 : 24
        var startsWithImage = false
        if case .image = display.blocks.first { startsWithImage = true }
        let topInset: CGFloat = showClose && !startsWithImage ? 44 : inset

        for block in display.blocks {
            switch block {
            case let .image(url, alt):
                guard let image = images[url] else { continue }
                let iv = UIImageView(image: image)
                iv.contentMode = .scaleAspectFit
                iv.clipsToBounds = true
                iv.isAccessibilityElement = alt != nil
                iv.accessibilityLabel = alt
                iv.accessibilityTraits = .image
                let ratio = image.size.width > 0 ? image.size.height / image.size.width : 0.5
                let height = iv.heightAnchor.constraint(equalTo: iv.widthAnchor, multiplier: ratio)
                height.priority = .defaultHigh
                height.isActive = true
                iv.heightAnchor.constraint(lessThanOrEqualToConstant: banner ? 96 : 280).isActive = true
                stack.addArrangedSubview(iv)
            case let .title(text):
                let label = makeLabel(text, style: banner ? .headline : .title2, bold: true, color: textColor)
                label.accessibilityTraits = .header
                if accessibilityFocus == nil { accessibilityFocus = label }
                stack.addArrangedSubview(label)
            case let .body(text):
                stack.addArrangedSubview(makeLabel(text, style: banner ? .subheadline : .body, bold: false, color: textColor))
            case let .button(b):
                stack.addArrangedSubview(makeButton(b))
            case let .carousel(c):
                stack.addArrangedSubview(HSCarouselView(carousel: c, images: images, textColor: textColor, background: background,
                                                        banner: banner, makeButton: { [unowned self] in self.makeButton($0) }))
            }
        }

        if display.isHtml {
            embedHtml()
        } else {
            let scroll = UIScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.alwaysBounceVertical = false
            scroll.addSubview(stack)
            card.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: fullscreen ? card.safeAreaLayoutGuide.topAnchor : card.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: fullscreen ? card.safeAreaLayoutGuide.bottomAnchor : card.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: inset),
                stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -inset),
            ])
            // İçerik kısa ise kart içeriğe göre boyutlanır; uzunsa kaydırılır.
            let fit = scroll.heightAnchor.constraint(equalTo: scroll.contentLayoutGuide.heightAnchor)
            fit.priority = .defaultLow
            fit.isActive = true
            let content = scroll.contentLayoutGuide
            if fullscreen {
                // Tam ekranda içerik dikeyde ortalanır; uzunsa kaydırılır.
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: topInset),
                    stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -inset),
                    stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                    content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
                ])
                let tight = content.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: topInset + inset)
                tight.priority = .defaultLow
                tight.isActive = true
            } else {
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: content.topAnchor, constant: topInset),
                    stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
                ])
            }
        }

        if showClose {
            let close = UIButton(type: .system)
            close.setImage(UIImage(systemName: "xmark"), for: .normal)
            close.tintColor = textColor
            close.accessibilityLabel = Self.closeLabel
            close.translatesAutoresizingMaskIntoConstraints = false
            close.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
            card.addSubview(close)
            NSLayoutConstraint.activate([
                close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44),
                close.topAnchor.constraint(equalTo: fullscreen ? card.safeAreaLayoutGuide.topAnchor : card.topAnchor, constant: 4),
                close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            ])
        }

        let guide = view.safeAreaLayoutGuide
        switch display.layout {
        case .fullscreen:
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: view.topAnchor), card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: view.leadingAnchor), card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        case .bannerTop, .bannerBottom:
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
                card.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
                // HTML banner yüksekliğini köprü belirler (üst sınır ekranın %90'ı); yerel banner en fazla yarım ekran.
                card.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, multiplier: display.isHtml ? 0.9 : 0.5),
                display.layout == .bannerTop
                    ? card.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8)
                    : card.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            ])
        case .modal:
            let width = card.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -48)
            width.priority = .defaultHigh
            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
                card.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
                width,
                card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
                card.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, constant: -48),
            ])
        }
        if accessibilityFocus == nil { accessibilityFocus = card }
    }

    /// HTML içerik: kartı dolduran WKWebView. Banner/modal yüksekliği `html_height` ile başlar, `resize` ile güncellenir
    /// (üst sınır ekranın %90'ı); tam ekranda WebView kartın güvenli alanını doldurur.
    private func embedHtml() {
        let htmlView = HSHtmlInAppView(html: display.html ?? "", language: message.language, rules: rules) { [weak self] action in
            self?.handleBridge(action)
        }
        web = htmlView
        let webView = htmlView.webView
        card.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: fullscreen ? card.safeAreaLayoutGuide.topAnchor : card.topAnchor),
            webView.bottomAnchor.constraint(equalTo: fullscreen ? card.safeAreaLayoutGuide.bottomAnchor : card.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        if !fullscreen {
            let initial = display.htmlHeight.map { CGFloat($0) } ?? (banner ? Self.defaultBannerHtmlHeight : Self.defaultModalHtmlHeight)
            let height = webView.heightAnchor.constraint(equalToConstant: initial)
            // Kart sınırları (ekranın %90'ı) istenen yükseklikten önce gelir.
            height.priority = .defaultHigh
            height.isActive = true
            webView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.9).isActive = true
            webHeight = height
        }
        accessibilityFocus = webView
        htmlView.load()
    }

    private func handleBridge(_ action: HSHtmlBridgeAction) {
        switch action {
        case .ready:
            break
        case .close:
            handle.dismissed()
        case let .click(actionId, url):
            handle.htmlClicked(actionId, url: url)
        case let .addTag(key, value):
            handle.htmlAddTag(key, value: value)
        case let .trackEvent(name, props):
            handle.htmlTrackEvent(name, properties: props)
        case let .resize(height):
            guard let webHeight, webHeight.constant != CGFloat(height) else { return }
            webHeight.constant = CGFloat(height)
            view.layoutIfNeeded()
        }
    }

    private func makeLabel(_ text: String, style: UIFont.TextStyle, bold: Bool, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = color
        label.textAlignment = banner ? .natural : .center
        let base = UIFont.preferredFont(forTextStyle: style)
        // Kalın stil dinamik yazı boyutunu korur (metin stili tanımlayıcıda kalır).
        label.font = bold ? base.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? base : base
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func makeButton(_ b: HSInAppButton) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(b.text, for: .normal)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        let bg: UIColor = HSInAppStyle.parseColor(b.backgroundColor).map(Self.uiColor)
            ?? color(nil, light: HSInAppStyle.lightButton, dark: HSInAppStyle.darkButton)
        let fg: UIColor
        if let explicit = HSInAppStyle.parseColor(b.textColor) { fg = Self.uiColor(explicit) }
        else if let bgHex = HSInAppStyle.parseColor(b.backgroundColor) { fg = Self.uiColor(HSInAppStyle.contrastingText(bgHex)) }
        else { fg = Self.uiColor(HSInAppStyle.darkText) }
        button.backgroundColor = bg
        button.setTitleColor(fg, for: .normal)
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.handle.buttonClicked(b.id) }, for: .touchUpInside)
        return button
    }

    @objc private func dismissTapped() { handle.dismissed() }

    /// VoiceOver "geri" hareketi (iki parmakla Z) kapatılabilir mesajı kapatır.
    override func accessibilityPerformEscape() -> Bool {
        guard display.dismissible else { return false }
        handle.dismissed()
        return true
    }

    private var offscreenTransform: CGAffineTransform {
        switch display.layout {
        case .bannerTop: return CGAffineTransform(translationX: 0, y: -200)
        case .bannerBottom: return CGAffineTransform(translationX: 0, y: 200)
        default: return CGAffineTransform(scaleX: 0.92, y: 0.92)
        }
    }

    func animateIn(_ completion: @escaping () -> Void) {
        loadViewIfNeeded()
        card.transform = offscreenTransform
        card.alpha = 0
        scrim.alpha = 0
        let reduce = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduce ? 0 : 0.25, delay: 0, options: .curveEaseOut, animations: {
            self.card.transform = .identity
            self.card.alpha = 1
            self.scrim.alpha = 1
        }, completion: { _ in completion() })
    }

    func animateOut(_ completion: @escaping () -> Void) {
        let reduce = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduce ? 0 : 0.2, delay: 0, options: .curveEaseIn, animations: {
            self.card.transform = self.offscreenTransform
            self.card.alpha = 0
            self.scrim.alpha = 0
        }, completion: { [weak self] _ in
            self?.web?.destroy()
            completion()
        })
    }

    static var closeLabel: String {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("tr") ? "Kapat" : "Close"
    }
}
