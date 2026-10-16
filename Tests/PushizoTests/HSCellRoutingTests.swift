import XCTest
@testable import PushizoCore

/// Hücre sunucularını taklit eder: `https://global.test` 421 `HS_WRONG_CELL` döner, diğer kökler 200.
/// `loop` açıkken her kök diğerini gösterir (döngü koruması testi).
private final class CellURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [String] = []
    static var target = "https://api.eu.test/"
    static var loop = false

    static var urls: [String] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    static func reset(target: String = "https://api.eu.test/", loop: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        captured = []
        self.target = target
        self.loop = loop
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!.absoluteString
        CellURLProtocol.lock.lock()
        CellURLProtocol.captured.append(url)
        let target = CellURLProtocol.target
        let loop = CellURLProtocol.loop
        CellURLProtocol.lock.unlock()
        let wrong = url.hasPrefix("https://global.test/") || (loop && url.hasPrefix("https://api.eu.test/"))
        let next = loop && url.hasPrefix("https://api.eu.test/") ? "https://global.test" : target
        let status = wrong ? 421 : 200
        let body = wrong
            ? #"{"error":{"code":"HS_WRONG_CELL","message":"x","details":{"cell_id":"eu","api_url":"\#(next)"}}}"#
            : #"{"ok":true}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Hücre yönlendirmesi (ADR-0032 §4): ortak vektörler (`sdk/testdata/cell-routing-vectors.json`; Web ve Android aynı
/// dosyayı kullanır) ve 421 `HS_WRONG_CELL` yeniden denemesi.
final class HSCellRoutingTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        // Tests/PushizoTests/<dosya> → sdk/testdata
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testdata/cell-routing-vectors.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func makeApi(_ root: String = "https://global.test") -> HSApi {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CellURLProtocol.self]
        return HSApi(apiUrl: root, appId: "app_1", sdkVersion: "test", session: URLSession(configuration: configuration))
    }

    func testAcceptVectors() throws {
        let cases = try XCTUnwrap(vectors()["accept"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let candidate: Any? = c["candidate"] is NSNull ? nil : c["candidate"]
            XCTAssertEqual(HSCellRouting.acceptApiUrl(candidate, current: c["current"] as! String), c["expected"] as? String, c["name"] as! String)
        }
    }

    func testWrongCellVectors() throws {
        let cases = try XCTUnwrap(vectors()["wrong_cell"] as? [[String: Any]])
        for c in cases {
            let actual = HSCellRouting.wrongCellTarget(status: c["status"] as! Int, envelope: c["body"], current: c["current"] as! String)
            XCTAssertEqual(actual, c["expected"] as? String, c["name"] as! String)
        }
    }

    func testInitialBaseUsesSavedRegionalRootForSameSeed() {
        let seed = "https://api.pushizo.com"
        XCTAssertEqual(HSCellRouting.initialBase(seed: seed + "/", savedSeed: seed, savedUrl: "https://api.eu.test"), "https://api.eu.test")
        XCTAssertEqual(HSCellRouting.initialBase(seed: "https://other.test", savedSeed: seed, savedUrl: "https://api.eu.test"), "https://other.test")
        XCTAssertEqual(HSCellRouting.initialBase(seed: seed, savedSeed: seed, savedUrl: "http://evil.test"), seed)
        XCTAssertEqual(HSCellRouting.initialBase(seed: seed, savedSeed: nil, savedUrl: nil), seed)
    }

    func testWrongCellSwitchesRootRetriesOnceAndNotifies() async throws {
        CellURLProtocol.reset()
        let api = makeApi()
        var changes: [String] = []
        api.onApiUrlChange = { changes.append($0) }
        let result = try await api.request("POST", "/events", body: ["events": []])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(CellURLProtocol.urls, [
            "https://global.test/sdk/v1/apps/app_1/events",
            "https://api.eu.test/sdk/v1/apps/app_1/events",
        ])
        XCTAssertEqual(changes, ["https://api.eu.test"])
        XCTAssertEqual(api.apiUrl, "https://api.eu.test")
        // Sonraki istekler (kuyruktaki işlemler dahil) doğrudan bölgesel köke gider.
        try await api.request("GET", "/config")
        XCTAssertEqual(CellURLProtocol.urls.last, "https://api.eu.test/sdk/v1/apps/app_1/config")
    }

    func testCellsPointingAtEachOtherFollowOnlyOneReroute() async {
        CellURLProtocol.reset(loop: true)
        let api = makeApi()
        do {
            try await api.request("GET", "/config")
            XCTFail("421 beklenirdi")
        } catch let error as HSApiError {
            XCTAssertEqual(error.status, 421)
            XCTAssertEqual(error.code, "HS_WRONG_CELL")
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
        XCTAssertEqual(CellURLProtocol.urls.count, 2)
    }

    func testInsecureTargetIsIgnored() async {
        CellURLProtocol.reset(target: "http://evil.test")
        let api = makeApi()
        do {
            try await api.request("GET", "/config")
            XCTFail("421 beklenirdi")
        } catch {
            XCTAssertEqual((error as? HSApiError)?.status, 421)
        }
        XCTAssertEqual(CellURLProtocol.urls.count, 1)
        XCTAssertEqual(api.apiUrl, "https://global.test")
    }

    func testStorageKeepsRegionalRootPerSeed() {
        let suite = "hs.tests.cell.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let storage = HSStorage(appId: "app_1", appGroup: suite)
        XCTAssertEqual(storage.resolvedApiUrl(seed: "https://api.pushizo.com"), "https://api.pushizo.com")
        storage.saveRegionalApi(seed: "https://api.pushizo.com/", url: "https://api.eu.test")
        XCTAssertEqual(storage.resolvedApiUrl(seed: "https://api.pushizo.com"), "https://api.eu.test")
        XCTAssertEqual(storage.resolvedApiUrl(seed: "https://proxy.example.com"), "https://proxy.example.com")
    }
}
