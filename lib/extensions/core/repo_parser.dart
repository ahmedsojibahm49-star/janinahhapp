import 'models.dart';

/// Normalise what a user pastes into an https URL.
///
/// * `cloudstreamrepo://host/path` → `https://host/path`
/// * `github.com/u/r/blob/b/repo.json` → raw.githubusercontent.com
/// * anything else must already be an https URL.
///
/// Returns null when the input cannot be made into a usable https URL.
Uri? normalizeRepoUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (s.toLowerCase().startsWith('cloudstreamrepo://')) {
    s = 'https://${s.substring('cloudstreamrepo://'.length)}';
  }
  final uri = Uri.tryParse(s);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
  if (!uri.isScheme('https')) return null;
  if (uri.host == 'github.com') {
    final seg = uri.pathSegments;
    // /user/repo/blob/branch/path... or /user/repo/raw/branch/path...
    if (seg.length >= 5 && (seg[2] == 'blob' || seg[2] == 'raw')) {
      return Uri.https(
        'raw.githubusercontent.com',
        '/${seg[0]}/${seg[1]}/${seg.sublist(3).join('/')}',
      );
    }
  }
  return uri;
}

/// Quick sniff: does [decoded] look like a CloudStream `repo.json`?
bool looksLikeRepoManifest(Object? decoded) =>
    decoded is Map && decoded['pluginLists'] is List;

/// Parse a `repo.json` document.
RepoManifest parseRepoManifest(Object? decoded) {
  if (decoded is! Map) {
    throw const ExtensionFormatException(
        'Repository manifest must be a JSON object.');
  }
  final lists = decoded['pluginLists'];
  if (lists is! List) {
    throw const ExtensionFormatException(
        'Repository manifest has no “pluginLists” array.');
  }
  final urls = <String>[];
  for (final e in lists) {
    if (e is! String) continue;
    final uri = normalizeRepoUrl(e);
    if (uri != null && !urls.contains(uri.toString())) {
      urls.add(uri.toString());
    }
  }
  if (urls.isEmpty) {
    throw const ExtensionFormatException(
        'Repository manifest lists no usable https plugin list.');
  }
  String? s(Object? v) =>
      v is String && v.trim().isNotEmpty ? v.trim() : null;
  final version = decoded['manifestVersion'];
  return RepoManifest(
    name: s(decoded['name']) ?? 'Repository',
    iconUrl: normalizeIconUrl(s(decoded['iconUrl'])),
    description: s(decoded['description']),
    manifestVersion: version is int ? version : 1,
    pluginLists: urls,
  );
}

/// Parse one `plugins.json` (a JSON array of extension rows).
///
/// Invalid rows are skipped and counted, never fatal. Duplicate
/// `internalName`s keep the highest version.
PluginListResult parsePluginList(Object? decoded) {
  if (decoded is! List) {
    throw const ExtensionFormatException(
        'Plugin list must be a JSON array.');
  }
  final byName = <String, PluginEntry>{};
  var skipped = 0;
  var duplicates = 0;
  for (final raw in decoded) {
    final entry = PluginEntry.fromJson(raw);
    if (entry == null || !_validEntry(entry)) {
      skipped++;
      continue;
    }
    final existing = byName[entry.internalName];
    if (existing == null) {
      byName[entry.internalName] = entry;
    } else {
      duplicates++;
      if (entry.version > existing.version) {
        byName[entry.internalName] = entry;
      }
    }
  }
  return PluginListResult(
    entries: byName.values.toList(growable: false),
    skipped: skipped,
    duplicates: duplicates,
  );
}

bool _validEntry(PluginEntry e) {
  final uri = Uri.tryParse(e.url);
  if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) return false;
  // internalName becomes a file name and a provider id.
  if (!RegExp(r'^[A-Za-z0-9._\- ]{1,80}$').hasMatch(e.internalName)) {
    return false;
  }
  if (e.internalName.contains('..')) return false;
  return true;
}
