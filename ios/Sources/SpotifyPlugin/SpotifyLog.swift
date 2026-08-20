import os.log

/// Plugin-side diagnostics, written to the unified system log under the
/// `com.jacquesbeets.capacitor-spotify` subsystem (visible in Console.app and
/// `xcrun devicectl`/`log stream`).
///
/// Failures are always logged: an integrator holding a rejected promise has to
/// be able to find the SDK error behind it, and a promise rejection is a poor
/// place to put a transport dump. `debug` additionally logs the connect
/// play-by-play and is opt-in through `initialize({ debug: true })`, which also
/// raises the Spotify SDK's own `SPTAppRemote` log level.
enum SpotifyLog {
    /// Set from `initialize()`. Main thread only, like the rest of the plugin.
    static var isDebugEnabled = false

    private static let log = OSLog(subsystem: "com.jacquesbeets.capacitor-spotify", category: "spotify")

    static func error(_ message: String) {
        os_log("%{public}@", log: log, type: .error, message)
    }

    static func debug(_ message: String) {
        guard isDebugEnabled else { return }
        // .info rather than .debug so the line survives without a log profile.
        os_log("%{public}@", log: log, type: .info, message)
    }
}
