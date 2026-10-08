import XCTest
@testable import HeroSignalCore

/// Tercih modelleri (ADR-0019 §4): yanıt ayrıştırma ve girdi doğrulama; Android `HsPreferencesTest` ile aynı vakalar.
final class HSPreferencesTests: XCTestCase {
    func testParsesPreferencesResult() throws {
        let json = """
        {"data":[
          {"category":"promos","channel":null,"opted_in":false,"explicit":true,"source":"sdk","updated_at":"2026-10-07T10:00:00Z"},
          {"category":"orders","channel":"ios_push","opted_in":true,"explicit":false,"source":null,"updated_at":null}],
         "categories":[
          {"key":"promos","name":{"tr":"Kampanyalar","en":"Promotions"},"description":{"tr":"İndirimler"},"channels":["ios_push","email"],"default_opted_in":false},
          {"key":"orders","name":{"en":"Orders"},"description":{},"channels":null,"default_opted_in":true},
          {"name":{"en":"Anahtarsız"}}]}
        """
        let result = HSPreferencesParser.parseResult(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
        XCTAssertEqual(result.preferences.count, 2)
        let promos = result.preferences[0]
        XCTAssertNil(promos.channel)
        XCTAssertFalse(promos.optedIn)
        XCTAssertTrue(promos.explicit)
        XCTAssertEqual(promos.source, "sdk")
        XCTAssertEqual(promos.updatedAt, HSIsoTime.parse("2026-10-07T10:00:00Z"))
        XCTAssertEqual(result.preferences[1].channel, "ios_push")
        XCTAssertNil(result.preferences[1].updatedAt)

        XCTAssertEqual(result.categories.map(\.key), ["promos", "orders"]) // anahtarsız kategori atlanır
        let cat = result.categories[0]
        XCTAssertEqual(cat.localizedName("tr"), "Kampanyalar")
        XCTAssertEqual(cat.localizedName("de"), "Promotions") // İngilizce yedek
        XCTAssertEqual(cat.channels, ["ios_push", "email"])
        XCTAssertFalse(cat.defaultOptedIn)
        XCTAssertNil(result.categories[1].channels)
        XCTAssertEqual(result.categories[1].localizedName("tr"), "Orders")
        XCTAssertTrue(result.categories[1].defaultOptedIn)
    }

    func testValidatesAndSerializesInput() {
        let inputs = [HSPreferenceInput(category: "promos", optedIn: false), HSPreferenceInput(category: "orders", channel: "email", optedIn: true)]
        XCTAssertTrue(HSPreferencesParser.isValid(inputs))
        XCTAssertTrue(inputs[0].json["channel"] is NSNull)
        XCTAssertEqual(inputs[0].json["opted_in"] as? Bool, false)
        XCTAssertEqual(inputs[1].json["channel"] as? String, "email")

        XCTAssertFalse(HSPreferencesParser.isValid([]))
        XCTAssertFalse(HSPreferencesParser.isValid([HSPreferenceInput(category: "", optedIn: true)]))
        XCTAssertFalse(HSPreferencesParser.isValid([HSPreferenceInput(category: "promos", channel: "fax", optedIn: true)]))
    }
}
