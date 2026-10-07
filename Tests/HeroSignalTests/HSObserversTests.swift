import UserNotifications
import XCTest
@testable import HeroSignalCore

final class HSObserversTests: XCTestCase {
    func testRegistryNotifiesInOrderAndRemovesByToken() {
        let registry = HSListenerRegistry<Int>()
        var calls: [String] = []
        let first = registry.add { calls.append("a\($0)") }
        registry.add { calls.append("b\($0)") }
        registry.notify(1)
        XCTAssertTrue(registry.remove(first))
        XCTAssertFalse(registry.remove(first), "aynı belirteç ikinci kez kaldırılamaz")
        registry.notify(2)
        XCTAssertEqual(calls, ["a1", "b1", "b2"])
        XCTAssertEqual(registry.count, 1)
    }

    func testRegistryAllowsRemovalFromInsideListener() {
        let registry = HSListenerRegistry<Int>()
        var token: HSListenerToken?
        var count = 0
        token = registry.add { _ in
            count += 1
            if let token { registry.remove(token) }
        }
        registry.notify(1)
        registry.notify(2)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(registry.isEmpty)
    }

    func testPermissionTrackerIgnoresBaselineAndReportsOnlyChanges() {
        let tracker = HSPermissionTracker()
        var calls: [Bool] = []
        tracker.observers.add { calls.append($0) }
        XCTAssertNil(tracker.lastKnown)
        XCTAssertFalse(tracker.update(false), "ilk ölçüm temel değerdir")
        XCTAssertFalse(tracker.update(false))
        XCTAssertTrue(tracker.update(true))
        XCTAssertFalse(tracker.update(true))
        XCTAssertTrue(tracker.update(false))
        XCTAssertEqual(calls, [true, false])
        XCTAssertEqual(tracker.lastKnown, false)
    }

    func testPermissionObserverRemoval() {
        let tracker = HSPermissionTracker()
        var calls = 0
        let token = tracker.observers.add { _ in calls += 1 }
        tracker.update(false)
        tracker.update(true)
        tracker.observers.remove(token)
        tracker.update(false)
        XCTAssertEqual(calls, 1)
    }

    func testGrantedStatuses() {
        XCTAssertTrue(HSPermissionTracker.isGranted(.authorized))
        XCTAssertTrue(HSPermissionTracker.isGranted(.provisional))
        XCTAssertFalse(HSPermissionTracker.isGranted(.denied))
        XCTAssertFalse(HSPermissionTracker.isGranted(.notDetermined))
    }
}
