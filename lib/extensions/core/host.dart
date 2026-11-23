import 'dart:convert';
import 'dart:typed_data';

/// Injected edges of the extension layer. The Flutter app supplies real
/// implementations (http, Hive, dart:io, Android MethodChannel); tests
/// supply fakes.

// ---------------------------------------------------------------- errors

enum ExtensionError {
  unsupportedPlatform,
  apiMismatch,
  unsupportedPackage,
  network,
  timeout,
  http,
  tooLarge,
  integrity,
  invalidPackage,
  initFailed,
  duplicateRepo,
  invalidRepo,
  notFound,
  disabled,
  providerFailed,
}

/// Structured, user-presentable failure. [message] is English detail text
/// for logs/diagnostics; the UI localises by [error].
class ExtensionException implements Exception {
  const ExtensionException(this.error, this.message, {this.statusCode});
  final ExtensionError error;
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

// ------------------------------------------------------------------ http

enum FetchFailure { network, timeout, http, tooLarge }

class FetchException implements Exception {
  const FetchException(this.kind, this.message, {this.statusCode});
  final FetchFailure kind;
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

typedef ProgressCallback = void Function(int received, int? total);

abstract class ExtensionFetcher {
  /// GET [url]. Throws [FetchException]. Must enforce [maxBytes] while
  /// streaming (not after) and [timeout] on connect + body.
  Future<Uint8List> fetch(
    Uri url, {
    Duration timeout = const Duration(seconds: 20),
    int maxBytes = 10 * 1024 * 1024,
    ProgressCallback? onProgress,
  });
}

// --------------------------------------------------------------- storage

abstract class KeyValueStore {
  String? read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Where installed packages live on disk.
abstract class PackageStorage {
  /// Persist [bytes] and return the absolute path. The file must be
  /// read-only afterwards (Android 14+ refuses to load writable dex).
  Future<String> save(String fileName, Uint8List bytes);
  Future<void> delete(String path);
  Future<bool> exists(String path);
}

// ------------------------------------------------------------------ host

/// What the native runtime can do on this device.
class HostInfo {
  const HostInfo({
    required this.available,
    this.apiVersions = const {1},
    this.runtime = 'none',
    this.unavailableReason,
  });

  final bool available;

  /// CloudStream plugin `apiVersion`s the runtime was built against.
  final Set<int> apiVersions;
  final String runtime;
  final String? unavailableReason;

  static const HostInfo unavailable = HostInfo(
    available: false,
    unavailableReason: 'No compatible native runtime on this platform.',
  );
}

/// A provider (CloudStream `MainAPI`) registered by one package.
class HostProvider {
  const HostProvider({
    required this.apiName,
    required this.name,
    this.lang,
    this.supportedTypes = const [],
    this.hasMainPage = false,
  });

  final String apiName;
  final String name;
  final String? lang;
  final List<String> supportedTypes;
  final bool hasMainPage;

  Map<String, dynamic> toJson() => {
        'apiName': apiName,
        'name': name,
        'lang': lang,
        'supportedTypes': supportedTypes,
        'hasMainPage': hasMainPage,
      };

  static HostProvider? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final api = raw['apiName'];
    if (api is! String || api.isEmpty) return null;
    return HostProvider(
      apiName: api,
      name: raw['name'] is String ? raw['name'] as String : api,
      lang: raw['lang'] is String ? raw['lang'] as String : null,
      supportedTypes: raw['supportedTypes'] is List
          ? [for (final t in raw['supportedTypes'] as List) t.toString()]
          : const [],
      hasMainPage: raw['hasMainPage'] == true,
    );
  }
}

class LiveSearchResult {
  const LiveSearchResult({
    required this.name,
    required this.url,
    this.posterUrl,
    this.type,
    this.year,
  });
  final String name;
  final String url;
  final String? posterUrl;

  /// CloudStream TvType name (`Anime`, `Movie`, `TvSeries`…).
  final String? type;
  final int? year;
}

/// One home row a provider offers ("Trending", "Latest"...).
class LiveHomeRow {
  const LiveHomeRow({required this.title, required this.items});
  final String title;
  final List<LiveSearchResult> items;
}

class LiveEpisode {
  const LiveEpisode({
    required this.data,
    this.name,
    this.season,
    this.episode,
    this.posterUrl,
    this.description,
  });

  /// Opaque string handed back to `loadLinks`.
  final String data;
  final String? name;
  final int? season;
  final int? episode;
  final String? posterUrl;
  final String? description;
}

class LiveDetails {
  const LiveDetails({
    required this.name,
    required this.url,
    this.type,
    this.posterUrl,
    this.backdropUrl,
    this.plot,
    this.year,
    this.rating,
    this.tags = const [],
    this.status,
    this.episodes = const [],
  });

