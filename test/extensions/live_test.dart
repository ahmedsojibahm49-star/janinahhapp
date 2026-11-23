import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/extensions/core/host.dart';
import 'package:streambox/extensions/core/live.dart';
import 'package:streambox/extensions/core/manager.dart';

import 'fakes.dart';

/// Manager with N installed+enabled providers named P0..Pn.
Future<(ExtensionManager, FakeHost)> setup(int n) async {
  final fetcher = FakeFetcher();
  final host = FakeHost();
  final manager = ExtensionManager(
    fetcher: fetcher,
    store: MemoryKv(),
    packages: MemoryPackages(),
    host: host,
  );
  final rows = <Map<String, Object?>>[];
  for (var i = 0; i < n; i++) {
    final pkg = buildCs3();
    fetcher.bytes('https://repo.example/P$i.cs3', pkg);
    rows.add(pluginRow('P$i', package: pkg));
  }
  fetcher.json('https://repo.example/repo.json', {
    'name': 'R',
    'pluginLists': ['https://repo.example/plugins.json'],
  });
  fetcher.json('https://repo.example/plugins.json', rows);
  await manager.load();
  await manager.addRepo('https://repo.example/repo.json');
  for (var i = 0; i < n; i++) {
    await manager.install('P$i');
  }
  return (manager, host);
}

LiveSearchResult r(String name, {String? url, String type = 'Anime'}) =>
    LiveSearchResult(name: name, url: url ?? 'https://s/$name', type: type);

