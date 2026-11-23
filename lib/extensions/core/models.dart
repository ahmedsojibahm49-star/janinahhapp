import 'dart:convert';

/// Pure-Dart models for CloudStream-style extension repositories.
///
/// Nothing in `lib/extensions/core` imports Flutter, Hive or `package:*` —
/// the whole layer is unit-testable with a plain Dart VM and every I/O
/// edge (HTTP, storage, files, the native host) is an injected interface.

/// Content category used by the Extension Store filter chips.
enum ExtensionCategory { anime, movies, tvSeries, other }

/// CloudStream `status` field: 0 down, 1 ok, 2 slow, 3 beta-only.
class PluginStatus {
  PluginStatus._();
  static const int down = 0;
  static const int ok = 1;
  static const int slow = 2;
  static const int beta = 3;
}

/// One extension advertised by a `plugins.json` list.
class PluginEntry {
  const PluginEntry({
    required this.internalName,
    required this.name,
    required this.url,
    required this.version,
    this.status = PluginStatus.ok,
    this.authors = const [],
    this.description,
    this.fileSize,
    this.repositoryUrl,
    this.language,
    this.tvTypes = const [],
    this.iconUrl,
    this.apiVersion,
    this.fileHash,
  });

  final String internalName;
  final String name;
  final String url;
  final int version;
  final int status;
  final List<String> authors;
  final String? description;
  final int? fileSize;
  final String? repositoryUrl;
  final String? language;
  final List<String> tvTypes;
  final String? iconUrl;
  final int? apiVersion;

  /// Lower-case hex SHA-256 of the package, when the list supplies one.
  final String? fileHash;

  /// Categories derived from [tvTypes]. Never empty.
  Set<ExtensionCategory> get categories => categoriesFor(tvTypes);

  Map<String, dynamic> toJson() => {
        'internalName': internalName,
        'name': name,
        'url': url,
        'version': version,
        'status': status,
        'authors': authors,
        'description': description,
        'fileSize': fileSize,
        'repositoryUrl': repositoryUrl,
        'language': language,
        'tvTypes': tvTypes,
        'iconUrl': iconUrl,
        'apiVersion': apiVersion,
        'fileHash': fileHash,
      };

  /// Lenient decode of a cached row. Returns null if unusable.
  static PluginEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final internal = _str(raw['internalName']);
    final url = _str(raw['url']);
    if (internal == null || url == null) return null;
    return PluginEntry(
      internalName: internal,
      name: _str(raw['name']) ?? internal,
      url: url,
      version: _int(raw['version']) ?? 0,
      status: _int(raw['status']) ?? PluginStatus.ok,
      authors: _strList(raw['authors']),
      description: _str(raw['description']),
      fileSize: _int(raw['fileSize']),
      repositoryUrl: _str(raw['repositoryUrl']),
      language: _str(raw['language']),
      tvTypes: _strList(raw['tvTypes']),
      iconUrl: normalizeIconUrl(_str(raw['iconUrl'])),
      apiVersion: _int(raw['apiVersion']),
      fileHash: _hash(raw['fileHash']),
    );
  }
}

/// Map CloudStream `tvTypes` to store categories.
Set<ExtensionCategory> categoriesFor(List<String> tvTypes) {
  final out = <ExtensionCategory>{};
  for (final t in tvTypes) {
    switch (t.trim().toLowerCase()) {
      case 'anime':
      case 'animemovie':
      case 'ova':
        out.add(ExtensionCategory.anime);
      case 'movie':
      case 'documentary':
        out.add(ExtensionCategory.movies);
      case 'tvseries':
      case 'asiandrama':
      case 'cartoon':
      case 'live':
        out.add(ExtensionCategory.tvSeries);
      default:
        out.add(ExtensionCategory.other);
    }
  }
  if (out.isEmpty) out.add(ExtensionCategory.other);
  return out;
}

/// A parsed `repo.json` manifest.
class RepoManifest {
  const RepoManifest({
    required this.name,
    required this.pluginLists,
    this.iconUrl,
    this.description,
    this.manifestVersion = 1,
  });

  final String name;
  final List<String> pluginLists;
  final String? iconUrl;
  final String? description;
  final int manifestVersion;
}

/// Result of parsing one `plugins.json`.
class PluginListResult {
  const PluginListResult({
    required this.entries,
    this.skipped = 0,
    this.duplicates = 0,
  });

  final List<PluginEntry> entries;

  /// Rows dropped because they failed validation.
  final int skipped;

  /// Rows dropped because the same internalName appeared twice
  /// (the higher version is kept).
  final int duplicates;
}

/// Thrown for a structurally invalid repo manifest / plugin list.
class ExtensionFormatException implements Exception {
  const ExtensionFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

String? _str(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

List<String> _strList(Object? v) {
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e is String && e.trim().isNotEmpty) e.trim(),
  ];
}

/// Accepts a bare 64-hex SHA-256 or one prefixed `sha256-` / `sha256:`
/// (CloudStream repositories publish `sha256-<hex>`).
String? _hash(Object? v) {
  final s = _str(v)?.toLowerCase();
  if (s == null) return null;
  final cleaned = s.startsWith('sha256-') || s.startsWith('sha256:')
      ? s.substring(7)
      : s;
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(cleaned) ? cleaned : null;
}

/// Repositories publish icon URLs with a `%size%` placeholder (favicon
/// services); left as is they 404 and no logo shows. Fill it in, and
/// upgrade plain http (Android blocks cleartext traffic by default).
String? normalizeIconUrl(String? url) {
  if (url == null) return null;
  var u = url
      .replaceAll('%size%', '128')
      .replaceAll('{size}', '128')
      .replaceAll('%SIZE%', '128');
  if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
  final uri = Uri.tryParse(u);
  if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) return null;
  return u;
}

/// Decode UTF-8 JSON bytes, tolerating a BOM.
Object? decodeJsonBytes(List<int> bytes) {
  var b = bytes;
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
    b = b.sublist(3);
  }
  try {
    return jsonDecode(utf8.decode(b));
  } on FormatException {
    throw const ExtensionFormatException('Response is not valid JSON.');
  }
}
