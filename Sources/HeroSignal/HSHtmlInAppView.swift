import Foundation
// SPM: ayrı modül; CocoaPods alt spec'leri tek "HeroSignal" modülünde derlenir.
#if canImport(HeroSignalCore)
import HeroSignalCore
#endif
import UIKit
import WebKit

/**
 HTML in-app mesajını yalıtılmış bir `WKWebView`'da çizer (ADR-0027). Güvenlik katmanları:
 - Belgedeki CSP ağ isteklerini (fetch/XHR/WebSocket) ve dış betik/stil yüklemeyi engeller; yalnızca https/data görsel.
 - `WKContentRuleList`: https/data görseller dışındaki tüm alt kaynak yüklerini engeller (CSP'ye ek savunma). Kural
   listesi bir kez, eşzamansız derlenir ve gösterim derleme bitene kadar bekler; derlenemezse (eski/kısıtlı WebKit)
   mesaj yalnızca CSP ve gezinme denetimiyle gösterilir.
 - `websiteDataStore = .nonPersistent()` (çerez/depolama kalıcı değil), JavaScript pencere açamaz.
 - `WKNavigationDelegate`: `loadHTMLString(baseURL: nil)` ile yapılan ilk yükleme (`about:blank`) dışında her gezinme
   iptal edilir (bağlantılar köprü üzerinden `click` olur). `WKUIDelegate` yeni pencere ve JS diyaloglarını reddeder.
 - Uygulamaya yalnızca `heroSignalBridge` ileti işleyicisi açıktır; mesaj ana çerçeveden gelmeli ve `HSHtmlBridge` ile
   (işaret, sürüm, gösterime özel nonce, şema) doğrulanmalıdır.
 */
@MainActor
final class HSHtmlInAppView: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    /// Her gösterim (görünüm) için yeni nonce; köprü betiğine gömülür.
    private let nonce = HSHtmlBridge.newNonce()
    private let html: String
    private let language: String?
    private let onAction: (HSHtmlBridgeAction) -> Void
    private var initialLoadAllowed = false
    private var destroyed = false

    init(html: String, language: String?, rules: WKContentRuleList?, onAction: @escaping (HSHtmlBridgeAction) -> Void) {
        self.html = html
        self.language = language
        self.onAction = onAction
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.dataDetectorTypes = []
        if let rules { configuration.userContentController.add(rules) }
        // İleti işleyicisi WKUserContentController tarafından güçlü tutulur: döngü olmasın diye zayıf aracı kullanılır.
        let proxy = HSWeakScriptMessageHandler()
        configuration.userContentController.add(proxy, name: HSHtmlBridge.handlerName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        proxy.target = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Belgeyi yükler: base URL yok (`about:blank`, opak köken).
    func load() {
        guard !destroyed, let document = HSHtmlBridge.document(html: html, nonce: nonce, language: language) else { return }
        webView.loadHTMLString(document, baseURL: nil)
    }

    /// Görünüm kaldırılınca: köprü ayrılır, yükleme durdurulur. Tekrar çağrı zararsızdır.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: HSHtmlBridge.handlerName)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !destroyed, message.frameInfo.isMainFrame, let body = message.body as? String,
              let action = HSHtmlBridge.parse(json: body, nonce: nonce) else {
            HSLog.log(.debug, "HTML in-app köprüsü: geçersiz mesaj yok sayıldı")
            return
        }
        onAction(action)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Yalnızca ilk belge yüklemesi (loadHTMLString, baseURL nil → about:blank ana çerçeve) geçer.
        if !initialLoadAllowed, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.url?.absoluteString == "about:blank" {
            initialLoadAllowed = true
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }

    // MARK: İçerik kural listesi

    private static let ruleListIdentifier = "HeroSignalHtmlInApp-v1"
    /// Önce her şeyi (ana belge hariç alt kaynaklar) engelle, sonra https/data görsellere izin ver.
    private static let ruleListJson = """
    [
      {"trigger": {"url-filter": ".*", "resource-type": ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup"]}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^https://", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}}
    ]
    """
    private static var compiledRules: WKContentRuleList?
    private static var compileFailed = false
    private static var waiters: [(WKContentRuleList?) -> Void] = []

    /// Derlenmiş kural listesi (bir kez derlenir, sonra önbellekten). Derlenemezse nil: CSP + gezinme denetimiyle devam.
    static func ruleList() async -> WKContentRuleList? {
        if let compiledRules { return compiledRules }
        if compileFailed { return nil }
        return await withCheckedContinuation { continuation in
            requestRules { continuation.resume(returning: $0) }
        }
    }

    /// Ana iş parçacığında çağrılır; eşzamanlı istekler tek derlemeyi bekler.
    private static func requestRules(_ completion: @escaping (WKContentRuleList?) -> Void) {
        waiters.append(completion)
        guard waiters.count == 1 else { return }
        guard let store = WKContentRuleListStore.default() else {
            finishCompile(nil, error: nil)
            return
        }
        store.compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: ruleListJson) { list, error in
            Task { @MainActor in finishCompile(list, error: error) }
        }
    }

    private static func finishCompile(_ list: WKContentRuleList?, error: Error?) {
        compiledRules = list
        if list == nil {
            compileFailed = true
            let reason = error.map { "\($0)" } ?? "kural deposu yok"
            HSLog.log(.warn, "HTML in-app içerik kuralları derlenemedi; yalnızca CSP ve gezinme denetimi uygulanıyor: \(reason)")
        }
        let pending = waiters
        waiters = []
        pending.forEach { $0(list) }
    }
}

