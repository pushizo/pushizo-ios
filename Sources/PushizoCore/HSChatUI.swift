import Foundation

/// Hazır sohbet arayüzü metinleri (22 dil, `HSStrings`; dil verilmezse cihaz dili).
public struct HSChatStrings: Equatable {
    public let title: String
    public let close: String
    public let online: String
    public let offline: String
    public let placeholder: String
    public let send: String
    public let attach: String
    public let typing: String
    public let read: String
    public let delivered: String
    public let sent: String
    public let sending: String
    public let retry: String
    public let bot: String
    public let agent: String
    public let you: String
    public let offlineDefault: String
    public let email: String
    public let name: String
    public let message: String
    public let leave: String
    public let thanks: String
    public let start: String
    public let emailRequired: String
    public let invalidEmail: String
    public let tooLarge: String
    public let error: String
    public let download: String
    public let resolved: String

    public static func forLanguage(_ language: String?) -> HSChatStrings {
        let code = language.map(HSStrings.resolve) ?? HSStrings.deviceLanguage
        func t(_ key: String) -> String { HSStrings.text("chat_" + key, language: code) }
        return HSChatStrings(
            title: t("title"), close: t("close"), online: t("online"), offline: t("offline"), placeholder: t("placeholder"),
            send: t("send"), attach: t("attach"), typing: t("typing"), read: t("read"), delivered: t("delivered"), sent: t("sent"),
            sending: t("sending"), retry: t("retry"), bot: t("bot"), agent: t("agent"), you: t("you"),
            offlineDefault: t("offline_default"), email: t("email"), name: t("name"), message: t("message"), leave: t("leave"),
            thanks: t("thanks"), start: t("start"), emailRequired: t("email_required"), invalidEmail: t("invalid_email"),
            tooLarge: t("too_large"), error: t("error"), download: t("download"), resolved: t("resolved")
        )
    }

    /// "{name} yazıyor…": ad yoksa "Temsilci".
    public func typing(name: String?) -> String {
        let who = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return typing.replacingOccurrences(of: "{name}", with: who.isEmpty ? agent : who)
    }

    /// Ek boyutu sınırı metni (MB tam sayıya yuvarlanır, en az 1).
    public func tooLarge(maxBytes: Int) -> String {
        tooLarge.replacingOccurrences(of: "{mb}", with: String(max(1, maxBytes / (1024 * 1024))))
    }
}

/// Hazır sohbet arayüzünün saf kuralları (`HSChatViewController`; birim testli).
public enum HSChatUI {
    /// Arayüzün gösterdiği ekran.
    public enum Mode: Equatable {
        /// Sohbet akışı ve mesaj alanı.
        case conversation
        /// Sohbet başlamadan önce e-posta (ve ad) istenir.
        case preChat
        /// Çevrimdışı: e-postayla mesaj bırakma formu.
        case offlineForm
    }

    /**
     Gösterilecek ekran. Süren bir konuşma varsa her zaman akış. Yoksa: çevrimdışıyken e-posta toplanıyorsa çevrimdışı
     formu; e-posta zorunluysa ve henüz verilmediyse ön form; aksi hâlde akış.
     */
    public static func mode(config: HSChatConfig, hasConversation: Bool, emailProvided: Bool) -> Mode {
        if hasConversation { return .conversation }
        if !config.online && config.collectEmailOffline { return .offlineForm }
        if config.requireEmail && !emailProvided { return .preChat }
        return .conversation
    }

    /// Yalnız `#rrggbb` kabul edilir; kırmızı/yeşil/mavi 0-255. Geçersizse nil (varsayılan vurgu rengi kullanılır).
    public static func rgb(_ hex: String?) -> (red: Int, green: Int, blue: Int)? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        guard hex.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// Vurgu rengi üzerinde okunaklı metin için açık renk mi gerekir (göreli parlaklık, WCAG).
    public static func needsLightText(red: Int, green: Int, blue: Int) -> Bool {
        func channel(_ v: Int) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        return luminance < 0.5
    }

    /// Durum etiketinin gösterileceği mesaj: listedeki son ziyaretçi mesajı (yoksa nil).
    public static func statusIndex(_ messages: [HSChatMessage]) -> Int? {
        messages.lastIndex(where: \.isFromVisitor)
    }

    /// Ziyaretçi mesajının durum metni; temsilcinin okuma işaretçisi mesajı kapsıyorsa "okundu".
    public static func statusText(_ message: HSChatMessage, agentLastReadSeq: Int, strings: HSChatStrings) -> String {
        if message.seq <= 0 || message.status == HSChatMessage.statusPending { return strings.sending }
        if message.status == HSChatMessage.statusRead || message.seq <= agentLastReadSeq { return strings.read }
        if message.status == HSChatMessage.statusDelivered { return strings.delivered }
        return strings.sent
    }

    /// Balonun üstündeki gönderen adı: ziyaretçi ve sistem mesajında yok; temsilci/bot için ad ya da varsayılan etiket.
    public static func senderLabel(_ message: HSChatMessage, strings: HSChatStrings) -> String? {
        switch message.sender {
        case HSChatMessage.senderAgent: return nonEmpty(message.authorName) ?? strings.agent
        case HSChatMessage.senderBot: return nonEmpty(message.authorName) ?? strings.bot
        default: return nil
        }
    }

    /// VoiceOver etiketi: "Gönderen: metin" (ekler adlarıyla).
    public static func accessibilityLabel(_ message: HSChatMessage, strings: HSChatStrings) -> String {
        let who = message.isFromVisitor ? strings.you : (senderLabel(message, strings: strings) ?? "")
        let parts = [nonEmpty(message.text)].compactMap { $0 } + message.attachments.map(\.name)
        let body = parts.joined(separator: ", ")
        return who.isEmpty ? body : "\(who): \(body)"
    }

    /// Hızlı yanıt düğmeleri yalnız listenin son mesajı bot sorusuysa gösterilir (yanıtlanan soru yeniden sorulmaz).
    public static func quickReplies(_ messages: [HSChatMessage]) -> [HSChatQuickReply] {
        guard let last = messages.last, !last.isFromVisitor else { return [] }
        return last.quickReplies ?? []
    }

    /// Okundu işaretlenecek sıra: karşı tarafın (temsilci/bot/sistem) en büyük sırası, `alreadyRead`'den büyükse.
    public static func readTarget(_ messages: [HSChatMessage], alreadyRead: Int) -> Int? {
        guard let top = messages.filter({ !$0.isFromVisitor }).map(\.seq).max(), top > alreadyRead else { return nil }
        return top
    }

    /// Dosya uzantısından sunucunun kabul ettiği MIME türü; desteklenmiyorsa nil.
    public static func mimeType(fileName: String) -> String? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        default: return nil
        }
    }

    /// Ek gönderilebilir mi: tür app ayarında ve sunucu listesinde, boyut sınır içinde.
    public enum AttachmentCheck: Equatable { case ok(mimeType: String), unsupported, tooLarge }

    public static func checkAttachment(fileName: String, size: Int, config: HSChatConfig) -> AttachmentCheck {
        guard let mime = mimeType(fileName: fileName), HSChatLimits.attachmentTypes.contains(mime) else { return .unsupported }
        if !config.attachmentTypes.isEmpty, !config.attachmentTypes.contains(mime) { return .unsupported }
        let limit = min(config.attachmentMaxBytes > 0 ? config.attachmentMaxBytes : HSChatLimits.maxAttachmentBytes, HSChatLimits.maxAttachmentBytes)
        return size > limit ? .tooLarge : .ok(mimeType: mime)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
