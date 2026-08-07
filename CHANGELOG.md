# Changelog

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
