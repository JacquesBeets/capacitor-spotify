import Foundation
import SpotifyiOS
import UIKit

/// Owns the OAuth session: interactive authorization via `SPTSessionManager`,
/// keychain persistence, and access-token refresh.
///
/// Every method must be called on the main thread — the Spotify SDK is not
/// thread safe. `Spotify` (the facade) is responsible for the hop.
final class SpotifyAuthManager: NSObject, SPTSessionManagerDelegate {
    typealias TokenCompletion = (Result<StoredSession, SpotifyError>) -> Void

    /// Emits the JS `AuthStateChange` payload.
    var onAuthStateChanged: (([String: Any]) -> Void)?

    private let config: SpotifyConfig
    private let configuration: SPTConfiguration
    private lazy var sessionManager = SPTSessionManager(configuration: configuration, delegate: self)

    private var pendingAuthorize: [TokenCompletion] = []
    private var pendingRefresh: [TokenCompletion] = []
    private let refresher: SpotifyTokenRefresher

    /// True once an in-flight `authorize()` has app-switched us to Spotify.
    /// `ASWebAuthenticationSession` never backgrounds the app, so this only
    /// arms for the app-switch flow — the one that can silently never return.
    private var leftAppDuringAuthorize = false
    private var authorizeWatchdog: DispatchWorkItem?
    /// Grace period after returning to the foreground for the redirect (and its
    /// PKCE token exchange) to land before we call the grant abandoned.
    private static let authorizeWatchdogSeconds: TimeInterval = 3

