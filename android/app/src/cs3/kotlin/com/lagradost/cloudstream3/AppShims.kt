package com.lagradost.cloudstream3

import android.app.Activity
import android.content.Context
import android.content.res.Resources
import android.util.DisplayMetrics
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import com.lagradost.cloudstream3.utils.DataStore
import com.lagradost.cloudstream3.utils.Event
import com.lagradost.cloudstream3.utils.UiText
import com.lagradost.cloudstream3.utils.DataStore.getKeys as dsGetKeys
import com.lagradost.cloudstream3.utils.DataStore.removeKey as dsRemoveKey
import com.lagradost.cloudstream3.utils.DataStore.removeKeys as dsRemoveKeys
import com.lagradost.cloudstream3.utils.DataStore.setKey as dsSetKey

/**
 * Host-side stand-ins for CloudStream's app classes. Every member below
 * mirrors the SIGNATURE (name + JVM descriptor) of the real app class,
 * verified against the app's published classes.jar, because plugin
 * bytecode links to these by name and an almost-right signature fails
 * with NoSuchMethodError.
 *
 * Plugins call `getKey<T>(path)` / `setKey(path, value)`, which the real
 * app declares `inline` — so at runtime they reach `getKeyClass` /
 * `setKeyClass` here.
 */
class CloudStreamApp {
    companion object {
        @Volatile
        private var appContext: Context? = null

        var context: Context?
            get() = appContext
            set(value) {
                appContext = value?.applicationContext
            }

        fun getActivity(context: Context): Activity? = CommonActivity.activity

        @Suppress("UNCHECKED_CAST")
        fun <T> getKeyClass(path: String, valueType: Class<T>): T? {
            val ctx = appContext ?: return null
            return with(DataStore) { ctx.getKey(path, valueType as Class<Any>) as T? }
        }

        fun <T> setKeyClass(path: String, value: T) {
            val ctx = appContext ?: return
            with(DataStore) { ctx.dsSetKey(path, value) }
        }

        fun setKey(path: String, value: Any?) {
            val ctx = appContext ?: return
            with(DataStore) { ctx.dsSetKey(path, value) }
        }

        fun setKey(folder: String, path: String, value: Any?) {
            val ctx = appContext ?: return
            with(DataStore) { ctx.dsSetKey(folder, path, value) }
        }

        fun getKeys(folder: String): List<String>? {
            val ctx = appContext ?: return null
            return with(DataStore) { ctx.dsGetKeys(folder) }
        }

        fun removeKey(folder: String, path: String) {
            val ctx = appContext ?: return
            with(DataStore) { ctx.dsRemoveKey(folder, path) }
        }

        fun removeKey(path: String) {
            val ctx = appContext ?: return
            with(DataStore) { ctx.dsRemoveKey(path) }
        }

        fun removeKeys(folder: String): Int? {
            val ctx = appContext ?: return null
            return with(DataStore) { ctx.dsRemoveKeys(folder) }
        }
    }
}

/** Older plugins reach the same store through this name. */
class AcraApplication {
    companion object {
        val context: Context? get() = CloudStreamApp.context

        fun setKey(path: String, value: Any?) = CloudStreamApp.setKey(path, value)

        fun setKey(folder: String, path: String, value: Any?) =
            CloudStreamApp.setKey(folder, path, value)

        fun removeKeys(folder: String): Int? = CloudStreamApp.removeKeys(folder)
    }
}

/**
 * Lifecycle events plugins subscribe to (e.g. "register my provider once
 * every plugin is loaded"). StreamBox fires them once after a plugin load.
 */
class MainActivity {
    companion object {
        val afterPluginsLoadedEvent = Event<Boolean>()
        val mainPluginsLoadedEvent = Event<Boolean>()
        val afterRepositoryLoadedEvent = Event<Boolean>()
        val bookmarksUpdatedEvent = Event<Boolean>()
        val reloadHomeEvent = Event<Boolean>()
        val reloadLibraryEvent = Event<Boolean>()
        val reloadAccountEvent = Event<Boolean>()

        var lastError: String? = null
        var nextSearchQuery: String? = null
    }
}

/** `CommonActivity.showToast(...)` is a common plugin call. */
object CommonActivity {
    @Volatile
    var activity: Activity? = null
        private set

    // Screen facts some plugins use to pick image sizes.
    val displayMetrics: DisplayMetrics get() = Resources.getSystem().displayMetrics
    val screenWidth: Int get() = displayMetrics.widthPixels
    val screenHeight: Int get() = displayMetrics.heightPixels
    val screenWidthWithOrientation: Int get() = displayMetrics.widthPixels
    val screenHeightWithOrientation: Int get() = displayMetrics.heightPixels

    var isPipDesired: Boolean = false
    var isInPIPMode: Boolean = false
    var appliedTheme: Int = 0
    var appliedColor: Int = 0
    var keyEventListener: ((Any) -> Boolean)? = null
    val onColorSelectedEvent = Event<Pair<Int, Int>>()
    val onDialogDismissedEvent = Event<Int>()

    fun setActivityInstance(newActivity: Activity?) {
        activity = newActivity
    }

    fun showToast(message: String?, duration: Int? = null) {
        val text = message ?: return
        val ctx = activity ?: CloudStreamApp.context ?: return
        val length = if (duration == Toast.LENGTH_LONG) Toast.LENGTH_LONG else Toast.LENGTH_SHORT
        Handler(Looper.getMainLooper()).post {
            try {
                Toast.makeText(ctx, text, length).show()
            } catch (_: Throwable) {
            }
        }
    }

    fun showToast(act: Activity?, message: String?, duration: Int? = null) =
        showToast(message, duration)

    fun showToast(message: UiText?, duration: Int? = null) {
        val ctx = activity ?: CloudStreamApp.context ?: return
        showToast(message?.asStringNull(ctx), duration)
    }

    fun showToast(act: Activity?, message: UiText?, duration: Int) {
        showToast(message, duration)
    }

    fun showToast(act: Activity?, message: Int, duration: Int? = null) {
        showToast(message, duration)
    }

    fun showToast(message: Int, duration: Int? = null) {
        val ctx = activity ?: CloudStreamApp.context ?: return
        showToast(runCatching { ctx.getString(message) }.getOrNull(), duration)
    }
}
