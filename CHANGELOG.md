# Changelog

## 0.5.0 — 2026-08-20

Error reporting on iOS. Every item here was mis-diagnosed by an integrator
because the plugin said something confidently wrong.

- fix(ios): a `connect()` fallback that cannot start is no longer reported as
  `SPOTIFY_APP_NOT_INSTALLED`. `authorizeAndPlayURI`'s flag means "installed
  **and** an authorization attempt can be made" (`SPTAppRemote.h`), and it
  comes back `NO` for a Spotify app that is installed and running. The refusal
  is now diagnosed: `SPOTIFY_APP_NOT_INSTALLED` only when `canOpenURL`
  ("spotify:") fails — naming the `LSApplicationQueriesSchemes` entry as the
  other possible cause — and otherwise the new **`AUTHORIZE_AND_PLAY_REFUSED`**
  code, which lists the real candidates most-likely-first: the dashboard app
  **owner** holding no active Premium subscription, the account missing from
  User Management on a development-mode app, a missing `spotify-action` scheme,
  a logged-out Spotify app, an unregistered redirect URI.
- New **`diagnoseAccess()`** on all three platforms: probes `GET /v1/me` (no
  scope or tier gate) and reports Spotify's own verdict — `ok`, the plugin
  `code`, `httpStatus`, Spotify's verbatim `spotifyMessage`, and a plain-words
  `message` that names the owner-subscription case its own text hides. **Never
  rejects**, so it is safe to call straight from a `catch` block; "not
  initialized" and "no session" come back as diagnoses too. This turns the
  investigation above into one line.
- fix(ios): `didFailConnectionAttemptWithError` no longer discards `error`. It
  is logged, and it is carried into the eventual rejection message and into
  `connectionStateChanged`'s new `error.cause` — so the JS side sees
  `com.spotify.app-remote.transport Code=-2000 "Stream error."` instead of only
  the fallback's verdict.
- `initialize({ debug: true })` (iOS): raises the `SPTAppRemote` log level to
  `debug` and logs the plugin's connect trail under the
  `com.jacquesbeets.capacitor-spotify` subsystem. The SDK log level was
  hard-coded to `none`; it now defaults to `error`, and connection failures are
  logged whether or not `debug` is on.
- docs: `LSApplicationQueriesSchemes` must declare **both** `spotify` and
  `spotify-action` — the SDK opens
  `spotify-action://authorize?response_type=token` for `authorizeAndPlayURI`,
  and iOS refuses undeclared schemes. Troubleshooting gained the
  `AUTHORIZE_AND_PLAY_REFUSED` checklist and the two app-level `403`s that
  produce it — the owner's lapsed Premium subscription (`"Active premium
  subscription required for the owner of the app"`) and development-mode user
  registration (`"the user may not be registered"`, which non-owner accounts
  also receive for the owner-subscription case, pointing at the wrong setting).
  Both leave PKCE authorization succeeding, so a token is not evidence of
  access; `GET /v1/me` is the discriminator.

## 0.4.1 — 2026-08-11

- fix(ios): podspec renamed `CapacitorSpotify.podspec` →
  `JacquesbeetsCapacitorSpotify.podspec` (with matching `s.name`). The
  Capacitor CLI pascal-cases the npm package name into the consumer Podfile,
  so **CocoaPods apps could not install 0.3.0 or 0.4.0** ("No podspec found
  for `JacquesbeetsCapacitorSpotify`") — 0.4.0's changelog wrongly claimed
  CocoaPods was unaffected. Same root cause as 0.4.0's SPM product rename.

## 0.4.0 — 2026-08-11

- **Capacitor 7 support** (alongside 8): peer dependency widened to
  `@capacitor/core >=7.0.0`, capacitor-swift-pm accepted as `7.0.0..<9.0.0`,
  AGP classpath lowered to 8.7.2, `androidx.core-ktx` fallback lowered to
  1.16.0 (1.17.0 needs compileSdk 36), iOS deployment floor lowered to 14.0
  (SPM + podspec). Verified against a Capacitor 7.6.8 app on both platforms.
- fix(ios): SPM package/product renamed `CapacitorSpotify` →
  `JacquesbeetsCapacitorSpotify` to match the scoped npm name. **0.3.0 does
  not resolve in SPM-based apps** — the Capacitor CLI derives the product
  name from the npm package name. (CocoaPods has the same issue via the
  podspec name; that half was missed here and fixed in 0.4.1.)

## 0.3.0 — 2026-08-07

- New `getUserCapabilities()` — detect Free-tier accounts (`canPlayOnDemand`)
  before playback fails. iOS/Android read it from the Spotify app; web infers
  it from a connected player (the Web Playback SDK requires Premium).
- New Web API-backed player helpers on all platforms: `addToQueue({uri})`,
  `getDevices()`, `transferPlayback({deviceId, play?})` — native platforms get
  their own authenticated HTTP clients with the same error mapping as web.
- fix(android): numeric plugin-call options (`positionMs`, `volume`) are now
  coerced through `Number` — `PluginCall.getLong()` dropped 32-bit values.

## 0.2.0 — 2026-08-07

- New `getImage({ imageId, width? })` — album art as a directly renderable
  value: base64 `data:` URI on iOS/Android (fetched through the Spotify app's
  ImagesApi, works with its cache), CDN URL on web. Pass
  `track.imageUri` from any player state.
- fix(web): always request `user-read-email` + `user-read-private` on web —
  the Web Playback SDK rejects tokens without them ("Invalid token scopes").

## 0.1.0 — 2026-08-06

Initial release.

- Unified TypeScript API (`Spotify` plugin): `initialize`, `authorize`,
  `getAccessToken`, `logout`, `isSpotifyAppInstalled`, `getCapabilities`,
  `connect`, `disconnect`, `isConnected`, `play`, `pause`, `resume`,
  `togglePlay`, `skipNext`, `skipPrevious`, `seekTo`, `setShuffle`,
  `setRepeatMode`, `setVolume`, `getVolume`, `getPlayerState`; events
  `playerStateChanged`, `connectionStateChanged`, `authStateChanged`;
  stable error codes on every rejection.
- **iOS**: Spotify iOS SDK 5.0.1 (App Remote + `SPTSessionManager` PKCE auth),
  Keychain token storage, background disconnect / foreground reconnect,
  `authorizeAndPlayURI` wake fallback. Vendored xcframework for CocoaPods,
  official SPM package pin for SPM apps.
- **Android** (Kotlin): App Remote 0.8.0 (vendored AAR via bundled local Maven
  repo) + `com.spotify.android:auth` 5.0.0 with Authorization Code + PKCE and
  plugin-side token exchange/refresh; lifecycle-aware connection handling.
- **Web**: Web Playback SDK wrapper (Connect device, live state events),
  full PKCE auth with automatic refresh, minimal Web API bridge for
  play-by-URI / transfer / shuffle / repeat, DRM viability probe.
- Example app under `example-app/` for manual end-to-end testing.
