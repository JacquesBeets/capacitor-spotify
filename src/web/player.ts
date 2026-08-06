import type {
  ConnectionStateChange,
  PlaybackRestrictions,
  PlayerState,
  RepeatMode,
  SpotifyErrorCode,
  Track,
} from '../definitions';

import type { SpotifyAuth } from './auth';
import { errorCode, errorMessage, spotifyError } from './errors';
import type {
  SpotifyPlayer,
  SpotifySdk,
  WebPlaybackDisallows,
  WebPlaybackState,
  WebPlaybackTrack,
} from './spotify-sdk';

const SDK_SCRIPT_URL = 'https://sdk.scdn.co/spotify-player.js';
const SDK_SCRIPT_ID = 'capacitor-spotify-web-playback-sdk';
const DEFAULT_PLAYER_NAME = 'Capacitor App';
/** How long to wait for the SDK's `ready` event before giving up. */
const CONNECT_TIMEOUT_MS = 15_000;

/** Every event this plugin subscribes to, so teardown can unsubscribe. */
const SDK_EVENTS = [
  'ready',
  'not_ready',
  'player_state_changed',
  'initialization_error',
  'authentication_error',
  'account_error',
  'playback_error',
  'autoplay_failed',
];

/** Shared across instances: the SDK script can only be loaded once per page. */
let sdkPromise: Promise<SpotifySdk> | null = null;

/**
 * Inject the Web Playback SDK script and resolve once `window.Spotify` exists.
 *
 * The SDK signals readiness by calling `window.onSpotifyWebPlaybackSDKReady`,
 * which therefore has to be installed *before* the script starts executing.
 */
function loadSdk(): Promise<SpotifySdk> {
  if (sdkPromise) {
    return sdkPromise;
  }

  sdkPromise = new Promise<SpotifySdk>((resolve, reject) => {
    if (window.Spotify) {
      resolve(window.Spotify);
      return;
    }

    const previousCallback = window.onSpotifyWebPlaybackSDKReady;
    window.onSpotifyWebPlaybackSDKReady = () => {
      previousCallback?.();
      if (window.Spotify) {
        resolve(window.Spotify);
      } else {
        sdkPromise = null;
        reject(
          spotifyError('CONNECTION_FAILED', 'The Spotify Web Playback SDK loaded without exposing window.Spotify.'),
        );
      }
    };

    // Someone (a previous connect(), or the host app) already started the load;
    // the callback above still fires for us.
    if (document.getElementById(SDK_SCRIPT_ID)) {
      return;
    }

    const script = document.createElement('script');
    script.id = SDK_SCRIPT_ID;
    script.src = SDK_SCRIPT_URL;
    script.async = true;
    script.onerror = () => {
      sdkPromise = null;
      script.remove();
      reject(
        spotifyError(
          'OFFLINE',
          `Could not load the Spotify Web Playback SDK from ${SDK_SCRIPT_URL}. Check the network connection and any content security policy.`,
        ),
      );
    };
    document.head.appendChild(script);
  });

  return sdkPromise;
}

/**
 * Wraps a single Web Playback SDK player: connection lifecycle, event
 * translation and the playback commands the SDK can service locally.
 */
