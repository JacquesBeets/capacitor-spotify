import type { AccessDiagnosis, SpotifyErrorCode } from '../definitions';

/** Matches the error-body limit the Web API clients use on every platform. */
const MESSAGE_LIMIT = 500;

/**
 * Reads a `GET /v1/me` response into an {@link AccessDiagnosis}.
 *
 * The wording here is shared with the iOS and Android implementations so
 * integrators comparing platforms compare like with like. Spotify's own text is
 * passed through untouched: on iOS two app-level `403`s are indistinguishable
 * from the native side, and one of them names the wrong setting, so the raw
 * message is the only reliable diagnosis.
 */
export function diagnosisFrom(status: number, body: string): AccessDiagnosis {
  if (status >= 200 && status < 300) {
    const profile = json(body);
    return {
      ok: true,
      message: 'Spotify accepted GET /v1/me — this app and account can use the Web API',
      httpStatus: status,
      ...(typeof profile?.id === 'string' ? { userId: profile.id } : {}),
      ...(typeof profile?.product === 'string' ? { product: profile.product } : {}),
    };
  }

  const reported = spotifyMessage(body);
  return {
    ok: false,
    message: reading(status, reported),
    code: codeFor(status, reported),
    httpStatus: status,
    ...(reported ? { spotifyMessage: reported } : {}),
  };
}

/** The probe never got an answer — no session, no network, or no plugin. */
export function diagnosisFailed(code: SpotifyErrorCode, message: string): AccessDiagnosis {
  return { ok: false, message, code };
}

function reading(status: number, reported: string): string {
  if (status === 401) {
    return 'Spotify rejected the access token — the session is no longer valid, call authorize() again';
  }
  if (status === 403) {
    return /owner/i.test(reported)
      ? 'Spotify is refusing this app: the account that owns your dashboard app has no active Premium subscription. ' +
          'That blocks every user of the app regardless of their own tier, and Spotify can take a few hours to ' +
          'allow requests again once the subscription is active.'
      : 'Spotify is refusing this account. Its message points at User Management, but non-owner accounts get that ' +
          "same text when the dashboard app owner's Premium subscription has lapsed — check the owner's " +
          "subscription first, then the app's User Management allowlist.";
  }
  if (status === 429) {
    return 'Spotify rate limited the probe — retry in a few seconds';
  }
  return `Spotify answered the probe with HTTP ${status}`;
}

/**
 * Same status-to-code mapping as `toApiError` in `./api`, so a diagnosis and a
 * real rejection agree about what went wrong.
 */
function codeFor(status: number, reported: string): SpotifyErrorCode {
  if (status === 401) {
    return 'NOT_AUTHENTICATED';
  }
  if (status === 403) {
    return /premium/i.test(reported) ? 'PREMIUM_REQUIRED' : 'USER_NOT_AUTHORIZED';
  }
  if (status === 429) {
    return 'RATE_LIMITED';
  }
  return 'UNKNOWN';
}

/**
 * Spotify wraps its reason in `{"error": {"status": …, "message": …}}`. Falls
 * back to the raw body, which is all a non-JSON error leaves behind.
 */
function spotifyMessage(body: string): string {
  const error = json(body)?.error as { message?: unknown } | undefined;
  const message = typeof error?.message === 'string' ? error.message : body;
  return message.slice(0, MESSAGE_LIMIT);
}

function json(body: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(body);
    return typeof parsed === 'object' && parsed !== null ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}
