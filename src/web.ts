import { WebPlugin } from '@capacitor/core';

import type {
  AccessToken,
  AuthorizeOptions,
  GetImageOptions,
  GetImageResult,
  InitializeOptions,
  PlayOptions,
  PlayerState,
  RepeatMode,
  SpotifyCapabilities,
  SpotifyDevice,
  SpotifyPlugin,
  UserCapabilities,
} from './definitions';
import { SpotifyWebApi } from './web/api';
import { SpotifyAuth } from './web/auth';
import { spotifyError } from './web/errors';
import { SpotifyWebPlayer } from './web/player';

/**
 * Web implementation: Authorization Code + PKCE for auth and the Spotify Web
 * Playback SDK for playback, with a handful of Web API calls for the things the
 * SDK cannot do itself.
 *
 * This class is only a facade — the work lives in `src/web/`.
 */
export class SpotifyWeb extends WebPlugin implements SpotifyPlugin {
  private readonly auth = new SpotifyAuth((event) => this.notifyListeners('authStateChanged', event));
  private readonly player = new SpotifyWebPlayer(
    this.auth,
    (event) => this.notifyListeners('connectionStateChanged', event),
    (state) => this.notifyListeners('playerStateChanged', state),
  );
  private readonly api = new SpotifyWebApi(this.auth);
  private initialized = false;

  async initialize(options: InitializeOptions): Promise<void> {
    if (!options?.clientId) {
      throw spotifyError('NOT_INITIALIZED', 'initialize() requires a Spotify clientId.');
    }
    if (!options.redirectUri) {
      throw spotifyError('NOT_INITIALIZED', 'initialize() requires a redirectUri.');
    }

    this.auth.configure(options);
    this.player.setPlayerName(options.playerName);
    // Set before completing the redirect, so a failed OAuth callback does not
    // leave the plugin unusable (and initialize() stays idempotent).
    this.initialized = true;
    await this.auth.completeRedirect();
  }

  async authorize(options?: AuthorizeOptions): Promise<AccessToken> {
    this.assertInitialized();
    return this.auth.authorize(options);
  }

  async getAccessToken(options?: { forceRefresh?: boolean }): Promise<AccessToken> {
    this.assertInitialized();
    return this.auth.getAccessToken(options);
  }

  async logout(): Promise<void> {
    await this.player.disconnect();
    this.api.reset();
    await this.auth.logout();
  }

  async isSpotifyAppInstalled(): Promise<{ installed: boolean }> {
    // The web platform never talks to the installed Spotify app.
    return { installed: false };
  }

  async getCapabilities(): Promise<SpotifyCapabilities> {
    return {
      platform: 'web',
      requiresSpotifyApp: false,
      requiresPremium: true,
      canSetVolume: true,
      canGetVolume: true,
      webPlaybackViable: await probeWebPlaybackViable(),
    };
  }

  /**
   * `ConnectOptions.playUri` is iOS-only, so no options are accepted here —
   * passing them from shared code remains harmless.
   */
  async connect(): Promise<void> {
    this.assertInitialized();
    // Surfaces NOT_AUTHENTICATED up front rather than through an SDK event.
    await this.auth.getAccessToken();
    await this.player.connect();
  }

  async disconnect(): Promise<void> {
    this.api.reset();
    await this.player.disconnect();
  }

  async isConnected(): Promise<{ connected: boolean }> {
    return { connected: this.player.isConnected() };
  }

  async play(options?: PlayOptions): Promise<void> {
    const deviceId = this.requireDeviceId();
    if (!options?.uri) {
      await this.player.resume();
      return;
    }
    await this.api.play(deviceId, options.uri);
  }

  async pause(): Promise<void> {
    this.assertConnected();
    await this.player.pause();
  }

  async resume(): Promise<void> {
    this.assertConnected();
    await this.player.resume();
  }

  async togglePlay(): Promise<void> {
    this.assertConnected();
    await this.player.togglePlay();
  }

  async skipNext(): Promise<void> {
    this.assertConnected();
    await this.player.nextTrack();
  }

  async skipPrevious(): Promise<void> {
    this.assertConnected();
    await this.player.previousTrack();
  }

  async seekTo(options: { positionMs: number }): Promise<void> {
    this.assertConnected();
    await this.player.seek(options.positionMs);
  }

  async setShuffle(options: { enabled: boolean }): Promise<void> {
    await this.api.setShuffle(this.requireDeviceId(), options.enabled);
  }

  async setRepeatMode(options: { repeatMode: RepeatMode }): Promise<void> {
    await this.api.setRepeatMode(this.requireDeviceId(), options.repeatMode);
  }

