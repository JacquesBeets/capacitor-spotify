import XCTest
@testable import SpotifyPlugin

/// Unit coverage for the pure mapping helpers. Anything that touches
/// `SPTAppRemote` or `SPTSessionManager` needs a live Spotify app, so it is
/// exercised from the example app rather than here.
final class SpotifyTests: XCTestCase {
    /// Every code in the JS `SpotifyErrorCode` union must exist natively with
    /// the exact same wire string, since apps switch on `error.code`.
    func testErrorCodesMatchTypeScriptUnion() {
        let expected = [
            "NOT_INITIALIZED", "NOT_AUTHENTICATED", "AUTH_CANCELLED", "AUTH_FAILED",
            "TOKEN_REFRESH_FAILED", "SPOTIFY_APP_NOT_INSTALLED", "AUTHORIZE_AND_PLAY_REFUSED", "NOT_CONNECTED",
            "CONNECTION_FAILED", "PREMIUM_REQUIRED", "USER_NOT_AUTHORIZED",
            "UNSUPPORTED_VERSION", "OFFLINE", "NOT_ACTIVE_DEVICE", "NOT_SUPPORTED",
            "PLAYBACK_FAILED", "RATE_LIMITED", "UNKNOWN"
        ]
        for code in expected {
            XCTAssertNotNil(SpotifyErrorCode(rawValue: code), "missing native error code \(code)")
        }
    }

    func testSpotifyErrorSerializesForConnectionEvents() {
        let error = SpotifyError(.notConnected, "nope")
        XCTAssertEqual(error.asJS["code"] as? String, "NOT_CONNECTED")
        XCTAssertEqual(error.asJS["message"] as? String, "nope")
        XCTAssertNil(error.asJS["cause"], "no cause means no key, not a null")
    }

    /// The transport error behind a failure is the whole diagnosis, so it has
    /// to reach JS: `cause` for listeners, and `message` for a rejected promise
    /// (which carries nothing else across the bridge).
    func testSpotifyErrorKeepsTheUnderlyingFailure() {
        let underlying = NSError(
            domain: "com.spotify.app-remote.transport",
            code: -2000,
            userInfo: [NSLocalizedDescriptionKey: "Stream error."]
        )
        XCTAssertEqual(
            SpotifyError.describe(underlying),
            "com.spotify.app-remote.transport Code=-2000 \"Stream error.\""
        )
        XCTAssertNil(SpotifyError.describe(nil))

        let mapped = SpotifyError.from(underlying, fallback: .connectionFailed, prefix: "Could not connect")
        XCTAssertEqual(mapped.code, .connectionFailed)
        XCTAssertEqual(mapped.message, "Could not connect: Stream error.")
        XCTAssertEqual(mapped.cause, "com.spotify.app-remote.transport Code=-2000 \"Stream error.\"")
        XCTAssertEqual(mapped.asJS["cause"] as? String, mapped.cause)

        let blamed = SpotifyError(.authorizeAndPlayRefused, "Refused").withUnderlying("Code=-2000")
        XCTAssertEqual(blamed.code, .authorizeAndPlayRefused)
        XCTAssertEqual(blamed.cause, "Code=-2000")
        XCTAssertTrue(blamed.message.contains("Refused"))
        XCTAssertTrue(blamed.message.contains("Code=-2000"))
        // Already-blamed errors stay put rather than growing a second copy.
        XCTAssertEqual(blamed.withUnderlying("Code=-2000").message, blamed.message)
    }

    /// A timeout carries no `NSError`, and must not claim one.
    func testSpotifyErrorFromNilKeepsThePrefixOnly() {
        let error = SpotifyError.from(nil, fallback: .connectionFailed, prefix: "Could not connect")
        XCTAssertEqual(error.message, "Could not connect")
        XCTAssertNil(error.cause)
    }

