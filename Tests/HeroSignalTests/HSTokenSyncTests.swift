import UserNotifications
import XCTest
@testable import HeroSignalCore

/// Sahte istekçi: çağrıları kaydeder, yanıtı işleyiciden alır.
private final class FakeRequester {
    struct Call { let method: String; let path: String; let body: [String: Any]? }
    var calls: [Call] = []
    var handler: (Call) throws -> [String: Any]

    init(handler: @escaping (Call) throws -> [String: Any]) { self.handler = handler }

    func sync() -> HSTokenSync {
        HSTokenSync { method, path, body in
            let call = Call(method: method, path: path, body: body)
            self.calls.append(call)
            return try self.handler(call)
        }
    }
}

final class HSTokenSyncTests: XCTestCase {
    private let created: [String: Any] = ["subscription_id": "sub_1", "user_id": "usr_1", "external_id": NSNull()]

    func testCreatesSubscriptionWhenNoneRegistered() async throws {
        let fake = FakeRequester { _ in self.created }
        let result = try await fake.sync().sync(subscriptionId: nil, registeredToken: nil, token: "tok_a", device: ["push_environment": "sandbox"], user: [:])
        XCTAssertEqual(result, .created(subscriptionId: "sub_1", userId: "usr_1", externalId: nil))
        XCTAssertEqual(fake.calls.map(\.method), ["POST"])
        XCTAssertEqual(fake.calls[0].path, "/subscriptions")
        XCTAssertEqual(fake.calls[0].body?["channel"] as? String, "ios_push")
        XCTAssertEqual((fake.calls[0].body?["device"] as? [String: Any])?["push_environment"] as? String, "sandbox")
        XCTAssertEqual(fake.calls[0].body?["ownership_proof"] as? Bool, true)
    }

