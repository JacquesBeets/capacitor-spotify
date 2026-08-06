package com.jacquesbeets.plugins.spotify

import com.getcapacitor.Logger

class Spotify {

    fun echo(value: String): String {
        Logger.info("Echo", value)

        return value
    }
}
