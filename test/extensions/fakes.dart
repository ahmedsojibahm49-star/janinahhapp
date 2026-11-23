import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:streambox/extensions/core/host.dart';
import 'package:streambox/extensions/core/sha256.dart';

// ------------------------------------------------------------ zip builder

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

/// Build a real ZIP. [deflate] uses method 8 (raw deflate) like real
/// `.cs3` files; false uses method 0 (stored).
Uint8List buildZip(Map<String, List<int>> files, {bool deflate = true}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  void u16(BytesBuilder b, int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(BytesBuilder b, int v) => b.add(
      [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

  files.forEach((name, data) {
    final nameBytes = utf8.encode(name);
    final method = deflate ? 8 : 0;
    final comp = deflate ? ZLibCodec(raw: true).encode(data) : data;
    final crc = _crc32(data);
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, 0);
    u16(out, method);
    u16(out, 0);
    u16(out, 0);
    u32(out, crc);
    u32(out, comp.length);
    u32(out, data.length);
    u16(out, nameBytes.length);
    u16(out, 0);
    out.add(nameBytes);
    out.add(comp);

    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0);
    u16(central, method);
    u16(central, 0);
    u16(central, 0);
    u32(central, crc);
    u32(central, comp.length);
    u32(central, data.length);
    u16(central, nameBytes.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(nameBytes);
    count++;
  });
  final cdOffset = out.length;
  final cd = central.toBytes();
  out.add(cd);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, count);
  u16(out, count);
  u32(out, cd.length);
  u32(out, cdOffset);
  u16(out, 0);
  return out.toBytes();
}

/// A syntactically valid CloudStream package.
Uint8List buildCs3({
  String pluginClassName = 'com.example.ExamplePlugin',
  int version = 1,
  bool deflate = true,
  Map<String, List<int>> extra = const {},
}) =>
    buildZip({
      'classes.dex': utf8.encode('dex 035 fake bytecode ' * 20),
      'manifest.json': utf8.encode(jsonEncode({
        'pluginClassName': pluginClassName,
        'name': 'Example',
        'version': version,
        'requiresResources': false,
      })),
      ...extra,
    }, deflate: deflate);

// ------------------------------------------------------------------ fakes

class FakeFetcher implements ExtensionFetcher {
  final Map<String, Object> routes = {}; // Uint8List | String | FetchException
  final List<String> calls = [];
  int inFlight = 0;
  int maxInFlight = 0;
  Duration latency = Duration.zero;

  void json(String url, Object body) =>
      routes[url] = Uint8List.fromList(utf8.encode(jsonEncode(body)));
  void bytes(String url, List<int> b) =>
      routes[url] = Uint8List.fromList(b);
  void fail(String url, FetchException e) => routes[url] = e;

  @override
  Future<Uint8List> fetch(Uri url,
      {Duration timeout = const Duration(seconds: 20),
      int maxBytes = 10 * 1024 * 1024,
      ProgressCallback? onProgress}) async {
    calls.add(url.toString());
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      final r = routes[url.toString()];
      if (r == null) {
        throw const FetchException(FetchFailure.http, 'HTTP 404',
            statusCode: 404);
      }
      if (r is FetchException) throw r;
      final b = r as Uint8List;
      if (b.length > maxBytes) {
        throw const FetchException(FetchFailure.tooLarge, 'too large');
      }
      onProgress?.call(b.length ~/ 2, b.length);
      onProgress?.call(b.length, b.length);
      return b;
    } finally {
      inFlight--;
    }
  }
}

