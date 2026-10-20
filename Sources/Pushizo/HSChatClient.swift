import Foundation
#if canImport(PushizoCore)
import PushizoCore
#endif
import UIKit

/// Sohbet dinleyicisi kaydı (`removeListener` için).
public final class HSChatListenerToken {
    let id = UUID()
}

extension Pushizo {
    /**
     Canlı sohbet (ADR-0040). Ziyaretçi kimliği cihazda üretilir (belirteç Keychain'de); mesajlar sıra numaralıdır,
     gerçek zamanlı iletim SSE (`chat/stream`, `URLSession.bytes`) + POST'tur. Akış koparsa üstel geri çekilmeyle yeniden
     bağlanılır ve arada `after_seq` yoklamasıyla eksikler alınır. Uygulama kapalıyken temsilci mesajı push (`pushizo_chat`)
     ile gelir; okunmamış sayısı yenilenir, bildirime tıklama `addOpenListener` dinleyicilerine iletilir.

     ```swift
     try await Pushizo.Chat.start()
     let token = Pushizo.Chat.addListener { event in if case let .message(m) = event { … } }
     Pushizo.Chat.startListening()
     let page = try await Pushizo.Chat.getMessages()
     try await Pushizo.Chat.sendMessage("Merhaba")
     ```
     Dinleyiciler ana iş parçacığında çağrılır.
     */
    public enum Chat {
        private static let lock = NSLock()
        private static var listeners: [UUID: (HSChatEvent) -> Void] = [:]
        private static var openListeners: [UUID: (HSChatPushInfo) -> Void] = [:]
        private static var pendingOpen: HSChatPushInfo?
        private static var streamTask: Task<Void, Never>?
        /// Her başlat/durdur çağrısında artar: biten eski döngü yenisinin kaydını silmez.
        private static var streamGeneration = 0
        private static var conversationId: String?
        private static var typingState = false
        private static var typingSentAt = Date.distantPast
        private static var deliveredAckTask: Task<Void, Never>?
        private static let seen = HSChatSeen()
        private static let streamSession: URLSession = {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 24 * 60 * 60
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: config)
        }()

        static let sendOperation = "chat_send"
        static let offlineOperation = "chat_offline"

        private static func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        private static func context() throws -> (HSStorage, HSApi) {
            guard let store = storage, let api else { throw HSError.notInitialized }
            // Gizlilik onayı yoksa ağ çağrısı yapılmaz (yeniden denenebilir hata: gönderimler kuyrukta bekler).
            guard networkAllowed else { throw HSApiError(status: 0, code: "CONSENT_REQUIRED", message: "gizlilik onayı bekleniyor") }
            return (store, api)
        }

        private static func visitor(_ store: HSStorage) -> HSChatVisitor { HSChatVisitor.ensure(store) }

        // MARK: Durum

        /// Bu cihazın ziyaretçi kimliği (sohbet henüz kullanılmadıysa nil).
        public static var visitorId: String? { storage?.chatVisitorId }

        /// Son bilinen okunmamış (temsilci/bot) mesaj sayısı; güncel değer için `refreshUnreadCount()`.
        public static var unreadCount: Int { storage?.chatUnreadCount ?? 0 }

        /// Canlı dinleme açık mı.
        public static var isListening: Bool { locked { streamTask != nil } }

        // MARK: Dinleyiciler

        /// Sohbet olay dinleyicisi (ana iş parçacığında); `removeListener` için belirteç döner.
        @discardableResult
        public static func addListener(_ listener: @escaping (HSChatEvent) -> Void) -> HSChatListenerToken {
            let token = HSChatListenerToken()
            locked { listeners[token.id] = listener }
            return token
        }

        public static func removeListener(_ token: HSChatListenerToken) {
            _ = locked { listeners.removeValue(forKey: token.id) }
        }

        /// Sohbet bildirimine tıklama dinleyicisi; dinleyici yokken gelen tıklama saklanır ve ilk dinleyiciye iletilir.
        @discardableResult
        public static func addOpenListener(_ listener: @escaping (HSChatPushInfo) -> Void) -> HSChatListenerToken {
            let token = HSChatListenerToken()
            let pending: HSChatPushInfo? = locked {
                openListeners[token.id] = listener
                defer { pendingOpen = nil }
                return pendingOpen
            }
            if let pending { DispatchQueue.main.async { listener(pending) } }
            return token
        }

