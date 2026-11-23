# v1.0.6

## 1. Updates without uninstalling

**Why you had to uninstall every time.** Android only updates an app in place
when the new APK is signed with the *same* key as the installed one. Every
release so far was signed with a different key (checked on the published
APKs — v1.0.1, v1.0.3, v1.0.4 and v1.0.5 have four different certificate
SHA-256 values), because the GitHub Actions run had no signing secrets and
fell back to a throw-away debug key that is created fresh on every run.

**What changed**

* `build-apk.yml` now **fails a tag build** if the four signing secrets are
  missing, so a debug-signed release can never be published again.
* The workflow prints the signing certificate for every build (step
  “Show signing certificate”) and publishes `streambox-<tag>.apk.sha256`.
* New in-app updater: Settings → *Check for updates* (and a quiet check about
  4 s after launch). It reads the latest GitHub release, downloads the APK,
  verifies the SHA-256, and installs it over the app with Android's
  PackageInstaller. If Android rejects it because of a key mismatch, the
  sheet says so in plain words instead of failing silently.

**One-time setup (needed once, then updates are one tap):**

1. On a computer: `bash tool/print-signing-secrets.sh android/streambox-release.keystore`
2. GitHub → repo → Settings → Secrets and variables → Actions → add
   `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
   `ANDROID_KEY_PASSWORD` (values from the script and `keystore-passwords.txt`).
3. Push the tag (`git tag v1.0.6 && git push origin v1.0.6`).
4. **Uninstall the current app one last time** and install v1.0.6 — the
   installed v1.0.5 carries a random debug key that can never be updated.
   From v1.0.6 on, every release keeps the same key and the in-app *Update
   now* button works. Never lose the keystore: with a new key you are back to
   uninstalling.

Every release must also raise `version:` in `pubspec.yaml` (`1.0.6+6` →
`1.0.7+7`) and the hard-coded `settings.aboutVersion` strings (a test checks).

## 2. Camera notch

The app runs in immersive mode, which hides the status bar, so Flutter
reports `padding.top == 0` while the camera cut-out is still there and
content slid under the camera. `withCutoutSafePadding` (MaterialApp
`builder`) reads the cut-out rectangles and lifts the padding past them — no
screen had to change. Math is unit-tested (`test/cutout_insets_test.dart`).

## 3. Icons

Already done in v1.0.5 and re-verified: all 57 icons in `lib/` are Linear
(`_copy`) and there are no trailing chevrons. Nothing added in this release
uses a Bold icon or a decorative one.

## 4. Extensions (Settings → Providers → Extensions)

* Add a `repo.json` (or a `plugins.json`, GitHub blob link or
  `cloudstreamrepo://` link). Pasting one into *Add provider* also works: it
  is tried as a catalog first, then handed to the extension manager.
* Extension Store with search, sort, filters (All, Installed, Not installed,
  Enabled, Disabled, Anime, Movies, TV series, Other), install / enable /
  disable / update / update all / uninstall / details.
* Install pipeline: compatibility check → download (streamed, size-capped,
  https only) → size + SHA-256 check → ZIP/`manifest.json`/`classes.dex`
  validation → load in the native runtime → only then recorded as installed.
  Any failure leaves nothing installed (and keeps a working older version).
* Enabled extensions add rails to Home (pull to refresh) and join Search (concurrent, per-provider timeout, partial
  results when one fails, source shown under each result); Details loads the
  episodes from the provider; the existing Player resolves the stream on
  demand (headers, fallback sources, one subtitle track).
* State (repositories, installed packages, enable flags) is kept in a Hive
  box of JSON strings — no adapters/codegen.

### Limits — read this

* **The `.cs3` runtime is Android-only and built into the default APK.**
  `.cs3` files are Dalvik bytecode compiled against CloudStream's Kotlin API,
  so `android/app/src/cs3/` hosts them: a `PathClassLoader` loads the package,
  the plugin registers its `MainAPI` providers, and search / details /
  links / home rows are plain calls on those objects (the same architecture
  as the open-source Zangetsu app; written independently).
  What was verified without a phone:
  * the Kotlin host, shims and updater **compile with kotlinc 2.4.20 against
    CloudStream's real `classes.jar`** (no errors);
  * every shim signature that plugins call was compared with the real app
    class (name + JVM descriptor);
  * all **87 plugins of the Phisher repository** were scanned at bytecode
    level: 532 references into the shim classes, 3 unresolved (rare, in
    2 plugins: `Ultima`, `WatchParty`).
  What was NOT verified: running on a device, and Gradle/JitPack resolving
  the CloudStream library inside GitHub Actions. The workflow therefore tries
  library v4.9.1, then v4.8.0, then builds without the runtime (the app then
  says so on the Extensions screen) — a bad dependency can never cost a
  release, and the log tells which rung was used.
* Known gaps: Cloudflare-challenged sources (the WebView solver is not
  ported — 6 plugins reference it), tracker/sync features (AniList etc.),
  and plugin settings screens. A plugin that needs a class the host lacks
  fails with `NoClassDefFoundError: <name>` shown in its details.
* **Extensions are third-party code running inside StreamBox with its
  permissions. They are not sandboxed.** Add only repositories you trust.
* Linking CloudStream's GPL-3.0 library means a build that includes it must
  be distributed under GPL-3.0.
* Extension settings screens (Android UI inside the plugin) are not shown.
* NSFW / torrent / audio types are filtered out of live results.

## Debug pass (found by reading/analysing the code without a Flutter SDK)

* `HiveKeyValueStore`: a `late final` nullable field cannot be null-checked
  and then used — that is a compile error; rewritten with a local copy.
* `flutter analyze` would have failed on an unused import
  (`extensions_screen.dart`) and two missing `const` in tests; fixed.
* Riverpod 3 retries failed providers automatically. A provider site that
  errors would have been called up to 10 times and the screen would have
  spun for a minute; retry is now off for live search/details (the Retry
  button does it on demand).
* Updater: any unexpected exception (TLS, storage full) left the sheet on
  “Checking…/Downloading…” forever; now ends in an error state. A stale
  download size from a previous attempt no longer leaks into the next.
* Search and Player are byte-for-byte unchanged unless an extension is
  actually enabled (no extra spinner, no extra widget around the video).

## Fixes after the first field test

* “Plugins do not install”: the first APK shipped without the runtime, so
  every install was refused. The runtime is now part of the default build.
* “No logos”: 18 of the 87 icon URLs contain a `%size%` placeholder that
  404s as written; it is now filled in. (Also fixed: the real `fileHash`
  format is `sha256-<hex>`; the old parser ignored it, so downloads were not
  being hash-checked. All 87 entries are checked now.)
* “Nothing shows”: Search only works after typing. Home now shows each
  enabled provider's own rows.
* Search used a single plugin search method; plugins implement one of three.
  All three are tried. Link resolution no longer waits for a callback that
  many plugins never finish: it returns as soon as links arrive.
* A plugin that hangs while starting times out after 60 s instead of
  freezing the install.