class MemoryKv implements KeyValueStore {
  final Map<String, String> data = {};
  @override
  String? read(String key) => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class MemoryPackages implements PackageStorage {
  final Map<String, Uint8List> files = {};
  @override
  Future<String> save(String fileName, Uint8List bytes) async {
    final p = '/pkgs/$fileName';
    files[p] = bytes;
    return p;
  }

  @override
  Future<void> delete(String path) async => files.remove(path);
  @override
  Future<bool> exists(String path) async => files.containsKey(path);
}

class FakeHost implements ExtensionHost {
  FakeHost({this.available = true, this.apis = const {1}});
  final bool available;
  final Set<int> apis;
  final Set<String> loaded = {};
  final List<String> loadCalls = [];
  final List<String> unloadCalls = [];
  final Set<String> failLoadPaths = {};
  final Set<String> hangLoad = {};
  final Set<String> failSearch = {};
  final Set<String> hangSearch = {};
  Map<String, List<LiveSearchResult>> searchResults = {};
  Map<String, List<LiveHomeRow>> homeRows = {};
  final Set<String> failHome = {};
  int searchInFlight = 0;
  int searchMaxInFlight = 0;
  Duration searchLatency = Duration.zero;
  List<HostProvider> Function(String internalName) providersFor =
      (n) => [HostProvider(apiName: n, name: n, supportedTypes: ['Anime'])];

  @override
  Future<HostInfo> info() async => HostInfo(
        available: available,
        apiVersions: apis,
        runtime: 'fake',
        unavailableReason: available ? null : 'no runtime',
      );

  @override
  Future<List<HostProvider>> load(
      {required String internalName,
      required String path,
      required String pluginClassName}) async {
    loadCalls.add('$internalName@$path');
    if (hangLoad.contains(internalName)) await Completer<void>().future;
    if (failLoadPaths.contains(path)) {
      throw const ExtensionException(
          ExtensionError.initFailed, 'ClassNotFoundException');
    }
    loaded.add(internalName);
    return providersFor(internalName);
  }

  @override
  Future<void> unload(String internalName) async {
    unloadCalls.add(internalName);
    loaded.remove(internalName);
  }

  @override
  Future<List<LiveSearchResult>> search(
      String internalName, String apiName, String query,
      {int page = 1}) async {
    searchInFlight++;
    if (searchInFlight > searchMaxInFlight) {
      searchMaxInFlight = searchInFlight;
    }
    try {
      if (searchLatency > Duration.zero) {
        await Future<void>.delayed(searchLatency);
      }
      if (hangSearch.contains(internalName)) {
        await Completer<void>().future;
      }
      if (failSearch.contains(internalName)) {
        throw const ExtensionException(
            ExtensionError.providerFailed, 'site changed');
      }
      return searchResults['$internalName/$apiName'] ?? const [];
    } finally {
      searchInFlight--;
    }
  }

  @override
  Future<List<LiveHomeRow>> home(String internalName, String apiName) async {
    if (failHome.contains(internalName)) {
      throw const ExtensionException(
          ExtensionError.providerFailed, 'home broke');
    }
    return homeRows['$internalName/$apiName'] ?? const [];
  }

  @override
  Future<LiveDetails> details(
          String internalName, String apiName, String url) async =>
      LiveDetails(name: 'D $url', url: url, episodes: const [
        LiveEpisode(data: 'ep1', episode: 1),
      ]);

  @override
  Future<LiveLinks> links(
          String internalName, String apiName, String data) async =>
      LiveLinks(links: [
        LiveLink(url: 'https://cdn.example/$data.m3u8', source: 'S',
            quality: 720, isM3u8: true),
        LiveLink(url: 'https://cdn.example/$data-1080.mp4', source: 'S',
            quality: 1080),
        const LiveLink(url: 'javascript:alert(1)', source: 'evil'),
      ], subtitles: [
        const LiveSubtitle(lang: 'en', url: 'https://cdn.example/s.vtt'),
      ]);
}

/// A plugin list entry as CloudStream publishes it.
Map<String, Object?> pluginRow(
  String internal, {
  int version = 1,
  Uint8List? package,
  bool withHash = true,
  int? apiVersion = 1,
  String? url,
  List<String> tvTypes = const ['Anime'],
  int status = 1,
}) =>
    {
      'name': internal,
      'internalName': internal,
      'url': url ?? 'https://repo.example/$internal.cs3',
      'version': version,
      'status': status,
      'authors': ['someone'],
      'description': 'desc $internal',
      'language': 'en',
      'tvTypes': tvTypes,
      'iconUrl': 'https://repo.example/$internal.png',
      'repositoryUrl': 'https://github.com/x/y',
      'apiVersion': ?apiVersion,
      if (package != null) 'fileSize': package.length,
      if (package != null && withHash) 'fileHash': sha256Hex(package),
    };
