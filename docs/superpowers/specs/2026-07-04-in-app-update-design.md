# In-App Update — Design Spec

**Date:** 2026-07-04
**Status:** Approved (design), pending implementation plan

## Goal

When a newer Clippy release is published, every existing install detects it, shows the user a changelog, and updates itself — as seamlessly as each platform allows, with no manual re-install. A "bug update" shows only **New Improvements** and **Bug Fixes**; a larger release also shows **New Features**.

## Architecture overview

```
release.json (repo)  --CI-->  /version.json (relay)  <--poll--  UpdateService (app)
                                                                      |
                                        UpdateBanner + UpdateSheet (UI)
                                                                      |
                                            PlatformUpdater (per-OS install)
```

- **Source of truth:** a `release.json` in the repo (hand-authored per release). CI copies it to `server/web/downloads/version.json`, served by the relay at `/version.json`.
- **Detection:** shared-Dart `UpdateService` fetches `/version.json`, compares against the app's own version (`package_info_plus`), exposes `UpdateInfo?` (null = up to date).
- **UI:** a dismissible banner on the home screen + a "Check for updates" row in Settings; both open an update sheet with the changelog and one **Update** button.
- **Install:** a per-platform `PlatformUpdater` downloads the right artifact and applies it.

## `version.json` / `release.json` shape

```json
{
  "version": "1.1.0",
  "build": 5,
  "notes": {
    "features":     ["Sign-in with Google account sync"],
    "improvements": ["Faster background screenshot sync"],
    "fixes":        ["Fixed URL-bar copies not syncing"]
  },
  "android": "/download/Clippy-Android.apk",
  "macos":   "/download/Clippy-macOS.zip",
  "windows": "/download/Clippy-Setup.exe"
}
```

- `release.json` in the repo is identical minus the artifact URLs (CI fills those in, since they're fixed relay paths).
- **Changelog rule:** the sheet renders only non-empty sections. A patch/bug release leaves `features` empty → only Improvements + Fixes show. `version` bump kind (patch vs minor/major) is derived from semver purely for the header label ("Bug fixes & improvements" vs "New in 1.1"); the sections themselves are driven by which lists are non-empty. No commit parsing.

## Detection logic (`UpdateService`)

- On app start (non-blocking) and on manual Settings check: `GET {relayHost}/version.json`.
- Parse into `UpdateInfo { version, build, notes, artifactUrlForThisPlatform }`.
- `isNewer(manifest, current)` = semantic-version compare of `version`, tie-broken by `build`.
- Failures (offline, 404, malformed) are swallowed — no update surfaced, no error shown on the auto path; the Settings path shows "Couldn't check — try again."
- A one-shot "dismissed for this version" flag (SharedPreferences, keyed by manifest version) hides the banner until the next release; the Settings entry always works.

## Per-platform install (`PlatformUpdater`)

**Android** — download APK to app storage, then a native `MethodChannel` triggers the system package installer (`ACTION_VIEW` / `PackageInstaller`) via a `FileProvider` URI. Requires the `REQUEST_INSTALL_PACKAGES` manifest permission and a one-time user grant ("allow Clippy to install apps"); the installer updates the existing app in place (same signature → in-place update, no data loss).

**macOS** — download `Clippy-macOS.zip` (the raw `.app`, added as a CI artifact) to a temp dir, unzip, then spawn a detached shell helper that: waits for the current PID to exit, `rm -rf`s the installed `/Applications/Clippy.app`, moves the new one in, and `open`s it. The app then quits itself. The user owns the bundle (drag-installed) so no admin prompt. Relaunches automatically.

**Windows** — download `Clippy-Setup.exe`, launch it with `/SILENT /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS` (Inno Setup, already used in CI), then exit. Inno replaces the install and relaunches. Requires `windows/installer.iss` to declare a stable `AppId` and the `CloseApplications`/`RestartApplications` directives (verify/add during implementation).

All three show a download progress indicator in the update sheet; on failure they fall back to opening the download page in the browser with a clear message.

## Release process (author flow)

1. Bump `version:` in `pubspec.yaml`.
2. Edit `release.json` — write the `features` / `improvements` / `fixes` lists (leave `features` empty for a bug release).
3. Push. CI builds all platforms, emits the macOS `.app` zip, copies artifacts + generates `version.json`, deploys to the relay.
4. Every existing install sees the update on next launch / manual check.

## Components (files)

- `server/lib/relay.dart` — add `/version.json` route (serve `web/downloads/version.json`).
- `.github/workflows/ci.yml` — generate `version.json` from `release.json` + `pubspec` version; add macOS `.app` zip artifact.
- `release.json` (repo root) — hand-authored changelog + version.
- `lib/core/update/update_info.dart` — model + semver compare (pure, unit-tested).
- `lib/core/update/update_service.dart` — fetch + compare + dismissal state.
- `lib/platform/updater/platform_updater.dart` — interface + `android/macos/windows` impls (download + apply).
- `lib/app/update_sheet.dart`, banner integration in `home_page.dart`, Settings row in `settings_page.dart`.
- `android/.../MainActivity.kt` (or a small channel) — APK install intent; `AndroidManifest.xml` — `REQUEST_INSTALL_PACKAGES` + FileProvider.
- `macos/Runner` — no native change needed (shell helper spawned from Dart).
- `windows/installer.iss` — stable AppId + restart directives.

## Testing / success criteria

- **Unit:** `isNewer` semver compare (1.0.0 vs 1.0.1, 1.2.0 vs 1.10.0, build tie-break, equal, malformed → false). Changelog section rendering (empty features hidden).
- **Integration:** `UpdateService` against a stubbed manifest (newer / same / older / offline).
- **On-device manual proof (per platform):** publish a test manifest with a higher version → app shows the banner → tap Update → the app updates in place and relaunches showing the new version. This is the real acceptance gate (as with the rest of Clippy: proven on the actual devices, not just unit tests).

## Out of scope (YAGNI)

- Forced/mandatory updates (a `critical` flag can be added later; v1 is always dismissible).
- Delta/partial updates — full artifact each time.
- Auto-download in the background — download starts only when the user taps Update.
- Rollback.
