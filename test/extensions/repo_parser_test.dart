import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/extensions/core/models.dart';
import 'package:streambox/extensions/core/repo_parser.dart';

import 'fakes.dart';

void main() {
  group('normalizeRepoUrl', () {
    test('accepts https and rejects http / junk', () {
      expect(normalizeRepoUrl('https://a.example/repo.json').toString(),
          'https://a.example/repo.json');
      expect(normalizeRepoUrl('http://a.example/repo.json'), isNull);
      expect(normalizeRepoUrl('not a url'), isNull);
      expect(normalizeRepoUrl('  '), isNull);
      expect(normalizeRepoUrl('ftp://a.example/x'), isNull);
    });

    test('cloudstreamrepo:// becomes https://', () {
      expect(normalizeRepoUrl('cloudstreamrepo://a.example/r.json').toString(),
          'https://a.example/r.json');
    });

    test('github blob URL becomes raw URL', () {
      expect(
          normalizeRepoUrl(
                  'https://github.com/phisher98/ext/blob/builds/repo.json')
              .toString(),
          'https://raw.githubusercontent.com/phisher98/ext/builds/repo.json');
    });
  });

  group('parseRepoManifest', () {
    test('valid manifest', () {
      final m = parseRepoManifest({
        'name': 'Phisher Repo',
        'iconUrl': 'https://x/i.png',
        'description': 'd',
        'manifestVersion': 1,
        'pluginLists': ['https://x/plugins.json'],
      });
      expect(m.name, 'Phisher Repo');
      expect(m.pluginLists, ['https://x/plugins.json']);
      expect(m.manifestVersion, 1);
    });

    test('multiple lists are kept, duplicates and bad urls dropped', () {
      final m = parseRepoManifest({
        'name': 'R',
        'pluginLists': [
          'https://x/a.json',
          'https://x/b.json',
          'https://x/a.json',
          'http://insecure/c.json',
          42,
        ],
      });
      expect(m.pluginLists, ['https://x/a.json', 'https://x/b.json']);
    });

    test('rejects non-object, missing or empty pluginLists', () {
      expect(() => parseRepoManifest([]),
          throwsA(isA<ExtensionFormatException>()));
      expect(() => parseRepoManifest({'name': 'x'}),
          throwsA(isA<ExtensionFormatException>()));
      expect(() => parseRepoManifest({'pluginLists': []}),
          throwsA(isA<ExtensionFormatException>()));
      expect(
          () => parseRepoManifest({
                'pluginLists': ['http://only-insecure/x.json']
              }),
          throwsA(isA<ExtensionFormatException>()));
    });

    test('name falls back when absent', () {
      expect(
          parseRepoManifest({
            'pluginLists': ['https://x/a.json']
          }).name,
          'Repository');
    });
  });

  group('parsePluginList', () {
    test('parses every documented field', () {
      final pkg = buildCs3();
      final r = parsePluginList([pluginRow('Alpha', package: pkg)]);
      expect(r.entries, hasLength(1));
      final e = r.entries.single;
      expect(e.internalName, 'Alpha');
      expect(e.name, 'Alpha');
      expect(e.url, 'https://repo.example/Alpha.cs3');
      expect(e.version, 1);
      expect(e.status, 1);
      expect(e.authors, ['someone']);
      expect(e.description, 'desc Alpha');
      expect(e.fileSize, pkg.length);
      expect(e.repositoryUrl, 'https://github.com/x/y');
      expect(e.language, 'en');
      expect(e.tvTypes, ['Anime']);
      expect(e.iconUrl, 'https://repo.example/Alpha.png');
      expect(e.apiVersion, 1);
      expect(e.fileHash!.length, 64);
    });

    test('empty list is valid and empty', () {
      final r = parsePluginList([]);
      expect(r.entries, isEmpty);
      expect(r.skipped, 0);
    });

    test('non-array is rejected', () {
      expect(() => parsePluginList({'a': 1}),
          throwsA(isA<ExtensionFormatException>()));
    });

    test('invalid rows are skipped and counted, not fatal', () {
      final r = parsePluginList([
        pluginRow('Good'),
        {'internalName': 'NoUrl'},
        'junk',
        pluginRow('Insecure', url: 'http://x/y.cs3'),
        pluginRow('../evil'),
        pluginRow('Also Good'),
      ]);
      expect(r.entries.map((e) => e.internalName).toSet(),
          {'Good', 'Also Good'});
      expect(r.skipped, 4);
    });

    test('duplicates keep the higher version', () {
      final r = parsePluginList([
        pluginRow('Dup', version: 2),
        pluginRow('Dup', version: 5),
        pluginRow('Dup', version: 3),
      ]);
      expect(r.entries, hasLength(1));
      expect(r.entries.single.version, 5);
      expect(r.duplicates, 2);
    });

    test('malformed hash is ignored, sha256: prefix accepted', () {
      final good = 'a' * 64;
      final r = parsePluginList([
        {...pluginRow('A'), 'fileHash': 'zzz'},
        {...pluginRow('B'), 'fileHash': 'sha256:${good.toUpperCase()}'},
      ]);
      final byName = {for (final e in r.entries) e.internalName: e};
      expect(byName['A']!.fileHash, isNull);
      expect(byName['B']!.fileHash, good);
    });

    test('tolerates nulls and numeric strings', () {
      final r = parsePluginList([
        {
          'internalName': 'N',
          'url': 'https://x/N.cs3',
          'version': '7',
          'authors': null,
          'tvTypes': null,
          'description': null,
        }
      ]);
      expect(r.entries.single.version, 7);
      expect(r.entries.single.authors, isEmpty);
    });
  });

  group('categories', () {
    test('tvTypes map to store categories', () {
      expect(categoriesFor(['Anime', 'AnimeMovie']),
          {ExtensionCategory.anime});
      expect(categoriesFor(['Movie']), {ExtensionCategory.movies});
      expect(categoriesFor(['TvSeries', 'AsianDrama']),
          {ExtensionCategory.tvSeries});
      expect(categoriesFor(['NSFW']), {ExtensionCategory.other});
      expect(categoriesFor([]), {ExtensionCategory.other});
      expect(categoriesFor(['Movie', 'Anime']),
          {ExtensionCategory.movies, ExtensionCategory.anime});
    });
  });

  group('real CloudStream repository data', () {
    test('sha256-<hex> hashes (the real format) are read', () {
      final hex = 'ab' * 32;
      final r = parsePluginList([
        {...pluginRow('A'), 'fileHash': 'sha256-$hex'},
      ]);
      expect(r.entries.single.fileHash, hex);
    });

    test('icon urls with %size% get a real size; http is upgraded', () {
      final r = parsePluginList([
        {
          ...pluginRow('A'),
          'iconUrl':
              'https://www.google.com/s2/favicons?domain=x.cc&sz=%size%',
        },
        {...pluginRow('B'), 'iconUrl': 'http://x.example/i.png'},
        {...pluginRow('C'), 'iconUrl': 'javascript:alert(1)'},
      ]);
      final by = {for (final e in r.entries) e.internalName: e};
      expect(by['A']!.iconUrl,
          'https://www.google.com/s2/favicons?domain=x.cc&sz=128');
      expect(by['B']!.iconUrl, 'https://x.example/i.png');
      expect(by['C']!.iconUrl, isNull);
    });
  });

  test('decodeJsonBytes tolerates a BOM and rejects garbage', () {
    final withBom = [0xEF, 0xBB, 0xBF, ...utf8.encode('{"a":1}')];
    expect(decodeJsonBytes(withBom), {'a': 1});
    expect(() => decodeJsonBytes(utf8.encode('<html>')),
        throwsA(isA<ExtensionFormatException>()));
  });
}
