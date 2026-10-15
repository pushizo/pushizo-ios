import Foundation

/// HTML in-app köprüsü (`HeroSignalBridge`) olay özelliği değeri.
public enum HSBridgeValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// `Session.sendEvent(properties:)` için Foundation değeri (`null` → `NSNull`).
    public var foundationValue: Any {
        switch self {
        case let .string(s): return s
        case let .number(n): return n
        case let .bool(b): return b
        case .null: return NSNull()
        }
    }
}

/// HTML in-app köprüsünden gelen, doğrulanmış eylem.
public enum HSHtmlBridgeAction: Equatable {
    case ready
    case close
    case click(actionId: String, url: String?)
    case addTag(key: String, value: String)
    case trackEvent(name: String, props: [String: HSBridgeValue])
    case resize(height: Int)
}

/**
 HTML in-app mesajı belgesi ve `HeroSignalBridge` köprü protokolü (v2 Faz 18, ADR-0027). Yalnızca Foundation kullanır;
 ortak vektörlerle (`sdk/testdata/html-bridge-vectors.json`) sınanır.

 Mantık `packages/shared/src/html-in-app.ts` ile birebir aynıdır; tek fark köprü betiğinin mesajı `window.parent`
 yerine `window.webkit.messageHandlers.heroSignalBridge.postMessage(JSON)` ile göndermesidir. Uzunluklar JavaScript gibi
 UTF-16 birimiyle ölçülür. Güvenlik modeli temizleme değil yalıtımdır: CSP ağ isteklerini ve dış betikleri engeller,
 WKWebView yapılandırması (`HSHtmlInAppView`) gezinme ve kalıcı depolamayı kapatır, uygulamaya yalnızca burada
 doğrulanan dört eylem ulaşır.
 */
public enum HSHtmlBridge {
    /// Belgeye eklenen içerik güvenliği politikası (Web SDK ile aynı).
    public static let csp = "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'"
    public static let mark = "herosignal-bridge"
    public static let version = 1
    /// HTML içeriği üst sınırı (UTF-16 birimi).
    public static let maxHtmlLength = 100_000
    /// Köprüden gelen tek mesajın üst sınırı (UTF-16 birimi); daha büyüğü ayrıştırılmadan reddedilir.
    public static let maxMessageLength = 32_000
    /// `WKUserContentController` ileti işleyicisinin adı.
    public static let handlerName = "heroSignalBridge"

    private static let maxProps = 20
    private static let nonceAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    private static let blockedSchemes: Set<String> = ["javascript", "data", "vbscript", "file", "blob", "about"]

    /// JavaScript `\s` ve `String.prototype.trim` ile aynı boşluk kümesi (UTF-16 birimleri).
    private static func isJsWhitespace(_ u: UInt16) -> Bool {
        switch u {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    private static func isAsciiLetter(_ u: UInt16) -> Bool { (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) }
    private static func isAsciiDigit(_ u: UInt16) -> Bool { (0x30...0x39).contains(u) }

    private static func jsTrim(_ value: String) -> String {
        let units = Array(value.utf16)
        var start = 0
        var end = units.count
        while start < end, isJsWhitespace(units[start]) { start += 1 }
        while end > start, isJsWhitespace(units[end - 1]) { end -= 1 }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    /// JavaScript `slice(0, n)` karşılığı (UTF-16 birimi).
    private static func jsPrefix(_ value: String, _ n: Int) -> String {
        value.utf16.count <= n ? value : String(decoding: Array(value.utf16.prefix(n)), as: UTF16.self)
    }

    /// Her gösterim için yeni nonce (24 güvenli karakter; sistem kriptografik üreteci).
    public static func newNonce() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<24).map { _ in nonceAlphabet.randomElement(using: &rng)! })
    }

