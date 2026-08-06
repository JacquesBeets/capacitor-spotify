import type { SpotifyErrorCode } from '../definitions';

/**
 * Error thrown by every rejection of the web implementation.
 *
 * Mirrors the native platforms, where rejections arrive as `{ message, code }`,
 * so apps can always switch on `error.code`.
 */
export class SpotifyWebError extends Error {
  readonly code: SpotifyErrorCode;

  constructor(code: SpotifyErrorCode, message: string) {
    super(message);
    this.name = 'SpotifyWebError';
    this.code = code;
  }
}

/** Create a {@link SpotifyWebError}. */
export function spotifyError(code: SpotifyErrorCode, message: string): SpotifyWebError {
  return new SpotifyWebError(code, message);
}

/** The {@link SpotifyErrorCode} of a thrown value, when it is one of ours. */
export function errorCode(error: unknown): SpotifyErrorCode | null {
  return error instanceof SpotifyWebError ? error.code : null;
}

/** Best-effort human readable message for an unknown thrown value. */
export function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return typeof error === 'string' ? error : String(error);
}
