import XCTest
@testable import PushizoCore

/// Faz 39 (ADR-0066): özellik bayrağı kuralları.
final class HSFeatureFlagRulesTests: XCTestCase {
    private let response: [String: Any] = ["flags": [
        "yeni_sepet": ["enabled": true, "value": "mavi"],
        "kapali": ["enabled": false, "value": false],
        "bos": ["enabled": true, "value": NSNull()],
        "bozuk": ["enabled": "x"],
        "metin": "x",
    ]]

    func testParse() throws {
        let cache = try XCTUnwrap(HSFeatureFlagRules.parse(response))
        XCTAssertEqual(Set(cache.keys), ["yeni_sepet", "kapali", "bos"])
        XCTAssertNil(HSFeatureFlagRules.parse([:]))
        XCTAssertNil(HSFeatureFlagRules.parse(["flags": "x"]))
    }

    func testDefaultOnlyForUnknownKey() {
        let cache = HSFeatureFlagRules.parse(response)
        XCTAssertTrue(HSFeatureFlagRules.isEnabled(cache, key: "yeni_sepet", default: false))
        XCTAssertFalse(HSFeatureFlagRules.isEnabled(cache, key: "kapali", default: true))
        XCTAssertTrue(HSFeatureFlagRules.isEnabled(cache, key: "bilinmeyen", default: true))
        XCTAssertFalse(HSFeatureFlagRules.isEnabled(nil, key: "yeni_sepet", default: false))
    }

    func testValue() {
        let cache = HSFeatureFlagRules.parse(response)
        XCTAssertEqual(HSFeatureFlagRules.value(cache, key: "yeni_sepet") as? String, "mavi")
        XCTAssertNil(HSFeatureFlagRules.value(cache, key: "bos"))
        XCTAssertNil(HSFeatureFlagRules.value(cache, key: "bilinmeyen"))
    }

    func testBodyAndSubject() {
        let anonymous = HSFeatureFlagRules.body(subscriptionId: nil, subject: "anon_x", registeredToken: nil, identityHash: nil)
        XCTAssertEqual(anonymous["subject"] as? String, "anon_x")
        let owned = HSFeatureFlagRules.body(subscriptionId: "sub_1", subject: "anon_x", registeredToken: nil, identityHash: "h")
        XCTAssertEqual(owned["subscription_id"] as? String, "sub_1")
        XCTAssertEqual(owned["identity_hash"] as? String, "h")
        XCTAssertNil(owned["subject"])
        let subject = HSFeatureFlagRules.newSubject()
        XCTAssertTrue(subject.hasPrefix("anon_"))
        XCTAssertEqual(subject.count, 37)
        XCTAssertNotEqual(subject, HSFeatureFlagRules.newSubject())
    }
}
