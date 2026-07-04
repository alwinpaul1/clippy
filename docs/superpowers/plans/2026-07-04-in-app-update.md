# In-App Update Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Existing Clippy installs detect a newer release, show a changelog, and update in place — Android (APK install-intent), macOS (swap `.app` + relaunch), Windows (silent Inno Setup) — with a dismissible launch banner and a Settings check.

**Architecture:** `release.json` (repo) → CI → `/version.json` (relay). Shared-Dart `UpdateService` polls it and compares to the app version. UI banner/sheet renders the changelog and calls a per-platform `PlatformUpdater`.

**Tech Stack:** Dart/Flutter, `package_info_plus`, `http`, Kotlin (Android install intent), shell (macOS), Inno Setup (Windows), Dart relay.

## Global Constraints

- App version source of truth: `pubspec.yaml` `version:` (e.g. `1.1.0+5`).
- Changelog sections rendered only if non-empty; `features` empty ⇒ bug-update view (Improvements + Fixes only).
- Update always dismissible (no forced updates in v1).
- Relay host for the manifest = same `relayUrl` host the app already uses (`lib/app/relay_config.dart`), over https.
- Network/parse failures on the auto path are silent; the Settings path reports them.
- Match existing code style (small focused files under `lib/core` and `lib/platform`).

---

### Task 1: `UpdateInfo` model + semver compare (pure, unit-tested)

**Files:**
- Create: `lib/core/update/update_info.dart`
- Test: `test/core/update/update_info_test.dart`

**Produces:**
- `class UpdateInfo { final String version; final int build; final List<String> features, improvements, fixes; final String? androidUrl, macosUrl, windowsUrl; }`
- `factory UpdateInfo.fromJson(Map<String,dynamic>)`
- `bool isNewerThan(String currentVersion, int currentBuild)` — semver compare of `version`, build tie-break.
- `bool get isBugUpdate => features.isEmpty;`
- top-level `int compareSemver(String a, String b)` (-1/0/1).

- [ ] **Step 1: Failing tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clippy/core/update/update_info.dart';

void main() {
  test('compareSemver orders numerically not lexically', () {
    expect(compareSemver('1.2.0', '1.10.0'), -1);
    expect(compareSemver('1.0.1', '1.0.0'), 1);
    expect(compareSemver('1.0.0', '1.0.0'), 0);
  });
  test('isNewerThan uses version then build', () {
    final u = UpdateInfo.fromJson({'version': '1.1.0', 'build': 5, 'notes': {}});
    expect(u.isNewerThan('1.0.0', 1), true);
    expect(u.isNewerThan('1.1.0', 4), true);   // same version, higher build
    expect(u.isNewerThan('1.1.0', 5), false);  // equal
    expect(u.isNewerThan('1.2.0', 1), false);  // older manifest
  });
  test('isBugUpdate when features empty', () {
    final bug = UpdateInfo.fromJson({'version': '1.0.1', 'build': 2, 'notes': {'fixes': ['x']}});
    expect(bug.isBugUpdate, true);
    final feat = UpdateInfo.fromJson({'version': '1.1.0', 'build': 3, 'notes': {'features': ['y']}});
    expect(feat.isBugUpdate, false);
  });
  test('fromJson tolerates missing notes/urls', () {
    final u = UpdateInfo.fromJson({'version': '1.0.0', 'build': 1});
    expect(u.features, isEmpty);
    expect(u.androidUrl, isNull);
  });
}
```

- [ ] **Step 2:** `flutter test test/core/update/update_info_test.dart` → FAIL (no file).
- [ ] **Step 3: Implement `update_info.dart`.**

```dart
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

