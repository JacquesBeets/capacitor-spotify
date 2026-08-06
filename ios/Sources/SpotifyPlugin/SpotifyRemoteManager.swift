import Foundation
import SpotifyiOS
import UIKit

/// Owns the `SPTAppRemote` connection to the Spotify app and every playback
/// command issued through it.
///
/// Main thread only — the Spotify SDK is not thread safe and its callbacks come
/// back on the main thread too. `Spotify` (the facade) performs the hop.
final class SpotifyRemoteManager: NSObject, SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    typealias VoidCompletion = (Result<Void, SpotifyError>) -> Void
    typealias StateCompletion = (Result<[String: Any], SpotifyError>) -> Void

    /// Emits the JS `ConnectionStateChange` payload.
    var onConnectionStateChanged: (([String: Any]) -> Void)?
    /// Emits the JS `PlayerState` payload.
    var onPlayerStateChanged: (([String: Any]) -> Void)?

    /// Internal rather than private so `SpotifyRemoteManager+Playback` can
    /// reach it — Swift scopes `private` to the declaring file.
    let appRemote: SPTAppRemote
    private weak var auth: SpotifyAuthManager?

    private var pendingConnect: [VoidCompletion] = []
    private var connectTimeout: DispatchWorkItem?
    private var pendingPlayUri: String?
    /// True once `authorizeAndPlayURI` has been used for the current attempt —
    /// stops us bouncing the user to Spotify twice.
    private var didFallBackToAuthorizeAndPlay = false
    /// Set when we disconnect on our own behalf, so the delegate does not emit a
    /// second, contradictory `connectionStateChanged`.
    private var suppressDisconnectEvent = false
    private var pendingReconnect = false

    /// How long to wait for the App Remote handshake — including the round trip
    /// through the Spotify app for `authorizeAndPlayURI` — before giving up.
    private static let connectTimeoutSeconds: TimeInterval = 30

    var isConnected: Bool { appRemote.isConnected }

    init(configuration: SPTConfiguration, auth: SpotifyAuthManager) {
        self.appRemote = SPTAppRemote(configuration: configuration, logLevel: .none)
        self.auth = auth
        super.init()
        appRemote.delegate = self
        observeAppLifecycle()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Connection

    func connect(playUri: String?, completion: @escaping VoidCompletion) {
        if appRemote.isConnected {
            completion(.success(()))
            return
        }

        pendingConnect.append(completion)
        guard pendingConnect.count == 1 else { return }

        pendingPlayUri = playUri
        didFallBackToAuthorizeAndPlay = false
        startConnectTimeout()

        if let token = auth?.usableAccessToken {
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
        } else {
            // No token: only `authorizeAndPlayURI` can both authorize us and
            // wake the Spotify app into a connectable state.
            beginAuthorizeAndPlay()
        }
    }

    func disconnect() {
        pendingReconnect = false
        guard appRemote.isConnected else { return }
        appRemote.disconnect()
    }

    /// Consumes the `authorizeAndPlayURI` callback URL.
    ///
    /// Returns true when the URL belonged to that flow, in which case it must
    /// *not* also be handed to `SPTSessionManager` (which would read the missing
    /// authorization code as a failure).
    func handleAuthorizationCallback(_ url: URL) -> Bool {
        guard let params = appRemote.authorizationParameters(from: url) else { return false }

        if let token = params[SPTAppRemoteAccessTokenKey] {
            appRemote.connectionParameters.accessToken = token
            auth?.storeAppRemoteToken(token)
            if !pendingConnect.isEmpty {
                appRemote.connect()
            }
            return true
        }

        if let description = params[SPTAppRemoteErrorDescriptionKey] {
            let error = SpotifyAuthManager.authError(fromDescription: description)
            auth?.failPendingAuthorize(error)
            finishConnect(.failure(error))
            return true
        }

        return false
    }

    var isSpotifyAppInstalled: Bool {
        guard let url = URL(string: "spotify:") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private func beginAuthorizeAndPlay() {
        didFallBackToAuthorizeAndPlay = true
        // An empty URI resumes the user's last context, per the SDK docs.
        appRemote.authorizeAndPlayURI(pendingPlayUri ?? "") { [weak self] spotifyInstalled in
            DispatchQueue.main.async {
                guard let self = self, !spotifyInstalled else { return }
                self.finishConnect(.failure(SpotifyError(
                    .spotifyAppNotInstalled,
                    "The Spotify app is not installed — App Remote playback requires it"
                )))
            }
        }
    }

    private func startConnectTimeout() {
        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finishConnect(.failure(SpotifyError(
                .connectionFailed,
                "Timed out connecting to the Spotify app"
            )))
        }
        connectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeoutSeconds, execute: work)
    }

    private func finishConnect(_ result: Result<Void, SpotifyError>) {
        connectTimeout?.cancel()
        connectTimeout = nil
        pendingPlayUri = nil
        didFallBackToAuthorizeAndPlay = false

        let completions = pendingConnect
        pendingConnect.removeAll()
        completions.forEach { $0(result) }
    }

    private func emitConnectionState(connected: Bool, reason: String, error: SpotifyError? = nil) {
        var payload: [String: Any] = ["connected": connected, "reason": reason]
        if let error = error {
            payload["error"] = error.asJS
        }
        onConnectionStateChanged?(payload)
    }

    // MARK: - App lifecycle

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    /// iOS suspends us shortly after backgrounding, which the Spotify app sees
    /// as a dead socket. Disconnect cleanly and remember to come back.
    @objc private func appDidEnterBackground() {
        guard appRemote.isConnected else { return }
        pendingReconnect = true
        suppressDisconnectEvent = true
        appRemote.disconnect()
        emitConnectionState(connected: false, reason: "appBackgrounded")
    }

    @objc private func appWillEnterForeground() {
        guard pendingReconnect else { return }
        pendingReconnect = false
        if let token = auth?.usableAccessToken {
            appRemote.connectionParameters.accessToken = token
        }
        appRemote.connect()
    }

    // MARK: - SPTAppRemoteDelegate

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: { [weak self] result, error in
            guard error == nil else { return }
            // Seed listeners with the state at subscription time; the Spotify
            // app only pushes deltas from here on.
            if let state = result as? (any SPTAppRemotePlayerState) {
                self?.onPlayerStateChanged?(playerStateToJS(state))
            } else {
                self?.emitCurrentPlayerState()
            }
        })
        emitConnectionState(connected: true, reason: "connect")
        finishConnect(.success(()))
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        // Spotify refuses App Remote connections while it is not playing. The
        // documented remedy is authorizeAndPlayURI, which wakes it up.
        if !pendingConnect.isEmpty && !didFallBackToAuthorizeAndPlay {
            beginAuthorizeAndPlay()
            return
        }

        let mapped = SpotifyError.from(error, fallback: .connectionFailed, prefix: "Could not connect to the Spotify app")
        emitConnectionState(connected: false, reason: "error", error: mapped)
        finishConnect(.failure(mapped))
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        if suppressDisconnectEvent {
            suppressDisconnectEvent = false
        } else if let error = error {
            let mapped = SpotifyError.from(error, fallback: .notConnected, prefix: "Disconnected from the Spotify app")
            emitConnectionState(connected: false, reason: "error", error: mapped)
        } else {
            emitConnectionState(connected: false, reason: "disconnect")
        }

        if !pendingConnect.isEmpty {
            finishConnect(.failure(SpotifyError.from(error, fallback: .connectionFailed, prefix: "Disconnected before the connection was ready")))
        }
    }

    // MARK: - SPTAppRemotePlayerStateDelegate

    func playerStateDidChange(_ playerState: any SPTAppRemotePlayerState) {
        onPlayerStateChanged?(playerStateToJS(playerState))
    }

    private func emitCurrentPlayerState() {
        appRemote.playerAPI?.getPlayerState { [weak self] result, error in
            guard error == nil, let state = result as? (any SPTAppRemotePlayerState) else { return }
            self?.onPlayerStateChanged?(playerStateToJS(state))
        }
    }
}
