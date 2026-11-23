package com.lagradost.cloudstream3.utils

import android.content.Context
import android.content.SharedPreferences
import com.fasterxml.jackson.databind.json.JsonMapper
import com.fasterxml.jackson.module.kotlin.kotlinModule

/**
 * JSON-in-SharedPreferences store with the app's `DataStore` API. The
 * Context-receiver functions compile to static-style methods taking the
 * Context first, which is exactly how plugin bytecode calls them.
 */
object DataStore {
    private const val PREFS = "streambox_cs3_datastore"

    val mapper: JsonMapper = JsonMapper.builder().addModule(kotlinModule()).build()

    fun getSharedPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun getDefaultSharedPrefs(context: Context): SharedPreferences = getSharedPrefs(context)

    fun getFolderName(folder: String, path: String): String = "$folder/$path"

    fun <T> Context.setKey(path: String, value: T) {
        try {
            getSharedPrefs(this).edit().putString(path, mapper.writeValueAsString(value)).apply()
        } catch (_: Exception) {
        }
    }

    fun <T> Context.setKey(folder: String, path: String, value: T) =
        setKey(getFolderName(folder, path), value)

    fun <T> Context.getKey(path: String, valueType: Class<T>): T? {
        val json = getSharedPrefs(this).getString(path, null) ?: return null
        return try {
            mapper.readValue(json, valueType)
        } catch (_: Exception) {
            null
        }
    }

    fun <T> toKotlinObject(value: String, valueType: Class<T>): T = mapper.readValue(value, valueType)

    fun Context.getKeys(folder: String): List<String> {
        val prefix = folder.trimEnd('/') + "/"
        return try {
            getSharedPrefs(this).all.keys.filter { it.startsWith(prefix) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun Context.containsKey(path: String): Boolean =
        try {
            getSharedPrefs(this).contains(path)
        } catch (_: Exception) {
            false
        }

    fun Context.containsKey(folder: String, path: String): Boolean =
        containsKey(getFolderName(folder, path))

    fun Context.removeKey(path: String) {
        try {
            val prefs = getSharedPrefs(this)
            if (prefs.contains(path)) prefs.edit().remove(path).apply()
        } catch (_: Exception) {
        }
    }

    fun Context.removeKey(folder: String, path: String) = removeKey(getFolderName(folder, path))

    fun Context.removeKeys(folder: String): Int =
        try {
            val keys = getKeys(folder)
            val editor = getSharedPrefs(this).edit()
            keys.forEach { editor.remove(it) }
            editor.apply()
            keys.size
        } catch (_: Exception) {
            0
        }
}

/** Observer list behind the app's lifecycle events (`plusAssign`/`invoke`). */
class Event<T> {
    private val observers = mutableSetOf<(T) -> Unit>()

    val size: Int get() = synchronized(observers) { observers.size }

    operator fun plusAssign(observer: (T) -> Unit) {
        synchronized(observers) { observers.add(observer) }
    }

    operator fun minusAssign(observer: (T) -> Unit) {
        synchronized(observers) { observers.remove(observer) }
    }

    operator fun invoke(value: T) {
        val snapshot = synchronized(observers) { observers.toList() }
        for (observer in snapshot) observer(value)
    }
}

class EmptyEvent {
    private val observers = mutableSetOf<Runnable>()

    val size: Int get() = synchronized(observers) { observers.size }

    operator fun plusAssign(observer: Runnable) {
        synchronized(observers) { observers.add(observer) }
    }

    operator fun minusAssign(observer: Runnable) {
        synchronized(observers) { observers.remove(observer) }
    }

    operator fun invoke() {
        val snapshot = synchronized(observers) { observers.toList() }
        for (observer in snapshot) observer.run()
    }
}

/** Plugins only type-reference this; turning it into a string needs real UI. */
open class UiText {
    fun asString(context: Context): String = ""

    fun asStringNull(context: Context): String? = null
}
