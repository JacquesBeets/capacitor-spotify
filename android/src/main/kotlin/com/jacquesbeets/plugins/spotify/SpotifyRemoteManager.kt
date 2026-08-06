package com.jacquesbeets.plugins.spotify

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.spotify.android.appremote.api.ConnectionParams
import com.spotify.android.appremote.api.Connector
import com.spotify.android.appremote.api.PlayerApi
import com.spotify.android.appremote.api.SpotifyAppRemote
import com.spotify.protocol.client.CallResult
import com.spotify.protocol.client.Subscription
import com.spotify.protocol.types.PlayerContext
import com.spotify.protocol.types.PlayerState
import com.spotify.protocol.types.VolumeState

/**
 * Owns the App Remote connection, its player-state/context/volume
 * subscriptions and every playback command.
 *
 * All methods must be called from the main thread — the App Remote SDK
 * delivers its callbacks on the thread that created the connection.
 */
class SpotifyRemoteManager {

    private var appRemote: SpotifyAppRemote? = null
    private var playerStateSubscription: Subscription<PlayerState>? = null
    private var playerContextSubscription: Subscription<PlayerContext>? = null
    private var volumeSubscription: Subscription<VolumeState>? = null

    @Volatile
    private var lastPlayerState: PlayerState? = null

    @Volatile
    private var lastPlayerContext: PlayerContext? = null

    @Volatile
    private var lastVolume: Float? = null

    private val pendingVolumeCallbacks = mutableListOf<(Float?) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Invoked for every player-state (or context) update while connected. */
    var onPlayerState: ((PlayerState, PlayerContext?) -> Unit)? = null

    /** Invoked when a subscription fails and the remote is no longer connected. */
    var onConnectionLost: ((Throwable) -> Unit)? = null

    // region connection

    fun connect(
        context: Context,
        clientId: String,
        redirectUri: String,
        onSuccess: () -> Unit,
        onError: (Throwable) -> Unit,
    ) {
        if (isConnected()) {
            onSuccess()
            return
        }

        val params = ConnectionParams.Builder(clientId)
            .setRedirectUri(redirectUri)
            .showAuthView(true)
            .build()

        SpotifyAppRemote.connect(
            context,
            params,
            object : Connector.ConnectionListener {
                override fun onConnected(remote: SpotifyAppRemote) {
                    appRemote = remote
                    subscribe()
                    onSuccess()
                }

                override fun onFailure(error: Throwable) {
                    appRemote = null
                    onError(error)
                }
            },
        )
    }

    fun disconnect() {
        playerStateSubscription?.cancel()
        playerStateSubscription = null
        playerContextSubscription?.cancel()
        playerContextSubscription = null
        volumeSubscription?.cancel()
        volumeSubscription = null

        appRemote?.let { SpotifyAppRemote.disconnect(it) }
        appRemote = null

        lastPlayerState = null
        lastPlayerContext = null
        lastVolume = null
        flushVolumeCallbacks(null)
    }

    fun isConnected(): Boolean = appRemote?.isConnected == true

    private fun subscribe() {
        val remote = appRemote ?: return

        val stateSubscription = remote.playerApi.subscribeToPlayerState()
        stateSubscription.setEventCallback { state ->
            lastPlayerState = state
            emitPlayerState()
        }
        stateSubscription.setErrorCallback { handleSubscriptionError(it) }
        playerStateSubscription = stateSubscription

        val contextSubscription = remote.playerApi.subscribeToPlayerContext()
        contextSubscription.setEventCallback { playerContext ->
            lastPlayerContext = playerContext
            emitPlayerState()
        }
        contextSubscription.setErrorCallback { handleSubscriptionError(it) }
        playerContextSubscription = contextSubscription

        // Volume is only observable, so keep the latest value for getVolume().
        val volume = remote.connectApi.subscribeToVolumeState()
        volume.setEventCallback { volumeState ->
            val level = volumeState.mVolume
            lastVolume = level
            flushVolumeCallbacks(level)
        }
        volume.setErrorCallback { flushVolumeCallbacks(null) }
        volumeSubscription = volume
    }

    private fun emitPlayerState() {
        val state = lastPlayerState ?: return
        onPlayerState?.invoke(state, lastPlayerContext)
    }

