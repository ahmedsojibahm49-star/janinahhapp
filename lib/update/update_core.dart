// Pure-Dart logic for the in-app updater (no Flutter, no I/O): version
// parsing/comparison and "what is the newest GitHub release". Every
// network edge is injected so this runs on a bare Dart VM in tests.

/// Where releases are published (GitHub Actions attaches the APK on tags).
const String kRepoOwner = 'ahmedsojibahm49-star';
const String kRepoName = 'streambox-app';

/// `1.0.5`, `v1.0.5`, `1.0.5+5`. Compared by major.minor.patch only —
/// the build number after `+` is informational.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.build]);

  final int major;
  final int minor;
  final int patch;
  final int? build;

  static AppVersion? tryParse(String input) {
    final m = RegExp(r'^\s*v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?')
        .firstMatch(input);
    if (m == null) return null;
    return AppVersion(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      m.group(4) == null ? null : int.parse(m.group(4)!),
    );
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(AppVersion o) => compareTo(o) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// A release newer than the installed app.
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.apkUrl,
    required this.checksumUrl,
  });

  final String tag;
  final AppVersion version;
  final Uri apkUrl;

  /// `<apk>.sha256` published next to the APK by the workflow. May 404 for
  /// releases made before checksums existed — callers must tolerate that.
  final Uri checksumUrl;
}

/// `https://github.com/<o>/<r>/releases/latest` — GitHub answers this with
/// a redirect to `.../releases/tag/<tag>`. Using the redirect (instead of
/// api.github.com) means no API rate limit and no token.
Uri latestReleaseUri({String owner = kRepoOwner, String repo = kRepoName}) =>
    Uri.https('github.com', '/$owner/$repo/releases/latest');

/// The tag in a `.../releases/tag/<tag>` URL, or null.
String? tagFromLocation(String location) {
  final m = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(location);
  if (m == null) return null;
  return Uri.decodeComponent(m.group(1)!);
}

/// Naming contract with `.github/workflows/build-apk.yml`.
Uri apkUrlFor(String tag,
        {String owner = kRepoOwner, String repo = kRepoName}) =>
    Uri.https('github.com',
        '/$owner/$repo/releases/download/$tag/streambox-$tag.apk');

Uri checksumUrlFor(String tag,
        {String owner = kRepoOwner, String repo = kRepoName}) =>
    Uri.https('github.com',
        '/$owner/$repo/releases/download/$tag/streambox-$tag.apk.sha256');

/// Parse the first 64-hex token of a `.sha256` file (`<hash>  <name>` or
/// bare hash). Null if absent/malformed.
String? parseChecksum(String body) {
  final m = RegExp(r'\b([0-9a-fA-F]{64})\b').firstMatch(body);
  return m?.group(1)!.toLowerCase();
}

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Returns the newer release, or null when [current] is up to date.
///
/// [resolveRedirect] must GET/HEAD the URL WITHOUT following redirects and
/// return the `Location` header (null when there is none). Throws
/// [UpdateCheckException] for unreadable answers.
Future<UpdateInfo?> checkForUpdate({
  required AppVersion current,
  required Future<String?> Function(Uri url) resolveRedirect,
  String owner = kRepoOwner,
  String repo = kRepoName,
}) async {
  final location =
      await resolveRedirect(latestReleaseUri(owner: owner, repo: repo));
  if (location == null) {
    throw const UpdateCheckException('No release has been published yet.');
  }
  final tag = tagFromLocation(location);
  final latest = tag == null ? null : AppVersion.tryParse(tag);
  if (tag == null || latest == null) {
    throw const UpdateCheckException(
        'The latest release has an unreadable version tag.');
  }
  if (!(latest > current)) return null;
  return UpdateInfo(
    tag: tag,
    version: latest,
    apkUrl: apkUrlFor(tag, owner: owner, repo: repo),
    checksumUrl: checksumUrlFor(tag, owner: owner, repo: repo),
  );
}

/// True when an Android installer failure means "the new APK is signed
/// with a different key than the installed app" (the classic reason a
/// user has to uninstall first).
bool isSignatureMismatch(String? message) {
  if (message == null) return false;
  final m = message.toUpperCase();
  return m.contains('INCOMPATIBLE') ||
      m.contains('SIGNATURES DO NOT MATCH') ||
      m.contains('UPDATE_INCOMPATIBLE') ||
      m.contains('SIGNATURE');
}
