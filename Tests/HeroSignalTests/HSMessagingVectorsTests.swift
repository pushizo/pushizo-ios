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

    func testParsesTriggerGroupsVariantAndNewActions() throws {
        let json = """
        {"id":"iam_g","priority":3,"variant_id":"var_b",
         "triggers":[{"kind":"event","name":"cart_viewed"}],
         "trigger_groups":[
           [{"kind":"event","name":"cart_viewed"},{"kind":"trigger","key":"cart_total","op":"gt","value":100}],
           [{"kind":"session_duration","seconds":30}]],
         "display":{"layout":"modal","dismissible":true,"blocks":[
           {"type":"button","id":"allow","text":"İzin ver","action":{"type":"push_prompt"}},
           {"type":"button","id":"buy","text":"Satın al","action":{"type":"outcome","name":"purchase","value":49.9}},
           {"type":"button","id":"later","text":"Sonra","action":{"type":"outcome","name":"remind_later"}},
           {"type":"button","id":"noname","text":"Bozuk","action":{"type":"outcome"}}]},
         "remaining_impressions":1,"min_interval_seconds":0,"last_impression_at":null,"end_at":null}
        """
        let m = HSInAppParser.parseMessage(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])!
        XCTAssertEqual(m.variantId, "var_b")
        XCTAssertEqual(m.triggerGroups.count, 2)
        XCTAssertEqual(m.triggerGroups[0], m.triggers) // geriye uyum: ilk grup
        XCTAssertEqual(m.triggerGroups[1], [.sessionDuration(30)])
        XCTAssertEqual(m.display.buttons.map(\.id), ["allow", "buy", "later"]) // adsız outcome düğmesi atlanır
        XCTAssertEqual(m.display.buttons[0].action, .pushPrompt)
        XCTAssertEqual(m.display.buttons[1].action, .outcome(name: "purchase", value: 49.9))
        XCTAssertEqual(m.display.buttons[2].action, .outcome(name: "remind_later", value: nil))

        // trigger_groups yok/boş → triggers tek grup; variant_id yok → nil.
        let legacy = HSInAppParser.parseMessage([
            "id": "iam_l", "triggers": [["kind": "screen", "name": "home"]], "trigger_groups": [] as [Any], "variant_id": NSNull(),
            "display": ["layout": "modal", "blocks": [] as [Any]],
        ])!
        XCTAssertEqual(legacy.triggerGroups, [[.screen("home")]])
        XCTAssertNil(legacy.variantId)
        XCTAssertEqual(HSInAppParser.parseTriggerGroups(nil, triggers: []), [[]])
    }

    func testTriggerGroupsAreOrOfAnd() {
        let groups: [[HSInAppTrigger]] = [
            [.event("cart_viewed"), .condition(key: "cart_total", op: "gt", value: .number(100))],
            [.screen("checkout")],
        ]
        XCTAssertFalse(HSInAppRules.matchesAny(groups, cause: .event("cart_viewed"), state: HSInAppState(triggers: ["cart_total": "50"])))
        XCTAssertTrue(HSInAppRules.matchesAny(groups, cause: .event("cart_viewed"), state: HSInAppState(triggers: ["cart_total": "150"])))
        XCTAssertTrue(HSInAppRules.matchesAny(groups, cause: .screen("checkout"), state: HSInAppState(screen: "checkout")))
        XCTAssertFalse(HSInAppRules.matchesAny(groups, cause: .screen("home"), state: HSInAppState(screen: "home")))
        // Boş grup listesi tetiksiz mesaj gibi: yalnızca oturum başı.
        XCTAssertTrue(HSInAppRules.matchesAny([], cause: .sessionStart, state: HSInAppState()))
        XCTAssertFalse(HSInAppRules.matchesAny([], cause: .event("x"), state: HSInAppState()))
    }

    func testSessionDurationFiresOnTimerAndHoldsAfterwards() {
        let duration: [HSInAppTrigger] = [.sessionDuration(30)]
        XCTAssertFalse(HSInAppRules.matches(duration, cause: .sessionDuration, state: HSInAppState(sessionSeconds: 29)))
        XCTAssertTrue(HSInAppRules.matches(duration, cause: .sessionDuration, state: HSInAppState(sessionSeconds: 30)))
        XCTAssertFalse(HSInAppRules.matches(duration, cause: .sessionStart, state: HSInAppState(sessionSeconds: 0)))
        // Olayla birlikte: olay ateşler, süre koşulu sağlanmalı.
        let combined = duration + [.event("cart_viewed")]
        XCTAssertFalse(HSInAppRules.matches(combined, cause: .event("cart_viewed"), state: HSInAppState(sessionSeconds: 10)))
        XCTAssertTrue(HSInAppRules.matches(combined, cause: .event("cart_viewed"), state: HSInAppState(sessionSeconds: 45)))
        XCTAssertFalse(HSInAppRules.matches(combined, cause: .sessionDuration, state: HSInAppState(sessionSeconds: 45))) // olay anı değil

        let a = HSInAppParser.parseMessage(["id": "a", "trigger_groups": [[["kind": "session_duration", "seconds": 60]], [["kind": "session_duration", "seconds": 20]]], "display": ["blocks": [] as [Any]]])!
        let b = HSInAppParser.parseMessage(["id": "b", "triggers": [["kind": "event", "name": "x"]], "display": ["blocks": [] as [Any]]])!
        XCTAssertEqual(HSInAppRules.nextSessionDurationSeconds([a, b], sessionSeconds: 0), 20)
        XCTAssertEqual(HSInAppRules.nextSessionDurationSeconds([a, b], sessionSeconds: 20), 60)
        XCTAssertNil(HSInAppRules.nextSessionDurationSeconds([a, b], sessionSeconds: 60))
        XCTAssertNil(HSInAppRules.nextSessionDurationSeconds([b], sessionSeconds: 0))
    }

    func testGlobalIntervalCoversAllMessages() {
        let t100 = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(HSInAppRules.globalIntervalAllows(minIntervalSeconds: 0, lastImpressionAt: t100, now: Date(timeIntervalSince1970: 101)))
        XCTAssertTrue(HSInAppRules.globalIntervalAllows(minIntervalSeconds: 60, lastImpressionAt: nil, now: t100))
        XCTAssertFalse(HSInAppRules.globalIntervalAllows(minIntervalSeconds: 60, lastImpressionAt: t100, now: Date(timeIntervalSince1970: 159.9)))
        XCTAssertTrue(HSInAppRules.globalIntervalAllows(minIntervalSeconds: 60, lastImpressionAt: t100, now: Date(timeIntervalSince1970: 160)))
        let m = HSInAppParser.parseMessage([
            "id": "iam_x", "priority": 1, "triggers": [["kind": "event", "name": "e"]],
            "display": ["layout": "modal", "dismissible": true, "blocks": [] as [Any]], "remaining_impressions": 5,
        ])!
        XCTAssertNil(HSInAppRules.select([m], cause: .event("e"), state: HSInAppState(), locals: [:], now: Date(timeIntervalSince1970: 150),
                                         globalMinIntervalSeconds: 60, lastImpressionAt: t100))
        XCTAssertEqual(HSInAppRules.select([m], cause: .event("e"), state: HSInAppState(), locals: [:], now: Date(timeIntervalSince1970: 160),
                                           globalMinIntervalSeconds: 60, lastImpressionAt: t100)?.id, "iam_x")
        XCTAssertEqual(HSInAppRules.select([m], cause: .event("e"), state: HSInAppState(), locals: [:], now: Date(timeIntervalSince1970: 150),
                                           globalMinIntervalSeconds: 0, lastImpressionAt: t100)?.id, "iam_x")
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
