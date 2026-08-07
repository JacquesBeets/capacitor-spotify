import Foundation
import Security
import SpotifyiOS

// MARK: - Error codes

/// Mirrors `SpotifyErrorCode` in `src/definitions.ts`. The raw values are the
/// strings surfaced to JavaScript as `error.code`.
public enum SpotifyErrorCode: String {
    case notInitialized = "NOT_INITIALIZED"
    case notAuthenticated = "NOT_AUTHENTICATED"
    case authCancelled = "AUTH_CANCELLED"
    case authFailed = "AUTH_FAILED"
    case tokenRefreshFailed = "TOKEN_REFRESH_FAILED"
    case spotifyAppNotInstalled = "SPOTIFY_APP_NOT_INSTALLED"
    case notConnected = "NOT_CONNECTED"
    case connectionFailed = "CONNECTION_FAILED"
    case premiumRequired = "PREMIUM_REQUIRED"
    case userNotAuthorized = "USER_NOT_AUTHORIZED"
    case unsupportedVersion = "UNSUPPORTED_VERSION"
    case offline = "OFFLINE"
    case notActiveDevice = "NOT_ACTIVE_DEVICE"
    case notSupported = "NOT_SUPPORTED"
    case playbackFailed = "PLAYBACK_FAILED"
    case rateLimited = "RATE_LIMITED"
    case unknown = "UNKNOWN"
}

/// Every rejection this plugin produces. `code` is what apps switch on.
public struct SpotifyError: Error {
    public let code: SpotifyErrorCode
    public let message: String

    public init(_ code: SpotifyErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    /// Shape used inside the `error` field of `connectionStateChanged`.
    public var asJS: [String: Any] {
        ["code": code.rawValue, "message": message]
    }

    /// Best-effort translation of an SDK/transport error into a plugin error.
    public static func from(_ error: Error?, fallback: SpotifyErrorCode, prefix: String = "") -> SpotifyError {
        guard let error = error else {
            return SpotifyError(fallback, prefix.isEmpty ? "Unknown Spotify error" : prefix)
        }
        let nsError = error as NSError
        let message = prefix.isEmpty ? nsError.localizedDescription : "\(prefix): \(nsError.localizedDescription)"

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed:
                return SpotifyError(.offline, message)
            default:
                return SpotifyError(fallback, message)
            }
        }

        if nsError.domain == SPTAppRemoteErrorDomain {
            switch nsError.code {
            case SPTAppRemoteErrorCode.backgroundWakeupFailedError.rawValue,
                 SPTAppRemoteErrorCode.connectionAttemptFailedError.rawValue:
                return SpotifyError(.connectionFailed, message)
            case SPTAppRemoteErrorCode.connectionTerminatedError.rawValue:
                return SpotifyError(.notConnected, message)
            case SPTAppRemoteErrorCode.invalidArgumentsError.rawValue,
                 SPTAppRemoteErrorCode.requestFailedError.rawValue:
                return SpotifyError(fallback, message)
            default:
                return SpotifyError(fallback, message)
            }
        }

        return SpotifyError(fallback, message)
    }
}

// MARK: - Player state mapping

/// Maps `SPTAppRemotePlaybackOptionsRepeatMode` onto the JS `RepeatMode` union.
func repeatModeToJS(_ mode: SPTAppRemotePlaybackOptionsRepeatMode) -> String {
    switch mode {
    case .track: return "track"
    case .context: return "context"
    case .off: return "off"
    @unknown default: return "off"
    }
}

/// Parses the JS `RepeatMode` union back into the SDK enum.
func repeatModeFromJS(_ value: String) -> SPTAppRemotePlaybackOptionsRepeatMode? {
    switch value {
    case "off": return .off
    case "track": return .track
    case "context": return .context
    default: return nil
    }
}

/// Maps `SPTAppRemoteTrack` onto the JS `Track` interface.
///
/// The iOS SDK exposes a single `artist` per track (unlike the Web API), so
/// `artists` is always a one-element array.
func trackToJS(_ track: (any SPTAppRemoteTrack)?) -> [String: Any]? {
    guard let track = track else { return nil }

    let artistName = track.artist.name
    let artistUri = track.artist.uri
    var artist: [String: Any] = ["name": artistName]
    if !artistUri.isEmpty {
        artist["uri"] = artistUri
    }

    var result: [String: Any] = [
        "uri": track.uri,
        "name": track.name,
        "artistName": artistName,
        "artists": [artist],
        "albumName": track.album.name,
        "durationMs": Int(track.duration),
        "isEpisode": track.isEpisode,
        "isPodcast": track.isPodcast
    ]

    let albumUri = track.album.uri
    if !albumUri.isEmpty {
        result["albumUri"] = albumUri
    }
    // A raw Spotify image identifier, not an https URL — documented as such in
    // definitions.ts. Fetching the bytes needs SPTAppRemoteImageAPI.
    let imageUri = track.imageIdentifier
    if !imageUri.isEmpty {
        result["imageUri"] = imageUri
    }
    return result
}

