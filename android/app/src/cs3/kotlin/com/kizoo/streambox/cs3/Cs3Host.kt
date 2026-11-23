package com.kizoo.streambox.cs3

import android.content.Context
import android.content.res.AssetManager
import android.content.res.Resources
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.AnimeLoadResponse
import com.lagradost.cloudstream3.DubStatus
import com.lagradost.cloudstream3.Episode
import com.lagradost.cloudstream3.LiveStreamLoadResponse
import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.MainActivity
import com.lagradost.cloudstream3.MainPageRequest
import com.lagradost.cloudstream3.MovieLoadResponse
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.TvSeriesLoadResponse
import com.lagradost.cloudstream3.CloudStreamApp
import com.lagradost.cloudstream3.plugins.BasePlugin
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.ui.settings.Globals
import com.lagradost.cloudstream3.utils.ExtractorLink
import dalvik.system.PathClassLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * CloudStream (.cs3) runtime for StreamBox.
 *
 * A `.cs3` is an APK-like ZIP holding Dalvik bytecode compiled against
 * CloudStream's Kotlin API. It is loaded with a [PathClassLoader] whose
 * parent is this app's loader (which carries the bundled CloudStream
 * `library` + the shims in com.lagradost.cloudstream3.*), then its
 * `BasePlugin.load()` registers one or more `MainAPI` providers in
 * [APIHolder.allProviders]. Search / details / links are then plain calls on
 * those `MainAPI` objects.
 *
 * Channel `streambox/cs3` — every argument and result is a JSON string:
 *   info · load · unload · search · details · links · home
 *
 * Security: a plugin is arbitrary code running inside THIS process with
 * THIS app's permissions. It is not sandboxed. The Dart side only hands
 * over packages that passed SHA-256 + structure checks.
 *
 * Failure policy: every plugin call is isolated; a broken plugin yields a
 * coded channel error (INIT_FAILED / TIMEOUT / PROVIDER_FAILED / NOT_LOADED)
 * and never crashes the app.
 */
