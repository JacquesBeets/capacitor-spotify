package com.jacquesbeets.plugins.spotify

import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.activity.result.ActivityResult
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.ActivityCallback
import com.getcapacitor.annotation.CapacitorPlugin
import com.spotify.protocol.types.Image
import java.net.URLEncoder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

@CapacitorPlugin(name = "Spotify")
class SpotifyPlugin : Plugin() {

    private lateinit var authManager: SpotifyAuthManager
    private lateinit var webApi: SpotifyWebApi
    private val remoteManager = SpotifyRemoteManager()

    /** Auth and token work is blocking; keep it off the bridge thread. */
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile
    private var initialized = false

    @Volatile
    private var clientId: String? = null

    @Volatile
    private var redirectUri: String? = null

    /** Set when the App Remote connection was dropped because the app backgrounded. */
    @Volatile
    private var reconnectOnStart = false

    override fun load() {
        authManager = SpotifyAuthManager(context)
        webApi = SpotifyWebApi(authManager, executor)
        remoteManager.onPlayerState = { state, playerContext ->
            notifyListeners(EVENT_PLAYER_STATE, PlayerStateMapper.toJSObject(state, playerContext))
        }
        remoteManager.onConnectionLost = { error ->
            reconnectOnStart = false
            emitConnectionError(
                SpotifyErrors.mapConnectionError(error),
                error.message ?: "The connection to the Spotify app was lost.",
            )
        }
    }

    // region setup

    @PluginMethod
    fun initialize(call: PluginCall) {
        val clientId = call.getString("clientId")
        if (clientId.isNullOrBlank()) {
            call.reject("initialize() requires a clientId.", SpotifyErrors.NOT_INITIALIZED)
            return
        }
        val redirectUri = call.getString("redirectUri")
        if (redirectUri.isNullOrBlank()) {
            call.reject("initialize() requires a redirectUri.", SpotifyErrors.NOT_INITIALIZED)
            return
        }

        this.clientId = clientId
        this.redirectUri = redirectUri
        authManager.configure(clientId, redirectUri, stringList(call.getArray("scopes")))
        initialized = true
        call.resolve()
    }

    @PluginMethod
    fun isSpotifyAppInstalled(call: PluginCall) {
        call.resolve(JSObject().put("installed", isSpotifyInstalled()))
    }

    @PluginMethod
    fun getCapabilities(call: PluginCall) {
        val result = JSObject()
        result.put("platform", "android")
        result.put("requiresSpotifyApp", true)
        result.put("requiresPremium", false)
        result.put("canSetVolume", true)
        // Best-effort: read back from the App Remote volume-state subscription.
        result.put("canGetVolume", true)
        result.put("webPlaybackViable", false)
        call.resolve(result)
    }

    // endregion

    // region authorization

    @PluginMethod
    fun authorize(call: PluginCall) {
        if (!requireInitialized(call)) return
        val scopes = stringList(call.getArray("scopes"))
        val showDialog = call.getBoolean("showDialog", false) ?: false
        try {
            val intent = authManager.buildLoginIntent(activity, scopes, showDialog)
            startActivityForResult(call, intent, "onAuthResult")
        } catch (e: SpotifyException) {
            call.reject(e.message ?: "Could not start Spotify authorization.", e.code)
        } catch (e: Exception) {
            call.reject(e.message ?: "Could not start Spotify authorization.", SpotifyErrors.AUTH_FAILED)
        }
    }

    @ActivityCallback
    private fun onAuthResult(call: PluginCall?, result: ActivityResult) {
        if (call == null) return
        executor.execute {
            try {
                val session = authManager.handleAuthResponse(result.resultCode, result.data)
                emitAuthState()
                call.resolve(sessionToJSObject(session))
            } catch (e: SpotifyException) {
                emitAuthState()
                call.reject(e.message ?: "Spotify authorization failed.", e.code)
            } catch (e: Exception) {
                emitAuthState()
                call.reject(e.message ?: "Spotify authorization failed.", SpotifyErrors.AUTH_FAILED)
            }
        }
    }

    @PluginMethod
    fun getAccessToken(call: PluginCall) {
        if (!requireInitialized(call)) return
        val forceRefresh = call.getBoolean("forceRefresh", false) ?: false
        executor.execute {
            try {
                val session = authManager.getAccessToken(forceRefresh)
                if (session.renewed) emitAuthState()
                call.resolve(sessionToJSObject(session))
            } catch (e: SpotifyException) {
                emitAuthState()
                call.reject(e.message ?: "Could not get a Spotify access token.", e.code)
            } catch (e: Exception) {
                call.reject(e.message ?: "Could not get a Spotify access token.", SpotifyErrors.UNKNOWN)
            }
        }
    }