    /// Köprüden gelen URL: http(s) veya uygulama şeması (`myapp://`); javascript:/data:/file: reddedilir.
    public static func safeUrl(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let v = jsTrim(raw)
        let u = Array(v.utf16)
        guard !u.isEmpty, u.count <= 2000, isAsciiLetter(u[0]) else { return nil }
        // `^[a-z][a-z0-9+.-]*:` (büyük/küçük harf duyarsız)
        var i = 1
        while i < u.count, isAsciiLetter(u[i]) || isAsciiDigit(u[i]) || u[i] == 0x2B || u[i] == 0x2E || u[i] == 0x2D { i += 1 }
        guard i < u.count, u[i] == 0x3A else { return nil }
        let scheme = String(decoding: u[0..<i], as: UTF16.self).lowercased()
        if blockedSchemes.contains(scheme) { return nil }
        let slashes = i + 2 < u.count && u[i + 1] == 0x2F && u[i + 2] == 0x2F
        if scheme == "http" || scheme == "https" {
            // `^https?://[^\s/]+`
            guard slashes, i + 3 < u.count, !isJsWhitespace(u[i + 3]), u[i + 3] != 0x2F else { return nil }
            return v
        }
        return slashes ? v : nil
    }

    /// http(s) adresi tarayıcıda, diğer (uygulama şeması) adresler deeplink olarak açılır.
    public static func isWebUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// `WKScriptMessage.body` (JSON metni) doğrulaması; geçersiz, başka nonce'lu veya bilinmeyen mesaj → nil.
    public static func parse(json: String, nonce: String) -> HSHtmlBridgeAction? {
        guard json.utf16.count <= maxMessageLength, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return parse(object, nonce: nonce)
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !isBool(n) else { return nil }
        return n.doubleValue
    }

    /// `JSONSerialization` çıktısını doğrular (Web SDK `parseBridgeMessage` ile aynı kurallar).
    public static func parse(_ object: Any, nonce: String) -> HSHtmlBridgeAction? {
        guard let data = object as? [String: Any],
              data["hs"] as? String == mark,
              number(data["v"]) == Double(version),
              data["nonce"] as? String == nonce else { return nil }
        switch data["type"] as? String {
        case "ready":
            return .ready
        case "close":
            return .close
        case "click":
            guard let actionId = data["action_id"] as? String, isActionId(actionId) else { return nil }
            let raw = data["url"]
            if raw == nil || raw is NSNull || (raw as? String) == "" { return .click(actionId: actionId, url: nil) }
            return .click(actionId: actionId, url: safeUrl(raw))
        case "add_tag":
            guard let key = data["key"] as? String else { return nil }
            let units = key.utf16
            guard !units.isEmpty, units.count <= 128, !units.contains(where: isJsWhitespace) else { return nil }
            guard let value = data["value"] as? String, value.utf16.count <= 255 else { return nil }
            return .addTag(key: key, value: value)
        case "track_event":
            guard let rawName = data["name"] as? String else { return nil }
            let name = jsTrim(rawName)
            guard !name.isEmpty, name.utf16.count <= 100 else { return nil }
            var props: [String: HSBridgeValue] = [:]
            if let raw = data["props"], !(raw is NSNull) {
                guard let dict = raw as? [String: Any], dict.count <= maxProps else { return nil }
                for (k, v) in dict {
                    guard !k.isEmpty, k.utf16.count <= 64 else { return nil }
                    if v is NSNull {
                        props[k] = .null
                    } else if let s = v as? String {
                        props[k] = .string(jsPrefix(s, 255))
                    } else if let n = v as? NSNumber {
                        if isBool(n) { props[k] = .bool(n.boolValue) }
                        else if n.doubleValue.isFinite { props[k] = .number(n.doubleValue) }
                        else { return nil }
                    } else {
                        return nil
                    }
                }
            }
            return .trackEvent(name: name, props: props)
        case "resize":
            guard let h = number(data["height"]), h.isFinite, h >= 1 else { return nil }
            return .resize(height: Int(min(h.rounded(.up), 5000)))
        default:
            return nil
        }
    }

    /// `^[A-Za-z0-9_.:-]{1,64}$`
    private static func isActionId(_ value: String) -> Bool {
        let units = value.utf16
        guard !units.isEmpty, units.count <= 64 else { return false }
        return units.allSatisfy { isAsciiLetter($0) || isAsciiDigit($0) || $0 == 0x5F || $0 == 0x2E || $0 == 0x3A || $0 == 0x2D }
    }

    /// Nonce'u yalnızca güvenli karakterlerle sınırlar (betik içine gömülür); 8 karakterden kısaysa nil.
    static func cleanNonce(_ nonce: String) -> String? {
        let allowed = Set(nonceAlphabet)
        let n = String(nonce.filter { allowed.contains($0) }.prefix(64))
        return n.count >= 8 ? n : nil
    }

