import CommonCrypto
import Foundation
import Security

// MARK: - Modeller

/// Köprü sözlüklerinde boş değer: `NSNull` (JSON `null`).
func hsOrNull(_ value: Any?) -> Any { value ?? NSNull() }

/// Zaman → epoch milisaniye (yoksa `NSNull`).
func hsMillis(_ date: Date?) -> Any { hsOrNull(date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }) }

/// Sohbet mesajı eki (`GET chat/attachments/{id}`; bkz. `Pushizo.Chat.attachmentUrl`).
public struct HSChatAttachment: Equatable {
    public let id: String
    public let name: String
    public let type: String
    public let size: Int

    public init(id: String, name: String, type: String, size: Int) {
        self.id = id
        self.name = name
        self.type = type
        self.size = size
    }

    public var dictionary: [String: Any] { ["id": id, "name": name, "type": type, "size": size] }
}

/// Bot sorusunun hızlı yanıt seçeneği; seçildiğinde `sendMessage(_:optionId:)` ile gönderilir.
public struct HSChatQuickReply: Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    public var dictionary: [String: Any] { ["id": id, "label": label] }
}

/**
 Sohbet mesajı (ADR-0040 §3). `seq` konuşma içi sunucu sıra numarasıdır; çevrimdışı kuyrukta bekleyen yerel mesajda 0'dır
 ve `status` `pending` olur.
 */
public struct HSChatMessage: Equatable {
    public static let senderVisitor = "visitor"
    public static let senderAgent = "agent"
    public static let senderBot = "bot"
    public static let senderSystem = "system"
    public static let statusPending = "pending"
    public static let statusSent = "sent"
    public static let statusDelivered = "delivered"
    public static let statusRead = "read"

    /// Sunucu kimliği; bekleyen yerel mesajda nil.
    public let id: String?
    public let seq: Int
    public let clientMessageId: String?
    /// `visitor`, `agent`, `bot` veya `system`.
    public let sender: String
    public let authorName: String?
    public let text: String?
    public let attachments: [HSChatAttachment]
    /// Bot sorusunun seçenekleri (yoksa nil).
    public let quickReplies: [HSChatQuickReply]?
    /// `pending` (yerel), `sent`, `delivered` veya `read`.
    public let status: String
    public let createdAt: Date?

    public init(id: String?, seq: Int, clientMessageId: String?, sender: String, authorName: String?, text: String?,
                attachments: [HSChatAttachment], quickReplies: [HSChatQuickReply]?, status: String, createdAt: Date?) {
        self.id = id
        self.seq = seq
        self.clientMessageId = clientMessageId
        self.sender = sender
        self.authorName = authorName
        self.text = text
        self.attachments = attachments
        self.quickReplies = quickReplies
        self.status = status
        self.createdAt = createdAt
    }

    /// Ziyaretçinin kendi mesajı mı.
    public var isFromVisitor: Bool { sender == HSChatMessage.senderVisitor }

    /// Köprüler için sözlük (camelCase; boş değerler `NSNull`, zaman epoch milisaniye).
    public var dictionary: [String: Any] {
        [
            "id": hsOrNull(id),
            "seq": seq,
            "clientMessageId": hsOrNull(clientMessageId),
            "sender": sender,
            "authorName": hsOrNull(authorName),
            "text": hsOrNull(text),
            "attachments": attachments.map(\.dictionary),
            "quickReplies": hsOrNull(quickReplies.map { $0.map(\.dictionary) }),
            "status": status,
            "createdAt": hsMillis(createdAt),
        ] as [String: Any]
    }
}

/// Ziyaretçinin konuşması (`open`, `pending`, `resolved`; eski kayıtlarda `closed`).
public struct HSChatConversation: Equatable {
    public let id: String
    public let status: String
    public let lastSeq: Int
    /// Temsilcinin okuduğu son sıra (ziyaretçi mesajlarında "okundu").
    public let agentLastReadSeq: Int
    public let visitorLastReadSeq: Int
    public let unreadCount: Int
    public let botActive: Bool
    public let assigneeName: String?
    public let createdAt: Date?

