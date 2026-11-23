import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/update/update_core.dart';

void main() {
  group('AppVersion', () {
    test('parses plain, v-prefixed and build-suffixed versions', () {
      expect(AppVersion.tryParse('1.0.5').toString(), '1.0.5');
      expect(AppVersion.tryParse('v1.0.5').toString(), '1.0.5');
      expect(AppVersion.tryParse('1.0.5+5')!.build, 5);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse('1.0'), isNull);
    });

    test('numeric (not lexical) ordering', () {
      expect(AppVersion.tryParse('1.0.10')! > AppVersion.tryParse('1.0.9')!,
          isTrue);
      expect(AppVersion.tryParse('1.2.0')! > AppVersion.tryParse('1.1.99')!,
          isTrue);
      expect(AppVersion.tryParse('2.0.0')! > AppVersion.tryParse('1.99.99')!,
          isTrue);
      expect(AppVersion.tryParse('1.0.5+5') == AppVersion.tryParse('v1.0.5'),
          isTrue);
      expect(AppVersion.tryParse('1.0.4')! > AppVersion.tryParse('1.0.5')!,
          isFalse);
    });
  });

  group('release URLs', () {
    test('tag is read from the redirect Location', () {
      expect(
          tagFromLocation(
              'https://github.com/a/b/releases/tag/v1.0.6?x=1'),
          'v1.0.6');
      expect(tagFromLocation('https://github.com/a/b/releases'), isNull);
    });

    test('asset names follow the workflow contract', () {
      expect(apkUrlFor('v1.0.6').toString(),
          'https://github.com/$kRepoOwner/$kRepoName/releases/download/v1.0.6/streambox-v1.0.6.apk');
      expect(checksumUrlFor('v1.0.6').path.endsWith('.apk.sha256'), isTrue);
    });

    test('checksum parsing', () {
      final h = 'ab' * 32;
      expect(parseChecksum('$h  streambox-v1.0.6.apk\n'), h);
      expect(parseChecksum(h.toUpperCase()), h);
      expect(parseChecksum('<html>404</html>'), isNull);
    });
  });

  group('checkForUpdate', () {
    Future<String?> redirectTo(String tag) async =>
        'https://github.com/$kRepoOwner/$kRepoName/releases/tag/$tag';

    test('newer release is reported with its APK url', () async {
      final info = await checkForUpdate(
        current: AppVersion.tryParse('1.0.5')!,
        resolveRedirect: (_) => redirectTo('v1.0.6'),
      );
      expect(info, isNotNull);
      expect(info!.tag, 'v1.0.6');
      expect(info.apkUrl.path.endsWith('streambox-v1.0.6.apk'), isTrue);
    });

    test('same or older release means up to date', () async {
      for (final tag in ['v1.0.5', 'v1.0.4']) {
        final info = await checkForUpdate(
          current: AppVersion.tryParse('1.0.5')!,
          resolveRedirect: (_) => redirectTo(tag),
        );
        expect(info, isNull);
      }
    });

    test('no redirect or unreadable tag is a clear error', () async {
      await expectLater(
          checkForUpdate(
              current: AppVersion.tryParse('1.0.5')!,
              resolveRedirect: (_) async => null),
          throwsA(isA<UpdateCheckException>()));
      await expectLater(
          checkForUpdate(
              current: AppVersion.tryParse('1.0.5')!,
              resolveRedirect: (_) => redirectTo('nightly')),
          throwsA(isA<UpdateCheckException>()));
    });

    test('uses the releases/latest redirect, not the API', () async {
      Uri? asked;
      await checkForUpdate(
        current: AppVersion.tryParse('9.9.9')!,
        resolveRedirect: (u) {
          asked = u;
          return redirectTo('v1.0.6');
        },
      );
      expect(asked!.host, 'github.com');
      expect(asked!.path.endsWith('/releases/latest'), isTrue);
    });
  });

  test('signature-mismatch detection from installer messages', () {
    expect(
        isSignatureMismatch(
            'INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match'),
        isTrue);
    expect(isSignatureMismatch('Storage is full'), isFalse);
    expect(isSignatureMismatch(null), isFalse);
  });
}