    /**
     WKWebView içinde çalışan köprü betiği (Web SDK `htmlBridgeScript` ile aynı davranış). `HeroSignalBridge` değiştirilemez
     nesnedir; bağlantı tıklamaları gezinme yerine `click('link', href)` olur, `data-hs-close` kapatır,
     `data-hs-action="kimlik"` tıklama bildirir, form gönderimi engellenir, yükseklik `resize` ile bildirilir.
     İleti işleyicisi betik başında yakalanır (mesajın kendi betikleri `window.webkit`i sonradan değiştiremez).
     */
    public static func script(nonce: String) -> String? {
        guard let n = cleanNonce(nonce) else { return nil }
        let parts: [String] = [
            "(function(){\"use strict\";var N=\"" + n + "\",W=window.webkit,P=W&&W.messageHandlers&&W.messageHandlers." + handlerName + ";",
            "function s(m){m.hs=\"" + mark + "\";m.v=" + String(version) + ";m.nonce=N;try{P.postMessage(JSON.stringify(m))}catch(e){}}",
            "function t(v,x){return typeof v===\"string\"?v.slice(0,x):\"\"}",
            "var B=Object.freeze({",
            "close:function(){s({type:\"close\"})},",
            "click:function(a,u){s({type:\"click\",action_id:t(a,64)||\"html\",url:typeof u===\"string\"?u.slice(0,2000):undefined})},",
            "addTag:function(k,v){s({type:\"add_tag\",key:t(k,128),value:String(v==null?\"\":v).slice(0,255)})},",
            "trackEvent:function(n,p){var o={};try{o=JSON.parse(JSON.stringify(p||{}))}catch(e){}s({type:\"track_event\",name:t(n,100),props:o})}",
            "});",
            "try{Object.defineProperty(window,\"HeroSignalBridge\",{value:B,writable:false,configurable:false})}catch(e){}",
            "document.addEventListener(\"click\",function(e){var el=e.target;if(!el||!el.closest)return;",
            "var c=el.closest(\"[data-hs-close]\");if(c){e.preventDefault();B.close();return}",
            "var a=el.closest(\"[data-hs-action]\");var l=el.closest(\"a[href]\");",
            "if(a){e.preventDefault();B.click(a.getAttribute(\"data-hs-action\"),(l||a).getAttribute(\"href\")||a.getAttribute(\"data-hs-url\")||undefined);return}",
            "if(l){e.preventDefault();B.click(\"link\",l.getAttribute(\"href\"))}},true);",
            "document.addEventListener(\"submit\",function(e){e.preventDefault()},true);",
            "var H=0;function r(){var h=Math.ceil(document.documentElement.scrollHeight||0);if(h&&h!==H){H=h;s({type:\"resize\",height:h})}}",
            "window.addEventListener(\"load\",function(){s({type:\"ready\"});r()});",
            "if(typeof ResizeObserver===\"function\"){try{new ResizeObserver(r).observe(document.documentElement)}catch(e){}}",
            "})();",
        ]
        return parts.joined()
    }

    /**
     WKWebView belgesi: CSP meta etiketi en başta (kullanıcı HTML'inden önce), ardından köprü betiği ve kullanıcı HTML'i.
     Kullanıcı HTML'i tam belge ise olduğu gibi `<body>` içine konur; CSP ilk meta ile zaten yürürlüktedir.
     Nonce 8 güvenli karakterden kısaysa nil.
     */
    public static func document(html: String, nonce: String, language: String?) -> String? {
        guard let script = script(nonce: nonce) else { return nil }
        let langChars = (language ?? "en").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let lang = langChars.isEmpty ? "en" : String(langChars.prefix(10))
        let parts: [String] = [
            "<!doctype html><html lang=\"" + lang + "\"><head><meta charset=\"utf-8\">",
            "<meta http-equiv=\"Content-Security-Policy\" content=\"" + csp + "\">",
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
            "<meta name=\"color-scheme\" content=\"light dark\">",
            "<meta name=\"referrer\" content=\"no-referrer\">",
            "<style>html,body{margin:0;padding:0}body{font:15px/1.5 system-ui,-apple-system,\"Segoe UI\",Roboto,sans-serif}</style>",
            "<script>" + script + "</script></head><body>",
            jsPrefix(html, maxHtmlLength),
            "</body></html>",
        ]
        return parts.joined()
    }
}
