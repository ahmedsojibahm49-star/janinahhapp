import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: reads android/key.properties when present (created by
// the GitHub Actions workflow from secrets, or by hand for local builds).
// Without it the release build falls back to the debug keys so
// `flutter run --release` keeps working — but a debug-signed APK triggers
// stronger Play Protect warnings, so published releases should always be
// signed with the release key. NEVER commit key.properties or the
// keystore — both are gitignored (see .gitignore).
val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.exists()) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}
val hasReleaseSigning = keyPropertiesFile.exists() &&
    keyProperties["storeFile"] != null &&
    keyProperties["storePassword"] != null &&
    keyProperties["keyAlias"] != null &&
    keyProperties["keyPassword"] != null

// CloudStream (.cs3) runtime: ON by default — it is what lets installed
// extensions actually run. STREAMBOX_CS3=0 builds without it (the CI
// workflow uses that as a safety net if the runtime build fails), in which
// case the app reports "extensions are not available in this build".
// Sources: android/app/src/cs3/. License: CloudStream's library is GPL-3.0.
val withCs3 = System.getenv("STREAMBOX_CS3") != "0"
val cs3LibraryVersion = System.getenv("STREAMBOX_CS3_LIB") ?: "v4.9.1"

android {
    namespace = "com.kizoo.streambox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // The CloudStream library uses java.time & friends on older Androids.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources {
            // The CloudStream library and its dependencies ship overlapping
            // META-INF files; none of them is needed at runtime.
            excludes += listOf(
                "META-INF/*.kotlin_module",
                "META-INF/INDEX.LIST",
                "META-INF/io.netty.versions.properties",
                "META-INF/*.version",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/DEPENDENCIES",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
            )
        }
    }

    lint {
        // Android Lint crashes on the video_player_android plugin during
        // release builds (:video_player_android:lintVitalAnalyzeRelease fails
        // with a NoSuchMethodError inside lint's own JavaDocParser — a bug in
        // lint, not in our code). Disable release lint checks so the APK
        // build is not blocked by it.
        checkReleaseBuilds = false
        abortOnError = false
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.kizoo.streambox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    sourceSets {
        if (withCs3) {
            getByName("main").java.srcDir("src/cs3/kotlin")
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(keyProperties["storeFile"] as String)
                storePassword = keyProperties["storePassword"] as String
                keyAlias = keyProperties["keyAlias"] as String
                keyPassword = keyProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // .cs3 plugins are external bytecode that links to the bundled
            // CloudStream library BY NAME. R8 renaming/stripping those
            // classes makes every plugin fail to load, so minification and
            // resource shrinking stay OFF.
            isMinifyEnabled = false
            isShrinkResources = false

            // Release-signed when key.properties is present, debug-signed
            // otherwise (local runs without the keystore keep working).
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Recently built plugins call kotlinx.coroutines functions that only exist
// from 1.11.0 (e.g. BuildersKt.runBlockingK) straight from their own dex, so
// the app must ship that version or they fail to link. 1.11 is a superset of
// older releases, so forcing it on every configuration is safe.
configurations.configureEach {
    resolutionStrategy {
        force("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
        force("org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.11.0")
        force("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    if (withCs3) {
        // CloudStream's plugin API (MainAPI, extractors, NiceHttp client).
        implementation("com.github.recloudstream.cloudstream:library:$cs3LibraryVersion")
        implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
        // Jackson already ships at runtime inside the CloudStream library;
        // compileOnly just lets the DataStore shim reference JsonMapper.
        compileOnly("com.fasterxml.jackson.module:jackson-module-kotlin:2.13.1")
        // OkHttp is bundled by the library at runtime (NiceHttp is built on
        // it); compileOnly lets the CloudflareKiller stand-in implement
        // okhttp3.Interceptor.
        compileOnly("com.squareup.okhttp3:okhttp:4.12.0")
    }
}

flutter {
    source = "../.."
}
