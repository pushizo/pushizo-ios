import Foundation
#if canImport(PushizoCore)
import PushizoCore
#endif
#if canImport(UIKit)
import UIKit

/// Hazır içerik kartı akışı (ADR-0082): `Pushizo.ContentCards` verisini dikey liste olarak gösterir. Pencereye
/// eklendiğinde akışı yükler; yükleniyor, boş ve hata (yeniden dene) durumları vardır. Kartın en az yarısı göründüğünde
/// gösterim bir kez kaydedilir; tıklama kaydedilir ve bağlantı açılır (`onCardClick` true dönerse uygulama işler);
/// × kartı kapatır. Renkler sistem renkleriyle açık/koyu temaya uyar; Dynamic Type desteklenir.
public final class HSContentCardsView: UIView, UIScrollViewDelegate {
    /// Bir yüklemede istenen kart sayısı (1-100).
    public var limit: Int = 50 {
        didSet { limit = min(100, max(1, limit)) }
    }

    /// Kart tıklandığında çağrılır; true dönerse varsayılan bağlantı açma yapılmaz.
    public var onCardClick: ((HSContentCard) -> Bool)?

    /// Akış her yüklendiğinde çağrılır (rozet vb. için).
    public var onFeedLoaded: ((HSContentCardFeed) -> Void)?

    private let strings = HSContentCardStrings.forLanguage(Locale.preferredLanguages.first)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let statusStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var cards: [(view: UIView, card: HSContentCard)] = []
    private var impressed = Set<String>()
    private var loadTask: Task<Void, Never>?
    private var loaded = false

    private enum State { case loading, empty, error, content }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit { loadTask?.cancel() }

    private func setUp() {
        backgroundColor = .systemGroupedBackground
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        spinner.hidesWhenStopped = true
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        retryButton.setTitle(strings.retry, for: .normal)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 12
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        [spinner, messageLabel, retryButton].forEach(statusStack.addArrangedSubview)
        addSubview(statusStack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -12),
            statusStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        show(.loading)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !loaded { refresh() }
        if window == nil { loadTask?.cancel() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        checkImpressions()
    }

    /// Akışı yeniden yükler (ör. aşağı çekerek yenileme).
    public func refresh() {
        loadTask?.cancel()
        if cards.isEmpty { show(.loading) }
        let limit = self.limit
        loadTask = Task { @MainActor [weak self] in
            do {
                let feed = try await Pushizo.ContentCards.list(limit: limit)
                guard let self, !Task.isCancelled else { return }
                self.loaded = true
                self.render(feed)
                self.onFeedLoaded?(feed)
            } catch is CancellationError {
                return
            } catch {
                HSLog.log(.warn, "içerik kartları yüklenemedi: \(error.localizedDescription)")
                guard let self, !Task.isCancelled else { return }
                if self.cards.isEmpty { self.show(.error) }
            }
        }
    }

    @objc private func retryTapped() { refresh() }

    private func render(_ feed: HSContentCardFeed) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = feed.cards.map { card in
            let view = cardView(card)
            stack.addArrangedSubview(view)
            return (view, card)
        }
        show(feed.cards.isEmpty ? .empty : .content)
        setNeedsLayout()
    }

    private func show(_ state: State) {
        scroll.isHidden = state != .content
        statusStack.isHidden = state == .content
        if state == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        retryButton.isHidden = state != .error
        messageLabel.isHidden = state != .empty && state != .error
        messageLabel.text = state == .empty ? strings.empty : state == .error ? strings.error : nil
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) { checkImpressions() }

    private func checkImpressions() {
        guard window != nil, !scroll.isHidden else { return }
        let visibleBounds = scroll.bounds
        for entry in cards where !entry.card.viewed && !impressed.contains(entry.card.id) {
            let frame = entry.view.convert(entry.view.bounds, to: scroll)
            let visible = frame.intersection(visibleBounds)
            let visibleHeight = visible.isNull ? 0 : Double(visible.height)
            guard HSContentCardLayout.countsAsImpression(visibleHeight: visibleHeight, totalHeight: Double(frame.height)) else { continue }
            let id = entry.card.id
            impressed.insert(id)
            Task { @MainActor [weak self] in
                do {
                    try await Pushizo.ContentCards.logImpression(id)
                } catch {
                    self?.impressed.remove(id)
                    HSLog.log(.debug, "kart gösterimi kaydedilemedi: \(error.localizedDescription)")
                }
            }
        }
    }

