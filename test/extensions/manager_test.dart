import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/extensions/core/host.dart';
import 'package:streambox/extensions/core/manager.dart';
import 'package:streambox/extensions/core/sha256.dart';

import 'fakes.dart';

const repoUrl = 'https://repo.example/repo.json';
const listA = 'https://repo.example/plugins.json';
const listB = 'https://repo.example/plugins2.json';

class Env {
  Env({HostInfoOverride? host}) {
    this.host = host == null ? FakeHost() : FakeHost(available: host.available, apis: host.apis);
    manager = ExtensionManager(
      fetcher: fetcher,
      store: kv,
      packages: pkgs,
      host: this.host,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
  }
  final fetcher = FakeFetcher();
  final kv = MemoryKv();
  final pkgs = MemoryPackages();
  late final FakeHost host;
  late final ExtensionManager manager;

  /// A fresh manager over the SAME storage = an app restart.
  ExtensionManager restart({FakeHost? newHost}) => ExtensionManager(
        fetcher: fetcher,
        store: kv,
        packages: pkgs,
        host: newHost ?? host,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1700000001000),
      );

  void publish(List<Map<String, Object?>> rows,
      {List<String> lists = const [listA]}) {
    fetcher.json(repoUrl, {
      'name': 'Test Repo',
      'iconUrl': 'https://repo.example/icon.png',
      'description': 'd',
      'manifestVersion': 1,
      'pluginLists': lists,
    });
    fetcher.json(lists.first, rows);
  }
}

class HostInfoOverride {
  const HostInfoOverride({this.available = true, this.apis = const {1}});
  final bool available;
  final Set<int> apis;
}

/// Publish one installable package and return its bytes.
Env withPackage({String name = 'Alpha', int version = 1}) {
  final env = Env();
  final pkg = buildCs3(version: version);
  env.fetcher.bytes('https://repo.example/$name.cs3', pkg);
  env.publish([pluginRow(name, version: version, package: pkg)]);
  return env;
}

