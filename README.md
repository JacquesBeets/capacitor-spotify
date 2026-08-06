# capacitor-spotify

Capacitor plugin for Spotify: native App Remote playback + auth on iOS/Android, Web Playback SDK on web

## Install

To use npm

```bash
npm install capacitor-spotify
````

To use yarn

```bash
yarn add capacitor-spotify
```

Sync native files

```bash
npx cap sync
```

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
