import Foundation
import SpotifyiOS

/// Platform-agnostic facade over the Spotify iOS SDK.
///
/// `SpotifyPlugin` is a thin Capacitor bridge on top of this type. Everything
/// here funnels onto the main thread before touching the SDK, which is not
/// thread safe, and rejects with `NOT_INITIALIZED` until `initialize()` runs.
@objc public class Spotify: NSObject {
    typealias VoidResult = (Result<Void, SpotifyError>) -> Void
    typealias DataResult = (Result<[String: Any], SpotifyError>) -> Void

    /// Emits the JS `PlayerState` payload for `playerStateChanged`.
    var onPlayerStateChanged: (([String: Any]) -> Void)?
    /// Emits the JS `ConnectionStateChange` payload for `connectionStateChanged`.
    var onConnectionStateChanged: (([String: Any]) -> Void)?
    /// Emits the JS `AuthStateChange` payload for `authStateChanged`.
    var onAuthStateChanged: (([String: Any]) -> Void)?

    private var config: SpotifyConfig?
    private var auth: SpotifyAuthManager?
    private var remote: SpotifyRemoteManager?

    /// What this platform can do — mirrors the JS `SpotifyCapabilities`.
    static let capabilities: [String: Any] = [
        "platform": "ios",
        "requiresSpotifyApp": true,
        "requiresPremium": false,
        // The Spotify iOS SDK exposes no volume API at all.
        "canSetVolume": false,
        "canGetVolume": false,
        "webPlaybackViable": false
    ]

    // MARK: - Lifecycle

    /// Idempotent: re-initializing with identical options is a no-op, so an app
    /// can safely call it on every startup path.
    func initialize(_ newConfig: SpotifyConfig, completion: @escaping VoidResult) {
        onMain {
            if newConfig == self.config, self.auth != nil {
                completion(.success(()))
                return
            }

            self.remote?.disconnect()

            let configuration = SPTConfiguration(clientID: newConfig.clientId, redirectURL: newConfig.redirectUrl)
            configuration.tokenSwapURL = newConfig.tokenSwapUrl
            configuration.tokenRefreshURL = newConfig.tokenRefreshUrl

            let auth = SpotifyAuthManager(config: newConfig, configuration: configuration)
            auth.onAuthStateChanged = { [weak self] payload in self?.onAuthStateChanged?(payload) }

            let remote = SpotifyRemoteManager(configuration: configuration, auth: auth)
            remote.onConnectionStateChanged = { [weak self] payload in self?.onConnectionStateChanged?(payload) }
            remote.onPlayerStateChanged = { [weak self] payload in self?.onPlayerStateChanged?(payload) }

            self.config = newConfig
            self.auth = auth
            self.remote = remote
            completion(.success(()))
        }
    }

    /// Routes an incoming URL to whichever flow is waiting for it.
    /// Returns true when the URL was ours.
    @discardableResult
    func handleRedirectURL(_ url: URL) -> Bool {
        guard let auth = auth, let remote = remote else { return false }
        // The App Remote callback and the OAuth callback share a redirect URI;
        // App Remote gets first refusal so SPTSessionManager never sees a URL
        // with no authorization code in it.
        if remote.handleAuthorizationCallback(url) { return true }
        return auth.handleRedirectURL(url)
    }

    // MARK: - Auth

    func authorize(scopes: [String]?, completion: @escaping DataResult) {
        withAuth(completion) { auth in
            auth.authorize(scopes: scopes) { result in
                completion(result.map { $0.asJS })
            }
        }
    }

    func getAccessToken(forceRefresh: Bool, completion: @escaping DataResult) {
        withAuth(completion) { auth in
            auth.getAccessToken(forceRefresh: forceRefresh) { result in
                completion(result.map { $0.asJS })
            }
        }
    }

    func logout(completion: @escaping VoidResult) {
        withAuth(completion) { auth in
            self.remote?.disconnect()
            auth.logout()
            completion(.success(()))
        }
    }