    func testOfflineTransportErrorsAreClassifiedAsOffline() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(SpotifyError.from(offline, fallback: .connectionFailed).code, .offline)
    }

    // MARK: - diagnoseAccess

    /// The owner-subscription 403 is the one the old error reporting hid, and
    /// Spotify's own wording is what tells it apart from an allowlist miss.
    func testDiagnosisNamesTheOwnerSubscription() {
        let body = """
        {"error":{"status":403,"message":"Active premium subscription required for the owner of the app. \
        When the subscription status changes, it can take a few hours before requests are allowed again."}}
        """
        let diagnosis = SpotifyAccessDiagnosis.from(status: 403, body: body)

        XCTAssertFalse(diagnosis.allowed)
        XCTAssertEqual(diagnosis.code, .premiumRequired)
        XCTAssertEqual(diagnosis.httpStatus, 403)
        XCTAssertTrue(diagnosis.message.contains("owns your dashboard app"))
        // Spotify's own text, unwrapped from its JSON envelope and verbatim.
        XCTAssertEqual(diagnosis.spotifyMessage?.hasPrefix("Active premium subscription required"), true)
        XCTAssertNil(diagnosis.userId)
    }

    /// The message a non-owner account gets for *either* cause. The reading has
    /// to warn that it names the wrong setting.
    func testDiagnosisDistrustsTheNotRegisteredMessage() {
        let body = """
        {"error":{"status":403,"message":"Check settings on https://developer.spotify.com/dashboard, \
        the user may not be registered."}}
        """
        let diagnosis = SpotifyAccessDiagnosis.from(status: 403, body: body)

        XCTAssertEqual(diagnosis.code, .userNotAuthorized)
        XCTAssertTrue(diagnosis.message.contains("owner's subscription first"))
        XCTAssertEqual(diagnosis.spotifyMessage?.contains("may not be registered"), true)
    }

    func testDiagnosisReadsTheProfileOnSuccess() {
        let diagnosis = SpotifyAccessDiagnosis.from(
            status: 200,
            body: #"{"id":"someuser","product":"premium","display_name":"Someone"}"#
        )

        XCTAssertTrue(diagnosis.allowed)
        XCTAssertNil(diagnosis.code)
        XCTAssertEqual(diagnosis.userId, "someuser")
        XCTAssertEqual(diagnosis.product, "premium")
        XCTAssertNil(diagnosis.asJS["spotifyMessage"], "nothing was refused, so there is nothing to quote")
        XCTAssertEqual(diagnosis.asJS["ok"] as? Bool, true)
    }

    /// A non-JSON body still has to produce a usable diagnosis rather than
    /// swallowing whatever Spotify (or a proxy) actually said.
    func testDiagnosisFallsBackToTheRawBody() {
        let diagnosis = SpotifyAccessDiagnosis.from(status: 502, body: "<html>Bad gateway</html>")

        XCTAssertEqual(diagnosis.code, .unknown)
        XCTAssertEqual(diagnosis.spotifyMessage, "<html>Bad gateway</html>")
        XCTAssertTrue(diagnosis.message.contains("HTTP 502"))
    }

    /// No answer at all — no session, no network, no plugin — is still reported,
    /// never thrown: `diagnoseAccess()` is what a caller reaches for in a catch.
    func testDiagnosisReportsAFailureToEvenAsk() {
        let diagnosis = SpotifyAccessDiagnosis.failed(SpotifyError(.notAuthenticated, "No Spotify session"))

        XCTAssertFalse(diagnosis.allowed)
        XCTAssertEqual(diagnosis.code, .notAuthenticated)
        XCTAssertEqual(diagnosis.message, "No Spotify session")
        XCTAssertNil(diagnosis.asJS["httpStatus"])
    }

    /// A nil player state still has to produce the full `PlayerState` shape so
    /// JS callers never have to null-check the event payload itself.
    func testPlayerStateToJSWithNilStateIsTotal() {
        let json = playerStateToJS(nil)

        XCTAssertTrue(json["track"] is NSNull)
        XCTAssertEqual(json["paused"] as? Bool, true)
        XCTAssertEqual(json["positionMs"] as? Int, 0)
        XCTAssertEqual(json["playbackSpeed"] as? Double, 1.0)
        XCTAssertEqual(json["shuffle"] as? Bool, false)
        XCTAssertEqual(json["repeatMode"] as? String, "off")
        XCTAssertNotNil(json["receivedAtMs"] as? Int)
        XCTAssertNil(json["contextUri"])

        let restrictions = json["restrictions"] as? [String: Any]
        XCTAssertEqual(restrictions?.count, 6)
        XCTAssertEqual(restrictions?["canSkipNext"] as? Bool, false)
    }

    func testTrackToJSWithNilTrack() {
        XCTAssertNil(trackToJS(nil))
    }

    func testRepeatModeRoundTrip() {
        for value in ["off", "track", "context"] {
            guard let parsed = repeatModeFromJS(value) else {
                return XCTFail("\(value) should parse")
            }
            XCTAssertEqual(repeatModeToJS(parsed), value)
        }
        XCTAssertNil(repeatModeFromJS("all"))
    }

    func testScopeParsingSplitsKnownFromUnknown() {
        let (mask, unmapped) = SpotifyScopes.parse(["streaming", "app-remote-control", "not-a-scope"])

        XCTAssertTrue(mask.contains(.streaming))
        XCTAssertTrue(mask.contains(.appRemoteControl))
        XCTAssertEqual(unmapped, ["not-a-scope"])
        XCTAssertEqual(SpotifyScopes.strings(mask), ["app-remote-control", "streaming"])
        XCTAssertNil(SpotifyScopes.strings([]))
    }

    func testAuthErrorClassifiesUserCancellation() {
        XCTAssertEqual(SpotifyAuthManager.authError(fromDescription: "access_denied").code, .authCancelled)
        XCTAssertEqual(SpotifyAuthManager.authError(fromDescription: "invalid_client").code, .authFailed)
    }

    /// The refresh body is form-encoded by hand — tokens contain characters
    /// (`-`, `_`, and occasionally `/` or `+`) that must survive the round trip.
    func testFormEncodingEscapesReservedCharacters() {
        let encoded = SpotifyTokenRefresher.formEncode(["grant_type": "refresh_token", "refresh_token": "a/b+c=d"])
        XCTAssertEqual(encoded, "grant_type=refresh_token&refresh_token=a%2Fb%2Bc%3Dd")
    }

    func testStoredSessionValidityUsesLeeway() {
        let expiring = StoredSession(accessToken: "a", refreshToken: nil, expiresAt: nowMs() + 30_000, scopes: nil)
        let fresh = StoredSession(accessToken: "a", refreshToken: "r", expiresAt: nowMs() + 600_000, scopes: ["streaming"])

        XCTAssertFalse(expiring.isValid(), "a token expiring inside the leeway window is not usable")
        XCTAssertTrue(fresh.isValid())
        XCTAssertEqual(fresh.asJS["tokenType"] as? String, "Bearer")
        XCTAssertEqual(fresh.asJS["scopes"] as? [String], ["streaming"])
        XCTAssertNil(expiring.asJS["scopes"])
    }

    func testCapabilitiesMatchIOSPlatform() {
        XCTAssertEqual(Spotify.capabilities["platform"] as? String, "ios")
        XCTAssertEqual(Spotify.capabilities["requiresSpotifyApp"] as? Bool, true)
        XCTAssertEqual(Spotify.capabilities["requiresPremium"] as? Bool, false)
        XCTAssertEqual(Spotify.capabilities["canSetVolume"] as? Bool, false)
        XCTAssertEqual(Spotify.capabilities["canGetVolume"] as? Bool, false)
        XCTAssertEqual(Spotify.capabilities["webPlaybackViable"] as? Bool, false)
    }
}
