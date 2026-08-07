# capacitor-spotify

Capacitor 8 plugin for Spotify: one TypeScript API over the **Spotify iOS SDK** (App Remote), the **Spotify Android SDK** (App Remote + auth library), and the **Web Playback SDK**.

- **iOS / Android** — controls playback in the installed Spotify app via App Remote: play/pause/skip/seek/shuffle/repeat, live player-state events, OAuth (PKCE) tokens for your own Web API calls.
- **Web** — streams inside the browser via the Web Playback SDK (your page becomes a Spotify Connect device).

## Platform support

| Feature | iOS | Android | Web |
| --- | :-: | :-: | :-: |
| `authorize()` / `getAccessToken()` (OAuth + PKCE, auto-refresh) | ✅ | ✅ | ✅ |
| `connect()` / `disconnect()` to player | ✅ | ✅ | ✅ |
| `play(uri)` / `pause` / `resume` / `togglePlay` | ✅ | ✅ | ✅ |
| `skipNext` / `skipPrevious` / `seekTo` | ✅ | ✅ | ✅ |
| `setShuffle` / `setRepeatMode` | ✅ | ✅ | ✅ |
| `setVolume` / `getVolume` | ❌ `NOT_SUPPORTED` | ✅ / best-effort | ✅ |
| `getImage` (album art) | ✅ via Spotify app | ✅ via Spotify app | ✅ CDN URL |
| `playerStateChanged` live events | ✅ | ✅ | ✅ |
| Audio plays… | in the Spotify app | in the Spotify app | in your web page |
| Requires Spotify app installed | ✅ | ✅ | — |
| Requires Spotify Premium | for on-demand URI playback | for on-demand URI playback | ✅ always |

## Requirements

- Capacitor 8 (iOS 15+, Android minSdk 24)
- **Your own Spotify app** (client ID) from the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) — see setup below
- iOS/Android: the Spotify app installed on the device, user logged in
- Web: a real browser with DRM (Widevine/FairPlay) support and a Premium account. **The Web Playback SDK does not work inside the Capacitor webview** — the native implementations exist for exactly that reason. Use `getCapabilities().webPlaybackViable` to detect support.