class Cs3Host(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private class HostError(val code: String, message: String) : Exception(message)

    private class Loaded(val internalName: String, val plugin: BasePlugin)

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val loaded = ConcurrentHashMap<String, Loaded>()

    // Blocking plugin work (network, parsing) must never run on the UI thread.
    private val pool = ThreadPoolExecutor(
        4, 12, 30L, TimeUnit.SECONDS, LinkedBlockingQueue(),
    ) { r -> Thread(r, "streambox-cs3").apply { isDaemon = true } }

    // Link resolution outlives the call that started it (see [links]).
    private val linkScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val linkJobs = ConcurrentHashMap<String, Job>()

    @Volatile
    private var lifecycleEventsFired = false

    init {
        // Plugins and library helpers look for the global application context.
        runCatching { CloudStreamApp.context = context }
        runCatching { com.lagradost.api.setContext(WeakReference<Any>(context)) }
        runCatching { Globals.resolveFrom(context) }
        channel.setMethodCallHandler(this)
    }

    // ------------------------------------------------------------ channel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        pool.execute {
            try {
                val out: String? = when (call.method) {
                    "info" -> info()
                    "load" -> load(
                        arg(call, "internalName"),
                        arg(call, "path"),
                        arg(call, "pluginClassName"),
                    )
                    "unload" -> unload(arg(call, "internalName"))
                    "search" -> search(
                        arg(call, "internalName"),
                        arg(call, "apiName"),
                        arg(call, "query"),
                        call.argument<Int>("page") ?: 1,
                    )
                    "details" -> details(
                        arg(call, "internalName"),
                        arg(call, "apiName"),
                        arg(call, "url"),
                    )
                    "links" -> links(
                        arg(call, "internalName"),
                        arg(call, "apiName"),
                        arg(call, "data"),
                    )
                    "home" -> home(arg(call, "internalName"), arg(call, "apiName"))
                    else -> {
                        main.post { result.notImplemented() }
                        return@execute
                    }
                }
                main.post { result.success(out) }
            } catch (e: HostError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Throwable) {
                Log.w(TAG, "${call.method} failed", e)
                main.post {
                    result.error(
                        "PROVIDER_FAILED",
                        "${e.javaClass.simpleName}: ${e.message ?: ""}".trim(),
                        null,
                    )
                }
            }
        }
    }

    private fun arg(call: MethodCall, name: String): String =
        call.argument<String>(name) ?: throw HostError("BAD_ARGS", "Missing argument: $name")

    private fun info(): String =
        JSONObject()
            .put("available", true)
            .put("apiVersions", JSONArray().put(1))
            .put("runtime", "cloudstream-library")
            .toString()

    // --------------------------------------------------------------- load

    private fun load(internalName: String, path: String, pluginClassName: String): String {
        unload(internalName)

        val file = File(path)
        if (!file.isFile) throw HostError("INIT_FAILED", "The package file is missing.")
        // Android 8+ refuses to load code from a file the app can still write.
        if (file.canWrite()) file.setReadOnly()

        val loader = PathClassLoader(file.absolutePath, context.classLoader)
        val manifest = try {
            loader.getResourceAsStream("manifest.json")?.bufferedReader()?.use {
                JSONObject(it.readText())
            }
        } catch (e: Exception) {
            null
        }
        val className = manifest?.optString("pluginClassName").orEmpty().ifBlank { pluginClassName }
        if (className.isBlank()) throw HostError("INIT_FAILED", "manifest.json names no plugin class.")

        val instance: BasePlugin = try {
            loader.loadClass(className).getDeclaredConstructor().newInstance() as BasePlugin
        } catch (t: Throwable) {
            throw HostError("INIT_FAILED", describe(t))
        }
        // Providers registered by this plugin carry `sourcePlugin = filename`,
        // which is how they are found again (and removed on unload).
        instance.filename = internalName

        if (instance is Plugin && manifest?.optBoolean("requiresResources") == true) {
            instance.needsResources = true
            runCatching { instance.resources = resourcesFor(file) }
        }

        val loadError = runCatching {
            if (instance is Plugin) instance.load(context) else instance.load()
        }.exceptionOrNull()

        // Plugins that register through lifecycle events do it after everyone
        // is loaded; fire those events once, like the real app does.
        fireLifecycleEventsOnce()

        val registered = providersOf(internalName)
        if (registered.isEmpty()) {
            val why = if (loadError != null) describe(loadError)
            else "The package registered no providers."
            throw HostError("INIT_FAILED", why)
        }
        // A plugin that threw AFTER registering (typically while building its
        // own settings screen against a non-activity context) still works.
        if (loadError != null) Log.w(TAG, "$internalName registered but load() threw: ${describe(loadError)}")

        loaded[internalName] = Loaded(internalName, instance)
        val arr = JSONArray()
        for (api in registered) {
            arr.put(
                JSONObject()
                    .put("apiName", api.name)
                    .put("name", api.name)
                    .put("lang", api.lang)
                    .put("supportedTypes", JSONArray(api.supportedTypes.map { it.name }))
                    .put("hasMainPage", api.hasMainPage),
            )
        }
        return arr.toString()
    }

    private fun unload(internalName: String): String? {
        linkJobs.keys.filter { it.startsWith("$internalName|") }.forEach { linkJobs.remove(it)?.cancel() }
        loaded.remove(internalName)
        val providers = APIHolder.allProviders
        synchronized(providers) {
            for (api in providers.filter { it.sourcePlugin == internalName }) {
                providers.remove(api)
                try {
                    APIHolder.removePluginMapping(api)
                } catch (_: Exception) {
                }
            }
        }
        return null
    }

    private fun fireLifecycleEventsOnce() {
        if (lifecycleEventsFired) return
        lifecycleEventsFired = true
        runCatching {
            MainActivity.mainPluginsLoadedEvent(true)
            MainActivity.afterPluginsLoadedEvent(true)
            MainActivity.afterRepositoryLoadedEvent(true)
        }
    }

    @Suppress("DEPRECATION")
    private fun resourcesFor(file: File): Resources {
        val assets = AssetManager::class.java.getDeclaredConstructor().newInstance()
        AssetManager::class.java.getMethod("addAssetPath", String::class.java)
            .invoke(assets, file.absolutePath)
        return Resources(assets, context.resources.displayMetrics, context.resources.configuration)
    }

    private fun providersOf(internalName: String): List<MainAPI> =
        synchronized(APIHolder.allProviders) {
            APIHolder.allProviders.filter { it.sourcePlugin == internalName }
        }

    private fun apiOf(internalName: String, apiName: String): MainAPI {
        if (!loaded.containsKey(internalName)) {
            throw HostError("NOT_LOADED", "The extension is not loaded.")
        }
        return providersOf(internalName).firstOrNull { it.name == apiName }
            ?: throw HostError("NOT_LOADED", "That provider is not loaded.")
    }

    /** `NoClassDefFoundError: X` is the useful part when a shim is missing. */
    private fun describe(t: Throwable): String {
        val root = generateSequence(t) { it.cause }.last()
        val msg = root.message?.takeIf { it.isNotBlank() }
        return if (msg != null) "${root.javaClass.simpleName}: $msg" else root.javaClass.simpleName
    }

    // ---------------------------------------------------------- operations

    private fun search(internalName: String, apiName: String, query: String, page: Int): String {
        val api = apiOf(internalName, apiName)
        var lastError: Throwable? = null
        // Providers implement only ONE of CloudStream's search forms; calling
        // the wrong one hits a default that throws NotImplementedError. Try
        // each: paginated, legacy, then the search-bar variant.
        val results: List<SearchResponse>? = runBlocking {
            withTimeoutOrNull(SEARCH_TIMEOUT_MS) {
                if (page > 1) {
                    runCatching { api.search(query, page)?.items }
                        .onFailure { lastError = it }.getOrNull()
                } else {
                    runCatching { api.search(query) }
                        .onFailure { lastError = it }.getOrNull()
                        ?: runCatching { api.search(query, 1)?.items }
                            .onFailure { lastError = it }.getOrNull()
                        ?: runCatching { api.quickSearch(query) }
                            .onFailure { lastError = it }.getOrNull()
                }
            }
        }
        if (results == null) {
            val err = lastError
            throw if (err != null) HostError("PROVIDER_FAILED", describe(err))
            else HostError("TIMEOUT", "The provider took too long to answer.")
        }
        val arr = JSONArray()
        for (r in results.take(MAX_RESULTS)) arr.put(searchJson(r))
        return arr.toString()
    }

    private fun searchJson(r: SearchResponse): JSONObject =
        JSONObject()
            .put("name", r.name)
            .put("url", r.url)
            .put("posterUrl", r.posterUrl)
            .put("type", r.type?.name)

    private fun details(internalName: String, apiName: String, url: String): String {
        val api = apiOf(internalName, apiName)
        var error: Throwable? = null
        val r: LoadResponse? = runBlocking {
            withTimeoutOrNull(LOAD_TIMEOUT_MS) {
                runCatching { api.load(url) }.onFailure { error = it }.getOrNull()
            }
        }
        if (r == null) {
            val err = error
            throw if (err != null) HostError("PROVIDER_FAILED", describe(err))
            else HostError("TIMEOUT", "The provider took too long to answer.")
        }

        val episodes = JSONArray()
        fun add(e: Episode) = episodes.put(
            JSONObject()
                .put("data", e.data)
                .put("name", e.name)
                .put("season", e.season)
                .put("episode", e.episode)
                .put("posterUrl", e.posterUrl),
        )
        fun addSingle(data: String) = episodes.put(
            JSONObject().put("data", data).put("season", 1).put("episode", 1),
        )
        when (r) {
            is TvSeriesLoadResponse -> r.episodes.forEach { add(it) }
            is AnimeLoadResponse -> {
                // Keyed by dub status: prefer subbed, else dubbed, else whatever
                // the source keyed its list under.
                val by = r.episodes
                val chosen = by[DubStatus.Subbed] ?: by[DubStatus.Dubbed] ?: by.values.flatten()
                chosen.forEach { add(it) }
            }
            is MovieLoadResponse -> addSingle(r.dataUrl)
            is LiveStreamLoadResponse -> addSingle(r.dataUrl)
            else -> Unit
        }
        return JSONObject()
            .put("name", r.name)
            .put("url", r.url)
            .put("type", r.type?.name)
            .put("posterUrl", r.posterUrl)
            .put("backdropUrl", optionalString(r, "getBackgroundPosterUrl"))
            .put("plot", r.plot)
            .put("year", r.year)
            .put("tags", JSONArray(optionalStrings(r, "getTags")))
            .put("episodes", episodes)
            .toString()
    }

    // Optional metadata is read reflectively: these accessors differ between
    // CloudStream versions and must never be able to break a title page.
    private fun optionalString(target: Any, getter: String): String? =
        try {
            target.javaClass.getMethod(getter).invoke(target) as? String
        } catch (_: Throwable) {
            null
        }

    private fun optionalStrings(target: Any, getter: String): List<String> =
        try {
            (target.javaClass.getMethod(getter).invoke(target) as? List<*>)
                ?.mapNotNull { it?.toString() } ?: emptyList()
        } catch (_: Throwable) {
            emptyList()
        }

    /**
     * Resolve playable links. Plugins stream links through a callback and
     * routinely never "finish": return as soon as the first links arrive plus
     * a short grace window for alternatives, and let the resolve keep going
     * in the background (capped) instead of throwing the rest away.
     */
    private fun links(internalName: String, apiName: String, data: String): String {
        val api = apiOf(internalName, apiName)
        val key = "$internalName|$apiName|$data"
        linkJobs.remove(key)?.cancel()

        val found = Collections.synchronizedList(ArrayList<ExtractorLink>())
        val subs = Collections.synchronizedList(ArrayList<SubtitleFile>())
        var failure: Throwable? = null

        val job = linkScope.launch {
            withTimeoutOrNull(LINK_BACKGROUND_CAP_MS) {
                runCatching {
                    api.loadLinks(data, false, { s -> subs.add(s) }, { l -> found.add(l) })
                }.onFailure { failure = it }
            }
        }
        linkJobs[key] = job
        job.invokeOnCompletion { linkJobs.remove(key, job) }

        runBlocking {
            withTimeoutOrNull(LINK_FIRST_CAP_MS) {
                while (found.isEmpty() && job.isActive) delay(50)
                if (found.isNotEmpty()) delay(LINK_GRACE_MS)
            }
        }
        if (found.isEmpty()) {
            val err = failure
            throw if (err != null) HostError("PROVIDER_FAILED", describe(err))
            else HostError("PROVIDER_FAILED", "The provider found no playable source.")
        }

        val outLinks = JSONArray()
        for (l in synchronized(found) { found.toList() }) {
            outLinks.put(
                JSONObject()
                    .put("url", l.url)
                    .put("source", l.name)
                    .put("name", l.name)
                    .put("quality", if (l.quality > 0) l.quality else JSONObject.NULL)
                    .put("isM3u8", l.isM3u8)
                    .put("headers", headersFor(l)),
            )
        }
        val outSubs = JSONArray()
        for (s in synchronized(subs) { subs.toList() }) {
            outSubs.put(JSONObject().put("lang", s.lang).put("url", s.url))
        }
        return JSONObject().put("links", outLinks).put("subtitles", outSubs).toString()
    }

    /** The player fetches the stream itself, so give it what the site expects. */
    private fun headersFor(link: ExtractorLink): JSONObject {
        val h = JSONObject()
        link.headers?.forEach { (k, v) -> h.put(k, v) }
        fun has(name: String) = h.keys().asSequence().any { it.equals(name, ignoreCase = true) }
        val referer = link.referer?.toString().orEmpty()
        if (referer.isNotBlank() && !has("Referer")) h.put("Referer", referer)
        if (referer.isNotBlank() && !has("Origin")) {
            runCatching {
                val u = java.net.URI(referer)
                if (!u.scheme.isNullOrBlank() && !u.host.isNullOrBlank()) {
                    val port = if (u.port > 0) ":${u.port}" else ""
                    h.put("Origin", "${u.scheme}://${u.host}$port")
                }
            }
        }
        if (!has("User-Agent")) h.put("User-Agent", BROWSER_UA)
        return h
    }

    /** The provider's home rows (its `mainPage` categories), fetched concurrently. */
    private fun home(internalName: String, apiName: String): String {
        val api = apiOf(internalName, apiName)
        val rows = JSONArray()
        if (!api.hasMainPage) return rows.toString()
        runBlocking {
            val responses = api.mainPage.take(MAX_HOME_ROWS).map { mp ->
                async(Dispatchers.IO) {
                    withTimeoutOrNull(HOME_ROW_TIMEOUT_MS) {
                        runCatching {
                            api.getMainPage(1, MainPageRequest(mp.name, mp.data, false))
                        }.onFailure { Log.w(TAG, "home '${mp.name}' failed", it) }.getOrNull()
                    }
                }
            }.awaitAll()
            for (resp in responses) {
                if (resp == null) continue
                for (list in resp.items) {
                    val items = JSONArray()
                    for (r in list.list.take(MAX_RESULTS)) items.put(searchJson(r))
                    if (items.length() > 0) {
                        rows.put(JSONObject().put("title", list.name).put("items", items))
                    }
                }
            }
        }
        return rows.toString()
    }

    companion object {
        const val CHANNEL = "streambox/cs3"
        private const val TAG = "StreamBoxCs3"

        private const val SEARCH_TIMEOUT_MS = 15_000L
        private const val LOAD_TIMEOUT_MS = 45_000L
        private const val HOME_ROW_TIMEOUT_MS = 10_000L
        private const val LINK_FIRST_CAP_MS = 20_000L
        private const val LINK_GRACE_MS = 800L
        private const val LINK_BACKGROUND_CAP_MS = 60_000L
        private const val MAX_RESULTS = 60
        private const val MAX_HOME_ROWS = 8

        private const val BROWSER_UA =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36"
    }
}