class UpdateInfo {
  final String version;
  final int build;
  final List<String> features, improvements, fixes;
  final String? androidUrl, macosUrl, windowsUrl;
  const UpdateInfo({
    required this.version, required this.build,
    this.features = const [], this.improvements = const [], this.fixes = const [],
    this.androidUrl, this.macosUrl, this.windowsUrl,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> j) {
    final notes = (j['notes'] as Map?)?.cast<String, dynamic>() ?? const {};
    List<String> list(String k) =>
        ((notes[k] as List?) ?? const []).map((e) => e.toString()).toList();
    return UpdateInfo(
      version: j['version'] as String,
      build: (j['build'] as num?)?.toInt() ?? 0,
      features: list('features'),
      improvements: list('improvements'),
      fixes: list('fixes'),
      androidUrl: j['android'] as String?,
      macosUrl: j['macos'] as String?,
      windowsUrl: j['windows'] as String?,
    );
  }

  bool isNewerThan(String currentVersion, int currentBuild) {
    final c = compareSemver(version, currentVersion);
    if (c != 0) return c > 0;
    return build > currentBuild;
  }

  bool get isBugUpdate => features.isEmpty;
}
```

- [ ] **Step 4:** `flutter test test/core/update/update_info_test.dart` → PASS.
- [ ] **Step 5:** Commit `feat(update): UpdateInfo model + semver compare`.

---

### Task 2: `UpdateService` — fetch, compare, dismissal

**Files:**
- Create: `lib/core/update/update_service.dart`
- Test: `test/core/update/update_service_test.dart`
- Modify: `pubspec.yaml` (add `package_info_plus`, `http`)

**Consumes:** `UpdateInfo` (Task 1).
**Produces:**
- `class UpdateService { UpdateService({required Uri manifestUri, required Future<({String version, int build})> Function() currentVersion, http.Client? client}); Future<UpdateInfo?> check(); Future<void> dismiss(String version); Future<bool> isDismissed(String version); }`
- `check()` returns the `UpdateInfo` if strictly newer, else null; swallows errors (returns null).
- `String? artifactUrlFor(UpdateInfo, TargetPlatform)` helper (relative → absolute against manifest host).

- [ ] **Step 1: Failing test** (inject a fake `http.Client` via `package:http/testing.dart` `MockClient`).

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:clippy/core/update/update_service.dart';

UpdateService svc(String body, {int code = 200}) => UpdateService(
      manifestUri: Uri.parse('https://relay.test/version.json'),
      currentVersion: () async => (version: '1.0.0', build: 1),
      client: MockClient((_) async => http.Response(body, code)),
    );

void main() {
  test('returns UpdateInfo when newer', () async {
    final u = await svc(jsonEncode({'version': '1.1.0', 'build': 2, 'notes': {'fixes': ['a']}})).check();
    expect(u, isNotNull);
    expect(u!.version, '1.1.0');
  });
  test('null when same or older', () async {
    expect(await svc(jsonEncode({'version': '1.0.0', 'build': 1})).check(), isNull);
    expect(await svc(jsonEncode({'version': '0.9.0', 'build': 1})).check(), isNull);
  });
  test('null on http error / bad json (silent)', () async {
    expect(await svc('nope', code: 500).check(), isNull);
    expect(await svc('not-json').check(), isNull);
  });
}
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** `flutter pub add package_info_plus http`. Implement `update_service.dart` (fetch, decode, `UpdateInfo.fromJson`, `isNewerThan`; wrap in try/catch → null; dismissal via `shared_preferences` keyed `clippy.update.dismissed`).
- [ ] **Step 4:** Run → PASS. Also `flutter analyze`.
- [ ] **Step 5:** Commit `feat(update): UpdateService fetch+compare+dismiss`.

---

### Task 3: Relay `/version.json` route + `release.json` + CI generation

**Files:**
- Modify: `server/lib/relay.dart` (add route near the `/download/` handler)
- Create: `release.json` (repo root)
- Modify: `.github/workflows/ci.yml` (deploy job: generate `version.json`, add macOS `.app` zip)
- Test: `server/test/relay_test.dart` (add a case if the suite hits routes; else manual curl)

**Produces:** `GET /version.json` → `web/downloads/version.json` with `application/json`.

- [ ] **Step 1:** Add to `relay.dart` request handler (mirror the `/download/` block):

```dart
if (req.uri.path == '/version.json') {
  for (final dir in ['web/downloads', '/app/web/downloads',
      '${File(Platform.resolvedExecutable).parent.parent.path}/web/downloads']) {
    final f = File('$dir/version.json');
    if (f.existsSync()) {
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'json')
        ..add(await f.readAsBytes());
      await req.response.close();
      return;
    }
  }
  req.response.statusCode = HttpStatus.notFound;
  await req.response.close();
  return;
}
```

- [ ] **Step 2:** Create `release.json`:

```json
{
  "notes": {
    "features": [],
    "improvements": ["In-app updates: Clippy now updates itself when a new version is out."],
    "fixes": []
  }
}
```

- [ ] **Step 3:** In `ci.yml` deploy job, before `railway up`, generate the manifest merging `pubspec` version + `release.json` notes + fixed URLs, and zip the macOS `.app`:

```bash
# version + build from pubspec (e.g. "1.1.0+5")
VER=$(grep -E '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//')
SEMVER=${VER%%+*}; BUILD=${VER##*+}
python3 - "$SEMVER" "$BUILD" <<'PY'
import json, sys
notes = json.load(open('release.json'))['notes']
open('server/web/downloads/version.json','w').write(json.dumps({
  'version': sys.argv[1], 'build': int(sys.argv[2]), 'notes': notes,
  'android': '/download/Clippy-Android.apk',
  'macos':   '/download/Clippy-macOS.zip',
  'windows': '/download/Clippy-Setup.exe',
}))
PY
# macOS .app zip for self-update (the mac build job already produced the .app in _dl)
( cd _dl && ditto -c -k --keepParent Clippy.app ../server/web/downloads/Clippy-macOS.zip ) || true
```

(Adjust the `_dl/Clippy.app` path to wherever the macOS artifact lands; the mac build must upload the raw `.app`, not only the DMG — add an `upload-artifact` of `build/macos/Build/Products/Release/clippy.app` and download it in deploy.)

- [ ] **Step 4:** Verify locally: `cd server && dart run bin/relay.dart &` then `curl -s localhost:8080/version.json` (after placing a test file). Expect the JSON.
- [ ] **Step 5:** Commit `feat(update): /version.json route + release.json + CI manifest`.

---

### Task 4: Android APK install (native channel + manifest)

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml` (add `REQUEST_INSTALL_PACKAGES`; a `FileProvider`)
- Create: `android/app/src/main/res/xml/file_paths.xml`
- Modify: `android/.../MainActivity.kt` (channel method `installApk(path)`)
- Create: `lib/platform/updater/android_updater.dart`

**Produces:** `AndroidUpdater.download(url, onProgress) → File`; `.install(File)` → fires the system installer.

- [ ] **Step 1:** Manifest — add `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>` and inside `<application>`:

```xml
<provider
  android:name="androidx.core.content.FileProvider"
  android:authorities="${applicationId}.fileprovider"
  android:exported="false" android:grantUriPermissions="true">
  <meta-data android:name="android.support.FILE_PROVIDER_PATHS"
    android:resource="@xml/file_paths"/>
</provider>
```

`file_paths.xml`:
```xml
<paths><files-path name="updates" path="updates/"/><cache-path name="cache" path="."/></paths>
```

- [ ] **Step 2:** `MainActivity.kt` channel (`clippy/update`):

```kotlin
"installApk" -> {
    val path = call.argument<String>("path")!!
    val file = java.io.File(path)
    val uri = androidx.core.content.FileProvider.getUriForFile(
        this, "$packageName.fileprovider", file)
    val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, "application/vnd.android.package-archive")
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    startActivity(intent)
    result.success(null)
}
```

- [ ] **Step 3:** `android_updater.dart` — `http` streamed GET to `getApplicationCacheDirectory()/updates/clippy-<ver>.apk`, report progress, then `MethodChannel('clippy/update').invokeMethod('installApk', {'path': file.path})`.
- [ ] **Step 4:** `flutter analyze`. On-device: trigger with a test manifest, confirm the installer opens and updates in place.
- [ ] **Step 5:** Commit `feat(update): Android in-app APK install`.

---

### Task 5: macOS swap-and-relaunch + Windows silent installer

**Files:**
- Create: `lib/platform/updater/desktop_updater.dart`
- Modify: `windows/installer.iss` (stable `AppId`, `CloseApplications=yes`, `RestartApplications=yes`)

**Produces:** `DesktopUpdater` implementing download + apply for macOS (`.zip`) and Windows (`.exe`).

- [ ] **Step 1: macOS** — download `.zip` to temp, `unzip`, then spawn a detached helper and quit:

```dart
final appPath = '/Applications/Clippy.app'; // resolvedExecutable → .app root in practice
final script = '''#!/bin/bash
while kill -0 $pid 2>/dev/null; do sleep 0.3; done
rm -rf "$appPath"
ditto "$newApp" "$appPath"
open "$appPath"
''';
// write to temp .sh, chmod +x, Process.start('/bin/bash', [sh], mode: detached), then exit(0)
```
(Resolve `appPath` from `Platform.resolvedExecutable` → strip `/Contents/MacOS/clippy`. `$pid` = `pid` from `dart:io`.)

- [ ] **Step 2: Windows** — download `Clippy-Setup.exe` to temp, `Process.start(setup, ['/SILENT','/CLOSEAPPLICATIONS','/RESTARTAPPLICATIONS'], mode: detached)`, then exit. Ensure `installer.iss` has a fixed `AppId={{...GUID...}}` and `[Setup] CloseApplications=yes` / `RestartApplications=yes`.
- [ ] **Step 3:** `flutter analyze`. Manual macOS proof on this Mac (test manifest → Update → app relaunches on new version).
- [ ] **Step 4:** Commit `feat(update): macOS swap + Windows silent installer`.

---

### Task 6: `PlatformUpdater` facade

**Files:**
- Create: `lib/platform/updater/platform_updater.dart`

**Produces:** `abstract class PlatformUpdater { Future<void> update(UpdateInfo, {void Function(double) onProgress}); }` + `PlatformUpdater.forCurrent()` returning the Android/macOS/Windows impl, falling back to opening the download page (`url_launcher`, or the existing share channel) on unsupported/failed.

- [ ] Wire Tasks 4/5 behind this; pick artifact URL via `artifactUrlFor`. Commit `feat(update): platform updater facade`.

---

### Task 7: UI — update sheet + home banner + Settings row

**Files:**
- Create: `lib/app/update_sheet.dart`
- Modify: `lib/app/home_page.dart` (banner when `UpdateInfo` available & not dismissed)
- Modify: `lib/app/settings_page.dart` ("Check for updates" row)
- Modify: `lib/app/clip_controller.dart` or app root (kick off `UpdateService.check()` on start, hold result in a `ValueNotifier<UpdateInfo?>`)

**Behavior:**
- Banner (reuse the `_ShotAccessBanner` visual pattern in `home_page.dart`): "Update available — vX.Y" with Update + dismiss.
- Sheet: title `New in X.Y` (feature update) or `Bug fixes & improvements` (bug update); sections **New Features / New Improvements / Bug Fixes** rendered only when non-empty; one **Update** button showing a progress bar during `PlatformUpdater.update`.
- Settings row: runs `check()`; shows the sheet, or a "You're up to date" / "Couldn't check" snackbar.

- [ ] Build UI, `flutter analyze` + `flutter test`, on-device smoke. Commit `feat(update): update banner, sheet, settings check`.

---

### Task 8: Release-process docs + wire-up verification

**Files:**
- Modify: `README`/`docs` — the 3-step release flow (bump pubspec, edit `release.json`, push).
- Verify end-to-end: publish a manifest with a higher version to the live relay, confirm each platform shows the banner and updates.

- [ ] Commit `docs(update): release process`.

---

## Self-Review

- **Spec coverage:** version.json (T3), detection/compare (T1/T2), changelog non-empty rule (T1 `isBugUpdate` + T7 rendering), Android in-place (T4), macOS swap+relaunch (T5), Windows silent (T5), banner+Settings (T7), release process (T3/T8). ✓
- **Types consistent:** `UpdateInfo` fields/`isNewerThan`/`isBugUpdate` used identically in T2/T6/T7. `MethodChannel('clippy/update')` name shared T4. ✓
- **Placeholders:** desktop `appPath`/`$pid` resolution called out as concrete steps, not TODOs. macOS `.app` artifact path in CI flagged as the one thing to confirm against the actual mac job output. ✓
