import type {
  AccessToken,
  AuthStateChange,
  AuthorizeOptions,
  InitializeOptions,
  SpotifyErrorCode,
} from '../definitions';

import { errorCode, errorMessage, spotifyError } from './errors';

const AUTHORIZE_ENDPOINT = 'https://accounts.spotify.com/authorize';
const TOKEN_ENDPOINT = 'https://accounts.spotify.com/api/token';

/** Where the in-flight PKCE challenge lives while the browser is at Spotify. */
const PKCE_STORAGE_KEY = 'capacitor_spotify.pkce';
/** Where the session lives between page loads. */
const TOKEN_STORAGE_KEY = 'capacitor_spotify.tokens';

/** Scopes required for Web Playback SDK streaming plus remote control. */
const DEFAULT_SCOPES = [
  'app-remote-control',
  'streaming',
  'user-modify-playback-state',
  'user-read-playback-state',
  'user-read-currently-playing',
];

/** Unreserved characters, per RFC 7636 §4.1. */
const VERIFIER_CHARSET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
/** Anything from 43 to 128 characters is a valid `code_verifier`. */
const VERIFIER_LENGTH = 96;
const STATE_LENGTH = 24;

/** Refresh the access token when less than this much life is left. */
const EXPIRY_MARGIN_MS = 60_000;

interface AuthConfig {
  clientId: string;
  redirectUri: string;
  scopes: string[];
}

interface StoredTokens {
  accessToken: string;
  refreshToken?: string;
  /** Epoch milliseconds. */
  expiresAt: number;
  scopes?: string[];
}

interface PkceStash {
  verifier: string;
  state: string;
}

interface TokenEndpointResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  refresh_token?: string;
  scope?: string;
}

/**
 * Authorization Code + PKCE for the browser: no client secret, no server.
 *
 * The interactive step is a full-page redirect, so a grant spans two page
 * loads: {@link SpotifyAuth.authorize} leaves for Spotify and
 * {@link SpotifyAuth.completeRedirect} (driven by `initialize()`) picks the
 * `?code=` back up when the browser returns.
 */
export class SpotifyAuth {
  private config: AuthConfig | null = null;
  private inFlightRefresh: Promise<AccessToken> | null = null;
  private pendingAuthorize: { resolve: (token: AccessToken) => void; reject: (error: unknown) => void } | null = null;

  constructor(private readonly emitAuthState: (event: AuthStateChange) => void) {}

  /** Apply (or re-apply) the configuration from `initialize()`. */
  configure(options: InitializeOptions): void {
    this.config = {
      clientId: options.clientId,
      redirectUri: options.redirectUri,
      scopes: options.scopes?.length ? options.scopes : DEFAULT_SCOPES,
    };
  }

  /**
   * Start the interactive grant by redirecting the current window to Spotify.
   *
   * The returned promise cannot settle in this document — the page is being torn
   * down. It is settled in the next page load by {@link completeRedirect}, which
   * also emits `authStateChanged`; apps should rely on that event (or simply
   * call {@link getAccessToken}) after `initialize()`.
   */
  async authorize(options?: AuthorizeOptions): Promise<AccessToken> {
    const config = this.requireConfig();
    const verifier = randomString(VERIFIER_LENGTH);
    const state = randomString(STATE_LENGTH);
    const challenge = await codeChallenge(verifier);

    writeJson<PkceStash>('session', PKCE_STORAGE_KEY, { verifier, state });

    const scopes = options?.scopes?.length ? options.scopes : config.scopes;
    const params = new URLSearchParams({
      client_id: config.clientId,
      response_type: 'code',
      redirect_uri: config.redirectUri,
      code_challenge_method: 'S256',
      code_challenge: challenge,
      scope: scopes.join(' '),
      state,
    });
    if (options?.showDialog) {
      params.set('show_dialog', 'true');
    }

    const pending = new Promise<AccessToken>((resolve, reject) => {
      this.pendingAuthorize = { resolve, reject };
    });
    window.location.assign(`${AUTHORIZE_ENDPOINT}?${params.toString()}`);
    return pending;
  }