export class SpotifyWebPlayer {
  private player: SpotifyPlayer | null = null;
  private deviceId: string | null = null;
  private playerName = DEFAULT_PLAYER_NAME;
  private connecting: Promise<void> | null = null;
  private pendingConnect: { resolve: () => void; reject: (error: unknown) => void } | null = null;
  private connectTimeout: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly auth: SpotifyAuth,
    private readonly emitConnectionState: (event: ConnectionStateChange) => void,
    private readonly emitPlayerState: (state: PlayerState) => void,
  ) {}

  /** Name shown in Spotify's device picker. Applied on the next connect. */
  setPlayerName(name?: string): void {
    this.playerName = name?.trim() ? name : DEFAULT_PLAYER_NAME;
  }

  isConnected(): boolean {
    return this.player !== null && this.deviceId !== null;
  }

  /** The Spotify Connect device ID, once the SDK has reported `ready`. */
  getDeviceId(): string | null {
    return this.deviceId;
  }

  async connect(): Promise<void> {
    if (this.isConnected()) {
      return;
    }
    if (this.connecting) {
      return this.connecting;
    }
    const attempt = this.doConnect();
    this.connecting = attempt;
    try {
      await attempt;
    } finally {
      this.connecting = null;
    }
  }

  async disconnect(): Promise<void> {
    const wasConnected = this.isConnected();
    this.settleConnect(spotifyError('NOT_CONNECTED', 'connect() was cancelled by disconnect().'));
    this.teardown();
    if (wasConnected) {
      this.emitConnectionState({ connected: false, reason: 'disconnect' });
    }
  }

  async pause(): Promise<void> {
    await this.command('pause', (player) => player.pause());
  }

  async resume(): Promise<void> {
    await this.command('resume', (player) => player.resume());
  }

  async togglePlay(): Promise<void> {
    await this.command('togglePlay', (player) => player.togglePlay());
  }

  async seek(positionMs: number): Promise<void> {
    await this.command('seekTo', (player) => player.seek(positionMs));
  }

  async previousTrack(): Promise<void> {
    await this.command('skipPrevious', (player) => player.previousTrack());
  }

  async nextTrack(): Promise<void> {
    await this.command('skipNext', (player) => player.nextTrack());
  }

  async setVolume(volume: number): Promise<void> {
    // The SDK rejects out-of-range values; clamp so 1.2 behaves like 1.0.
    const clamped = Math.min(1, Math.max(0, volume));
    await this.command('setVolume', (player) => player.setVolume(clamped));
  }

  async getVolume(): Promise<number> {
    const player = this.requirePlayer();
    try {
      return await player.getVolume();
    } catch (error) {
      throw spotifyError('PLAYBACK_FAILED', `getVolume failed: ${errorMessage(error)}`);
    }
  }

  /** `null` when playback is not on this device (or nothing is loaded). */
  async getCurrentState(): Promise<PlayerState | null> {
    const player = this.requirePlayer();
    let state: WebPlaybackState | null;
    try {
      state = await player.getCurrentState();
    } catch (error) {
      throw spotifyError('PLAYBACK_FAILED', `getPlayerState failed: ${errorMessage(error)}`);
    }
    return state ? toPlayerState(state) : null;
  }

  private async doConnect(): Promise<void> {
    const sdk = await loadSdk();

    const player = new sdk.Player({
      name: this.playerName,
      volume: 1,
      getOAuthToken: (callback) => {
        this.auth
          .getAccessToken()
          .then((token) => callback(token.accessToken))
          .catch((error) =>
            this.fail(
              errorCode(error) ?? 'NOT_AUTHENTICATED',
              `The Spotify Web Playback SDK could not be given an access token: ${errorMessage(error)}`,
            ),
          );
      },
    });
    this.registerListeners(player);
    this.player = player;

    const ready = new Promise<void>((resolve, reject) => {
      this.pendingConnect = { resolve, reject };
    });
    this.connectTimeout = setTimeout(
      () =>
        this.settleConnect(
          spotifyError(
            'CONNECTION_FAILED',
            `The Spotify Web Playback SDK did not become ready within ${CONNECT_TIMEOUT_MS} ms.`,
          ),
        ),
      CONNECT_TIMEOUT_MS,
    );

    try {
      // Primes the SDK's hidden <audio> element. Only effective inside the user
      // gesture that led here, and purely best-effort: older SDK builds and
      // desktop browsers do without it.
      if (typeof player.activateElement === 'function') {
        try {
          await player.activateElement();
        } catch {
          /* Best effort — autoplay may still be blocked. */
        }
      }

      const accepted = await player.connect();
      if (!accepted) {
        this.settleConnect(
          spotifyError('CONNECTION_FAILED', 'The Spotify Web Playback SDK refused to connect to Spotify.'),
        );
      }
      await ready;
    } catch (error) {
      this.teardown();
      throw error;
    }
  }

  private registerListeners(player: SpotifyPlayer): void {
    player.addListener('ready', ({ device_id }) => {
      this.deviceId = device_id;
      this.emitConnectionState({ connected: true, deviceId: device_id, reason: 'connect' });
      this.settleConnect(null);
    });

    player.addListener('not_ready', ({ device_id }) => {
      this.deviceId = null;
      this.emitConnectionState({ connected: false, deviceId: device_id, reason: 'disconnect' });
    });

    player.addListener('player_state_changed', (state) => {
      if (state) {
        this.emitPlayerState(toPlayerState(state));
      }
    });

    player.addListener('initialization_error', ({ message }) =>
      this.fail(
        'CONNECTION_FAILED',
        `The Spotify Web Playback SDK failed to initialize: ${message}. This usually means the browser or webview lacks the EME/DRM (Widevine) support the SDK requires — check getCapabilities().webPlaybackViable and prefer the native platforms inside a Capacitor webview.`,
      ),
    );

    player.addListener('authentication_error', ({ message }) =>
      this.fail('NOT_AUTHENTICATED', `Spotify rejected the access token: ${message}`),
    );

    player.addListener('account_error', ({ message }) =>
      this.fail('PREMIUM_REQUIRED', `Spotify Premium is required for Web Playback SDK playback: ${message}`),
    );

    player.addListener('playback_error', ({ message }) => this.fail('PLAYBACK_FAILED', `Playback failed: ${message}`));

    player.addListener('autoplay_failed', () =>
      this.emitConnectionState({
        connected: true,
        deviceId: this.deviceId ?? undefined,
        reason: 'error',
        error: {
          code: 'PLAYBACK_FAILED',
          message: 'Autoplay blocked by the browser — start playback from a user gesture.',
        },
      }),
    );
  }

  private async command(action: string, call: (player: SpotifyPlayer) => Promise<void>): Promise<void> {
    const player = this.requirePlayer();
    try {
      await call(player);
    } catch (error) {
      throw spotifyError('PLAYBACK_FAILED', `${action} failed: ${errorMessage(error)}`);
    }
  }

  private requirePlayer(): SpotifyPlayer {
    if (!this.player) {
      throw spotifyError('NOT_CONNECTED', 'The Spotify player is not connected. Call connect() first.');
    }
    return this.player;
  }

  /** Report an SDK error as an event, and fail an in-flight connect with it. */
  private fail(code: SpotifyErrorCode, message: string): void {
    this.emitConnectionState({
      connected: this.deviceId !== null,
      deviceId: this.deviceId ?? undefined,
      reason: 'error',
      error: { code, message },
    });
    this.settleConnect(spotifyError(code, message));
  }

  private settleConnect(error: Error | null): void {
    if (this.connectTimeout !== null) {
      clearTimeout(this.connectTimeout);
      this.connectTimeout = null;
    }
    const pending = this.pendingConnect;
    this.pendingConnect = null;
    if (!pending) {
      return;
    }
    if (error) {
      pending.reject(error);
    } else {
      pending.resolve();
    }
  }

  private teardown(): void {
    if (this.connectTimeout !== null) {
      clearTimeout(this.connectTimeout);
      this.connectTimeout = null;
    }
    this.pendingConnect = null;
    const player = this.player;
    this.player = null;
    this.deviceId = null;
    if (!player) {
      return;
    }
    try {
      // Detach first: a discarded player still fires `not_ready` on disconnect,
      // which would duplicate the event this class emits itself.
      for (const event of SDK_EVENTS) {
        player.removeListener(event);
      }
      player.disconnect();
    } catch {
      /* Already gone. */
    }
  }
}

