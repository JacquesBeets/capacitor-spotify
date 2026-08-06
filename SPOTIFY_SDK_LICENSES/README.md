# Spotify iOS SDK — redistribution notice

This plugin vendors `ios/SpotifyiOS.xcframework`, taken verbatim from tag
[`v5.0.1`](https://github.com/spotify/ios-sdk/tree/v5.0.1) of
<https://github.com/spotify/ios-sdk>.

## Licensing of the Spotify iOS SDK itself

The `spotify/ios-sdk` repository ships **no** `LICENSE` or `NOTICE` file at any
tag, including `v5.0.1`. The SDK is a closed-source binary distributed by
Spotify AB and its use is governed by the
[Spotify Developer Terms of Service](https://developer.spotify.com/terms) and the
[Spotify Developer Policy](https://developer.spotify.com/policy).

By using this plugin you are using the Spotify iOS SDK and are bound by those
terms. In particular, you must register your own application in the
[Spotify Developer Dashboard](https://developer.spotify.com/dashboard) and use
your own client ID.

`SPOTIFY` and the Spotify logo are trademarks of Spotify AB. This plugin is not
affiliated with, endorsed by, or sponsored by Spotify AB.

## Third-party code bundled inside SpotifyiOS.xcframework

Spotify's repository ships one third-party license file, reproduced here:

| File                                     | Component     | License |
| ---------------------------------------- | ------------- | ------- |
| `SpotifyiOS-MPMessagePack-LICENSE.md`    | MPMessagePack | MIT     |

## The plugin's own license

The Capacitor plugin source code (everything outside
`ios/SpotifyiOS.xcframework` and `android/repo/`) is MIT licensed — see the
repository root.
