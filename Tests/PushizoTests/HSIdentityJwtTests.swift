import XCTest
@testable import PushizoCore

/// İstekleri ağa çıkarmadan yakalar; son isteği saklar ve boş JSON yanıtı döner.
private final class CapturingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        captured = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CapturingURLProtocol.lock.lock()
        CapturingURLProtocol.captured.append(request)
        CapturingURLProtocol.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// JWT identity verification (ADR-0023 §9): mod kuralları, `Authorization` başlığı ve kalıcı depolama.
final class HSIdentityJwtTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "hs.tests.jwt.\(UUID().uuidString)"
        CapturingURLProtocol.reset()
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeApi() -> HSApi {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        return HSApi(apiUrl: "https://api.example.test/", appId: "app_1", sdkVersion: "test", session: URLSession(configuration: configuration))
    }

    func testModeParsingDefaultsToHmac() {
        XCTAssertEqual(HSIdentityVerificationMode(config: "jwt"), .jwt)
        XCTAssertEqual(HSIdentityVerificationMode(config: "both"), .both)
        XCTAssertEqual(HSIdentityVerificationMode(config: "hmac"), .hmac)
        XCTAssertEqual(HSIdentityVerificationMode(config: nil), .hmac, "eski sunucu alanı döndürmez")
        XCTAssertEqual(HSIdentityVerificationMode(config: "bilinmeyen"), .hmac)
    }

    func testLoginRulesFollowAppMode() {
        // Zorunlu değilse kanıt aranmaz.
        XCTAssertNil(HSIdentityVerification.loginError(required: false, mode: .jwt, identityHash: nil, jwt: nil))
        // jwt modu: HMAC yetmez.
        XCTAssertNotNil(HSIdentityVerification.loginError(required: true, mode: .jwt, identityHash: "h", jwt: nil))
        XCTAssertNil(HSIdentityVerification.loginError(required: true, mode: .jwt, identityHash: nil, jwt: "a.b.c"))
        // hmac modu: identityHash zorunlu.
        XCTAssertNotNil(HSIdentityVerification.loginError(required: true, mode: .hmac, identityHash: nil, jwt: "a.b.c"))
        XCTAssertNil(HSIdentityVerification.loginError(required: true, mode: .hmac, identityHash: "h", jwt: nil))
        // both modu: ikisinden biri yeter; boş dize kanıt sayılmaz.
        XCTAssertNotNil(HSIdentityVerification.loginError(required: true, mode: .both, identityHash: "", jwt: ""))
        XCTAssertNil(HSIdentityVerification.loginError(required: true, mode: .both, identityHash: "h", jwt: nil))
        XCTAssertNil(HSIdentityVerification.loginError(required: true, mode: .both, identityHash: nil, jwt: "a.b.c"))
    }

    func testBearerHeaderIsSentOnlyWhenTokenExists() async throws {
        let api = makeApi()
        var token: String?
        api.identityToken = { token }

        try await api.request("GET", "/config")
        XCTAssertNil(CapturingURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"))

        token = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1In0.sig"
        try await api.request("POST", "/subscriptions/sub_1/login", body: ["external_id": "u"])
        let request = try XCTUnwrap(CapturingURLProtocol.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1In0.sig")
        // Belirteç URL'ye yazılmaz.
        XCTAssertFalse(request.url!.absoluteString.contains("eyJ"))

        // Yenilenen belirteç sonraki istekte kullanılır.
        token = "new.jwt.value"
        try await api.request("GET", "/config")
        XCTAssertEqual(CapturingURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new.jwt.value")
    }

    func testJwtIsPersistedAndClearedWithIdentity() {
        let store = HSStorage(appId: "app_1", appGroup: suiteName)
        store.externalId = "user_42"
        store.identityJwt = "a.b.c"
        // Aynı depo (ör. App Group'u paylaşan NSE) belirteci okur.
        XCTAssertEqual(HSStorage(appId: "app_1", appGroup: suiteName).identityJwt, "a.b.c")
        store.clearIdentity()
        XCTAssertNil(store.identityJwt, "logout/onay geri çekme belirteci siler")
        XCTAssertNil(store.externalId)
    }
}
