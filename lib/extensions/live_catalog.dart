import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import '../providers/catalog_providers.dart';
import '../services/storage.dart';
import 'adapters.dart';
import 'core/host.dart';
import 'core/live.dart';
import 'core/manager.dart';
import 'native_host.dart';

// ====================================================================
// Riverpod wiring for the extension layer
// ====================================================================

final extensionManagerProvider = Provider<ExtensionManager>((ref) {
  return ExtensionManager(
    fetcher: const HttpExtensionFetcher(),
    store: HiveKeyValueStore(),
    packages: FilePackageStorage(),
    host: createExtensionHost(),
  );
});

/// Read once at app start. Loads persisted state and brings enabled
/// providers up in the background; never throws, never blocks the UI.
final extensionBootProvider = Provider<void>((ref) {
  final manager = ref.read(extensionManagerProvider);
  unawaited(() async {
    try {
      await manager.load();
      await manager.restoreEnabledProviders();
    } on Object {
      // Extensions are optional: a failure here must never reach the UI.
    }
  }());
});

/// Bumps whenever the manager changes, so widgets rebuild.
final extensionsRevisionProvider =
    NotifierProvider<ExtensionsRevision, int>(ExtensionsRevision.new);

class ExtensionsRevision extends Notifier<int> {
  @override
  int build() {
    final manager = ref.watch(extensionManagerProvider);
    void onChange() => state = state + 1;
    manager.addListener(onChange);
    ref.onDispose(() => manager.removeListener(onChange));
    return 0;
  }
}

final extensionStoreItemsProvider = Provider<List<StoreItem>>((ref) {
  ref.watch(extensionsRevisionProvider);
  return ref.read(extensionManagerProvider).storeItems();
});

final extensionReposProvider = Provider<List<RepoRecord>>((ref) {
  ref.watch(extensionsRevisionProvider);
  return ref.read(extensionManagerProvider).repos;
});

/// Stable key of the enabled+loaded providers; only changes when that SET
/// changes, so searches don't re-run during unrelated manager updates.
final activeProviderKeysProvider = Provider<String>((ref) {
  ref.watch(extensionsRevisionProvider);
  final active = ref.read(extensionManagerProvider).activeProviders();
  final keys = [
    for (final a in active)
      LiveId.provider(a.record.internalName, a.provider.apiName),
  ]..sort();
  return keys.join('|');
});

final liveProviderManagerProvider = Provider<LiveProviderManager>(
    (ref) => LiveProviderManager(ref.read(extensionManagerProvider)));

// ====================================================================
// Live results <-> the existing catalog (so Search/Details/Player work
// unchanged: a live title is stored as an ordinary ProviderItem whose
// providerId starts with `cs3~`).
// ====================================================================

/// CloudStream TvType -> app ContentType. Null = cannot be played here.
ContentType? contentTypeFor(String? tvType) {
  switch ((tvType ?? '').toLowerCase()) {
    case 'anime':
    case 'animemovie':
    case 'ova':
      return ContentType.anime;
    case 'movie':
    case 'documentary':
    case 'tvseries':
    case 'asiandrama':
    case 'cartoon':
    case 'live':
    case '':
      return ContentType.movie;
    default:
      // Torrent, Music, AudioBook, Podcast, NSFW, ...: not playable by the
      // app's video player (NSFW is excluded on purpose).
      return null;
  }
}

class LiveCatalog {
  LiveCatalog(this._box);
  final Box<ProviderItem> _box;

  /// Store search hits as catalog items (keeping any cached episodes) and
  /// return them in hit order.
  Future<List<ProviderItem>> storeHits(List<LiveSearchHit> hits) async {
    final out = <ProviderItem>[];
    final fresh = <String, ProviderItem>{};
    for (final h in hits) {
      final type = contentTypeFor(h.result.type);
      if (type == null) continue;
      final id = LiveId.itemId(h.result.url);
      final key = '${h.providerId}::$id';
      final existing = _box.get(key) ?? fresh[key];
      if (existing != null) {
        out.add(existing);
        continue;
      }
      final item = ProviderItem(
        id: id,
        providerId: h.providerId,
        type: type,
        title: h.result.name.trim(),
        posterUrl: h.result.posterUrl,
        year: h.result.year,
      );
      fresh[key] = item;
      out.add(item);
    }
    if (fresh.isNotEmpty) await _box.putAll(fresh);
    return out;
  }

  /// Store plain provider results (home rows) as catalog items.
  Future<List<ProviderItem>> storeResults(
    String providerId,
    List<LiveSearchResult> results,
  ) =>
      storeHits([
        for (final r in results)
          LiveSearchHit(
            providerId: providerId,
            providerName: '',
            result: r,
          ),
      ]);

  /// Write provider details (and episodes) into [item].
  Future<void> applyDetails(ProviderItem item, LiveDetails d) async {
    final eps = [...d.episodes];
    eps.sort((a, b) {
      final s = (a.season ?? 1).compareTo(b.season ?? 1);
      return s != 0 ? s : (a.episode ?? 0).compareTo(b.episode ?? 0);
    });
    item
      ..posterUrl = item.posterUrl ?? d.posterUrl
      ..backdropUrl = d.backdropUrl ?? item.backdropUrl
      ..overview = d.plot ?? item.overview
      ..year = item.year ?? d.year
      ..rating = d.rating ?? item.rating
      ..status = d.status ?? item.status;
    if (d.tags.isNotEmpty) item.genres = d.tags;
    item.episodes = [
      for (var i = 0; i < eps.length; i++)
        {
          'number': i + 1,
          if (eps[i].name != null && eps[i].name!.trim().isNotEmpty)
            'title': eps[i].name!.trim(),
          if (eps[i].season != null) 'season': eps[i].season,
          if (eps[i].episode != null) 'episode': eps[i].episode,
          if (eps[i].posterUrl != null) 'thumbnail': eps[i].posterUrl,
          // No videoUrl: the player resolves the real stream on demand.
          'liveData': eps[i].data,
        },
    ];
    await item.save();
  }
}

