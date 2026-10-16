import Foundation

/// Hücre mimarisi (ADR-0032 §4): SDK, app'in veri bölgesindeki API kökünü config `api_url`'den veya yanlış hücreye
/// giden isteğin 421 `HS_WRONG_CELL` yanıtındaki `details.api_url`'den öğrenir. Saf mantık; ortak vektörler
/// `sdk/testdata/cell-routing-vectors.json` (Web ve Android aynı kuralları uygular).
public enum HSCellRouting {
    public static let wrongCellStatus = 421
    public static let wrongCellCode = "HS_WRONG_CELL"
    /// Varsayılan (global) API kökü: `HSOptions.apiUrl` bu değerdeyse config `api_url` benimsenir.
    public static let defaultApiUrl = "https://api.pushizo.com"

    public static func trimSlash(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        if h == "localhost" || h.hasSuffix(".localhost") || h == "::1" || h == "[::1]" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }
    }

    /// Sunucunun bildirdiği API kökünü doğrular; kabul edilirse sondaki `/` atılmış hâlini döner.
    /// Kural: geçerli mutlak URL, `https` zorunlu (tek istisna: mevcut kök de `http` loopback iken loopback hedef),
    /// kullanıcı bilgisi / sorgu / parça içeremez. Alan adı kısıtlaması yoktur (bölge ve bayi alan adları farklı üst
    /// alan adlarında olabilir); adres yalnızca zaten güvenilen API'nin TLS yanıtından alınır.
    public static func acceptApiUrl(_ candidate: Any?, current: String) -> String? {
        guard let text = candidate as? String, !text.isEmpty, text.count <= 2048,
              let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }
        switch components.scheme?.lowercased() {
        case "https":
            break
        case "http":
            let cur = URLComponents(string: current)
            guard isLoopback(host), cur?.scheme?.lowercased() == "http", isLoopback(cur?.host) else { return nil }
        default:
            return nil
        }
        return trimSlash(text)
    }

    /// 421 `HS_WRONG_CELL` hata zarfından kabul edilebilir yeni API kökü (yoksa veya mevcut kökse nil).
    public static func wrongCellTarget(status: Int, envelope: Any?, current: String) -> String? {
        guard status == wrongCellStatus,
              let error = (envelope as? [String: Any])?["error"] as? [String: Any],
              error["code"] as? String == wrongCellCode,
              let next = acceptApiUrl((error["details"] as? [String: Any])?["api_url"], current: current)
        else { return nil }
        return next == trimSlash(current) ? nil : next
    }

    /// Başlangıçta kullanılacak kök: aynı başlangıç kökü (`seed`) için öğrenilmiş geçerli bölgesel kök varsa o, yoksa `seed`.
    public static func initialBase(seed: String, savedSeed: String?, savedUrl: String?) -> String {
        let normalized = trimSlash(seed)
        guard savedSeed == normalized else { return normalized }
        return acceptApiUrl(savedUrl, current: normalized) ?? normalized
    }
}