    private func click(_ card: HSContentCard) {
        Task {
            do { try await Pushizo.ContentCards.logClick(card.id) } catch {
                HSLog.log(.debug, "kart tıklaması kaydedilemedi: \(error.localizedDescription)")
            }
        }
        if onCardClick?(card) == true { return }
        guard let raw = card.url, let url = URL(string: raw) else { return }
        UIApplication.shared.open(url)
    }

    private func dismiss(_ card: HSContentCard) {
        guard let index = cards.firstIndex(where: { $0.card.id == card.id }) else { return }
        cards.remove(at: index).view.removeFromSuperview()
        if cards.isEmpty { show(.empty) }
        Task {
            do { try await Pushizo.ContentCards.dismiss(card.id) } catch {
                HSLog.log(.debug, "kart kapatılamadı: \(error.localizedDescription)")
            }
        }
    }

    private func cardView(_ card: HSContentCard) -> UIView {
        let parts = HSContentCardLayout.parts(card)
        let container = HSCardControl()
        container.backgroundColor = .secondarySystemGroupedBackground
        container.layer.cornerRadius = 12
        container.layer.borderWidth = card.pinned ? 2 : 1
        container.layer.borderColor = (card.pinned ? UIColor.tintColor : UIColor.separator).cgColor
        container.clipsToBounds = true
        container.isAccessibilityElement = false
        container.onTap = { [weak self] in self?.click(card) }

        let column = UIStackView()
        column.axis = .vertical
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        if parts.contains(.image) {
            let image = UIImageView()
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            image.backgroundColor = .tertiarySystemFill
            image.heightAnchor.constraint(equalToConstant: parts.contains(.text) ? 160 : 200).isActive = true
            image.isAccessibilityElement = !parts.contains(.text)
            image.accessibilityLabel = card.title ?? card.body
            column.addArrangedSubview(image)
            if let raw = card.imageUrl, let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" {
                Task { @MainActor [weak image] in
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 10
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2,
                          let loaded = UIImage(data: data) else { return }
                    image?.image = loaded
                }
            }
        }
        if parts.contains(.text) {
            let text = UIStackView()
            text.axis = .vertical
            text.spacing = 4
            text.isLayoutMarginsRelativeArrangement = true
            text.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 40)
            if card.pinned { text.addArrangedSubview(label(strings.pinned, .caption1, .tintColor, bold: true)) }
            if let title = card.title { text.addArrangedSubview(label(title, .headline, .label, bold: true)) }
            if let body = card.body { text.addArrangedSubview(label(body, .subheadline, .secondaryLabel)) }
            if parts.contains(.button), let button = card.buttonText {
                let action = label(button, .subheadline, .tintColor, bold: true)
                text.setCustomSpacing(10, after: text.arrangedSubviews.last ?? action)
                text.addArrangedSubview(action)
            }
            text.isAccessibilityElement = true
            text.accessibilityTraits = .button
            text.accessibilityLabel = [card.title, card.body, card.buttonText].compactMap { $0 }.joined(separator: ", ")
            column.addArrangedSubview(text)
        }

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .secondaryLabel
        close.accessibilityLabel = strings.dismiss
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addAction(UIAction { [weak self] _ in self?.dismiss(card) }, for: .touchUpInside)
        container.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            close.widthAnchor.constraint(equalToConstant: 36),
            close.heightAnchor.constraint(equalToConstant: 36),
        ])
        return container
    }

    private func label(_ value: String, _ style: UIFont.TextStyle, _ color: UIColor, bold: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = value
        label.numberOfLines = 0
        label.textColor = color
        let base = UIFont.preferredFont(forTextStyle: style)
        label.font = bold ? UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: 0) : base
        label.adjustsFontForContentSizeCategory = true
        return label
    }
}

/// Dokunulabilir kart kabı (kapatma düğmesi kendi dokunuşunu alır).
private final class HSCardControl: UIControl {
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tapped() { onTap?() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.85 : 1 }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // CGColor tema değişiminde kendiliğinden güncellenmez.
        layer.borderColor = (layer.borderWidth > 1 ? UIColor.tintColor : UIColor.separator).resolvedColor(with: traitCollection).cgColor
    }
}
#endif
