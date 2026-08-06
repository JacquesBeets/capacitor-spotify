package com.jacquesbeets.plugins.spotify

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import com.spotify.sdk.android.auth.AuthorizationClient
import com.spotify.sdk.android.auth.AuthorizationRequest
import com.spotify.sdk.android.auth.AuthorizationResponse
import com.spotify.sdk.android.auth.PKCEInformation
import com.spotify.sdk.android.auth.PKCEInformationFactory
import java.io.IOException
import java.net.URL
import java.net.URLEncoder
import java.security.NoSuchAlgorithmException
import javax.net.ssl.HttpsURLConnection
import org.json.JSONException
import org.json.JSONObject

/** A resolved Spotify session, ready to be handed back as an `AccessToken`. */
data class SpotifySession(
    val accessToken: String,
    val expiresAt: Long,
    val scopes: List<String>,
    /** True when this session was produced by a token exchange or refresh. */
    val renewed: Boolean = false,
)

/**
 * Authorization Code + PKCE flow via the Spotify auth library, with plugin-side
 * token exchange, storage and refresh. No client secret and no token-swap server
 * are involved.
 */
class SpotifyAuthManager(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    @Volatile
    private var clientId: String? = null

    @Volatile
    private var redirectUri: String? = null

    @Volatile
    private var defaultScopes: List<String> = DEFAULT_SCOPES

    /** Kept in memory as well as in prefs so a process death mid-auth recovers. */
    @Volatile
    private var codeVerifier: String? = null

    fun configure(clientId: String, redirectUri: String, scopes: List<String>?) {
        this.clientId = clientId
        this.redirectUri = redirectUri
        if (!scopes.isNullOrEmpty()) {
            this.defaultScopes = scopes
        }
    }

    // region interactive authorization

    /**
     * Builds the intent that drives the interactive grant. The auth library
     * prefers SSO through the installed Spotify app and falls back to Custom
     * Tabs / the browser.
     */
    fun buildLoginIntent(activity: Activity, scopes: List<String>?, showDialog: Boolean): Intent {
        val clientId = requireClientId()
        val redirectUri = requireRedirectUri()
        val requestedScopes = if (scopes.isNullOrEmpty()) defaultScopes else scopes

        val pkce = createPkceInformation()
        codeVerifier = pkce.verifier
        prefs.edit().putString(KEY_CODE_VERIFIER, pkce.verifier).apply()

        val request = AuthorizationRequest.Builder(clientId, AuthorizationResponse.Type.CODE, redirectUri)
            .setScopes(requestedScopes.toTypedArray())
            .setShowDialog(showDialog)
            .setPkceInformation(pkce)
            .build()

        return AuthorizationClient.createLoginActivityIntent(activity, request)
    }

    /**
     * Turns an activity result into a stored session. Blocking — call from a
     * background executor.
     */
    fun handleAuthResponse(resultCode: Int, data: Intent?): SpotifySession {
        val response = AuthorizationClient.getResponse(resultCode, data)
        val type: AuthorizationResponse.Type? = response.type

        return when (type) {
            AuthorizationResponse.Type.CODE -> {
                val code: String? = response.code
                if (code.isNullOrEmpty()) {
                    throw SpotifyException(SpotifyErrors.AUTH_FAILED, "Spotify returned no authorization code.")
                }
                val verifier = codeVerifier ?: prefs.getString(KEY_CODE_VERIFIER, null)
                if (verifier.isNullOrEmpty()) {
                    throw SpotifyException(
                        SpotifyErrors.AUTH_FAILED,
                        "Missing PKCE code verifier for the authorization code exchange.",
                    )
                }
                exchangeAuthorizationCode(code, verifier)
            }

            // auth-lib 5.0.0 performs the PKCE exchange itself in some flows and
            // hands back tokens directly.
            AuthorizationResponse.Type.TOKEN -> {
                val accessToken: String? = response.accessToken
                if (accessToken.isNullOrEmpty()) {
                    throw SpotifyException(SpotifyErrors.AUTH_FAILED, "Spotify returned no access token.")
                }
                clearCodeVerifier()
                val expiresAt = System.currentTimeMillis() + response.expiresIn.toLong() * 1000L
                val refreshToken: String? = response.refreshToken
                val scopes = storedScopes().ifEmpty { defaultScopes }
                persist(accessToken, refreshToken, expiresAt, scopes)
                SpotifySession(accessToken, expiresAt, scopes, renewed = true)
            }

            AuthorizationResponse.Type.CANCELLED, AuthorizationResponse.Type.EMPTY ->
                throw SpotifyException(SpotifyErrors.AUTH_CANCELLED, "Spotify authorization was cancelled.")

            AuthorizationResponse.Type.ERROR -> {
                val error: String? = response.error
                throw SpotifyException(
                    SpotifyErrors.AUTH_FAILED,
                    "Spotify authorization failed: ${if (error.isNullOrEmpty()) "unknown error" else error}",
                )
            }

            else -> throw SpotifyException(SpotifyErrors.AUTH_FAILED, "Unrecognized Spotify authorization response.")
        }
    }

    // endregion

    // region token access

    /**
     * Returns a valid session, refreshing when the access token is within
     * [EXPIRY_MARGIN_MS] of expiry. Blocking — call from a background executor.
     */
    @Synchronized
    fun getAccessToken(forceRefresh: Boolean): SpotifySession {
        val accessToken = prefs.getString(KEY_ACCESS_TOKEN, null)
        val refreshToken = prefs.getString(KEY_REFRESH_TOKEN, null)
        val expiresAt = prefs.getLong(KEY_EXPIRES_AT, 0L)

        if (accessToken.isNullOrEmpty() && refreshToken.isNullOrEmpty()) {
            throw SpotifyException(
                SpotifyErrors.NOT_AUTHENTICATED,
                "No Spotify session. Call authorize() first.",
            )
        }

        val stillValid = !accessToken.isNullOrEmpty() &&
            expiresAt - System.currentTimeMillis() > EXPIRY_MARGIN_MS
        if (!forceRefresh && stillValid) {
            return SpotifySession(accessToken!!, expiresAt, storedScopes())
        }

        if (refreshToken.isNullOrEmpty()) {
            clear()
            throw SpotifyException(
                SpotifyErrors.NOT_AUTHENTICATED,
                "The Spotify session expired and no refresh token is available. Call authorize() again.",
            )
        }

        return refreshSession(refreshToken)
    }

    fun logout() = clear()

    fun isAuthenticated(): Boolean {
        val accessToken = prefs.getString(KEY_ACCESS_TOKEN, null)
        val refreshToken = prefs.getString(KEY_REFRESH_TOKEN, null)
        if (accessToken.isNullOrEmpty()) return !refreshToken.isNullOrEmpty()
        return prefs.getLong(KEY_EXPIRES_AT, 0L) > System.currentTimeMillis() || !refreshToken.isNullOrEmpty()
    }

    fun storedExpiresAt(): Long = prefs.getLong(KEY_EXPIRES_AT, 0L)

    // endregion

    // region internals

    private fun createPkceInformation(): PKCEInformation = try {
        // Generates a 43-128 char verifier from the RFC 7636 charset plus the
        // base64url (no padding) SHA-256 challenge, method "S256".
        PKCEInformationFactory.create()
    } catch (e: NoSuchAlgorithmException) {
        throw SpotifyException(
            SpotifyErrors.AUTH_FAILED,
            "This device cannot generate a PKCE challenge: ${e.message}",
        )
    }

    private fun exchangeAuthorizationCode(code: String, verifier: String): SpotifySession {
        val payload = postToTokenEndpoint(
            mapOf(
                "grant_type" to "authorization_code",
                "code" to code,
                "redirect_uri" to requireRedirectUri(),
                "client_id" to requireClientId(),
                "code_verifier" to verifier,
            ),
            SpotifyErrors.AUTH_FAILED,
        )
        val session = persistTokenResponse(payload, null)
        clearCodeVerifier()
        return session
    }

    private fun refreshSession(refreshToken: String): SpotifySession {
        val clientId = requireClientId()
        val payload = try {
            postToTokenEndpoint(
                mapOf(
                    "grant_type" to "refresh_token",
                    "refresh_token" to refreshToken,
                    "client_id" to clientId,
                ),
                SpotifyErrors.TOKEN_REFRESH_FAILED,
            )
        } catch (e: SpotifyException) {
            clear()
            throw SpotifyException(
                SpotifyErrors.TOKEN_REFRESH_FAILED,
                e.message ?: "Refreshing the Spotify access token failed.",
            )
        }
        return persistTokenResponse(payload, refreshToken)
    }

    private fun persistTokenResponse(payload: JSONObject, previousRefreshToken: String?): SpotifySession {
        val accessToken = payload.optString("access_token")
        if (accessToken.isEmpty()) {
            throw SpotifyException(SpotifyErrors.AUTH_FAILED, "The Spotify token response contained no access_token.")
        }

        val expiresIn = payload.optLong("expires_in", DEFAULT_EXPIRES_IN_SECONDS)
        val expiresAt = System.currentTimeMillis() + expiresIn * 1000L

        // Spotify rotates refresh tokens; keep the previous one when omitted.
        val rotated = payload.optString("refresh_token")
        val refreshToken = if (rotated.isEmpty()) previousRefreshToken else rotated

        val scope = payload.optString("scope")
        val scopes = if (scope.isBlank()) {
            storedScopes().ifEmpty { defaultScopes }
        } else {
            scope.split(" ").filter { it.isNotBlank() }
        }

        persist(accessToken, refreshToken, expiresAt, scopes)
        return SpotifySession(accessToken, expiresAt, scopes, renewed = true)
    }

    private fun postToTokenEndpoint(form: Map<String, String>, failureCode: String): JSONObject {
        val body = form.entries.joinToString("&") { (key, value) ->
            "${URLEncoder.encode(key, "UTF-8")}=${URLEncoder.encode(value, "UTF-8")}"
        }

        var connection: HttpsURLConnection? = null
        try {
            connection = (URL(TOKEN_ENDPOINT).openConnection() as HttpsURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                setRequestProperty("Accept", "application/json")
            }
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }

            val status = connection.responseCode
            val successful = status in 200..299
            val stream = if (successful) connection.inputStream else connection.errorStream
            val raw = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()

            if (status == 429) {
                throw SpotifyException(
                    SpotifyErrors.RATE_LIMITED,
                    "Spotify rate limited the token request. Try again shortly.",
                )
            }

            val payload = try {
                if (raw.isBlank()) JSONObject() else JSONObject(raw)
            } catch (e: JSONException) {
                JSONObject()
            }

            if (!successful) {
                val description = payload.optString("error_description")
                    .ifEmpty { payload.optString("error") }
                    .ifEmpty { "HTTP $status" }
                throw SpotifyException(failureCode, "The Spotify token request failed: $description")
            }

            return payload
        } catch (e: SpotifyException) {
            throw e
        } catch (e: IOException) {
            throw SpotifyException(failureCode, "The Spotify token request failed: ${e.message}")
        } finally {
            connection?.disconnect()
        }
    }

    private fun persist(accessToken: String, refreshToken: String?, expiresAt: Long, scopes: List<String>) {
        prefs.edit()
            .putString(KEY_ACCESS_TOKEN, accessToken)
            .putString(KEY_REFRESH_TOKEN, refreshToken)
            .putLong(KEY_EXPIRES_AT, expiresAt)
            .putString(KEY_SCOPES, scopes.joinToString(" "))
            .apply()
    }

    private fun storedScopes(): List<String> =
        prefs.getString(KEY_SCOPES, null)?.split(" ")?.filter { it.isNotBlank() } ?: emptyList()

    private fun clearCodeVerifier() {
        codeVerifier = null
        prefs.edit().remove(KEY_CODE_VERIFIER).apply()
    }

    private fun clear() {
        codeVerifier = null
        prefs.edit().clear().apply()
    }

    private fun requireClientId(): String = clientId
        ?: throw SpotifyException(SpotifyErrors.NOT_INITIALIZED, "Call initialize() before authorizing.")

    private fun requireRedirectUri(): String = redirectUri
        ?: throw SpotifyException(SpotifyErrors.NOT_INITIALIZED, "Call initialize() before authorizing.")

    // endregion

    companion object {
        private const val PREFS_NAME = "capacitor_spotify"
        private const val KEY_ACCESS_TOKEN = "accessToken"
        private const val KEY_REFRESH_TOKEN = "refreshToken"
        private const val KEY_EXPIRES_AT = "expiresAt"
        private const val KEY_SCOPES = "scopes"
        private const val KEY_CODE_VERIFIER = "codeVerifier"

        private const val TOKEN_ENDPOINT = "https://accounts.spotify.com/api/token"
        private const val TIMEOUT_MS = 15_000
        private const val EXPIRY_MARGIN_MS = 60_000L
        private const val DEFAULT_EXPIRES_IN_SECONDS = 3600L

        val DEFAULT_SCOPES = listOf(
            "app-remote-control",
            "streaming",
            "user-modify-playback-state",
            "user-read-playback-state",
            "user-read-currently-playing",
        )
    }
}