    @PluginMethod
    fun logout(call: PluginCall) {
        if (!requireInitialized(call)) return
        runOnMain {
            val wasConnected = remoteManager.isConnected()
            remoteManager.disconnect()
            reconnectOnStart = false
            if (wasConnected) emitConnectionState(false, REASON_DISCONNECT)
            executor.execute {
                authManager.logout()
                emitAuthState()
                call.resolve()
            }
        }
    }

    // endregion

    // region connection

    @PluginMethod
    fun connect(call: PluginCall) {
        if (!requireInitialized(call)) return
        val clientId = this.clientId
        val redirectUri = this.redirectUri
        if (clientId == null || redirectUri == null) {
            call.reject("Call initialize() before connect().", SpotifyErrors.NOT_INITIALIZED)
            return
        }
        runOnMain {
            remoteManager.connect(
                context,
                clientId,
                redirectUri,
                onSuccess = {
                    reconnectOnStart = false
                    emitConnectionState(true, REASON_CONNECT)
                    call.resolve()
                },
                onError = { error ->
                    val code = SpotifyErrors.mapConnectionError(error)
                    val message = error.message ?: "Could not connect to the Spotify app."
                    emitConnectionError(code, message)
                    call.reject(message, code)
                },
            )
        }
    }

    @PluginMethod
    fun disconnect(call: PluginCall) {
        runOnMain {
            val wasConnected = remoteManager.isConnected()
            remoteManager.disconnect()
            reconnectOnStart = false
            if (wasConnected) emitConnectionState(false, REASON_DISCONNECT)
            call.resolve()
        }
    }

    @PluginMethod
    fun isConnected(call: PluginCall) {
        call.resolve(JSObject().put("connected", remoteManager.isConnected()))
    }

    // endregion

    // region playback

