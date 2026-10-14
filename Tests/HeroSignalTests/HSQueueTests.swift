import XCTest
@testable import HeroSignalCore

final class HSQueueTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "hs.tests.queue.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDeferredOperationStaysQueuedWithoutBlockingOthers() async {
        let queue = HSQueue(defaults: defaults, appId: "app_1")
        queue.enqueue(["type": "event", "name": "a", "at": 1])
        queue.enqueue(["type": "contact_add", "address": "ali@example.com", "at": 2])
        queue.enqueue(["type": "session_start", "at": 3])
        var handled: [String] = []
        let complete = await queue.flush { op in
            let type = op["type"] as? String ?? ""
            // Abonelik yok: olay ve oturum ertelenir, e-posta kaydı gönderilir.
            if type == "event" || type == "session_start" { throw HSQueueDeferred("abonelik yok") }
            handled.append(type)
        }
        XCTAssertFalse(complete, "ertelenen işlem varken kuyruk tamamlanmış sayılmaz")
        XCTAssertEqual(handled, ["contact_add"])
        XCTAssertEqual(queue.items.compactMap { $0["type"] as? String }, ["event", "session_start"])

        // Abonelik oluştu: ertelenen işlemler sırasıyla gönderilir.
        let completeLater = await queue.flush { op in handled.append(op["type"] as? String ?? "") }
        XCTAssertTrue(completeLater)
        XCTAssertEqual(handled, ["contact_add", "event", "session_start"])
        XCTAssertEqual(queue.count, 0)
    }

    func testDeferredEventBatchKeepsAllEvents() async {
        let queue = HSQueue(defaults: defaults, appId: "app_1")
        queue.enqueue(["type": "event", "name": "a", "at": 1])
        queue.enqueue(["type": "event", "name": "b", "at": 2])
        queue.enqueue(["type": "opened", "delivery_id": "d1", "at": 3])
        var handled: [String] = []
        _ = await queue.flush { op in
            if op["type"] as? String == "event_batch" { throw HSQueueDeferred("abonelik yok") }
            handled.append(op["type"] as? String ?? "")
        }
        XCTAssertEqual(handled, ["opened"])
        XCTAssertEqual(queue.items.compactMap { $0["name"] as? String }, ["a", "b"])
    }

    func testRetryableErrorStopsAndKeepsQueue() async {
        let queue = HSQueue(defaults: defaults, appId: "app_1")
        queue.enqueue(["type": "opened", "delivery_id": "d1", "at": 1])
        queue.enqueue(["type": "dismissed", "delivery_id": "d2", "at": 2])
        var calls = 0
        let complete = await queue.flush { _ in
            calls += 1
            // Onay geri çekildi veya ağ yok: kuyruk durur, işlemler kalır.
            throw HSApiError(status: 0, code: "CONSENT_REQUIRED", message: "onay bekleniyor")
        }
        XCTAssertFalse(complete)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(queue.count, 2)
    }

    func testPermanentErrorDropsOperationAndReportsIt() async {
        let queue = HSQueue(defaults: defaults, appId: "app_1")
        queue.enqueue(["type": "opened", "delivery_id": "d1", "at": 1])
        queue.enqueue(["type": "dismissed", "delivery_id": "d2", "at": 2])
        var rejected: [String] = []
        let complete = await queue.flush({ op in
            if op["type"] as? String == "opened" { throw HSApiError(status: 404, code: "NOT_FOUND", message: "yok") }
        }, onRejected: { op, _ in rejected.append(op["type"] as? String ?? "") })
        XCTAssertTrue(complete)
        XCTAssertEqual(rejected, ["opened"])
        XCTAssertEqual(queue.count, 0)
    }
}
