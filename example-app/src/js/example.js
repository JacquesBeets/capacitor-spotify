import { Capacitor } from '@capacitor/core';
import { Spotify } from '@jacquesbeets/capacitor-spotify';

import { CLIENT_ID, REDIRECT_URI_NATIVE, REDIRECT_URI_WEB } from './config.js';

const REDIRECT_URI = Capacitor.getPlatform() === 'web' ? REDIRECT_URI_WEB : REDIRECT_URI_NATIVE;

const logEl = document.getElementById('log');
const statusEl = document.getElementById('status');
const trackEl = document.getElementById('track');

function log(message, data) {
  const line = document.createElement('div');
  const time = new Date().toLocaleTimeString();
  line.textContent = data !== undefined ? `[${time}] ${message} ${JSON.stringify(data)}` : `[${time}] ${message}`;
  logEl.prepend(line);
}

function setStatus(text) {
  statusEl.textContent = text;
}

async function run(label, fn) {
  try {
    const result = await fn();
    log(`${label} ✓`, result);
    return result;
  } catch (err) {
    log(`${label} ✗ [${err.code ?? 'UNKNOWN'}] ${err.message ?? err}`);
    throw err;
  }
}

async function setup() {
  await run('initialize', () =>
    Spotify.initialize({
      clientId: CLIENT_ID,
      redirectUri: REDIRECT_URI,
      playerName: 'Capacitor Spotify Example',
      // Manual test bed: log the iOS SDK's own connect diagnostics too.
      debug: true,
    }),
  );

  const caps = await run('getCapabilities', () => Spotify.getCapabilities());
  setStatus(`platform=${caps.platform} · webPlaybackViable=${caps.webPlaybackViable}`);

  await Spotify.addListener('playerStateChanged', (state) => {
    trackEl.textContent = state.track
      ? `${state.paused ? '⏸' : '▶️'} ${state.track.name} — ${state.track.artistName} (${Math.round(state.positionMs / 1000)}s / ${Math.round(state.track.durationMs / 1000)}s)`
      : 'Nothing playing';
  });
  await Spotify.addListener('connectionStateChanged', (ev) => {
    log('connectionStateChanged', ev);
    setStatus(ev.connected ? `connected${ev.deviceId ? ` (device ${ev.deviceId})` : ''}` : `disconnected (${ev.reason ?? ''})`);
  });
  await Spotify.addListener('authStateChanged', (ev) => log('authStateChanged', ev));
}

// Wire up buttons
const actions = {
  authorize: () => Spotify.authorize(),
  getAccessToken: () => Spotify.getAccessToken(),
  logout: () => Spotify.logout(),
  isSpotifyAppInstalled: () => Spotify.isSpotifyAppInstalled(),
  diagnoseAccess: () => Spotify.diagnoseAccess(),
  connect: () => Spotify.connect({ playUri: '' }),
  disconnect: () => Spotify.disconnect(),
  play: () => Spotify.play({ uri: document.getElementById('uriInput').value || undefined }),
  resume: () => Spotify.resume(),
  pause: () => Spotify.pause(),
  togglePlay: () => Spotify.togglePlay(),
  skipNext: () => Spotify.skipNext(),
  skipPrevious: () => Spotify.skipPrevious(),
  seekTo: () => Spotify.seekTo({ positionMs: 30000 }),
  shuffleOn: () => Spotify.setShuffle({ enabled: true }),
  shuffleOff: () => Spotify.setShuffle({ enabled: false }),
  repeatContext: () => Spotify.setRepeatMode({ repeatMode: 'context' }),
  repeatOff: () => Spotify.setRepeatMode({ repeatMode: 'off' }),
  volumeHalf: () => Spotify.setVolume({ volume: 0.5 }),
  getPlayerState: () => Spotify.getPlayerState(),
  getUserCapabilities: () => Spotify.getUserCapabilities(),
  addToQueue: () => Spotify.addToQueue({ uri: 'spotify:track:4uLU6hMCjMI75M1A2tKUQC' }),
  getDevices: () => Spotify.getDevices(),
  transferToFirstOther: async () => {
    const { devices } = await Spotify.getDevices();
    const target = devices.find((d) => !d.isActive && d.id && !d.isRestricted);
    if (!target) throw new Error('no other targetable device found');
    await Spotify.transferPlayback({ deviceId: target.id, play: true });
    return { transferredTo: target.name };
  },
  getImage: async () => {
    const state = await Spotify.getPlayerState();
    if (!state.track?.imageUri) throw new Error('no track image available');
    const { dataUrl } = await Spotify.getImage({ imageId: state.track.imageUri, width: 360 });
    document.getElementById('albumArt').src = dataUrl;
    return { bytes: dataUrl.length };
  },
};

for (const [name, fn] of Object.entries(actions)) {
  const btn = document.querySelector(`[data-action="${name}"]`);
  if (btn) btn.addEventListener('click', () => run(name, fn).catch(() => undefined));
}

log(`running on ${Capacitor.getPlatform()}`);
if (CLIENT_ID === 'YOUR_SPOTIFY_CLIENT_ID') {
  setStatus('⚠️ Set CLIENT_ID and REDIRECT_URI in src/js/config.js first');
  log('Edit example-app/src/js/config.js with your Spotify app credentials');
} else {
  setup().catch(() => undefined);
}
