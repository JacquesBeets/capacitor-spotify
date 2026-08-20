package com.jacquesbeets.plugins.spotify

import com.getcapacitor.JSObject
import org.json.JSONObject

/**
 * Spotify's own verdict on whether this app and account may use the Web API,
 * as returned by `diagnoseAccess()`.
 *
 * Deliberately not an exception: the point is to hand the caller Spotify's
 * message rather than the plugin's interpretation of it. On iOS two app-level
 * `403`s are indistinguishable from the native side, and one of them names the
 * wrong setting, so the raw text is the only reliable diagnosis.
 *
 * Mirrors `AccessDiagnosis` in `src/definitions.ts`; the wording is shared with
 * the iOS and web implementations so integrators compare like with like.
 */
data class SpotifyAccessDiagnosis(
    val ok: Boolean,
    val message: String,
    val code: String?,
    val httpStatus: Int?,
    val spotifyMessage: String?,
    val userId: String?,
    val product: String?,
) {

    fun toJSObject(): JSObject {
        val result = JSObject()
        result.put("ok", ok)
        result.put("message", message)
        code?.let { result.put("code", it) }
        httpStatus?.let { result.put("httpStatus", it) }
        spotifyMessage?.takeIf { it.isNotEmpty() }?.let { result.put("spotifyMessage", it) }
        userId?.let { result.put("userId", it) }
        product?.let { result.put("product", it) }
        return result
    }

    companion object {
        /** Matches the error-body limit the Web API clients use on every platform. */
        private const val MESSAGE_LIMIT = 500

        /** Reads a `GET /v1/me` response, whatever Spotify put in the body. */
        fun from(status: Int, body: String): SpotifyAccessDiagnosis {
            if (status in 200..299) {
                val profile = json(body)
                return SpotifyAccessDiagnosis(
                    ok = true,
                    message = "Spotify accepted GET /v1/me — this app and account can use the Web API",
                    code = null,
                    httpStatus = status,
                    spotifyMessage = null,
                    userId = profile?.optString("id")?.ifEmpty { null },
                    product = profile?.optString("product")?.ifEmpty { null },
                )
            }

            val reported = spotifyMessage(body)
            return SpotifyAccessDiagnosis(
                ok = false,
                message = reading(status, reported),
                code = code(status, reported),
                httpStatus = status,
                spotifyMessage = reported.ifEmpty { null },
                userId = null,
                product = null,
            )
        }

        /** The probe never got an answer — no session, no network, or no plugin. */
        fun failed(code: String, message: String) = SpotifyAccessDiagnosis(
            ok = false,
            message = message,
            code = code,
            httpStatus = null,
            spotifyMessage = null,
            userId = null,
            product = null,
        )

        private fun reading(status: Int, reported: String): String = when {
            status == 401 ->
                "Spotify rejected the access token — the session is no longer valid, call authorize() again"

            status == 403 && reported.contains("owner", ignoreCase = true) ->
                "Spotify is refusing this app: the account that owns your dashboard app has no active Premium " +
                    "subscription. That blocks every user of the app regardless of their own tier, and Spotify " +
                    "can take a few hours to allow requests again once the subscription is active."

            status == 403 ->
                "Spotify is refusing this account. Its message points at User Management, but non-owner accounts " +
                    "get that same text when the dashboard app owner's Premium subscription has lapsed — check " +
                    "the owner's subscription first, then the app's User Management allowlist."

            status == 429 -> "Spotify rate limited the probe — retry in a few seconds"

            else -> "Spotify answered the probe with HTTP $status"
        }

        /**
         * Same status-to-code mapping as [SpotifyWebApi] and `src/web/api.ts`, so
         * a diagnosis and a real rejection agree about what went wrong.
         */
        private fun code(status: Int, reported: String): String = when {
            status == 401 -> SpotifyErrors.NOT_AUTHENTICATED
            status == 403 && reported.contains("premium", ignoreCase = true) -> SpotifyErrors.PREMIUM_REQUIRED
            status == 403 -> SpotifyErrors.USER_NOT_AUTHORIZED
            status == 429 -> SpotifyErrors.RATE_LIMITED
            else -> SpotifyErrors.UNKNOWN
        }

        /**
         * Spotify wraps its reason in `{"error": {"status": …, "message": …}}`.
         * Falls back to the raw body, which is all a non-JSON error leaves behind.
         */
        private fun spotifyMessage(body: String): String {
            val message = json(body)?.optJSONObject("error")?.optString("message")
            return (message?.ifEmpty { null } ?: body).take(MESSAGE_LIMIT)
        }

        private fun json(body: String): JSONObject? = try {
            JSONObject(body)
        } catch (e: org.json.JSONException) {
            null
        }
    }
}
