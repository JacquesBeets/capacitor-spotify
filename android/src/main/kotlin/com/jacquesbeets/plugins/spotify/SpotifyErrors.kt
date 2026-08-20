package com.jacquesbeets.plugins.spotify

import com.spotify.android.appremote.api.error.AuthenticationFailedException
import com.spotify.android.appremote.api.error.CouldNotFindSpotifyApp
import com.spotify.android.appremote.api.error.NotLoggedInException
import com.spotify.android.appremote.api.error.OfflineModeException
import com.spotify.android.appremote.api.error.SpotifyConnectionTerminatedException
import com.spotify.android.appremote.api.error.SpotifyDisconnectedException
import com.spotify.android.appremote.api.error.UnsupportedFeatureVersionException
import com.spotify.android.appremote.api.error.UserNotAuthorizedException

/**
 * Error codes surfaced to JavaScript. These must stay in sync with the
 * `SpotifyErrorCode` union in `src/definitions.ts`.
 */
object SpotifyErrors {
    const val NOT_INITIALIZED = "NOT_INITIALIZED"
    const val NOT_AUTHENTICATED = "NOT_AUTHENTICATED"
    const val AUTH_CANCELLED = "AUTH_CANCELLED"
    const val AUTH_FAILED = "AUTH_FAILED"
    const val TOKEN_REFRESH_FAILED = "TOKEN_REFRESH_FAILED"
    const val SPOTIFY_APP_NOT_INSTALLED = "SPOTIFY_APP_NOT_INSTALLED"

    /** iOS only: `authorizeAndPlayURI` would not start an authorization attempt. */
    const val AUTHORIZE_AND_PLAY_REFUSED = "AUTHORIZE_AND_PLAY_REFUSED"

    const val NOT_CONNECTED = "NOT_CONNECTED"
    const val CONNECTION_FAILED = "CONNECTION_FAILED"
    const val PREMIUM_REQUIRED = "PREMIUM_REQUIRED"
    const val USER_NOT_AUTHORIZED = "USER_NOT_AUTHORIZED"
    const val UNSUPPORTED_VERSION = "UNSUPPORTED_VERSION"
    const val OFFLINE = "OFFLINE"
    const val NOT_ACTIVE_DEVICE = "NOT_ACTIVE_DEVICE"
    const val NOT_SUPPORTED = "NOT_SUPPORTED"
    const val PLAYBACK_FAILED = "PLAYBACK_FAILED"
    const val RATE_LIMITED = "RATE_LIMITED"
    const val UNKNOWN = "UNKNOWN"

    /**
     * Maps an App Remote connection failure onto a `SpotifyErrorCode`.
     *
     * [CouldNotFindSpotifyApp] means "no *usable* Spotify app", not simply "not
     * installed": the SDK's locator walks `com.spotify.music`, `.canary` and
     * `.partners`, and accepts one only when it has a launch intent (so the
     * `<queries>` entry must survive manifest merging on API 30+) *and* its
     * signing certificate matches Spotify's release fingerprints. A re-signed
     * or sideloaded Spotify build is therefore reported as missing.
     */
    fun mapConnectionError(throwable: Throwable): String = when (throwable) {
        is SpotifyException -> throwable.code
        is CouldNotFindSpotifyApp -> SPOTIFY_APP_NOT_INSTALLED
        is NotLoggedInException -> NOT_AUTHENTICATED
        is AuthenticationFailedException -> AUTH_FAILED
        is UserNotAuthorizedException -> USER_NOT_AUTHORIZED
        is UnsupportedFeatureVersionException -> UNSUPPORTED_VERSION
        is OfflineModeException -> OFFLINE
        is SpotifyDisconnectedException, is SpotifyConnectionTerminatedException -> NOT_CONNECTED
        // Includes SpotifyRemoteServiceException.
        else -> CONNECTION_FAILED
    }

    /**
     * Same mapping as [mapConnectionError] but with `PLAYBACK_FAILED` as the
     * fallback, for failures raised by a `PlayerApi`/`ConnectApi` call.
     */
    fun mapPlaybackError(throwable: Throwable): String = when (throwable) {
        is SpotifyException -> throwable.code
        is CouldNotFindSpotifyApp -> SPOTIFY_APP_NOT_INSTALLED
        is NotLoggedInException -> NOT_AUTHENTICATED
        is AuthenticationFailedException -> AUTH_FAILED
        is UserNotAuthorizedException -> USER_NOT_AUTHORIZED
        is UnsupportedFeatureVersionException -> UNSUPPORTED_VERSION
        is OfflineModeException -> OFFLINE
        is SpotifyDisconnectedException, is SpotifyConnectionTerminatedException -> NOT_CONNECTED
        else -> PLAYBACK_FAILED
    }
}

/** Internal failure carrying the `SpotifyErrorCode` to reject a plugin call with. */
class SpotifyException(val code: String, message: String) : Exception(message)
