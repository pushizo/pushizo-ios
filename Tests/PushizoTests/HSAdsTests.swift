import XCTest
@testable import PushizoCore

/// ADR-0037: reklam kimliği (IDFA) kuyruk işlemi ve `ads_personalization` rıza kaydı; Android `HsAdsTest` ile aynı vakalar.
final class HSAdsTests: XCTestCase {
    func testNormalizesAdvertisingId() {
        XCTAssertEqual(HSAdsRules.normalize(" AB12CD34-EF56-7890-AB12-CD34EF567890 "), "ab12cd34-ef56-7890-ab12-cd34ef567890")
        XCTAssertNil(HSAdsRules.normalize("00000000-0000-0000-0000-000000000000"))
        XCTAssertNil(HSAdsRules.normalize("not-a-uuid"))
        XCTAssertNil(HSAdsRules.normalize(nil))
    }

    func testOperationAndBody() {
        let op = HSAdsRules.operation(advertisingId: "AB12CD34-EF56-7890-AB12-CD34EF567890", at: 1)
        XCTAssertEqual(op["type"] as? String, HSAdsRules.operationType)
        XCTAssertEqual(HSAdsRules.body(for: op, registeredToken: nil)["advertising_id"] as? String, "ab12cd34-ef56-7890-ab12-cd34ef567890")
        let clear = HSAdsRules.operation(advertisingId: "00000000-0000-0000-0000-000000000000", at: 2)
        XCTAssertEqual(clear["clear"] as? Bool, true)
        XCTAssertTrue(HSAdsRules.body(for: clear, registeredToken: nil)["advertising_id"] is NSNull)
        let token = "a1b2"
        XCTAssertEqual(HSAdsRules.body(for: op, registeredToken: token)["token_hash"] as? String, HSOwnership.tokenHash(token))
    }

    func testOnlyLatestOperationIsSent() {
        let first = HSAdsRules.operation(advertisingId: "ab12cd34-ef56-7890-ab12-cd34ef567890", at: 1)
        let second = HSAdsRules.operation(advertisingId: nil, at: 2)
        let queue: [[String: Any]] = [first, ["type": "event", "at": 1.5], second]
        XCTAssertTrue(HSAdsRules.isSuperseded(first, queue: queue))
        XCTAssertFalse(HSAdsRules.isSuperseded(second, queue: queue))
    }

    func testParsesConsents() throws {
        let json = """
        {"data":[],"categories":[],"consents":[
          {"purpose":"ads_personalization","granted":true,"source":"sdk","updated_at":"2026-10-20T10:00:00Z"},
          {"granted":true}]}
        """
        let result = HSPreferencesParser.parseResult(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
        XCTAssertEqual(result.consents, [HSUserConsent(purpose: HSConsentPurpose.adsPersonalization, granted: true, source: "sdk", updatedAt: HSIsoTime.parse("2026-10-20T10:00:00Z"))])
        let legacy = HSPreferencesParser.parseResult(["data": [], "categories": []])
        XCTAssertTrue(legacy.consents.isEmpty)
        XCTAssertTrue(HSPreferencesParser.isValid([HSPreferenceInput(category: HSConsentPurpose.adsPersonalization, optedIn: false)]))
    }
}
