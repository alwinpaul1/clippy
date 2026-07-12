/// Compares two `major.minor.patch` version strings numerically (ignoring any
/// `+build` suffix). Returns -1 if [a] < [b], 0 if equal, 1 if [a] > [b].
int compareSemver(String a, String b) {
  List<int> parts(String s) =>
      s.split('+').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// A published release as described by the relay's /version.json manifest.
/// The changelog is split into three optional lists; the UI shows only the
/// non-empty ones, so a bug release (empty [features]) surfaces just
/// "New Improvements" and "Bug Fixes".
class UpdateInfo {
  final String version;
  final int build;
  final List<String> features;
  final List<String> improvements;
  final List<String> fixes;
  final String? androidUrl;
  final String? macosUrl;
  final String? windowsUrl;
  // Expected SHA-256 (hex) of each artifact, from the CI-generated manifest.
  // The updater refuses to install without a match — see downloadTo.
  final String? androidSha256;
  final String? macosSha256;
  final String? windowsSha256;

  const UpdateInfo({
    required this.version,
    required this.build,
    this.features = const [],
    this.improvements = const [],
    this.fixes = const [],
    this.androidUrl,
    this.macosUrl,
    this.windowsUrl,
    this.androidSha256,
    this.macosSha256,
    this.windowsSha256,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> j) {
    final notes = (j['notes'] as Map?)?.cast<String, dynamic>() ?? const {};
    List<String> list(String k) =>
        ((notes[k] as List?) ?? const []).map((e) => e.toString()).toList();
    final sha = (j['sha256'] as Map?)?.cast<String, dynamic>() ?? const {};
    return UpdateInfo(
      version: j['version'] as String,
      build: (j['build'] as num?)?.toInt() ?? 0,
      features: list('features'),
      improvements: list('improvements'),
      fixes: list('fixes'),
      androidUrl: j['android'] as String?,
      macosUrl: j['macos'] as String?,
      windowsUrl: j['windows'] as String?,
      androidSha256: sha['android'] as String?,
      macosSha256: sha['macos'] as String?,
      windowsSha256: sha['windows'] as String?,
    );
  }

  /// True if this manifest is strictly newer than the running app: a higher
  /// semantic version, or the same version with a higher build number.
  bool isNewerThan(String currentVersion, int currentBuild) {
    final c = compareSemver(version, currentVersion);
    if (c != 0) return c > 0;
    return build > currentBuild;
  }

  /// A "bug update" has no new features — the changelog shows only
  /// improvements and fixes.
  bool get isBugUpdate => features.isEmpty;
}
