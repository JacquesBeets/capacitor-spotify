import Foundation

/// Authenticated caller for the Spotify Web API.
///
/// App Remote cannot queue tracks, enumerate Connect devices or move playback
/// between them, so those calls go over HTTP instead. Access tokens come from
/// `SpotifyAuthManager`, which already refreshes them lazily — nothing here
/// duplicates that logic.
///
/// Must be called on the main thread (`SpotifyAuthManager` requires it);
/// completions come back on the main thread too.
final class SpotifyWebApiClient {
    /// `nil` data means the response carried no body — every mutating endpoint
    /// used here answers `204 No Content`.
    typealias DataCompletion = (Result<Data?, SpotifyError>) -> Void

    private static let baseUrl = "https://api.spotify.com/v1"
    /// Error bodies are not reliably JSON, and can be long; a snippet is enough
    /// to make a rejection debuggable.
    private static let snippetLimit = 500

    private weak var auth: SpotifyAuthManager?
    private let urlSession: URLSession

    init(auth: SpotifyAuthManager, urlSession: URLSession = .shared) {
        self.auth = auth
        self.urlSession = urlSession
    }

    /// Calls `https://api.spotify.com/v1<path>` with a bearer token.
    ///
    /// A `401` is retried once against a force-refreshed token before it is
    /// reported as `NOT_AUTHENTICATED`.
    func request(method: String, path: String, body: [String: Any]? = nil, completion: @escaping DataCompletion) {
        perform(method: method, path: path, body: body, mayRetry: true, completion: completion)
    }

    /// `encodeURIComponent` semantics: Spotify URIs are full of `:`, which
    /// `.urlQueryAllowed` would leave unescaped.
    static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Request pipeline

    private enum Outcome {
        case success(Data?)
        /// A `401` that still has its one forced-refresh retry left.
        case retryAuth
        case failure(SpotifyError)
    }

    /// `mayRetry` is spent by the single retry a `401` earns; the retry itself
    /// runs with a force-refreshed token and no further retries.
    private func perform(
        method: String,
        path: String,
        body: [String: Any]?,
        mayRetry: Bool,
        completion: @escaping DataCompletion
    ) {
        guard let url = URL(string: Self.baseUrl + path) else {
            completion(.failure(SpotifyError(.unknown, "Invalid Spotify Web API path '\(path)'")))
            return
        }
        guard let auth = auth else {
            completion(.failure(SpotifyError(.notInitialized, "Spotify plugin is not initialized — call initialize() first")))
            return
        }

        auth.getAccessToken(forceRefresh: !mayRetry) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let session):
                guard let request = Self.urlRequest(url: url, method: method, body: body, token: session.accessToken) else {
                    completion(.failure(SpotifyError(.unknown, "Could not encode the Spotify Web API request body")))
                    return
                }
                self.send(request, mayRetry: mayRetry) { outcome in
                    switch outcome {
                    case .success(let data):
                        completion(.success(data))
                    case .failure(let error):
                        completion(.failure(error))
                    case .retryAuth:
                        self.perform(method: method, path: path, body: body, mayRetry: false, completion: completion)
                    }
                }
            }
        }
    }

    /// Nil when `body` is not JSON-encodable.
    private static func urlRequest(url: URL, method: String, body: [String: Any]?, token: String) -> URLRequest? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body = body {
            guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.httpBody = encoded
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest, mayRetry: Bool, completion: @escaping (Outcome) -> Void) {
        urlSession.dataTask(with: request) { data, response, error in
            let outcome = Self.outcome(data: data, response: response, error: error, mayRetry: mayRetry)
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    // MARK: - Response mapping

    private static func outcome(data: Data?, response: URLResponse?, error: Error?, mayRetry: Bool) -> Outcome {
        if let error = error {
            return .failure(SpotifyError.from(error, fallback: .offline, prefix: "The Spotify Web API is unreachable"))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(SpotifyError(.unknown, "The Spotify Web API returned no response"))
        }

        let status = http.statusCode
        if (200..<300).contains(status) {
            guard status != 204, let data = data, !data.isEmpty else { return .success(nil) }
            return .success(data)
        }
        if status == 401, mayRetry {
            return .retryAuth
        }
        return .failure(failure(status: status, http: http, body: snippet(from: data)))
    }

    /// Mirrors the status mapping of the web implementation (`src/web/api.ts`)
    /// so `error.code` means the same thing on every platform.
    private static func failure(status: Int, http: HTTPURLResponse, body: String) -> SpotifyError {
        let suffix = body.isEmpty ? "" : ": \(body)"
        switch status {
        case 401:
            return SpotifyError(.notAuthenticated, "Spotify rejected the access token\(suffix)")
        case 403:
            return body.localizedCaseInsensitiveContains("premium")
                ? SpotifyError(.premiumRequired, "Spotify Premium is required for playback control\(suffix)")
                : SpotifyError(.userNotAuthorized, "Spotify refused the request\(suffix)")
        case 404:
            return SpotifyError(
                .notActiveDevice,
                "Spotify has no active device for this request — start playback on a device first\(suffix)"
            )
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After") ?? "a few"
            return SpotifyError(.rateLimited, "Spotify rate limited the request. Retry after \(retryAfter) seconds\(suffix)")
        default:
            return SpotifyError(.playbackFailed, "The Spotify Web API request failed (HTTP \(status))\(suffix)")
        }
    }

    private static func snippet(from data: Data?) -> String {
        guard let data = data, let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(snippetLimit))
    }
}