void main() {
  test('LiveId round-trips awkward names and never contains ::', () {
    for (final (internal, api) in [
      ('Simple', 'Simple'),
      ('Has Space', 'Api: One/Two'),
      ('A~B', 'C~D'),
      ('Ünï', '日本語'),
    ]) {
      final id = LiveId.provider(internal, api);
      expect(id.contains('::'), isFalse);
      expect(LiveId.isLive(id), isTrue);
      final back = LiveId.parse(id)!;
      expect(back.internalName, internal);
      expect(back.apiName, api);
    }
    expect(LiveId.parse('sample'), isNull);
    expect(LiveId.isLive('sample'), isFalse);
  });

  test('item ids are route-safe and reversible', () {
    const url = 'https://site.example/a/b?c=d&e=f#g';
    final id = LiveId.itemId(url);
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id), isTrue);
    expect(LiveId.urlFromItemId(id), url);
    expect(LiveId.urlFromItemId('***'), isNull);
  });

  test('search aggregates enabled providers with attribution', () async {
    final (m, host) = await setup(2);
    host.searchResults = {
      'P0/P0': [r('Naruto'), r('Bleach')],
      'P1/P1': [r('One Piece')],
    };
    final out = await LiveProviderManager(m).search('x');
    expect(out.hits, hasLength(3));
    expect(out.failures, isEmpty);
    final byProvider = <String, int>{};
    for (final h in out.hits) {
      byProvider[h.providerId] = (byProvider[h.providerId] ?? 0) + 1;
    }
    expect(byProvider[LiveId.provider('P0', 'P0')], 2);
    expect(byProvider[LiveId.provider('P1', 'P1')], 1);
  });

  test('disabled providers are excluded from search', () async {
    final (m, host) = await setup(2);
    host.searchResults = {
      'P0/P0': [r('A')],
      'P1/P1': [r('B')],
    };
    await m.setEnabled('P1', false);
    final out = await LiveProviderManager(m).search('x');
    expect(out.hits.map((h) => h.result.name).toList(), ['A']);
  });

  test('a failing provider yields partial results from the others',
      () async {
    final (m, host) = await setup(3);
    host.searchResults = {
      'P0/P0': [r('A')],
      'P2/P2': [r('C')],
    };
    host.failSearch.add('P1');
    final out = await LiveProviderManager(m).search('x');
    expect(out.hits.map((h) => h.result.name).toSet(), {'A', 'C'});
    expect(out.failures.keys.toList(), [LiveId.provider('P1', 'P1')]);
  });

  test('a hung provider times out without blocking the rest', () async {
    final (m, host) = await setup(2);
    host.searchResults = {'P1/P1': [r('B')]};
    host.hangSearch.add('P0');
    final out = await LiveProviderManager(m)
        .search('x', timeout: const Duration(milliseconds: 50));
    expect(out.hits.map((h) => h.result.name).toList(), ['B']);
    expect(out.failures[LiveId.provider('P0', 'P0')], 'timeout');
  });

  test('concurrency is bounded', () async {
    final (m, host) = await setup(8);
    host.searchLatency = const Duration(milliseconds: 15);
    await LiveProviderManager(m).search('x', concurrency: 3);
    expect(host.searchMaxInFlight, lessThan(4));
    expect(host.searchMaxInFlight, greaterThan(0));
  });

  test('duplicates inside one provider are dropped', () async {
    final (m, host) = await setup(1);
    host.searchResults = {
      'P0/P0': [
        r('Same', url: 'https://s/1'),
        r('Same', url: 'https://s/1'),
        r('Same', url: 'https://s/2'), // same title+type, other url
        r('Other'),
        const LiveSearchResult(name: '', url: 'https://s/empty'),
      ],
    };
    final out = await LiveProviderManager(m).search('x');
    expect(out.hits.map((h) => h.result.name).toList(), ['Same', 'Other']);
  });

  test('cancel stops new provider calls and drops late results', () async {
    final (m, host) = await setup(6);
    host.searchLatency = const Duration(milliseconds: 20);
    host.searchResults = {for (var i = 0; i < 6; i++) 'P$i/P$i': [r('T$i')]};
    final cancel = SearchCancel();
    final future =
        LiveProviderManager(m).search('x', concurrency: 2, cancel: cancel);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    cancel.cancel();
    final out = await future;
    expect(out.cancelled, isTrue);
    expect(out.hits.length, lessThan(6));
  });

  test('identical concurrent queries share one run', () async {
    final (m, host) = await setup(2);
    host.searchLatency = const Duration(milliseconds: 20);
    host.searchResults = {'P0/P0': [r('A')]};
    final live = LiveProviderManager(m);
    final a = live.search('same');
    final b = live.search('Same ');
    final outs = await Future.wait([a, b]);
    expect(outs[0].hits.length, outs[1].hits.length);
    expect(host.searchMaxInFlight, lessThan(3));
  });

  test('empty query and no providers are empty, not errors', () async {
    final (m, _) = await setup(0);
    final live = LiveProviderManager(m);
    expect((await live.search('   ')).hits, isEmpty);
    expect((await live.search('x')).hits, isEmpty);
  });

  test('details and links on a disabled provider are refused', () async {
    final (m, _) = await setup(1);
    final id = LiveId.provider('P0', 'P0');
    final live = LiveProviderManager(m);
    expect((await live.details(id, 'https://s/x')).name, 'D https://s/x');
    await m.setEnabled('P0', false);
    await expectLater(live.details(id, 'https://s/x'),
        throwsA(isA<ExtensionException>()
            .having((e) => e.error, 'error', ExtensionError.disabled)));
    await expectLater(live.links(id, 'ep1'),
        throwsA(isA<ExtensionException>()));
    await expectLater(live.details('not-live', 'u'),
        throwsA(isA<ExtensionException>()
            .having((e) => e.error, 'error', ExtensionError.notFound)));
  });

  test('links: non-http(s) urls are dropped, best quality is picked',
      () async {
    final (m, _) = await setup(1);
    final out =
        await LiveProviderManager(m).links(LiveId.provider('P0', 'P0'), 'ep1');
    expect(out.links.map((l) => l.url).toList(), [
      'https://cdn.example/ep1.m3u8',
      'https://cdn.example/ep1-1080.mp4',
    ]);
    expect(out.subtitles, hasLength(1));
    final best = LiveProviderManager.pickBest(out.links)!;
    expect(best.quality, 1080);
    expect(LiveProviderManager.pickBest(const []), isNull);
  });

  group('home rows', () {
    LiveSearchResult item(String n) =>
        LiveSearchResult(name: n, url: 'https://s/$n', type: 'Anime');

    Future<(ExtensionManager, FakeHost)> withHome(int n) async {
      final (m, host) = await setup(n);
      // Re-register providers with a main page: unload + load again.
      host.providersFor = (name) => [
            HostProvider(
                apiName: name, name: name, supportedTypes: const ['Anime'],
                hasMainPage: true),
          ];
      for (var i = 0; i < n; i++) {
        await m.setEnabled('P$i', false);
        await m.setEnabled('P$i', true);
      }
      return (m, host);
    }

    test('collects rows from providers that have a main page', () async {
      final (m, host) = await withHome(2);
      host.homeRows = {
        'P0/P0': [
          LiveHomeRow(title: 'Trending', items: [item('A'), item('B')]),
          const LiveHomeRow(title: 'Empty', items: []),
        ],
        'P1/P1': [LiveHomeRow(title: 'Latest', items: [item('C')])],
      };
      final sections = await LiveProviderManager(m).home();
      expect(sections.map((s) => '${s.providerName}:${s.title}').toList(),
          ['P0:Trending', 'P1:Latest']);
      expect(sections.first.items, hasLength(2));
    });

    test('a failing provider is skipped, others still show', () async {
      final (m, host) = await withHome(2);
      host.failHome.add('P0');
      host.homeRows = {
        'P1/P1': [LiveHomeRow(title: 'Latest', items: [item('C')])],
      };
      final sections = await LiveProviderManager(m).home();
      expect(sections.map((s) => s.providerName).toList(), ['P1']);
    });

    test('providers without a main page are not asked', () async {
      final (m, host) = await setup(1); // default FakeHost: hasMainPage false
      host.homeRows = {
        'P0/P0': [LiveHomeRow(title: 'X', items: [item('A')])],
      };
      expect(await LiveProviderManager(m).home(), isEmpty);
    });

    test('rows per provider are capped', () async {
      final (m, host) = await withHome(1);
      host.homeRows = {
        'P0/P0': [
          for (var i = 0; i < 6; i++)
            LiveHomeRow(title: 'Row$i', items: [item('T$i')]),
        ],
      };
      final sections = await LiveProviderManager(m).home();
      expect(sections, hasLength(3));
    });
  });
}
