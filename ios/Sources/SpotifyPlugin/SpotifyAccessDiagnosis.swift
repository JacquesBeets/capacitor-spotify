import Foundation

/// Spotify's own verdict on whether this app and account may use the Web API,
/// as returned by `diagnoseAccess()`.
///
/// Deliberately not an `Error`: the point is to hand the caller Spotify's
/// message rather than the plugin's interpretation of it. Two app-level `403`s
/// are indistinguishable from the native side — both make `connect()` fail with
/// `com.spotify.app-remote.transport Code=-2000 "Stream error."` and
/// `authorizeAndPlayURI` return `NO` — and one of them names the wrong setting,
/// so the raw text is the only reliable diagnosis.
///
/// Mirrors `AccessDiagnosis` in `src/definitions.ts`; the wording is shared with
/// the Android and web implementations so integrators compare like with like.
struct SpotifyAccessDiagnosis {
    /// Serialized as `ok`, the JS field name.
    let allowed: Bool
    let message: String
    let code: SpotifyErrorCode?
    let httpStatus: Int?
    let spotifyMessage: String?
    let userId: String?
    let product: String?

    var asJS: [String: Any] {
        var payload: [String: Any] = ["ok": allowed, "message": message]
        if let code = code {
            payload["code"] = code.rawValue
        }
        if let httpStatus = httpStatus {
            payload["httpStatus"] = httpStatus
        }
        if let spotifyMessage = spotifyMessage, !spotifyMessage.isEmpty {
            payload["spotifyMessage"] = spotifyMessage
        }
        if let userId = userId {
            payload["userId"] = userId
        }
        if let product = product {
            payload["product"] = product
        }
        return payload
    }

    /// Reads a `GET /v1/me` response. `body` is Spotify's payload, whatever it
    /// contained — JSON on both the success and the error path, in practice.
    static func from(status: Int, body: String) -> SpotifyAccessDiagnosis {
        let reported = spotifyMessage(in: body)

        if (200..<300).contains(status) {
            let profile = json(body)
            return SpotifyAccessDiagnosis(
                allowed: true,
                message: "Spotify accepted GET /v1/me — this app and account can use the Web API",
                code: nil,
                httpStatus: status,
                spotifyMessage: nil,
                userId: profile?["id"] as? String,
                product: profile?["product"] as? String
            )
        }

        return SpotifyAccessDiagnosis(
            allowed: false,
            message: reading(status: status, reported: reported),
            code: self.code(status: status, reported: reported),
            httpStatus: status,
            spotifyMessage: reported.isEmpty ? nil : reported,
            userId: nil,
            product: nil
        )
    }

    /// The probe never got an answer — no session, no network, or no plugin.
    static func failed(_ error: SpotifyError) -> SpotifyAccessDiagnosis {
        SpotifyAccessDiagnosis(
            allowed: false,
            message: error.message,
            code: error.code,
            httpStatus: nil,
            spotifyMessage: nil,
            userId: nil,
            product: nil
        )
    }

    // MARK: - Mapping

    private static func reading(status: Int, reported: String) -> String {
        switch status {
        case 401:
            return "Spotify rejected the access token — the session is no longer valid, call authorize() again"
        case 403 where reported.localizedCaseInsensitiveContains("owner"):
            return "Spotify is refusing this app: the account that owns your dashboard app has no active Premium "
                + "subscription. That blocks every user of the app regardless of their own tier, and Spotify can "
                + "take a few hours to allow requests again once the subscription is active."
        case 403:
            return "Spotify is refusing this account. Its message points at User Management, but non-owner accounts "
                + "get that same text when the dashboard app owner's Premium subscription has lapsed — check the "
                + "owner's subscription first, then the app's User Management allowlist."
        case 429:
            return "Spotify rate limited the probe — retry in a few seconds"
        default:
            return "Spotify answered the probe with HTTP \(status)"
        }
    }

    /// Same status-to-code mapping as `SpotifyWebApiClient` and `src/web/api.ts`,
    /// so a diagnosis and a real rejection agree about what went wrong.
    private static func code(status: Int, reported: String) -> SpotifyErrorCode {
        switch status {
        case 401:
            return .notAuthenticated
        case 403 where reported.localizedCaseInsensitiveContains("premium"):
            return .premiumRequired
        case 403:
            return .userNotAuthorized
        case 429:
            return .rateLimited
        default:
            return .unknown
        }
    }

    /// Spotify wraps its reason in `{"error": {"status": …, "message": …}}`.
    /// Falls back to the raw body, which is all a non-JSON error leaves behind.
    private static func spotifyMessage(in body: String) -> String {
        guard let error = json(body)?["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(body.prefix(messageLimit))
        }
        return String(message.prefix(messageLimit))
    }

    /// Matches the error-body limit the Web API clients use on every platform.
    private static let messageLimit = 500

    private static func json(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
