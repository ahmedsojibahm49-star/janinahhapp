package com.lagradost.cloudstream3.plugins

import android.content.Context
import android.content.res.Resources

/**
 * Host-side stand-ins for classes that live in CloudStream's *app* module.
 *
 * A `.cs3` is compiled against CloudStream's app, not just its `library`,
 * and links to these classes BY NAME when it loads. The `library` artifact
 * StreamBox bundles has `BasePlugin` but not the classes below, so without
 * them a plugin dies with NoClassDefFoundError before it registers a
 * provider. Only the small public surface plugins actually touch is
 * provided; a plugin that needs more fails with a clear error naming the
 * missing class (shown in the extension's details) and can be supported by
 * adding it here.
 */
abstract class Plugin : BasePlugin() {
    companion object {
        // Compose-compiled plugins read this static field when their class
        // initialises; it must exist as `public static final int $stable`.
        const val `$stable`: Int = 8
    }

    /**
     * Plugins override either this overload or the no-arg [BasePlugin.load].
     * The real app's default forwards to `load()`, so a plugin that only
     * overrides the no-arg one (and registers its provider there) must
     * still run — otherwise it loads but registers nothing.
     */
    open fun load(context: Context) {
        load()
    }

    var resources: Resources? = null
    var needsResources: Boolean = false
    var openSettings: ((context: Context) -> Unit)? = null
}

/** Mirrors the app's `PluginData`, reported empty (see [PluginManager]). */
data class PluginData(
    val internalName: String,
    val url: String?,
    val isOnline: Boolean,
    val filePath: String,
    val version: Int,
)

/**
 * Some plugins call `PluginManager.getPluginsOnline()` / `unloadPlugin()`
 * from their own `reload()`. Reporting "nothing installed" makes them take
 * the plain "register me" path; unloading is owned by StreamBox itself.
 */
object PluginManager {
    fun getPluginsOnline(): Array<PluginData> = emptyArray()

    fun getPluginsLocal(): Array<PluginData> = emptyArray()

    // Registries of loaded plugins keyed by path/url: StreamBox owns loading
    // and exposes none of them to plugins.
    val plugins: Map<String, BasePlugin> get() = emptyMap()

    val urlPlugins: Map<String, BasePlugin> get() = emptyMap()

    var currentlyLoading: String? = null

    val loadedLocalPlugins: Boolean get() = true

    val loadedOnlinePlugins: Boolean get() = true

    fun isSafeMode(): Boolean = false

    fun checkSafeModeFile(): Boolean = false

    fun getPluginSanitizedFileName(name: String): String =
        name.replace(Regex("[^A-Za-z0-9._-]"), "_")

    fun unloadPlugin(absolutePath: String) {}
}
