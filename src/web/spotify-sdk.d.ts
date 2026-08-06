/**
 * Minimal typings for the Spotify Web Playback SDK, which is loaded at runtime
 * from `https://sdk.scdn.co/spotify-player.js` and exposes itself as the
 * `window.Spotify` global.
 *
 * Deliberately hand-written (and deliberately minimal) so the plugin needs no
 * `@types/*` dependency. Only the surface the plugin actually touches is typed.
 *
 * Reference: https://developer.spotify.com/documentation/web-playback-sdk/reference
 */

export interface WebPlaybackArtist {
  uri: string;
  name: string;
}

export interface WebPlaybackImage {
  url: string;
  height?: number | null;
  width?: number | null;
}

export interface WebPlaybackAlbum {
  uri: string;
  name: string;
  images: WebPlaybackImage[];
}

export interface WebPlaybackTrack {
  uri: string;
  id: string | null;
  name: string;
  duration_ms: number;
  artists: WebPlaybackArtist[];
  album: WebPlaybackAlbum;
  /** `track` for music, `episode` for podcast episodes, `ad` for adverts. */
  type?: 'track' | 'episode' | 'ad';
  media_type?: 'audio' | 'video';
  is_playable?: boolean;
}

/** Actions the current context forbids. Absent keys mean "allowed". */
export interface WebPlaybackDisallows {
  pausing?: boolean;
  peeking_next?: boolean;
  peeking_prev?: boolean;
  resuming?: boolean;
  seeking?: boolean;
  skipping_next?: boolean;
  skipping_prev?: boolean;
  toggling_repeat_context?: boolean;
  toggling_repeat_track?: boolean;
  toggling_shuffle?: boolean;
}

export interface WebPlaybackContext {
  uri: string | null;
  metadata: Record<string, unknown> | null;
}

export interface WebPlaybackTrackWindow {
  current_track: WebPlaybackTrack;
  previous_tracks: WebPlaybackTrack[];
  next_tracks: WebPlaybackTrack[];
}

export interface WebPlaybackState {
  context: WebPlaybackContext;
  disallows: WebPlaybackDisallows;
  paused: boolean;
  /** Position within the current track, in milliseconds. */
  position: number;
  duration: number;
  /** `0` no repeat, `1` repeat one, `2` repeat the whole context. */
  repeat_mode: number;
  shuffle: boolean;
  timestamp: number;
  track_window: WebPlaybackTrackWindow;
}

export interface WebPlaybackInstance {
  device_id: string;
}

export interface WebPlaybackError {
  message: string;
}

export interface SpotifyPlayerOptions {
  name: string;
  getOAuthToken: (callback: (token: string) => void) => void;
  volume?: number;
  enableMediaSession?: boolean;
}

export interface SpotifyPlayer {
  addListener(event: 'ready' | 'not_ready', callback: (instance: WebPlaybackInstance) => void): boolean;
  addListener(event: 'player_state_changed', callback: (state: WebPlaybackState | null) => void): boolean;
  addListener(
    event: 'initialization_error' | 'authentication_error' | 'account_error' | 'playback_error',
    callback: (error: WebPlaybackError) => void,
  ): boolean;
  addListener(event: 'autoplay_failed', callback: () => void): boolean;
  removeListener(event: string): boolean;
  connect(): Promise<boolean>;
  disconnect(): void;
  /**
   * Primes the SDK's hidden `<audio>` element. Must be called from a user
   * gesture on mobile browsers. Added in a later SDK release, hence optional.
   */
  activateElement?(): Promise<void>;
  getCurrentState(): Promise<WebPlaybackState | null>;
  getVolume(): Promise<number>;
  setVolume(volume: number): Promise<void>;
  setName(name: string): Promise<void>;
  pause(): Promise<void>;
  resume(): Promise<void>;
  togglePlay(): Promise<void>;
  seek(positionMs: number): Promise<void>;
  previousTrack(): Promise<void>;
  nextTrack(): Promise<void>;
}

/** The `window.Spotify` namespace object installed by the SDK script. */
export interface SpotifySdk {
  Player: new (options: SpotifyPlayerOptions) => SpotifyPlayer;
}

declare global {
  interface Window {
    Spotify?: SpotifySdk;
    /** Invoked by the SDK script once `window.Spotify` is available. */
    onSpotifyWebPlaybackSDKReady?: () => void;
  }
}
