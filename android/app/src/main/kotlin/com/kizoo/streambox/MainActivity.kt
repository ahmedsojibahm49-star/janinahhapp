package com.kizoo.streambox

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var updater: AppUpdater? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        updater = AppUpdater(this, messenger)
        registerOptionalCs3(flutterEngine)
    }

    /**
     * The CloudStream (.cs3) runtime is an OPTIONAL build flavour
     * (`-Pcs3=true`). It lives in src/cs3/ and is looked up by reflection so
     * the default build never depends on it. When it is absent the Dart
     * side gets MissingPluginException and reports "extensions not
     * available in this build" instead of failing.
     */
    private fun registerOptionalCs3(flutterEngine: FlutterEngine) {
        try {
            val cls = Class.forName("com.kizoo.streambox.cs3.Cs3Host")
            cls.getConstructor(
                android.content.Context::class.java,
                io.flutter.plugin.common.BinaryMessenger::class.java,
            ).newInstance(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        } catch (_: ClassNotFoundException) {
            // Default build: no CloudStream runtime.
        } catch (_: Throwable) {
            // A broken optional runtime must never crash app start.
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        updater?.dispose()
        updater = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