  /**
   * Finish a grant when the current URL is an OAuth callback. No-op otherwise,
   * which makes it safe to call on every `initialize()`.
   *
   * Rejects (so `initialize()` rejects) when the callback carries an error or
   * fails verification — otherwise a denied grant would be silently lost, since
   * the `authorize()` promise died with the previous page.
   */
  async completeRedirect(): Promise<void> {
    const url = new URL(window.location.href);
    const code = url.searchParams.get('code');
    const state = url.searchParams.get('state');
    const oauthError = url.searchParams.get('error');
    if (!code && !oauthError) {
      return;
    }
    // Read before stripping: stripOAuthParams() mutates these search params.
    const description = url.searchParams.get('error_description');

    const stash = readJson<PkceStash>('session', PKCE_STORAGE_KEY);
    removeItem('session', PKCE_STORAGE_KEY);
    stripOAuthParams(url);

    if (oauthError) {
      throw this.failAuthorize(
        oauthError === 'access_denied' ? 'AUTH_CANCELLED' : 'AUTH_FAILED',
        oauthError === 'access_denied'
          ? 'The Spotify authorization request was denied.'
          : `Spotify authorization failed: ${description ?? oauthError}`,
      );
    }
    if (!code) {
      throw this.failAuthorize('AUTH_FAILED', 'The Spotify redirect carried no authorization code.');
    }
    if (!stash || !state || stash.state !== state) {
      throw this.failAuthorize(
        'AUTH_FAILED',
        'The Spotify redirect could not be verified (OAuth state mismatch). Start authorize() again.',
      );
    }

    const config = this.requireConfig();
    let tokens: StoredTokens;
    try {
      tokens = await this.exchangeCode(code, stash.verifier, config);
    } catch (error) {
      throw this.failAuthorize(errorCode(error) ?? 'AUTH_FAILED', errorMessage(error));
    }

    this.writeTokens(tokens);
    const token = toAccessToken(tokens);
    this.emitAuthState({ authenticated: true, expiresAt: tokens.expiresAt });

    const pending = this.pendingAuthorize;
    this.pendingAuthorize = null;
    pending?.resolve(token);
  }

  /** A usable access token, refreshed when it is about to expire. */
  async getAccessToken(options?: { forceRefresh?: boolean }): Promise<AccessToken> {
    const tokens = this.readTokens();
    if (!tokens) {
      throw spotifyError('NOT_AUTHENTICATED', 'There is no Spotify session. Call authorize() first.');
    }

    const stillUsable = tokens.expiresAt - Date.now() > EXPIRY_MARGIN_MS;
    if (stillUsable && !options?.forceRefresh) {
      return toAccessToken(tokens);
    }

    if (!tokens.refreshToken) {
      if (stillUsable) {
        throw spotifyError(
          'TOKEN_REFRESH_FAILED',
          'The stored Spotify session has no refresh token, so it cannot be refreshed.',
        );
      }
      this.clearSession();
      this.emitAuthState({ authenticated: false });
      throw spotifyError(
        'NOT_AUTHENTICATED',
        'The Spotify session expired and has no refresh token. Call authorize() again.',
      );
    }

    return this.refresh(tokens.refreshToken);
  }

  /** Drop the stored session. */
  async logout(): Promise<void> {
    this.clearSession();
    this.emitAuthState({ authenticated: false });
  }

  private requireConfig(): AuthConfig {
    if (!this.config) {
      throw spotifyError('NOT_INITIALIZED', 'Call initialize() before using the Spotify plugin.');
    }
    return this.config;
  }

  /** Reject an in-flight `authorize()` and return the error to throw. */
  private failAuthorize(code: SpotifyErrorCode, message: string): Error {
    const error = spotifyError(code, message);
    this.emitAuthState({ authenticated: false });
    const pending = this.pendingAuthorize;
    this.pendingAuthorize = null;
    pending?.reject(error);
    return error;
  }

  /** Single-flight so a burst of callers triggers exactly one refresh. */
  private refresh(refreshToken: string): Promise<AccessToken> {
    if (this.inFlightRefresh) {
      return this.inFlightRefresh;
    }
    const attempt = this.runRefresh(refreshToken);
    this.inFlightRefresh = attempt;
    const clear = () => {
      if (this.inFlightRefresh === attempt) {
        this.inFlightRefresh = null;
      }
    };
    // `Promise.prototype.finally` is ES2018; this library targets ES2017.
    attempt.then(clear, clear);
    return attempt;
  }

  private async runRefresh(refreshToken: string): Promise<AccessToken> {
    const config = this.requireConfig();
    let response: TokenEndpointResponse;
    try {
      response = await this.postToken(
        new URLSearchParams({
          grant_type: 'refresh_token',
          refresh_token: refreshToken,
          client_id: config.clientId,
        }),
        'TOKEN_REFRESH_FAILED',
      );
    } catch (error) {
      if (errorCode(error) === 'OFFLINE') {
        // A network blip must not cost the user their session.
        throw error;
      }
      this.clearSession();
      this.emitAuthState({ authenticated: false });
      throw spotifyError('TOKEN_REFRESH_FAILED', `Refreshing the Spotify access token failed: ${errorMessage(error)}`);
    }

    const tokens: StoredTokens = {
      ...toStoredTokens(response),
      // Spotify rotates refresh tokens; keep the new one when it sends one.
      refreshToken: response.refresh_token ?? refreshToken,
    };
    this.writeTokens(tokens);
    this.emitAuthState({ authenticated: true, expiresAt: tokens.expiresAt });
    return toAccessToken(tokens);
  }

