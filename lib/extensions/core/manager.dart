import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'host.dart';
import 'models.dart';
import 'package_validator.dart';
import 'repo_parser.dart';
import 'sha256.dart';

// ============================================================ records

/// A configured repository + its cached plugin lists.
class RepoRecord {
  const RepoRecord({
    required this.id,
    required this.url,
    required this.name,
    required this.pluginListUrls,
    this.iconUrl,
    this.description,
    this.lastRefreshedAt,
    this.lastError,
    this.entries = const [],
    this.skipped = 0,
    this.duplicates = 0,
  });

  final String id;
  final String url;
  final String name;
  final String? iconUrl;
  final String? description;
  final List<String> pluginListUrls;

  /// Epoch millis of the last successful refresh.
  final int? lastRefreshedAt;
  final String? lastError;
  final List<PluginEntry> entries;
  final int skipped;
  final int duplicates;

  RepoRecord copyWith({
    String? name,
    String? iconUrl,
    String? description,
    List<String>? pluginListUrls,
    int? lastRefreshedAt,
    String? lastError,
    bool clearError = false,
    List<PluginEntry>? entries,
    int? skipped,
    int? duplicates,
  }) =>
      RepoRecord(
        id: id,
        url: url,
        name: name ?? this.name,
        iconUrl: iconUrl ?? this.iconUrl,
        description: description ?? this.description,
        pluginListUrls: pluginListUrls ?? this.pluginListUrls,
        lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
        lastError: clearError ? null : (lastError ?? this.lastError),
        entries: entries ?? this.entries,
        skipped: skipped ?? this.skipped,
        duplicates: duplicates ?? this.duplicates,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'iconUrl': iconUrl,
        'description': description,
        'pluginListUrls': pluginListUrls,
        'lastRefreshedAt': lastRefreshedAt,
        'lastError': lastError,
        'skipped': skipped,
        'duplicates': duplicates,
        'entries': [for (final e in entries) e.toJson()],
      };

  static RepoRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final url = raw['url'];
    if (id is! String || url is! String) return null;
    return RepoRecord(
      id: id,
      url: url,
      name: raw['name'] is String ? raw['name'] as String : 'Repository',
      iconUrl: raw['iconUrl'] as String?,
      description: raw['description'] as String?,
      pluginListUrls: raw['pluginListUrls'] is List
          ? [for (final u in raw['pluginListUrls'] as List) u.toString()]
          : const [],
      lastRefreshedAt: raw['lastRefreshedAt'] as int?,
      lastError: raw['lastError'] as String?,
      skipped: raw['skipped'] as int? ?? 0,
      duplicates: raw['duplicates'] as int? ?? 0,
      entries: raw['entries'] is List
          ? [
              for (final e in raw['entries'] as List)
                if (PluginEntry.fromJson(e) != null) PluginEntry.fromJson(e)!,
            ]
          : const [],
    );
  }
}

/// A package that was downloaded, verified AND loaded by the host.
class InstalledRecord {
  const InstalledRecord({
    required this.internalName,
    required this.name,
    required this.version,
    required this.path,
    required this.sha256,
    required this.sizeBytes,
    required this.installedAt,
    required this.pluginClassName,
    this.repoId,
    this.enabled = true,
    this.apiVersion,
    this.authors = const [],
    this.description,
    this.language,
    this.tvTypes = const [],
    this.iconUrl,
    this.repositoryUrl,
    this.providers = const [],
    this.lastInitAt,
    this.lastError,
  });

  final String internalName;
  final String name;
  final int version;
  final String path;
  final String sha256;
  final int sizeBytes;
  final int installedAt;
  final String pluginClassName;
  final String? repoId;
  final bool enabled;
  final int? apiVersion;
  final List<String> authors;
  final String? description;
  final String? language;
  final List<String> tvTypes;
  final String? iconUrl;
  final String? repositoryUrl;
  final List<HostProvider> providers;

  /// Epoch millis of the last successful host initialisation.
  final int? lastInitAt;
  final String? lastError;

  Set<ExtensionCategory> get categories => categoriesFor(tvTypes);

