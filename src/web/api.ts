import type { AccessDiagnosis, RepeatMode } from '../definitions';

import type { SpotifyAuth } from './auth';
import { diagnosisFailed, diagnosisFrom } from './diagnosis';
import { errorCode, errorMessage, spotifyError } from './errors';

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

  async addToQueue(uri: string): Promise<void> {
    await this.webApi(`/me/player/queue?uri=${encodeURIComponent(uri)}`, { method: 'POST' });
  }

  async getDevices(): Promise<unknown[]> {
    const response = await this.webApi('/me/player/devices', { method: 'GET' });
    const payload = (await response.json()) as { devices?: unknown[] };
    return payload.devices ?? [];
  }

  async transferPlayback(deviceId: string, play: boolean): Promise<void> {
    await this.webApi('/me/player', {
      method: 'PUT',
      body: JSON.stringify({ device_ids: [deviceId], play }),
    });
    this.activeDeviceId = deviceId;
  }

  /**
   * `GET /me`, reported rather than mapped: *which* `403` Spotify sends is the
   * whole diagnosis, and `toApiError` throws that text away. Never throws — a
   * missing session or a dead network is itself part of the answer.
   */
  async probeAccess(): Promise<AccessDiagnosis> {
    let response: Response;
    try {
      response = await this.rawGet('/me');
    } catch (error) {
      return diagnosisFailed(errorCode(error) ?? 'UNKNOWN', errorMessage(error));
    }
    return diagnosisFrom(response.status, await readWholeBody(response));
  }

  /** `GET /me`, for subscription inference when the SDK is not connected. */
  async getProfile(): Promise<{ product?: string }> {
    const response = await this.webApi('/me', { method: 'GET' });
    return (await response.json()) as { product?: string };
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
   * Authorized `GET` that hands back the response whatever its status, so the
   * caller can read Spotify's own message. A `401` still earns one
   * forced-refresh retry, so a merely stale token is not reported as a problem
   * with the app.
   */
  private async rawGet(path: string, retry = true): Promise<Response> {
    const token = await this.auth.getAccessToken({ forceRefresh: !retry });
    let response: Response;
    try {
      response = await fetch(`${API_BASE}${path}`, {
        method: 'GET',
        headers: { Authorization: `Bearer ${token.accessToken}` },
      });
    } catch (error) {
      throw spotifyError('OFFLINE', `The Spotify Web API is unreachable: ${errorMessage(error)}`);
    }
    if (response.status === 401 && retry) {
      return this.rawGet(path, false);
    }
    return response;
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

/**
 * Unlike `readBody`, keeps the whole payload: a truncated `/me` body is not
 * parseable JSON, and the diagnosis trims what it shows the caller.
 */
async function readWholeBody(response: Response): Promise<string> {
  try {
    return (await response.text()).trim();
  } catch {
    return '';
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