final liveCatalogProvider = Provider<LiveCatalog>(
    (ref) => LiveCatalog(Hive.box<ProviderItem>(BoxNames.catalog)));

/// Live search results as catalog items. Empty unless some provider is
/// enabled and loaded. Cancels itself when the query changes.
final liveSearchItemsProvider = FutureProvider.autoDispose
    .family<List<ProviderItem>, String>(
        // Riverpod 3 retries failed providers automatically; a provider
        // site that errors must not be hammered with repeated requests.
        retry: (_, _) => null, (ref, query) async {
  ref.watch(activeProviderKeysProvider);
  final q = query.trim();
  if (q.length < 2) return const <ProviderItem>[];
  final manager = ref.read(extensionManagerProvider);
  if (manager.activeProviders().isEmpty) return const <ProviderItem>[];

  final cancel = SearchCancel();
  ref.onDispose(cancel.cancel);
  final outcome =
      await ref.read(liveProviderManagerProvider).search(q, cancel: cancel);
  if (cancel.isCancelled) return const <ProviderItem>[];
  return ref.read(liveCatalogProvider).storeHits(outcome.hits);
});

/// A home rail made of live (extension) titles.
class LiveRail {
  const LiveRail({required this.title, required this.items});
  final String title;
  final List<ProviderItem> items;
}

/// Home rows from enabled extensions, stored as catalog items so the
/// existing Details/Player work on them. Refreshed when the set of active
/// providers changes, or when Home is pulled to refresh.
final liveHomeProvider = FutureProvider<List<LiveRail>>(
    // No automatic retry: pull-to-refresh re-runs it.
    retry: (_, _) => null, (ref) async {
  ref.watch(activeProviderKeysProvider);
  final manager = ref.read(extensionManagerProvider);
  if (manager.activeProviders().isEmpty) return const <LiveRail>[];
  final sections = await ref.read(liveProviderManagerProvider).home();
  final catalog = ref.read(liveCatalogProvider);
  final rails = <LiveRail>[];
  for (final s in sections) {
    final items = await catalog.storeResults(s.providerId, s.items);
    if (items.isEmpty) continue;
    rails.add(LiveRail(title: '${s.providerName} · ${s.title}', items: items));
    if (rails.length >= 12) break;
  }
  return rails;
});

/// "Provider · year" for a live (extension) title; null for catalog items.
String? liveSourceLabel(ProviderItem item) {
  final ref = LiveId.parse(item.providerId);
  if (ref == null) return null;
  final year = item.year;
  return year == null ? ref.apiName : '${ref.apiName} · $year';
}

/// Loads episodes for a live item once (keyed by the catalog box key).
final liveDetailsProvider = FutureProvider.family<void, String>(
    // No automatic retry: the user retries explicitly (Retry button).
    retry: (_, _) => null, (ref, boxKey) async {
  final box = Hive.box<ProviderItem>(BoxNames.catalog);
  final item = box.get(boxKey);
  if (item == null || !LiveId.isLive(item.providerId)) return;
  if (item.episodes.isNotEmpty) return;
  final url = LiveId.urlFromItemId(item.id);
  if (url == null) {
    throw const ExtensionException(
        ExtensionError.notFound, 'This title has no valid address.');
  }
  final details =
      await ref.read(liveProviderManagerProvider).details(item.providerId, url);
  await ref.read(liveCatalogProvider).applyDetails(item, details);
  ref.invalidate(itemByIdProvider(boxKey));
});

// ====================================================================
// Player support
// ====================================================================

class LiveStream {
  const LiveStream({
    required this.url,
    required this.headers,
    required this.source,
    this.quality,
  });
  final String url;
  final Map<String, String> headers;
  final String source;
  final int? quality;
}

class LivePlayback {
  const LivePlayback({required this.streams, this.subtitle});

  /// Best quality first.
  final List<LiveStream> streams;
  final LiveSubtitle? subtitle;
}

/// Resolve an episode's `liveData` into playable streams (+ one subtitle).
Future<LivePlayback> resolveLivePlayback(
  LiveProviderManager manager,
  String providerId,
  String data,
) async {
  final links = await manager.links(providerId, data);
  if (links.links.isEmpty) {
    throw const ExtensionException(ExtensionError.providerFailed,
        'The provider returned no playable source.');
  }
  final sorted = [...links.links]
    ..sort((a, b) => (b.quality ?? -1).compareTo(a.quality ?? -1));
  LiveSubtitle? sub;
  for (final s in links.subtitles) {
    if (s.lang.toLowerCase().startsWith('en')) {
      sub = s;
      break;
    }
  }
  sub ??= links.subtitles.isEmpty ? null : links.subtitles.first;
  return LivePlayback(
    streams: [
      for (final l in sorted)
        LiveStream(
          url: l.url,
          headers: l.headers,
          source: l.source,
          quality: l.quality,
        ),
    ],
    subtitle: sub,
  );
}

/// Download a subtitle file as text (size-capped). Null on any failure:
/// subtitles are optional and must never block playback.
Future<String?> fetchSubtitleText(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.isScheme('https')) return null;
  final client = http.Client();
  try {
    final res = await client.get(uri).timeout(const Duration(seconds: 6));
    if (res.statusCode != 200 || res.bodyBytes.length > 2 * 1024 * 1024) {
      return null;
    }
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  } on Object {
    return null;
  } finally {
    client.close();
  }
}
