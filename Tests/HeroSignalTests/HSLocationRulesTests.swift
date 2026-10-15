import XCTest
@testable import HeroSignalCore

/// v2 Faz 17b — konum paylaşımı kuralları: aralık, doğrulama, kuyruk işlemi ve PATCH gövdesi.
final class HSLocationRulesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "hs.tests.location.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testIsDueRequiresSharingConsentAndPermission() {
        let now: TimeInterval = 1_000_000
        XCTAssertTrue(HSLocationRules.isDue(shared: true, networkAllowed: true, permissionGranted: true, lastSentAt: nil, now: now))
        XCTAssertFalse(HSLocationRules.isDue(shared: false, networkAllowed: true, permissionGranted: true, lastSentAt: nil, now: now))
        XCTAssertFalse(HSLocationRules.isDue(shared: true, networkAllowed: false, permissionGranted: true, lastSentAt: nil, now: now), "onay yokken gönderilmez")
        XCTAssertFalse(HSLocationRules.isDue(shared: true, networkAllowed: true, permissionGranted: false, lastSentAt: nil, now: now), "izin yokken gönderilmez")
        // `force` izin/onay kuralını aşmaz.
        XCTAssertFalse(HSLocationRules.isDue(shared: true, networkAllowed: true, permissionGranted: false, lastSentAt: nil, now: now, force: true))
    }

    func testIsDueHonoursFiveMinuteInterval() {
        let now: TimeInterval = 1_000_000
        let due = { (last: TimeInterval?, force: Bool) in
            HSLocationRules.isDue(shared: true, networkAllowed: true, permissionGranted: true, lastSentAt: last, now: now, force: force)
        }
        XCTAssertFalse(due(now - HSLocationRules.minInterval + 1, false))
        XCTAssertTrue(due(now - HSLocationRules.minInterval, false))
        XCTAssertTrue(due(now - 10, true), "paylaşım yeni açıldıysa aralık beklenmez")
        XCTAssertTrue(due(now + 60, false), "saat geri alındıysa bekleme kilitlenmez")
    }

    func testPayloadValidatesRoundsAndClampsAccuracy() {
        let payload = HSLocationRules.payload(latitude: 41.00823456, longitude: 28.97841234, accuracy: 12.34)
        XCTAssertEqual(payload?["lat"] as? Double, 41.008235)
        XCTAssertEqual(payload?["lng"] as? Double, 28.978412)
        XCTAssertEqual(payload?["accuracy_m"] as? Double, 12.3)
        XCTAssertEqual(HSLocationRules.payload(latitude: 1, longitude: 2, accuracy: 5_000_000)?["accuracy_m"] as? Double, HSLocationRules.maxAccuracyMeters)
        // CoreLocation geçersiz doğruluğu negatif verir: alan gönderilmez.
        XCTAssertNil(HSLocationRules.payload(latitude: 1, longitude: 2, accuracy: -1)?["accuracy_m"])
        XCTAssertNil(HSLocationRules.payload(latitude: 1, longitude: 2, accuracy: nil)?["accuracy_m"])
        XCTAssertNil(HSLocationRules.payload(latitude: 90.5, longitude: 0, accuracy: nil))
        XCTAssertNil(HSLocationRules.payload(latitude: 0, longitude: -181, accuracy: nil))
        XCTAssertNil(HSLocationRules.payload(latitude: .nan, longitude: 0, accuracy: nil))
    }

    func testBodyCarriesLocationOrNullWithOwnershipProof() throws {
        let token = "abc123"
        let location = try XCTUnwrap(HSLocationRules.payload(latitude: 41, longitude: 29, accuracy: 30))
        let body = try XCTUnwrap(HSLocationRules.body(for: HSLocationRules.operation(location: location, at: 1), registeredToken: token))
        XCTAssertEqual((body["location"] as? [String: Any])?["lat"] as? Double, 41)
        XCTAssertEqual((body["location"] as? [String: Any])?["accuracy_m"] as? Double, 30)
        XCTAssertEqual(body["token_hash"] as? String, HSOwnership.tokenHash(token))

        let clear = try XCTUnwrap(HSLocationRules.body(for: HSLocationRules.clearOperation(at: 2), registeredToken: token))
        XCTAssertTrue(clear["location"] is NSNull, "kapatma location: null gönderir")
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: clear, options: [.sortedKeys]), encoding: .utf8))
        XCTAssertTrue(json.contains("\"location\":null"))

        // Bozuk işlem atılır.
        XCTAssertNil(HSLocationRules.body(for: ["type": "location", "location": ["lat": 200, "lng": 0], "at": 3], registeredToken: token))
    }

    func testOperationsArePropertyListsAndLatestWins() async {
        let queue = HSQueue(defaults: defaults, appId: "app_1")
        let first = HSLocationRules.operation(location: ["lat": 1.0, "lng": 2.0], at: 1)
        queue.enqueue(first)
        queue.enqueue(["type": "tags", "tags": ["a": "1"], "at": 2])
        queue.enqueue(HSLocationRules.clearOperation(at: 3))
        // UserDefaults'a yazılabildi (NSNull içermez).
        XCTAssertEqual(queue.count, 3)

        var sent: [[String: Any]] = []
        let complete = await queue.flush { op in
            if op["type"] as? String == HSLocationRules.operationType,
               HSLocationRules.isSuperseded(op, queue: queue.items) { return }
            sent.append(op)
        }
        XCTAssertTrue(complete)
        XCTAssertEqual(sent.compactMap { $0["type"] as? String }, ["tags", "location"])
        XCTAssertTrue(HSLocationRules.isClear(sent[1]), "henüz gönderilmemiş eski konum gönderilmez; son durum (kapatma) gider")
        XCTAssertEqual(queue.count, 0)
    }

    func testStoragePersistsSharingState() {
        let store = HSStorage(appId: "app_1", appGroup: suiteName)
        XCTAssertFalse(store.locationShared)
        XCTAssertNil(store.locationLastSentAt)
        store.locationShared = true
        store.locationLastSentAt = 123
        // Aynı depo yeniden açılınca (uygulama yeniden başlatıldı) tercih korunur.
        let reopened = HSStorage(appId: "app_1", appGroup: suiteName)
        XCTAssertTrue(reopened.locationShared)
        XCTAssertEqual(reopened.locationLastSentAt, 123)
        reopened.locationLastSentAt = nil
        XCTAssertNil(store.locationLastSentAt)
    }
}