    func testTokenChangePatchesExistingSubscription() async throws {
        let fake = FakeRequester { _ in ["id": "sub_1"] }
        let result = try await fake.sync().sync(subscriptionId: "sub_1", registeredToken: "tok_a", token: "tok_b", device: [:], user: [:])
        XCTAssertEqual(result, .updated)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].method, "PATCH")
        XCTAssertEqual(fake.calls[0].path, "/subscriptions/sub_1")
        XCTAssertEqual(fake.calls[0].body?["token"] as? String, "tok_b")
        // Sahiplik kanıtı (ADR-0016): eski (kayıtlı) token'ın SHA-256 özeti.
        XCTAssertEqual(fake.calls[0].body?["token_hash"] as? String, HSOwnership.tokenHash("tok_a"))
    }

    func testOwnershipProofHashAndQuery() {
        // Bilinen vektör: SHA-256("abc").
        XCTAssertEqual(HSOwnership.tokenHash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(HSOwnership.query(registeredToken: nil), "")
        XCTAssertEqual(HSOwnership.query(registeredToken: "ayse@example.com"), "?token_hash=\(HSOwnership.tokenHash("ayse@example.com"))")
        let identity = String(repeating: "a", count: 64)
        XCTAssertEqual(
            HSOwnership.query(registeredToken: "+905321234567", identityHash: identity),
            "?token_hash=\(HSOwnership.tokenHash("+905321234567"))&identity_hash=\(identity)"
        )
        XCTAssertNil(HSOwnership.withProof(["opted_in": false], registeredToken: nil)["token_hash"])
    }

    func testLoginAndLogoutOwnershipProof() {
        // login: identity_hash hedef kullanıcınındır; abonelik kanıtı kayıtlı token'ın özetidir.
        let target = String(repeating: "b", count: 64)
        let login = HSOwnership.loginBody(externalId: "u-42", identityHash: target, registeredToken: "tok_a")
        XCTAssertEqual(login["external_id"] as? String, "u-42")
        XCTAssertEqual(login["identity_hash"] as? String, target)
        XCTAssertEqual(login["token_hash"] as? String, HSOwnership.tokenHash("tok_a"))
        XCTAssertEqual(Set(HSOwnership.loginBody(externalId: "u-42", identityHash: nil, registeredToken: nil).keys), ["external_id"])
        // logout/sessions: token özeti + giriş yapmış kullanıcının identity_hash'i.
        let identity = String(repeating: "c", count: 64)
        let logout = HSOwnership.withProof([:], registeredToken: "tok_a", identityHash: identity)
        XCTAssertEqual(logout["token_hash"] as? String, HSOwnership.tokenHash("tok_a"))
        XCTAssertEqual(logout["identity_hash"] as? String, identity)
    }

    func testInAppAndInboxOwnershipProof() {
        // In-app/inbox sorgusu: subscription_id + kayıtlı token'ın (e-posta/SMS'te kanonik adresin) özeti + identity_hash.
        let identity = String(repeating: "d", count: 64)
        XCTAssertEqual(
            HSOwnership.subscriptionQuery(subscriptionId: "sub_push", registeredToken: "apns_tok", identityHash: identity),
            "subscription_id=sub_push&token_hash=\(HSOwnership.tokenHash("apns_tok"))&identity_hash=\(identity)"
        )
        XCTAssertEqual(
            HSOwnership.subscriptionQuery(subscriptionId: "sub_mail", registeredToken: "ayse@example.com"),
            "subscription_id=sub_mail&token_hash=\(HSOwnership.tokenHash("ayse@example.com"))"
        )
        // Kanıt yoksa yalnızca abonelik kimliği; sorgu değeri güvenli kodlanır.
        XCTAssertEqual(HSOwnership.subscriptionQuery(subscriptionId: "a&b", registeredToken: nil), "subscription_id=a%26b")

        // In-app olayı ve inbox read/read-all gövdesi.
        let event = HSOwnership.subscriptionBody(["type": "impression"], subscriptionId: "sub_mail", registeredToken: "ayse@example.com")
        XCTAssertEqual(event["subscription_id"] as? String, "sub_mail")
        XCTAssertEqual(event["type"] as? String, "impression")
        XCTAssertEqual(event["token_hash"] as? String, HSOwnership.tokenHash("ayse@example.com"))
        XCTAssertNil(event["identity_hash"])
        let read = HSOwnership.subscriptionBody(subscriptionId: "sub_push", registeredToken: "apns_tok", identityHash: identity)
        XCTAssertEqual(Set(read.keys), ["subscription_id", "token_hash", "identity_hash"])
        XCTAssertEqual(Set(HSOwnership.subscriptionBody(subscriptionId: "sub_x", registeredToken: nil).keys), ["subscription_id"])
    }

    func testSameTokenSendsNothing() async throws {
        let fake = FakeRequester { _ in XCTFail("istek beklenmiyordu"); return [:] }
        let result = try await fake.sync().sync(subscriptionId: "sub_1", registeredToken: "tok_a", token: "tok_a", device: [:], user: [:])
        XCTAssertEqual(result, .unchanged)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testMissingSubscriptionIsRecreatedAfter404() async throws {
        let fake = FakeRequester { call in
            if call.method == "PATCH" { throw HSApiError(status: 404, code: "HS_NOT_FOUND", message: "yok") }
            return self.created
        }
        let result = try await fake.sync().sync(subscriptionId: "sub_old", registeredToken: "tok_a", token: "tok_b", device: [:], user: ["external_id": "u1"])
        XCTAssertEqual(result, .created(subscriptionId: "sub_1", userId: "usr_1", externalId: nil))
        XCTAssertEqual(fake.calls.map(\.method), ["PATCH", "POST"])
        XCTAssertEqual((fake.calls[1].body?["user"] as? [String: Any])?["external_id"] as? String, "u1")
    }

    func testTransientErrorIsThrown() async {
        let fake = FakeRequester { _ in throw HSApiError(status: 503, code: "HS_SERVICE_UNAVAILABLE", message: "x") }
        do {
            _ = try await fake.sync().sync(subscriptionId: "sub_1", registeredToken: "tok_a", token: "tok_b", device: [:], user: [:])
            XCTFail("hata bekleniyordu")
        } catch let error as HSApiError {
            XCTAssertEqual(error.status, 503)
        } catch {
            XCTFail("beklenmeyen hata \(error)")
        }
    }

    func testAliasValidation() {
        XCTAssertEqual(HSAliases.normalize(["crm_id": " 42 "]), ["crm_id": "42"])
        XCTAssertNil(HSAliases.normalize(["CRM": "1"]))
        XCTAssertNil(HSAliases.normalize(["external_id": "1"]))
        XCTAssertNil(HSAliases.normalize(["hs_id": "1"]))
        XCTAssertNil(HSAliases.normalize(["crm_id": "  "]))
        XCTAssertNil(HSAliases.normalize([:]))
        XCTAssertNil(HSAliases.normalize(Dictionary(uniqueKeysWithValues: (0...20).map { ("a\($0)", "v") })))
    }

    func testBadgeIncrementAndSetUseSharedCounter() {
        let defaults = UserDefaults(suiteName: "hs.tests.badge")!
        defaults.removePersistentDomain(forName: "hs.tests.badge")
        let store = HSBadgeStore(defaults: defaults)
        let inc = HSNotification(userInfo: ["aps": ["alert": ["title": "T"], "mutable-content": 1], "hs": ["dlv": "d1", "badge_inc": 2]])!
        XCTAssertEqual(inc.badgeIncrement, 2)
        XCTAssertEqual(store.apply(inc), 2)
        XCTAssertEqual(store.apply(inc), 4)
        let set = HSNotification(userInfo: ["aps": ["alert": "x", "badge": 1], "hs": ["dlv": "d2"]])!
        XCTAssertEqual(store.apply(set), 1)
        let none = HSNotification(userInfo: ["aps": ["alert": "x"], "hs": ["dlv": "d3"]])!
        XCTAssertNil(store.apply(none))
        store.count = 0
        XCTAssertEqual(store.apply(inc), 2)
    }

    func testCategoriesAreMergedNotOverwritten() {
        let appCategory = UNNotificationCategory(identifier: "app_chat", actions: [], intentIdentifiers: [])
        let old = HSCategories.category(identifier: "hs_ok", actions: [HSAction(id: "ok", title: "Eski", url: nil)])
        let new = HSCategories.category(identifier: "hs_ok", actions: [HSAction(id: "ok", title: "Yeni", url: nil)])
        let merged = HSCategories.merge([appCategory, old], adding: new)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.identifier == "app_chat" })
        XCTAssertEqual(merged.first { $0.identifier == "hs_ok" }?.actions.first?.title, "Yeni")
        XCTAssertTrue(new.options.contains(.customDismissAction))
        XCTAssertEqual(HSCategories.identifier(for: [HSAction(id: "a", title: "A", url: nil), HSAction(id: "b", title: "B", url: nil)]), "hs_a_b")
    }

    func testAppGroupResolutionPrefersExplicitValue() {
        XCTAssertEqual(HSAppGroup.resolve("group.explicit"), "group.explicit")
    }

    func testErrorReporterDedupesThrottlesAndSkipsNetworkErrors() {
        let reporter = HSErrorReporter(platform: "ios", sdkVersion: "0.1.0", maxPerSession: 3)
        XCTAssertTrue(reporter.record(code: "registration_failed", message: "kayıt başarısız", error: HSApiError(status: 500, code: "HS_INTERNAL", message: "x")))
        XCTAssertFalse(reporter.record(code: "registration_failed", message: "kayıt başarısız", error: HSApiError(status: 500, code: "HS_INTERNAL", message: "x")))
        XCTAssertFalse(reporter.record(code: "x", message: "ağ", error: HSApiError(status: 0, code: "NETWORK", message: "offline")))
        XCTAssertFalse(reporter.record(code: "x", message: "ağ", error: URLError(.notConnectedToInternet)))
        let token = String(repeating: "f", count: 64)
        XCTAssertTrue(reporter.record(code: "b", message: "token \(token)", context: ["op": "tags"]))
        XCTAssertTrue(reporter.record(code: "c", message: "üçüncü"))
        XCTAssertFalse(reporter.record(code: "d", message: "limit"))
        let batch = reporter.drain()?["errors"] as? [[String: Any]]
        XCTAssertEqual(batch?.count, 3)
        XCTAssertEqual(batch?[0]["message"] as? String, "kayıt başarısız: HTTP 500 HS_INTERNAL")
        XCTAssertEqual(batch?[0]["platform"] as? String, "ios")
        XCTAssertFalse((batch?[1]["message"] as? String ?? "").contains(token))
        XCTAssertNil(reporter.drain())
    }
}
