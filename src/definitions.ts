export interface SpotifyPlugin {
  echo(options: { value: string }): Promise<{ value: string }>;
}
