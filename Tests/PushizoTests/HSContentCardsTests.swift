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

    private func card(_ type: String, title: String? = "Başlık", image: String? = nil, button: String? = nil) -> HSContentCard {
        var json: [String: Any] = ["id": "cc_1", "type": type]
        if let title { json["title"] = title }
        if let image { json["image_url"] = image }
        if let button { json["button_text"] = button }
        return HSContentCardParser.parseCard(json)!
    }

    /// Hazır görünüm yerleşimi; Android `HsContentCardsLayoutTest` ile aynı kurallar.
    func testLayoutPartsFollowCardType() {
        XCTAssertEqual(HSContentCardLayout.parts(card("classic", image: "https://x/a.png", button: "Aç")), [.text, .button])
        XCTAssertEqual(HSContentCardLayout.parts(card("captioned_image", image: "https://x/a.png")), [.image, .text])
        XCTAssertEqual(HSContentCardLayout.parts(card("captioned_image", title: nil, image: "https://x/a.png")), [.image])
        XCTAssertEqual(HSContentCardLayout.parts(card("captioned_image")), [.text])
        XCTAssertEqual(HSContentCardLayout.parts(card("image_only", image: "https://x/a.png", button: "Aç")), [.image])
        XCTAssertEqual(HSContentCardLayout.parts(card("image_only", button: "Aç")), [.text, .button])
    }

    func testImpressionNeedsHalfVisibleAndStringsFollowLanguage() {
        XCTAssertTrue(HSContentCardLayout.countsAsImpression(visibleHeight: 50, totalHeight: 100))
        XCTAssertFalse(HSContentCardLayout.countsAsImpression(visibleHeight: 49, totalHeight: 100))
        XCTAssertFalse(HSContentCardLayout.countsAsImpression(visibleHeight: 0, totalHeight: 0))
        XCTAssertEqual(HSContentCardStrings.forLanguage("tr-TR").retry, "Tekrar dene")
        XCTAssertEqual(HSContentCardStrings.forLanguage("de").retry, "Try again")
    }
}
