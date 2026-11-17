import Foundation
#if canImport(PushizoCore)
import PushizoCore
#endif
#if canImport(UIKit)
import QuickLook
import UIKit
import UniformTypeIdentifiers

/**
 Hazır canlı sohbet ekranı (ADR-0040): `Pushizo.Chat` verisini mesaj akışı ve mesaj alanı olarak gösterir. Modal sunum
 için `Pushizo.Chat.show()`; kendi gezinme yapınıza gömmek için doğrudan oluşturun (`showsCloseButton = false`).

 Ekran app'in sohbet ayarlarını (`getConfig`) uygular: başlık, karşılama metni, vurgu rengi, çevrimdışı mesaj formu
 (`collectEmailOffline`), sohbet öncesi e-posta formu (`requireEmail`) ve dosya ekleme. Görünürken canlı akışı dinler,
 gelen mesajları okundu işaretler ve "yazıyor" bilgisini gönderir; kapanınca dinlemeyi (kendisi başlattıysa) durdurur.
 Renkler sistem renkleridir (açık/koyu tema), yerleşim sağdan sola dillerde aynalanır, metinler Dynamic Type ile ölçeklenir
 ve tüm denetimler VoiceOver etiketlidir. Yükleniyor, hata (yeniden dene) ve boş (karşılama) durumları vardır.
 Objective-C'de `PZChatViewController` adıyla kullanılır.
 */
@objc(PZChatViewController)
public final class HSChatViewController: UIViewController, UITextViewDelegate, UIScrollViewDelegate, UIDocumentPickerDelegate, QLPreviewControllerDataSource {
    /// Başlıktaki kapat düğmesi (gömülü kullanımda kapatılabilir).
    @objc public var showsCloseButton = true {
        didSet { closeButton.isHidden = !showsCloseButton }
    }

    /// Kapat düğmesine basıldığında çağrılır; verilmezse ekran kendini kapatır (`dismiss`).
    @objc public var onClose: (() -> Void)?

    private let strings = HSChatStrings.forLanguage(Locale.preferredLanguages.first)
    private var config: HSChatConfig?
    private var messages: [HSChatMessage] = []
    private var agentLastReadSeq = 0
    private var readSeq = 0
    private var hasConversation = false
    private var hasMore = false
    private var loadingEarlier = false
    private var emailProvided = false
    private var resolved = false
    private var mode: HSChatUI.Mode = .conversation
    private var isVisible = false
    private var startedListening = false
    private var listenerToken: HSChatListenerToken?
    private var loadTask: Task<Void, Never>?
    private var typingHideWork: DispatchWorkItem?
    private var accent: UIColor = .systemBlue
    private var accentText: UIColor = .white
    private var previewURL: URL?

    private let header = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let stateStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stateLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let formScroll = UIScrollView()
    private let formStack = UIStackView()
    private let formInfo = UILabel()
    private let emailField = UITextField()
    private let nameField = UITextField()
    private let formMessage = UITextView()
    private let formError = UILabel()
    private let formButton = UIButton(type: .system)
    private let footer = UIStackView()
    private let typingLabel = UILabel()
    private let bannerLabel = UILabel()
    private let repliesStack = UIStackView()
    private let composer = UIStackView()
    private let attachButton = UIButton(type: .system)
    private let input = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private var inputHeight: NSLayoutConstraint?

    private enum Screen { case loading, error, conversation, form, thanks }

