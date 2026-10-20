import XCTest
@testable import PushizoCore

final class HSChatTests: XCTestCase {
    private final class MemoryChatState: HSChatState {
        var chatVisitorId: String?
        var chatVisitorToken: String?
        var chatEnabled = false
        var chatIdentifyKey: String?
        var chatLastSeq = 0
        var chatDeliveredSeq = 0
        var chatUnreadCount = 0

        func clearChatVisitor() {
            chatVisitorId = nil
            chatVisitorToken = nil
            chatIdentifyKey = nil
            chatLastSeq = 0
            chatDeliveredSeq = 0
            chatUnreadCount = 0
        }
    }

    private let visitor = HSChatVisitor(id: String(repeating: "v", count: 32), token: String(repeating: "t", count: 64))

    private func message(_ seq: Int, id: String? = nil, cmid: String? = nil, sender: String = HSChatMessage.senderAgent, status: String = "sent") -> HSChatMessage {
        HSChatMessage(id: id ?? (seq > 0 ? "msg_\(seq)" : nil), seq: seq, clientMessageId: cmid, sender: sender, authorName: nil,
                      text: "m\(seq)", attachments: [], quickReplies: nil, status: status, createdAt: nil)
    }

    // MARK: Ziyaretçi kimliği

    func testVisitorIdentityMatchesServerPatternAndPersists() {
        let state = MemoryChatState()
        let first = HSChatVisitor.ensure(state)
        XCTAssertTrue(HSChatLimits.isVisitorId(first.id))
        XCTAssertTrue(HSChatLimits.isVisitorToken(first.token))
        XCTAssertEqual(first.id.count, 32)
        XCTAssertEqual(first.token.count, 64)
        XCTAssertEqual(state.chatVisitorId, first.id)
        XCTAssertEqual(HSChatVisitor.ensure(state), first, "ikinci çağrı aynı kimliği döndürmeli")
        XCTAssertNotEqual(HSChatVisitor.ensure(MemoryChatState()).token, first.token)
    }

    func testInvalidStoredIdentityIsReplacedAndStateCleared() {
        let state = MemoryChatState()
        state.chatVisitorId = "kisa"
        state.chatVisitorToken = String(repeating: "x", count: 64)
        state.chatIdentifyKey = "eski"
        state.chatLastSeq = 9
        let v = HSChatVisitor.ensure(state)
        XCTAssertNotEqual(v.id, "kisa")
        XCTAssertNil(state.chatIdentifyKey)
        XCTAssertEqual(state.chatLastSeq, 0)
    }

    func testClientMessageIdsAreValidAndUnique() {
        let ids = Set((0..<50).map { _ in HSChatVisitor.newClientMessageId() })
        XCTAssertEqual(ids.count, 50)
        ids.forEach { XCTAssertTrue(HSChatLimits.isClientMessageId($0), $0) }
    }

    // MARK: İstek gövdeleri

    func testIdentifyBodyBindsSubscriptionOnlyWithTokenProof() {
        let body = HSChatRequests.identifyBody(visitor: visitor, externalId: "user_42", identityHash: "hash1234567890abcdef",
                                               subscriptionId: "sub_1", registeredToken: "apns-token", name: " Ali ", email: nil, language: "tr")
        XCTAssertEqual(body["visitor_id"] as? String, visitor.id)
        XCTAssertEqual(body["visitor_token"] as? String, visitor.token)
        XCTAssertEqual(body["external_id"] as? String, "user_42")
        XCTAssertEqual(body["identity_hash"] as? String, "hash1234567890abcdef")
        XCTAssertEqual(body["subscription_id"] as? String, "sub_1")
        XCTAssertEqual(body["token_hash"] as? String, HSOwnership.tokenHash("apns-token"))
        XCTAssertEqual(body["name"] as? String, "Ali")
        XCTAssertNil(body["email"])

        let noToken = HSChatRequests.identifyBody(visitor: visitor, externalId: nil, identityHash: "yok", subscriptionId: "sub_1",
                                                  registeredToken: nil, name: nil, email: nil, language: nil)
        XCTAssertNil(noToken["subscription_id"], "kanıt yoksa abonelik gönderilmez")
        XCTAssertNil(noToken["token_hash"])
        XCTAssertNil(noToken["identity_hash"], "external_id yoksa identity_hash gönderilmez")
    }

