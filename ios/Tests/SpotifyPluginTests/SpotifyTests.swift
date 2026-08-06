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
            "TOKEN_REFRESH_FAILED", "SPOTIFY_APP_NOT_INSTALLED", "NOT_CONNECTED",
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
