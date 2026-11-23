import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core/host.dart';

/// Android implementation of [ExtensionHost]: a MethodChannel to the
/// Kotlin `Cs3Host` (DexClassLoader + CloudStream library). All payloads
/// cross the channel as JSON strings so no platform-codec casting is
/// needed on either side.
class NativeExtensionHost implements ExtensionHost {
  NativeExtensionHost([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'streambox/cs3';
  final MethodChannel _channel;

  Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    try {
      final raw = await _channel.invokeMethod<String>(method, args);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw);
    } on MissingPluginException {
      throw const ExtensionException(ExtensionError.unsupportedPlatform,
          'The native extension runtime is not part of this build.');
    } on PlatformException catch (e) {
      throw ExtensionException(
        switch (e.code) {
          'INIT_FAILED' => ExtensionError.initFailed,
          'TIMEOUT' => ExtensionError.timeout,
          'API_MISMATCH' => ExtensionError.apiMismatch,
          'NOT_LOADED' => ExtensionError.disabled,
          _ => ExtensionError.providerFailed,
        },
        e.message ?? e.code,
      );
    } on FormatException {
      throw const ExtensionException(ExtensionError.providerFailed,
          'The native runtime returned an unreadable answer.');
    }
  }

  @override
  Future<HostInfo> info() async {
    try {
      final j = await _call('info');
      if (j is! Map) return HostInfo.unavailable;
      return HostInfo(
        available: j['available'] == true,
        apiVersions: {
          for (final v in (j['apiVersions'] as List? ?? const [1]))
            if (v is int) v,
        },
        runtime: j['runtime'] as String? ?? 'cloudstream',
        unavailableReason: j['reason'] as String?,
      );
    } on ExtensionException catch (e) {
      return HostInfo(available: false, unavailableReason: e.message);
    }
  }

  @override
  Future<List<HostProvider>> load({
    required String internalName,
    required String path,
    required String pluginClassName,
  }) async {
    final j = await _call('load', {
      'internalName': internalName,
      'path': path,
      'pluginClassName': pluginClassName,
    });
    if (j is! List) return const [];
    return [
      for (final p in j)
        if (HostProvider.fromJson(p) != null) HostProvider.fromJson(p)!,
    ];
  }

  @override
  Future<void> unload(String internalName) async {
    await _call('unload', {'internalName': internalName});
  }

  @override
  Future<List<LiveSearchResult>> search(
    String internalName,
    String apiName,
    String query, {
    int page = 1,
  }) async {
    final j = await _call('search', {
      'internalName': internalName,
      'apiName': apiName,
      'query': query,
      'page': page,
    });
    if (j is! List) return const [];
    final out = <LiveSearchResult>[];
    for (final r in j) {
      if (r is! Map) continue;
      final name = r['name'];
      final url = r['url'];
      if (name is! String || url is! String) continue;
      out.add(LiveSearchResult(
        name: name,
        url: url,
        posterUrl: r['posterUrl'] as String?,
        type: r['type'] as String?,
        year: r['year'] as int?,
      ));
    }
    return out;
  }

  @override
  Future<LiveDetails> details(
      String internalName, String apiName, String url) async {
    final j = await _call('details', {
      'internalName': internalName,
      'apiName': apiName,
      'url': url,
    });
    if (j is! Map) {
      throw const ExtensionException(
          ExtensionError.providerFailed, 'The provider returned no details.');
    }
    final eps = <LiveEpisode>[];
    for (final e in (j['episodes'] as List? ?? const [])) {
      if (e is! Map || e['data'] is! String) continue;
      eps.add(LiveEpisode(
        data: e['data'] as String,
        name: e['name'] as String?,
        season: e['season'] as int?,
        episode: e['episode'] as int?,
        posterUrl: e['posterUrl'] as String?,
        description: e['description'] as String?,
      ));
    }
    return LiveDetails(
      name: j['name'] as String? ?? '',
      url: j['url'] as String? ?? url,
      type: j['type'] as String?,
      posterUrl: j['posterUrl'] as String?,
      backdropUrl: j['backdropUrl'] as String?,
      plot: j['plot'] as String?,
      year: j['year'] as int?,
      rating: (j['rating'] as num?)?.toDouble(),
      tags: [for (final t in (j['tags'] as List? ?? const [])) t.toString()],
      status: j['status'] as String?,
      episodes: eps,
    );
  }

  @override
  Future<LiveLinks> links(
      String internalName, String apiName, String data) async {
    final j = await _call('links', {
      'internalName': internalName,
      'apiName': apiName,
      'data': data,
    });
    if (j is! Map) return const LiveLinks();
    final links = <LiveLink>[];
    for (final l in (j['links'] as List? ?? const [])) {
      if (l is! Map || l['url'] is! String) continue;
      final headers = <String, String>{};
      final h = l['headers'];
      if (h is Map) {
        h.forEach((k, v) => headers[k.toString()] = v.toString());
      }
      links.add(LiveLink(
        url: l['url'] as String,
        source: l['source'] as String? ?? '',
        name: l['name'] as String?,
        quality: l['quality'] as int?,
        isM3u8: l['isM3u8'] == true,
        headers: headers,
      ));
    }
    final subs = <LiveSubtitle>[];
    for (final s in (j['subtitles'] as List? ?? const [])) {
      if (s is! Map || s['url'] is! String) continue;
      subs.add(LiveSubtitle(
          lang: s['lang'] as String? ?? '', url: s['url'] as String));
    }
    return LiveLinks(links: links, subtitles: subs);
  }

  @override
  Future<List<LiveHomeRow>> home(String internalName, String apiName) async {
    final j = await _call('home', {
      'internalName': internalName,
      'apiName': apiName,
    });
    if (j is! List) return const [];
    final rows = <LiveHomeRow>[];
    for (final r in j) {
      if (r is! Map || r['title'] is! String) continue;
      final items = <LiveSearchResult>[];
      for (final it in (r['items'] as List? ?? const [])) {
        if (it is! Map || it['name'] is! String || it['url'] is! String) {
          continue;
        }
        items.add(LiveSearchResult(
          name: it['name'] as String,
          url: it['url'] as String,
          posterUrl: it['posterUrl'] as String?,
          type: it['type'] as String?,
          year: it['year'] as int?,
        ));
      }
      rows.add(LiveHomeRow(title: r['title'] as String, items: items));
    }
    return rows;
  }
}

/// Picks the runtime for this platform. Only Android can host CloudStream
/// (`.cs3`) packages — they are Dalvik bytecode.
ExtensionHost createExtensionHost() {
  if (!kIsWeb && Platform.isAndroid) return NativeExtensionHost();
  return const UnavailableHost(
      'CloudStream extensions are Android-only (they are DEX bytecode).');
}