  private async exchangeCode(code: string, verifier: string, config: AuthConfig): Promise<StoredTokens> {
    const response = await this.postToken(
      new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: config.redirectUri,
        client_id: config.clientId,
        code_verifier: verifier,
      }),
      'AUTH_FAILED',
    );
    return toStoredTokens(response);
  }

  private async postToken(body: URLSearchParams, failureCode: SpotifyErrorCode): Promise<TokenEndpointResponse> {
    let response: Response;
    try {
      response = await fetch(TOKEN_ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body,
      });
    } catch (error) {
      throw spotifyError('OFFLINE', `The Spotify accounts service is unreachable: ${errorMessage(error)}`);
    }

    if (!response.ok) {
      const detail = await readBody(response);
      throw spotifyError(
        response.status === 429 ? 'RATE_LIMITED' : failureCode,
        `The Spotify token request failed (HTTP ${response.status})${detail ? `: ${detail}` : ''}`,
      );
    }

    return (await response.json()) as TokenEndpointResponse;
  }

  private readTokens(): StoredTokens | null {
    const tokens = readJson<StoredTokens>('local', TOKEN_STORAGE_KEY);
    return tokens?.accessToken ? tokens : null;
  }

  private writeTokens(tokens: StoredTokens): void {
    writeJson('local', TOKEN_STORAGE_KEY, tokens);
  }

  private clearSession(): void {
    removeItem('local', TOKEN_STORAGE_KEY);
    removeItem('session', PKCE_STORAGE_KEY);
  }
}

function toStoredTokens(response: TokenEndpointResponse): StoredTokens {
  return {
    accessToken: response.access_token,
    refreshToken: response.refresh_token,
    expiresAt: Date.now() + response.expires_in * 1000,
    scopes: response.scope ? response.scope.split(' ').filter(Boolean) : undefined,
  };
}

function toAccessToken(tokens: StoredTokens): AccessToken {
  return {
    accessToken: tokens.accessToken,
    expiresAt: tokens.expiresAt,
    scopes: tokens.scopes,
    tokenType: 'Bearer',
  };
}

/** Remove the OAuth parameters from the address bar without reloading. */
function stripOAuthParams(url: URL): void {
  for (const key of ['code', 'state', 'error', 'error_description']) {
    url.searchParams.delete(key);
  }
  try {
    window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
  } catch {
    /* Not fatal: the URL simply keeps its query string. */
  }
}

/** Cryptographically random string over {@link VERIFIER_CHARSET}. */
function randomString(length: number): string {
  // Reject the tail of the byte range so every character is equally likely.
  const ceiling = 256 - (256 % VERIFIER_CHARSET.length);
  let out = '';
  while (out.length < length) {
    const bytes = new Uint8Array(length - out.length);
    window.crypto.getRandomValues(bytes);
    for (const byte of bytes) {
      if (byte < ceiling) {
        out += VERIFIER_CHARSET.charAt(byte % VERIFIER_CHARSET.length);
      }
    }
  }
  return out;
}

/** `base64url(SHA-256(verifier))`, as required for `code_challenge_method=S256`. */
async function codeChallenge(verifier: string): Promise<string> {
  const digest = await window.crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  const bytes = new Uint8Array(digest);
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return window.btoa(binary).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
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

type StorageKind = 'local' | 'session';

function readJson<T>(kind: StorageKind, key: string): T | null {
  const raw = safeStorage(kind, (store) => store.getItem(key));
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

function writeJson<T>(kind: StorageKind, key: string, value: T): void {
  safeStorage(kind, (store) => store.setItem(key, JSON.stringify(value)));
}

function removeItem(kind: StorageKind, key: string): void {
  safeStorage(kind, (store) => store.removeItem(key));
}

/**
 * Reaching for Web Storage — let alone using it — throws in some privacy modes
 * and sandboxed iframes; degrade to a no-op instead of crashing the plugin.
 */
function safeStorage<T>(kind: StorageKind, use: (store: Storage) => T): T | null {
  try {
    return use(kind === 'local' ? window.localStorage : window.sessionStorage);
  } catch {
    return null;
  }
}
