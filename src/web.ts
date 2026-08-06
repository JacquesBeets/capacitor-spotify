import { WebPlugin } from '@capacitor/core';

import type { SpotifyPlugin } from './definitions';

export class SpotifyWeb extends WebPlugin implements SpotifyPlugin {
  async echo(options: { value: string }): Promise<{ value: string }> {
    console.log('ECHO', options);
    return options;
  }
}
