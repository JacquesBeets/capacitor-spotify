import type { PluginListenerHandle } from '@capacitor/core';

/**
 * Repeat mode for the player.
 *
 * - `off`: no repeat
 * - `track`: repeat the current track
 * - `context`: repeat the current context (album, playlist, ...)
 */
export type RepeatMode = 'off' | 'track' | 'context';

/**
 * Error codes attached to rejected calls.
 *
 * Native rejections arrive as `{ message, code }`; on web, thrown errors
 * carry the same `code` property. Switch on `error.code` in your app.
 */
export type SpotifyErrorCode =
  | 'NOT_INITIALIZED'
  | 'NOT_AUTHENTICATED'
  | 'AUTH_CANCELLED'
  | 'AUTH_FAILED'
  | 'TOKEN_REFRESH_FAILED'
  | 'SPOTIFY_APP_NOT_INSTALLED'
  | 'NOT_CONNECTED'
  | 'CONNECTION_FAILED'
  | 'PREMIUM_REQUIRED'
  | 'USER_NOT_AUTHORIZED'
  | 'UNSUPPORTED_VERSION'
  | 'OFFLINE'
  | 'NOT_ACTIVE_DEVICE'
  | 'NOT_SUPPORTED'
  | 'PLAYBACK_FAILED'
  | 'RATE_LIMITED'
  | 'UNKNOWN';

export interface InitializeOptions {
  /**
   * Your Spotify app's client ID from the
   * [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
   *
   * Every consumer of this plugin must register their own Spotify app.
   */
  clientId: string;
  /**
   * OAuth redirect URI. Must exactly match a Redirect URI registered in the
   * Spotify Developer Dashboard.
   *
   * Native: a custom scheme such as `myapp://spotify-callback`.
   * Web: an `https://` page of your app (or `http://127.0.0.1:port` in dev —
   * `localhost` is not allowed by Spotify).
   */
  redirectUri: string;
  /**
   * OAuth scopes to request during {@link SpotifyPlugin.authorize}.
   *
   * @default ["app-remote-control", "streaming", "user-modify-playback-state", "user-read-playback-state", "user-read-currently-playing"]
   */
  scopes?: string[];
  /**
   * Web only: name of the Spotify Connect device created by the Web Playback
   * SDK, shown in Spotify's device picker.
   *
   * @default "Capacitor App"
   */
  playerName?: string;
  /**
   * iOS only: URL of your token-swap service. Optional — by default the
   * plugin uses Authorization Code + PKCE and needs no server.
   */
  tokenSwapUrl?: string;
  /**
   * iOS only: URL of your token-refresh service. Optional — by default the
   * plugin refreshes tokens itself via PKCE.
   */
  tokenRefreshUrl?: string;
}

export interface AuthorizeOptions {
  /** Override the scopes given to `initialize()` for this grant. */
  scopes?: string[];
  /** Web only: force the Spotify approval dialog even if previously approved. */
  showDialog?: boolean;
}

export interface AccessToken {
  /** The OAuth access token. Pass as `Authorization: Bearer <token>` to the Web API. */
  accessToken: string;
  /** Expiry time as epoch milliseconds. */
  expiresAt: number;
  /** Granted scopes, when known. */
  scopes?: string[];
  tokenType: 'Bearer';
}

export interface ConnectOptions {
  /**
   * iOS only: Spotify URI passed to `authorizeAndPlayURI` when connecting
   * while the Spotify app is not playing (iOS requires active playback to
   * connect — this wakes Spotify up, briefly app-switching to it).
   * Empty string resumes the user's last context. Ignored on Android/web.
   */
  playUri?: string;
}

export interface PlayOptions {
  /**
   * A Spotify URI (`spotify:track:...`, `spotify:album:...`,
   * `spotify:playlist:...`, `spotify:artist:...`). Omit to resume playback.
   */
  uri?: string;
}

export interface SpotifyCapabilities {
  platform: 'ios' | 'android' | 'web';
  /** True on iOS/Android: the Spotify app must be installed for playback. */
  requiresSpotifyApp: boolean;
  /** True on web: Spotify Premium is required for the Web Playback SDK. */
  requiresPremium: boolean;
  /** True where `setVolume()` works (Android, web). */
  canSetVolume: boolean;
  /** True where `getVolume()` works (web; Android best-effort). */
  canGetVolume: boolean;
  /**
   * Web only: whether the browser has the EME/DRM support (Widevine) the Web
   * Playback SDK needs. False in most native webviews — use the native
   * platforms there. Always false on iOS/Android.
   */
  webPlaybackViable: boolean;
}

export interface Artist {
  name: string;
  uri?: string;
}

export interface Track {
  uri: string;
  name: string;
  /** Convenience: name of the primary artist. */
  artistName: string;
  artists: Artist[];
  albumName: string;
  albumUri?: string;
  durationMs: number;
  /**
   * Web: an `https` image URL. iOS/Android: a raw Spotify image identifier
   * (not directly loadable; image fetch support is planned future work).
   */
  imageUri?: string;
  isEpisode: boolean;
  isPodcast: boolean;
}

export interface PlaybackRestrictions {
  canSkipNext: boolean;
  canSkipPrevious: boolean;
  canSeek: boolean;
  canToggleShuffle: boolean;
  canRepeatTrack: boolean;
  canRepeatContext: boolean;
}

