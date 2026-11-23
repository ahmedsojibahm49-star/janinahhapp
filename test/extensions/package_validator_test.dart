import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/extensions/core/models.dart';
import 'package:streambox/extensions/core/package_validator.dart';
import 'package:streambox/extensions/core/sha256.dart';

import 'fakes.dart';

PluginEntry entryFor(Uint8List pkg, {String? hash, int? size}) => PluginEntry(
      internalName: 'X',
      name: 'X',
      url: 'https://x/X.cs3',
      version: 1,
      fileSize: size ?? pkg.length,
      fileHash: hash ?? sha256Hex(pkg),
    );

void main() {
  test('valid deflated package passes and reports the plugin class', () {
    final pkg = buildCs3(pluginClassName: 'a.b.CPlugin');
    final info = verifyPackage(pkg, entryFor(pkg));
    expect(info.pluginClassName, 'a.b.CPlugin');
    expect(info.dexCount, 1);
    expect(info.name, 'Example');
  });

  test('valid stored (uncompressed) package passes', () {
    final pkg = buildCs3(deflate: false);
    expect(verifyPackage(pkg, entryFor(pkg)).pluginClassName,
        'com.example.ExamplePlugin');
  });

  test('multi-dex package counts every classes*.dex', () {
    final pkg = buildCs3(extra: {'classes2.dex': utf8.encode('more')});
    expect(inspectCs3(pkg).dexCount, 2);
  });

  test('hash mismatch is an integrity failure', () {
    final pkg = buildCs3();
    expect(
        () => verifyPackage(pkg, entryFor(pkg, hash: 'b' * 64)),
        throwsA(isA<PackageException>()
            .having((e) => e.problem, 'problem', PackageProblem.hashMismatch)));
  });

  test('no advertised hash: still validates format, skips hash', () {
    final pkg = buildCs3();
    const e = PluginEntry(
        internalName: 'X', name: 'X', url: 'https://x/X.cs3', version: 1);
    expect(verifyPackage(pkg, e).dexCount, 1);
  });

  test('size mismatch means an incomplete download', () {
    final pkg = buildCs3();
    expect(
        () => verifyPackage(pkg, entryFor(pkg, size: pkg.length + 10)),
        throwsA(isA<PackageException>()
            .having((e) => e.problem, 'problem', PackageProblem.sizeMismatch)));
  });

  test('truncated download is rejected', () {
    final pkg = buildCs3();
    final cut = Uint8List.sublistView(pkg, 0, pkg.length - 30);
    expect(
        () => verifyPackage(cut, entryFor(pkg)),
        throwsA(isA<PackageException>()));
  });

  test('empty body is rejected', () {
    expect(
        () => verifyPackage(
            Uint8List(0),
            const PluginEntry(
                internalName: 'X',
                name: 'X',
                url: 'https://x/X.cs3',
                version: 1)),
        throwsA(isA<PackageException>()
            .having((e) => e.problem, 'problem', PackageProblem.empty)));
  });

  test('an HTML error page saved as .cs3 is "not a zip"', () {
    final html = Uint8List.fromList(utf8.encode('<html>404 not found</html>' * 3));
    expect(
        () => inspectCs3(html),
        throwsA(isA<PackageException>()
            .having((e) => e.problem, 'problem', PackageProblem.notAZip)));
  });

  test('zip without classes.dex is not a CloudStream package', () {
    final zip = buildZip({'manifest.json': utf8.encode('{"pluginClassName":"a"}')});
    expect(
        () => inspectCs3(zip),
        throwsA(isA<PackageException>()
            .having((e) => e.problem, 'problem', PackageProblem.noDex)));
  });

  test('zip without manifest.json is rejected', () {
    final zip = buildZip({'classes.dex': [1, 2, 3]});
    expect(
        () => inspectCs3(zip),
        throwsA(isA<PackageException>()
            .having((e) => e.problem, 'problem', PackageProblem.noManifest)));
  });

  test('manifest without pluginClassName or invalid JSON is rejected', () {
    final noClass = buildZip({
      'classes.dex': [1],
      'manifest.json': utf8.encode('{"name":"x"}'),
    });
    final badJson = buildZip({
      'classes.dex': [1],
      'manifest.json': utf8.encode('{not json'),
    });
    for (final z in [noClass, badJson]) {
      expect(
          () => inspectCs3(z),
          throwsA(isA<PackageException>()
              .having((e) => e.problem, 'problem', PackageProblem.badManifest)));
    }
  });

  test('path traversal entry names are rejected', () {
    final zip = buildZip({
      'classes.dex': [1],
      'manifest.json': utf8.encode('{"pluginClassName":"a"}'),
      '../evil': [1],
    });
    expect(() => inspectCs3(zip), throwsA(isA<PackageException>()));
  });
}
