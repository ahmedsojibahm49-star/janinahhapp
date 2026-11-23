import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_core.dart';

/// In-app updater state machine: check GitHub for a newer release,
/// download the APK (streamed to disk, with progress), verify it, then hand
/// it to Android's PackageInstaller through the `streambox/update` channel.
///
/// Android only installs it over the current app when it is signed with the
/// same key — see [UpdateState.signatureMismatch] for the explicit message
/// when that is not the case.

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  needsPermission,
  downloading,
  verifying,
  installing,
  error,
}

enum UpdateError {
  none,
  unsupported,
  network,
  noRelease,
  download,
  integrity,
  installFailed,
  signatureMismatch,
}

@immutable
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.currentVersion,
    this.info,
    this.received = 0,
    this.total,
    this.error = UpdateError.none,
    this.detail,
  });

  final UpdatePhase phase;

  /// Installed `versionName`, e.g. `1.0.5` (null until read).
  final String? currentVersion;
  final UpdateInfo? info;
  final int received;
  final int? total;
  final UpdateError error;

  /// Raw message from the installer / network, for diagnostics.
  final String? detail;

  bool get signatureMismatch => error == UpdateError.signatureMismatch;

  /// 0..1 while downloading with a known size.
  double? get fraction {
    final t = total;
    if (phase != UpdatePhase.downloading || t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.verifying ||
      phase == UpdatePhase.installing;

  UpdateState copyWith({
    UpdatePhase? phase,
    String? currentVersion,
    UpdateInfo? info,
    int? received,
    int? total,
    bool clearTotal = false,
    UpdateError? error,
    String? detail,
    bool clearDetail = false,
  }) =>
      UpdateState(
        phase: phase ?? this.phase,
        currentVersion: currentVersion ?? this.currentVersion,
        info: info ?? this.info,
        received: received ?? this.received,
        total: clearTotal ? null : (total ?? this.total),
        error: error ?? this.error,
        detail: clearDetail ? null : (detail ?? this.detail),
      );
}

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

class UpdateController extends Notifier<UpdateState> {
  static const MethodChannel _channel = MethodChannel('streambox/update');

  bool _autoChecked = false;

  bool get supported => !kIsWeb && Platform.isAndroid;

  @override
  UpdateState build() {
    if (supported) {
      _channel.setMethodCallHandler(_onNative);
      ref.onDispose(() => _channel.setMethodCallHandler(null));
    }
    return const UpdateState();
  }

  // ---------------------------------------------------------- native

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method != 'installResult') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    if (args['success'] == true) {
      // The app is normally replaced and restarted before we get here.
      state = state.copyWith(
          phase: UpdatePhase.idle, error: UpdateError.none, clearDetail: true);
      return null;
    }
    final message = (args['message'] as String?) ?? '';
    state = state.copyWith(
      phase: UpdatePhase.error,
      error: isSignatureMismatch(message)
          ? UpdateError.signatureMismatch
          : UpdateError.installFailed,
      detail: message,
    );
    return null;
  }

  Future<String?> _currentVersion() async {
    if (!supported) return null;
    try {
      final raw = await _channel.invokeMethod<String>('version');
      if (raw == null) return null;
      final j = jsonDecode(raw);
      return j is Map ? j['versionName'] as String? : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> _canInstall() async {
    try {
      final raw = await _channel.invokeMethod<String>('version');
      final j = raw == null ? null : jsonDecode(raw);
      return j is Map && j['canInstall'] == true;
    } on PlatformException {
      return false;
    }
  }

  // ----------------------------------------------------------- check

  /// Once per app run, never shows errors. Safe to call at startup.
  Future<void> autoCheck() async {
    if (_autoChecked || !supported) return;
    _autoChecked = true;
    await check(silent: true);
  }

  Future<void> check({bool silent = false}) async {
    if (state.busy) return;
    if (!supported) {
      if (!silent) {
        state = state.copyWith(
            phase: UpdatePhase.error, error: UpdateError.unsupported);
      }
      return;
    }
    state = state.copyWith(
        phase: UpdatePhase.checking,
        error: UpdateError.none,
        clearDetail: true);
    final versionName = await _currentVersion();
    final current =
        versionName == null ? null : AppVersion.tryParse(versionName);
    if (current == null) {
      state = state.copyWith(
          phase: silent ? UpdatePhase.idle : UpdatePhase.error,
          currentVersion: versionName,
          error: UpdateError.network,
          detail: 'Could not read the installed version.');
      return;
    }
    try {
      final info = await checkForUpdate(
        current: current,
        resolveRedirect: _resolveRedirect,
      );
      state = info == null
          ? state.copyWith(
              phase: UpdatePhase.upToDate,
              currentVersion: current.toString())
          : state.copyWith(
              phase: UpdatePhase.available,
              currentVersion: current.toString(),
              info: info);
    } on UpdateCheckException catch (e) {
      state = state.copyWith(
        phase: silent ? UpdatePhase.idle : UpdatePhase.error,
        currentVersion: current.toString(),
        error: UpdateError.noRelease,
        detail: e.message,
      );
    } on TimeoutException {
      _networkFailure(silent, current.toString(), 'Timed out.');
    } on SocketException catch (e) {
      _networkFailure(silent, current.toString(), e.message);
    } on http.ClientException catch (e) {
      _networkFailure(silent, current.toString(), e.message);
    } on Object catch (e) {
      // Anything else (TLS handshake, bad redirect...) must not leave the
      // sheet spinning on "Checking…" forever.
      _networkFailure(silent, current.toString(), e.toString());
    }
  }

  void _networkFailure(bool silent, String current, String detail) {
    state = state.copyWith(
      phase: silent ? UpdatePhase.idle : UpdatePhase.error,
      currentVersion: current,
      error: UpdateError.network,
      detail: detail,
    );
  }

  /// GET without following redirects; returns the Location header.
  Future<String?> _resolveRedirect(Uri url) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', url)
        ..followRedirects = false
        ..headers['User-Agent'] = 'StreamBox-updater';
      final res = await client.send(req).timeout(const Duration(seconds: 15));
      unawaited(res.stream.drain<void>().catchError((_) {}));
      return res.headers['location'];
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------- update

  /// Download → verify → install the release found by [check].
  Future<void> startUpdate() async {
    final info = state.info;
    if (info == null || state.busy || !supported) return;

    if (!await _canInstall()) {
      state = state.copyWith(phase: UpdatePhase.needsPermission);
      try {
        await _channel.invokeMethod<bool>('openInstallSettings');
      } on PlatformException {
        // The sheet still explains what to enable.
      }
      return;
    }

    state = state.copyWith(
        phase: UpdatePhase.downloading,
        received: 0,
        clearTotal: true,
        error: UpdateError.none,
        clearDetail: true);
    File? file;
    try {
      file = await _download(info);
      state = state.copyWith(phase: UpdatePhase.verifying);
      await _verify(file, info);
      state = state.copyWith(phase: UpdatePhase.installing);
      await _channel.invokeMethod<bool>('install', {'path': file.path});
      // Result arrives via _onNative; the system dialog is up meanwhile.
    } on _UpdateFailure catch (e) {
      if (file != null) unawaited(_safeDelete(file));
      state = state.copyWith(
          phase: UpdatePhase.error, error: e.error, detail: e.detail);
    } on PlatformException catch (e) {
      if (e.code == 'NEEDS_PERMISSION') {
        state = state.copyWith(phase: UpdatePhase.needsPermission);
      } else {
        state = state.copyWith(
          phase: UpdatePhase.error,
          error: isSignatureMismatch(e.message)
              ? UpdateError.signatureMismatch
              : UpdateError.installFailed,
          detail: e.message ?? e.code,
        );
      }
    } on TimeoutException {
      if (file != null) unawaited(_safeDelete(file));
      state = state.copyWith(
          phase: UpdatePhase.error,
          error: UpdateError.download,
          detail: 'The download stalled.');
    } on SocketException catch (e) {
      if (file != null) unawaited(_safeDelete(file));
      state = state.copyWith(
          phase: UpdatePhase.error,
          error: UpdateError.download,
          detail: e.message);
    } on http.ClientException catch (e) {
      if (file != null) unawaited(_safeDelete(file));
      state = state.copyWith(
          phase: UpdatePhase.error,
          error: UpdateError.download,
          detail: e.message);
    } on Object catch (e) {
      // e.g. storage full (FileSystemException) or a TLS failure: show an
      // error instead of staying on "Downloading…" forever.
      if (file != null) unawaited(_safeDelete(file));
      state = state.copyWith(
          phase: UpdatePhase.error,
          error: UpdateError.download,
          detail: e.toString());
    }
  }

  Future<File> _download(UpdateInfo info) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/update');
    if (await dir.exists()) {
      await dir.delete(recursive: true); // old APKs: free the space
    }
    await dir.create(recursive: true);
    final file = File('${dir.path}/streambox-${info.tag}.apk');

    final client = http.Client();
    IOSink? sink;
    try {
      final req = http.Request('GET', info.apkUrl)
        ..headers['User-Agent'] = 'StreamBox-updater';
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw _UpdateFailure(UpdateError.download,
            'The server answered HTTP ${res.statusCode}.');
      }
      final finalUrl = res is http.BaseResponseWithUrl ? res.url : info.apkUrl;
      if (!finalUrl.isScheme('https')) {
        throw const _UpdateFailure(
            UpdateError.download, 'Redirected to an insecure URL.');
      }
      final total = res.contentLength;
      state = state.copyWith(total: total);
      sink = file.openWrite();
      var received = 0;
      var lastReported = 0;
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        // ~1% steps keep rebuilds cheap.
        if (total == null || received - lastReported >= total ~/ 100) {
          lastReported = received;
          state = state.copyWith(received: received);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      state = state.copyWith(received: received);
      if (total != null && received != total) {
        throw _UpdateFailure(UpdateError.download,
            'Incomplete download ($received of $total bytes).');
      }
      return file;
    } finally {
      await sink?.close();
      client.close();
    }
  }

  Future<void> _verify(File file, UpdateInfo info) async {
    // 1. Really an APK (a ZIP): "PK\x03\x04".
    final head = await file.openRead(0, 4).expand((b) => b).toList();
    if (head.length < 4 ||
        head[0] != 0x50 ||
        head[1] != 0x4b ||
        head[2] != 0x03 ||
        head[3] != 0x04) {
      throw const _UpdateFailure(
          UpdateError.integrity, 'The downloaded file is not an APK.');
    }
    // 2. SHA-256 against the published .sha256 (when the release has one).
    String? expected;
    final client = http.Client();
    try {
      final res = await client
          .get(info.checksumUrl,
              headers: {'User-Agent': 'StreamBox-updater'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) expected = parseChecksum(res.body);
    } on Object {
      expected = null; // optional: Android still verifies the signature
    } finally {
      client.close();
    }
    if (expected != null) {
      final digest = await crypto.sha256.bind(file.openRead()).first;
      if (digest.toString() != expected) {
        throw const _UpdateFailure(UpdateError.integrity,
            'The download does not match its published SHA-256.');
      }
    }
  }

  Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on Object {
      // Cache dir; the OS will reclaim it.
    }
  }

  void reset() {
    if (state.busy) return;
    state = state.copyWith(
        phase: UpdatePhase.idle, error: UpdateError.none, clearDetail: true);
  }
}

class _UpdateFailure implements Exception {
  const _UpdateFailure(this.error, this.detail);
  final UpdateError error;
  final String detail;
}
