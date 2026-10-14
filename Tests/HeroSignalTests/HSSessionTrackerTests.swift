import XCTest
@testable import HeroSignalCore

final class HSSessionTrackerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "hs.tests.session.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func tracker() -> HSSessionTracker { HSSessionTracker(defaults: defaults, appId: "app_1") }

    func testFirstForegroundStartsSession() {
        let session = tracker()
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.enterForeground(at: t0), [.start])
        XCTAssertTrue(session.isActive)
        // Arka plana geçmeden yeniden etkinleşme (Denetim Merkezi vb.) yeni oturum açmaz.
        XCTAssertEqual(session.enterForeground(at: t0.addingTimeInterval(5)), [])
    }

    func testShortBackgroundContinuesSession() {
        let session = tracker()
        _ = session.enterForeground(at: t0)
        session.enterBackground(at: t0.addingTimeInterval(60))
        XCTAssertEqual(session.enterForeground(at: t0.addingTimeInterval(60 + 29)), [], "30 sn'den kısa arka plan oturumu sürdürür")
        session.enterBackground(at: t0.addingTimeInterval(89 + 40))
        // Süre yalnızca ön plan zamanıdır: 60 + 40 = 100 sn.
        XCTAssertEqual(session.enterForeground(at: t0.addingTimeInterval(129 + 30)), [.end(durationSeconds: 100), .start])
    }

    func testBackgroundTimeoutPersistsAcrossProcessRestart() {
        let first = tracker()
        _ = first.enterForeground(at: t0)
        first.enterBackground(at: t0.addingTimeInterval(45))
        // Süreç arka planda sonlandı; yeni süreçte durum UserDefaults'tan okunur.
        let restarted = tracker()
        XCTAssertTrue(restarted.isActive)
        XCTAssertEqual(restarted.enterForeground(at: t0.addingTimeInterval(45 + 600)), [.end(durationSeconds: 45), .start])
    }

    func testRestartWithinWindowContinuesSession() {
        let first = tracker()
        _ = first.enterForeground(at: t0)
        first.enterBackground(at: t0.addingTimeInterval(10))
        let restarted = tracker()
        XCTAssertEqual(restarted.enterForeground(at: t0.addingTimeInterval(20)), [])
    }

    func testExpireEndsSessionOnlyAfterWindow() {
        let session = tracker()
        _ = session.enterForeground(at: t0)
        session.enterBackground(at: t0.addingTimeInterval(20))
        XCTAssertNil(session.expire(at: t0.addingTimeInterval(20 + 29)))
        XCTAssertEqual(session.expire(at: t0.addingTimeInterval(20 + 30)), .end(durationSeconds: 20))
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.expire(at: t0.addingTimeInterval(200)), "oturum bir kez kapanır")
        XCTAssertEqual(session.enterForeground(at: t0.addingTimeInterval(300)), [.start])
    }

    func testForegroundSessionLeftByPreviousProcessIsClosed() {
        let first = tracker()
        _ = first.enterForeground(at: t0)
        // Önceki süreç ön plandayken sonlandı (arka plan kaydı yok).
        let restarted = tracker()
        XCTAssertEqual(restarted.enterForeground(at: t0.addingTimeInterval(1_000)), [.end(durationSeconds: 0), .start])
    }
}
