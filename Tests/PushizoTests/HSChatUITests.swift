import XCTest
@testable import PushizoCore

/// Hazır sohbet arayüzünün (`HSChatViewController`) saf kuralları.
final class HSChatUITests: XCTestCase {
    private func config(online: Bool = true, collectEmailOffline: Bool = false, requireEmail: Bool = false, maxBytes: Int = 5 * 1024 * 1024, types: [String] = []) -> HSChatConfig {
        HSChatConfig(
            enabled: true, online: online, withinBusinessHours: online, color: nil, textColor: nil, position: "right", theme: "auto",
            title: nil, greeting: nil, offlineMessage: nil, collectEmailOffline: collectEmailOffline, requireEmail: requireEmail,
            attachmentsEnabled: true, attachmentMaxBytes: maxBytes, attachmentTypes: types, language: "tr"
        )
    }

    private func message(_ seq: Int, _ sender: String, status: String = HSChatMessage.statusSent, name: String? = nil, text: String? = "merhaba",
                         replies: [HSChatQuickReply]? = nil, attachments: [HSChatAttachment] = []) -> HSChatMessage {
        HSChatMessage(id: seq > 0 ? "m\(seq)" : nil, seq: seq, clientMessageId: "c-\(seq)-\(sender)", sender: sender, authorName: name, text: text,
                      attachments: attachments, quickReplies: replies, status: status, createdAt: nil)
    }

    func testModeFollowsConversationOfflineAndEmailRules() {
        XCTAssertEqual(HSChatUI.mode(config: config(), hasConversation: false, emailProvided: false), .conversation)
        XCTAssertEqual(HSChatUI.mode(config: config(requireEmail: true), hasConversation: false, emailProvided: false), .preChat)
        XCTAssertEqual(HSChatUI.mode(config: config(requireEmail: true), hasConversation: false, emailProvided: true), .conversation)
        XCTAssertEqual(HSChatUI.mode(config: config(online: false, collectEmailOffline: true), hasConversation: false, emailProvided: false), .offlineForm)
        XCTAssertEqual(HSChatUI.mode(config: config(online: false), hasConversation: false, emailProvided: false), .conversation)
        // Süren konuşma her zaman akışı gösterir.
        XCTAssertEqual(HSChatUI.mode(config: config(online: false, collectEmailOffline: true, requireEmail: true), hasConversation: true, emailProvided: false), .conversation)
    }

    func testColorAcceptsOnlySixDigitHex() {
        let rgb = HSChatUI.rgb("#1A2b3C")
        XCTAssertEqual(rgb?.red, 0x1A)
        XCTAssertEqual(rgb?.green, 0x2B)
        XCTAssertEqual(rgb?.blue, 0x3C)
        for bad in [nil, "", "#fff", "1a2b3c", "#1a2b3g", "#-1a2b3", "red", "#1a2b3c;"] { XCTAssertNil(HSChatUI.rgb(bad)) }
        XCTAssertTrue(HSChatUI.needsLightText(red: 0, green: 0, blue: 0))
        XCTAssertTrue(HSChatUI.needsLightText(red: 0, green: 80, blue: 200))
        XCTAssertFalse(HSChatUI.needsLightText(red: 255, green: 255, blue: 255))
        XCTAssertFalse(HSChatUI.needsLightText(red: 255, green: 230, blue: 0))
    }

    func testStatusBelongsToLastVisitorMessage() {
        let strings = HSChatStrings.forLanguage("en")
        let list = [message(1, "visitor"), message(2, "agent"), message(3, "visitor", status: HSChatMessage.statusDelivered), message(4, "bot")]
        XCTAssertEqual(HSChatUI.statusIndex(list), 2)
        XCTAssertNil(HSChatUI.statusIndex([message(1, "agent")]))
        XCTAssertEqual(HSChatUI.statusText(list[2], agentLastReadSeq: 0, strings: strings), strings.delivered)
        XCTAssertEqual(HSChatUI.statusText(list[2], agentLastReadSeq: 3, strings: strings), strings.read)
        XCTAssertEqual(HSChatUI.statusText(list[0], agentLastReadSeq: 0, strings: strings), strings.sent)
        XCTAssertEqual(HSChatUI.statusText(message(0, "visitor", status: HSChatMessage.statusPending), agentLastReadSeq: 9, strings: strings), strings.sending)
        XCTAssertEqual(HSChatUI.statusText(message(5, "visitor", status: HSChatMessage.statusRead), agentLastReadSeq: 0, strings: strings), strings.read)
    }