    func testIdentifyKeyChangesWithInputAndExcludesToken() {
        func key(_ ext: String, _ token: String) -> String {
            HSChatRequests.identifyKey(HSChatRequests.identifyBody(visitor: visitor, externalId: ext, identityHash: nil, subscriptionId: "sub",
                                                                   registeredToken: token, name: nil, email: nil, language: nil))
        }
        XCTAssertEqual(key("u1", "tok"), key("u1", "tok"))
        XCTAssertNotEqual(key("u1", "tok"), key("u1", "tok2"))
        XCTAssertNotEqual(key("u1", "tok"), key("u2", "tok"))
        XCTAssertFalse(key("u1", "tok").contains(visitor.token))
    }

    func testSendOfflineTypingAndAckBodies() throws {
        let send = HSChatRequests.sendBody(visitor: visitor, clientMessageId: "m_abcdefgh", text: "Merhaba", optionId: "opt_1",
                                           name: nil, email: "ali@example.com", language: nil)
        XCTAssertEqual(send["client_message_id"] as? String, "m_abcdefgh")
        XCTAssertEqual(send["option_id"] as? String, "opt_1")
        XCTAssertNil(send["name"])
        let offline = HSChatRequests.offlineBody(visitor: visitor, clientMessageId: "m_12345678", email: "ali@example.com", text: "Arayın", name: "Ali", language: nil)
        XCTAssertEqual(offline["email"] as? String, "ali@example.com")
        XCTAssertEqual(HSChatRequests.typingBody(visitor: visitor, typing: true)["typing"] as? Bool, true)
        XCTAssertEqual(try HSChatRequests.ackBody(visitor: visitor, readSeq: 7, deliveredSeq: nil)["read_seq"] as? Int, 7)
        XCTAssertThrowsError(try HSChatRequests.ackBody(visitor: visitor, readSeq: nil, deliveredSeq: nil))
    }

    func testMessagesQueryAndValidation() throws {
        XCTAssertEqual(try HSChatRequests.messagesQuery(visitor: visitor, afterSeq: 5, beforeSeq: nil, limit: 50),
                       "visitor_id=\(visitor.id)&token=\(visitor.token)&after_seq=5&limit=50")
        XCTAssertThrowsError(try HSChatRequests.messagesQuery(visitor: visitor, afterSeq: nil, beforeSeq: nil, limit: 0))
        XCTAssertThrowsError(try HSChatRequests.messagesQuery(visitor: visitor, afterSeq: nil, beforeSeq: 0, limit: 10))
        XCTAssertEqual(try HSChatRequests.requireText("  selam "), "selam")
        XCTAssertThrowsError(try HSChatRequests.requireText("   "))
        XCTAssertThrowsError(try HSChatRequests.requireText(String(repeating: "a", count: 4001)))
    }

    func testMultipartBody() {
        var mp = HSMultipart(boundary: "BOUNDARY")
        mp.field("visitor_id", visitor.id)
        mp.file("file", fileName: "rapor \"son\".pdf", mimeType: "application/pdf", bytes: Data([1, 2, 3]))
        let text = String(decoding: mp.build(), as: UTF8.self)
        XCTAssertEqual(mp.contentType, "multipart/form-data; boundary=BOUNDARY")
        XCTAssertTrue(text.hasPrefix("--BOUNDARY\r\nContent-Disposition: form-data; name=\"visitor_id\"\r\n\r\n\(visitor.id)\r\n"))
        XCTAssertTrue(text.contains("filename=\"rapor %22son%22.pdf\"\r\nContent-Type: application/pdf\r\n\r\n\u{1}\u{2}\u{3}\r\n"))
        XCTAssertTrue(text.hasSuffix("--BOUNDARY--\r\n"))
    }

    // MARK: SSE

