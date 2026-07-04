# Clippy — project rules

Cross-device clipboard sync: Flutter clients (macOS / Windows / Android) + a Dart
WebSocket relay on Railway. Clips are E2E AES-256 encrypted; devices pair by QR.
The relay also hosts the download page and the in-app-update manifest.

---

## Cutting a new release  ← the important one

Everything below is triggered by two files. To ship a new version:

1. **Bump the version in `pubspec.yaml`** (line `version:`), format `SEMVER+BUILD`.
   Always raise **at least the build number** — the updater treats a higher
   semver *or* a higher build as "newer" (`isNewerThan` in
   `lib/core/update/update_info.dart`). Examples:
   - bug/maintenance: `1.0.0+1` → `1.0.1+2`
   - new features:    `1.0.0+1` → `1.1.0+2`

2. **Edit `release.json`** (repo root) — its `notes` become the changelog:
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
   stages the artifacts, and `railway up`s the relay. Within a couple of minutes
   `https://clippy-relay-production.up.railway.app/version.json` reflects the new
   version, and every client shows the update banner/sheet on next launch and
   self-updates when the user taps it.

Nothing else to touch — don't hand-edit `version.json` (it is generated) and
don't upload artifacts manually.

---

## Invariants — do NOT break these

- **Android signing.** The APK must stay release-signed by the **one permanent
  keystore** at `~/.clippy/clippy-release.jks`. CI does this from the
  `ANDROID_KEYSTORE_BASE64` GitHub secret (base64 of that exact keystore); if the
  secret is missing it falls back to *debug* signing, and Android then **refuses
  to install the update over an existing install** (signature mismatch). The
  keystore is **unrecoverable if lost** — lose it and no existing install can
  ever be updated again. Keep the secret set; never regenerate the key.

- **CI deploy flag.** The `railway up` line in `ci.yml` must keep
  **`--no-gitignore`**. The download artifacts are staged into
  `server/web/downloads/` (which is gitignored), and `railway up` honours
  `.gitignore` by default — without the flag it drops them and the relay serves
  404 for `version.json` + every `/download/*`. `.railwayignore` still trims
  `build/`, `.dart_tool/`, and the Flutter app dirs.

- **Artifact names are a contract.** The updater fetches
  `/download/Clippy-Android.apk`, `/download/Clippy-macOS.zip`,
  `/download/Clippy-Setup.exe`. If you rename an artifact, update the matching
  path in the "Generate update manifest" step of `ci.yml` in the same change.

---

## Verifying a release went out

```
curl -s https://clippy-relay-production.up.railway.app/version.json      # 200 + new version
curl -so/dev/null -w '%{http_code}\n' \
  https://clippy-relay-production.up.railway.app/download/Clippy-Android.apk  # 200
```
(Repeat for `Clippy-macOS.zip` and `Clippy-Setup.exe`.) A changed byte size vs.
the previous build confirms the automated deploy replaced the artifacts.