        public static func removeOpenListener(_ token: HSChatListenerToken) {
            _ = locked { openListeners.removeValue(forKey: token.id) }
        }

        static func emit(_ event: HSChatEvent) {
            let current = locked { Array(listeners.values) }
            guard !current.isEmpty else { return }
            DispatchQueue.main.async { current.forEach { $0(event) } }
        }

        // MARK: Kimlik

        /**
         Sohbeti etkinleştirir ve ziyaretçiyi sunucuya tanıtır: giriş yapılmışsa kullanıcıya (`external_id` + kanıt), push
         aboneliği varsa ona (sahiplik kanıtıyla; çevrimdışı mesaj bildirimi için) bağlar. Sonraki login/logout ve abonelik
         değişimlerinde bağlama SDK tarafından yenilenir.
         */
        @discardableResult
        public static func start(name: String? = nil, email: String? = nil, language: String? = nil) async throws -> HSChatIdentifyResult {
            let (store, _) = try context()
            store.chatEnabled = true
            // force: her zaman sonuç döner.
            return try await identify(name: name, email: email, language: language, force: true)!
        }

        /// Ziyaretçi bilgisini (ad, e-posta, dil) günceller ve bağlamayı yeniler.
        @discardableResult
        public static func identify(name: String? = nil, email: String? = nil, language: String? = nil) async throws -> HSChatIdentifyResult {
            try await start(name: name, email: email, language: language)
        }

        /// `force` false iken girdi son başarılı çağrıyla aynıysa istek atılmaz (nil).
        static func identify(name: String?, email: String?, language: String?, force: Bool) async throws -> HSChatIdentifyResult? {
            let (store, api) = try context()
            let v = visitor(store)
            let externalId = store.externalId
            let body = HSChatRequests.identifyBody(
                visitor: v,
                externalId: externalId,
                identityHash: externalId != nil ? store.userIdentityHash : nil,
                subscriptionId: store.subscriptionId,
                registeredToken: store.registeredToken,
                name: name,
                email: email,
                language: language
            )
            let key = HSChatRequests.identifyKey(body)
            if !force && key == store.chatIdentifyKey { return nil }
            let result = HSChatParser.identify(try await api.request("POST", "/chat/identify", body: body))
            store.chatIdentifyKey = key
            if let conversation = result.conversation { onConversation(conversation) }
            return result
        }

        /// Ziyaretçi henüz tanıtılmadıysa önce bağlanır; hata gönderimi engellemez.
        private static func ensureIdentified(_ store: HSStorage) async {
            guard store.chatIdentifyKey == nil else { return }
            do { _ = try await identify(name: nil, email: nil, language: nil, force: false) } catch {
                HSLog.log(.debug, "sohbet ziyaretçisi bağlanamadı")
            }
        }

        /// Login, logout veya push aboneliği/token değişimi (çekirdek çağırır); sohbet başlatılmadıysa no-op.
        static func onIdentityChanged() {
            guard let store = storage, store.chatEnabled else { return }
            Task {
                do { _ = try await identify(name: nil, email: nil, language: nil, force: false) } catch {
                    HSLog.log(.warn, "sohbet ziyaretçisi yeniden bağlanamadı: \(error)")
                }
            }
        }

        /// Logout / onayın geri alınması: dinleme durur, ziyaretçi kimliği silinir (sonraki kişi önceki sohbeti görmez).
        static func onLogout() {
            guard let store = storage else { return }
            stopListening()
            locked { conversationId = nil }
            seen.clear()
            let hadUnread = store.chatUnreadCount != 0
            store.clearChatVisitor()
            if hadUnread { emit(.unreadCount(0)) }
        }

        // MARK: Okuma

        /// Widget ayarları, çevrimiçi durumu, çevrimdışı metni ve ek sınırları.
        public static func getConfig(language: String? = nil) async throws -> HSChatConfig {
            let (_, api) = try context()
            let query = language.flatMap { $0.isEmpty ? nil : "?language=\(HSChatVisitor.encode($0))" } ?? ""
            return HSChatParser.config(try await api.request("GET", "/chat/config\(query)"))
        }