  InstalledRecord copyWith({
    bool? enabled,
    List<HostProvider>? providers,
    int? lastInitAt,
    String? lastError,
    bool clearError = false,
  }) =>
      InstalledRecord(
        internalName: internalName,
        name: name,
        version: version,
        path: path,
        sha256: sha256,
        sizeBytes: sizeBytes,
        installedAt: installedAt,
        pluginClassName: pluginClassName,
        repoId: repoId,
        enabled: enabled ?? this.enabled,
        apiVersion: apiVersion,
        authors: authors,
        description: description,
        language: language,
        tvTypes: tvTypes,
        iconUrl: iconUrl,
        repositoryUrl: repositoryUrl,
        providers: providers ?? this.providers,
        lastInitAt: lastInitAt ?? this.lastInitAt,
        lastError: clearError ? null : (lastError ?? this.lastError),
      );

  Map<String, dynamic> toJson() => {
        'internalName': internalName,
        'name': name,
        'version': version,
        'path': path,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        'installedAt': installedAt,
        'pluginClassName': pluginClassName,
        'repoId': repoId,
        'enabled': enabled,
        'apiVersion': apiVersion,
        'authors': authors,
        'description': description,
        'language': language,
        'tvTypes': tvTypes,
        'iconUrl': iconUrl,
        'repositoryUrl': repositoryUrl,
        'providers': [for (final p in providers) p.toJson()],
        'lastInitAt': lastInitAt,
        'lastError': lastError,
      };

  static InstalledRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final internal = raw['internalName'];
    final path = raw['path'];
    if (internal is! String || path is! String) return null;
    List<String> strs(Object? v) =>
        v is List ? [for (final e in v) e.toString()] : const [];
    return InstalledRecord(
      internalName: internal,
      name: raw['name'] is String ? raw['name'] as String : internal,
      version: raw['version'] as int? ?? 0,
      path: path,
      sha256: raw['sha256'] as String? ?? '',
      sizeBytes: raw['sizeBytes'] as int? ?? 0,
      installedAt: raw['installedAt'] as int? ?? 0,
      pluginClassName: raw['pluginClassName'] as String? ?? '',
      repoId: raw['repoId'] as String?,
      enabled: raw['enabled'] != false,
      apiVersion: raw['apiVersion'] as int?,
      authors: strs(raw['authors']),
      description: raw['description'] as String?,
      language: raw['language'] as String?,
      tvTypes: strs(raw['tvTypes']),
      iconUrl: raw['iconUrl'] as String?,
      repositoryUrl: raw['repositoryUrl'] as String?,
      providers: raw['providers'] is List
          ? [
              for (final p in raw['providers'] as List)
                if (HostProvider.fromJson(p) != null)
                  HostProvider.fromJson(p)!,
            ]
          : const [],
      lastInitAt: raw['lastInitAt'] as int?,
      lastError: raw['lastError'] as String?,
    );
  }
}

// ======================================================== store items

/// Why an extension can or cannot be installed on this device.
enum Compatibility {
  compatible,
  unsupportedPlatform,
  apiMismatch,
  unsupportedPackage,
}

enum InstallPhase { downloading, verifying, installing }

class InstallProgress {
  const InstallProgress(this.phase, {this.received = 0, this.total});
  final InstallPhase phase;
  final int received;
  final int? total;

  /// 0..1 while downloading with a known size, else null.
  double? get fraction {
    if (phase != InstallPhase.downloading) return null;
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }
}

/// One row of the Extension Store: the best advertised version of an
/// extension joined with its install state.
class StoreItem {
  const StoreItem({
    required this.entry,
    required this.repo,
    required this.compatibility,
    this.installed,
    this.otherRepoNames = const [],
  });

  final PluginEntry entry;
  final RepoRecord repo;
  final Compatibility compatibility;
  final InstalledRecord? installed;
  final List<String> otherRepoNames;

  String get internalName => entry.internalName;
  bool get isInstalled => installed != null;
  bool get isEnabled => installed?.enabled ?? false;
  bool get hasUpdate =>
      installed != null && entry.version > installed!.version;
  bool get canInstall => compatibility == Compatibility.compatible;
}

// ============================================================ manager