    public var dictionary: [String: Any] {
        [
            "id": id, "status": status, "lastSeq": lastSeq, "agentLastReadSeq": agentLastReadSeq,
            "visitorLastReadSeq": visitorLastReadSeq, "unreadCount": unreadCount, "botActive": botActive,
            "assigneeName": hsOrNull(assigneeName),
            "createdAt": hsMillis(createdAt),
        ] as [String: Any]
    }
}

/// `GET chat/conversation`: konuşma (henüz yoksa nil) ve okunmamış sayısı.
public struct HSChatConversationState: Equatable {
    public let conversation: HSChatConversation?
    public let unreadCount: Int

    public var dictionary: [String: Any] { ["conversation": hsOrNull(conversation?.dictionary), "unreadCount": unreadCount] }
}

/// Mesaj sayfası (kronolojik).
public struct HSChatMessagePage: Equatable {
    public let messages: [HSChatMessage]
    public let hasMore: Bool

    public var dictionary: [String: Any] { ["messages": messages.map(\.dictionary), "hasMore": hasMore] }
}

/// `chat/identify` sonucu.
public struct HSChatIdentifyResult: Equatable {
    public let userId: String?
    public let conversation: HSChatConversation?

    public var dictionary: [String: Any] { ["userId": hsOrNull(userId), "conversation": hsOrNull(conversation?.dictionary)] }
}

/// Sohbet widget ayarları ve çevrimiçi durumu (`GET chat/config`).
public struct HSChatConfig: Equatable {
    public let enabled: Bool
    /// Çalışma saatleri içinde ve en az bir temsilci (veya bot) çevrimiçi.
    public let online: Bool
    public let withinBusinessHours: Bool
    public let color: String?
    public let textColor: String?
    public let position: String
    public let theme: String
    public let title: String?
    public let greeting: String?
    /// Çevrimdışıyken gösterilecek metin; çevrimdışı mesaj için `leaveOfflineMessage`.
    public let offlineMessage: String?
    public let collectEmailOffline: Bool
    public let requireEmail: Bool
    public let attachmentsEnabled: Bool
    public let attachmentMaxBytes: Int
    public let attachmentTypes: [String]
    public let language: String

    public var dictionary: [String: Any] {
        [
            "enabled": enabled, "online": online, "withinBusinessHours": withinBusinessHours,
            "color": hsOrNull(color), "textColor": hsOrNull(textColor), "position": position, "theme": theme,
            "title": hsOrNull(title), "greeting": hsOrNull(greeting), "offlineMessage": hsOrNull(offlineMessage),
            "collectEmailOffline": collectEmailOffline, "requireEmail": requireEmail, "attachmentsEnabled": attachmentsEnabled,
            "attachmentMaxBytes": attachmentMaxBytes, "attachmentTypes": attachmentTypes, "language": language,
        ] as [String: Any]
    }
}

/// Push bildirimindeki sohbet işareti (`pushizo_chat`).
public struct HSChatPushInfo: Equatable {
    public let conversationId: String
    public let seq: Int

    public init(conversationId: String, seq: Int) {
        self.conversationId = conversationId
        self.seq = seq
    }

    public var dictionary: [String: Any] { ["conversationId": conversationId, "seq": seq] }
}

/**
 Sohbet olayları (dinleyiciler ana iş parçacığında çağrılır). Köprüler `type` + `payload` ile iletir:
 `message`, `typing`, `read`, `unread`, `conversation`, `connection`, `error`.
 */
public enum HSChatEvent {
    /// Yeni mesaj (temsilci, bot, sistem veya bu cihazdan gönderilen; bekleyen yerel mesaj `pending`).
    case message(HSChatMessage)
    /// Temsilci yazıyor göstergesi.
    case typing(Bool, name: String?)
    /// Temsilci bu sıra numarasına kadar ziyaretçi mesajlarını okudu.
    case agentRead(Int)
    /// Okunmamış (temsilci/bot) mesaj sayısı değişti.
    case unreadCount(Int)
    /// Konuşma durumu değişti.
    case conversationUpdated(id: String, status: String, botActive: Bool)
    /// Canlı akış bağlandı/koptu (koparsa SDK yeniden bağlanır).
    case connection(Bool)
    /// Kalıcı hata (ör. `HS_PLAN_FEATURE_REQUIRED`); dinleme durdu.
    case error(code: String, message: String?)