    /**
     * A subscription error while the remote is still connected is transient; if
     * the remote is gone, tear down and report the lost connection instead of
     * silently going deaf.
     */
    private fun handleSubscriptionError(error: Throwable) {
        if (isConnected()) return
        disconnect()
        onConnectionLost?.invoke(error)
    }

    // endregion

    // region playback

    fun play(uri: String?, onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        val result = if (uri.isNullOrEmpty()) player.resume() else player.play(uri)
        bind(result, onSuccess, onError)
    }

    fun pause(onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        bind(player.pause(), onSuccess, onError)
    }

    fun resume(onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        bind(player.resume(), onSuccess, onError)
    }

    fun togglePlay(onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        val cached = lastPlayerState
        if (cached != null) {
            bind(if (cached.isPaused) player.resume() else player.pause(), onSuccess, onError)
            return
        }
        val stateResult = player.playerState
        stateResult.setResultCallback { state ->
            bind(if (state.isPaused) player.resume() else player.pause(), onSuccess, onError)
        }
        stateResult.setErrorCallback { onError(it) }
    }

    fun skipNext(onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        bind(player.skipNext(), onSuccess, onError)
    }

    fun skipPrevious(onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        bind(player.skipPrevious(), onSuccess, onError)
    }

    fun seekTo(positionMs: Long, onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        bind(player.seekTo(positionMs), onSuccess, onError)
    }

    fun setShuffle(enabled: Boolean, onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        bind(player.setShuffle(enabled), onSuccess, onError)
    }

    fun setRepeat(repeatMode: Int, onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        bind(player.setRepeat(repeatMode), onSuccess, onError)
    }

    fun getPlayerState(onSuccess: (PlayerState, PlayerContext?) -> Unit, onError: (Throwable) -> Unit) {
        val player = playerApi(onError) ?: return
        val result = player.playerState
        result.setResultCallback { state ->
            lastPlayerState = state
            onSuccess(state, lastPlayerContext)
        }
        result.setErrorCallback { onError(it) }
    }

    fun setVolume(volume: Float, onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        val remote = appRemote
        if (remote == null || !remote.isConnected) {
            onError(notConnected())
            return
        }
        val result = remote.connectApi.connectSetVolume(volume)
        result.setResultCallback {
            lastVolume = volume
            onSuccess()
        }
        result.setErrorCallback { onError(it) }
    }

    /**
     * Best-effort volume read: the App Remote SDK only exposes volume as a
     * subscription, so this returns the latest observed value or waits briefly
     * for the first event. `null` means the value is unavailable.
     */
    fun getVolume(callback: (Float?) -> Unit) {
        val cached = lastVolume
        if (cached != null) {
            callback(cached)
            return
        }
        if (!isConnected()) {
            callback(null)
            return
        }
        synchronized(pendingVolumeCallbacks) { pendingVolumeCallbacks.add(callback) }
        mainHandler.postDelayed({ flushVolumeCallbacks(lastVolume) }, VOLUME_TIMEOUT_MS)
    }

    // endregion

    // region internals

    private fun playerApi(onError: (Throwable) -> Unit): PlayerApi? {
        val remote = appRemote
        if (remote == null || !remote.isConnected) {
            onError(notConnected())
            return null
        }
        return remote.playerApi
    }

    private fun <T> bind(result: CallResult<T>, onSuccess: () -> Unit, onError: (Throwable) -> Unit) {
        result.setResultCallback { onSuccess() }
        result.setErrorCallback { onError(it) }
    }

    private fun flushVolumeCallbacks(volume: Float?) {
        val callbacks = synchronized(pendingVolumeCallbacks) {
            if (pendingVolumeCallbacks.isEmpty()) return
            val copy = pendingVolumeCallbacks.toList()
            pendingVolumeCallbacks.clear()
            copy
        }
        callbacks.forEach { it(volume) }
    }

    private fun notConnected() = SpotifyException(
        SpotifyErrors.NOT_CONNECTED,
        "Not connected to the Spotify app. Call connect() first.",
    )

    // endregion

    private companion object {
        const val VOLUME_TIMEOUT_MS = 3_000L
    }
}
