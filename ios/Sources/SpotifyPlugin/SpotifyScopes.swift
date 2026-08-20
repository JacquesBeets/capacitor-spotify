import Foundation
import SpotifyiOS

/// Resolved `initialize()` options. `Equatable` so `initialize()` can stay
/// idempotent without tearing down a live connection.
struct SpotifyConfig: Equatable {
    let clientId: String
    let redirectUrl: URL
    let scopes: [String]
    let tokenSwapUrl: URL?
    let tokenRefreshUrl: URL?
    /// Verbose diagnostics: raises the `SPTAppRemote` log level to `.debug` and
    /// turns on the plugin's own connect trail.
    let debug: Bool

    /// Matches the documented default in `src/definitions.ts`.
    static let defaultScopes = [
        "app-remote-control",
        "streaming",
        "user-modify-playback-state",
        "user-read-playback-state",
        "user-read-currently-playing"
    ]
}

/// Translates between Spotify's OAuth scope strings — what `definitions.ts`
/// exposes — and the `SPTScope` bitmask the iOS SDK wants.
enum SpotifyScopes {
    private static let map: [String: SPTScope] = [
        "playlist-read-private": .playlistReadPrivate,
        "playlist-read-collaborative": .playlistReadCollaborative,
        "playlist-modify-public": .playlistModifyPublic,
        "playlist-modify-private": .playlistModifyPrivate,
        "user-follow-read": .userFollowRead,
        "user-follow-modify": .userFollowModify,
        "user-library-read": .userLibraryRead,
        "user-library-modify": .userLibraryModify,
        "user-read-birthdate": .userReadBirthDate,
        "user-read-email": .userReadEmail,
        "user-read-private": .userReadPrivate,
        "user-top-read": .userTopRead,
        "ugc-image-upload": .ugcImageUpload,
        "streaming": .streaming,
        "app-remote-control": .appRemoteControl,
        "user-read-playback-state": .userReadPlaybackState,
        "user-modify-playback-state": .userModifyPlaybackState,
        "user-read-currently-playing": .userReadCurrentlyPlaying,
        "user-read-recently-played": .userReadRecentlyPlayed,
        "openid": .openid
    ]

    /// Splits requested scopes into the `SPTScope` bitmask plus anything the
    /// enum cannot represent — Spotify adds scopes faster than the SDK does.
    static func parse(_ scopes: [String]) -> (SPTScope, [String]) {
        var mask: SPTScope = []
        var unmapped: [String] = []
        for scope in scopes {
            if let known = map[scope] {
                mask.insert(known)
            } else {
                unmapped.append(scope)
            }
        }
        return (mask, unmapped)
    }

    /// The granted scopes of a session, as the strings JS expects. Nil rather
    /// than `[]` so `AccessToken.scopes` is simply absent when unknown.
    static func strings(_ scope: SPTScope) -> [String]? {
        let strings = map
            .filter { scope.contains($0.value) }
            .keys
            .sorted()
        return strings.isEmpty ? nil : strings
    }
}
