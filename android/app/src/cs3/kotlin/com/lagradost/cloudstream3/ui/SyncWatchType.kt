package com.lagradost.cloudstream3.ui

/** Referenced by type only (tracker watch states in the real app). */
enum class SyncWatchType(val internalId: Int, val stringRes: Int, val iconRes: Int) {
    NONE(-1, 0, 0),
    WATCHING(0, 0, 0),
    COMPLETED(1, 0, 0),
    ONHOLD(2, 0, 0),
    DROPPED(3, 0, 0),
    PLANTOWATCH(4, 0, 0),
    REWATCHING(5, 0, 0);

    companion object {
        fun fromInternalId(id: Int?) = entries.find { it.internalId == id } ?: NONE
    }
}
