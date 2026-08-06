# Changelog

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
