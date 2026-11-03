import XCTest
@testable import PushizoCore

/// Faz 38 (ADR-0065): arka plan bölge izleme kuralları.
final class HSGeofenceRulesTests: XCTestCase {
    private let now: TimeInterval = 1_800_000_000

    private func due(enabled: Bool = true, lastSyncAt: TimeInterval?, latitude: Double = 41, longitude: Double = 29) -> Bool {
        HSGeofenceRules.isSyncDue(enabled: enabled, lastSyncAt: lastSyncAt, lastLatitude: 41, lastLongitude: 29, latitude: latitude, longitude: longitude, now: now)
    }

    func testSyncRules() {
        XCTAssertFalse(due(enabled: false, lastSyncAt: nil))
        XCTAssertTrue(due(lastSyncAt: nil))
        XCTAssertFalse(due(lastSyncAt: now - HSGeofenceRules.syncInterval + 1))
        XCTAssertTrue(due(lastSyncAt: now - HSGeofenceRules.syncInterval))
        XCTAssertTrue(due(lastSyncAt: now + 1))
        XCTAssertFalse(due(lastSyncAt: now - 1, latitude: 41.04))
        XCTAssertTrue(due(lastSyncAt: now - 1, latitude: 41.05))
    }

    func testDistance() {
        XCTAssertEqual(HSGeofenceRules.distance(41, 29, 42, 29), 111_195, accuracy: 5)
        XCTAssertEqual(HSGeofenceRules.distance(41, 29, 41, 29), 0, accuracy: 0.001)
    }

    func testParseRegions() {
        let response: [String: Any] = ["data": [
            ["id": "gfn_1", "lat": 41.0, "lng": 29.0, "radius_m": 300],
            ["id": "", "lat": 41.0, "lng": 29.0, "radius_m": 300],
            ["id": "gfn_2", "lng": 29.0, "radius_m": 300],
            ["id": "gfn_3", "lat": 41.0, "lng": 29.0, "radius_m": 0],
        ]]
        XCTAssertEqual(HSGeofenceRules.parseRegions(response), [HSGeofenceRegion(id: "gfn_1", latitude: 41, longitude: 29, radius: 300)])
        XCTAssertEqual(HSGeofenceRules.parseRegions([:]), [])
        let many: [String: Any] = ["data": (0..<30).map { ["id": "gfn_\($0)", "lat": 41.0, "lng": 29.0, "radius_m": 100] as [String: Any] }]
        XCTAssertEqual(HSGeofenceRules.parseRegions(many).count, HSGeofenceRules.maxRegions)
    }

    func testIdentifierKeepsAppRegionsApart() {
        XCTAssertEqual(HSGeofenceRules.geofenceId(fromIdentifier: HSGeofenceRules.regionIdentifier("gfn_1")), "gfn_1")
        XCTAssertNil(HSGeofenceRules.geofenceId(fromIdentifier: "uygulamanin-bolgesi"))
        XCTAssertNil(HSGeofenceRules.geofenceId(fromIdentifier: HSGeofenceRules.identifierPrefix))
    }

    func testBodyHasNoCoordinates() throws {
        let op = HSGeofenceRules.operation(geofenceId: "gfn_1", transition: "enter", at: now)
        let body = try XCTUnwrap(HSGeofenceRules.body(for: op, registeredToken: nil))
        let event = try XCTUnwrap((body["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["geofence_id"] as? String, "gfn_1")
        XCTAssertEqual(event["transition"] as? String, "enter")
        XCTAssertEqual(event["occurred_at"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertNil(event["lat"])
        XCTAssertNil(event["lng"])
        XCTAssertNil(HSGeofenceRules.body(for: ["type": HSGeofenceRules.operationType], registeredToken: nil))
    }
}