        /// Konuşma (yoksa nil) ve okunmamış sayısı.
        public static func getConversation() async throws -> HSChatConversationState {
            let (store, api) = try context()
            let state = HSChatParser.conversationState(try await api.request("GET", "/chat/conversation?\(visitor(store).query())"))
            if let conversation = state.conversation { onConversation(conversation) }
            setUnread(state.unreadCount)
            return state
        }

        /// Mesajlar (kronolojik): parametresiz en yeni `limit`; `afterSeq` sonrakiler, `beforeSeq` daha eski geçmiş (1-100).
        public static func getMessages(afterSeq: Int? = nil, beforeSeq: Int? = nil, limit: Int = 50) async throws -> HSChatMessagePage {
            let (store, api) = try context()
            let query = try HSChatRequests.messagesQuery(visitor: visitor(store), afterSeq: afterSeq, beforeSeq: beforeSeq, limit: limit)
            let page = HSChatParser.page(try await api.request("GET", "/chat/messages?\(query)"))
            page.messages.forEach { _ = seen.mark($0.id) }
            if beforeSeq == nil, let maxSeq = page.messages.map(\.seq).max() { advanceLastSeq(maxSeq) }
            scheduleDeliveredAck(page.messages)
            return page
        }

        /// Okunmamış sayısını sunucudan yeniler.
        @discardableResult
        public static func refreshUnreadCount() async throws -> Int { try await getConversation().unreadCount }

        // MARK: Gönderim

        /**
         Mesaj gönderir (ilk mesaj konuşmayı açar); `optionId` bot sorusunda seçilen hızlı yanıttır. Ağ yoksa mesaj kalıcı
         kuyruğa alınır ve `pending` yerel mesaj döner; gönderilince dinleyicilere sunucu kopyası gelir.
         */
        @discardableResult
        public static func sendMessage(_ text: String, optionId: String? = nil) async throws -> HSChatMessage {
            let clean = try HSChatRequests.requireText(text)
            guard let store = storage else { throw HSError.notInitialized }
            store.chatEnabled = true
            if networkAllowed { await ensureIdentified(store) }
            var op: [String: Any] = [
                "type": sendOperation, "visitor_id": visitor(store).id, "client_message_id": HSChatVisitor.newClientMessageId(),
                "text": clean, "at": Date().timeIntervalSince1970,
            ]
            if let optionId { op["option_id"] = optionId }
            return try await sendOrQueue(op) { try await performSend(op) }
        }

        /// Çevrimdışı / çalışma saatleri dışında e-postayla mesaj bırakır.
        @discardableResult
        public static func leaveOfflineMessage(email: String, text: String, name: String? = nil) async throws -> HSChatMessage {
            let clean = try HSChatRequests.requireText(text)
            guard let normalized = HSContacts.normalizeEmail(email) else { throw HSChatError.invalidArgument("Geçersiz e-posta adresi") }
            guard let store = storage else { throw HSError.notInitialized }
            store.chatEnabled = true
            if networkAllowed { await ensureIdentified(store) }
            var op: [String: Any] = [
                "type": offlineOperation, "visitor_id": visitor(store).id, "client_message_id": HSChatVisitor.newClientMessageId(),
                "text": clean, "email": normalized, "at": Date().timeIntervalSince1970,
            ]
            if let name { op["name"] = name }
            return try await sendOrQueue(op) { try await performOffline(op) }
        }

        /// Geçici hatada işlem kalıcı kuyruğa yazılır ve aynı `client_message_id` ile yeniden denenir (sunucu tekilleştirir).
        private static func sendOrQueue(_ op: [String: Any], _ send: () async throws -> HSChatMessage) async throws -> HSChatMessage {
            do {
                return try await send()
            } catch let error as HSApiError where error.isRetryable {
                HSLog.log(.info, "sohbet mesajı çevrimdışı kuyruğa alındı (\(error.code))")
                enqueue(op)
                let pending = HSChatMessage(
                    id: nil, seq: 0, clientMessageId: op["client_message_id"] as? String, sender: HSChatMessage.senderVisitor,
                    authorName: op["name"] as? String, text: op["text"] as? String, attachments: [], quickReplies: nil,
                    status: HSChatMessage.statusPending, createdAt: Date()
                )
                emit(.message(pending))
                return pending
            }
        }