    func isSpotifyAppInstalled(completion: @escaping DataResult) {
        withRemote(completion) { remote in
            completion(.success(["installed": remote.isSpotifyAppInstalled]))
        }
    }

    // MARK: - Connection

    func connect(playUri: String?, completion: @escaping VoidResult) {
        withRemote(completion) { remote in
            remote.connect(playUri: playUri, completion: completion)
        }
    }

    func disconnect(completion: @escaping VoidResult) {
        withRemote(completion) { remote in
            remote.disconnect()
            completion(.success(()))
        }
    }

    func isConnected(completion: @escaping DataResult) {
        withRemote(completion) { remote in
            completion(.success(["connected": remote.isConnected]))
        }
    }

    // MARK: - Playback

    func play(uri: String?, completion: @escaping VoidResult) {
        withRemote(completion) { $0.play(uri: uri, completion: completion) }
    }

    func pause(completion: @escaping VoidResult) {
        withRemote(completion) { $0.pause(completion: completion) }
    }

    func resume(completion: @escaping VoidResult) {
        withRemote(completion) { $0.resume(completion: completion) }
    }

    func togglePlay(completion: @escaping VoidResult) {
        withRemote(completion) { $0.togglePlay(completion: completion) }
    }

    func skipNext(completion: @escaping VoidResult) {
        withRemote(completion) { $0.skipNext(completion: completion) }
    }

    func skipPrevious(completion: @escaping VoidResult) {
        withRemote(completion) { $0.skipPrevious(completion: completion) }
    }

    func seekTo(positionMs: Int, completion: @escaping VoidResult) {
        withRemote(completion) { $0.seek(toPositionMs: positionMs, completion: completion) }
    }

    func setShuffle(enabled: Bool, completion: @escaping VoidResult) {
        withRemote(completion) { $0.setShuffle(enabled, completion: completion) }
    }

    func setRepeatMode(_ mode: String, completion: @escaping VoidResult) {
        withRemote(completion) { remote in
            guard let parsed = repeatModeFromJS(mode) else {
                completion(.failure(SpotifyError(.notSupported, "Unknown repeat mode '\(mode)' — expected off, track or context")))
                return
            }
            remote.setRepeatMode(parsed, completion: completion)
        }
    }

    func getPlayerState(completion: @escaping DataResult) {
        withRemote(completion) { $0.getPlayerState(completion: completion) }
    }

    func getImage(imageId: String, width: Int, completion: @escaping DataResult) {
        withRemote(completion) { $0.getImage(imageId: imageId, widthPx: width, completion: completion) }
    }

    // MARK: - Unsupported on iOS

    func setVolume(completion: @escaping VoidResult) {
        completion(.failure(Self.volumeUnsupported))
    }

    func getVolume(completion: @escaping DataResult) {
        completion(.failure(Self.volumeUnsupported))
    }

    private static let volumeUnsupported = SpotifyError(
        .notSupported,
        "Volume control is not available on iOS — the Spotify iOS SDK exposes no volume API"
    )

    // MARK: - Plumbing

    private static let notInitialized = SpotifyError(
        .notInitialized,
        "Spotify plugin is not initialized — call initialize() first"
    )

    private func withAuth<T>(_ completion: @escaping (Result<T, SpotifyError>) -> Void, _ body: @escaping (SpotifyAuthManager) -> Void) {
        onMain {
            guard let auth = self.auth else {
                completion(.failure(Self.notInitialized))
                return
            }
            body(auth)
        }
    }

    private func withRemote<T>(_ completion: @escaping (Result<T, SpotifyError>) -> Void, _ body: @escaping (SpotifyRemoteManager) -> Void) {
        onMain {
            guard let remote = self.remote else {
                completion(.failure(Self.notInitialized))
                return
            }
            body(remote)
        }
    }

    /// Capacitor delivers plugin calls off the main thread; the Spotify SDK
    /// insists on being called from it.
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