export interface PlayerState {
  /** Currently playing track, or null when nothing is loaded. */
  track: Track | null;
  paused: boolean;
  positionMs: number;
  /** Playback speed multiplier. Always 1 on web. */
  playbackSpeed: number;
  shuffle: boolean;
  repeatMode: RepeatMode;
  /** What the current context allows — drive UI enablement from this. */
  restrictions: PlaybackRestrictions;
  /** URI of the playing context (album/playlist/...), when known. */
  contextUri?: string;
  /** Title of the playing context. iOS/Android only. */
  contextTitle?: string;
  /**
   * Epoch ms timestamp of when this snapshot was taken — extrapolate the
   * live position as `positionMs + (Date.now() - receivedAtMs)` while playing.
   */
  receivedAtMs: number;
}

export interface ConnectionStateChange {
  connected: boolean;
  /** Web only: the Web Playback SDK device ID (from the SDK `ready` event). */
  deviceId?: string;
  reason?: 'connect' | 'disconnect' | 'appBackgrounded' | 'error';
  error?: { code: SpotifyErrorCode; message: string };
}

export interface AuthStateChange {
  authenticated: boolean;
  /** Token expiry (epoch ms), present while authenticated. */
  expiresAt?: number;
}

export interface SpotifyPlugin {
  /**
   * Configure the plugin. Must be called before any other method. Idempotent.
   *
   * Web: also completes a pending OAuth redirect — call it on app startup so
   * a `?code=` callback on the current URL resolves the in-flight
   * `authorize()` flow.
   */
  initialize(options: InitializeOptions): Promise<void>;

  /**
   * Launch interactive Spotify authorization.
   *
   * iOS: `SPTSessionManager` (app-switch to Spotify, or in-app web auth when
   * Spotify is not installed). Android: Spotify auth library (SSO via the
   * Spotify app, Custom Tabs fallback). Web: Authorization Code + PKCE via a
   * full-page redirect.
   *
   * All platforms use PKCE — no client secret is involved.
   */
  authorize(options?: AuthorizeOptions): Promise<AccessToken>;

  /**
   * Get a valid access token, refreshing it internally when it is about to
   * expire. Rejects with `NOT_AUTHENTICATED` when there is no session.
   *
   * Use this to call the Spotify Web API from your own code.
   */
  getAccessToken(options?: { forceRefresh?: boolean }): Promise<AccessToken>;

  /** Clear the stored session and disconnect the player if connected. */
  logout(): Promise<void>;

  /**
   * Whether the Spotify app is installed on this device. Always false on web.
   */
  isSpotifyAppInstalled(): Promise<{ installed: boolean }>;

  /** What this platform supports — see {@link SpotifyCapabilities}. */
  getCapabilities(): Promise<SpotifyCapabilities>;

  /**
   * Connect to the player.
   *
   * iOS/Android: connects to the Spotify app via App Remote and subscribes to
   * player state. Web: loads the Web Playback SDK and creates the Connect
   * device — must be called from a user gesture (tap/click).
   */
  connect(options?: ConnectOptions): Promise<void>;

  /** Disconnect from the player. Safe to call when not connected. */
  disconnect(): Promise<void>;

  isConnected(): Promise<{ connected: boolean }>;

  /**
   * Play a Spotify URI, or resume playback when no URI is given.
   *
   * Web: starting a URI requires this SDK device to be (or become) the active
   * device; the plugin transfers playback automatically on first play.
   */
  play(options?: PlayOptions): Promise<void>;

  pause(): Promise<void>;

  resume(): Promise<void>;

  togglePlay(): Promise<void>;

  skipNext(): Promise<void>;

  skipPrevious(): Promise<void>;

  seekTo(options: { positionMs: number }): Promise<void>;

  setShuffle(options: { enabled: boolean }): Promise<void>;

  setRepeatMode(options: { repeatMode: RepeatMode }): Promise<void>;

  /**
   * Set player volume (0.0–1.0). Android and web only — iOS rejects with
   * `NOT_SUPPORTED` (the Spotify iOS SDK has no volume control).
   */
  setVolume(options: { volume: number }): Promise<void>;

  /**
   * Get player volume (0.0–1.0). Web and Android (best-effort) — iOS rejects
   * with `NOT_SUPPORTED`.
   */
  getVolume(): Promise<{ volume: number }>;

  /**
   * One-shot player state snapshot. Rejects `NOT_CONNECTED` when the player
   * is not connected, or `NOT_ACTIVE_DEVICE` on web when playback lives on
   * another device.
   */
  getPlayerState(): Promise<PlayerState>;

  /** Fired whenever the player state changes (track, pause, seek, ...). */
  addListener(eventName: 'playerStateChanged', listener: (state: PlayerState) => void): Promise<PluginListenerHandle>;

  /** Fired when the player connection is established or lost. */
  addListener(
    eventName: 'connectionStateChanged',
    listener: (event: ConnectionStateChange) => void,
  ): Promise<PluginListenerHandle>;

  /** Fired when authentication is gained, refreshed, or lost. */
  addListener(eventName: 'authStateChanged', listener: (event: AuthStateChange) => void): Promise<PluginListenerHandle>;

  removeAllListeners(): Promise<void>;
}