        /// Kuyruktaki sohbet işlemi (çekirdek kuyruğu çağırır); ziyaretçi değiştiyse (logout) atılır.
        static func performQueued(_ op: [String: Any]) async throws {
            guard let store = storage, op["visitor_id"] as? String == store.chatVisitorId else {
                HSLog.log(.debug, "önceki ziyaretçinin bekleyen sohbet mesajı atıldı")
                return
            }
            switch op["type"] as? String {
            case sendOperation: _ = try await performSend(op)
            case offlineOperation: _ = try await performOffline(op)
            default: break
            }
        }

        private static func performSend(_ op: [String: Any]) async throws -> HSChatMessage {
            let (store, api) = try context()
            let body = HSChatRequests.sendBody(
                visitor: visitor(store), clientMessageId: op["client_message_id"] as? String ?? "", text: op["text"] as? String ?? "",
                optionId: op["option_id"] as? String, name: op["name"] as? String, email: op["email"] as? String, language: op["language"] as? String
            )
            return try onSendResult(try await api.request("POST", "/chat/messages", body: body))
        }

        private static func performOffline(_ op: [String: Any]) async throws -> HSChatMessage {
            let (store, api) = try context()
            let body = HSChatRequests.offlineBody(
                visitor: visitor(store), clientMessageId: op["client_message_id"] as? String ?? "", email: op["email"] as? String ?? "",
                text: op["text"] as? String ?? "", name: op["name"] as? String, language: op["language"] as? String
            )
            return try onSendResult(try await api.request("POST", "/chat/offline", body: body))
        }

