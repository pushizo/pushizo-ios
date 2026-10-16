import XCTest
@testable import PushizoCore

/// HTML in-app köprüsü ortak vektörleri (`sdk/testdata/html-bridge-vectors.json`; Web ve Android aynı dosyayı kullanır)
/// ile HTML/carousel ayrıştırma testleri.
final class HSHtmlInAppTests: XCTestCase {
    private static let vectors: [String: Any] = {
        // Tests/PushizoTests/<dosya> → sdk/testdata
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testdata/html-bridge-vectors.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func bridgeValue(_ value: Any) -> HSBridgeValue {
        if value is NSNull { return .null }
        if let s = value as? String { return .string(s) }
        let n = value as! NSNumber
        return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
    }

    /// Vektör dosyasındaki `expected` nesnesi (Web SDK `HtmlBridgeAction`) → Swift eylemi.
    private func expectedAction(_ e: [String: Any]) -> HSHtmlBridgeAction {
        switch e["type"] as! String {
        case "ready": return .ready
        case "close": return .close
        case "click": return .click(actionId: e["actionId"] as! String, url: e["url"] as? String)
        case "add_tag": return .addTag(key: e["key"] as! String, value: e["value"] as! String)
        case "track_event": return .trackEvent(name: e["name"] as! String, props: (e["props"] as! [String: Any]).mapValues(bridgeValue))
        default: return .resize(height: (e["height"] as! NSNumber).intValue)
        }
    }

    func testBridgeMessageVectors() throws {
        let nonce = Self.vectors["nonce"] as! String
        let cases = Self.vectors["messages"] as! [[String: Any]]
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for c in cases {
            let name = c["name"] as! String
            // Yerel kanal mesajı JSON metni olarak alır (`postMessage(JSON.stringify(m))`).
            let body = String(data: try JSONSerialization.data(withJSONObject: c["data"]!), encoding: .utf8)!
            let actual = HSHtmlBridge.parse(json: body, nonce: nonce)
            if let expected = c["expected"] as? [String: Any] {
                XCTAssertEqual(actual, expectedAction(expected), name)
            } else {
                XCTAssertNil(actual, name)
            }
        }
    }

    func testUrlVectors() {
        for c in Self.vectors["urls"] as! [[String: Any]] {
            XCTAssertEqual(HSHtmlBridge.safeUrl(c["value"]), c["expected"] as? String, c["value"] as! String)
        }
        XCTAssertNil(HSHtmlBridge.safeUrl(42))
        XCTAssertTrue(HSHtmlBridge.isWebUrl("HTTPS://shop.example.com"))
        XCTAssertFalse(HSHtmlBridge.isWebUrl("myapp://cart"))
    }

    func testMalformedAndOversizedMessagesAreRejected() {
        let nonce = "nonce-12345"
        XCTAssertNil(HSHtmlBridge.parse(json: "bozuk", nonce: nonce))
        XCTAssertNil(HSHtmlBridge.parse(json: "[1,2]", nonce: nonce))
        let pad = String(repeating: "x", count: HSHtmlBridge.maxMessageLength)
        XCTAssertNil(HSHtmlBridge.parse(json: #"{"hs":"pushizo-bridge","v":1,"nonce":"nonce-12345","type":"close","pad":"\#(pad)"}"#, nonce: nonce))
        // Sürüm metin veya mantıksal değer olarak gelirse reddedilir; dizi özellik reddedilir.
        XCTAssertNil(HSHtmlBridge.parse(json: #"{"hs":"pushizo-bridge","v":"1","nonce":"nonce-12345","type":"close"}"#, nonce: nonce))
        XCTAssertNil(HSHtmlBridge.parse(json: #"{"hs":"pushizo-bridge","v":true,"nonce":"nonce-12345","type":"close"}"#, nonce: nonce))
        XCTAssertNil(HSHtmlBridge.parse(json: #"{"hs":"pushizo-bridge","v":1,"nonce":"nonce-12345","type":"track_event","name":"x","props":[1]}"#, nonce: nonce))
        // Satır sonu eklenmiş eylem kimliği reddedilir (JavaScript `$` gibi tam eşleşme).
        XCTAssertNil(HSHtmlBridge.parse(json: #"{"hs":"pushizo-bridge","v":1,"nonce":"nonce-12345","type":"click","action_id":"buy\n"}"#, nonce: nonce))
        // Uzun metin özellik 255 UTF-16 birimine kırpılır.
        let long = String(repeating: "a", count: 300)
        let event = HSHtmlBridge.parse(json: #"{"hs":"pushizo-bridge","v":1,"nonce":"nonce-12345","type":"track_event","name":"x","props":{"s":"\#(long)"}}"#, nonce: nonce)
        XCTAssertEqual(event, .trackEvent(name: "x", props: ["s": .string(String(repeating: "a", count: 255))]))
    }

    func testDocumentStartsWithCspAndUsesNativeBridge() throws {
        let nonce = HSHtmlBridge.newNonce()
        let doc = try XCTUnwrap(HSHtmlBridge.document(html: "<p>Merhaba</p><script>evil()</script>", nonce: nonce, language: "tr-TR"))
        XCTAssertTrue(doc.hasPrefix("<!doctype html><html lang=\"tr-TR\"><head><meta charset=\"utf-8\">"))
        let csp = try XCTUnwrap(doc.range(of: "<meta http-equiv=\"Content-Security-Policy\" content=\"\(HSHtmlBridge.csp)\">"))
        let content = try XCTUnwrap(doc.range(of: "<p>Merhaba</p>"))
        let script = try XCTUnwrap(doc.range(of: "<script>(function()"))
        XCTAssertLessThan(csp.lowerBound, content.lowerBound)
        XCTAssertLessThan(script.lowerBound, content.lowerBound)
        XCTAssertTrue(doc.contains("var N=\"\(nonce)\""))
        XCTAssertTrue(doc.contains("W.messageHandlers.pushizoBridge"))
        XCTAssertTrue(doc.contains("P.postMessage(JSON.stringify(m))"))
        XCTAssertFalse(doc.contains("window.parent"))
        XCTAssertTrue(doc.hasSuffix("</body></html>"))
        // Dil özniteliği temizlenir; içerik üst sınırda kesilir; kısa nonce reddedilir.
        XCTAssertTrue(HSHtmlBridge.document(html: "x", nonce: nonce, language: "\"><script>")!.hasPrefix("<!doctype html><html lang=\"script\">"))
        let big = HSHtmlBridge.document(html: String(repeating: "a", count: HSHtmlBridge.maxHtmlLength + 10), nonce: nonce, language: nil)!
        XCTAssertTrue(big.contains("lang=\"en\""))
        XCTAssertNil(HSHtmlBridge.document(html: "x", nonce: "kısa", language: nil))
    }

    func testNonceIsRandomAndSafe() {
        let a = HSHtmlBridge.newNonce()
        let b = HSHtmlBridge.newNonce()
        XCTAssertEqual(a.count, 24)
        XCTAssertTrue(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(HSHtmlBridge.script(nonce: "abc\"def</script>ghi")!.contains("var N=\"abcdefscriptghi\""))
    }

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    func testCarouselBlockParsing() throws {
        let m = try XCTUnwrap(HSInAppParser.parseMessage(json("""
        { "id": "iam_c", "priority": 0, "triggers": [],
          "display": { "layout": "modal", "dismissible": true, "content_type": "blocks", "html": null, "html_height": null, "blocks": [
            { "type": "title", "text": "Yeni özellikler" },
            { "type": "carousel", "id": "steps", "cards": [
              { "id": "c1", "title": "Adım 1", "body": "Profilini tamamla", "image_url": "https://cdn.example.com/1.png", "image_alt": "Profil",
                "button": { "id": "b1", "text": "Başla", "action": { "type": "deeplink", "url": "myapp://profile" } } },
              { "id": "c2", "title": "Adım 2", "body": null, "image_url": null, "image_alt": null, "button": null },
              { "id": "c3", "title": "Adım 3", "button": { "id": "bad", "text": "Kötü", "action": { "type": "url", "url": "javascript:alert(1)" } } },
              { "title": "Kimliksiz kart" }
            ] },
            { "type": "carousel", "id": "empty", "cards": [] },
            { "type": "button", "id": "close", "text": "Kapat", "action": { "type": "dismiss" } },
            { "type": "countdown", "id": "future" }
          ] } }
        """)))
        XCTAssertEqual(m.display.contentType, .blocks)
        XCTAssertFalse(m.display.isHtml)
        // Başlık, carousel ve düğme; kartsız carousel ve tanınmayan blok atlanır.
        XCTAssertEqual(m.display.blocks.count, 3)
        guard case let .carousel(carousel) = m.display.blocks[1] else { return XCTFail("carousel bekleniyordu") }
        XCTAssertEqual(carousel.id, "steps")
        XCTAssertEqual(carousel.cards.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(carousel.cards[0].body, "Profilini tamamla")
        XCTAssertEqual(carousel.cards[0].imageUrl, "https://cdn.example.com/1.png")
        XCTAssertEqual(carousel.cards[0].imageAlt, "Profil")
        XCTAssertEqual(carousel.cards[0].button?.action, .deeplink("myapp://profile"))
        XCTAssertNil(carousel.cards[1].button)
        XCTAssertNil(carousel.cards[1].body)
        XCTAssertNil(carousel.cards[2].button)
        // Tıklama bildirimi düğme listesinden çözülür: kart düğmeleri de bulunur.
        XCTAssertEqual(m.display.buttons.map(\.id), ["b1", "close"])
    }

    func testHtmlContentParsing() {
        let list = HSInAppParser.parseList(json("""
        { "language": "tr", "data": [
          { "id": "iam_h", "priority": 1, "triggers": [{ "kind": "session_start" }],
            "display": { "layout": "banner_bottom", "dismissible": true, "content_type": "html",
              "html": "<h1>Merhaba Ayşe</h1><button data-hs-close>Kapat</button>", "html_height": 140,
              "blocks": [{ "type": "title", "text": "yok sayılır" }] } },
          { "id": "iam_empty", "priority": 0, "triggers": [],
            "display": { "layout": "modal", "content_type": "html", "html": null, "html_height": null, "blocks": [] } },
          { "id": "iam_legacy", "priority": 0, "triggers": [],
            "display": { "layout": "modal", "blocks": [{ "type": "body", "text": "Eski" }] } }
        ] }
        """))
        // İçeriksiz HTML mesajı atlanır.
        XCTAssertEqual(list.map(\.id), ["iam_h", "iam_legacy"])
        let html = list[0]
        XCTAssertTrue(html.display.isHtml)
        XCTAssertEqual(html.display.html, "<h1>Merhaba Ayşe</h1><button data-hs-close>Kapat</button>")
        XCTAssertEqual(html.display.htmlHeight, 140)
        XCTAssertTrue(html.display.blocks.isEmpty)
        XCTAssertEqual(html.language, "tr")
        XCTAssertEqual(list[1].display.contentType, .blocks)
        XCTAssertNil(list[1].display.htmlHeight)
        XCTAssertEqual(list[1].display.blocks, [.body("Eski")])
    }
}
