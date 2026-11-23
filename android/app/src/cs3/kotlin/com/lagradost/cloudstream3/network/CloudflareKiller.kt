package com.lagradost.cloudstream3.network

import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Six of the popular plugins reference this class (`interceptor =
 * CloudflareKiller()`), so it must exist for them to load at all.
 *
 * The real one solves Cloudflare's browser check inside a WebView. This
 * stand-in does NOT: it simply forwards the request. Sources behind an
 * active Cloudflare challenge will therefore fail with a 403/503 (the
 * provider then reports an error), while every source without one works.
 */
class CloudflareKiller : Interceptor {
    companion object {
        const val TAG = "CloudflareKiller"

        fun parseCookieMap(cookie: String): Map<String, String> =
            cookie.split(";").associate {
                val parts = it.split("=")
                (parts.getOrNull(0)?.trim() ?: "") to (parts.getOrNull(1)?.trim() ?: "")
            }.filter { it.key.isNotBlank() && it.value.isNotBlank() }
    }

    val savedCookies: MutableMap<String, Map<String, String>> = mutableMapOf()

    fun getCookieHeaders(url: String): Headers = Headers.Builder().build()

    override fun intercept(chain: Interceptor.Chain): Response = chain.proceed(chain.request())
}