/// `WKUserContentController` ileti işleyicisini zayıf tutan aracı (WKWebView ↔ görünüm döngüsünü önler).
@MainActor
private final class HSWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/**
 Carousel bloğu: yatay kaydırmalı kartlar. Birden fazla kart varsa kart genişliği alanın %85'idir (sonraki kart görünür);
 kaydırma bırakıldığında en yakın karta oturur. VoiceOver kart başlığını "Kart 1/3: başlık" olarak okur; düğmeler
 en az 44pt yüksekliğindedir.
 */
final class HSCarouselView: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private let spacing: CGFloat = 12
    private var positionedForRtl = false

    init(carousel: HSInAppCarousel, images: [String: UIImage], textColor: UIColor, background: UIColor, banner: Bool,
         makeButton: (HSInAppButton) -> UIButton) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.decelerationRate = .fast
        scroll.delegate = self
        addSubview(scroll)
        row.axis = .horizontal
        row.spacing = spacing
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            // Dikey kaydırma yok: görünüm yüksekliği en uzun kart kadardır.
            scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: scroll.contentLayoutGuide.heightAnchor),
        ])
        let total = carousel.cards.count
        let ratio: CGFloat = total > 1 ? 0.85 : 1
        for (index, card) in carousel.cards.enumerated() {
            let view = makeCard(card, index: index, total: total, images: images, textColor: textColor,
                                background: background, banner: banner, makeButton: makeButton)
            row.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, multiplier: ratio).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmez") }

    private func makeCard(_ card: HSInAppCarouselCard, index: Int, total: Int, images: [String: UIImage], textColor: UIColor,
                          background: UIColor, banner: Bool, makeButton: (HSInAppButton) -> UIButton) -> UIView {
        let container = UIView()
        container.backgroundColor = background
        container.layer.cornerRadius = 12
        container.layer.borderWidth = 1
        container.layer.borderColor = textColor.withAlphaComponent(0.2).cgColor
        container.clipsToBounds = true
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])
        if let url = card.imageUrl, let image = images[url] {
            let iv = UIImageView(image: image)
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = 8
            iv.isAccessibilityElement = card.imageAlt != nil
            iv.accessibilityLabel = card.imageAlt
            iv.accessibilityTraits = .image
            iv.heightAnchor.constraint(equalToConstant: banner ? 80 : 140).isActive = true
            stack.addArrangedSubview(iv)
        }
        let title = UILabel()
        title.text = card.title
        title.numberOfLines = 0
        title.textColor = textColor
        let base = UIFont.preferredFont(forTextStyle: banner ? .subheadline : .headline)
        title.font = base.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? base
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityLabel = Self.cardLabel(index: index + 1, total: total, title: card.title)
        title.accessibilityTraits = .header
        stack.addArrangedSubview(title)
        if let body = card.body, !body.isEmpty {
            let label = UILabel()
            label.text = body
            label.numberOfLines = 0
            label.textColor = textColor
            label.font = UIFont.preferredFont(forTextStyle: banner ? .footnote : .subheadline)
            label.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(label)
        }
        if let button = card.button {
            // Düğmeler kart altına hizalanır (kartlar en uzun kart kadar yüksektir).
            let spacer = UIView()
            spacer.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
            stack.addArrangedSubview(spacer)
            stack.addArrangedSubview(makeButton(button))
        }
        return container
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Sağdan sola dillerde ilk kart sağdadır: başlangıçta ona kaydırılır.
        if !positionedForRtl, effectiveUserInterfaceLayoutDirection == .rightToLeft, scroll.contentSize.width > scroll.bounds.width {
            positionedForRtl = true
            scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width
        }
    }

    // MARK: UIScrollViewDelegate

    /// Bırakılan kaydırma en yakın kartın başına oturur (hız yönündeki karta).
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard let first = row.arrangedSubviews.first, first.bounds.width > 0 else { return }
        let step = first.bounds.width + spacing
        var page = (targetContentOffset.pointee.x / step).rounded()
        if velocity.x > 0.2 { page = (scrollView.contentOffset.x / step).rounded(.up) }
        else if velocity.x < -0.2 { page = (scrollView.contentOffset.x / step).rounded(.down) }
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        targetContentOffset.pointee.x = min(max(0, page * step), maxX)
    }

    static func cardLabel(index: Int, total: Int, title: String) -> String {
        let turkish = (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("tr")
        return turkish ? "Kart \(index)/\(total): \(title)" : "Card \(index)/\(total): \(title)"
    }
}