/// Repository manager + installer + enable/disable registry.
///
/// Pure Dart; every side effect goes through an injected interface.
/// Notifies listeners after every state change.
class ExtensionManager {
  ExtensionManager({
    required this._fetcher,
    required this._store,
    required this._packages,
    required this._host,
    DateTime Function()? clock,
    this.fetchTimeout = const Duration(seconds: 20),
    this.loadTimeout = const Duration(seconds: 60),
    this.listConcurrency = 3,
  }) : _clock = clock ?? DateTime.now;

  static const String reposKey = 'ext.repos.v1';
  static const String installedKey = 'ext.installed.v1';

  final ExtensionFetcher _fetcher;
  final KeyValueStore _store;
  final PackageStorage _packages;
  final ExtensionHost _host;
  final DateTime Function() _clock;
  final Duration fetchTimeout;

  /// How long a package may take to start in the native host before the
  /// install / enable is abandoned (a hung plugin must not hang the UI).
  final Duration loadTimeout;
  final int listConcurrency;

  final Map<String, RepoRecord> _repos = {};
  final Map<String, InstalledRecord> _installed = {};
  final Map<String, InstallProgress> _progress = {};
  final Set<String> _busy = {};
  final Set<String> _refreshing = {};
  final Set<String> _loadedInHost = {};
  final List<void Function()> _listeners = [];

  HostInfo _hostInfo = HostInfo.unavailable;
  bool _loaded = false;

  // ------------------------------------------------------- observation

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  HostInfo get hostInfo => _hostInfo;
  bool get isLoaded => _loaded;
  List<RepoRecord> get repos => _repos.values.toList(growable: false);
  List<InstalledRecord> get installed =>
      _installed.values.toList(growable: false);
  InstalledRecord? installedRecord(String internalName) =>
      _installed[internalName];
  InstallProgress? progressOf(String internalName) => _progress[internalName];
  bool isBusy(String internalName) => _busy.contains(internalName);
  bool isRefreshing(String repoId) => _refreshing.contains(repoId);
  bool isLoadedInHost(String internalName) =>
      _loadedInHost.contains(internalName);

  // ------------------------------------------------------------ startup

  /// Read persisted state. Fast: no network, no host calls. Call
  /// [restoreEnabledProviders] afterwards (in the background) to bring
  /// enabled providers up.
  Future<void> load() async {
    _repos.clear();
    _installed.clear();
    _decodeInto(_store.read(reposKey), (o) {
      final r = RepoRecord.fromJson(o);
      if (r != null) _repos[r.id] = r;
    });
    _decodeInto(_store.read(installedKey), (o) {
      final r = InstalledRecord.fromJson(o);
      if (r != null) _installed[r.internalName] = r;
    });
    try {
      _hostInfo = await _host.info();
    } catch (_) {
      _hostInfo = HostInfo.unavailable;
    }
    _loaded = true;
    _notify();
  }