    public var type: String {
        switch self {
        case .message: return "message"
        case .typing: return "typing"
        case .agentRead: return "read"
        case .unreadCount: return "unread"
        case .conversationUpdated: return "conversation"
        case .connection: return "connection"
        case .error: return "error"
        }
    }

    public var payload: [String: Any] {
        switch self {
        case let .message(m): return ["message": m.dictionary]
        case let .typing(typing, name): return ["typing": typing, "name": hsOrNull(name)]
        case let .agentRead(seq): return ["seq": seq]
        case let .unreadCount(count): return ["count": count]
        case let .conversationUpdated(id, status, botActive): return ["conversationId": id, "status": status, "botActive": botActive]
        case let .connection(connected): return ["connected": connected]
        case let .error(code, message): return ["code": code, "message": hsOrNull(message)]
        }
    }
}

// MARK: - Ayrıştırma

/// Sunucu yanıtlarının ayrıştırıcısı (`apps/api/src/live-chat/chat.dto.ts`).
public enum HSChatParser {
    static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    static func date(_ value: Any?) -> Date? { HSInAppParser.nonEmpty(value).flatMap(HSIsoTime.parse) }

    public static func message(_ json: [String: Any]) -> HSChatMessage {
        HSChatMessage(
            id: HSInAppParser.nonEmpty(json["id"]),
            seq: int(json["seq"]),
            clientMessageId: HSInAppParser.nonEmpty(json["client_message_id"]),
            sender: HSInAppParser.nonEmpty(json["sender"]) ?? HSChatMessage.senderSystem,
            authorName: HSInAppParser.nonEmpty(json["author_name"]),
            text: HSInAppParser.nonEmpty(json["text"]),
            attachments: (json["attachments"] as? [[String: Any]] ?? []).map {
                HSChatAttachment(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", type: $0["type"] as? String ?? "", size: int($0["size"]))
            },
            quickReplies: (json["quick_replies"] as? [[String: Any]])?.map {
                HSChatQuickReply(id: $0["id"] as? String ?? "", label: $0["label"] as? String ?? "")
            },
            status: HSInAppParser.nonEmpty(json["status"]) ?? HSChatMessage.statusSent,
            createdAt: date(json["created_at"])
        )
    }

    public static func conversation(_ json: Any?) -> HSChatConversation? {
        guard let json = json as? [String: Any], let id = HSInAppParser.nonEmpty(json["id"]) else { return nil }
        return HSChatConversation(
            id: id,
            status: HSInAppParser.nonEmpty(json["status"]) ?? "open",
            lastSeq: int(json["last_seq"]),
            agentLastReadSeq: int(json["agent_last_read_seq"]),
            visitorLastReadSeq: int(json["visitor_last_read_seq"]),
            unreadCount: int(json["unread_count"]),
            botActive: json["bot_active"] as? Bool ?? false,
            assigneeName: HSInAppParser.nonEmpty(json["assignee_name"]),
            createdAt: date(json["created_at"])
        )
    }

    public static func conversationState(_ json: [String: Any]) -> HSChatConversationState {
        let conversation = conversation(json["conversation"])
        let unread = (json["unread_count"] as? NSNumber)?.intValue ?? conversation?.unreadCount ?? 0
        return HSChatConversationState(conversation: conversation, unreadCount: unread)
    }

    public static func page(_ json: [String: Any]) -> HSChatMessagePage {
        let messages = (json["data"] as? [[String: Any]] ?? []).map(message).sorted { $0.seq < $1.seq }
        return HSChatMessagePage(messages: messages, hasMore: json["has_more"] as? Bool ?? false)
    }

    public static func identify(_ json: [String: Any]) -> HSChatIdentifyResult {
        HSChatIdentifyResult(userId: HSInAppParser.nonEmpty(json["user_id"]), conversation: conversation(json["conversation"]))
    }

    public static func config(_ json: [String: Any]) -> HSChatConfig {
        let attachments = json["attachments"] as? [String: Any]
        return HSChatConfig(
            enabled: json["enabled"] as? Bool ?? false,
            online: json["online"] as? Bool ?? false,
            withinBusinessHours: json["within_business_hours"] as? Bool ?? false,
            color: HSInAppParser.nonEmpty(json["color"]),
            textColor: HSInAppParser.nonEmpty(json["text_color"]),
            position: HSInAppParser.nonEmpty(json["position"]) ?? "right",
            theme: HSInAppParser.nonEmpty(json["theme"]) ?? "auto",
            title: HSInAppParser.nonEmpty(json["title"]),
            greeting: HSInAppParser.nonEmpty(json["greeting"]),
            offlineMessage: HSInAppParser.nonEmpty(json["offline_message"]),
            collectEmailOffline: json["collect_email_offline"] as? Bool ?? false,
            requireEmail: json["require_email"] as? Bool ?? false,
            attachmentsEnabled: attachments?["enabled"] as? Bool ?? false,
            attachmentMaxBytes: (attachments?["max_bytes"] as? NSNumber)?.intValue ?? HSChatLimits.maxAttachmentBytes,
            attachmentTypes: attachments?["types"] as? [String] ?? [],
            language: HSInAppParser.nonEmpty(json["language"]) ?? "en"
        )
    }
}

// MARK: - Sınırlar ve kimlik

/// Sohbet sınırları (sunucudaki `CHAT_LIMITS` ile aynı).
public enum HSChatLimits {
    public static let maxText = 4000
    public static let maxAttachmentBytes = 10 * 1024 * 1024
    /// Sunucunun kabul ettiği ek türleri (sihirli bayt ile ayrıca doğrulanır).
    public static let attachmentTypes: Set<String> = ["image/png", "image/jpeg", "image/webp", "image/gif", "application/pdf", "text/plain"]

