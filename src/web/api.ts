import type { RepeatMode } from '../definitions';

import type { SpotifyAuth } from './auth';
import { errorMessage, spotifyError } from './errors';

const API_BASE = 'https://api.spotify.com/v1';

/**
 * The thinnest possible Spotify Web API client: only the calls the Web Playback
 * SDK cannot make itself (starting a URI, transferring playback, shuffle and
 * repeat) go through here. Everything else is a local SDK call.
 */
export class SpotifyWebApi {
  /** The device this client has already transferred playback to. */
  private activeDeviceId: string | null = null;

  constructor(private readonly auth: SpotifyAuth) {}

  /** Forget the transfer state, e.g. after a disconnect. */
  reset(): void {
    this.activeDeviceId = null;
  }

  /** Start playing `uri` on the SDK device, transferring playback if needed. */
  async play(deviceId: string, uri: string): Promise<void> {
    await this.ensureActiveDevice(deviceId);
    await this.webApi(`/me/player/play?device_id=${encodeURIComponent(deviceId)}`, {
      method: 'PUT',
      body: JSON.stringify(toPlayBody(uri)),
    });
  }

  async setShuffle(deviceId: string, enabled: boolean): Promise<void> {
    await this.webApi(`/me/player/shuffle?state=${enabled}&device_id=${encodeURIComponent(deviceId)}`, {
      method: 'PUT',
    });
  }

  async setRepeatMode(deviceId: string, repeatMode: RepeatMode): Promise<void> {
    // `off` | `track` | `context` are exactly the values the Web API expects.
    await this.webApi(`/me/player/repeat?state=${repeatMode}&device_id=${encodeURIComponent(deviceId)}`, {
      method: 'PUT',
    });
  }

  /**
   * A Web Playback SDK device is registered but inactive until playback is
   * transferred to it, so the first play has to claim it.
   */
  private async ensureActiveDevice(deviceId: string): Promise<void> {
    if (this.activeDeviceId === deviceId) {
      return;
    }
    await this.webApi('/me/player', {
      method: 'PUT',
      body: JSON.stringify({ device_ids: [deviceId], play: true }),
    });
    this.activeDeviceId = deviceId;
  }

  /**
   * Authorized `fetch` against the Web API.
   *
   * @param retry whether a `401` may be retried once with a forced token
   *   refresh; the retry itself runs with `retry` off.
   */
  private async webApi(path: string, init: RequestInit, retry = true): Promise<Response> {
    const token = await this.auth.getAccessToken({ forceRefresh: !retry });
    const headers: Record<string, string> = { Authorization: `Bearer ${token.accessToken}` };
    if (init.body !== undefined) {
      headers['Content-Type'] = 'application/json';
    }

    let response: Response;
    try {
      response = await fetch(`${API_BASE}${path}`, { ...init, headers });
    } catch (error) {
      throw spotifyError('OFFLINE', `The Spotify Web API is unreachable: ${errorMessage(error)}`);
    }

    // Every endpoint used here answers 204 No Content, so the body is never
    // read on success — parsing it would throw.
    if (response.ok) {
      return response;
    }
    if (response.status === 401 && retry) {
      return this.webApi(path, init, false);
    }
    throw await toApiError(response);
  }
}

/** Tracks and episodes are played as `uris`; everything else is a context. */
function toPlayBody(uri: string): Record<string, unknown> {
  return /^spotify:(track|episode):/.test(uri) ? { uris: [uri] } : { context_uri: uri };
}

async function toApiError(response: Response): Promise<Error> {
  const detail = await readBody(response);
  const suffix = detail ? `: ${detail}` : '';

  switch (response.status) {
    case 401:
      return spotifyError('NOT_AUTHENTICATED', `Spotify rejected the access token${suffix}`);
    case 403:
      return /premium/i.test(detail)
        ? spotifyError('PREMIUM_REQUIRED', `Spotify Premium is required for playback control${suffix}`)
        : spotifyError('USER_NOT_AUTHORIZED', `Spotify refused the request${suffix}`);
    case 404:
      return spotifyError(
        'NOT_ACTIVE_DEVICE',
        `Spotify has no active device for this request — reconnect the player${suffix}`,
      );
    case 429: {
      const retryAfter = response.headers.get('Retry-After');
      return spotifyError(
        'RATE_LIMITED',
        `Spotify rate limited the request. Retry after ${retryAfter ?? 'a few'} seconds${suffix}`,
      );
    }
    default:
      return spotifyError('UNKNOWN', `The Spotify Web API request failed (HTTP ${response.status})${suffix}`);
  }
}

async function readBody(response: Response): Promise<string> {
  try {
    // Never `.json()`: error bodies are not reliably JSON (and may be empty).
    const text = await response.text();
    return text.trim().slice(0, 500);
  } catch {
    return '';
  }
}