    func testSseParserHandlesEventsIdsMultilineDataAndComments() {
        let parser = HSSseParser()
        let lines = [
            "retry: 3000", ": connected", "",
            "id: 4", "event: message", "data: {\"seq\":4}", "",
            ": hb", "",
            "event: typing", "data: {\"typing\":true,", "data: \"name\":\"Ayşe\"}", "",
            "data:no-space", "",
        ]
        let events = lines.compactMap { parser.feed($0) }
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], HSSseEvent(event: "message", data: "{\"seq\":4}", id: "4"))
        XCTAssertEqual(events[1].data, "{\"typing\":true,\n\"name\":\"Ayşe\"}")
        XCTAssertEqual(events[1].id, "4")
        XCTAssertEqual(events[2].data, "no-space")
        XCTAssertEqual(parser.retryMs, 3000)
    }

    func testLineSplitterKeepsEmptyLinesAndUtf8() {
        var splitter = HSLineSplitter()
        let parser = HSSseParser()
        var events: [HSSseEvent] = []
        for byte in Array("id: 1\r\ndata: Ayşe\r\n\r\n".utf8) {
            if let line = splitter.append(byte), let event = parser.feed(line) { events.append(event) }
        }
        XCTAssertEqual(events, [HSSseEvent(event: "message", data: "Ayşe", id: "1")])
    }

    // MARK: Sıra ve tekilleştirme

    func testTimelineSortsAndDeduplicatesBySeq() {
        let merged = HSChatTimeline.merge([message(3), message(1)], [message(2), message(3, status: "read")])
        XCTAssertEqual(merged.map(\.seq), [1, 2, 3])
        XCTAssertEqual(merged.last?.status, "read")
    }

    func testPendingMessageIsReplacedByServerCopy() {
        let pending = message(0, cmid: "m_local001", sender: HSChatMessage.senderVisitor, status: HSChatMessage.statusPending)
        let other = message(0, cmid: "m_local002", sender: HSChatMessage.senderVisitor, status: HSChatMessage.statusPending)
        let before = HSChatTimeline.merge([message(1)], [pending, other])
        XCTAssertEqual(before.map(\.seq), [1, 0, 0])
        let after = HSChatTimeline.merge(before, [message(2, cmid: "m_local001", sender: HSChatMessage.senderVisitor)])
        XCTAssertEqual(after.map(\.seq), [1, 2, 0])
        XCTAssertEqual(after.last?.clientMessageId, "m_local002")
    }

    func testSeenSetIsBounded() {
        let seen = HSChatSeen(capacity: 3)
        XCTAssertTrue(seen.mark("a"))
        XCTAssertFalse(seen.mark("a"))
        XCTAssertTrue(seen.mark(nil))
        _ = seen.mark("b"); _ = seen.mark("c"); _ = seen.mark("d")
        XCTAssertTrue(seen.mark("a"), "kapasite aşılınca en eski unutulur")
    }

    func testBackoffDoublesAndCaps() {
        XCTAssertEqual(HSChatBackoff.delayMs(failures: 1, jitter: 0.5), 1_000)
        XCTAssertEqual(HSChatBackoff.delayMs(failures: 2, jitter: 0.5), 2_000)
        XCTAssertEqual(HSChatBackoff.delayMs(failures: 6, jitter: 0.5), 30_000)
        XCTAssertEqual(HSChatBackoff.delayMs(failures: 40, jitter: 0.5), 30_000)
        XCTAssertEqual(HSChatBackoff.delayMs(failures: 1, jitter: 0), 800)
    }

    // MARK: Ayrıştırma

    func testParsesMessageAndConversation() throws {
        let json: [String: Any] = [
            "message": [
                "id": "cmsg_1", "seq": 12, "client_message_id": NSNull(), "sender": "bot", "author_name": "Asistan", "text": "Seçin",
                "attachments": [["id": "att_1", "name": "a.png", "type": "image/png", "size": 2048]],
                "quick_replies": [["id": "o1", "label": "Satış"], ["id": "o2", "label": "Destek"]],
                "status": "delivered", "created_at": "2026-10-20T10:00:00.000Z",
            ],
            "conversation": ["id": "conv_1", "status": "open", "last_seq": 12, "agent_last_read_seq": 10, "visitor_last_read_seq": 11,
                             "unread_count": 1, "bot_active": true, "assignee_name": NSNull(), "created_at": "2026-10-20T09:59:00Z"],
        ]
        let m = HSChatParser.message(json["message"] as! [String: Any])
        XCTAssertEqual(m.seq, 12)
        XCTAssertNil(m.clientMessageId)
        XCTAssertEqual(m.sender, HSChatMessage.senderBot)
        XCTAssertEqual(m.attachments, [HSChatAttachment(id: "att_1", name: "a.png", type: "image/png", size: 2048)])
        XCTAssertEqual(m.quickReplies?.map(\.id), ["o1", "o2"])
        XCTAssertEqual(m.createdAt?.timeIntervalSince1970, 1_792_490_400)
        XCTAssertEqual(m.dictionary["createdAt"] as? Int64, 1_792_490_400_000)
        XCTAssertTrue(m.dictionary["clientMessageId"] is NSNull)
        let c = try XCTUnwrap(HSChatParser.conversation(json["conversation"]))
        XCTAssertTrue(c.botActive)
        XCTAssertEqual(c.unreadCount, 1)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(m.dictionary))
    }

    func testPageSortedAndEmptyConversationState() {
        let page = HSChatParser.page(["data": [["id": "b", "seq": 5, "sender": "agent"], ["id": "a", "seq": 4, "sender": "visitor"]], "has_more": true])
        XCTAssertEqual(page.messages.map(\.seq), [4, 5])
        XCTAssertTrue(page.hasMore)
        let empty = HSChatParser.conversationState(["conversation": NSNull(), "unread_count": 0])
        XCTAssertNil(empty.conversation)
        XCTAssertEqual(empty.unreadCount, 0)
    }

    func testParsesConfig() {
        let cfg = HSChatParser.config([
            "enabled": true, "online": false, "within_business_hours": false, "color": "#112233", "position": "left", "theme": "dark",
            "offline_message": "Şu an çevrimdışıyız", "collect_email_offline": true, "require_email": false,
            "attachments": ["enabled": true, "max_bytes": 10_485_760, "types": ["image/png", "application/pdf"]], "language": "tr",
        ])
        XCTAssertFalse(cfg.online)
        XCTAssertEqual(cfg.offlineMessage, "Şu an çevrimdışıyız")
        XCTAssertEqual(cfg.attachmentMaxBytes, 10_485_760)
        XCTAssertEqual(cfg.attachmentTypes, ["image/png", "application/pdf"])
    }

    // MARK: Push

    func testParsesChatPushMarker() {
        XCTAssertEqual(HSChatPush.parse(["pushizo_chat": "{\"conversation_id\":\"conv_1\",\"seq\":7}", "aps": [String: Any]()]),
                       HSChatPushInfo(conversationId: "conv_1", seq: 7))
        XCTAssertEqual(HSChatPush.parse(["pushizo_chat": ["conversation_id": "conv_3", "seq": 2]]),
                       HSChatPushInfo(conversationId: "conv_3", seq: 2))
        XCTAssertEqual(HSChatPush.parse(["custom_data": ["pushizo_chat": ["conversation_id": "conv_2", "seq": 3]]]),
                       HSChatPushInfo(conversationId: "conv_2", seq: 3))
        XCTAssertNil(HSChatPush.parse(["aps": ["alert": "Merhaba"]]))
        XCTAssertNil(HSChatPush.parse(["pushizo_chat": "bozuk"]))
    }

    func testEventTypesAndPayloads() {
        let events: [HSChatEvent] = [
            .message(message(1)), .typing(true, name: "Ayşe"), .agentRead(4), .unreadCount(2),
            .conversationUpdated(id: "conv_1", status: "resolved", botActive: false), .connection(true), .error(code: "HS_PLAN_FEATURE_REQUIRED", message: nil),
        ]
        XCTAssertEqual(events.map(\.type), ["message", "typing", "read", "unread", "conversation", "connection", "error"])
        XCTAssertEqual(events[3].payload["count"] as? Int, 2)
        events.forEach { XCTAssertTrue(JSONSerialization.isValidJSONObject($0.payload)) }
    }
}
