import XCTest
@testable import PushizoCore

/// İstekleri ağa çıkarmadan yakalar (gövde `httpBodyStream` ile de okunur) ve boş JSON yanıtı döner.
private final class LiveActivityURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [(request: URLRequest, body: Data?)] = []

    static var requests: [(request: URLRequest, body: Data?)] {
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
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        LiveActivityURLProtocol.lock.lock()
        LiveActivityURLProtocol.captured.append((request, body))
        LiveActivityURLProtocol.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Live Activities (ADR-0024): belirteç dönüşümü, kuyruk işlemleri, istek gövdesi ve genel türün kodlanması.
final class HSLiveActivitiesTests: XCTestCase {
    private let pushToken = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
    private let laToken = "00ff10aa20bb30cc40dd50ee60ff7000112233445566778899aabbccddeeff00"

    override func setUp() {
        super.setUp()
        LiveActivityURLProtocol.reset()
    }

    func testHexTokenIsLowercaseAndZeroPadded() {
        XCTAssertEqual(HSLiveActivities.hexToken(Data([0x00, 0x0f, 0xab, 0xff])), "000fabff")
        XCTAssertEqual(HSLiveActivities.hexToken(Data()), "")
        XCTAssertTrue(HSLiveActivities.isValidToken(HSLiveActivities.hexToken(Data(repeating: 0xAB, count: 32))))
        XCTAssertFalse(HSLiveActivities.isValidToken("abc"), "sunucu en az 32 karakter ister")
        XCTAssertFalse(HSLiveActivities.isValidToken(String(repeating: "zz", count: 20)))
    }

    func testActivityTypeAndIdRulesMatchServer() {
        XCTAssertTrue(HSLiveActivities.isValidActivityType("DeliveryAttributes"))
        XCTAssertTrue(HSLiveActivities.isValidActivityType(PushizoDefaultLiveActivityAttributes.activityType))
        XCTAssertFalse(HSLiveActivities.isValidActivityType("Generic<Int>"))
        XCTAssertFalse(HSLiveActivities.isValidActivityType("1Attributes"))
        XCTAssertTrue(HSLiveActivities.isValidActivityId("order_42:v1.2-x"))
        XCTAssertTrue(HSLiveActivities.isValidActivityId(UUID().uuidString), "Activity.id yedeği de geçerli")
        XCTAssertFalse(HSLiveActivities.isValidActivityId(""))
        XCTAssertFalse(HSLiveActivities.isValidActivityId("bosluk var"))
        XCTAssertFalse(HSLiveActivities.isValidActivityId(String(repeating: "a", count: 101)))
    }

    func testDefaultTypeNameEqualsSwiftTypeName() {
        XCTAssertEqual(String(describing: PushizoDefaultLiveActivityAttributes.self), PushizoDefaultLiveActivityAttributes.activityType)
    }

    func testActivityDataUsesSnakeCaseKey() throws {
        let data = try JSONEncoder().encode(PushizoActivityData(activityId: "lac_1"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json as? [String: String], ["activity_id": "lac_1"])
        let decoded = try JSONDecoder().decode(PushizoActivityData.self, from: Data(#"{"activity_id":"lac_2"}"#.utf8))
        XCTAssertEqual(decoded.activityId, "lac_2")
    }

    func testDefaultAttributesDecodeServerStartPayload() throws {
        // packages/render: start payload'ındaki `attributes` düz nesnedir ve `pushizo.activity_id` içerir.
        let json = #"{"title":"Sipariş #42","items":3,"express":true,"price":12.5,"nested":{"x":1},"empty":null,"pushizo":{"activity_id":"lac_9"}}"#
        let attributes = try JSONDecoder().decode(PushizoDefaultLiveActivityAttributes.self, from: Data(json.utf8))
        XCTAssertEqual(attributes.pushizo, PushizoActivityData(activityId: "lac_9"))
        XCTAssertEqual(attributes.data["title"], .string("Sipariş #42"))
        XCTAssertEqual(attributes.data["items"]?.intValue, 3)
        XCTAssertEqual(attributes.data["express"], .bool(true))
        XCTAssertEqual(attributes.data["price"]?.doubleValue, 12.5)
        XCTAssertNil(attributes.data["pushizo"], "pushizo veri alanı değildir")
        XCTAssertNil(attributes.data["nested"], "ilkel olmayan değer atlanır")
        XCTAssertNil(attributes.data["empty"])
        XCTAssertEqual(attributes.data["items"]?.description, "3")

        // Bozuk pushizo alanı etkinliği düşürmez.
        let broken = try JSONDecoder().decode(PushizoDefaultLiveActivityAttributes.self, from: Data(#"{"title":"x","pushizo":"y"}"#.utf8))
        XCTAssertNil(broken.pushizo)
        XCTAssertEqual(broken.data["title"], .string("x"))
    }

    func testDefaultAttributesRoundTrip() throws {
        let original = PushizoDefaultLiveActivityAttributes(data: ["title": .string("Maç"), "home": .number(2)], pushizo: PushizoActivityData(activityId: "match_1"))
        let encoded = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Maç")
        XCTAssertEqual((json["pushizo"] as? [String: Any])?["activity_id"] as? String, "match_1")
        let decoded = try JSONDecoder().decode(PushizoDefaultLiveActivityAttributes.self, from: encoded)
        XCTAssertEqual(decoded.data, original.data)
        XCTAssertEqual(decoded.pushizo, original.pushizo)

        let state = PushizoDefaultLiveActivityAttributes.ContentState(data: ["status": .string("Yolda"), "eta": .number(12), "late": .bool(false)])
        let stateJson = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertEqual(stateJson["status"] as? String, "Yolda")
        XCTAssertEqual(stateJson["late"] as? Bool, false)
        let decodedState = try JSONDecoder().decode(PushizoDefaultLiveActivityAttributes.ContentState.self, from: Data(#"{"status":"Yolda","eta":12,"late":false}"#.utf8))
        XCTAssertEqual(decodedState, state)
    }

    func testBridgeValuesAreValidated() {
        let values = PushizoLiveActivityValue.dictionary(from: ["s": "x", "i": 3, "d": 2.5, "b": true, "n": NSNumber(value: 0)] as [String: Any])
        XCTAssertEqual(values?["s"], .string("x"))
        XCTAssertEqual(values?["i"], .number(3))
        XCTAssertEqual(values?["d"], .number(2.5))
        XCTAssertEqual(values?["b"], .bool(true), "Bool sayıya dönüşmez")
        XCTAssertEqual(values?["n"], .number(0), "0 sayısı Bool'a dönüşmez")
        XCTAssertEqual(PushizoLiveActivityValue.dictionary(from: nil), [:])
        XCTAssertNil(PushizoLiveActivityValue.dictionary(from: ["o": ["x": 1]] as [String: Any]), "iç içe nesne reddedilir")
        XCTAssertNil(PushizoLiveActivityValue.dictionary(from: ["a": [1, 2]] as [String: Any]))
        XCTAssertNil(PushizoLiveActivityValue.dictionary(from: ["x": NSNull()] as [String: Any]))
        XCTAssertNil(PushizoLiveActivityValue.dictionary(from: ["x": Double.nan] as [String: Any]))
        XCTAssertNil(PushizoLiveActivityValue.dictionary(from: ["": "x"] as [String: Any]), "boş anahtar")
        XCTAssertNil(PushizoLiveActivityValue.dictionary(from: [String(repeating: "k", count: 65): "x"] as [String: Any]))
        XCTAssertNil(PushizoLiveActivityValue.dictionary(from: ["t": String(repeating: "x", count: 4001)] as [String: Any]))
        XCTAssertNil(PushizoLiveActivityValue.dictionary(from: "metin"))
    }

    func testOperationsAndRequestBodiesCarryOwnershipProof() throws {
        let start = HSLiveActivities.tokenOperation(activityType: "DeliveryAttributes", kind: .pushToStart, activityId: "yok_sayilir", token: laToken.uppercased(), at: 1)
        XCTAssertNil(start["activity_id"], "push_to_start belirtecinde activity_id gönderilmez")
        let startRequest = try XCTUnwrap(HSLiveActivities.request(for: start, subscriptionId: "sub_1", registeredToken: pushToken, identityHash: nil))
        XCTAssertEqual(startRequest.path, "/live-activities/tokens")
        XCTAssertEqual(startRequest.body["subscription_id"] as? String, "sub_1")
        XCTAssertEqual(startRequest.body["activity_type"] as? String, "DeliveryAttributes")
        XCTAssertEqual(startRequest.body["kind"] as? String, "push_to_start")
        XCTAssertEqual(startRequest.body["token"] as? String, laToken, "belirteç küçük harfe çevrilir")
        XCTAssertEqual(startRequest.body["token_hash"] as? String, HSOwnership.tokenHash(pushToken), "kanıt: cihaz push token'ının özeti")
        XCTAssertNil(startRequest.body["identity_hash"])
        XCTAssertNil(startRequest.body["activity_id"])

        let update = HSLiveActivities.tokenOperation(activityType: "DeliveryAttributes", kind: .update, activityId: "lac_1", token: laToken)
        let updateRequest = try XCTUnwrap(HSLiveActivities.request(for: update, subscriptionId: "sub_1", registeredToken: nil, identityHash: String(repeating: "f", count: 64)))
        XCTAssertEqual(updateRequest.body["activity_id"] as? String, "lac_1")
        XCTAssertEqual(updateRequest.body["identity_hash"] as? String, String(repeating: "f", count: 64))
        XCTAssertNil(updateRequest.body["token_hash"])

        let delete = HSLiveActivities.deleteOperation(activityType: "DeliveryAttributes", kind: .update, activityId: "lac_1")
        let deleteRequest = try XCTUnwrap(HSLiveActivities.request(for: delete, subscriptionId: "sub_1", registeredToken: pushToken, identityHash: nil))
        XCTAssertEqual(deleteRequest.path, "/live-activities/tokens/delete")
        XCTAssertNil(deleteRequest.body["token"], "silme isteği belirteç taşımaz")
        XCTAssertEqual(deleteRequest.body["activity_id"] as? String, "lac_1")
        XCTAssertEqual(deleteRequest.body["token_hash"] as? String, HSOwnership.tokenHash(pushToken))
    }

    func testInvalidOperationsProduceNoRequest() {
        var update = HSLiveActivities.tokenOperation(activityType: "DeliveryAttributes", kind: .update, activityId: nil, token: laToken)
        XCTAssertNil(HSLiveActivities.request(for: update, subscriptionId: "sub_1", registeredToken: pushToken, identityHash: nil), "update'te activity_id zorunlu")
        update["activity_id"] = "lac_1"
        update["token"] = "kisa"
        XCTAssertNil(HSLiveActivities.request(for: update, subscriptionId: "sub_1", registeredToken: pushToken, identityHash: nil))
        let badType = HSLiveActivities.tokenOperation(activityType: "Bad<Type>", kind: .pushToStart, activityId: nil, token: laToken)
        XCTAssertNil(HSLiveActivities.request(for: badType, subscriptionId: "sub_1", registeredToken: pushToken, identityHash: nil))
        XCTAssertNil(HSLiveActivities.request(for: ["type": "event"], subscriptionId: "sub_1", registeredToken: pushToken, identityHash: nil))
    }

    func testOperationsSurviveQueuePersistence() async throws {
        let suite = "hs.tests.la.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = HSQueue(defaults: defaults, appId: "app_1")
        queue.enqueue(HSLiveActivities.tokenOperation(activityType: "DeliveryAttributes", kind: .update, activityId: "lac_1", token: laToken))
        queue.enqueue(HSLiveActivities.deleteOperation(activityType: "DeliveryAttributes", kind: .update, activityId: "lac_1"))

        // Abonelik yokken işlemler sırasıyla kuyrukta bekler.
        var subscriptionId: String?
        var sent: [String] = []
        let handler: ([String: Any]) async throws -> Void = { op in
            guard let subId = subscriptionId else { throw HSQueueDeferred("push aboneliği yok") }
            let request = try XCTUnwrap(HSLiveActivities.request(for: op, subscriptionId: subId, registeredToken: self.pushToken, identityHash: nil))
            sent.append(request.path)
        }
        let first = await HSQueue(defaults: defaults, appId: "app_1").flush(handler)
        XCTAssertFalse(first)
        XCTAssertEqual(queue.count, 2)
        XCTAssertTrue(sent.isEmpty)

        subscriptionId = "sub_1"
        let second = await HSQueue(defaults: defaults, appId: "app_1").flush(handler)
        XCTAssertTrue(second)
        XCTAssertEqual(sent, ["/live-activities/tokens", "/live-activities/tokens/delete"])
        XCTAssertEqual(queue.count, 0)
    }

    func testRequestIsSentToSdkEndpointWithBearerJwt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let api = HSApi(apiUrl: "https://api.example.test", appId: "app_1", sdkVersion: "test", session: URLSession(configuration: configuration))
        api.identityToken = { "a.b.c" }

        let op = HSLiveActivities.tokenOperation(activityType: PushizoDefaultLiveActivityAttributes.activityType, kind: .update, activityId: "order_42", token: laToken)
        let request = try XCTUnwrap(HSLiveActivities.request(for: op, subscriptionId: "sub_1", registeredToken: pushToken, identityHash: nil))
        let response = try await api.request("POST", request.path, body: request.body)
        XCTAssertEqual(response["ok"] as? Bool, true)

        let captured = try XCTUnwrap(LiveActivityURLProtocol.requests.last)
        XCTAssertEqual(captured.request.httpMethod, "POST")
        XCTAssertEqual(captured.request.url?.absoluteString, "https://api.example.test/sdk/v1/apps/app_1/live-activities/tokens")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Authorization"), "Bearer a.b.c")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(captured.body)) as? [String: Any])
        XCTAssertEqual(body["subscription_id"] as? String, "sub_1")
        XCTAssertEqual(body["activity_type"] as? String, "PushizoDefaultLiveActivityAttributes")
        XCTAssertEqual(body["kind"] as? String, "update")
        XCTAssertEqual(body["activity_id"] as? String, "order_42")
        XCTAssertEqual(body["token"] as? String, laToken)
        XCTAssertEqual(body["token_hash"] as? String, HSOwnership.tokenHash(pushToken))
    }

    func testErrorCodesMatchBridgeContract() {
        XCTAssertEqual(HSLiveActivityError.notSupported("x").code, "PLATFORM_NOT_SUPPORTED")
        XCTAssertEqual(HSLiveActivityError.notInitialized.code, "NOT_READY")
        XCTAssertEqual(HSLiveActivityError.invalidArgument("x").code, "INVALID_ARGUMENT")
        XCTAssertEqual(HSLiveActivityError.requestFailed("x").code, "LIVE_ACTIVITY_FAILED")
        XCTAssertEqual(HSLiveActivityError.invalidArgument("mesaj").message, "mesaj")
    }
}
