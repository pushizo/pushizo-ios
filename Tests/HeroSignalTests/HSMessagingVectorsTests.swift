import XCTest
@testable import HeroSignalCore

/// Ortak vektörler (`sdk/testdata/messaging-vectors.json`): Android `HsMessagingVectorsTest` aynı dosyayı kullanır.
final class HSMessagingVectorsTests: XCTestCase {
    private static let vectors: [String: Any] = {
        // Tests/HeroSignalTests/<dosya> → sdk/testdata
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testdata/messaging-vectors.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func list(_ name: String, in json: [String: Any] = vectors) -> [[String: Any]] {
        json[name] as? [[String: Any]] ?? []
    }

    private func string(_ value: Any?) -> String? { value as? String }

    private func cause(_ json: [String: Any]) -> HSInAppCause {
        switch json["kind"] as? String {
        case "session_start": return .sessionStart
        case "event": return .event(json["name"] as! String)
        case "screen": return .screen(json["name"] as! String)
        default: return .triggerChange(Set(json["keys"] as? [String] ?? []))
        }
    }

    private func state(_ json: [String: Any]) -> HSInAppState {
        HSInAppState(screen: json["screen"] as? String, triggers: json["triggers"] as? [String: String] ?? [:])
    }

    private func message(id: String, priority: Int, triggers: [[String: Any]], extra: [String: Any] = [:]) -> HSInAppMessage {
        var json: [String: Any] = [
            "id": id, "priority": priority, "triggers": triggers,
            "display": ["layout": "modal", "dismissible": true, "blocks": [] as [Any]],
        ]
        json.merge(extra) { _, new in new }
        return HSInAppParser.parseMessage(json)!
    }

    func testTriggerVectors() {
        let cases = list("triggers")
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        for c in cases {
            let triggers = HSInAppParser.parseTriggers(c["triggers"] as? [[String: Any]] ?? [])
            let actual = HSInAppRules.matches(triggers, cause: cause(c["cause"] as! [String: Any]), state: state(c["state"] as! [String: Any]))
            XCTAssertEqual(actual, c["expected"] as? Bool, c["name"] as? String ?? "")
        }
    }

    func testFrequencyVectors() {
        for c in list("frequency") {
            let m = message(id: "iam_1", priority: 0, triggers: [], extra: c["message"] as! [String: Any])
            let local = HSLocalImpressions(count: (c["local_impressions"] as? NSNumber)?.intValue ?? 0,
                                           lastAt: string(c["local_last_impression_at"]).flatMap(HSIsoTime.parse),
                                           interacted: c["local_interacted"] as? Bool ?? false)
            let now = HSIsoTime.parse(c["now"] as! String)!
            XCTAssertEqual(HSInAppRules.canDisplay(m, local: local, now: now), c["expected"] as? Bool, c["name"] as? String ?? "")
        }
    }

    func testSelectionVectors() {
        for c in list("selection") {
            let messages = list("messages", in: c).map {
                message(id: $0["id"] as! String, priority: ($0["priority"] as! NSNumber).intValue,
                        triggers: $0["triggers"] as! [[String: Any]], extra: ["remaining_impressions": 1])
            }
            let selected = HSInAppRules.select(messages, cause: cause(c["cause"] as! [String: Any]), state: state(c["state"] as! [String: Any]),
                                               locals: [:], now: Date(timeIntervalSince1970: 0))
            XCTAssertEqual(selected?.id, string(c["expected"]), c["name"] as? String ?? "")
        }
    }

    func testContactNormalization() {
        for c in list("email") { XCTAssertEqual(HSContacts.normalizeEmail(c["input"] as! String), string(c["expected"]), c["input"] as! String) }
        for c in list("phone") { XCTAssertEqual(HSContacts.normalizePhone(c["input"] as! String), string(c["expected"]), c["input"] as! String) }
    }

    func testRegistrationUser() {
        for c in list("registration_user") {
            let user = HSContacts.registrationUser(externalId: string(c["external_id"]), identityHash: string(c["identity_hash"]),
                                                   subscriptionId: string(c["subscription_id"]))
            XCTAssertEqual(user, c["expected"] as? [String: String], c["name"] as? String ?? "")
        }
    }

    func testColorsAndContrast() {
        for c in list("colors") {
            XCTAssertEqual(HSInAppStyle.parseColor(c["input"] as? String).map(HSInAppStyle.format), string(c["expected"]), c["input"] as! String)
        }
        for c in list("contrast") {
            let bg = HSInAppStyle.parseColor(c["background"] as? String)!
            XCTAssertEqual(HSInAppStyle.format(HSInAppStyle.contrastingText(bg)), c["expected"] as? String)
        }
    }
}

final class HSInAppParserTests: XCTestCase {
    func testParsesListAndSkipsInvalidEntries() throws {
        let json = """
        {"language":"tr","data":[
          {"id":"iam_1","priority":10,
           "triggers":[{"kind":"event","name":"cart_viewed"},{"kind":"trigger","key":"cart_total","op":"gt","value":100}],
           "display":{"layout":"banner_bottom","background_color":"#ffffff","text_color":null,"dismissible":false,"auto_dismiss_seconds":8,
             "blocks":[
               {"type":"image","url":"https://cdn.example.com/sale.png","alt":"İndirim"},
               {"type":"title","text":"Merhaba Ayşe"},
               {"type":"body","text":"Sepetin seni bekliyor"},
               {"type":"button","id":"go","text":"Sepete git","action":{"type":"deeplink","url":"myapp://cart"},"background_color":"#18181b","text_color":null},
               {"type":"button","id":"vip","text":"VIP","action":{"type":"tags","tags":{"segment":"vip"}},"background_color":null,"text_color":null},
               {"type":"button","id":"bad","text":"Kötü","action":{"type":"url","url":"javascript:alert(1)"},"background_color":null,"text_color":null},
               {"type":"video","url":"https://cdn.example.com/x.mp4"}]},
           "remaining_impressions":2,"min_interval_seconds":86400,"stop_after_interaction":true,"last_impression_at":"2026-10-06T12:00:00.000Z","end_at":null},
          {"id":"iam_broken","priority":1},
          {"id":"iam_2","priority":0,"triggers":[{"kind":"session_start"}],
           "display":{"layout":"carousel","background_color":null,"text_color":null,"dismissible":true,"auto_dismiss_seconds":null,"blocks":[]},
           "remaining_impressions":1,"min_interval_seconds":0,"last_impression_at":null,"end_at":"2026-12-31T23:59:59+03:00"}]}
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let list = HSInAppParser.parseList(object)
        XCTAssertEqual(list.map(\.id), ["iam_1", "iam_2"])

        let m = list[0]
        XCTAssertEqual(m.triggers, [.event("cart_viewed"), .condition(key: "cart_total", op: "gt", value: .number(100))])
        XCTAssertEqual(m.display.layout, .bannerBottom)
        XCTAssertFalse(m.display.dismissible)
        XCTAssertEqual(m.display.autoDismissSeconds, 8)
        XCTAssertNil(m.display.textColor)
        XCTAssertEqual(m.display.blocks.count, 5)
        XCTAssertEqual(m.display.blocks[0], .image(url: "https://cdn.example.com/sale.png", alt: "İndirim"))
        XCTAssertEqual(m.display.buttons.map(\.id), ["go", "vip"])
        XCTAssertEqual(m.display.buttons[0].action, .deeplink("myapp://cart"))
        XCTAssertEqual(m.display.buttons[1].action, .tags(["segment": "vip"]))
        XCTAssertEqual(m.minIntervalSeconds, 86_400)
        XCTAssertTrue(m.stopAfterInteraction)
        XCTAssertFalse(list[1].stopAfterInteraction)
        XCTAssertEqual(m.lastImpressionAt, HSIsoTime.parse("2026-10-06T12:00:00Z"))

        XCTAssertEqual(list[1].display.layout, .modal)
        XCTAssertNil(list[1].display.autoDismissSeconds)
        XCTAssertEqual(list[1].endAt, HSIsoTime.parse("2026-12-31T20:59:59Z"))
    }

    func testIsoTime() {
        XCTAssertEqual(HSIsoTime.parse("1970-01-01T00:00:00Z"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(HSIsoTime.parse("1970-01-01T00:00:01.5Z"), Date(timeIntervalSince1970: 1.5))
        XCTAssertEqual(HSIsoTime.parse("2025-10-07T12:00:00Z"), Date(timeIntervalSince1970: 1_759_838_400))
        XCTAssertEqual(HSIsoTime.parse("2025-10-07T15:00:00+03:00"), HSIsoTime.parse("2025-10-07T12:00:00Z"))
        XCTAssertNil(HSIsoTime.parse("2025-10-07"))
    }

    func testInboxPage() throws {
        let json = """
        {"data":[
          {"id":"ibx_2","message_id":"msg_2","title":"Kargo","body":"Siparişin yolda","url":"myapp://orders/2","image_url":null,
           "data":{"order":"2"},"read":false,"read_at":null,"archived_at":null,"expires_at":"2026-11-01T00:00:00Z","created_at":"2026-10-07T10:00:00Z"},
          {"id":"ibx_1","message_id":null,"title":null,"body":"Hoş geldin","url":null,"image_url":"https://cdn.example.com/a.png",
           "data":{},"read":true,"read_at":"2026-10-06T09:00:00Z","archived_at":null,"expires_at":null,"created_at":"2026-10-06T08:00:00Z"}],
         "unread_count":1,"next_cursor":"c2","has_more":true}
        """
        let page = HSInboxParser.parsePage(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
        XCTAssertEqual(page.items.map(\.id), ["ibx_2", "ibx_1"])
        XCTAssertEqual(page.unreadCount, 1)
        XCTAssertEqual(page.nextCursor, "c2")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items[0].data, ["order": "2"])
        XCTAssertFalse(page.items[0].read)
        XCTAssertNil(page.items[0].imageUrl)
        XCTAssertEqual(page.items[0].createdAt, HSIsoTime.parse("2026-10-07T10:00:00Z"))
        XCTAssertNil(page.items[1].title)
        XCTAssertTrue(page.items[1].read)
    }

    func testLocalImpressionsLimitSelection() {
        let m = HSInAppParser.parseMessage([
            "id": "iam_x", "priority": 1, "triggers": [["kind": "event", "name": "e"]],
            "display": ["layout": "modal", "dismissible": true, "blocks": [] as [Any]],
            "remaining_impressions": 2, "min_interval_seconds": 0,
        ])!
        let now = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(HSInAppRules.select([m], cause: .event("e"), state: HSInAppState(), locals: ["iam_x": HSLocalImpressions(count: 1)], now: now)?.id, "iam_x")
        XCTAssertNil(HSInAppRules.select([m], cause: .event("e"), state: HSInAppState(), locals: ["iam_x": HSLocalImpressions(count: 2)], now: now))
    }
}
