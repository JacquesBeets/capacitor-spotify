package com.jacquesbeets.plugins.spotify

import java.io.IOException
import java.net.URL
import java.util.concurrent.ExecutorService
import javax.net.ssl.HttpsURLConnection

/**
 * The thinnest possible Spotify Web API client: only the calls the App Remote
 * SDK cannot make itself (queueing, listing Connect devices and transferring
 * playback) go through here.
 *
 * Both the token lookup and the HTTP call block, so every request is dispatched
 * onto [executor]; the callbacks run on that same background thread.
 */
class SpotifyWebApi(
    private val authManager: SpotifyAuthManager,
    private val executor: ExecutorService,
) {

    /**
     * Performs an authorized request against `https://api.spotify.com/v1`.
     *
     * @param pathWithQuery the path (and query) appended to the API base, e.g.
     *   `/me/player/devices`.
     * @param body an optional JSON request body.
     * @param onSuccess receives the response body, or `null` for `204 No Content`.
     */
    fun request(
        method: String,
        pathWithQuery: String,
        body: String? = null,
        onSuccess: (String?) -> Unit,
        onError: (SpotifyException) -> Unit,
    ) {
        executor.execute {
            var payload: String? = null
            // Invoke the callbacks outside the try so a throwing onSuccess is not
            // reported as a request failure.
            val failure: SpotifyException? = try {
                payload = perform(method, pathWithQuery, body, retry = true)
                null
            } catch (e: SpotifyException) {
                e
            } catch (e: Exception) {
                SpotifyException(SpotifyErrors.UNKNOWN, e.message ?: "The Spotify Web API request failed.")
            }

            if (failure != null) onError(failure) else onSuccess(payload)
        }
    }

    /**
     * Calls [pathWithQuery] and reports the raw status and body instead of
     * mapping them onto a [SpotifyException].
     *
     * `diagnoseAccess()` needs it that way: *which* `403` Spotify sends is the
     * whole diagnosis, and mapping throws that text away. A `401` still earns
     * one forced-refresh retry, so a merely stale token is not reported as a
     * problem with the app.
     */
    fun probe(pathWithQuery: String, onResult: (SpotifyAccessDiagnosis) -> Unit) {
        executor.execute {
            val diagnosis = try {
                probe(pathWithQuery, retry = true)
            } catch (e: SpotifyException) {
                SpotifyAccessDiagnosis.failed(e.code, e.message ?: "The Spotify Web API probe failed.")
            } catch (e: Exception) {
                SpotifyAccessDiagnosis.failed(SpotifyErrors.UNKNOWN, e.message ?: "The Spotify Web API probe failed.")
            }
            onResult(diagnosis)
        }
    }

    // region internals

    private fun probe(pathWithQuery: String, retry: Boolean): SpotifyAccessDiagnosis {
        val token = accessToken(forceRefresh = !retry)

        var connection: HttpsURLConnection? = null
        try {
            connection = (URL("$API_BASE$pathWithQuery").openConnection() as HttpsURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                setRequestProperty("Authorization", "Bearer $token")
                setRequestProperty("Accept", "application/json")
            }

            val status = connection.responseCode
            if (status == HttpsURLConnection.HTTP_UNAUTHORIZED && retry) {
                connection.disconnect()
                connection = null
                return probe(pathWithQuery, retry = false)
            }

            // Whole body, not the 500-char error snippet: a truncated `/me`
            // payload is not parseable JSON. The diagnosis trims what it shows.
            val body = if (status in 200..299) readBody(connection) else readErrorBody(connection)
            return SpotifyAccessDiagnosis.from(status, body)
        } catch (e: IOException) {
            return SpotifyAccessDiagnosis.failed(
                SpotifyErrors.OFFLINE,
                "The Spotify Web API is unreachable: ${e.message}",
            )
        } finally {
            connection?.disconnect()
        }
    }

    private fun readBody(connection: HttpsURLConnection): String = try {
        connection.inputStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty().trim()
    } catch (e: IOException) {
        ""
    }

    /**
     * @param retry whether a `401` may be retried once with a forced token
     *   refresh; the retry itself runs with `retry` off.
     */
    private fun perform(method: String, pathWithQuery: String, body: String?, retry: Boolean): String? {
        val token = accessToken(forceRefresh = !retry)

        var connection: HttpsURLConnection? = null
        try {
            connection = (URL("$API_BASE$pathWithQuery").openConnection() as HttpsURLConnection).apply {
                requestMethod = method
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                setRequestProperty("Authorization", "Bearer $token")
                setRequestProperty("Accept", "application/json")
                if (body != null) {
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                }
            }
            if (body != null) {
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }

            val status = connection.responseCode
            if (status in 200..299) {
                // Most of these endpoints answer 204 No Content.
                if (status == HttpsURLConnection.HTTP_NO_CONTENT) return null
                val raw = connection.inputStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
                return if (raw.isNullOrBlank()) null else raw
            }

            if (status == HttpsURLConnection.HTTP_UNAUTHORIZED && retry) {
                connection.disconnect()
                connection = null
                return perform(method, pathWithQuery, body, retry = false)
            }

            throw toApiError(status, readErrorBody(connection), connection.getHeaderField("Retry-After"))
        } catch (e: SpotifyException) {
            throw e
        } catch (e: IOException) {
            throw SpotifyException(SpotifyErrors.OFFLINE, "The Spotify Web API is unreachable: ${e.message}")
        } finally {
            connection?.disconnect()
        }
    }

    private fun accessToken(forceRefresh: Boolean): String = try {
        authManager.getAccessToken(forceRefresh).accessToken
    } catch (e: SpotifyException) {
        throw e
    } catch (e: Exception) {
        throw SpotifyException(
            SpotifyErrors.NOT_AUTHENTICATED,
            e.message ?: "No Spotify session. Call authorize() first.",
        )
    }

    /** Never parsed as JSON: error bodies are not reliably JSON (and may be empty). */
    private fun readErrorBody(connection: HttpsURLConnection): String = try {
        connection.errorStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
            .orEmpty()
            .trim()
            .take(ERROR_BODY_LIMIT)
    } catch (e: IOException) {
        ""
    }

    /** Mirrors the status mapping of the web implementation (`src/web/api.ts`). */
    private fun toApiError(status: Int, detail: String, retryAfter: String?): SpotifyException {
        val suffix = if (detail.isEmpty()) "" else ": $detail"
        return when {
            status == 401 -> SpotifyException(
                SpotifyErrors.NOT_AUTHENTICATED,
                "Spotify rejected the access token$suffix",
            )

            status == 403 && detail.contains("premium", ignoreCase = true) -> SpotifyException(
                SpotifyErrors.PREMIUM_REQUIRED,
                "Spotify Premium is required for playback control$suffix",
            )

            status == 403 -> SpotifyException(
                SpotifyErrors.USER_NOT_AUTHORIZED,
                "Spotify refused the request$suffix",
            )

            status == 404 -> SpotifyException(
                SpotifyErrors.NOT_ACTIVE_DEVICE,
                "Spotify has no active device for this request — start playback on a device first$suffix",
            )

            status == 429 -> SpotifyException(
                SpotifyErrors.RATE_LIMITED,
                "Spotify rate limited the request. Retry after ${retryAfter ?: "a few"} seconds$suffix",
            )

            else -> SpotifyException(
                SpotifyErrors.PLAYBACK_FAILED,
                "The Spotify Web API request failed (HTTP $status)$suffix",
            )
        }
    }

    // endregion

    private companion object {
        const val API_BASE = "https://api.spotify.com/v1"
        const val TIMEOUT_MS = 15_000
        const val ERROR_BODY_LIMIT = 500
    }
}