    static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isVisitorId(_ value: String) -> Bool { matches(value, pattern: "^[A-Za-z0-9_-]{16,64}$") }
    public static func isVisitorToken(_ value: String) -> Bool { matches(value, pattern: "^[A-Za-z0-9_-]{32,128}$") }
    public static func isClientMessageId(_ value: String) -> Bool { matches(value, pattern: "^[A-Za-z0-9_.:-]{8,64}$") }
}

/// Sohbet ziyaretçi durumunun kalıcı deposu (`HSStorage`; testlerde bellek içi).
public protocol HSChatState: AnyObject {
    var chatVisitorId: String? { get set }
    var chatVisitorToken: String? { get set }
    var chatEnabled: Bool { get set }
    var chatIdentifyKey: String? { get set }
    var chatLastSeq: Int { get set }
    var chatDeliveredSeq: Int { get set }
    var chatUnreadCount: Int { get set }
    func clearChatVisitor()
}

extension HSStorage: HSChatState {}

/**
 Ziyaretçi kimliği (ADR-0040 §2): ilk kullanımda rastgele 32 karakterlik `visitor_id` ve 64 karakterlik gizli
 `visitor_token` (`[A-Za-z0-9_-]`, `SecRandomCopyBytes`). GET uçlarında `visitor_id` + `token` sorgusu, gövdeli uçlarda
 `visitor_token`.
 */
public struct HSChatVisitor: Equatable {
    public let id: String
    public let token: String

    public init(id: String, token: String) {
        self.id = id
        self.token = token
    }

    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let lock = NSLock()

    /// Kriptografik rastgele dizi (64 karakterlik alfabe; bayt başına alt 6 bit — eşit dağılımlı).
    public static func randomString(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            // Sistem rastgele kaynağı başarısızsa Swift'in kriptografik üreticisi (SystemRandomNumberGenerator).
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        return String(bytes.map { alphabet[Int($0 & 0x3F)] })
    }

