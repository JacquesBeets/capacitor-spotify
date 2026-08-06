// Fill in your own Spotify app credentials from
// https://developer.spotify.com/dashboard — see the plugin README for the
// full dashboard setup (redirect URIs, package name / bundle ID, user allowlist).
export const CLIENT_ID = 'YOUR_SPOTIFY_CLIENT_ID';

// Register BOTH of these in the dashboard. Native uses a custom scheme;
// web uses a page of the app itself (Spotify does not allow "localhost").
export const REDIRECT_URI_NATIVE = 'capacitor-spotify-example://callback';
export const REDIRECT_URI_WEB = 'http://127.0.0.1:5173/callback';