  void _decodeInto(String? raw, void Function(Object?) each) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) decoded.forEach(each);
    } on FormatException {
      // Corrupt cache: start empty rather than crash the app.
    }
  }

  /// Load every enabled package into the host, [concurrency] at a time.
  /// A failing package is recorded (lastError) and skipped — it never
  /// blocks or crashes the others.
  Future<void> restoreEnabledProviders({int concurrency = 2}) async {
    if (!_hostInfo.available) return;
    final queue = _installed.values.where((r) => r.enabled).toList();
    var next = 0;
    Future<void> worker() async {
      while (next < queue.length) {
        final record = queue[next++];
        await _loadIntoHost(record.internalName);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < queue.length; i++) worker(),
    ]);
  }

  /// Returns true when the package is now loaded.
  Future<bool> _loadIntoHost(String internalName) async {
    final record = _installed[internalName];
    if (record == null) return false;
    try {
      if (!await _packages.exists(record.path)) {
        throw const ExtensionException(ExtensionError.initFailed,
            'The installed package file is missing. Reinstall it.');
      }
      final providers = await _hostLoad(
        record.internalName,
        record.path,
        record.pluginClassName,
      );
      _loadedInHost.add(internalName);
      _installed[internalName] = record.copyWith(
        providers: providers,
        lastInitAt: _clock().millisecondsSinceEpoch,
        clearError: true,
      );
      await _persistInstalled();
      _notify();
      return true;
    } catch (e) {
      _loadedInHost.remove(internalName);
      _installed[internalName] =
          record.copyWith(lastError: _describe(e));
      await _persistInstalled();
      _notify();
      return false;
    }
  }

  // ------------------------------------------------------ repositories

  static String repoIdFor(Uri url) {
    // Stable, short, route-safe: host + path hash-free slug.
    final slug = '${url.host}${url.path}'
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.length > 80 ? slug.substring(0, 80) : slug;
  }

  /// Add a repository from a pasted URL (`repo.json`, a direct
  /// `plugins.json`, a GitHub blob URL or `cloudstreamrepo://…`).
  Future<RepoRecord> addRepo(String input) async {
    final uri = normalizeRepoUrl(input);
    if (uri == null) {
      throw const ExtensionException(ExtensionError.invalidRepo,
          'Enter a valid https:// repository URL.');
    }
    final id = repoIdFor(uri);
    if (_repos.containsKey(id)) {
      throw const ExtensionException(
          ExtensionError.duplicateRepo, 'This repository is already added.');
    }
    final fetched = await _fetchRepo(uri, id, previous: null);
    _repos[id] = fetched;
    await _persistRepos();
    _notify();
    return fetched;
  }

  /// Re-fetch one repository. On failure the cached entries stay and
  /// [RepoRecord.lastError] is set; the exception is also thrown.
  Future<RepoRecord> refreshRepo(String id) async {
    final current = _repos[id];
    if (current == null) {
      throw const ExtensionException(
          ExtensionError.notFound, 'That repository no longer exists.');
    }
    if (!_refreshing.add(id)) return current; // duplicate request guard
    _notify();
    try {
      final fresh = await _fetchRepo(Uri.parse(current.url), id,
          previous: current);
      _repos[id] = fresh;
      await _persistRepos();
      return fresh;
    } on ExtensionException catch (e) {
      _repos[id] = current.copyWith(lastError: e.message);
      await _persistRepos();
      rethrow;
    } finally {
      _refreshing.remove(id);
      _notify();
    }
  }

  /// Refresh every repo; one failing repo does not stop the others.
  /// Returns the number that failed.
  Future<int> refreshAll() async {
    var failed = 0;
    for (final id in _repos.keys.toList()) {
      try {
        await refreshRepo(id);
      } on ExtensionException {
        failed++;
      }
    }
    return failed;
  }

  /// Remove a repository. Packages already installed from it keep
  /// working; only the store listing disappears.
  Future<void> removeRepo(String id) async {
    if (_repos.remove(id) == null) return;
    await _persistRepos();
    _notify();
  }

  Future<RepoRecord> _fetchRepo(Uri uri, String id,
      {required RepoRecord? previous}) async {
    final rootBytes = await _get(uri, maxBytes: 12 * 1024 * 1024);
    final Object? rootJson;
    try {
      rootJson = decodeJsonBytes(rootBytes);
    } on ExtensionFormatException catch (e) {
      throw ExtensionException(ExtensionError.invalidRepo, e.message);
    }

    late final String name;
    String? icon;
    String? description;
    late final List<String> listUrls;
    final results = <PluginListResult>[];
    var failures = 0;
    String? lastFailure;

    if (rootJson is List) {
      // A bare plugins.json was pasted: treat it as a one-list repo.
      try {
        results.add(parsePluginList(rootJson));
      } on ExtensionFormatException catch (e) {
        throw ExtensionException(ExtensionError.invalidRepo, e.message);
      }
      name = previous?.name ?? uri.host;
      listUrls = [uri.toString()];
    } else if (looksLikeRepoManifest(rootJson)) {
      final RepoManifest manifest;
      try {
        manifest = parseRepoManifest(rootJson);
      } on ExtensionFormatException catch (e) {
        throw ExtensionException(ExtensionError.invalidRepo, e.message);
      }
      name = manifest.name;
      icon = manifest.iconUrl;
      description = manifest.description;
      listUrls = manifest.pluginLists;
      // Fetch plugin lists with bounded concurrency.
      var next = 0;
      final slots = List<PluginListResult?>.filled(listUrls.length, null);
      Future<void> worker() async {
        while (next < listUrls.length) {
          final i = next++;
          try {
            final bytes = await _get(Uri.parse(listUrls[i]),
                maxBytes: 20 * 1024 * 1024);
            slots[i] = parsePluginList(decodeJsonBytes(bytes));
          } on ExtensionException catch (e) {
            failures++;
            lastFailure = e.message;
          } on ExtensionFormatException catch (e) {
            failures++;
            lastFailure = e.message;
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < listConcurrency && i < listUrls.length; i++)
          worker(),
      ]);
      results.addAll(slots.whereType<PluginListResult>());
      if (results.isEmpty) {
        throw ExtensionException(
          ExtensionError.invalidRepo,
          lastFailure ?? 'No plugin list could be read.',
        );
      }
    } else {
      throw const ExtensionException(ExtensionError.invalidRepo,
          'This is not a CloudStream repository (no “pluginLists”).');
    }

    // Merge lists: keep the highest version per internalName.
    final merged = <String, PluginEntry>{};
    var skipped = 0;
    var duplicates = 0;
    for (final r in results) {
      skipped += r.skipped;
      duplicates += r.duplicates;
      for (final e in r.entries) {
        final existing = merged[e.internalName];
        if (existing == null) {
          merged[e.internalName] = e;
        } else {
          duplicates++;
          if (e.version > existing.version) merged[e.internalName] = e;
        }
      }
    }

    return RepoRecord(
      id: id,
      url: uri.toString(),
      name: name,
      iconUrl: icon,
      description: description,
      pluginListUrls: listUrls,
      lastRefreshedAt: _clock().millisecondsSinceEpoch,
      lastError: failures > 0
          ? '$failures of ${listUrls.length} plugin lists failed: $lastFailure'
          : null,
      entries: merged.values.toList(growable: false),
      skipped: skipped,
      duplicates: duplicates,
    );
  }

  Future<Uint8List> _get(Uri url,
      {required int maxBytes, ProgressCallback? onProgress}) async {
    try {
      return await _fetcher.fetch(url,
          timeout: fetchTimeout,
          maxBytes: maxBytes,
          onProgress: onProgress);
    } on FetchException catch (e) {
      throw ExtensionException(
        switch (e.kind) {
          FetchFailure.network => ExtensionError.network,
          FetchFailure.timeout => ExtensionError.timeout,
          FetchFailure.http => ExtensionError.http,
          FetchFailure.tooLarge => ExtensionError.tooLarge,
        },
        e.message,
        statusCode: e.statusCode,
      );
    }
  }

  // ------------------------------------------------------------- store

  Compatibility compatibilityOf(PluginEntry e) {
    if (!_hostInfo.available) return Compatibility.unsupportedPlatform;
    final path = Uri.tryParse(e.url)?.path.toLowerCase() ?? '';
    if (!path.endsWith('.cs3')) return Compatibility.unsupportedPackage;
    final api = e.apiVersion;
    if (api != null && !_hostInfo.apiVersions.contains(api)) {
      return Compatibility.apiMismatch;
    }
    return Compatibility.compatible;
  }

  /// Every advertised extension (best version per internalName) joined
  /// with install state. Sorted by name.
  List<StoreItem> storeItems() {
    final best = <String, (PluginEntry, RepoRecord)>{};
    final seenIn = <String, Set<String>>{};
    for (final repo in _repos.values) {
      for (final e in repo.entries) {
        seenIn.putIfAbsent(e.internalName, () => {}).add(repo.name);
        final cur = best[e.internalName];
        if (cur == null || e.version > cur.$1.version) {
          best[e.internalName] = (e, repo);
        }
      }
    }
    final items = [
      for (final b in best.entries)
        StoreItem(
          entry: b.value.$1,
          repo: b.value.$2,
          compatibility: compatibilityOf(b.value.$1),
          installed: _installed[b.key],
          otherRepoNames: [
            for (final n in seenIn[b.key]!)
              if (n != b.value.$2.name) n,
          ],
        ),
    ];
    items.sort((a, b) =>
        a.entry.name.toLowerCase().compareTo(b.entry.name.toLowerCase()));
    return items;
  }

  StoreItem? storeItem(String internalName) {
    for (final i in storeItems()) {
      if (i.internalName == internalName) return i;
    }
    return null;
  }

  List<StoreItem> updatesAvailable() =>
      storeItems().where((i) => i.hasUpdate && i.canInstall).toList();

  // ----------------------------------------------------------- install

  /// Download, verify, load and register an extension. Also used for
  /// updates. On ANY failure nothing new is recorded and a previously
  /// installed version keeps working.
  Future<InstalledRecord> install(String internalName) async {
    final item = storeItem(internalName);
    if (item == null) {
      throw const ExtensionException(ExtensionError.notFound,
          'That extension is no longer listed by any repository.');
    }
    switch (item.compatibility) {
      case Compatibility.compatible:
        break;
      case Compatibility.unsupportedPlatform:
        throw ExtensionException(
          ExtensionError.unsupportedPlatform,
          _hostInfo.unavailableReason ??
              'This device has no CloudStream-compatible runtime.',
        );
      case Compatibility.apiMismatch:
        throw ExtensionException(ExtensionError.apiMismatch,
            'Built for plugin API ${item.entry.apiVersion}, which this app does not support.');
      case Compatibility.unsupportedPackage:
        throw const ExtensionException(ExtensionError.unsupportedPackage,
            'Only .cs3 CloudStream packages can be installed.');
    }
    if (!_busy.add(internalName)) {
      throw const ExtensionException(
          ExtensionError.providerFailed, 'This extension is already busy.');
    }
    _notify();
    String? newPath;
    final previous = _installed[internalName];
    try {
      final entry = item.entry;
      _progress[internalName] =
          const InstallProgress(InstallPhase.downloading);
      _notify();
      final bytes = await _get(
        Uri.parse(entry.url),
        maxBytes: maxPackageBytes,
        onProgress: (received, total) {
          _progress[internalName] = InstallProgress(
              InstallPhase.downloading,
              received: received,
              total: total ?? entry.fileSize);
          _notify();
        },
      );

      _progress[internalName] = const InstallProgress(InstallPhase.verifying);
      _notify();
      final PackageInfo info;
      try {
        info = verifyPackage(bytes, entry);
      } on PackageException catch (e) {
        final integrity = e.problem == PackageProblem.hashMismatch ||
            e.problem == PackageProblem.sizeMismatch ||
            e.problem == PackageProblem.empty;
        throw ExtensionException(
          integrity
              ? ExtensionError.integrity
              : ExtensionError.invalidPackage,
          e.message,
        );
      }

      _progress[internalName] =
          const InstallProgress(InstallPhase.installing);
      _notify();
      final hash = sha256Hex(bytes);
      final fileName = '${_safeName(entry.internalName)}-${entry.version}.cs3';
      newPath = await _packages.save(fileName, bytes);

      // Try the NEW package first; keep the old one loaded until it works.
      final List<HostProvider> providers;
      try {
        providers = await _hostLoad(
          entry.internalName,
          newPath,
          info.pluginClassName,
        );
      } catch (e) {
        // Restore the previous version in the host if it was running.
        if (previous != null && _loadedInHost.contains(internalName)) {
          unawaited(_loadIntoHost(internalName));
        }
        throw e is ExtensionException
            ? e
            : ExtensionException(ExtensionError.initFailed, _describe(e));
      }
      if (previous != null && previous.path != newPath) {
        unawaited(_packages.delete(previous.path).catchError((_) {}));
      }

      final now = _clock().millisecondsSinceEpoch;
      final record = InstalledRecord(
        internalName: entry.internalName,
        name: entry.name,
        version: entry.version,
        path: newPath,
        sha256: hash,
        sizeBytes: bytes.length,
        installedAt: now,
        pluginClassName: info.pluginClassName,
        repoId: item.repo.id,
        // An update keeps the user's choice; a fresh install starts on.
        enabled: previous?.enabled ?? true,
        apiVersion: entry.apiVersion,
        authors: entry.authors,
        description: entry.description,
        language: entry.language,
        tvTypes: entry.tvTypes,
        iconUrl: entry.iconUrl,
        repositoryUrl: entry.repositoryUrl,
        providers: providers,
        lastInitAt: now,
      );
      _installed[internalName] = record;
      _loadedInHost.add(internalName);
      if (!record.enabled) {
        // Installed-but-disabled stays unloaded: release resources.
        await _safeUnload(internalName);
      }
      await _persistInstalled();
      return record;
    } catch (e) {
      if (newPath != null && previous?.path != newPath) {
        unawaited(_packages.delete(newPath).catchError((_) {}));
      }
      rethrow;
    } finally {
      _progress.remove(internalName);
      _busy.remove(internalName);
      _notify();
    }
  }

  /// Update every extension that has a newer compatible version.
  /// Returns (updated, failed).
  Future<({int updated, int failed})> updateAll() async {
    var updated = 0;
    var failed = 0;
    for (final item in updatesAvailable()) {
      try {
        await install(item.internalName);
        updated++;
      } on ExtensionException {
        failed++;
      }
    }
    return (updated: updated, failed: failed);
  }

  Future<void> uninstall(String internalName) async {
    final record = _installed[internalName];
    if (record == null) return;
    if (!_busy.add(internalName)) return;
    _notify();
    try {
      await _safeUnload(internalName);
      _installed.remove(internalName);
      await _persistInstalled();
      try {
        await _packages.delete(record.path);
      } catch (_) {
        // Orphaned file is harmless; the record is already gone.
      }
    } finally {
      _busy.remove(internalName);
      _notify();
    }
  }

  // --------------------------------------------------- enable / disable

  /// Independent of install state. Disabling unloads the package from
  /// the host (resources released) but keeps it installed; enabling
  /// loads it again. Throws when enabling fails (state stays disabled).
  Future<void> setEnabled(String internalName, bool enabled) async {
    final record = _installed[internalName];
    if (record == null) {
      throw const ExtensionException(
          ExtensionError.notFound, 'That extension is not installed.');
    }
    if (record.enabled == enabled && _loadedInHost.contains(internalName) ==
        enabled) {
      return;
    }
    if (!_busy.add(internalName)) return;
    _notify();
    try {
      if (enabled) {
        _installed[internalName] = record.copyWith(enabled: true);
        final ok = await _loadIntoHost(internalName);
        if (!ok) {
          final msg = _installed[internalName]?.lastError ?? 'Failed to start.';
          _installed[internalName] =
              _installed[internalName]!.copyWith(enabled: false);
          await _persistInstalled();
          throw ExtensionException(ExtensionError.initFailed, msg);
        }
      } else {
        await _safeUnload(internalName);
        _installed[internalName] = record.copyWith(enabled: false);
      }
      await _persistInstalled();
    } finally {
      _busy.remove(internalName);
      _notify();
    }
  }

  Future<List<HostProvider>> _hostLoad(
      String internalName, String path, String pluginClassName) {
    return _host
        .load(
          internalName: internalName,
          path: path,
          pluginClassName: pluginClassName,
        )
        .timeout(
          loadTimeout,
          onTimeout: () => throw const ExtensionException(
              ExtensionError.timeout, 'The extension took too long to start.'),
        );
  }

  Future<void> _safeUnload(String internalName) async {
    _loadedInHost.remove(internalName);
    try {
      await _host.unload(internalName);
    } catch (_) {
      // Unload is best-effort: the record, not the host, is the truth.
    }
  }

  // -------------------------------------------------------- live access

  /// Providers that are enabled AND currently loaded in the host.
  List<({InstalledRecord record, HostProvider provider})> activeProviders() {
    final out = <({InstalledRecord record, HostProvider provider})>[];
    for (final r in _installed.values) {
      if (!r.enabled || !_loadedInHost.contains(r.internalName)) continue;
      for (final p in r.providers) {
        out.add((record: r, provider: p));
      }
    }
    return out;
  }

  /// True when [providerId] belongs to an enabled, loaded provider.
  bool isProviderActive(String providerId) {
    final ref = LiveId.parse(providerId);
    if (ref == null) return false;
    final r = _installed[ref.internalName];
    if (r == null || !r.enabled || !_loadedInHost.contains(ref.internalName)) {
      return false;
    }
    return r.providers.any((p) => p.apiName == ref.apiName);
  }

  ExtensionHost get host => _host;

  // ------------------------------------------------------- persistence

  Future<void> _persistRepos() => _store.write(
      reposKey, jsonEncode([for (final r in _repos.values) r.toJson()]));

  Future<void> _persistInstalled() => _store.write(installedKey,
      jsonEncode([for (final r in _installed.values) r.toJson()]));

  // ----------------------------------------------------------- helpers

  static String _safeName(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  static String _describe(Object e) =>
      e is ExtensionException ? e.message : e.toString();
}