/// Maps `SPTAppRemotePlaybackRestrictions` onto the JS `PlaybackRestrictions` interface.
func restrictionsToJS(_ restrictions: any SPTAppRemotePlaybackRestrictions) -> [String: Any] {
    [
        "canSkipNext": restrictions.canSkipNext,
        "canSkipPrevious": restrictions.canSkipPrevious,
        "canSeek": restrictions.canSeek,
        "canToggleShuffle": restrictions.canToggleShuffle,
        "canRepeatTrack": restrictions.canRepeatTrack,
        "canRepeatContext": restrictions.canRepeatContext
    ]
}

/// Maps `SPTAppRemotePlayerState` onto the JS `PlayerState` interface.
func playerStateToJS(_ state: (any SPTAppRemotePlayerState)?) -> [String: Any] {
    guard let state = state else {
        // A defensive shape for "nothing loaded" — keeps the contract total so
        // callers never have to null-check the event payload itself.
        return [
            "track": NSNull(),
            "paused": true,
            "positionMs": 0,
            "playbackSpeed": 1.0,
            "shuffle": false,
            "repeatMode": "off",
            "restrictions": [
                "canSkipNext": false,
                "canSkipPrevious": false,
                "canSeek": false,
                "canToggleShuffle": false,
                "canRepeatTrack": false,
                "canRepeatContext": false
            ],
            "receivedAtMs": nowMs()
        ]
    }

    var result: [String: Any] = [
        "track": trackToJS(state.track) ?? NSNull(),
        "paused": state.isPaused,
        "positionMs": Int(state.playbackPosition),
        "playbackSpeed": Double(state.playbackSpeed),
        "shuffle": state.playbackOptions.isShuffling,
        "repeatMode": repeatModeToJS(state.playbackOptions.repeatMode),
        "restrictions": restrictionsToJS(state.playbackRestrictions),
        "receivedAtMs": nowMs()
    ]

    let contextUri = state.contextURI.absoluteString
    if !contextUri.isEmpty {
        result["contextUri"] = contextUri
    }
    let contextTitle = state.contextTitle
    if !contextTitle.isEmpty {
        result["contextTitle"] = contextTitle
    }
    return result
}

// MARK: - Web API mapping

/// Maps a Web API device object onto the JS `SpotifyDevice` interface.
///
/// Spotify reports `id` as `null` for devices that cannot be targeted, and
/// omits `volume_percent` for devices that do not report a volume.
func deviceToJS(_ raw: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [
        "id": NSNull(),
        "name": raw["name"] as? String ?? "",
        "type": raw["type"] as? String ?? "",
        "isActive": raw["is_active"] as? Bool ?? false,
        "isPrivateSession": raw["is_private_session"] as? Bool ?? false,
        "isRestricted": raw["is_restricted"] as? Bool ?? false
    ]
    if let id = raw["id"] as? String {
        result["id"] = id
    }
    if let volumePercent = raw["volume_percent"] as? Int {
        result["volumePercent"] = volumePercent
    }
    return result
}

/// Epoch milliseconds, the unit every timestamp in `definitions.ts` uses.
func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}

// MARK: - Session

/// The persisted OAuth session. Encoded as a single JSON blob in the keychain.
struct StoredSession: Codable {
    let accessToken: String
    let refreshToken: String?
    /// Epoch milliseconds.
    let expiresAt: Int
    let scopes: [String]?

    /// Treat a token expiring within a minute as already stale so callers never
    /// hand a token to the Web API that dies mid-flight.
    func isValid(leewayMs: Int = 60_000) -> Bool {
        expiresAt - leewayMs > nowMs()
    }

    /// Shape of the JS `AccessToken` interface.
    var asJS: [String: Any] {
        var result: [String: Any] = [
            "accessToken": accessToken,
            "expiresAt": expiresAt,
            "tokenType": "Bearer"
        ]
        if let scopes = scopes {
            result["scopes"] = scopes
        }
        return result
    }
}

// MARK: - Keychain

/// Minimal `kSecClassGenericPassword` wrapper — no third-party dependencies.
enum SessionStore {
    private static let service = "capacitor-spotify"
    private static let account = "session"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func save(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }

        var query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available after first unlock so a background refresh still works,
            // but never synced to iCloud or included in device backups.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { current, _ in current }
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func load() -> StoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