void main() {
  group('repositories', () {
    test('add: fetches repo.json, then every plugin list, stores entries',
        () async {
      final env = Env();
      env.publish([pluginRow('Alpha'), pluginRow('Beta')]);
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      expect(repo.name, 'Test Repo');
      expect(repo.entries, hasLength(2));
      expect(repo.lastRefreshedAt, 1700000000000);
      expect(env.fetcher.calls, [repoUrl, listA]);
      expect(env.manager.storeItems().map((i) => i.internalName).toList(),
          ['Alpha', 'Beta']);
    });

    test('multiple plugin lists are all fetched and merged', () async {
      final env = Env();
      env.publish([pluginRow('Alpha')], lists: [listA, listB]);
      env.fetcher.json(listB, [pluginRow('Beta'), pluginRow('Alpha', version: 4)]);
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      final byName = {for (final e in repo.entries) e.internalName: e};
      expect(byName.keys.toSet(), {'Alpha', 'Beta'});
      expect(byName['Alpha']!.version, 4); // duplicate → higher version
      expect(repo.duplicates, 1);
    });

    test('one failing plugin list still yields partial results', () async {
      final env = Env();
      env.publish([pluginRow('Alpha')], lists: [listA, listB]);
      env.fetcher.fail(listB,
          const FetchException(FetchFailure.network, 'offline'));
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      expect(repo.entries, hasLength(1));
      expect(repo.lastError, contains('1 of 2'));
    });

    test('every plugin list failing is an invalid repo', () async {
      final env = Env();
      env.publish([], lists: [listA]);
      env.fetcher.fail(
          listA, const FetchException(FetchFailure.timeout, 'slow'));
      await env.manager.load();
      await expectLater(
          env.manager.addRepo(repoUrl),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.invalidRepo)));
      expect(env.manager.repos, isEmpty);
    });

    test('empty plugin list is a valid empty repository', () async {
      final env = Env();
      env.publish([]);
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      expect(repo.entries, isEmpty);
      expect(env.manager.storeItems(), isEmpty);
    });

    test('network, timeout and HTTP errors map to typed errors', () async {
      for (final (failure, expected) in [
        (FetchFailure.network, ExtensionError.network),
        (FetchFailure.timeout, ExtensionError.timeout),
        (FetchFailure.http, ExtensionError.http),
        (FetchFailure.tooLarge, ExtensionError.tooLarge),
      ]) {
        final env = Env();
        env.fetcher.fail(repoUrl, FetchException(failure, 'x'));
        await env.manager.load();
        await expectLater(
            env.manager.addRepo(repoUrl),
            throwsA(isA<ExtensionException>()
                .having((e) => e.error, 'error', expected)));
      }
    });

    test('invalid JSON / not a repo are rejected', () async {
      final env = Env();
      env.fetcher.bytes(repoUrl, utf8.encode('<html>nope</html>'));
      await env.manager.load();
      await expectLater(
          env.manager.addRepo(repoUrl),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.invalidRepo)));
      env.fetcher.json(repoUrl, {'name': 'x'}); // object without pluginLists
      await expectLater(
          env.manager.addRepo(repoUrl),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.invalidRepo)));
    });

    test('http:// and garbage urls are rejected before any request',
        () async {
      final env = Env();
      await env.manager.load();
      for (final bad in ['http://x/repo.json', 'hello', '']) {
        await expectLater(
            env.manager.addRepo(bad),
            throwsA(isA<ExtensionException>()
                .having((e) => e.error, 'error', ExtensionError.invalidRepo)));
      }
      expect(env.fetcher.calls, isEmpty);
    });

    test('duplicate repository is refused', () async {
      final env = Env();
      env.publish([pluginRow('Alpha')]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await expectLater(
          env.manager.addRepo(repoUrl),
          throwsA(isA<ExtensionException>().having(
              (e) => e.error, 'error', ExtensionError.duplicateRepo)));
    });

    test('a bare plugins.json URL works as a one-list repository', () async {
      final env = Env();
      env.fetcher.json(listA, [pluginRow('Alpha')]);
      await env.manager.load();
      final repo = await env.manager.addRepo(listA);
      expect(repo.entries, hasLength(1));
      expect(repo.pluginListUrls, [listA]);
    });

    test('refresh picks up new versions; failure keeps the cache', () async {
      final env = Env();
      env.publish([pluginRow('Alpha', version: 1)]);
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      env.fetcher.json(listA, [pluginRow('Alpha', version: 2)]);
      await env.manager.refreshRepo(repo.id);
      expect(env.manager.storeItem('Alpha')!.entry.version, 2);

      env.fetcher.fail(
          listA, const FetchException(FetchFailure.network, 'offline'));
      await expectLater(env.manager.refreshRepo(repo.id),
          throwsA(isA<ExtensionException>()));
      // cached entries are still there, error is recorded
      expect(env.manager.storeItem('Alpha')!.entry.version, 2);
      expect(env.manager.repos.single.lastError, isNotNull);
    });

    test('refreshAll continues past a failing repo and counts failures',
        () async {
      final env = Env();
      env.publish([pluginRow('Alpha')]);
      env.fetcher.json('https://other.example/r.json', {
        'name': 'Other',
        'pluginLists': ['https://other.example/p.json'],
      });
      env.fetcher.json('https://other.example/p.json', [pluginRow('Gamma')]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await env.manager.addRepo('https://other.example/r.json');
      env.fetcher.fail(repoUrl,
          const FetchException(FetchFailure.network, 'down'));
      final failed = await env.manager.refreshAll();
      expect(failed, 1);
      expect(env.manager.storeItems().map((e) => e.internalName).toSet(),
          {'Alpha', 'Gamma'});
    });

    test('remove deletes the listing but keeps installed packages',
        () async {
      final env = withPackage();
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      await env.manager.install('Alpha');
      await env.manager.removeRepo(repo.id);
      expect(env.manager.repos, isEmpty);
      expect(env.manager.storeItems(), isEmpty);
      expect(env.manager.installed.single.internalName, 'Alpha');
      expect(env.manager.isProviderActive(LiveId.provider('Alpha', 'Alpha')),
          isTrue);
    });

    test('repositories survive an app restart', () async {
      final env = Env();
      env.publish([pluginRow('Alpha')]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      final again = env.restart();
      await again.load();
      expect(again.repos.single.name, 'Test Repo');
      expect(again.storeItems().single.internalName, 'Alpha');
    });

    test('a corrupt cache starts empty instead of crashing', () async {
      final env = Env();
      env.kv.data[ExtensionManager.reposKey] = '{not json';
      env.kv.data[ExtensionManager.installedKey] = '[1,2,"x"]';
      await env.manager.load();
      expect(env.manager.repos, isEmpty);
      expect(env.manager.installed, isEmpty);
    });

    test('plugin lists are fetched with bounded concurrency', () async {
      final env = Env();
      final urls = [for (var i = 0; i < 8; i++) 'https://repo.example/p$i.json'];
      env.fetcher.json(repoUrl, {'name': 'R', 'pluginLists': urls});
      for (var i = 0; i < urls.length; i++) {
        env.fetcher.json(urls[i], [pluginRow('P$i')]);
      }
      env.fetcher.latency = const Duration(milliseconds: 10);
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      expect(repo.entries, hasLength(8));
      expect(env.fetcher.maxInFlight, lessThan(4));
    });
  });

  group('store', () {
    test('same extension in two repos: best version wins, others listed',
        () async {
      final env = Env();
      env.publish([pluginRow('Alpha', version: 1)]);
      env.fetcher.json('https://b.example/r.json',
          {'name': 'Repo B', 'pluginLists': ['https://b.example/p.json']});
      env.fetcher.json('https://b.example/p.json',
          [pluginRow('Alpha', version: 3, url: 'https://b.example/A.cs3')]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await env.manager.addRepo('https://b.example/r.json');
      final item = env.manager.storeItem('Alpha')!;
      expect(item.entry.version, 3);
      expect(item.repo.name, 'Repo B');
      expect(item.otherRepoNames, ['Test Repo']);
    });

    test('compatibility is reported, not hidden', () async {
      final env = Env();
      env.publish([
        pluginRow('Fine'),
        pluginRow('NewApi', apiVersion: 99),
        pluginRow('Jar', url: 'https://repo.example/x.jar'),
      ]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      final c = {
        for (final i in env.manager.storeItems()) i.internalName: i.compatibility
      };
      expect(c['Fine'], Compatibility.compatible);
      expect(c['NewApi'], Compatibility.apiMismatch);
      expect(c['Jar'], Compatibility.unsupportedPackage);
    });

    test('no native runtime: everything is unsupportedPlatform', () async {
      final env = Env(host: const HostInfoOverride(available: false));
      env.publish([pluginRow('Alpha')]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      expect(env.manager.storeItem('Alpha')!.compatibility,
          Compatibility.unsupportedPlatform);
      await expectLater(
          env.manager.install('Alpha'),
          throwsA(isA<ExtensionException>().having((e) => e.error, 'error',
              ExtensionError.unsupportedPlatform)));
      expect(env.manager.installed, isEmpty);
      expect(env.pkgs.files, isEmpty);
    });
  });

  group('install', () {
    test('happy path: verified, saved, loaded, persisted', () async {
      final env = withPackage();
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      final progress = <InstallPhase>[];
      env.manager.addListener(() {
        final p = env.manager.progressOf('Alpha');
        if (p != null && (progress.isEmpty || progress.last != p.phase)) {
          progress.add(p.phase);
        }
      });
      final rec = await env.manager.install('Alpha');
      expect(rec.version, 1);
      expect(rec.enabled, isTrue);
      expect(rec.pluginClassName, 'com.example.ExamplePlugin');
      expect(rec.sha256, sha256Hex(env.pkgs.files[rec.path]!));
      expect(env.host.loaded, {'Alpha'});
      expect(rec.providers.single.apiName, 'Alpha');
      expect(progress, [
        InstallPhase.downloading,
        InstallPhase.verifying,
        InstallPhase.installing,
      ]);
      expect(env.manager.progressOf('Alpha'), isNull);
      expect(env.manager.isBusy('Alpha'), isFalse);
      expect(env.manager.storeItem('Alpha')!.isInstalled, isTrue);
    });

    test('hash mismatch: nothing saved, nothing installed', () async {
      final env = Env();
      final pkg = buildCs3();
      final tampered = buildCs3(pluginClassName: 'evil.Plugin');
      env.fetcher.bytes('https://repo.example/Alpha.cs3', tampered);
      env.publish([pluginRow('Alpha', package: pkg)]); // advertises pkg's hash
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await expectLater(
          env.manager.install('Alpha'),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.integrity)));
      expect(env.manager.installed, isEmpty);
      expect(env.pkgs.files, isEmpty);
      expect(env.host.loadCalls, isEmpty);
    });

    test('truncated download is an integrity failure', () async {
      final env = Env();
      final pkg = buildCs3();
      env.fetcher.bytes(
          'https://repo.example/Alpha.cs3', pkg.sublist(0, pkg.length - 5));
      env.publish([pluginRow('Alpha', package: pkg)]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await expectLater(
          env.manager.install('Alpha'),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.integrity)));
      expect(env.manager.installed, isEmpty);
    });

    test('a non-package body (no advertised hash) is invalidPackage',
        () async {
      final env = Env();
      env.fetcher.bytes('https://repo.example/Alpha.cs3',
          utf8.encode('<html>blocked</html>'));
      env.publish([pluginRow('Alpha')]); // no size/hash advertised
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await expectLater(
          env.manager.install('Alpha'),
          throwsA(isA<ExtensionException>().having(
              (e) => e.error, 'error', ExtensionError.invalidPackage)));
      expect(env.manager.installed, isEmpty);
    });

    test('host refuses the package: not reported installed, file removed',
        () async {
      final env = withPackage();
      env.host.failLoadPaths.add('/pkgs/Alpha-1.cs3');
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await expectLater(
          env.manager.install('Alpha'),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.initFailed)));
      expect(env.manager.installed, isEmpty);
      expect(env.pkgs.files, isEmpty);
      expect(env.manager.storeItem('Alpha')!.isInstalled, isFalse);
    });

    test('a plugin that never starts times out instead of hanging', () async {
      final env = withPackage();
      env.host.hangLoad.add('Alpha');
      final fast = ExtensionManager(
        fetcher: env.fetcher,
        store: env.kv,
        packages: env.pkgs,
        host: env.host,
        loadTimeout: const Duration(milliseconds: 50),
      );
      await fast.load();
      await fast.addRepo(repoUrl);
      await expectLater(
          fast.install('Alpha'),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.timeout)));
      expect(fast.installed, isEmpty);
      expect(env.pkgs.files, isEmpty);
    });

    test('download failure leaves no trace', () async {
      final env = Env();
      env.publish([pluginRow('Alpha')]);
      env.fetcher.fail('https://repo.example/Alpha.cs3',
          const FetchException(FetchFailure.network, 'reset'));
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await expectLater(env.manager.install('Alpha'),
          throwsA(isA<ExtensionException>()));
      expect(env.manager.installed, isEmpty);
      expect(env.manager.isBusy('Alpha'), isFalse);
    });

    test('API mismatch and non-.cs3 are refused with no download',
        () async {
      final env = Env();
      env.publish([
        pluginRow('NewApi', apiVersion: 99),
        pluginRow('Jar', url: 'https://repo.example/x.jar'),
      ]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await expectLater(
          env.manager.install('NewApi'),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.apiMismatch)));
      await expectLater(
          env.manager.install('Jar'),
          throwsA(isA<ExtensionException>().having(
              (e) => e.error, 'error', ExtensionError.unsupportedPackage)));
      expect(env.fetcher.calls.where((c) => c.endsWith('.cs3') || c.endsWith('.jar')),
          isEmpty);
    });

    test('installing something unknown is notFound', () async {
      final env = Env();
      await env.manager.load();
      await expectLater(
          env.manager.install('Ghost'),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.notFound)));
    });

    test('duplicate concurrent installs are blocked', () async {
      final env = withPackage();
      env.fetcher.latency = const Duration(milliseconds: 20);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      final first = env.manager.install('Alpha');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await expectLater(env.manager.install('Alpha'),
          throwsA(isA<ExtensionException>()));
      await first;
      expect(
          env.fetcher.calls.where((c) => c.endsWith('Alpha.cs3')), hasLength(1));
      expect(env.manager.installed, hasLength(1));
    });

    test('installed state survives restart; enabled ones reload',
        () async {
      final env = withPackage();
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await env.manager.install('Alpha');

      final newHost = FakeHost();
      final again = env.restart(newHost: newHost);
      await again.load();
      expect(again.installed.single.internalName, 'Alpha');
      expect(again.isLoadedInHost('Alpha'), isFalse); // lazy, not yet
      await again.restoreEnabledProviders();
      expect(newHost.loaded, {'Alpha'});
      expect(again.isProviderActive(LiveId.provider('Alpha', 'Alpha')),
          isTrue);
      expect(again.installed.single.lastInitAt, 1700000001000);
    });
  });

  group('enable / disable', () {
    Future<Env> installedEnv() async {
      final env = withPackage();
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await env.manager.install('Alpha');
      return env;
    }

    test('disable releases the host but keeps it installed', () async {
      final env = await installedEnv();
      await env.manager.setEnabled('Alpha', false);
      expect(env.host.loaded, isEmpty);
      expect(env.host.unloadCalls, ['Alpha']);
      final rec = env.manager.installedRecord('Alpha')!;
      expect(rec.enabled, isFalse);
      expect(env.pkgs.files, hasLength(1)); // still on disk
      expect(env.manager.isProviderActive(LiveId.provider('Alpha', 'Alpha')),
          isFalse);
      expect(env.manager.activeProviders(), isEmpty);
    });

    test('enable loads it again', () async {
      final env = await installedEnv();
      await env.manager.setEnabled('Alpha', false);
      await env.manager.setEnabled('Alpha', true);
      expect(env.host.loaded, {'Alpha'});
      expect(env.manager.activeProviders(), hasLength(1));
    });

    test('states are independent per extension and persist', () async {
      final env = Env();
      final a = buildCs3(), b = buildCs3(), c = buildCs3();
      env.fetcher.bytes('https://repo.example/A.cs3', a);
      env.fetcher.bytes('https://repo.example/B.cs3', b);
      env.fetcher.bytes('https://repo.example/C.cs3', c);
      env.publish([
        pluginRow('A', package: a),
        pluginRow('B', package: b),
        pluginRow('C', package: c),
      ]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      for (final n in ['A', 'B', 'C']) {
        await env.manager.install(n);
      }
      await env.manager.setEnabled('B', false);

      final newHost = FakeHost();
      final again = env.restart(newHost: newHost);
      await again.load();
      await again.restoreEnabledProviders();
      expect(again.installedRecord('A')!.enabled, isTrue);
      expect(again.installedRecord('B')!.enabled, isFalse);
      expect(again.installedRecord('C')!.enabled, isTrue);
      expect(newHost.loaded, {'A', 'C'}); // B never loaded
    });

    test('enabling a broken package fails loudly and stays disabled',
        () async {
      final env = await installedEnv();
      await env.manager.setEnabled('Alpha', false);
      env.host.failLoadPaths.add(env.manager.installedRecord('Alpha')!.path);
      await expectLater(
          env.manager.setEnabled('Alpha', true),
          throwsA(isA<ExtensionException>()
              .having((e) => e.error, 'error', ExtensionError.initFailed)));
      final rec = env.manager.installedRecord('Alpha')!;
      expect(rec.enabled, isFalse);
      expect(rec.lastError, isNotNull);
    });

    test('a failing package at startup is isolated', () async {
      final env = Env();
      final a = buildCs3(), b = buildCs3();
      env.fetcher.bytes('https://repo.example/A.cs3', a);
      env.fetcher.bytes('https://repo.example/B.cs3', b);
      env.publish([pluginRow('A', package: a), pluginRow('B', package: b)]);
      await env.manager.load();
      await env.manager.addRepo(repoUrl);
      await env.manager.install('A');
      await env.manager.install('B');

      final newHost = FakeHost()
        ..failLoadPaths.add(env.manager.installedRecord('A')!.path);
      final again = env.restart(newHost: newHost);
      await again.load();
      await again.restoreEnabledProviders();
      expect(newHost.loaded, {'B'});
      expect(again.installedRecord('A')!.lastError, isNotNull);
      expect(again.installedRecord('A')!.enabled, isTrue); // user's choice kept
      expect(
          again.activeProviders().map((p) => p.record.internalName).toList(),
          ['B']);
    });

    test('missing package file at startup is reported, not fatal', () async {
      final env = await installedEnv();
      env.pkgs.files.clear();
      final again = env.restart(newHost: FakeHost());
      await again.load();
      await again.restoreEnabledProviders();
      expect(again.installedRecord('Alpha')!.lastError, contains('missing'));
      expect(again.activeProviders(), isEmpty);
    });

    test('uninstall removes record, file and host registration', () async {
      final env = await installedEnv();
      await env.manager.uninstall('Alpha');
      expect(env.manager.installed, isEmpty);
      expect(env.pkgs.files, isEmpty);
      expect(env.host.loaded, isEmpty);
      final again = env.restart();
      await again.load();
      expect(again.installed, isEmpty);
    });
  });

  group('updates', () {
    test('update available is detected', () async {
      final env = withPackage(version: 1);
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      await env.manager.install('Alpha');
      expect(env.manager.updatesAvailable(), isEmpty);

      final v2 = buildCs3(version: 2, pluginClassName: 'com.example.V2');
      env.fetcher.bytes('https://repo.example/Alpha.cs3', v2);
      env.fetcher.json(listA, [pluginRow('Alpha', version: 2, package: v2)]);
      await env.manager.refreshRepo(repo.id);
      expect(env.manager.updatesAvailable().single.internalName, 'Alpha');
      expect(env.manager.storeItem('Alpha')!.hasUpdate, isTrue);
    });

    test('update keeps disabled state, replaces the file, one registration',
        () async {
      final env = withPackage(version: 1);
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      await env.manager.install('Alpha');
      await env.manager.setEnabled('Alpha', false);

      final v2 = buildCs3(version: 2, pluginClassName: 'com.example.V2');
      env.fetcher.bytes('https://repo.example/Alpha.cs3', v2);
      env.fetcher.json(listA, [pluginRow('Alpha', version: 2, package: v2)]);
      await env.manager.refreshRepo(repo.id);

      final rec = await env.manager.install('Alpha');
      expect(rec.version, 2);
      expect(rec.enabled, isFalse); // preference preserved
      expect(rec.pluginClassName, 'com.example.V2');
      expect(env.manager.installed, hasLength(1));
      await Future<void>.delayed(Duration.zero);
      expect(env.pkgs.files.keys.toList(), ['/pkgs/Alpha-2.cs3']);
      expect(env.host.loaded, isEmpty); // disabled → released
    });

    test('failed update keeps the working old version', () async {
      final env = withPackage(version: 1);
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      await env.manager.install('Alpha');

      final v2 = buildCs3(version: 2);
      env.fetcher.bytes('https://repo.example/Alpha.cs3', v2);
      env.fetcher.json(listA, [pluginRow('Alpha', version: 2, package: v2)]);
      await env.manager.refreshRepo(repo.id);
      env.host.failLoadPaths.add('/pkgs/Alpha-2.cs3');

      await expectLater(env.manager.install('Alpha'),
          throwsA(isA<ExtensionException>()));
      await Future<void>.delayed(Duration.zero);
      expect(env.manager.installedRecord('Alpha')!.version, 1);
      expect(env.pkgs.files.keys.toList(), ['/pkgs/Alpha-1.cs3']);
      // old version restored in the host
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(env.host.loaded, {'Alpha'});
    });

    test('updateAll reports updated / failed counts', () async {
      final env = Env();
      final a1 = buildCs3(version: 1), b1 = buildCs3(version: 1);
      env.fetcher.bytes('https://repo.example/A.cs3', a1);
      env.fetcher.bytes('https://repo.example/B.cs3', b1);
      env.publish([
        pluginRow('A', package: a1),
        pluginRow('B', package: b1),
      ]);
      await env.manager.load();
      final repo = await env.manager.addRepo(repoUrl);
      await env.manager.install('A');
      await env.manager.install('B');

      final a2 = buildCs3(version: 2);
      env.fetcher.bytes('https://repo.example/A.cs3', a2);
      // B v2 download is corrupt (HTML) with a hash that cannot match.
      final b2 = buildCs3(version: 2, pluginClassName: 'x.B2');
      env.fetcher.bytes('https://repo.example/B.cs3', utf8.encode('<html>'));
      env.fetcher.json(listA, [
        pluginRow('A', version: 2, package: a2),
        pluginRow('B', version: 2, package: b2),
      ]);
      await env.manager.refreshRepo(repo.id);
      final result = await env.manager.updateAll();
      expect(result.updated, 1);
      expect(result.failed, 1);
      expect(env.manager.installedRecord('A')!.version, 2);
      expect(env.manager.installedRecord('B')!.version, 1);
    });
  });
}
