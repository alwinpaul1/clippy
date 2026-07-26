# Clippy — project rules

Cross-device clipboard sync: Flutter clients (macOS / Windows / Android) + a Dart
WebSocket relay on the VPS (`clippy.alwinpaul.me`). Clips are E2E AES-256
encrypted; devices pair by QR. The relay also hosts the download page and the
in-app-update manifest.

---

## Cutting a new release  ← the important one

Everything below is triggered by two files. To ship a new version:

1. **Bump the version in `pubspec.yaml`** (line `version:`), format `SEMVER+BUILD`.
   Always raise **at least the build number** — the updater treats a higher
   semver *or* a higher build as "newer" (`isNewerThan` in
   `lib/core/update/update_info.dart`). Examples:
   - bug/maintenance: `1.0.0+1` → `1.0.1+2`
   - new features:    `1.0.0+1` → `1.1.0+2`

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

- **Windows code signing (SmartScreen).** Unsigned `Clippy-Setup.exe` triggers
  SmartScreen ("Unknown publisher"). There is **no free software-only fix** —
  you need an Authenticode cert (OV cloud/HSM, or Azure Trusted Signing).
  CI signs automatically when these secrets exist:
  - `WINDOWS_CERT_PFX_BASE64` — base64 of the `.pfx` (export from your CA/HSM)
  - `WINDOWS_CERT_PASSWORD` — PFX password
  Timestamp uses DigiCert (`http://timestamp.digicert.com`). Without the
  secrets, CI still builds an unsigned installer and prints a notice.
  Note (2026): EV no longer auto-bypasses SmartScreen; reputation still builds
  over downloads. Signing shows a real publisher name and is required for a
  professional install path.
  **Never regenerate** the Inno `AppId` in `windows/installer.iss` — it is the
  permanent upgrade identity.

---

## Verifying a release went out

```
curl -s https://clippy.alwinpaul.me/version.json      # 200 + new version
curl -so/dev/null -w '%{http_code}\n' \
  https://clippy.alwinpaul.me/download/Clippy-Android.apk  # 200
```
(Repeat for `Clippy-macOS.zip` and `Clippy-Setup.exe`.) A changed byte size vs.
the previous build confirms the automated deploy replaced the artifacts.
