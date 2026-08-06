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

    /** Maps an App Remote connection failure onto a `SpotifyErrorCode`. */
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