    init(config: SpotifyConfig, configuration: SPTConfiguration, urlSession: URLSession = .shared) {
        self.config = config
        self.configuration = configuration
        self.refresher = SpotifyTokenRefresher(
            clientId: config.clientId,
            endpointOverride: config.tokenRefreshUrl,
            urlSession: urlSession
        )
        super.init()
        observeAppLifecycle()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - State

    /// The persisted session, whether or not its access token is still fresh.
    var storedSession: StoredSession? { SessionStore.load() }

    /// A token good for at least another minute, or nil.
    var usableAccessToken: String? {
        guard let session = storedSession, session.isValid() else { return nil }
        return session.accessToken
    }

    // MARK: - Authorization

    func authorize(scopes requested: [String]?, completion: @escaping TokenCompletion) {
        pendingAuthorize.append(completion)
        // A second authorize() while one is in flight just joins the queue.
        guard pendingAuthorize.count == 1 else { return }

        leftAppDuringAuthorize = false
        let scopeStrings = requested?.isEmpty == false ? requested ?? config.scopes : config.scopes
        let (scope, unmapped) = SpotifyScopes.parse(scopeStrings)

        if unmapped.isEmpty {
            sessionManager.initiateSession(with: scope, options: .default, campaign: nil)
        } else {
            // SPTScope cannot express every scope Spotify offers; fall back to
            // the raw-string entry point so custom scopes survive.
            sessionManager.initiateSession(withRawScope: scopeStrings.joined(separator: " "), options: .default, campaign: nil)
        }
    }

    func logout() {
        SessionStore.clear()
        sessionManager.session = nil
        emitAuthState()
    }

    /// Forwards an OAuth redirect to `SPTSessionManager`.
    ///
    /// The App Remote `authorizeAndPlayURI` callback uses the same redirect URI
    /// but a different payload, so `SpotifyRemoteManager` gets first refusal.
    func handleRedirectURL(_ url: URL) -> Bool {
        let handled = sessionManager.application(UIApplication.shared, open: url, options: [:])
        if handled {
            // The redirect proves the grant is still alive, even if the token
            // exchange behind it takes another moment.
            cancelAuthorizeWatchdog()
        }
        return handled
    }

    // MARK: - Abandoned-grant detection

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func appDidEnterBackground() {
        if !pendingAuthorize.isEmpty {
            leftAppDuringAuthorize = true
        }
    }

    /// The user switched to Spotify to approve the grant and came back. If no
    /// redirect follows, they backed out — otherwise the `authorize()` promise
    /// would hang forever. A later redirect still persists the session and
    /// emits `authStateChanged`, so a false negative here is recoverable.
    @objc private func appDidBecomeActive() {
        guard leftAppDuringAuthorize, !pendingAuthorize.isEmpty else { return }
        leftAppDuringAuthorize = false

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.pendingAuthorize.isEmpty else { return }
            self.resolvePendingAuthorize(.failure(SpotifyError(
                .authCancelled,
                "Spotify authorization was cancelled"
            )))
        }
        authorizeWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.authorizeWatchdogSeconds, execute: work)
    }

    private func cancelAuthorizeWatchdog() {
        authorizeWatchdog?.cancel()
        authorizeWatchdog = nil
        leftAppDuringAuthorize = false
    }

    /// Stores the access token handed back by `authorizeAndPlayURI`.
    ///
    /// That flow yields no refresh token and no expiry, so we assume Spotify's
    /// standard one-hour lifetime and keep any scopes we already knew about.
    func storeAppRemoteToken(_ accessToken: String) {
        let session = StoredSession(
            accessToken: accessToken,
            refreshToken: storedSession?.refreshToken,
            expiresAt: nowMs() + 3_600_000,
            scopes: storedSession?.scopes ?? config.scopes
        )
        SessionStore.save(session)
        emitAuthState()
        resolvePendingAuthorize(.success(session))
    }

    /// Fails any in-flight `authorize()` — used when a redirect carries an error.
    func failPendingAuthorize(_ error: SpotifyError) {
        resolvePendingAuthorize(.failure(error))
    }

    // MARK: - Access tokens

    func getAccessToken(forceRefresh: Bool, completion: @escaping TokenCompletion) {
        guard let session = storedSession else {
            completion(.failure(SpotifyError(.notAuthenticated, "No Spotify session — call authorize() first")))
            return
        }

        if !forceRefresh, session.isValid() {
            completion(.success(session))
            return
        }

        guard let refreshToken = session.refreshToken else {
            // App-Remote-only tokens cannot be refreshed. A still-valid one is
            // fine to hand back even under forceRefresh; a dead one is not.
            if session.isValid() {
                completion(.success(session))
            } else {
                SessionStore.clear()
                emitAuthState()
                completion(.failure(SpotifyError(.notAuthenticated, "Session expired and no refresh token is available")))
            }
            return
        }

        pendingRefresh.append(completion)
        guard pendingRefresh.count == 1 else { return }
        performRefresh(refreshToken: refreshToken, previous: session)
    }

    private func performRefresh(refreshToken: String, previous: StoredSession) {
        refresher.refresh(refreshToken: refreshToken, previous: previous) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let session):
                SessionStore.save(session)
            case .failure:
                // A refresh token Spotify rejects will never work again; drop
                // the session so the app is pushed back through authorize().
                SessionStore.clear()
            }
            self.emitAuthState()

            let completions = self.pendingRefresh
            self.pendingRefresh.removeAll()
            completions.forEach { $0(result) }
        }
    }

    private func resolvePendingAuthorize(_ result: Result<StoredSession, SpotifyError>) {
        cancelAuthorizeWatchdog()
        let completions = pendingAuthorize
        pendingAuthorize.removeAll()
        completions.forEach { $0(result) }
    }

    private func emitAuthState() {
        let session = storedSession
        var payload: [String: Any] = ["authenticated": session != nil]
        if let session = session {
            payload["expiresAt"] = session.expiresAt
        }
        onAuthStateChanged?(payload)
    }

    // MARK: - SPTSessionManagerDelegate

    func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        let stored = Self.storedSession(from: session)
        SessionStore.save(stored)
        emitAuthState()
        resolvePendingAuthorize(.success(stored))
    }

    func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        SessionStore.save(Self.storedSession(from: session))
        emitAuthState()
    }

    func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        resolvePendingAuthorize(.failure(Self.authError(from: error)))
    }

    // MARK: - Helpers

    /// `ASWebAuthenticationSession` reports a user-dismissed sheet as
    /// `canceledLogin`; the Spotify app reports a declined grant as
    /// `access_denied`. Both are cancellations, not failures.
    private static func authError(from error: Error) -> SpotifyError {
        let nsError = error as NSError
        let cancelled = nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1
            || nsError.code == NSUserCancelledError
        return cancelled
            ? SpotifyError(.authCancelled, "Spotify authorization was cancelled")
            : authError(fromDescription: nsError.localizedDescription)
    }

    /// Classifies an OAuth error string — as delivered in a redirect URL or in
    /// an `NSError`'s description — as a cancellation or a real failure.
    static func authError(fromDescription description: String) -> SpotifyError {
        let cancelled = description.localizedCaseInsensitiveContains("access_denied")
            || description.localizedCaseInsensitiveContains("cancel")
        return cancelled
            ? SpotifyError(.authCancelled, "Spotify authorization was cancelled")
            : SpotifyError(.authFailed, "Spotify authorization failed: \(description)")
    }

    private static func storedSession(from session: SPTSession) -> StoredSession {
        StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken.isEmpty ? nil : session.refreshToken,
            expiresAt: Int(session.expirationDate.timeIntervalSince1970 * 1000),
            scopes: SpotifyScopes.strings(session.scope)
        )
    }
}
