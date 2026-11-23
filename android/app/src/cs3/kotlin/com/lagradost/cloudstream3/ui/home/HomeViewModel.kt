package com.lagradost.cloudstream3.ui.home

/** Some plugins ask for "resume watching" rows; StreamBox has none to offer. */
class HomeViewModel {
    companion object {
        suspend fun getResumeWatching(): List<Any>? = null
    }
}