    /// Kayıtlı ve biçimi geçerli kimlik varsa onu, yoksa yenisini üretip saklar.
    public static func ensure(_ state: HSChatState) -> HSChatVisitor {
        lock.lock(); defer { lock.unlock() }
        if let id = state.chatVisitorId, let token = state.chatVisitorToken,
           HSChatLimits.isVisitorId(id), HSChatLimits.isVisitorToken(token) {
            return HSChatVisitor(id: id, token: token)
        }
        state.clearChatVisitor()
        let visitor = HSChatVisitor(id: randomString(32), token: randomString(64))
        state.chatVisitorId = visitor.id
        state.chatVisitorToken = visitor.token
        return visitor
    }

    /// İstemci mesaj kimliği; yeniden denemelerde aynı kimlik kullanılır (sunucu tekilleştirir).
    public static func newClientMessageId() -> String { "m_" + randomString(24) }

    public func auth(_ body: [String: Any] = [:]) -> [String: Any] {
        var out = body
        out["visitor_id"] = id
        out["visitor_token"] = token
        return out
    }

    /// GET sorgusu (başında `?` yok); nil değerler atlanır.
    public func query(_ params: [(String, Any?)] = []) -> String {
        ([("visitor_id", id as Any?), ("token", token as Any?)] + params).compactMap { key, value -> String? in
            guard let value else { return nil }
            return "\(key)=\(HSChatVisitor.encode("\(value)"))"
        }.joined(separator: "&")
    }

    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()

    public static func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value }
}

// MARK: - İstek gövdeleri

public enum HSChatRequests {
    private static func clean(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    /**
     `POST chat/identify`: kullanıcı (`external_id` + login'deki `identity_hash`; JWT başlıkta) ve push aboneliği
     bağlama. Abonelik yalnızca sahiplik kanıtıyla (`token_hash`, ADR-0016) gönderilir.
     */
    public static func identifyBody(visitor: HSChatVisitor, externalId: String?, identityHash: String?, subscriptionId: String?,
                                    registeredToken: String?, name: String?, email: String?, language: String?) -> [String: Any] {
        var body = visitor.auth()
        if let ext = clean(externalId) {
            body["external_id"] = ext
            if let hash = clean(identityHash) { body["identity_hash"] = hash }
        }
        if let subscriptionId, let registeredToken {
            body["subscription_id"] = subscriptionId
            body["token_hash"] = HSOwnership.tokenHash(registeredToken)
        }
        if let name = clean(name) { body["name"] = name }
        if let email = clean(email) { body["email"] = email }
        if let language = clean(language) { body["language"] = language }
        return body
    }

    /// Identify girdisinin özeti (belirteç hariç; SHA-256): değişmediyse istek tekrarlanmaz.
    public static func identifyKey(_ body: [String: Any]) -> String {
        let canonical = body.keys.filter { $0 != "visitor_token" }.sorted().map { "\($0)=\(body[$0] ?? "")" }.joined(separator: "\u{1}")
        return HSOwnership.tokenHash(canonical)
    }

    public static func sendBody(visitor: HSChatVisitor, clientMessageId: String, text: String, optionId: String?,
                                name: String?, email: String?, language: String?) -> [String: Any] {
        var body = visitor.auth(["client_message_id": clientMessageId, "text": text])
        if let optionId = clean(optionId) { body["option_id"] = optionId }
        if let name = clean(name) { body["name"] = name }
        if let email = clean(email) { body["email"] = email }
        if let language = clean(language) { body["language"] = language }
        return body
    }

    public static func offlineBody(visitor: HSChatVisitor, clientMessageId: String, email: String, text: String,
                                   name: String?, language: String?) -> [String: Any] {
        var body = visitor.auth(["client_message_id": clientMessageId, "email": email.trimmingCharacters(in: .whitespaces), "text": text])
        if let name = clean(name) { body["name"] = name }
        if let language = clean(language) { body["language"] = language }
        return body
    }

    public static func typingBody(visitor: HSChatVisitor, typing: Bool) -> [String: Any] { visitor.auth(["typing": typing]) }

    /// `POST chat/ack`: en az biri verilmelidir.
    public static func ackBody(visitor: HSChatVisitor, readSeq: Int?, deliveredSeq: Int?) throws -> [String: Any] {
        guard readSeq != nil || deliveredSeq != nil else { throw HSChatError.invalidArgument("readSeq veya deliveredSeq gerekli") }
        var body = visitor.auth()
        if let readSeq { body["read_seq"] = readSeq }
        if let deliveredSeq { body["delivered_seq"] = deliveredSeq }
        return body
    }

    /// `GET chat/messages` sorgusu.
    public static func messagesQuery(visitor: HSChatVisitor, afterSeq: Int?, beforeSeq: Int?, limit: Int) throws -> String {
        guard (1...100).contains(limit) else { throw HSChatError.invalidArgument("limit 1-100 olmalı") }
        if let afterSeq, afterSeq < 0 { throw HSChatError.invalidArgument("afterSeq negatif olamaz") }
        if let beforeSeq, beforeSeq < 1 { throw HSChatError.invalidArgument("beforeSeq en az 1 olmalı") }
        return visitor.query([("after_seq", afterSeq), ("before_seq", beforeSeq), ("limit", limit)])
    }

    /// Metin doğrulaması (kırpılmış, 1–4000 karakter).
    public static func requireText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HSChatError.invalidArgument("Mesaj metni boş olamaz") }
        guard trimmed.count <= HSChatLimits.maxText else { throw HSChatError.invalidArgument("Mesaj en fazla \(HSChatLimits.maxText) karakter olabilir") }
        return trimmed
    }
}

