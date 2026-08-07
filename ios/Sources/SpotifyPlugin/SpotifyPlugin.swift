import Capacitor
import Foundation

/// Capacitor bridge for the Spotify plugin.
///
/// Mirrors the `SpotifyPlugin` interface in `src/definitions.ts` one-to-one; all
/// real work lives in `Spotify` and the two managers behind it.
@objc(SpotifyPlugin)
public class SpotifyPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SpotifyPlugin"
    public let jsName = "Spotify"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "initialize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "authorize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAccessToken", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "logout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isSpotifyAppInstalled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getCapabilities", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isConnected", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "togglePlay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "skipNext", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "skipPrevious", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seekTo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setShuffle", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setRepeatMode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPlayerState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getImage", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getUserCapabilities", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "addToQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDevices", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "transferPlayback", returnType: CAPPluginReturnPromise)
    ]

    private let implementation = Spotify()

    override public func load() {
        implementation.onPlayerStateChanged = { [weak self] data in
            self?.notifyListeners("playerStateChanged", data: data)
        }
        implementation.onConnectionStateChanged = { [weak self] data in
            self?.notifyListeners("connectionStateChanged", data: data)
        }
        implementation.onAuthStateChanged = { [weak self] data in
            self?.notifyListeners("authStateChanged", data: data)
        }

        // OAuth and App Remote both come back through the app's custom scheme;
        // universal links are observed too in case the redirect URI is https.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleOpenURL(_:)), name: .capacitorOpenURL, object: nil)
        center.addObserver(self, selector: #selector(handleOpenURL(_:)), name: .capacitorOpenUniversalLink, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleOpenURL(_ notification: Notification) {
        guard let object = notification.object as? [String: Any],
              let url = object["url"] as? URL else {
            return
        }
        implementation.handleRedirectURL(url)
    }

    // MARK: - Lifecycle

    @objc func initialize(_ call: CAPPluginCall) {
        guard let clientId = call.getString("clientId"), !clientId.isEmpty else {
            call.reject("clientId is required", SpotifyErrorCode.notInitialized.rawValue)
            return
        }
        guard let redirectUri = call.getString("redirectUri"),
              let redirectUrl = URL(string: redirectUri) else {
            call.reject("A valid redirectUri is required", SpotifyErrorCode.notInitialized.rawValue)
            return
        }

        let requested = (call.getArray("scopes", String.self) ?? []).filter { !$0.isEmpty }
        let config = SpotifyConfig(
            clientId: clientId,
            redirectUrl: redirectUrl,
            scopes: requested.isEmpty ? SpotifyConfig.defaultScopes : requested,
            tokenSwapUrl: call.getString("tokenSwapUrl").flatMap { URL(string: $0) },
            tokenRefreshUrl: call.getString("tokenRefreshUrl").flatMap { URL(string: $0) }
        )
        implementation.initialize(config) { self.settle(call, $0) }
    }

    @objc func getCapabilities(_ call: CAPPluginCall) {
        call.resolve(Spotify.capabilities)
    }

    // MARK: - Auth

    @objc func authorize(_ call: CAPPluginCall) {
        implementation.authorize(scopes: call.getArray("scopes", String.self)) { self.settle(call, $0) }
    }

    @objc func getAccessToken(_ call: CAPPluginCall) {
        implementation.getAccessToken(forceRefresh: call.getBool("forceRefresh", false)) { self.settle(call, $0) }
    }

    @objc func logout(_ call: CAPPluginCall) {
        implementation.logout { self.settle(call, $0) }
    }

    @objc func isSpotifyAppInstalled(_ call: CAPPluginCall) {
        implementation.isSpotifyAppInstalled { self.settle(call, $0) }
    }

    // MARK: - Connection

    @objc func connect(_ call: CAPPluginCall) {
        implementation.connect(playUri: call.getString("playUri")) { self.settle(call, $0) }
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        implementation.disconnect { self.settle(call, $0) }
    }

    @objc func isConnected(_ call: CAPPluginCall) {
        implementation.isConnected { self.settle(call, $0) }
    }

    // MARK: - Playback

    @objc func play(_ call: CAPPluginCall) {
        implementation.play(uri: call.getString("uri")) { self.settle(call, $0) }
    }

    @objc func pause(_ call: CAPPluginCall) {
        implementation.pause { self.settle(call, $0) }
    }

    @objc func resume(_ call: CAPPluginCall) {
        implementation.resume { self.settle(call, $0) }
    }

    @objc func togglePlay(_ call: CAPPluginCall) {
        implementation.togglePlay { self.settle(call, $0) }
    }

    @objc func skipNext(_ call: CAPPluginCall) {
        implementation.skipNext { self.settle(call, $0) }
    }

    @objc func skipPrevious(_ call: CAPPluginCall) {
        implementation.skipPrevious { self.settle(call, $0) }
    }

    @objc func seekTo(_ call: CAPPluginCall) {
        guard let positionMs = call.getInt("positionMs") else {
            call.reject("positionMs is required", SpotifyErrorCode.playbackFailed.rawValue)
            return
        }
        implementation.seekTo(positionMs: positionMs) { self.settle(call, $0) }
    }

    @objc func setShuffle(_ call: CAPPluginCall) {
        guard let enabled = call.getBool("enabled") else {
            call.reject("enabled is required", SpotifyErrorCode.playbackFailed.rawValue)
            return
        }
        implementation.setShuffle(enabled: enabled) { self.settle(call, $0) }
    }

    @objc func setRepeatMode(_ call: CAPPluginCall) {
        guard let mode = call.getString("repeatMode") else {
            call.reject("repeatMode is required", SpotifyErrorCode.playbackFailed.rawValue)
            return
        }
        implementation.setRepeatMode(mode) { self.settle(call, $0) }
    }

    @objc func getPlayerState(_ call: CAPPluginCall) {
        implementation.getPlayerState { self.settle(call, $0) }
    }

    @objc func getImage(_ call: CAPPluginCall) {
        guard let imageId = call.getString("imageId"), !imageId.isEmpty else {
            call.reject("getImage() requires an imageId.", SpotifyErrorCode.unknown.rawValue)
            return
        }
        implementation.getImage(imageId: imageId, width: call.getInt("width") ?? 480) { self.settle(call, $0) }
    }

    @objc func getUserCapabilities(_ call: CAPPluginCall) {
        implementation.getUserCapabilities { self.settle(call, $0) }
    }

    // MARK: - Web API

    @objc func addToQueue(_ call: CAPPluginCall) {
        guard let uri = call.getString("uri"), !uri.isEmpty else {
            call.reject("addToQueue() requires a uri.", SpotifyErrorCode.unknown.rawValue)
            return
        }
        implementation.addToQueue(uri: uri) { self.settle(call, $0) }
    }

    @objc func getDevices(_ call: CAPPluginCall) {
        implementation.getDevices { self.settle(call, $0) }
    }

    @objc func transferPlayback(_ call: CAPPluginCall) {
        guard let deviceId = call.getString("deviceId"), !deviceId.isEmpty else {
            call.reject("transferPlayback() requires a deviceId.", SpotifyErrorCode.unknown.rawValue)
            return
        }
        implementation.transferPlayback(deviceId: deviceId, play: call.getBool("play", false)) { self.settle(call, $0) }
    }

    // MARK: - Unsupported on iOS

    @objc func setVolume(_ call: CAPPluginCall) {
        implementation.setVolume { self.settle(call, $0) }
    }

    @objc func getVolume(_ call: CAPPluginCall) {
        implementation.getVolume { self.settle(call, $0) }
    }

    // MARK: - Plumbing

    private func settle(_ call: CAPPluginCall, _ result: Result<Void, SpotifyError>) {
        switch result {
        case .success:
            call.resolve()
        case .failure(let error):
            call.reject(error.message, error.code.rawValue)
        }
    }

    private func settle(_ call: CAPPluginCall, _ result: Result<[String: Any], SpotifyError>) {
        switch result {
        case .success(let data):
            call.resolve(data)
        case .failure(let error):
            call.reject(error.message, error.code.rawValue)
        }
    }
}