> [!IMPORTANT]
> **Spotify Development Mode limits (since Feb/Mar 2026):** the account owning your Spotify app must hold an active **Premium** subscription, and only **5 users** (allowlisted in *User Management*) can use the app. Higher limits require [extended quota mode](https://developer.spotify.com/documentation/web-api/concepts/quota-modes), which Spotify currently grants only to registered organizations with an active service of ≥250k MAU. This is a Spotify platform policy, not a plugin limitation — plan your product accordingly.

## Install

Until the package is published to npm, install from GitHub:

```bash
npm install https://github.com/JacquesBeets/capacitor-spotify.git
npx cap sync
```

> Installing from a git URL runs the plugin's build (`prepublishOnly`) only when packed. If `dist/` is missing after a git install, run `npm --prefix node_modules/capacitor-spotify run build` once, or install from a packed tarball (`npm pack` in a plugin checkout → `npm install <tarball>`).

Once published to npm it will be:

```bash
npm install capacitor-spotify
npx cap sync
```

## Spotify Developer Dashboard setup

1. Create an app at <https://developer.spotify.com/dashboard> (accept the Developer Terms). Note your **Client ID** — you never need the client secret (the plugin uses PKCE; don't ship the secret in an app).
2. In **Settings → APIs used**, enable **Web API** (and **Web Playback SDK** if you target web).
3. Add **Redirect URIs** (exact match, per platform):
   - Native (iOS/Android): a custom scheme, e.g. `myapp://spotify-callback`. All-lowercase; Spotify recommends App Links / Universal Links for production.
   - Web: an `https://` URL of your app. For local dev use `http://127.0.0.1:<port>/` — **`localhost` is rejected**.
4. Android: register your **package name** and **SHA-1 signing fingerprint** (both debug and release):
   ```bash
   keytool -list -v -alias androiddebugkey -keystore ~/.android/debug.keystore -storepass android | grep SHA1
   ```
5. iOS: register your **bundle ID**.
6. **User Management**: add each test user's Spotify account (max 5 in development mode). Non-allowlisted users get `403` / `USER_NOT_AUTHORIZED`.

## iOS setup

Add to your app's `Info.plist`:

```xml
<!-- Lets the plugin detect + launch the Spotify app -->
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>spotify</string>
</array>

<!-- Your OAuth redirect scheme (the part before ://) -->
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.yourcompany.yourapp</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>myapp</string>
    </array>
  </dict>
</array>
```

Notes:
- The plugin handles the redirect callback itself (via Capacitor's URL-open events) — no AppDelegate changes needed.
- The Spotify iOS SDK requires the Spotify app to be *actively playing* for a plain connect. When it isn't, `connect({ playUri })` falls back to `authorizeAndPlayURI`, which **briefly app-switches to Spotify**, starts playback, and returns. Pass `playUri: ''` to resume the user's last context.
- iOS cannot control the Spotify app's volume — `setVolume()`/`getVolume()` reject with `NOT_SUPPORTED`.

## Android setup

Since `com.spotify.android:auth` 5.0.0 the redirect receiver must be declared in **your app's** `AndroidManifest.xml` (inside `<application>`), with your redirect URI's scheme/host:

```xml
<activity
    android:name="com.spotify.sdk.android.auth.browser.RedirectUriReceiverActivity"
    android:exported="true">
  <intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="myapp" android:host="spotify-callback" />
  </intent-filter>
</activity>
```

Notes:
- The Spotify App Remote AAR is not on Maven Central; this plugin **vendors it** and registers a local Maven repository automatically — no Gradle changes needed in your app. (Exception: see [Troubleshooting](#troubleshooting) if your app uses `FAIL_ON_PROJECT_REPOS`.)
- The plugin's manifest already ships the `<queries>` entry needed to see the Spotify app on Android 11+.

## Web setup

No install steps. At runtime the plugin injects `https://sdk.scdn.co/spotify-player.js` and creates a Spotify Connect device named after `playerName`.

- Works in real desktop/mobile browsers with EME/DRM; **not** in the Capacitor webview.
- `connect()` must be called from a user gesture (click/tap) — browser autoplay policy.
- The user needs **Spotify Premium** (`account_error` → `PREMIUM_REQUIRED` otherwise).

## Usage

```typescript
import { Spotify } from 'capacitor-spotify';

// 1. Initialize once at startup. On web this also completes a pending
//    OAuth redirect, so call it before anything else.
await Spotify.initialize({
  clientId: 'YOUR_CLIENT_ID',
  redirectUri: 'myapp://spotify-callback', // or https://... on web
  playerName: 'My Awesome App',
});

// 2. Authenticate (interactive; PKCE — tokens are stored & refreshed for you)
const token = await Spotify.authorize();

// ...use the token for your own Web API calls whenever you like:
const { accessToken } = await Spotify.getAccessToken();
const me = await fetch('https://api.spotify.com/v1/me', {
  headers: { Authorization: `Bearer ${accessToken}` },
}).then((r) => r.json());

// 3. Listen to events
await Spotify.addListener('playerStateChanged', (state) => {
  console.log(state.paused ? 'paused' : 'playing', state.track?.name);
});
await Spotify.addListener('connectionStateChanged', (ev) => {
  console.log('connected:', ev.connected, ev.reason ?? '');
});

// 4. Connect (from a user gesture!) and play
await Spotify.connect({ playUri: '' });
await Spotify.play({ uri: 'spotify:playlist:37i9dQZF1DXcBWIGoYBM5M' });

// 5. Control playback
await Spotify.pause();
await Spotify.skipNext();
await Spotify.seekTo({ positionMs: 30_000 });
await Spotify.setRepeatMode({ repeatMode: 'context' });

// 6. Inspect state on demand
const state = await Spotify.getPlayerState();
```

Error handling — every rejection carries a stable `code`:

```typescript
try {
  await Spotify.connect();
} catch (err: any) {
  switch (err.code) {
    case 'SPOTIFY_APP_NOT_INSTALLED': /* prompt install */ break;
    case 'PREMIUM_REQUIRED':          /* explain premium */ break;
    case 'NOT_AUTHENTICATED':         await Spotify.authorize(); break;
    default: console.error(err.code, err.message);
  }
}
```

A runnable demo lives in [`example-app/`](./example-app) — bring your own client ID.

## API


<docgen-index>

* [`initialize(...)`](#initialize)
* [`authorize(...)`](#authorize)
* [`getAccessToken(...)`](#getaccesstoken)
* [`logout()`](#logout)
* [`isSpotifyAppInstalled()`](#isspotifyappinstalled)
* [`getCapabilities()`](#getcapabilities)
* [`connect(...)`](#connect)
* [`disconnect()`](#disconnect)
* [`isConnected()`](#isconnected)
* [`play(...)`](#play)
* [`pause()`](#pause)
* [`resume()`](#resume)
* [`togglePlay()`](#toggleplay)
* [`skipNext()`](#skipnext)
* [`skipPrevious()`](#skipprevious)
* [`seekTo(...)`](#seekto)
* [`setShuffle(...)`](#setshuffle)
* [`setRepeatMode(...)`](#setrepeatmode)
* [`setVolume(...)`](#setvolume)
* [`getVolume()`](#getvolume)
* [`getPlayerState()`](#getplayerstate)
* [`getImage(...)`](#getimage)
* [`addListener('playerStateChanged', ...)`](#addlistenerplayerstatechanged-)
* [`addListener('connectionStateChanged', ...)`](#addlistenerconnectionstatechanged-)
* [`addListener('authStateChanged', ...)`](#addlistenerauthstatechanged-)
* [`removeAllListeners()`](#removealllisteners)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>


<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### initialize(...)

```typescript
initialize(options: InitializeOptions) => Promise<void>
```

Configure the plugin. Must be called before any other method. Idempotent.

Web: also completes a pending OAuth redirect — call it on app startup so
a `?code=` callback on the current URL resolves the in-flight
`authorize()` flow.

| Param         | Type                                                            |
| ------------- | --------------------------------------------------------------- |
| **`options`** | <code><a href="#initializeoptions">InitializeOptions</a></code> |

--------------------


### authorize(...)

```typescript
authorize(options?: AuthorizeOptions | undefined) => Promise<AccessToken>
```

Launch interactive Spotify authorization.

iOS: `SPTSessionManager` (app-switch to Spotify, or in-app web auth when
Spotify is not installed). Android: Spotify auth library (SSO via the
Spotify app, Custom Tabs fallback). Web: Authorization Code + PKCE via a
full-page redirect.

All platforms use PKCE — no client secret is involved.

| Param         | Type                                                          |
| ------------- | ------------------------------------------------------------- |
| **`options`** | <code><a href="#authorizeoptions">AuthorizeOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#accesstoken">AccessToken</a>&gt;</code>

--------------------


### getAccessToken(...)

```typescript
getAccessToken(options?: { forceRefresh?: boolean | undefined; } | undefined) => Promise<AccessToken>
```

Get a valid access token, refreshing it internally when it is about to
expire. Rejects with `NOT_AUTHENTICATED` when there is no session.

Use this to call the Spotify Web API from your own code.

| Param         | Type                                     |
| ------------- | ---------------------------------------- |
| **`options`** | <code>{ forceRefresh?: boolean; }</code> |

**Returns:** <code>Promise&lt;<a href="#accesstoken">AccessToken</a>&gt;</code>

--------------------


### logout()

```typescript
logout() => Promise<void>
```

Clear the stored session and disconnect the player if connected.

--------------------


### isSpotifyAppInstalled()

```typescript
isSpotifyAppInstalled() => Promise<{ installed: boolean; }>
```

Whether the Spotify app is installed on this device. Always false on web.

**Returns:** <code>Promise&lt;{ installed: boolean; }&gt;</code>

--------------------


### getCapabilities()

```typescript
getCapabilities() => Promise<SpotifyCapabilities>
```

What this platform supports — see {@link <a href="#spotifycapabilities">SpotifyCapabilities</a>}.

**Returns:** <code>Promise&lt;<a href="#spotifycapabilities">SpotifyCapabilities</a>&gt;</code>

--------------------


### connect(...)

```typescript
connect(options?: ConnectOptions | undefined) => Promise<void>
```

Connect to the player.

iOS/Android: connects to the Spotify app via App Remote and subscribes to
player state. Web: loads the Web Playback SDK and creates the Connect
device — must be called from a user gesture (tap/click).

| Param         | Type                                                      |
| ------------- | --------------------------------------------------------- |
| **`options`** | <code><a href="#connectoptions">ConnectOptions</a></code> |

--------------------


### disconnect()

```typescript
disconnect() => Promise<void>
```

Disconnect from the player. Safe to call when not connected.

--------------------


### isConnected()

```typescript
isConnected() => Promise<{ connected: boolean; }>
```

**Returns:** <code>Promise&lt;{ connected: boolean; }&gt;</code>

--------------------


### play(...)

```typescript
play(options?: PlayOptions | undefined) => Promise<void>
```

Play a Spotify URI, or resume playback when no URI is given.

Web: starting a URI requires this SDK device to be (or become) the active
device; the plugin transfers playback automatically on first play.

| Param         | Type                                                |
| ------------- | --------------------------------------------------- |
| **`options`** | <code><a href="#playoptions">PlayOptions</a></code> |

--------------------


### pause()

```typescript
pause() => Promise<void>
```

--------------------


### resume()

```typescript
resume() => Promise<void>
```

--------------------


### togglePlay()

```typescript
togglePlay() => Promise<void>
```

--------------------


### skipNext()

```typescript
skipNext() => Promise<void>
```

--------------------


### skipPrevious()

```typescript
skipPrevious() => Promise<void>
```

--------------------


### seekTo(...)

```typescript
seekTo(options: { positionMs: number; }) => Promise<void>
```

| Param         | Type                                 |
| ------------- | ------------------------------------ |
| **`options`** | <code>{ positionMs: number; }</code> |

--------------------


### setShuffle(...)

```typescript
setShuffle(options: { enabled: boolean; }) => Promise<void>
```

| Param         | Type                               |
| ------------- | ---------------------------------- |
| **`options`** | <code>{ enabled: boolean; }</code> |

--------------------


### setRepeatMode(...)

```typescript
setRepeatMode(options: { repeatMode: RepeatMode; }) => Promise<void>
```

| Param         | Type                                                               |
| ------------- | ------------------------------------------------------------------ |
| **`options`** | <code>{ repeatMode: <a href="#repeatmode">RepeatMode</a>; }</code> |

--------------------


### setVolume(...)

```typescript
setVolume(options: { volume: number; }) => Promise<void>
```

Set player volume (0.0–1.0). Android and web only — iOS rejects with
`NOT_SUPPORTED` (the Spotify iOS SDK has no volume control).

| Param         | Type                             |
| ------------- | -------------------------------- |
| **`options`** | <code>{ volume: number; }</code> |

--------------------


### getVolume()

```typescript
getVolume() => Promise<{ volume: number; }>
```

Get player volume (0.0–1.0). Web and Android (best-effort) — iOS rejects
with `NOT_SUPPORTED`.

**Returns:** <code>Promise&lt;{ volume: number; }&gt;</code>

--------------------


### getPlayerState()

```typescript
getPlayerState() => Promise<PlayerState>
```

One-shot player state snapshot. Rejects `NOT_CONNECTED` when the player
is not connected, or `NOT_ACTIVE_DEVICE` on web when playback lives on
another device.

**Returns:** <code>Promise&lt;<a href="#playerstate">PlayerState</a>&gt;</code>

--------------------


### getImage(...)

```typescript
getImage(options: GetImageOptions) => Promise<GetImageResult>
```

Fetch album art for a track. Pass {@link <a href="#track">Track.imageUri</a>} from a player
state as `imageId`. iOS/Android fetch through the Spotify app (works with
its offline cache) and require a connected player; web resolves to a CDN
URL without a network round-trip.

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#getimageoptions">GetImageOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getimageresult">GetImageResult</a>&gt;</code>

--------------------


### addListener('playerStateChanged', ...)

```typescript
addListener(eventName: 'playerStateChanged', listener: (state: PlayerState) => void) => Promise<PluginListenerHandle>
```

Fired whenever the player state changes (track, pause, seek, ...).

| Param           | Type                                                                    |
| --------------- | ----------------------------------------------------------------------- |
| **`eventName`** | <code>'playerStateChanged'</code>                                       |
| **`listener`**  | <code>(state: <a href="#playerstate">PlayerState</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### addListener('connectionStateChanged', ...)

```typescript
addListener(eventName: 'connectionStateChanged', listener: (event: ConnectionStateChange) => void) => Promise<PluginListenerHandle>
```

Fired when the player connection is established or lost.

| Param           | Type                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------- |
| **`eventName`** | <code>'connectionStateChanged'</code>                                                       |
| **`listener`**  | <code>(event: <a href="#connectionstatechange">ConnectionStateChange</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### addListener('authStateChanged', ...)

```typescript
addListener(eventName: 'authStateChanged', listener: (event: AuthStateChange) => void) => Promise<PluginListenerHandle>
```

Fired when authentication is gained, refreshed, or lost.

| Param           | Type                                                                            |
| --------------- | ------------------------------------------------------------------------------- |
| **`eventName`** | <code>'authStateChanged'</code>                                                 |
| **`listener`**  | <code>(event: <a href="#authstatechange">AuthStateChange</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### removeAllListeners()

```typescript
removeAllListeners() => Promise<void>
```

--------------------


### Interfaces


#### InitializeOptions

| Prop                  | Type                  | Description                                                                                                                                                                                                                                                                       | Default                                                                                                                                   |
| --------------------- | --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **`clientId`**        | <code>string</code>   | Your Spotify app's client ID from the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard). Every consumer of this plugin must register their own Spotify app.                                                                                                  |                                                                                                                                           |
| **`redirectUri`**     | <code>string</code>   | OAuth redirect URI. Must exactly match a Redirect URI registered in the Spotify Developer Dashboard. Native: a custom scheme such as `myapp://spotify-callback`. Web: an `https://` page of your app (or `http://127.0.0.1:port` in dev — `localhost` is not allowed by Spotify). |                                                                                                                                           |
| **`scopes`**          | <code>string[]</code> | OAuth scopes to request during {@link SpotifyPlugin.authorize}.                                                                                                                                                                                                                   | <code>["app-remote-control", "streaming", "user-modify-playback-state", "user-read-playback-state", "user-read-currently-playing"]</code> |
| **`playerName`**      | <code>string</code>   | Web only: name of the Spotify Connect device created by the Web Playback SDK, shown in Spotify's device picker.                                                                                                                                                                   | <code>"Capacitor App"</code>                                                                                                              |
| **`tokenSwapUrl`**    | <code>string</code>   | iOS only: URL of your token-swap service. Optional — by default the plugin uses Authorization Code + PKCE and needs no server.                                                                                                                                                    |                                                                                                                                           |
| **`tokenRefreshUrl`** | <code>string</code>   | iOS only: URL of your token-refresh service. Optional — by default the plugin refreshes tokens itself via PKCE.                                                                                                                                                                   |                                                                                                                                           |


#### AccessToken

| Prop              | Type                  | Description                                                                           |
| ----------------- | --------------------- | ------------------------------------------------------------------------------------- |
| **`accessToken`** | <code>string</code>   | The OAuth access token. Pass as `Authorization: Bearer &lt;token&gt;` to the Web API. |
| **`expiresAt`**   | <code>number</code>   | Expiry time as epoch milliseconds.                                                    |
| **`scopes`**      | <code>string[]</code> | Granted scopes, when known.                                                           |
| **`tokenType`**   | <code>'Bearer'</code> |                                                                                       |


#### AuthorizeOptions

| Prop             | Type                  | Description                                                              |
| ---------------- | --------------------- | ------------------------------------------------------------------------ |
| **`scopes`**     | <code>string[]</code> | Override the scopes given to `initialize()` for this grant.              |
| **`showDialog`** | <code>boolean</code>  | Web only: force the Spotify approval dialog even if previously approved. |


#### SpotifyCapabilities

| Prop                     | Type                                     | Description                                                                                                                                                                               |
| ------------------------ | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`platform`**           | <code>'ios' \| 'android' \| 'web'</code> |                                                                                                                                                                                           |
| **`requiresSpotifyApp`** | <code>boolean</code>                     | True on iOS/Android: the Spotify app must be installed for playback.                                                                                                                      |
| **`requiresPremium`**    | <code>boolean</code>                     | True on web: Spotify Premium is required for the Web Playback SDK.                                                                                                                        |
| **`canSetVolume`**       | <code>boolean</code>                     | True where `setVolume()` works (Android, web).                                                                                                                                            |
| **`canGetVolume`**       | <code>boolean</code>                     | True where `getVolume()` works (web; Android best-effort).                                                                                                                                |
| **`webPlaybackViable`**  | <code>boolean</code>                     | Web only: whether the browser has the EME/DRM support (Widevine) the Web Playback SDK needs. False in most native webviews — use the native platforms there. Always false on iOS/Android. |


#### ConnectOptions

| Prop          | Type                | Description                                                                                                                                                                                                                                                                      |
| ------------- | ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`playUri`** | <code>string</code> | iOS only: Spotify URI passed to `authorizeAndPlayURI` when connecting while the Spotify app is not playing (iOS requires active playback to connect — this wakes Spotify up, briefly app-switching to it). Empty string resumes the user's last context. Ignored on Android/web. |


#### PlayOptions

| Prop      | Type                | Description                                                                                                                      |
| --------- | ------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **`uri`** | <code>string</code> | A Spotify URI (`spotify:track:...`, `spotify:album:...`, `spotify:playlist:...`, `spotify:artist:...`). Omit to resume playback. |


#### PlayerState

| Prop                | Type                                                                  | Description                                                                                                                                     |
| ------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **`track`**         | <code><a href="#track">Track</a> \| null</code>                       | Currently playing track, or null when nothing is loaded.                                                                                        |
| **`paused`**        | <code>boolean</code>                                                  |                                                                                                                                                 |
| **`positionMs`**    | <code>number</code>                                                   |                                                                                                                                                 |
| **`playbackSpeed`** | <code>number</code>                                                   | Playback speed multiplier. Always 1 on web.                                                                                                     |
| **`shuffle`**       | <code>boolean</code>                                                  |                                                                                                                                                 |
| **`repeatMode`**    | <code><a href="#repeatmode">RepeatMode</a></code>                     |                                                                                                                                                 |
| **`restrictions`**  | <code><a href="#playbackrestrictions">PlaybackRestrictions</a></code> | What the current context allows — drive UI enablement from this.                                                                                |
| **`contextUri`**    | <code>string</code>                                                   | URI of the playing context (album/playlist/...), when known.                                                                                    |
| **`contextTitle`**  | <code>string</code>                                                   | Title of the playing context. iOS/Android only.                                                                                                 |
| **`receivedAtMs`**  | <code>number</code>                                                   | Epoch ms timestamp of when this snapshot was taken — extrapolate the live position as `positionMs + (Date.now() - receivedAtMs)` while playing. |


#### Track

| Prop             | Type                  | Description                                                                                                                                 |
| ---------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **`uri`**        | <code>string</code>   |                                                                                                                                             |
| **`name`**       | <code>string</code>   |                                                                                                                                             |
| **`artistName`** | <code>string</code>   | Convenience: name of the primary artist.                                                                                                    |
| **`artists`**    | <code>Artist[]</code> |                                                                                                                                             |
| **`albumName`**  | <code>string</code>   |                                                                                                                                             |
| **`albumUri`**   | <code>string</code>   |                                                                                                                                             |
| **`durationMs`** | <code>number</code>   |                                                                                                                                             |
| **`imageUri`**   | <code>string</code>   | Web: an `https` image URL. iOS/Android: a raw Spotify image identifier (not directly loadable; image fetch support is planned future work). |
| **`isEpisode`**  | <code>boolean</code>  |                                                                                                                                             |
| **`isPodcast`**  | <code>boolean</code>  |                                                                                                                                             |


#### Artist

| Prop       | Type                |
| ---------- | ------------------- |
| **`name`** | <code>string</code> |
| **`uri`**  | <code>string</code> |


#### PlaybackRestrictions

| Prop                   | Type                 |
| ---------------------- | -------------------- |
| **`canSkipNext`**      | <code>boolean</code> |
| **`canSkipPrevious`**  | <code>boolean</code> |
| **`canSeek`**          | <code>boolean</code> |
| **`canToggleShuffle`** | <code>boolean</code> |
| **`canRepeatTrack`**   | <code>boolean</code> |
| **`canRepeatContext`** | <code>boolean</code> |


#### GetImageResult

| Prop          | Type                | Description                                                                                                                                       |
| ------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`dataUrl`** | <code>string</code> | A value directly usable as an `&lt;img src&gt;`: a base64 `data:` URI on iOS/Android (fetched through the Spotify app), an `https://` URL on web. |


#### GetImageOptions

| Prop          | Type                | Description                                                                                                                                      | Default          |
| ------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------- |
| **`imageId`** | <code>string</code> | The image identifier from {@link <a href="#track">Track.imageUri</a>} — a `spotify:image:...` value on iOS/Android, or an `https://` URL on web. |                  |
| **`width`**   | <code>number</code> | Desired image width in pixels. Native maps this to the nearest size the Spotify app provides (144/240/360/480/720); web ignores it.              | <code>480</code> |


#### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


#### ConnectionStateChange

| Prop            | Type                                                                                      | Description                                                            |
| --------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| **`connected`** | <code>boolean</code>                                                                      |                                                                        |
| **`deviceId`**  | <code>string</code>                                                                       | Web only: the Web Playback SDK device ID (from the SDK `ready` event). |
| **`reason`**    | <code>'error' \| 'connect' \| 'disconnect' \| 'appBackgrounded'</code>                    |                                                                        |
| **`error`**     | <code>{ code: <a href="#spotifyerrorcode">SpotifyErrorCode</a>; message: string; }</code> |                                                                        |


#### AuthStateChange

| Prop                | Type                 | Description                                           |
| ------------------- | -------------------- | ----------------------------------------------------- |
| **`authenticated`** | <code>boolean</code> |                                                       |
| **`expiresAt`**     | <code>number</code>  | Token expiry (epoch ms), present while authenticated. |


### Type Aliases


#### RepeatMode

Repeat mode for the player.

- `off`: no repeat
- `track`: repeat the current track
- `context`: repeat the current context (album, playlist, ...)

<code>'off' | 'track' | 'context'</code>


#### SpotifyErrorCode

Error codes attached to rejected calls.

Native rejections arrive as `{ message, code }`; on web, thrown errors
carry the same `code` property. Switch on `error.code` in your app.

<code>'NOT_INITIALIZED' | 'NOT_AUTHENTICATED' | 'AUTH_CANCELLED' | 'AUTH_FAILED' | 'TOKEN_REFRESH_FAILED' | 'SPOTIFY_APP_NOT_INSTALLED' | 'NOT_CONNECTED' | 'CONNECTION_FAILED' | 'PREMIUM_REQUIRED' | 'USER_NOT_AUTHORIZED' | 'UNSUPPORTED_VERSION' | 'OFFLINE' | 'NOT_ACTIVE_DEVICE' | 'NOT_SUPPORTED' | 'PLAYBACK_FAILED' | 'RATE_LIMITED' | 'UNKNOWN'</code>

</docgen-api>

## Error codes

| Code | Meaning |
| --- | --- |
| `NOT_INITIALIZED` | `initialize()` has not been called yet |
| `NOT_AUTHENTICATED` | No session — call `authorize()` |
| `AUTH_CANCELLED` | User dismissed the login/consent flow |
| `AUTH_FAILED` | Authorization failed (bad client ID, redirect mismatch, ...) |
| `TOKEN_REFRESH_FAILED` | Refresh grant failed; session was cleared |
| `SPOTIFY_APP_NOT_INSTALLED` | iOS/Android: Spotify app missing |
| `NOT_CONNECTED` | Player method called before `connect()` succeeded |
| `CONNECTION_FAILED` | Could not connect (on web often missing DRM/webview) |
| `PREMIUM_REQUIRED` | Operation needs a Premium account |
| `USER_NOT_AUTHORIZED` | User lacks `app-remote-control` scope or isn't on the app's user allowlist (development mode) |
| `UNSUPPORTED_VERSION` | Installed Spotify app is too old |
| `OFFLINE` | Network unavailable / Spotify app in offline mode |
| `NOT_ACTIVE_DEVICE` | Web: playback lives on another device |
| `NOT_SUPPORTED` | Not available on this platform (e.g. volume on iOS) |
| `PLAYBACK_FAILED` | A playback command failed |
| `RATE_LIMITED` | Web API 429 — retry later |
| `UNKNOWN` | Anything unmapped |

## Troubleshooting

**App Remote won't connect (iOS/Android)** — the Spotify app must be installed, logged in, and have been launched at least once. On iOS it must be *playing* for a plain connect; use `connect({ playUri: '' })` to let the plugin wake it (expect a brief app switch). On Android, connection errors surface as typed codes (`SPOTIFY_APP_NOT_INSTALLED`, `OFFLINE`, ...).

**`INVALID_CLIENT: Insecure redirect URI`** — your redirect URI isn't registered (exact match!), or the dashboard rejected a custom scheme. Try an all-lowercase, app-specific scheme with a host part (`myapp://spotify-callback`), or use App Links / Universal Links.

**Web: `CONNECTION_FAILED` immediately** — the environment has no EME/DRM (Capacitor webview, Chromium without Widevine, some privacy browsers). Check `getCapabilities().webPlaybackViable`. Ad blockers can also block `sdk.scdn.co`.

**Web: `authorize()` seems to do nothing** — it navigates the page to Spotify. Make sure you call `initialize()` on startup so the redirect back completes the flow, and that the page URL you started from is the registered redirect URI.

**403 from playback calls** — user isn't in your app's User Management allowlist (development mode, max 5), or isn't Premium.

**`PLAYBACK_FAILED: Cannot seek in song [CANT_PLAY_ON_DEMAND]`** — the account is playing in Free-tier (non-on-demand) mode; Spotify disallows seeking there. Check `state.restrictions.canSeek` and disable your seek UI when false — the other `restrictions` flags work the same way.

**Android: `setVolume` fails with "No IAP endpoint"** — many Spotify app builds don't expose local-device volume to App Remote. Treat volume control on Android as best-effort.

**Android: `FAIL_ON_PROJECT_REPOS` build error** — if your app opts into `dependencyResolutionManagement { repositoriesMode = FAIL_ON_PROJECT_REPOS }`, the plugin can't self-register its bundled Maven repo. Add it to your `settings.gradle` instead:

```groovy
dependencyResolutionManagement {
  repositories {
    maven { url "$rootDir/../node_modules/capacitor-spotify/android/repo" }
  }
}
```

**Android build: "Cannot find a Java installation ... languageVersion=21"** — Capacitor 8 builds with a Java 21 toolchain. Point `JAVA_HOME` at a JDK 21 (Android Studio's bundled JBR works: `/Applications/Android Studio.app/Contents/jbr/Contents/Home`).

**Token expired after ~1 hour** — expected; Spotify access tokens live 1 hour. The plugin refreshes automatically inside `getAccessToken()` and for the web player's `getOAuthToken` callback. If you cache the token string yourself, re-call `getAccessToken()` instead.

## Bundled Spotify SDK versions

| SDK | Version | How it ships |
| --- | --- | --- |
| Spotify iOS SDK (`SpotifyiOS.xcframework`) | 5.0.1 | Vendored in `ios/` (CocoaPods) + official SPM package pin |
| Spotify Android App Remote | 0.8.0 | Vendored AAR in `android/repo/` (not on Maven Central) |
| Spotify Android auth library | 5.0.0 | Maven Central (`com.spotify.android:auth`) |
| Web Playback SDK | rolling | Loaded at runtime from `sdk.scdn.co` |

Upgrading the iOS SDK: bump the `exact:` pin in `Package.swift` **and** replace `ios/SpotifyiOS.xcframework` from the same tag in one commit.

## Future work

Web API player helpers (queue, device list, transfer), `ContentApi` browsing, library add/remove + user capabilities (`UserApi`), user profile, token-swap server recipe, EncryptedSharedPreferences, CI.

## License

This plugin is [MIT](./LICENSE) licensed.

The vendored Spotify SDK binaries (`ios/SpotifyiOS.xcframework`, `android/repo/.../app-remote-0.8.0.aar`) remain subject to Spotify's own terms — see [`SPOTIFY_SDK_LICENSES/`](./SPOTIFY_SDK_LICENSES) and the [Spotify Developer Terms](https://developer.spotify.com/terms/). Note that Spotify's SDK/Web Playback terms restrict commercial use without prior written approval from Spotify — review them for your use case.