        /// Ek gönderir (PNG/JPEG/WebP/GIF/PDF/düz metin, en çok 10 MB); `text` isteğe bağlı açıklamadır.
        @discardableResult
        public static func sendAttachment(_ data: Data, fileName: String, mimeType: String, text: String? = nil) async throws -> HSChatMessage {
            guard !data.isEmpty else { throw HSChatError.invalidArgument("Dosya boş olamaz") }
            guard data.count <= HSChatLimits.maxAttachmentBytes else { throw HSChatError.invalidArgument("Dosya 10 MB sınırını aşıyor") }
            let mime = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            guard HSChatLimits.attachmentTypes.contains(mime) else {
                throw HSChatError.invalidArgument("Desteklenmeyen dosya türü: \(mime) (PNG, JPEG, WebP, GIF, PDF, düz metin)")
            }
            let (store, api) = try context()
            store.chatEnabled = true
            await ensureIdentified(store)
            let v = visitor(store)
            var multipart = HSMultipart()
            multipart.field("visitor_id", v.id)
            multipart.field("visitor_token", v.token)
            multipart.field("client_message_id", HSChatVisitor.newClientMessageId())
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                multipart.field("text", try HSChatRequests.requireText(text))
            }
            multipart.file("file", fileName: fileName.isEmpty ? "file" : fileName, mimeType: mime, bytes: data)
            return try onSendResult(try await api.requestRaw("POST", "/chat/attachments", contentType: multipart.contentType, data: multipart.build()))
        }

        /// Yerel dosya adresinden ek gönderir (ad dosya adından alınır).
        @discardableResult
        public static func sendAttachment(fileURL: URL, mimeType: String, text: String? = nil) async throws -> HSChatMessage {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= HSChatLimits.maxAttachmentBytes else { throw HSChatError.invalidArgument("Dosya 10 MB sınırını aşıyor") }
            let data = try Data(contentsOf: fileURL)
            return try await sendAttachment(data, fileName: fileURL.lastPathComponent, mimeType: mimeType, text: text)
        }

        private static func onSendResult(_ json: [String: Any]) throws -> HSChatMessage {
            guard let raw = json["message"] as? [String: Any] else { throw HSError.invalidResponse }
            let message = HSChatParser.message(raw)
            let hadConversation = locked { conversationId != nil }
            if let conversation = HSChatParser.conversation(json["conversation"]) { onConversation(conversation) }
            if seen.mark(message.id) { emit(.message(message)) }
            // İlk mesaj konuşmayı açtı: konuşmasız akış yalnızca kalp atışı taşır, yeniden kurulur.
            if !hadConversation, locked({ conversationId != nil }) { restartStream() }
            return message
        }

        // MARK: Okundu / teslim / yazıyor

        /// `seq` numarasına kadar okundu işaretler; kalan okunmamış sayısını döndürür.
        @discardableResult
        public static func markRead(_ seq: Int) async throws -> Int {
            guard seq >= 0 else { throw HSChatError.invalidArgument("seq negatif olamaz") }
            let (store, api) = try context()
            let body = try HSChatRequests.ackBody(visitor: visitor(store), readSeq: seq, deliveredSeq: nil)
            let state = HSChatParser.conversationState(try await api.request("POST", "/chat/ack", body: body))
            if let conversation = state.conversation { onConversation(conversation) }
            setUnread(state.unreadCount)
            return state.unreadCount
        }

        /// Temsilci/bot mesajları cihaza ulaştı: teslim işaretçisi kısa gecikmeyle ve yalnızca ileri giderek gönderilir.
        private static func scheduleDeliveredAck(_ messages: [HSChatMessage]) {
            guard let store = storage, let maxSeq = messages.filter({ !$0.isFromVisitor }).map(\.seq).max(), maxSeq > store.chatDeliveredSeq else { return }
            let task = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                let target = max(maxSeq, store.chatDeliveredSeq)
                do {
                    let (store, api) = try context()
                    _ = try await api.request("POST", "/chat/ack", body: try HSChatRequests.ackBody(visitor: visitor(store), readSeq: nil, deliveredSeq: target))
                    if target > store.chatDeliveredSeq { store.chatDeliveredSeq = target }
                } catch {
                    HSLog.log(.debug, "sohbet teslim bilgisi gönderilemedi")
                }
            }
            locked {
                deliveredAckTask?.cancel()
                deliveredAckTask = task
            }
        }

        /// Yazıyor göstergesi ("yazıyor" en sık 3 sn'de bir; konuşma yoksa gönderilmez). Hata yalnızca günlüğe yazılır.
        public static func setTyping(_ typing: Bool) {
            let shouldSend: Bool = locked {
                guard conversationId != nil else { return false }
                let now = Date()
                if typing && typingState && now.timeIntervalSince(typingSentAt) < 3 { return false }
                if !typing && !typingState { return false }
                typingState = typing
                typingSentAt = now
                return true
            }
            guard shouldSend else { return }
            Task {
                do {
                    let (store, api) = try context()
                    _ = try await api.request("POST", "/chat/typing", body: HSChatRequests.typingBody(visitor: visitor(store), typing: typing))
                } catch {
                    HSLog.log(.debug, "yazıyor bilgisi gönderilemedi")
                }
            }
        }

        // MARK: Okunmamış / konuşma

        private static func setUnread(_ count: Int) {
            guard let store = storage else { return }
            let value = max(count, 0)
            guard store.chatUnreadCount != value else { return }
            store.chatUnreadCount = value
            emit(.unreadCount(value))
        }

        private static func onConversation(_ conversation: HSChatConversation) {
            locked { conversationId = conversation.id }
            setUnread(conversation.unreadCount)
        }

        private static func advanceLastSeq(_ seq: Int) {
            guard let store = storage else { return }
            locked { if seq > store.chatLastSeq { store.chatLastSeq = seq } }
        }

        // MARK: Push

        /// Push alındı (ön planda; çekirdek çağırır): sohbet bildirimiyse okunmamış sayısı yenilenir.
        static func onPushReceived(_ userInfo: [AnyHashable: Any]) {
            guard HSChatPush.parse(userInfo) != nil, storage?.chatVisitorId != nil else { return }
            Task { _ = try? await getConversation() }
        }

        /// Uygulama ön plana geldi: arka planda gelen sohbet bildirimleri için okunmamış sayısı yenilenir.
        static func onForeground() {
            guard let store = storage, store.chatEnabled, store.chatVisitorId != nil, networkAllowed else { return }
            Task { _ = try? await getConversation() }
        }

        /// Bildirime tıklandı (çekirdek çağırır): sohbet bildirimiyse açma dinleyicilerine iletilir.
        static func onNotificationOpened(_ userInfo: [AnyHashable: Any]) {
            guard let info = HSChatPush.parse(userInfo) else { return }
            let current: [(HSChatPushInfo) -> Void] = locked {
                if openListeners.isEmpty { pendingOpen = info }
                return Array(openListeners.values)
            }
            guard !current.isEmpty else { return }
            DispatchQueue.main.async { current.forEach { $0(info) } }
        }

        // MARK: Canlı akış

        /**
         Canlı dinlemeyi başlatır (SSE). Kopan bağlantı 1 sn'den 30 sn'ye üstel geri çekilmeyle yeniden kurulur; her
         denemeden önce `after_seq` yoklamasıyla kaçırılan mesajlar alınır. Kalıcı hatada (403/404) durur ve `.error`
         olayı gelir. Uygulama arka plana geçince `stopListening()` önerilir (temsilci mesajı push ile gelir).
         */
        public static func startListening() {
            guard let store = storage else { return }
            store.chatEnabled = true
            locked {
                guard streamTask == nil else { return }
                streamGeneration += 1
                let generation = streamGeneration
                streamTask = Task {
                    await listenLoop()
                    // Döngü kalıcı hatayla kendiliğinden bittiyse kayıt temizlenir (yeniden başlatılabilir).
                    locked { if streamGeneration == generation { streamTask = nil } }
                }
            }
        }

        /// Canlı dinlemeyi durdurur (açık bağlantı iptalle kapanır).
        public static func stopListening() {
            let task: Task<Void, Never>? = locked {
                streamGeneration += 1
                defer { streamTask = nil }
                return streamTask
            }
            task?.cancel()
        }

        /// Konuşma açıldı: akış (konuşmasızken yalnızca kalp atışı) yeni döngüyle yeniden kurulur.
        private static func restartStream() {
            guard isListening else { return }
            stopListening()
            startListening()
        }

        private static func listenLoop() async {
            var failures = 0
            while !Task.isCancelled {
                var connected = false
                do {
                    let (store, api) = try context()
                    let lastSeq = store.chatLastSeq > 0 ? store.chatLastSeq : nil
                    guard let request = api.streamRequest("/chat/stream?\(visitor(store).query())", lastEventId: lastSeq) else { break }
                    let (bytes, response) = try await streamSession.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        // Hata zarfı (en çok 8 KB) okunur: `{"error":{"code","message"}}`.
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 8_192 { break }
                        }
                        let envelope = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any]
                        let error = HSApiError(status: status, code: envelope?["code"] as? String ?? "HTTP_\(status)", message: envelope?["message"] as? String ?? "HTTP \(status)")
                        if !error.isRetryable {
                            HSLog.log(.warn, "sohbet akışı durdu: \(error.code)")
                            emit(.error(code: error.code, message: error.message))
                            break
                        }
                        throw error
                    }
                    connected = true
                    failures = 0
                    emit(.connection(true))
                    let parser = HSSseParser()
                    var splitter = HSLineSplitter()
                    for try await byte in bytes {
                        if let line = splitter.append(byte), let event = parser.feed(line) { handle(event) }
                    }
                } catch let error as HSError where error == .notInitialized {
                    break
                } catch {
                    if Task.isCancelled { break }
                    HSLog.log(.debug, "sohbet akışı koptu")
                }
                if connected { emit(.connection(false)) }
                if Task.isCancelled { break }
                // Yoklama yedeği: akış yokken kaçırılan mesajlar `after_seq` ile alınır.
                try? await pollMissed()
                failures += 1
                try? await Task.sleep(nanoseconds: UInt64(HSChatBackoff.delayMs(failures: failures)) * 1_000_000)
            }
        }

        private static func handle(_ event: HSSseEvent) {
            guard let data = event.data.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            switch event.event {
            case "message":
                onIncoming([HSChatParser.message(json)])
            case "typing":
                emit(.typing(json["typing"] as? Bool ?? false, name: HSInAppParserBridge.nonEmpty(json["name"])))
            case "read":
                let seq = (json["seq"] as? NSNumber)?.intValue ?? 0
                if seq > 0 { emit(.agentRead(seq)) }
            case "conversation":
                guard let id = HSInAppParserBridge.nonEmpty(json["id"]) else { return }
                locked { conversationId = id }
                if let unread = json["unread_count"] as? NSNumber { setUnread(unread.intValue) }
                emit(.conversationUpdated(id: id, status: HSInAppParserBridge.nonEmpty(json["status"]) ?? "open", botActive: json["bot_active"] as? Bool ?? false))
            default:
                break
            }
        }

        /// Akıştan/yoklamadan gelen mesajlar: sıra ilerletilir, yeniler bildirilir, temsilci mesajları okunmamışa eklenir.
        private static func onIncoming(_ messages: [HSChatMessage]) {
            let fresh = messages.sorted { $0.seq < $1.seq }.filter { seen.mark($0.id) }
            if let maxSeq = messages.map(\.seq).max() { advanceLastSeq(maxSeq) }
            guard !fresh.isEmpty else { return }
            fresh.forEach { emit(.message($0)) }
            let fromAgent = fresh.filter { !$0.isFromVisitor && $0.sender != HSChatMessage.senderSystem }.count
            if fromAgent > 0 { setUnread(unreadCount + fromAgent) }
            scheduleDeliveredAck(fresh)
        }

        private static func pollMissed() async throws {
            guard locked({ conversationId != nil }) else { return }
            for _ in 0..<10 {
                let (store, api) = try context()
                let query = try HSChatRequests.messagesQuery(visitor: visitor(store), afterSeq: store.chatLastSeq, beforeSeq: nil, limit: 100)
                let page = HSChatParser.page(try await api.request("GET", "/chat/messages?\(query)"))
                onIncoming(page.messages)
                if !page.hasMore || page.messages.isEmpty { break }
            }
        }

        // MARK: Ek indirme

        /**
         Ek dosyasının adresi (yalnızca bu ziyaretçinin konuşmasındaki ekler). Adres ziyaretçi belirtecini sorguda taşır:
         yalnızca görsel yükleyiciye verin, loglamayın veya paylaşmayın.
         */
        public static func attachmentUrl(_ attachmentId: String, download: Bool = false) throws -> URL {
            guard let store = storage, let api else { throw HSError.notInitialized }
            let id = attachmentId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? attachmentId
            let raw = "\(api.base)/chat/attachments/\(id)?\(visitor(store).query())" + (download ? "&download=true" : "")
            guard let url = URL(string: raw) else { throw HSError.invalidResponse }
            return url
        }

        // MARK: Geri çağrılı sürümler (köprüler; tamamlama ana iş parçacığında)

        public static func start(name: String? = nil, email: String? = nil, language: String? = nil, _ completion: @escaping (Result<HSChatIdentifyResult, Error>) -> Void) {
            run(completion) { try await start(name: name, email: email, language: language) }
        }

        public static func getConfig(language: String? = nil, _ completion: @escaping (Result<HSChatConfig, Error>) -> Void) {
            run(completion) { try await getConfig(language: language) }
        }

        public static func getConversation(_ completion: @escaping (Result<HSChatConversationState, Error>) -> Void) {
            run(completion) { try await getConversation() }
        }

        public static func getMessages(afterSeq: Int? = nil, beforeSeq: Int? = nil, limit: Int = 50, _ completion: @escaping (Result<HSChatMessagePage, Error>) -> Void) {
            run(completion) { try await getMessages(afterSeq: afterSeq, beforeSeq: beforeSeq, limit: limit) }
        }

        public static func sendMessage(_ text: String, optionId: String? = nil, _ completion: @escaping (Result<HSChatMessage, Error>) -> Void) {
            run(completion) { try await sendMessage(text, optionId: optionId) }
        }

        public static func sendAttachment(_ data: Data, fileName: String, mimeType: String, text: String? = nil, _ completion: @escaping (Result<HSChatMessage, Error>) -> Void) {
            run(completion) { try await sendAttachment(data, fileName: fileName, mimeType: mimeType, text: text) }
        }

        public static func markRead(_ seq: Int, _ completion: @escaping (Result<Int, Error>) -> Void) {
            run(completion) { try await markRead(seq) }
        }

        public static func refreshUnreadCount(_ completion: @escaping (Result<Int, Error>) -> Void) {
            run(completion) { try await refreshUnreadCount() }
        }

        public static func leaveOfflineMessage(email: String, text: String, name: String? = nil, _ completion: @escaping (Result<HSChatMessage, Error>) -> Void) {
            run(completion) { try await leaveOfflineMessage(email: email, text: text, name: name) }
        }

        private static func run<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ body: @escaping () async throws -> T) {
            Task {
                let result: Result<T, Error>
                do { result = .success(try await body()) } catch { result = .failure(error) }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
}

/// `HSInAppParser.nonEmpty` çekirdekte modül içidir; sohbet istemcisi aynı kuralı burada uygular.
enum HSInAppParserBridge {
    static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}