    public init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        loadTask?.cancel()
        if let listenerToken { Pushizo.Chat.removeListener(listenerToken) }
    }

    // MARK: Yaşam döngüsü

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildHeader()
        buildContent()
        buildForm()
        buildFooter()
        layout()
        listenerToken = Pushizo.Chat.addListener { [weak self] event in self?.handle(event) }
        show(.loading)
        reload()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        if mode == .conversation, config != nil { beginListening() }
        markReadIfNeeded()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        Pushizo.Chat.setTyping(false)
        // Dinlemeyi uygulama kendisi başlattıysa ona dokunulmaz.
        if startedListening {
            startedListening = false
            Pushizo.Chat.stopListening()
        }
    }

    // MARK: Kurulum

    private func label(_ style: UIFont.TextStyle, color: UIColor = .label, lines: Int = 0) -> UILabel {
        let l = UILabel()
        configure(l, style, color: color, lines: lines)
        return l
    }

    private func configure(_ l: UILabel, _ style: UIFont.TextStyle, color: UIColor, lines: Int = 0) {
        l.font = .preferredFont(forTextStyle: style)
        l.adjustsFontForContentSizeCategory = true
        l.textColor = color
        l.numberOfLines = lines
    }

    private func buildHeader() {
        header.backgroundColor = .secondarySystemBackground
        header.translatesAutoresizingMaskIntoConstraints = false
        configure(titleLabel, .headline, color: .label, lines: 1)
        titleLabel.text = strings.title
        titleLabel.accessibilityTraits = .header
        configure(statusLabel, .footnote, color: .secondaryLabel, lines: 1)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.accessibilityLabel = strings.close
        closeButton.tintColor = .label
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let titles = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        titles.axis = .vertical
        titles.spacing = 2
        titles.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titles)
        header.addSubview(closeButton)
        view.addSubview(header)
        NSLayoutConstraint.activate([
            titles.leadingAnchor.constraint(equalTo: header.layoutMarginsGuide.leadingAnchor),
            titles.topAnchor.constraint(equalTo: header.safeAreaLayoutGuide.topAnchor, constant: 12),
            titles.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            closeButton.trailingAnchor.constraint(equalTo: header.layoutMarginsGuide.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: titles.centerYAnchor),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func buildContent() {
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)

        spinner.hidesWhenStopped = true
        configure(stateLabel, .body, color: .secondaryLabel)
        stateLabel.textAlignment = .center
        retryButton.setTitle(strings.retry, for: .normal)
        retryButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        stateStack.axis = .vertical
        stateStack.alignment = .center
        stateStack.spacing = 12
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        [spinner, stateLabel, retryButton].forEach(stateStack.addArrangedSubview)
        view.addSubview(stateStack)
    }

    private func field(_ field: UITextField, placeholder: String, keyboard: UIKeyboardType, content: UITextContentType) {
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = keyboard
        field.textContentType = content
        field.autocapitalizationType = keyboard == .emailAddress ? .none : .words
        field.autocorrectionType = .no
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func buildForm() {
        formScroll.alwaysBounceVertical = true
        formScroll.keyboardDismissMode = .interactive
        formScroll.translatesAutoresizingMaskIntoConstraints = false
        formStack.axis = .vertical
        formStack.spacing = 12
        formStack.translatesAutoresizingMaskIntoConstraints = false
        configure(formInfo, .body, color: .label)
        field(emailField, placeholder: strings.email, keyboard: .emailAddress, content: .emailAddress)
        field(nameField, placeholder: strings.name, keyboard: .default, content: .name)
        formMessage.font = .preferredFont(forTextStyle: .body)
        formMessage.adjustsFontForContentSizeCategory = true
        formMessage.accessibilityLabel = strings.message
        formMessage.layer.borderColor = UIColor.separator.cgColor
        formMessage.layer.borderWidth = 1
        formMessage.layer.cornerRadius = 8
        formMessage.backgroundColor = .systemBackground
        formMessage.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        configure(formError, .footnote, color: .systemRed)
        formError.isHidden = true
        formButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        formButton.titleLabel?.adjustsFontForContentSizeCategory = true
        formButton.layer.cornerRadius = 10
        formButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        formButton.addTarget(self, action: #selector(formTapped), for: .touchUpInside)
        [formInfo, emailField, nameField, formMessage, formError, formButton].forEach(formStack.addArrangedSubview)
        formScroll.addSubview(formStack)
        view.addSubview(formScroll)
    }

    private func buildFooter() {
        footer.axis = .vertical
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false
        configure(typingLabel, .footnote, color: .secondaryLabel, lines: 1)
        typingLabel.isHidden = true
        configure(bannerLabel, .footnote, color: .systemRed)
        bannerLabel.isHidden = true
        repliesStack.axis = .vertical
        repliesStack.spacing = 6
        repliesStack.alignment = .leading
        repliesStack.isHidden = true

        attachButton.setImage(UIImage(systemName: "paperclip"), for: .normal)
        attachButton.accessibilityLabel = strings.attach
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        attachButton.isHidden = true
        input.delegate = self
        input.font = .preferredFont(forTextStyle: .body)
        input.adjustsFontForContentSizeCategory = true
        input.isScrollEnabled = false
        input.backgroundColor = .secondarySystemBackground
        input.layer.cornerRadius = 18
        input.textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        input.accessibilityLabel = strings.placeholder
        configure(placeholder, .body, color: .placeholderText, lines: 1)
        placeholder.text = strings.placeholder
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(placeholder)
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        sendButton.accessibilityLabel = strings.send
        sendButton.isEnabled = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        composer.axis = .horizontal
        composer.alignment = .bottom
        composer.spacing = 8
        [attachButton, input, sendButton].forEach(composer.addArrangedSubview)
        for button in [attachButton, sendButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        inputHeight = input.heightAnchor.constraint(lessThanOrEqualToConstant: 120)
        inputHeight?.isActive = true
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 15),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 9),
        ])
        [typingLabel, bannerLabel, repliesStack, composer].forEach(footer.addArrangedSubview)
        view.addSubview(footer)
        applyAccent()
    }

    private func layout() {
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            footer.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            // Klavye açılınca mesaj alanı onun üstünde kalır.
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            formScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            formScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formScroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            formStack.topAnchor.constraint(equalTo: formScroll.contentLayoutGuide.topAnchor, constant: 16),
            formStack.bottomAnchor.constraint(equalTo: formScroll.contentLayoutGuide.bottomAnchor, constant: -16),
            formStack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            stateStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateStack.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor),
            stateStack.trailingAnchor.constraint(lessThanOrEqualTo: margins.trailingAnchor),
        ])
    }

    private func applyAccent() {
        if let rgb = HSChatUI.rgb(config?.color) {
            accent = UIColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
            accentText = HSChatUI.needsLightText(red: rgb.red, green: rgb.green, blue: rgb.blue) ? .white : .black
        } else {
            accent = .systemBlue
            accentText = .white
        }
        sendButton.tintColor = accent
        attachButton.tintColor = accent
        retryButton.tintColor = accent
        formButton.backgroundColor = accent
        formButton.setTitleColor(accentText, for: .normal)
    }

    private func show(_ screen: Screen) {
        let conversation = screen == .conversation
        scroll.isHidden = !conversation
        footer.isHidden = !conversation
        formScroll.isHidden = !(screen == .form || screen == .thanks)
        stateStack.isHidden = !(screen == .loading || screen == .error)
        retryButton.isHidden = screen != .error
        stateLabel.isHidden = screen != .error
        if screen == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        if screen == .error {
            stateLabel.text = strings.error
            UIAccessibility.post(notification: .screenChanged, argument: stateLabel)
        }
        if screen == .thanks {
            formInfo.text = strings.thanks
            [emailField, nameField, formMessage, formError, formButton].forEach { $0.isHidden = true }
            UIAccessibility.post(notification: .screenChanged, argument: formInfo)
        }
    }

    // MARK: Yükleme

    private func reload() {
        loadTask?.cancel()
        show(.loading)
        loadTask = Task { @MainActor [weak self] in
            do {
                let config = try await Pushizo.Chat.getConfig(language: HSStrings.deviceLanguage)
                let state = try await Pushizo.Chat.getConversation()
                var page: HSChatMessagePage?
                if state.conversation != nil { page = try await Pushizo.Chat.getMessages() }
                guard let self, !Task.isCancelled else { return }
                self.apply(config: config, conversation: state.conversation, page: page)
            } catch is CancellationError {
                return
            } catch {
                HSLog.log(.warn, "sohbet yüklenemedi: \(error.localizedDescription)")
                guard let self, !Task.isCancelled else { return }
                self.show(.error)
            }
        }
    }

    private func apply(config: HSChatConfig, conversation: HSChatConversation?, page: HSChatMessagePage?) {
        self.config = config
        hasConversation = conversation != nil
        agentLastReadSeq = conversation?.agentLastReadSeq ?? 0
        readSeq = conversation?.visitorLastReadSeq ?? 0
        resolved = conversation?.status == "resolved"
        if let page {
            messages = HSChatTimeline.merge([], page.messages)
            hasMore = page.hasMore
        }
        titleLabel.text = config.title.flatMap { $0.isEmpty ? nil : $0 } ?? strings.title
        statusLabel.text = config.online ? strings.online : strings.offline
        attachButton.isHidden = !config.attachmentsEnabled
        applyAccent()
        updateMode()
    }

    private func updateMode() {
        guard let config else { return }
        mode = HSChatUI.mode(config: config, hasConversation: hasConversation, emailProvided: emailProvided)
        switch mode {
        case .conversation:
            show(.conversation)
            render(scrollToBottom: true)
            if isVisible { beginListening() }
            markReadIfNeeded()
        case .preChat:
            formInfo.text = strings.emailRequired
            formMessage.isHidden = true
            formButton.setTitle(strings.start, for: .normal)
            show(.form)
        case .offlineForm:
            formInfo.text = config.offlineMessage.flatMap { $0.isEmpty ? nil : $0 } ?? strings.offlineDefault
            formMessage.isHidden = false
            formButton.setTitle(strings.leave, for: .normal)
            show(.form)
        }
    }

    private func beginListening() {
        guard !Pushizo.Chat.isListening else { return }
        startedListening = true
        Pushizo.Chat.startListening()
    }

    private func loadEarlier() {
        guard hasMore, !loadingEarlier, let first = messages.first(where: { $0.seq > 0 }) else { return }
        loadingEarlier = true
        Task { @MainActor [weak self] in
            let page = try? await Pushizo.Chat.getMessages(beforeSeq: first.seq)
            guard let self else { return }
            self.loadingEarlier = false
            guard let page else { return }
            self.hasMore = page.hasMore
            self.messages = HSChatTimeline.merge(page.messages, self.messages)
            // Eski mesajlar üste eklenirken görünen konum korunur.
            let before = self.scroll.contentSize.height
            self.render(scrollToBottom: false)
            self.scroll.layoutIfNeeded()
            self.scroll.contentOffset.y += self.scroll.contentSize.height - before
        }
    }

    // MARK: Olaylar

    private func handle(_ event: HSChatEvent) {
        guard isViewLoaded, config != nil else { return }
        switch event {
        case let .message(message):
            let wasEmpty = !hasConversation
            hasConversation = true
            messages = HSChatTimeline.merge(messages, [message])
            if !message.isFromVisitor {
                setTyping(false, name: nil)
                resolved = false
                if isVisible { UIAccessibility.post(notification: .announcement, argument: HSChatUI.accessibilityLabel(message, strings: strings)) }
            }
            if wasEmpty, mode != .conversation { updateMode() } else if mode == .conversation { render(scrollToBottom: true) }
            markReadIfNeeded()
        case let .typing(typing, name):
            setTyping(typing, name: name)
        case let .agentRead(seq):
            guard seq > agentLastReadSeq else { return }
            agentLastReadSeq = seq
            if mode == .conversation { render(scrollToBottom: false) }
        case let .conversationUpdated(_, status, _):
            let isResolved = status == "resolved"
            guard isResolved != resolved else { return }
            resolved = isResolved
            if mode == .conversation { render(scrollToBottom: true) }
        case .connection(true):
            banner(nil)
        case .error:
            banner(strings.error)
        case .connection, .unreadCount:
            break
        }
    }

    private func setTyping(_ typing: Bool, name: String?) {
        typingHideWork?.cancel()
        typingLabel.isHidden = !typing
        guard typing else { return }
        typingLabel.text = strings.typing(name: name)
        // "Yazmayı bıraktı" olayı kaçarsa gösterge takılı kalmaz.
        let work = DispatchWorkItem { [weak self] in self?.typingLabel.isHidden = true }
        typingHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func banner(_ text: String?) {
        bannerLabel.text = text
        bannerLabel.isHidden = text == nil
        if let text { UIAccessibility.post(notification: .announcement, argument: text) }
    }

    private func markReadIfNeeded() {
        guard isVisible, mode == .conversation, let target = HSChatUI.readTarget(messages, alreadyRead: readSeq) else { return }
        readSeq = target
        Task { _ = try? await Pushizo.Chat.markRead(target) }
    }

    // MARK: Çizim

    private func render(scrollToBottom: Bool) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let greeting = config?.greeting, !greeting.isEmpty, !hasMore {
            stack.addArrangedSubview(bubble(text: greeting, attachments: [], sender: strings.bot, mine: false, status: nil, accessibility: "\(strings.bot): \(greeting)"))
        }
        let statusIndex = HSChatUI.statusIndex(messages)
        for (index, message) in messages.enumerated() {
            if message.sender == HSChatMessage.senderSystem {
                stack.addArrangedSubview(note(message.text ?? ""))
                continue
            }
            let status = index == statusIndex ? HSChatUI.statusText(message, agentLastReadSeq: agentLastReadSeq, strings: strings) : nil
            stack.addArrangedSubview(bubble(
                text: message.text, attachments: message.attachments, sender: HSChatUI.senderLabel(message, strings: strings),
                mine: message.isFromVisitor, status: status, accessibility: HSChatUI.accessibilityLabel(message, strings: strings)
            ))
        }
        if resolved { stack.addArrangedSubview(note(strings.resolved)) }
        renderReplies()
        guard scrollToBottom else { return }
        scroll.layoutIfNeeded()
        let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }

    private func note(_ text: String) -> UIView {
        let l = label(.footnote, color: .secondaryLabel)
        l.text = text
        l.textAlignment = .center
        return l
    }

    private func bubble(text: String?, attachments: [HSChatAttachment], sender: String?, mine: Bool, status: String?, accessibility: String) -> UIView {
        let row = UIView()
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 2
        column.alignment = mine ? .trailing : .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)

        if let sender {
            let name = label(.caption1, color: .secondaryLabel, lines: 1)
            name.text = sender
            name.isAccessibilityElement = false
            column.addArrangedSubview(name)
        }
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 6
        box.isLayoutMarginsRelativeArrangement = true
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        let background = UIView()
        background.backgroundColor = mine ? accent : .secondarySystemBackground
        background.layer.cornerRadius = 16
        background.translatesAutoresizingMaskIntoConstraints = false
        box.insertSubview(background, at: 0)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: box.topAnchor),
            background.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        if let text, !text.isEmpty {
            let body = label(.body, color: mine ? accentText : .label)
            body.text = text
            body.isAccessibilityElement = true
            body.accessibilityLabel = accessibility
            box.addArrangedSubview(body)
        }
        for attachment in attachments {
            let button = AttachmentButton(type: .system)
            button.attachment = attachment
            button.setImage(UIImage(systemName: "paperclip"), for: .normal)
            button.setTitle(" " + attachment.name, for: .normal)
            button.tintColor = mine ? accentText : accent
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.contentHorizontalAlignment = .leading
            button.accessibilityLabel = "\(strings.download): \(attachment.name)"
            button.addTarget(self, action: #selector(attachmentTapped(_:)), for: .touchUpInside)
            box.addArrangedSubview(button)
        }
        column.addArrangedSubview(box)
        if let status {
            let state = label(.caption2, color: .secondaryLabel, lines: 1)
            state.text = status
            column.addArrangedSubview(state)
        }
        let side = mine ? column.trailingAnchor.constraint(equalTo: row.trailingAnchor) : column.leadingAnchor.constraint(equalTo: row.leadingAnchor)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: row.topAnchor),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.82),
            side,
        ])
        return row
    }

    private func renderReplies() {
        repliesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let replies = HSChatUI.quickReplies(messages)
        repliesStack.isHidden = replies.isEmpty
        for reply in replies {
            let button = ReplyButton(type: .system)
            button.reply = reply
            var configuration = UIButton.Configuration.plain()
            configuration.title = reply.label
            configuration.baseForegroundColor = accent
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            configuration.background.strokeColor = accent
            configuration.background.strokeWidth = 1
            configuration.background.cornerRadius = 16
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var updated = attributes
                updated.font = .preferredFont(forTextStyle: .callout)
                return updated
            }
            button.configuration = configuration
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addTarget(self, action: #selector(replyTapped(_:)), for: .touchUpInside)
            repliesStack.addArrangedSubview(button)
        }
    }

    // MARK: Eylemler

    @objc private func closeTapped() {
        if let onClose { onClose() } else { dismiss(animated: true) }
    }

    @objc private func retryTapped() { reload() }

    @objc private func sendTapped() {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.text = ""
        textViewDidChange(input)
        send(text, optionId: nil, restore: true)
    }

    @objc private func replyTapped(_ sender: ReplyButton) {
        guard let reply = sender.reply else { return }
        repliesStack.isHidden = true
        send(reply.label, optionId: reply.id, restore: false)
    }

    private func send(_ text: String, optionId: String?, restore: Bool) {
        banner(nil)
        Pushizo.Chat.setTyping(false)
        Task { @MainActor [weak self] in
            do {
                let message = try await Pushizo.Chat.sendMessage(text, optionId: optionId)
                guard let self else { return }
                self.hasConversation = true
                self.messages = HSChatTimeline.merge(self.messages, [message])
                self.render(scrollToBottom: true)
                if self.isVisible { self.beginListening() }
            } catch {
                HSLog.log(.warn, "sohbet mesajı gönderilemedi: \(error.localizedDescription)")
                guard let self else { return }
                self.banner(self.strings.error)
                if restore, self.input.text.isEmpty {
                    self.input.text = text
                    self.textViewDidChange(self.input)
                } else {
                    self.renderReplies()
                }
            }
        }
    }

    @objc private func attachTapped() {
        var types: [UTType] = [.png, .jpeg, .gif, .pdf, .plainText]
        if let webp = UTType("org.webmproject.webp") { types.append(webp) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let config else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        switch HSChatUI.checkAttachment(fileName: url.lastPathComponent, size: size, config: config) {
        case .tooLarge:
            banner(strings.tooLarge(maxBytes: min(config.attachmentMaxBytes > 0 ? config.attachmentMaxBytes : HSChatLimits.maxAttachmentBytes, HSChatLimits.maxAttachmentBytes)))
        case .unsupported:
            banner(strings.error)
        case let .ok(mimeType):
            banner(nil)
            Task { @MainActor [weak self] in
                do {
                    let message = try await Pushizo.Chat.sendAttachment(fileURL: url, mimeType: mimeType)
                    guard let self else { return }
                    self.hasConversation = true
                    self.messages = HSChatTimeline.merge(self.messages, [message])
                    self.render(scrollToBottom: true)
                    if self.isVisible { self.beginListening() }
                } catch {
                    HSLog.log(.warn, "sohbet eki gönderilemedi: \(error.localizedDescription)")
                    guard let self else { return }
                    self.banner(self.strings.error)
                }
            }
        }
    }

    /// Ek uygulama içinde indirilip önizlenir: adres ziyaretçi belirtecini taşıdığından tarayıcıya verilmez.
    @objc private func attachmentTapped(_ sender: AttachmentButton) {
        guard let attachment = sender.attachment, let url = try? Pushizo.Chat.attachmentUrl(attachment.id) else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            defer { sender?.isEnabled = true }
            do {
                let (file, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HSError.invalidResponse }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pushizo-chat-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Dosya adı yalnızca son yol bileşenidir (dizin geçişi olmaz).
                let name = (attachment.name as NSString).lastPathComponent
                let target = folder.appendingPathComponent(name.isEmpty ? attachment.id : name)
                try FileManager.default.moveItem(at: file, to: target)
                guard let self else { return }
                self.previewURL = target
                let preview = QLPreviewController()
                preview.dataSource = self
                self.present(preview, animated: true)
            } catch {
                HSLog.log(.warn, "sohbet eki açılamadı: \(error.localizedDescription)")
                self?.banner(self?.strings.error)
            }
        }
    }

    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }

    public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "/dev/null")) as NSURL
    }

    @objc private func formTapped() {
        let email = emailField.text ?? ""
        guard HSContacts.normalizeEmail(email) != nil else {
            formFailed(strings.invalidEmail)
            return
        }
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = formMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let offline = mode == .offlineForm
        if offline, text.isEmpty {
            formFailed(strings.message)
            return
        }
        formError.isHidden = true
        formButton.isEnabled = false
        view.endEditing(true)
        Task { @MainActor [weak self] in
            do {
                if offline {
                    _ = try await Pushizo.Chat.leaveOfflineMessage(email: email, text: text, name: name.isEmpty ? nil : name)
                } else {
                    _ = try await Pushizo.Chat.start(name: name.isEmpty ? nil : name, email: email)
                }
                guard let self else { return }
                self.formButton.isEnabled = true
                if offline {
                    self.show(.thanks)
                } else {
                    self.emailProvided = true
                    self.updateMode()
                }
            } catch {
                HSLog.log(.warn, "sohbet formu gönderilemedi: \(error.localizedDescription)")
                guard let self else { return }
                self.formButton.isEnabled = true
                self.formFailed(self.strings.error)
            }
        }
    }

    private func formFailed(_ text: String) {
        formError.text = text
        formError.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: Delegeler

    public func textViewDidChange(_ textView: UITextView) {
        guard textView === input else { return }
        let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        sendButton.isEnabled = !empty
        // En fazla yükseklikten sonra metin alanı kendi içinde kayar.
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        textView.isScrollEnabled = fitting > (inputHeight?.constant ?? 120)
        Pushizo.Chat.setTyping(!empty)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === scroll, scrollView.isDragging, scrollView.contentOffset.y < 40 else { return }
        loadEarlier()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Katman kenarlık renkleri dinamik değildir; tema değişince yeniden çözülür.
        formMessage.layer.borderColor = UIColor.separator.cgColor
    }
}

