# Clippy — project rules

Cross-device clipboard sync: Flutter clients (macOS / Windows / Android) + a Dart
WebSocket relay on the VPS (`clippy.alwinpaul.me`). Clips are E2E AES-256
encrypted; devices pair by QR. The relay also hosts the download page and the
in-app-update manifest.

---

## Cutting a new release  ← the important one

Everything below is triggered by two files. To ship a new version:

1. **Bump the version in `pubspec.yaml`** (line `version:`). Format is
   Flutter's `SEMVER+BUILD`. **What you raise depends on what shipped:**

   | The release contains | Raise |
   |---|---|
   | a new **feature** (`features` in `release.json` is non-empty) | **SEMVER and build** |
   | only **improvements / fixes** (`features` is `[]`) | **the build number ONLY** |

   Examples:
   - improvements only: `1.5.0+58` → `1.5.0+59`
   - new features:      `1.5.0+58` → `1.6.0+59`

   **The build number is always strictly increasing, with no exceptions.**
   Android's `versionCode` must rise or the APK will not install over the
   existing app.

   **A build-only release does reach users.** `UpdateInfo.isNewerThan`
   (`lib/core/update/update_info.dart`) compares the semver first and falls
   through to `build > currentBuild` when the semvers match, so the updater
   offers it. Do not "fix" that fall-through; this rule depends on it.

   **The cost of a build-only release, so nobody is surprised by it:** the
   user is told about "Version 1.5.0" while already running 1.5.0, because
   the sheet and the banner both print the semver and users never see the
   build number. That is the accepted trade for not inflating the semver on
   small changes. If it ever becomes confusing, the fix is to print the build
   in the sheet when the semver is unchanged, not to abandon the rule.

2. **Edit `release.json`** (repo root) — set its `"version"` to the new semver
   (CI FAILS the build if it doesn't match `pubspec.yaml`, so stale notes can
   never ship under a new version) and write its `notes`, which become the
   changelog:
   - `features`  — user-facing **new capabilities**.
     **Non-empty ⇒ the update sheet is titled "New in X.Y".**
   - `improvements`, `fixes` — everything else.
   - **Leave `features` empty (`[]`) for a bug/maintenance release.** Then
     `isBugUpdate` is true, the sheet is titled **"Bug fixes & improvements"**,
     and it shows only the improvements + fixes lists. (This is the deliberate
     "bug update" framing — no version-hero, just what got better.)
   - Empty lists are hidden; only write lines a user should read.

3. **Merge both files to `main` via PR.** The push to `main` is the release
   trigger — there is no separate publish step.

4. **The pipeline does the rest** (`.github/workflows/ci.yml`): builds
   Android/macOS/Windows, generates `version.json` from `pubspec.yaml` + `release.json`,
   stages the artifacts, and (when `VPS_SSH_KEY` / `VPS_HOST` secrets are set)
   rsyncs + rebuilds the Docker relay on the VPS. Within a couple of minutes
   `https://clippy.alwinpaul.me/version.json` reflects the new version, and
   every client shows the update banner/sheet on next launch and self-updates
   when the user taps it. Without those secrets, push artifacts to the VPS
   manually (`/opt/clippy/relay` + `docker build`/`run`).

Nothing else to touch — don't hand-edit `version.json` (it is generated) unless
staging a one-off VPS upload.

---

## Invariants — do NOT break these

- **Android signing.** The APK must stay release-signed by the **one permanent
  keystore** at `~/.clippy/clippy-release.jks`. CI does this from the
  `ANDROID_KEYSTORE_BASE64` GitHub secret (base64 of that exact keystore); if the
  secret is missing it falls back to *debug* signing, and Android then **refuses
  to install the update over an existing install** (signature mismatch). The
  keystore is **unrecoverable if lost** — lose it and no existing install can
  ever be updated again. Keep the secret set; never regenerate the key.

- **VPS deploy.** Relay runs as Docker `clippy-relay` on `127.0.0.1:8088` with
  Caddy terminating TLS for `clippy.alwinpaul.me` on the public IP. Do not bind
  the relay publicly without Caddy; do not steal Tailscale Serve `:443` from
  OpenClaw (Caddy binds the **public** IP only).

- **Artifact names are a contract.** The updater fetches
  `/download/Clippy-Android.apk`, `/download/Clippy-macOS.zip`,
  `/download/Clippy-Setup.exe`. If you rename an artifact, update the matching
  path in the "Generate update manifest" step of `ci.yml` in the same change.

- **Windows code signing (SmartScreen).** Optional CI hooks: `SIGNPATH_*`
  secrets (SignPath Foundation, if approved) or `WINDOWS_CERT_PFX_BASE64` +
  `WINDOWS_CERT_PASSWORD`. Without them the installer is unsigned. See
  `docs/windows-code-signing.md` (maintainer-only). **Never regenerate** the
  Inno `AppId` in `windows/installer.iss`.

---

## Verifying a release went out

```
curl -s https://clippy.alwinpaul.me/version.json      # 200 + new version AND build
curl -so/dev/null -w '%{http_code}\n' \
  https://clippy.alwinpaul.me/download/Clippy-Android.apk  # 200
```
(Repeat for `Clippy-macOS.zip` and `Clippy-Setup.exe`.)

**Check the `build`, not only the `version`.** After an improvements-only
release the semver is unchanged on purpose, so a version that "did not move"
proves nothing. The build number is what moved.

**Prove the artifacts are really new, do not infer it.** A changed byte size
is a hint. The manifest's `sha256` is written by CI and can describe a file
the VPS never received, so download one artifact and hash it yourself:

```
curl -sLo /tmp/c.zip https://clippy.alwinpaul.me/download/Clippy-macOS.zip
shasum -a 256 /tmp/c.zip     # must equal .sha256.macos in version.json
```
