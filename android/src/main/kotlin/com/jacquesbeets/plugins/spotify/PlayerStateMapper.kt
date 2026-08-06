package com.jacquesbeets.plugins.spotify

import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import com.spotify.protocol.types.PlayerContext
import com.spotify.protocol.types.PlayerOptions
import com.spotify.protocol.types.PlayerRestrictions
import com.spotify.protocol.types.PlayerState
import com.spotify.protocol.types.Repeat
import com.spotify.protocol.types.Track
import org.json.JSONObject

/**
 * Converts App Remote protocol types into the JSON shapes declared in
 * `src/definitions.ts`.
 */
object PlayerStateMapper {

    /** Maps a [PlayerState] (plus the latest [PlayerContext], when known) to `PlayerState`. */
    fun toJSObject(state: PlayerState, playerContext: PlayerContext? = null): JSObject {
        val options: PlayerOptions = state.playbackOptions ?: PlayerOptions.DEFAULT
        val restrictions: PlayerRestrictions = state.playbackRestrictions ?: PlayerRestrictions.DEFAULT

        val result = JSObject()
        result.put("track", trackToJSObject(state.track) ?: JSONObject.NULL)
        result.put("paused", state.isPaused)
        result.put("positionMs", state.playbackPosition)
        result.put("playbackSpeed", state.playbackSpeed.toDouble())
        result.put("shuffle", options.isShuffling)
        result.put("repeatMode", repeatModeToString(options.repeatMode))
        result.put("restrictions", restrictionsToJSObject(restrictions))
        result.put("receivedAtMs", System.currentTimeMillis())

        playerContext?.uri?.takeIf { it.isNotEmpty() }?.let { result.put("contextUri", it) }
        playerContext?.title?.takeIf { it.isNotEmpty() }?.let { result.put("contextTitle", it) }

        return result
    }

    /** Maps `Repeat.OFF`/`ONE`/`ALL` to the `RepeatMode` union. */
    fun repeatModeToString(repeatMode: Int): String = when (repeatMode) {
        Repeat.ONE -> "track"
        Repeat.ALL -> "context"
        else -> "off"
    }

    /** Inverse of [repeatModeToString]; null for an unrecognized value. */
    fun repeatModeToInt(repeatMode: String?): Int? = when (repeatMode) {
        "off" -> Repeat.OFF
        "track" -> Repeat.ONE
        "context" -> Repeat.ALL
        else -> null
    }

    private fun trackToJSObject(track: Track?): JSObject? {
        if (track == null) return null

        val artists = JSArray()
        val trackArtists = track.artists?.filterNotNull() ?: emptyList()
        val primaryArtist = track.artist ?: trackArtists.firstOrNull()
        val listed = if (trackArtists.isEmpty() && primaryArtist != null) listOf(primaryArtist) else trackArtists
        for (artist in listed) {
            val entry = JSObject()
            entry.put("name", artist.name ?: "")
            artist.uri?.let { entry.put("uri", it) }
            artists.put(entry)
        }

        val album = track.album
        val result = JSObject()
        result.put("uri", track.uri ?: "")
        result.put("name", track.name ?: "")
        result.put("artistName", primaryArtist?.name ?: "")
        result.put("artists", artists)
        result.put("albumName", album?.name ?: "")
        album?.uri?.let { result.put("albumUri", it) }
        result.put("durationMs", track.duration)
        track.imageUri?.raw?.let { result.put("imageUri", it) }
        result.put("isEpisode", track.isEpisode)
        result.put("isPodcast", track.isPodcast)
        return result
    }

    private fun restrictionsToJSObject(restrictions: PlayerRestrictions): JSObject {
        val result = JSObject()
        result.put("canSkipNext", restrictions.canSkipNext)
        result.put("canSkipPrevious", restrictions.canSkipPrev)
        result.put("canSeek", restrictions.canSeek)
        result.put("canToggleShuffle", restrictions.canToggleShuffle)
        result.put("canRepeatTrack", restrictions.canRepeatTrack)
        result.put("canRepeatContext", restrictions.canRepeatContext)
        return result
    }
}