private final class AttachmentButton: UIButton {
    var attachment: HSChatAttachment?
}

private final class ReplyButton: UIButton {
    var reply: HSChatQuickReply?
}

extension Pushizo.Chat {
    private static weak var presented: HSChatViewController?

    /**
     Hazır sohbet ekranını modal olarak açar (`HSChatViewController`). `presenter` verilmezse etkin sahnenin en üstteki
     görünüm denetleyicisi kullanılır. Ekran zaten açıksa yeniden açılmaz. Herhangi bir iş parçacığından çağrılabilir.
     */
    public static func show(from presenter: UIViewController? = nil, animated: Bool = true) {
        let present = {
            guard presented?.presentingViewController == nil, let host = presenter ?? topViewController() else {
                if presented == nil { HSLog.log(.warn, "Chat.show: sunum yapılacak görünüm denetleyicisi bulunamadı") }
                return
            }
            let controller = HSChatViewController()
            presented = controller
            host.present(controller, animated: animated)
        }
        if Thread.isMainThread { present() } else { DispatchQueue.main.async(execute: present) }
    }

    /// `show` ile açılan sohbet ekranını kapatır (açık değilse hiçbir şey yapmaz).
    public static func hide(animated: Bool = true) {
        let dismiss: () -> Void = { presented?.dismiss(animated: animated) }
        if Thread.isMainThread { dismiss() } else { DispatchQueue.main.async(execute: dismiss) }
    }

    /// `show` ile açılan sohbet ekranı şu an görünüyor mu.
    public static var isPresented: Bool { presented?.presentingViewController != nil }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// `HSChatViewController` için SwiftUI sarmalayıcısı: `.sheet(isPresented: $open) { HSChatView { open = false } }`.
public struct HSChatView: UIViewControllerRepresentable {
    private let onClose: (() -> Void)?

    /// `onClose` verilmezse kapat düğmesi gizlenir (gezinme yığınına gömülü kullanım).
    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    public func makeUIViewController(context: Context) -> HSChatViewController {
        let controller = HSChatViewController()
        controller.showsCloseButton = onClose != nil
        controller.onClose = onClose
        return controller
    }

    public func updateUIViewController(_ controller: HSChatViewController, context: Context) {
        controller.onClose = onClose
    }
}
#endif
#endif