function toPlayerState(state: WebPlaybackState): PlayerState {
  return {
    track: toTrack(state.track_window?.current_track),
    paused: state.paused,
    positionMs: state.position,
    // The Web Playback SDK has no rate control.
    playbackSpeed: 1,
    shuffle: state.shuffle,
    repeatMode: toRepeatMode(state.repeat_mode),
    restrictions: toRestrictions(state.disallows),
    contextUri: state.context?.uri ?? undefined,
    receivedAtMs: Date.now(),
  };
}

function toTrack(raw: WebPlaybackTrack | null | undefined): Track | null {
  if (!raw) {
    return null;
  }
  const artists = (raw.artists ?? []).map((artist) => ({ name: artist.name, uri: artist.uri }));
  const isEpisode = raw.type === 'episode';
  return {
    uri: raw.uri,
    name: raw.name,
    artistName: artists[0]?.name ?? '',
    artists,
    albumName: raw.album?.name ?? '',
    albumUri: raw.album?.uri,
    durationMs: raw.duration_ms,
    imageUri: raw.album?.images?.[0]?.url,
    isEpisode,
    // The SDK only distinguishes audio from video; video media is always
    // podcast content, as is anything typed as an episode.
    isPodcast: isEpisode || raw.media_type === 'video',
  };
}

/**
 * The SDK reports `repeat_mode` numerically. Per the Web Playback SDK reference
 * (https://developer.spotify.com/documentation/web-playback-sdk/reference) the
 * values are `0` NO_REPEAT, `1` ONCE_REPEAT (the current track) and `2`
 * FULL_CONTEXT_REPEAT. Community reports about `1` versus `2` are inconsistent;
 * this mapping deliberately follows the official reference.
 */
function toRepeatMode(mode: number): RepeatMode {
  switch (mode) {
    case 1:
      return 'track';
    case 2:
      return 'context';
    default:
      return 'off';
  }
}

/** `disallows` lists what is forbidden; the plugin exposes what is allowed. */
function toRestrictions(disallows: WebPlaybackDisallows | null | undefined): PlaybackRestrictions {
  const forbidden = disallows ?? {};
  return {
    canSkipNext: !forbidden.skipping_next,
    canSkipPrevious: !forbidden.skipping_prev,
    canSeek: !forbidden.seeking,
    canToggleShuffle: !forbidden.toggling_shuffle,
    canRepeatTrack: !forbidden.toggling_repeat_track,
    canRepeatContext: !forbidden.toggling_repeat_context,
  };
}