    func testSenderAndAccessibilityLabels() {
        let strings = HSChatStrings.forLanguage("en")
        XCTAssertNil(HSChatUI.senderLabel(message(1, "visitor"), strings: strings))
        XCTAssertNil(HSChatUI.senderLabel(message(1, "system"), strings: strings))
        XCTAssertEqual(HSChatUI.senderLabel(message(1, "agent", name: "Ayşe"), strings: strings), "Ayşe")
        XCTAssertEqual(HSChatUI.senderLabel(message(1, "agent", name: " "), strings: strings), strings.agent)
        XCTAssertEqual(HSChatUI.senderLabel(message(1, "bot"), strings: strings), strings.bot)
        XCTAssertEqual(HSChatUI.accessibilityLabel(message(1, "visitor", text: "selam"), strings: strings), "\(strings.you): selam")
        let withFile = message(2, "agent", name: "Ayşe", text: nil, attachments: [HSChatAttachment(id: "a", name: "fatura.pdf", type: "application/pdf", size: 10)])
        XCTAssertEqual(HSChatUI.accessibilityLabel(withFile, strings: strings), "Ayşe: fatura.pdf")
    }

    func testQuickRepliesOnlyForTrailingBotQuestion() {
        let replies = [HSChatQuickReply(id: "o1", label: "Evet"), HSChatQuickReply(id: "o2", label: "Hayır")]
        XCTAssertEqual(HSChatUI.quickReplies([message(1, "bot", replies: replies)]), replies)
        XCTAssertTrue(HSChatUI.quickReplies([message(1, "bot", replies: replies), message(2, "visitor")]).isEmpty)
        XCTAssertTrue(HSChatUI.quickReplies([message(1, "agent")]).isEmpty)
        XCTAssertTrue(HSChatUI.quickReplies([]).isEmpty)
    }

    func testReadTargetAdvancesOnlyForOtherPartyMessages() {
        let list = [message(1, "visitor"), message(2, "agent"), message(3, "bot"), message(4, "visitor")]
        XCTAssertEqual(HSChatUI.readTarget(list, alreadyRead: 0), 3)
        XCTAssertNil(HSChatUI.readTarget(list, alreadyRead: 3))
        XCTAssertNil(HSChatUI.readTarget([message(1, "visitor")], alreadyRead: 0))
    }

    func testAttachmentChecks() {
        XCTAssertEqual(HSChatUI.mimeType(fileName: "Foto.JPG"), "image/jpeg")
        XCTAssertEqual(HSChatUI.mimeType(fileName: "not.txt"), "text/plain")
        XCTAssertNil(HSChatUI.mimeType(fileName: "arsiv.zip"))
        XCTAssertNil(HSChatUI.mimeType(fileName: "uzantisiz"))
        XCTAssertEqual(HSChatUI.checkAttachment(fileName: "a.png", size: 1024, config: config()), .ok(mimeType: "image/png"))
        XCTAssertEqual(HSChatUI.checkAttachment(fileName: "a.png", size: 6 * 1024 * 1024, config: config()), .tooLarge)
        XCTAssertEqual(HSChatUI.checkAttachment(fileName: "a.zip", size: 10, config: config()), .unsupported)
        XCTAssertEqual(HSChatUI.checkAttachment(fileName: "a.pdf", size: 10, config: config(types: ["image/png"])), .unsupported)
        // App sınırı sunucu tavanını (10 MB) aşamaz; sınır verilmemişse tavan uygulanır.
        XCTAssertEqual(HSChatUI.checkAttachment(fileName: "a.pdf", size: 11 * 1024 * 1024, config: config(maxBytes: 50 * 1024 * 1024)), .tooLarge)
        XCTAssertEqual(HSChatUI.checkAttachment(fileName: "a.pdf", size: 9 * 1024 * 1024, config: config(maxBytes: 0)), .ok(mimeType: "application/pdf"))
    }

    func testStringsFillPlaceholdersInEveryLanguage() {
        for code in ["tr", "en", "de", "ar", "ja", "pt-BR", "zh-CN"] {
            let strings = HSChatStrings.forLanguage(code)
            XCTAssertFalse(strings.title.isEmpty, code)
            XCTAssertFalse(strings.typing(name: "Ayşe").contains("{"), code)
            XCTAssertTrue(strings.typing(name: "Ayşe").contains("Ayşe"), code)
            XCTAssertTrue(strings.typing(name: nil).contains(strings.agent), code)
            XCTAssertTrue(strings.tooLarge(maxBytes: 5 * 1024 * 1024).contains("5"), code)
            XCTAssertFalse(strings.tooLarge(maxBytes: 100).contains("{"), code)
        }
        XCTAssertEqual(HSChatStrings.forLanguage("tr").send, "Gönder")
        XCTAssertEqual(HSChatStrings.forLanguage("fi"), HSChatStrings.forLanguage("en"), "desteklenmeyen dil İngilizceye düşer")
    }
}