    @PluginMethod
    fun play(call: PluginCall) {
        if (!requireInitialized(call)) return
        val uri = call.getString("uri")
        runOnMain { remoteManager.play(uri, { call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun pause(call: PluginCall) {
        if (!requireInitialized(call)) return
        runOnMain { remoteManager.pause({ call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun resume(call: PluginCall) {
        if (!requireInitialized(call)) return
        runOnMain { remoteManager.resume({ call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun togglePlay(call: PluginCall) {
        if (!requireInitialized(call)) return
        runOnMain { remoteManager.togglePlay({ call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun skipNext(call: PluginCall) {
        if (!requireInitialized(call)) return
        runOnMain { remoteManager.skipNext({ call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun skipPrevious(call: PluginCall) {
        if (!requireInitialized(call)) return
        runOnMain { remoteManager.skipPrevious({ call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun seekTo(call: PluginCall) {
        if (!requireInitialized(call)) return
        // The bridge delivers JS numbers as Integer, Long or Double depending on
        // magnitude — PluginCall.getLong() only matches Long, so coerce manually.
        val positionMs = (call.data.opt("positionMs") as? Number)?.toLong()
        if (positionMs == null || positionMs < 0) {
            call.reject("seekTo() requires a positionMs of 0 or greater.", SpotifyErrors.UNKNOWN)
            return
        }
        runOnMain { remoteManager.seekTo(positionMs, { call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun setShuffle(call: PluginCall) {
        if (!requireInitialized(call)) return
        val enabled = call.getBoolean("enabled")
        if (enabled == null) {
            call.reject("setShuffle() requires an enabled boolean.", SpotifyErrors.UNKNOWN)
            return
        }
        runOnMain { remoteManager.setShuffle(enabled, { call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun setRepeatMode(call: PluginCall) {
        if (!requireInitialized(call)) return
        val repeatMode = PlayerStateMapper.repeatModeToInt(call.getString("repeatMode"))
        if (repeatMode == null) {
            call.reject("setRepeatMode() requires 'off', 'track' or 'context'.", SpotifyErrors.UNKNOWN)
            return
        }
        runOnMain { remoteManager.setRepeat(repeatMode, { call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun setVolume(call: PluginCall) {
        if (!requireInitialized(call)) return
        val volume = (call.data.opt("volume") as? Number)?.toFloat()
        if (volume == null || volume < 0f || volume > 1f) {
            call.reject("setVolume() requires a volume between 0.0 and 1.0.", SpotifyErrors.UNKNOWN)
            return
        }
        runOnMain { remoteManager.setVolume(volume, { call.resolve() }, { rejectPlayback(call, it) }) }
    }

    @PluginMethod
    fun getVolume(call: PluginCall) {
        if (!requireInitialized(call)) return
        runOnMain {
            if (!remoteManager.isConnected()) {
                call.reject("Not connected to the Spotify app. Call connect() first.", SpotifyErrors.NOT_CONNECTED)
                return@runOnMain
            }
            remoteManager.getVolume { volume ->
                if (volume == null) {
                    call.reject(
                        "The Spotify app did not report a volume level. getVolume() is best-effort on Android.",
                        SpotifyErrors.NOT_SUPPORTED,
                    )
                } else {
                    call.resolve(JSObject().put("volume", volume.toDouble()))
                }
            }
        }
    }

    @PluginMethod
    fun getPlayerState(call: PluginCall) {
        if (!requireInitialized(call)) return
        runOnMain {
            remoteManager.getPlayerState(
                { state, playerContext -> call.resolve(PlayerStateMapper.toJSObject(state, playerContext)) },
                { rejectPlayback(call, it) },
            )
        }
    }

    @PluginMethod
    fun getImage(call: PluginCall) {
        if (!requireInitialized(call)) return
        val imageId = call.getString("imageId")
        if (imageId.isNullOrEmpty()) {
            call.reject("getImage() requires an imageId.", SpotifyErrors.UNKNOWN)
            return
        }
        val width = call.getInt("width")
        val dimension = when {
            width == null -> Image.Dimension.MEDIUM
            width <= 144 -> Image.Dimension.THUMBNAIL
            width <= 240 -> Image.Dimension.X_SMALL
            width <= 360 -> Image.Dimension.SMALL
            width <= 480 -> Image.Dimension.MEDIUM
            else -> Image.Dimension.LARGE
        }
        runOnMain {
            remoteManager.getImage(
                imageId,
                dimension,
                { bitmap ->
                    executor.execute {
                        val stream = java.io.ByteArrayOutputStream()
                        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream)
                        val base64 = android.util.Base64.encodeToString(stream.toByteArray(), android.util.Base64.NO_WRAP)
                        call.resolve(JSObject().put("dataUrl", "data:image/png;base64,$base64"))
                    }
                },
                { rejectPlayback(call, it) },
            )
        }
    }

    @PluginMethod
    fun getUserCapabilities(call: PluginCall) {
        if (!requireInitialized(call)) return
        runOnMain {
            remoteManager.getUserCapabilities(
                { canPlayOnDemand -> call.resolve(JSObject().put("canPlayOnDemand", canPlayOnDemand)) },
                { rejectPlayback(call, it) },
            )
        }
    }

    // endregion

    // region web api

    /**
     * Never rejects: "not initialized" is itself a diagnosis, so it is reported
     * in the payload rather than as a rejection.
     */
    @PluginMethod
    fun diagnoseAccess(call: PluginCall) {
        if (!initialized) {
            call.resolve(
                SpotifyAccessDiagnosis.failed(
                    SpotifyErrors.NOT_INITIALIZED,
                    "Call initialize() before using the Spotify plugin.",
                ).toJSObject(),
            )
            return
        }
        webApi.probe("/me") { diagnosis -> call.resolve(diagnosis.toJSObject()) }
    }

    @PluginMethod
    fun addToQueue(call: PluginCall) {
        if (!requireInitialized(call)) return
        val uri = call.getString("uri")
        if (uri.isNullOrEmpty()) {
            call.reject("addToQueue() requires a uri.", SpotifyErrors.UNKNOWN)
            return
        }
        webApi.request(
            "POST",
            "/me/player/queue?uri=${URLEncoder.encode(uri, "UTF-8")}",
            onSuccess = { call.resolve() },
            onError = { rejectWebApi(call, it) },
        )
    }

    @PluginMethod
    fun getDevices(call: PluginCall) {
        if (!requireInitialized(call)) return
        webApi.request(
            "GET",
            "/me/player/devices",
            onSuccess = { body ->
                try {
                    call.resolve(JSObject().put("devices", devicesToJSArray(body)))
                } catch (e: JSONException) {
                    call.reject("Could not read the Spotify device list: ${e.message}", SpotifyErrors.UNKNOWN)
                }
            },
            onError = { rejectWebApi(call, it) },
        )
    }

    @PluginMethod
    fun transferPlayback(call: PluginCall) {
        if (!requireInitialized(call)) return
        val deviceId = call.getString("deviceId")
        if (deviceId.isNullOrEmpty()) {
            call.reject("transferPlayback() requires a deviceId.", SpotifyErrors.UNKNOWN)
            return
        }
        val play = call.getBoolean("play", false) ?: false
        val body = JSONObject()
            .put("device_ids", JSONArray().put(deviceId))
            .put("play", play)
            .toString()
        webApi.request(
            "PUT",
            "/me/player",
            body,
            onSuccess = { call.resolve() },
            onError = { rejectWebApi(call, it) },
        )
    }

    // endregion

    // region lifecycle

    override fun handleOnStop() {
        if (remoteManager.isConnected()) {
            reconnectOnStart = true
            remoteManager.disconnect()
            emitConnectionState(false, REASON_APP_BACKGROUNDED)
        }
        super.handleOnStop()
    }

    override fun handleOnStart() {
        super.handleOnStart()
        if (!reconnectOnStart) return
        val clientId = this.clientId ?: return
        val redirectUri = this.redirectUri ?: return
        remoteManager.connect(
            context,
            clientId,
            redirectUri,
            onSuccess = {
                reconnectOnStart = false
                emitConnectionState(true, REASON_CONNECT)
            },
            onError = { error ->
                emitConnectionError(
                    SpotifyErrors.mapConnectionError(error),
                    error.message ?: "Could not reconnect to the Spotify app.",
                )
            },
        )
    }

    override fun handleOnDestroy() {
        remoteManager.disconnect()
        executor.shutdown()
        super.handleOnDestroy()
    }

    // endregion

    // region helpers

    private fun requireInitialized(call: PluginCall): Boolean {
        if (initialized) return true
        call.reject("Call initialize() before using the Spotify plugin.", SpotifyErrors.NOT_INITIALIZED)
        return false
    }

    private fun rejectPlayback(call: PluginCall, error: Throwable) {
        call.reject(error.message ?: "The Spotify playback command failed.", SpotifyErrors.mapPlaybackError(error))
    }

    private fun rejectWebApi(call: PluginCall, error: SpotifyException) {
        call.reject(error.message ?: "The Spotify Web API request failed.", error.code)
    }

    /** Maps a `GET /me/player/devices` payload onto the `SpotifyDevice` shape. */
    private fun devicesToJSArray(body: String?): JSArray {
        val devices = JSArray()
        if (body.isNullOrBlank()) return devices
        val items = JSONObject(body).optJSONArray("devices") ?: return devices
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            val device = JSObject()
            device.put("id", if (item.isNull("id")) JSONObject.NULL else item.optString("id"))
            device.put("name", item.optString("name"))
            device.put("type", item.optString("type"))
            device.put("isActive", item.optBoolean("is_active"))
            device.put("isPrivateSession", item.optBoolean("is_private_session"))
            device.put("isRestricted", item.optBoolean("is_restricted"))
            if (!item.isNull("volume_percent")) device.put("volumePercent", item.optInt("volume_percent"))
            devices.put(device)
        }
        return devices
    }

    private fun isSpotifyInstalled(): Boolean = try {
        context.packageManager.getPackageInfo(SPOTIFY_PACKAGE, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun sessionToJSObject(session: SpotifySession): JSObject {
        val scopes = JSArray()
        session.scopes.forEach { scopes.put(it) }
        val result = JSObject()
        result.put("accessToken", session.accessToken)
        result.put("expiresAt", session.expiresAt)
        result.put("scopes", scopes)
        result.put("tokenType", "Bearer")
        return result
    }

    private fun emitAuthState() {
        val authenticated = authManager.isAuthenticated()
        val payload = JSObject().put("authenticated", authenticated)
        if (authenticated) payload.put("expiresAt", authManager.storedExpiresAt())
        notifyListeners(EVENT_AUTH_STATE, payload)
    }

    private fun emitConnectionState(connected: Boolean, reason: String) {
        val payload = JSObject()
        payload.put("connected", connected)
        payload.put("reason", reason)
        notifyListeners(EVENT_CONNECTION_STATE, payload)
    }

    private fun emitConnectionError(code: String, message: String) {
        val error = JSObject()
        error.put("code", code)
        error.put("message", message)
        val payload = JSObject()
        payload.put("connected", false)
        payload.put("reason", REASON_ERROR)
        payload.put("error", error)
        notifyListeners(EVENT_CONNECTION_STATE, payload)
    }

    private fun stringList(array: JSArray?): List<String>? {
        if (array == null) return null
        return try {
            array.toList<String>().filterNotNull()
        } catch (e: JSONException) {
            null
        }
    }

    /** App Remote calls must run on the main thread; plugin methods do not. */
    private fun runOnMain(block: () -> Unit) {
        val bridge = this.bridge
        if (bridge != null) {
            bridge.executeOnMainThread { block() }
        } else {
            Handler(Looper.getMainLooper()).post { block() }
        }
    }

    // endregion

    private companion object {
        const val SPOTIFY_PACKAGE = "com.spotify.music"

        const val EVENT_PLAYER_STATE = "playerStateChanged"
        const val EVENT_CONNECTION_STATE = "connectionStateChanged"
        const val EVENT_AUTH_STATE = "authStateChanged"

        const val REASON_CONNECT = "connect"
        const val REASON_DISCONNECT = "disconnect"
        const val REASON_APP_BACKGROUNDED = "appBackgrounded"
        const val REASON_ERROR = "error"
    }
}
