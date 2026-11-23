package com.lagradost.cloudstream3.ui.settings

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.res.Resources

/** Device-layout flags plugins read (some skip browser steps on a TV). */
object Globals {
    const val PHONE: Int = 0b001
    const val TV: Int = 0b010
    const val EMULATOR: Int = 0b100

    @Volatile
    private var layoutId = PHONE

    /** Present in the real app (an in-joke counter); plugins never rely on it. */
    var beneneCount: Int = 0

    /** StreamBox is a phone app: only report TV on a real television. */
    fun resolveFrom(context: Context) {
        layoutId = runCatching {
            val ui = context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager?
            val isTv = ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
            if (isTv) TV else PHONE
        }.getOrDefault(PHONE)
    }

    fun Context.updateTv() = resolveFrom(this)

    fun isLandscape(): Boolean =
        isLayout(TV or EMULATOR) ||
            Resources.getSystem().configuration.orientation == Configuration.ORIENTATION_LANDSCAPE

    fun isLayout(flags: Int): Boolean = (layoutId and flags) != 0
}