  final String name;
  final String url;
  final String? type;
  final String? posterUrl;
  final String? backdropUrl;
  final String? plot;
  final int? year;

  /// 0–10.
  final double? rating;
  final List<String> tags;
  final String? status;

  /// For a movie: exactly one entry whose [LiveEpisode.data] plays it.
  final List<LiveEpisode> episodes;
}

class LiveLink {
  const LiveLink({
    required this.url,
    required this.source,
    this.name,
    this.quality,
    this.isM3u8 = false,
    this.headers = const {},
  });
  final String url;
  final String source;
  final String? name;

  /// Vertical resolution (1080…) or null when unknown.
  final int? quality;
  final bool isM3u8;
  final Map<String, String> headers;

  Map<String, dynamic> toJson() => {
        'url': url,
        'source': source,
        'name': name,
        'quality': quality,
        'isM3u8': isM3u8,
        'headers': headers,
      };
}

class LiveSubtitle {
  const LiveSubtitle({required this.lang, required this.url});
  final String lang;
  final String url;
}

class LiveLinks {
  const LiveLinks({this.links = const [], this.subtitles = const []});
  final List<LiveLink> links;
  final List<LiveSubtitle> subtitles;
}

/// The native runtime. One instance per app. Every call can throw
/// [ExtensionException]; implementations must translate platform errors.
abstract class ExtensionHost {
  Future<HostInfo> info();

  /// Load [path] and register its providers. Idempotent per
  /// [internalName]: loading again replaces the previous load.
  Future<List<HostProvider>> load({
    required String internalName,
    required String path,
    required String pluginClassName,
  });

  Future<void> unload(String internalName);

  Future<List<LiveSearchResult>> search(
    String internalName,
    String apiName,
    String query, {
    int page = 1,
  });

  Future<LiveDetails> details(
      String internalName, String apiName, String url);

  Future<LiveLinks> links(
      String internalName, String apiName, String data);

  /// The provider's home rows (empty when it has none).
  Future<List<LiveHomeRow>> home(String internalName, String apiName);
}

/// Host used on platforms without a runtime (iOS, desktop, tests).
class UnavailableHost implements ExtensionHost {
  const UnavailableHost([this.reason]);
  final String? reason;

  ExtensionException get _error => ExtensionException(
        ExtensionError.unsupportedPlatform,
        reason ?? HostInfo.unavailable.unavailableReason!,
      );

  @override
  Future<HostInfo> info() async => HostInfo(
        available: false,
        unavailableReason: reason ?? HostInfo.unavailable.unavailableReason,
      );
  @override
  Future<List<HostProvider>> load(
          {required String internalName,
          required String path,
          required String pluginClassName}) =>
      Future.error(_error);
  @override
  Future<void> unload(String internalName) async {}
  @override
  Future<List<LiveSearchResult>> search(
          String internalName, String apiName, String query,
          {int page = 1}) =>
      Future.error(_error);
  @override
  Future<LiveDetails> details(
          String internalName, String apiName, String url) =>
      Future.error(_error);
  @override
  Future<LiveLinks> links(
          String internalName, String apiName, String data) =>
      Future.error(_error);
  @override
  Future<List<LiveHomeRow>> home(String internalName, String apiName) =>
      Future.error(_error);
}

// ------------------------------------------------------- provider ids

/// Catalog `providerId` for a live provider: `cs3~<internal>~<api>`.
/// `::` never appears (the catalog box key is `providerId::itemId`).
class LiveId {
  LiveId._();
  static const String prefix = 'cs3~';

  static String provider(String internalName, String apiName) =>
      '$prefix${_enc(internalName)}~${_enc(apiName)}';

  static bool isLive(String providerId) => providerId.startsWith(prefix);

  /// Returns (internalName, apiName) or null.
  static ({String internalName, String apiName})? parse(String providerId) {
    if (!isLive(providerId)) return null;
    final parts = providerId.substring(prefix.length).split('~');
    if (parts.length != 2) return null;
    try {
      return (
        internalName: Uri.decodeComponent(parts[0]),
        apiName: Uri.decodeComponent(parts[1]),
      );
    } on FormatException {
      return null;
    }
  }

  /// Reversible, route-safe item id for a provider URL.
  static String itemId(String url) =>
      base64Url.encode(utf8.encode(url)).replaceAll('=', '');

  static String? urlFromItemId(String id) {
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(id)));
    } on FormatException {
      return null;
    }
  }

  static String _enc(String s) =>
      Uri.encodeComponent(s).replaceAll('~', '%7E');
}
