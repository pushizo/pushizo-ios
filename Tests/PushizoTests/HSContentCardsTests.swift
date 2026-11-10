import XCTest
@testable import PushizoCore

/// İçerik kartı ayrıştırma (ADR-0082); Android `HsContentCardsTest` ile aynı senaryo.
final class HSContentCardsTests: XCTestCase {
    func testFeedParsesCardsAndUnknownTypeFallsBackToClassic() throws {
        let json = """
        {"unviewed_count":1,"data":[
          {"id":"inb_1","type":"captioned_image","title":"Kampanya","image_url":"https://cdn/x.png","button_text":"İncele",
           "pinned":true,"priority":70,"viewed":false,"clicked":false,"data":{"k":"v"},"created_at":"2026-11-10T10:00:00.000Z"},
          {"id":"inb_2","type":"gelecekte","viewed":true,"expires_at":null}
        ]}
        """
        let feed = HSContentCardParser.parseFeed(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
        XCTAssertEqual(feed.unviewedCount, 1)
        XCTAssertEqual(feed.cards.count, 2)
        let first = feed.cards[0]
        XCTAssertEqual(first.type, .captionedImage)
        XCTAssertEqual(first.buttonText, "İncele")
        XCTAssertTrue(first.pinned)
        XCTAssertEqual(first.priority, 70)
        XCTAssertEqual(first.data, ["k": "v"])
        XCTAssertEqual(first.createdAt, HSIsoTime.parse("2026-11-10T10:00:00.000Z"))
        let second = feed.cards[1]
        XCTAssertEqual(second.type, .classic)
        XCTAssertTrue(second.viewed)
        XCTAssertFalse(second.clicked)
        XCTAssertNil(second.expiresAt)
    }

    func testCardWithoutIdIsSkipped() {
        XCTAssertNil(HSContentCardParser.parseCard(["title": "kimliksiz"]))
    }
}