/// Sohbet kullanım hataları.
public enum HSChatError: Error, Equatable {
    case invalidArgument(String)
}

// MARK: - Multipart

/// `multipart/form-data` gövdesi (sohbet eki).
public struct HSMultipart {
    public let boundary: String
    private var data = Data()

    public init(boundary: String = "----pushizo" + HSChatVisitor.randomString(24)) {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "%22")
    }

    public mutating func field(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(HSMultipart.escape(name))\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func file(_ name: String, fileName: String, mimeType: String, bytes: Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(HSMultipart.escape(name))\"; filename=\"\(HSMultipart.escape(fileName))\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(bytes)
        data.append(Data("\r\n".utf8))
    }

    public func build() -> Data {
        var out = data
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }
}

// MARK: - SSE

/// Ayrıştırılmış SSE olayı.
public struct HSSseEvent: Equatable {
    public let event: String
    public let data: String
    public let id: String?
}

/**
 Server-Sent Events satır ayrıştırıcısı (WHATWG): `event:`, `data:` (çok satırlı veri `\n` ile), `id:` (NUL içeren yok
 sayılır), `retry:`; `:` ile başlayan satır yorumdur (kalp atışı). Boş satır olayı tamamlar; verisiz olay atılır.
 */
public final class HSSseParser {
    private var eventType: String?
    private var data = ""
    private var hasData = false
    public private(set) var lastEventId: String?
    public private(set) var retryMs: Int?

    public init() {}

    public func feed(_ rawLine: String) -> HSSseEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
        } else {
            field = line
            value = ""
        }
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": eventType = value
        case "data":
            if hasData { data += "\n" }
            data += value
            hasData = true
        case "id": if !value.contains("\u{0}") { lastEventId = value }
        case "retry": if let ms = Int(value), ms >= 0 { retryMs = ms }
        default: break
        }
        return nil
    }

    private func dispatch() -> HSSseEvent? {
        defer {
            eventType = nil
            data = ""
            hasData = false
        }
        guard hasData else { return nil }
        let type = (eventType?.isEmpty == false) ? eventType! : "message"
        return HSSseEvent(event: type, data: data, id: lastEventId)
    }
}

/// Bayt akışını satırlara böler (`\n`; `\r` ayrıştırıcıda temizlenir). `URLSession.AsyncBytes.lines` boş satırları
/// attığından (SSE olay sınırı) kullanılmaz.
public struct HSLineSplitter {
    private var buffer = [UInt8]()

    public init() {}