  async setVolume(options: { volume: number }): Promise<void> {
    this.assertConnected();
    await this.player.setVolume(options.volume);
  }

  async getVolume(): Promise<{ volume: number }> {
    this.assertConnected();
    return { volume: await this.player.getVolume() };
  }

  async getPlayerState(): Promise<PlayerState> {
    this.assertConnected();
    const state = await this.player.getCurrentState();
    if (!state) {
      throw spotifyError(
        'NOT_ACTIVE_DEVICE',
        'This device is not the active Spotify device — playback is happening elsewhere. Call play() to transfer it here.',
      );
    }
    return state;
  }

  async getUserCapabilities(): Promise<UserCapabilities> {
    this.assertInitialized();
    // A connected Web Playback SDK player proves Premium — the SDK refuses
    // non-Premium accounts with account_error before ever reaching `ready`.
    if (this.player.isConnected()) {
      return { canPlayOnDemand: true };
    }
    const profile = await this.api.getProfile();
    if (typeof profile.product === 'string') {
      return { canPlayOnDemand: profile.product === 'premium' };
    }
    throw spotifyError(
      'NOT_SUPPORTED',
      'The subscription level is unknown: development-mode apps get no product field. Connect the player to prove Premium instead.',
    );
  }

  async addToQueue(options: { uri: string }): Promise<void> {
    this.assertInitialized();
    if (!options?.uri) {
      throw spotifyError('UNKNOWN', 'addToQueue() requires a uri.');
    }
    await this.api.addToQueue(options.uri);
  }

  async getDevices(): Promise<{ devices: SpotifyDevice[] }> {
    this.assertInitialized();
    const raw = await this.api.getDevices();
    return { devices: raw.map(deviceToJS) };
  }

  async transferPlayback(options: { deviceId: string; play?: boolean }): Promise<void> {
    this.assertInitialized();
    if (!options?.deviceId) {
      throw spotifyError('UNKNOWN', 'transferPlayback() requires a deviceId.');
    }
    await this.api.transferPlayback(options.deviceId, options.play ?? false);
  }

  async getImage(options: GetImageOptions): Promise<GetImageResult> {
    this.assertInitialized();
    const imageId = options?.imageId;
    if (!imageId) {
      throw spotifyError('UNKNOWN', 'getImage() requires an imageId.');
    }
    // Web player states already carry https URLs; native-style identifiers
    // map onto Spotify's image CDN.
    if (imageId.startsWith('https://')) {
      return { dataUrl: imageId };
    }
    if (imageId.startsWith('spotify:image:')) {
      return { dataUrl: `https://i.scdn.co/image/${imageId.slice('spotify:image:'.length)}` };
    }
    throw spotifyError('UNKNOWN', `Unrecognized imageId: ${imageId}`);
  }

  private assertInitialized(): void {
    if (!this.initialized) {
      throw spotifyError('NOT_INITIALIZED', 'Call initialize() before using the Spotify plugin.');
    }
  }

  private assertConnected(): void {
    this.assertInitialized();
    if (!this.player.isConnected()) {
      throw spotifyError('NOT_CONNECTED', 'The Spotify player is not connected. Call connect() first.');
    }
  }

  private requireDeviceId(): string {
    this.assertConnected();
    const deviceId = this.player.getDeviceId();
    if (!deviceId) {
      throw spotifyError('NOT_CONNECTED', 'The Spotify Web Playback SDK device is not ready yet.');
    }
    return deviceId;
  }
}

/** Normalize a `GET /me/player/devices` entry into the plugin's shape. */
function deviceToJS(raw: unknown): SpotifyDevice {
  const device = raw as Record<string, unknown>;
  const result: SpotifyDevice = {
    id: typeof device.id === 'string' ? device.id : null,
    name: String(device.name ?? ''),
    type: String(device.type ?? ''),
    isActive: device.is_active === true,
    isPrivateSession: device.is_private_session === true,
    isRestricted: device.is_restricted === true,
  };
  if (typeof device.volume_percent === 'number') {
    result.volumePercent = device.volume_percent;
  }
  return result;
}

/**
 * The Web Playback SDK needs EME with Widevine, which most native webviews (and
 * some desktop builds) do not ship. Probing for it is the only reliable signal.
 */
async function probeWebPlaybackViable(): Promise<boolean> {
  if (typeof navigator === 'undefined' || typeof navigator.requestMediaKeySystemAccess !== 'function') {
    return false;
  }
  try {
    await navigator.requestMediaKeySystemAccess('com.widevine.alpha', [
      {
        initDataTypes: ['cenc'],
        audioCapabilities: [{ contentType: 'audio/mp4;codecs="mp4a.40.2"' }],
      },
    ]);
    return true;
  } catch {
    return false;
  }
}
