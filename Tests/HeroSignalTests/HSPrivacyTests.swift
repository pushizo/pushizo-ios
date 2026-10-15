import XCTest
@testable import HeroSignalCore

/// Gizlilik onayı, NSE `received` kalıcılığı, olay sahiplik kanıtı ve cihaz bilgisi.
final class HSPrivacyTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "hs.tests.privacy.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testConsentGate() {
        XCTAssertTrue(HSConsent.allowsNetwork(required: false, given: false))
        XCTAssertFalse(HSConsent.allowsNetwork(required: true, given: false))
        XCTAssertTrue(HSConsent.allowsNetwork(required: true, given: true))
    }

    func testExtensionReadsConsentWrittenByApp() {
        // Uygulama ve NSE aynı App Group deposunu kullanır.
        let app = HSStorage(appId: "app_1", appGroup: suiteName)
        let nse = HSStorage(appId: "app_1", appGroup: suiteName)
        XCTAssertTrue(HSConsent.allowsNetwork(storage: nse))
        app.privacyConsentRequired = true
        XCTAssertFalse(HSConsent.allowsNetwork(storage: nse), "onay verilmeden NSE ağ çağrısı yapmaz")
        app.consentGiven = true
        XCTAssertTrue(HSConsent.allowsNetwork(storage: nse))
        app.consentGiven = false
        XCTAssertFalse(HSConsent.allowsNetwork(storage: nse), "geri çekilen onay NSE'de de geçerlidir")
        // NSE kendi seçeneğiyle onay ister (App Group paylaşılmasa bile zorunluluk kaybolmaz).
        app.privacyConsentRequired = false
        XCTAssertFalse(HSConsent.allowsNetwork(storage: nse, required: true))
    }

    func testPendingReceivedIsPersistedDeduplicatedAndTaken() {
        let store = HSStorage(appId: "app_1", appGroup: suiteName)
        store.addPendingReceived("d1")
        store.addPendingReceived("d2")
        store.addPendingReceived("d1")
        XCTAssertEqual(store.pendingReceived, ["d1", "d2"])
        store.removePendingReceived("d1")
        XCTAssertEqual(store.pendingReceived, ["d2"])
        XCTAssertEqual(store.takePendingReceived(), ["d2"])
        XCTAssertEqual(store.pendingReceived, [])
        for i in 0..<(HSStorage.pendingReceivedMax + 5) { store.addPendingReceived("x\(i)") }
        XCTAssertEqual(store.pendingReceived.count, HSStorage.pendingReceivedMax)
        XCTAssertEqual(store.pendingReceived.first, "x5", "en eski kayıtlar atılır")
    }

    func testClearIdentityDropsPendingIdentityOperation() {
        let store = HSStorage(appId: "app_1", appGroup: suiteName)
        store.externalId = "user_42"
        store.pendingIdentityOperation = "login"
        store.optedInSyncPending = true
        store.syncedPushCapable = false
        store.clearIdentity()
        XCTAssertNil(store.externalId)
        XCTAssertNil(store.pendingIdentityOperation)
        // Opt-in tercihi ve sunucuya yazılan izin kimlikten bağımsızdır.
        XCTAssertTrue(store.optedInSyncPending)
        XCTAssertEqual(store.syncedPushCapable, false)
        store.syncedPushCapable = nil
        XCTAssertNil(store.syncedPushCapable)
    }

    func testEventItemsCarryOwnershipProof() {
        let ops: [[String: Any]] = [
            ["type": "event", "name": "purchase", "properties": ["sku": "A1"], "occurred_at": "2026-10-14T10:00:00Z", "value": 49.9],
            ["type": "event", "name": "viewed", "properties": [String: Any](), "occurred_at": "2026-10-14T10:00:01Z"],
        ]
        let identity = String(repeating: "b", count: 64)
        let items = HSOwnership.eventItems(ops, subscriptionId: "sub_1", registeredToken: "tok_a", identityHash: identity)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["name"] as? String, "purchase")
        XCTAssertEqual(items[0]["subscription_id"] as? String, "sub_1")
        XCTAssertEqual(items[0]["value"] as? Double, 49.9)
        XCTAssertEqual(items[0]["token_hash"] as? String, HSOwnership.tokenHash("tok_a"))
        XCTAssertEqual(items[1]["identity_hash"] as? String, identity)
        XCTAssertNil(items[1]["value"])
        XCTAssertNil(items[0]["type"], "kuyruk alanları gönderilmez")

        let anonymous = HSOwnership.eventItems(ops, subscriptionId: "sub_1", registeredToken: nil, identityHash: nil)
        XCTAssertNil(anonymous[0]["token_hash"])
        XCTAssertNil(anonymous[0]["identity_hash"])
        XCTAssertNil(anonymous[0]["event_id"], "eski kuyruk öğesinde event_id yok")
    }

    func testEventItemsForwardClientEventId() {
        let ops: [[String: Any]] = [["type": "event", "name": "viewed", "properties": [String: Any](), "occurred_at": "2026-10-14T10:00:01Z", "event_id": "e-123456789"]]
        let items = HSOwnership.eventItems(ops, subscriptionId: "sub_1", registeredToken: nil, identityHash: nil)
        XCTAssertEqual(items[0]["event_id"] as? String, "e-123456789")
    }

    func testDeviceInfoOmitsUnknownAppVersion() {
        let unknown = HSDeviceInfo.make(model: "iPhone", osVersion: "17.0", appVersion: nil, sdkVersion: "0.1.0", locale: "tr-TR", timezone: "Europe/Istanbul", pushCapable: false, pushEnvironment: "sandbox")
        XCTAssertFalse(unknown.keys.contains("app_version"), "bilinmeyen sürüm JSON null olarak gönderilmez")
        XCTAssertEqual(unknown["push_capable"] as? Bool, false)
        XCTAssertEqual(unknown["sdk_platform"] as? String, "ios")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(unknown))

        let known = HSDeviceInfo.make(model: "iPhone", osVersion: "17.0", appVersion: "2.3.1", sdkVersion: "0.1.0", locale: "tr-TR", timezone: "Europe/Istanbul", pushCapable: true, pushEnvironment: "production")
        XCTAssertEqual(known["app_version"] as? String, "2.3.1")
        XCTAssertEqual(known["push_capable"] as? Bool, true)
    }
}
