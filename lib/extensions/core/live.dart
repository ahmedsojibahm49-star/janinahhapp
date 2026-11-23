import 'dart:async';

import 'host.dart';
import 'manager.dart';

/// Cooperative cancel flag for a search fan-out. Native calls cannot be
/// aborted mid-flight, so cancelling stops NEW provider calls and drops
/// late results.
class SearchCancel {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class LiveSearchHit {
  const LiveSearchHit({
    required this.providerId,
    required this.providerName,
    required this.result,
  });
  final String providerId;
  final String providerName;
  final LiveSearchResult result;
}

class LiveSearchOutcome {
  const LiveSearchOutcome({
    this.hits = const [],
    this.failures = const {},
    this.cancelled = false,
  });

  final List<LiveSearchHit> hits;

  /// providerId → short reason, for providers that failed or timed out.
  /// Hits from the other providers are still returned (partial results).
  final Map<String, String> failures;
  final bool cancelled;
}

/// One home row, attributed to the provider that produced it.
class LiveHomeSection {
  const LiveHomeSection({
    required this.providerId,
    required this.providerName,
    required this.title,
    required this.items,
  });
  final String providerId;
  final String providerName;
  final String title;
  final List<LiveSearchResult> items;
}

/// Search / details / link resolution across ENABLED providers.
///
/// Isolation rules: a provider that throws or times out is recorded in
/// [LiveSearchOutcome.failures]; it never fails the whole search and
/// never reaches the UI as an unhandled error.
class LiveProviderManager {
  LiveProviderManager(this._ext);

  final ExtensionManager _ext;
  final Map<String, Future<LiveSearchOutcome>> _inFlight = {};

  static const Duration searchTimeout = Duration(seconds: 15);
  static const Duration detailsTimeout = Duration(seconds: 30);
  static const Duration linksTimeout = Duration(seconds: 45);

  /// Search every enabled+loaded provider, [concurrency] at a time.
  /// Identical concurrent queries share one run.
  Future<LiveSearchOutcome> search(
    String query, {
    int page = 1,
    int concurrency = 3,
    Duration timeout = searchTimeout,
    SearchCancel? cancel,
  }) {
    final q = query.trim();
    if (q.isEmpty) return Future.value(const LiveSearchOutcome());
    final key = '$page|${q.toLowerCase()}';
    if (cancel == null) {
      final running = _inFlight[key];
      if (running != null) return running;
    }
    final future = _runSearch(q, page, concurrency, timeout, cancel);
    if (cancel == null) {
      _inFlight[key] = future;
      future.whenComplete(() => _inFlight.remove(key));
    }
    return future;
  }

  Future<LiveSearchOutcome> _runSearch(String q, int page, int concurrency,
      Duration timeout, SearchCancel? cancel) async {
    final active = _ext.activeProviders();
    if (active.isEmpty) return const LiveSearchOutcome();

    final hits = <LiveSearchHit>[];
    final failures = <String, String>{};
    var next = 0;

    Future<void> worker() async {
      while (next < active.length) {
        if (cancel?.isCancelled ?? false) return;
        final a = active[next++];
        final providerId =
            LiveId.provider(a.record.internalName, a.provider.apiName);
        try {
          final results = await _ext.host
              .search(a.record.internalName, a.provider.apiName, q,
                  page: page)
              .timeout(timeout);
          if (cancel?.isCancelled ?? false) return;
          final seen = <String>{};
          for (final r in results) {
            if (r.url.isEmpty || r.name.trim().isEmpty) continue;
            // De-duplicate inside one provider (same url or same title).
            if (!seen.add(r.url) ||
                !seen.add('t:${r.name.trim().toLowerCase()}|${r.type}')) {
              continue;
            }
            hits.add(LiveSearchHit(
              providerId: providerId,
              providerName: a.provider.name,
              result: r,
            ));
          }
        } on TimeoutException {
          failures[providerId] = 'timeout';
        } catch (e) {
          failures[providerId] =
              e is ExtensionException ? e.message : e.toString();
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < active.length; i++) worker(),
    ]);
    return LiveSearchOutcome(
      hits: hits,
      failures: failures,
      cancelled: cancel?.isCancelled ?? false,
    );
  }

  /// Home rows of every enabled provider that has a main page. Bounded
  /// concurrency, per-provider timeout, a failing provider is skipped.
  Future<List<LiveHomeSection>> home({
    int concurrency = 2,
    int rowsPerProvider = 3,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final active =
        _ext.activeProviders().where((a) => a.provider.hasMainPage).toList();
    if (active.isEmpty) return const [];
    final slots = List<List<LiveHomeSection>>.filled(active.length, const []);
    var next = 0;
    Future<void> worker() async {
      while (next < active.length) {
        final i = next++;
        final a = active[i];
        final providerId =
            LiveId.provider(a.record.internalName, a.provider.apiName);
        try {
          final rows = await _ext.host
              .home(a.record.internalName, a.provider.apiName)
              .timeout(timeout);
          slots[i] = [
            for (final r in rows.take(rowsPerProvider))
              if (r.items.isNotEmpty)
                LiveHomeSection(
                  providerId: providerId,
                  providerName: a.provider.name,
                  title: r.title,
                  items: r.items,
                ),
          ];
        } on Object {
          slots[i] = const []; // isolated: one broken provider is skipped
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < active.length; i++) worker(),
    ]);
    return [for (final s in slots) ...s];
  }

  Future<LiveDetails> details(String providerId, String url) async {
    final ref = _activeRef(providerId);
    try {
      return await _ext.host
          .details(ref.internalName, ref.apiName, url)
          .timeout(detailsTimeout);
    } on TimeoutException {
      throw const ExtensionException(
          ExtensionError.timeout, 'The provider took too long to respond.');
    } on ExtensionException {
      rethrow;
    } catch (e) {
      throw ExtensionException(ExtensionError.providerFailed, e.toString());
    }
  }

  Future<LiveLinks> links(String providerId, String data) async {
    final ref = _activeRef(providerId);
    try {
      final out = await _ext.host
          .links(ref.internalName, ref.apiName, data)
          .timeout(linksTimeout);
      return LiveLinks(
        links: [
          for (final l in out.links)
            if (_playableScheme(l.url)) l,
        ],
        subtitles: [
          for (final s in out.subtitles)
            if (_playableScheme(s.url)) s,
        ],
      );
    } on TimeoutException {
      throw const ExtensionException(
          ExtensionError.timeout, 'The provider took too long to respond.');
    } on ExtensionException {
      rethrow;
    } catch (e) {
      throw ExtensionException(ExtensionError.providerFailed, e.toString());
    }
  }

  ({String internalName, String apiName}) _activeRef(String providerId) {
    final ref = LiveId.parse(providerId);
    if (ref == null) {
      throw const ExtensionException(
          ExtensionError.notFound, 'Unknown provider.');
    }
    if (!_ext.isProviderActive(providerId)) {
      throw const ExtensionException(ExtensionError.disabled,
          'This provider is disabled or not loaded.');
    }
    return ref;
  }

  static bool _playableScheme(String url) {
    final u = Uri.tryParse(url);
    return u != null && (u.isScheme('https') || u.isScheme('http'));
  }

  /// Best link for the existing player: highest known quality, preferring
  /// a known quality over unknown. Null when [links] is empty.
  static LiveLink? pickBest(List<LiveLink> links) {
    if (links.isEmpty) return null;
    final sorted = List.of(links)
      ..sort((a, b) => (b.quality ?? -1).compareTo(a.quality ?? -1));
    return sorted.first;
  }
}