    /// Bayt ekler; satır tamamlandıysa döner.
    public mutating func append(_ byte: UInt8) -> String? {
        if byte == 0x0A {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            return line
        }
        buffer.append(byte)
        return nil
    }
}

// MARK: - Sıra, tekilleştirme, geri çekilme, push

/**
 Mesaj listesi birleştirme: sunucu mesajları sıra numarasına göre artan ve tekil; bekleyen yerel mesaj (seq 0) aynı
 `clientMessageId` ile sunucu kopyası gelince kalkar ve listenin sonunda durur.
 */
public enum HSChatTimeline {
    public static func merge(_ current: [HSChatMessage], _ incoming: [HSChatMessage]) -> [HSChatMessage] {
        var bySeq: [Int: HSChatMessage] = [:]
        var pendingOrder: [String] = []
        var pending: [String: HSChatMessage] = [:]
        for m in current + incoming {
            if m.seq <= 0 {
                guard let key = m.clientMessageId else { continue }
                if pending[key] == nil { pendingOrder.append(key) }
                pending[key] = m
                continue
            }
            if let key = m.clientMessageId { pending.removeValue(forKey: key) }
            bySeq[m.seq] = m
        }
        let confirmed = Set(bySeq.values.compactMap(\.clientMessageId))
        let sorted = bySeq.values.sorted { $0.seq < $1.seq }
        return sorted + pendingOrder.compactMap { key in confirmed.contains(key) ? nil : pending[key] }
    }
}

/// Aynı sunucu mesajının bir kez bildirilmesi için sınırlı "görüldü" kümesi.
public final class HSChatSeen {
    private let capacity: Int
    private var order: [String] = []
    private var ids = Set<String>()
    private let lock = NSLock()

    public init(capacity: Int = 500) { self.capacity = capacity }

    /// İlk kez görülüyorsa true (ve kaydeder); kimliksiz (yerel) mesaj her zaman true.
    public func mark(_ id: String?) -> Bool {
        guard let id else { return true }
        lock.lock(); defer { lock.unlock() }
        guard ids.insert(id).inserted else { return false }
        order.append(id)
        while order.count > capacity { ids.remove(order.removeFirst()) }
        return true
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        order.removeAll()
        ids.removeAll()
    }
}

/// Yeniden bağlanma bekleme süresi: 1 sn'den ikiye katlanarak 30 sn tavana; ±%20 sapma.
public enum HSChatBackoff {
    public static let baseMs = 1_000
    public static let maxMs = 30_000

    public static func delayMs(failures: Int, jitter: Double = Double.random(in: 0...1)) -> Int {
        let exp = baseMs << (min(max(failures, 1), 16) - 1)
        let capped = min(exp, maxMs)
        let factor = 0.8 + 0.4 * min(max(jitter, 0), 1)
        return max(Int(Double(capped) * factor), 250)
    }
}

/**
 Push payload'undaki sohbet işareti: APNs kök anahtarı `pushizo_chat` (JSON metni veya sözlük); `custom_data` içinde iç
 içe gelen biçim de kabul edilir.
 */
public enum HSChatPush {
    public static let key = "pushizo_chat"

    public static func parse(_ userInfo: [AnyHashable: Any]) -> HSChatPushInfo? {
        if let info = info(from: userInfo[key]) { return info }
        if let custom = object(userInfo["custom_data"]) { return info(from: custom[key]) }
        return nil
    }

    static func object(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        if let text = value as? String, let data = text.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return nil
    }

    static func info(from value: Any?) -> HSChatPushInfo? {
        guard let json = object(value), let id = HSInAppParser.nonEmpty(json["conversation_id"]) else { return nil }
        return HSChatPushInfo(conversationId: id, seq: HSChatParser.int(json["seq"]))
    }
}

// MARK: - Keychain

/// Genel parola sınıfında küçük gizli değer deposu (sohbet ziyaretçi belirteci).
public enum HSKeychain {
    static let service = "com.pushizo.sdk"

    public static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Değeri yazar (nil siler); başarıda true.
    @discardableResult
    public static func write(_ value: String?, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
