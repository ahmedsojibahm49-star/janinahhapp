import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../services/storage.dart';
import 'core/host.dart';

/// Real implementations of the injected edges from `core/host.dart`.

// ------------------------------------------------------------------ http

/// HTTPS-only fetcher with streaming size cap, idle timeout, progress.
class HttpExtensionFetcher implements ExtensionFetcher {
  const HttpExtensionFetcher();

  static const String _userAgent = 'StreamBox/1.0 (extension manager)';

  @override
  Future<Uint8List> fetch(
    Uri url, {
    Duration timeout = const Duration(seconds: 20),
    int maxBytes = 10 * 1024 * 1024,
    ProgressCallback? onProgress,
  }) async {
    if (!url.isScheme('https')) {
      throw const FetchException(
          FetchFailure.network, 'Only https:// addresses are allowed.');
    }
    // A client per call: nothing stays open between fetches.
    final client = http.Client();
    try {
      final request = http.Request('GET', url)
        ..headers['User-Agent'] = _userAgent
        ..headers['Accept'] = '*/*';
      final response = await client.send(request).timeout(timeout);

      // A redirect must not downgrade to plain http.
      final finalUrl =
          response is http.BaseResponseWithUrl ? response.url : url;
      if (!finalUrl.isScheme('https')) {
        throw const FetchException(
            FetchFailure.network, 'The server redirected to an insecure URL.');
      }
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw FetchException(
          FetchFailure.http,
          'The server answered HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      }
      final declared = response.contentLength;
      if (declared != null && declared > maxBytes) {
        throw const FetchException(
            FetchFailure.tooLarge, 'The file is larger than allowed.');
      }

      final builder = BytesBuilder(copy: false);
      var received = 0;
      // Idle timeout per chunk: a stalled connection fails, a slow but
      // moving download of a big package does not.
      await for (final chunk in response.stream.timeout(timeout)) {
        received += chunk.length;
        if (received > maxBytes) {
          throw const FetchException(
              FetchFailure.tooLarge, 'The file is larger than allowed.');
        }
        builder.add(chunk);
        onProgress?.call(received, declared);
      }
      return builder.takeBytes();
    } on FetchException {
      rethrow;
    } on TimeoutException {
      throw const FetchException(
          FetchFailure.timeout, 'The server took too long to respond.');
    } on SocketException catch (e) {
      throw FetchException(FetchFailure.network, e.message);
    } on HandshakeException {
      throw const FetchException(
          FetchFailure.network, 'Secure connection failed (TLS).');
    } on http.ClientException catch (e) {
      throw FetchException(FetchFailure.network, e.message);
    } finally {
      client.close();
    }
  }
}

// --------------------------------------------------------------- storage

/// Hive-backed string store (`extensions` box). Falls back to memory when
/// the box is not open so a screen can never crash on it.
class HiveKeyValueStore implements KeyValueStore {
  HiveKeyValueStore()
      : _box = Hive.isBoxOpen(BoxNames.extensions)
            ? Hive.box<String>(BoxNames.extensions)
            : null;

  final Box<String>? _box;
  final Map<String, String> _memory = {};

  @override
  String? read(String key) {
    final box = _box;
    return box != null ? box.get(key) : _memory[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final box = _box;
    if (box != null) {
      await box.put(key, value);
    } else {
      _memory[key] = value;
    }
  }

  @override
  Future<void> delete(String key) async {
    final box = _box;
    if (box != null) {
      await box.delete(key);
    } else {
      _memory.remove(key);
    }
  }
}

/// Packages live in `<app support>/extensions/`, private to the app.
class FilePackageStorage implements PackageStorage {
  FilePackageStorage({Future<Directory> Function()? baseDir})
      : _baseDir = baseDir ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDir;

  Future<Directory> _dir() async {
    final base = await _baseDir();
    final dir = Directory('${base.path}/extensions');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<String> save(String fileName, Uint8List bytes) async {
    final dir = await _dir();
    // Basename only: never let a file name escape the folder.
    final safe = fileName.split(RegExp(r'[\\/]')).last;
    if (safe.isEmpty || safe.startsWith('.')) {
      throw const FileSystemException('Invalid package file name');
    }
    final target = File('${dir.path}/$safe');
    final tmp = File('${dir.path}/.$safe.part');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
    return target.path;
  }

  @override
  Future<void> delete(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<bool> exists(String path) => File(path).exists();
}
