# capacitor-spotify example app

Manual test harness for the plugin: authorize, connect, play a URI, and watch
live player-state events.

## Setup

1. Create a Spotify app at https://developer.spotify.com/dashboard (see the
   plugin README for the full walkthrough — redirect URIs, package name +
   SHA-1, bundle ID, user allowlist).
2. Edit `src/js/config.js` with your `CLIENT_ID` and `REDIRECT_URI`.
   - The native platforms are preconfigured for the redirect URI
     `capacitor-spotify-example://callback` (Android manifest intent-filter,
     iOS `CFBundleURLTypes`). Register that exact URI in the dashboard, or
     change it consistently in all three places.
   - For web, register `http://127.0.0.1:5173/` too.
3. `npm install`

## Run

```bash
# Web (real browser only — the Web Playback SDK needs DRM; requires Premium)
npm start   # then open http://127.0.0.1:5173/ (NOT localhost)

# Native (needs the Spotify app installed on the device)
npm run build
npx cap sync
npx cap open ios       # or: npx cap open android
```
