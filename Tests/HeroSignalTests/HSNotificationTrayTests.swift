import XCTest
@testable import HeroSignalCore

final class HSNotificationTrayTests: XCTestCase {
    private let entries: [HSNotificationTray.Entry] = [
        .init(identifier: "req-1", threadIdentifier: "orders", userInfo: ["aps": ["alert": "a"], "hs": ["dlv": "dlv_1"]]),
        .init(identifier: "req-2", threadIdentifier: "orders", userInfo: ["aps": ["alert": "b"], "hs": ["dlv": "dlv_2"]]),
        .init(identifier: "req-3", threadIdentifier: "", userInfo: ["aps": ["alert": "c"], "hs": ["dlv": "dlv_3"]]),
        // Uygulamanın kendi bildirimi (hs yok, alert yok) — hiçbir seçimde yer almaz.
        .init(identifier: "app-1", threadIdentifier: "orders", userInfo: ["custom": "1"]),
    ]

    func testMatchesByRequestIdentifierOrDeliveryId() {
        XCTAssertEqual(HSNotificationTray.identifiers(matching: "req-1", in: entries), ["req-1"])
        XCTAssertEqual(HSNotificationTray.identifiers(matching: "dlv_2", in: entries), ["req-2"])
        XCTAssertEqual(HSNotificationTray.identifiers(matching: "app-1", in: entries), [])
        XCTAssertEqual(HSNotificationTray.identifiers(matching: "", in: entries), [])
    }

    func testMatchesByThreadIdentifier() {
        XCTAssertEqual(HSNotificationTray.identifiers(inGroup: "orders", in: entries), ["req-1", "req-2"])
        XCTAssertEqual(HSNotificationTray.identifiers(inGroup: "", in: entries), [])
        XCTAssertEqual(HSNotificationTray.identifiers(inGroup: "none", in: entries), [])
    }
}
