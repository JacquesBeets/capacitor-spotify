import Foundation

/// Exchanges a refresh token for a fresh access token.
///
/// The plugin is a PKCE public client, so no client secret is ever involved —
/// unless the app configured a `tokenRefreshUrl`, in which case that service
/// holds the secret and only wants the refresh token.
struct SpotifyTokenRefresher {
    typealias Completion = (Result<StoredSession, SpotifyError>) -> Void

    let clientId: String
    /// The app's own refresh service, when one was configured.
    let endpointOverride: URL?
    let urlSession: URLSession

    private static let spotifyTokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")

    /// `previous` supplies the fallbacks for anything the response omits.
    /// Completes on the main thread.
    func refresh(refreshToken: String, previous: StoredSession, completion: @escaping Completion) {
        guard let endpoint = endpointOverride ?? Self.spotifyTokenEndpoint else {
            completion(.failure(SpotifyError(.tokenRefreshFailed, "Invalid token refresh URL")))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let fields: [String: String] = endpointOverride != nil
            ? ["refresh_token": refreshToken]
            : ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId]
        request.httpBody = Self.formEncode(fields).data(using: .utf8)

        urlSession.dataTask(with: request) { data, response, error in
            let result = Self.parse(data: data, response: response, error: error, previous: previous)
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func parse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        previous: StoredSession
    ) -> Result<StoredSession, SpotifyError> {
        if let error = error {
            return .failure(SpotifyError.from(error, fallback: .tokenRefreshFailed, prefix: "Token refresh failed"))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(SpotifyError(.tokenRefreshFailed, "Token refresh returned an unreadable response (HTTP \(status))"))
        }

        guard (200..<300).contains(status), let accessToken = json["access_token"] as? String else {
            let detail = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(status)"
            let code: SpotifyErrorCode = status == 429 ? .rateLimited : .tokenRefreshFailed
            return .failure(SpotifyError(code, "Token refresh failed: \(detail)"))
        }

        let expiresIn = (json["expires_in"] as? Int) ?? 3600
        let scopes = (json["scope"] as? String)
            .map { $0.split(separator: " ").map(String.init) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return .success(StoredSession(
            accessToken: accessToken,
            // Spotify rotates refresh tokens on some grants; keep the old one
            // when the response omits a replacement.
            refreshToken: (json["refresh_token"] as? String) ?? previous.refreshToken,
            expiresAt: nowMs() + expiresIn * 1000,
            scopes: scopes ?? previous.scopes
        ))
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .sorted()
            .joined(separator: "&")
    }
}
