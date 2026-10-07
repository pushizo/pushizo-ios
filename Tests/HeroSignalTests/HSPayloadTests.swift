import XCTest
@testable import HeroSignalCore

final class HSPayloadTests: XCTestCase {
    func testParsesApsAndHs() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Başlık", "body": "Gövde"], "sound": "default"],
            "hs": ["delivery_id": "dlv_1", "url": "myapp://orders/7", "image": "https://img", "actions": [["id": "track", "title": "Takip et", "url": "https://x/t"], ["id": "later", "title": "Sonra"]]],
            "hs_message_id": "msg_1",
            "order_id": "7",
        ]
        let n = HSNotification(userInfo: userInfo)
        XCTAssertNotNil(n)
        XCTAssertEqual(n?.title, "Başlık")
        XCTAssertEqual(n?.deliveryId, "dlv_1")
        XCTAssertEqual(n?.messageId, "msg_1")
        XCTAssertEqual(n?.actions.count, 2)
        XCTAssertEqual(n?.url(forAction: "track"), "https://x/t")
        XCTAssertEqual(n?.url(forAction: "later"), "myapp://orders/7")
        XCTAssertEqual(n?.data, ["order_id": "7"])
    }

    func testParsesNewHsShapeWithButtons() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T", "body": "B"], "mutable-content": 1],
            "hs": ["dlv": "dlv_9", "delivery_id": "dlv_9", "msg": "msg_9", "url": "https://x/n", "image": "https://img",
                   "buttons": [["id": "ok", "title": "Tamam", "icon": "https://i"]], "actions": [["id": "legacy", "title": "Eski"]], "badge_inc": 1],
        ]
        let n = HSNotification(userInfo: userInfo)
        XCTAssertEqual(n?.deliveryId, "dlv_9")
        XCTAssertEqual(n?.messageId, "msg_9")
        XCTAssertEqual(n?.actions, [HSAction(id: "ok", title: "Tamam", url: nil, icon: "https://i")])
        XCTAssertEqual(n?.badgeIncrement, 1)
        XCTAssertNil(n?.badgeSet)
    }

    func testNonHeroSignalPayloadReturnsNil() {
        XCTAssertNil(HSNotification(userInfo: ["aps": ["content-available": 1]]))
    }

    func testQueueMergesConsecutiveTagPatches() {
        let merged = HSQueue.mergeTail([
            ["type": "tags", "tags": ["a": "1"], "at": 1],
            ["type": "tags", "tags": ["b": "2", "a": NSNull()], "at": 2],
        ])
        XCTAssertEqual(merged.count, 1)
        let tags = merged[0]["tags"] as? [String: Any]
        XCTAssertEqual(tags?["b"] as? String, "2")
        XCTAssertTrue(tags?["a"] is NSNull)
    }

    func testLeadingEventsAreCappedAtBatchMax() {
        let events: [[String: Any]] = (0..<150).map { ["type": "event", "name": "e\($0)", "at": $0] }
        let tag: [String: Any] = ["type": "tags", "tags": [String: Any](), "at": 999]
        XCTAssertEqual(HSQueue.leadingEvents(events + [tag]).count, HSQueue.eventBatchMax)
        XCTAssertEqual(HSQueue.leadingEvents([tag] + events).count, 0)
    }
}
