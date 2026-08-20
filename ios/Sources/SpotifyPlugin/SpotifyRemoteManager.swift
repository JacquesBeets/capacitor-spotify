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
    /// Description of the error the *first* connect attempt failed with, kept
    /// so the eventual rejection can name it. Without this the fallback's
    /// verdict is all the JS side ever sees, and the transport error that
    /// actually explains the failure is lost.
    private var firstAttemptError: String?
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

    init(configuration: SPTConfiguration, auth: SpotifyAuthManager, debug: Bool = false) {
        // `.error` rather than `.none`: the SDK's own diagnostics are the only
        // window into the App Remote handshake. `debug` opens it fully.
        self.appRemote = SPTAppRemote(configuration: configuration, logLevel: debug ? .debug : .error)
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
        firstAttemptError = nil
        startConnectTimeout()

        if let token = auth?.usableAccessToken {
            SpotifyLog.debug("Connecting to the Spotify app with a stored access token")
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
        } else {
            // No token: only `authorizeAndPlayURI` can both authorize us and
            // wake the Spotify app into a connectable state.
            SpotifyLog.debug("No usable access token; going straight to authorizeAndPlayURI")
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
        Self.canOpen("spotify:")
    }

    /// `canOpenURL` is also false for any scheme the host app fails to declare
    /// in `LSApplicationQueriesSchemes`, so a false answer here means "not
    /// installed *or* not declared" — never just "not installed".
    private static func canOpen(_ scheme: String) -> Bool {
        guard let url = URL(string: scheme) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private func beginAuthorizeAndPlay() {
        didFallBackToAuthorizeAndPlay = true
        SpotifyLog.debug("Falling back to authorizeAndPlayURI(\(pendingPlayUri ?? ""))")
        // An empty URI resumes the user's last context, per the SDK docs.
        //
        // The flag is *not* an install check, whatever its old name suggested.
        // SPTAppRemote.h: "YES if the Spotify app is installed and an
        // authorization attempt can be made, otherwise NO. […] not a measure of
        // whether or not authentication succeeded". It comes back NO — in a few
        // milliseconds, with no app switch — for a Spotify app that is both
        // installed and running, so `canAttemptAuthorization` gets diagnosed
        // rather than reported as "not installed".
        appRemote.authorizeAndPlayURI(pendingPlayUri ?? "") { [weak self] canAttemptAuthorization in
            DispatchQueue.main.async {
                guard let self = self, !canAttemptAuthorization else { return }
                let error = self.authorizeAndPlayRefusal()
                SpotifyLog.error("authorizeAndPlayURI refused: \(error.code.rawValue) — \(error.message)")
                self.finishConnect(.failure(error))
            }
        }
    }

    /// Works out *why* `authorizeAndPlayURI` would not even try, instead of
    /// blaming the one cause that is easiest to state.
    private func authorizeAndPlayRefusal() -> SpotifyError {
        if !Self.canOpen("spotify:") {
            return SpotifyError(
                .spotifyAppNotInstalled,
                "Cannot reach the Spotify app: it is not installed, or your Info.plist does not list \"spotify\" "
                    + "under LSApplicationQueriesSchemes. App Remote playback needs both."
            )
        }
        // The SDK opens `spotify-action://authorize?response_type=token` for
        // this flow, and iOS answers canOpenURL with false for every scheme the
        // host app has not declared — so an undeclared scheme is refused here
        // long before Spotify sees the request.
        if !Self.canOpen("spotify-action:") {
            return SpotifyError(
                .authorizeAndPlayRefused,
                "The Spotify app refused to start an authorization attempt: your Info.plist does not list "
                    + "\"spotify-action\" under LSApplicationQueriesSchemes, which the Spotify SDK opens for "
                    + "authorizeAndPlayURI. Declare both \"spotify\" and \"spotify-action\"."
            )
        }
        // Spotify refusing the app itself is by far the likeliest cause here,
        // and it is invisible from this side: both of the Web API's 403s below
        // produce exactly this refusal plus a -2000 transport error, and one of
        // them ("the user may not be registered") names the wrong thing.
        return SpotifyError(
            .authorizeAndPlayRefused,
            "The Spotify app refused to start an authorization attempt (authorizeAndPlayURI returned NO while the "
                + "app is installed and reachable). Likeliest first: the owner of your Spotify dashboard app has no "
                + "active Premium subscription; the account is not in that app's User Management allowlist "
                + "(development mode); no user is logged into the Spotify app; this redirect URI is not registered "
                + "for your client ID. GET /v1/me with your access token returns Spotify's own reason in its 403 body."
        )
    }

    private func startConnectTimeout() {
        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            SpotifyLog.error("Timed out after \(Self.connectTimeoutSeconds)s connecting to the Spotify app")
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

        var result = result
        if case .failure(let error) = result {
            result = .failure(blaming(error))
        }
        firstAttemptError = nil

        let completions = pendingConnect
        pendingConnect.removeAll()
        completions.forEach { $0(result) }
    }

    /// Folds the first attempt's error into `error` — once, whichever of the
    /// event or the rejection reaches for it first.
    private func blaming(_ error: SpotifyError) -> SpotifyError {
        guard let first = firstAttemptError else { return error }
        firstAttemptError = nil
        return error.withUnderlying(first)
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
        SpotifyLog.debug("App Remote connected")
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
        let description = SpotifyError.describe(error) ?? "no error reported"
        SpotifyLog.error("App Remote connection attempt failed: \(description)")

        // Spotify refuses App Remote connections while it is not playing. The
        // documented remedy is authorizeAndPlayURI, which wakes it up.
        if !pendingConnect.isEmpty && !didFallBackToAuthorizeAndPlay {
            // Held on to rather than dropped: whatever the fallback goes on to
            // report, this is the error that explains the failure.
            firstAttemptError = SpotifyError.describe(error)
            beginAuthorizeAndPlay()
            return
        }

        // Blamed before the event goes out, so listeners and the rejected
        // promise tell the same story.
        let mapped = blaming(SpotifyError.from(error, fallback: .connectionFailed, prefix: "Could not connect to the Spotify app"))
        emitConnectionState(connected: false, reason: "error", error: mapped)
        finishConnect(.failure(mapped))
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        if let description = SpotifyError.describe(error) {
            SpotifyLog.error("App Remote disconnected: \(description)")
        } else {
            SpotifyLog.debug("App Remote disconnected")
        }

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
