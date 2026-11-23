import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'models.dart';
import 'sha256.dart';

/// What we learned from inspecting a `.cs3` package.
class PackageInfo {
  const PackageInfo({
    required this.pluginClassName,
    required this.dexCount,
    this.name,
    this.version,
    this.requiresResources = false,
  });

  final String pluginClassName;
  final int dexCount;
  final String? name;
  final int? version;
  final bool requiresResources;
}

/// Why a downloaded package was rejected.
enum PackageProblem {
  empty,
  tooLarge,
  sizeMismatch,
  hashMismatch,
  notAZip,
  noDex,
  noManifest,
  badManifest,
}

class PackageException implements Exception {
  const PackageException(this.problem, this.message);
  final PackageProblem problem;
  final String message;
  @override
  String toString() => message;
}

const int maxPackageBytes = 64 * 1024 * 1024;
const int _maxManifestBytes = 256 * 1024;

/// Full integrity + format gate. Throws [PackageException].
///
/// 1. non-empty and within [maxPackageBytes]
/// 2. matches the advertised `fileSize` (when given)
/// 3. SHA-256 equals the advertised `fileHash` (when given)
/// 4. is really a ZIP containing `classes*.dex` and a valid
///    `manifest.json` with `pluginClassName`
PackageInfo verifyPackage(Uint8List bytes, PluginEntry entry) {
  if (bytes.isEmpty) {
    throw const PackageException(
        PackageProblem.empty, 'The download was empty.');
  }
  if (bytes.length > maxPackageBytes) {
    throw const PackageException(
        PackageProblem.tooLarge, 'The package is too large.');
  }
  final expectedSize = entry.fileSize;
  if (expectedSize != null &&
      expectedSize > 0 &&
      expectedSize != bytes.length) {
    throw PackageException(
      PackageProblem.sizeMismatch,
      'Incomplete or changed download '
      '(${bytes.length} of $expectedSize bytes).',
    );
  }
  final expectedHash = entry.fileHash;
  if (expectedHash != null && sha256Hex(bytes) != expectedHash) {
    throw const PackageException(
      PackageProblem.hashMismatch,
      'Integrity check failed: the SHA-256 does not match the repository.',
    );
  }
  return inspectCs3(bytes);
}

/// Open a `.cs3` (ZIP) and read what the host needs. Throws
/// [PackageException]. Does NOT check hashes.
PackageInfo inspectCs3(Uint8List bytes) {
  final entries = _readZipDirectory(bytes);
  final dex = entries.keys
      .where((n) => RegExp(r'^classes\d*\.dex$').hasMatch(n))
      .length;
  if (dex == 0) {
    throw const PackageException(PackageProblem.noDex,
        'Not a CloudStream package: no classes.dex inside.');
  }
  final manifestEntry = entries['manifest.json'];
  if (manifestEntry == null) {
    throw const PackageException(PackageProblem.noManifest,
        'Not a CloudStream package: manifest.json is missing.');
  }
  final manifestBytes = _readEntry(bytes, manifestEntry, _maxManifestBytes);
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(manifestBytes));
  } on FormatException {
    throw const PackageException(
        PackageProblem.badManifest, 'manifest.json is not valid JSON.');
  }
  if (decoded is! Map ||
      decoded['pluginClassName'] is! String ||
      (decoded['pluginClassName'] as String).trim().isEmpty) {
    throw const PackageException(PackageProblem.badManifest,
        'manifest.json has no pluginClassName.');
  }
  final v = decoded['version'];
  return PackageInfo(
    pluginClassName: (decoded['pluginClassName'] as String).trim(),
    dexCount: dex,
    name: decoded['name'] is String ? decoded['name'] as String : null,
    version: v is int ? v : null,
    requiresResources: decoded['requiresResources'] == true,
  );
}

class _ZipEntry {
  const _ZipEntry(this.method, this.compSize, this.size, this.localOffset);
  final int method;
  final int compSize;
  final int size;
  final int localOffset;
}

Map<String, _ZipEntry> _readZipDirectory(Uint8List b) {
  const notZip = PackageException(
      PackageProblem.notAZip, 'Not a CloudStream package: not a ZIP file.');
  if (b.length < 22) throw notZip;
  final bd = ByteData.sublistView(b);
  // End Of Central Directory: scan back (comment ≤ 65535 bytes).
  var eocd = -1;
  final stop = b.length - 22 - 65535 < 0 ? 0 : b.length - 22 - 65535;
  for (var i = b.length - 22; i >= stop; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw notZip;
  final count = bd.getUint16(eocd + 10, Endian.little);
  final cdSize = bd.getUint32(eocd + 12, Endian.little);
  final cdOffset = bd.getUint32(eocd + 16, Endian.little);
  if (cdOffset + cdSize > b.length || count == 0xffff) throw notZip;

  final out = <String, _ZipEntry>{};
  var p = cdOffset;
  for (var n = 0; n < count; n++) {
    if (p + 46 > b.length ||
        bd.getUint32(p, Endian.little) != 0x02014b50) {
      throw notZip;
    }
    final method = bd.getUint16(p + 10, Endian.little);
    final compSize = bd.getUint32(p + 20, Endian.little);
    final size = bd.getUint32(p + 24, Endian.little);
    final nameLen = bd.getUint16(p + 28, Endian.little);
    final extraLen = bd.getUint16(p + 30, Endian.little);
    final commentLen = bd.getUint16(p + 32, Endian.little);
    final localOffset = bd.getUint32(p + 42, Endian.little);
    if (p + 46 + nameLen > b.length) throw notZip;
    final name = utf8.decode(b.sublist(p + 46, p + 46 + nameLen),
        allowMalformed: true);
    // Path traversal guard — we never extract, but refuse hostile names.
    if (name.contains('..') || name.startsWith('/')) {
      throw const PackageException(PackageProblem.notAZip,
          'Package contains an unsafe path and was rejected.');
    }
    out[name] = _ZipEntry(method, compSize, size, localOffset);
    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

Uint8List _readEntry(Uint8List b, _ZipEntry e, int maxBytes) {
  const bad = PackageException(
      PackageProblem.notAZip, 'Not a CloudStream package: corrupt ZIP.');
  if (e.size > maxBytes) {
    throw const PackageException(
        PackageProblem.badManifest, 'manifest.json is unreasonably large.');
  }
  final bd = ByteData.sublistView(b);
  final lo = e.localOffset;
  if (lo + 30 > b.length || bd.getUint32(lo, Endian.little) != 0x04034b50) {
    throw bad;
  }
  final nameLen = bd.getUint16(lo + 26, Endian.little);
  final extraLen = bd.getUint16(lo + 28, Endian.little);
  final start = lo + 30 + nameLen + extraLen;
  final end = start + e.compSize;
  if (end > b.length) throw bad;
  final raw = b.sublist(start, end);
  if (e.method == 0) return raw;
  if (e.method == 8) {
    try {
      final inflated = ZLibCodec(raw: true).decode(raw);
      if (inflated.length > maxBytes) {
        throw const PackageException(PackageProblem.badManifest,
            'manifest.json is unreasonably large.');
      }
      return Uint8List.fromList(inflated);
    } on FormatException {
      throw bad;
    }
  }
  throw bad;
}
