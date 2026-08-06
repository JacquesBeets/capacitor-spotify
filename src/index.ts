import { registerPlugin } from '@capacitor/core';

import type { SpotifyPlugin } from './definitions';

const Spotify = registerPlugin<SpotifyPlugin>('Spotify', {
  web: () => import('./web').then((m) => new m.SpotifyWeb()),
});

export * from './definitions';
export { Spotify };
