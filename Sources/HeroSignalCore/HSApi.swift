import Foundation

/// API hatası; 429/5xx ve ağ hataları yeniden denenebilir.
public struct HSApiError: Error, Equatable {
    public let status: Int
    public let code: String
    public let message: String
    public var isRetryable: Bool { status == 0 || status == 429 || status >= 500 }
}

/// `/sdk/v1/apps/{appId}` uçlarına JSON istek (URLSession, async/await).
public final class HSApi {
    public let apiUrl: String
    public let appId: String
    public let sdkVersion: String
    private let session: URLSession
    private let backoff: [UInt64] = [500, 1_500, 4_000]

    public init(apiUrl: String, appId: String, sdkVersion: String, session: URLSession = .shared) {
        self.apiUrl = apiUrl.hasSuffix("/") ? String(apiUrl.dropLast()) : apiUrl
        self.appId = appId
        self.sdkVersion = sdkVersion
        self.session = session
    }

    public var base: String {
        "\(apiUrl)/sdk/v1/apps/\(appId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appId)"
    }

    @discardableResult
    public func request(_ method: String, _ path: String, body: [String: Any]? = nil, attempt: Int = 0) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw HSApiError(status: 0, code: "BAD_URL", message: path) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("herosignal-ios/\(sdkVersion)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                if data.isEmpty { return [:] }
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            let envelope = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let error = HSApiError(status: status, code: envelope?["code"] as? String ?? "HTTP_\(status)", message: envelope?["message"] as? String ?? "HTTP \(status)")
            guard error.isRetryable, attempt < backoff.count else { throw error }
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(UInt64.init)
            try await Task.sleep(nanoseconds: ((retryAfter ?? 0) > 0 ? retryAfter! * 1_000 : backoff[min(attempt, backoff.count - 1)]) * 1_000_000)
            return try await self.request(method, path, body: body, attempt: attempt + 1)
        } catch let error as HSApiError {
            throw error
        } catch {
            guard attempt < backoff.count else { throw HSApiError(status: 0, code: "NETWORK", message: error.localizedDescription) }
            try await Task.sleep(nanoseconds: backoff[min(attempt, backoff.count - 1)] * 1_000_000)
            return try await self.request(method, path, body: body, attempt: attempt + 1)
        }
    }
}
