# Clippy

Cross-device clipboard sync. Copy on one device, paste on another — text and
images, end-to-end encrypted, with no account and no cloud reading your data.

**Platforms:** macOS · Windows · Android
**Download:** <https://clippy-relay-production.up.railway.app>

## What it does

- **Instant sync** of text and images between all paired devices. Images sync
  in their original format at full quality — no re-encoding, no downscaling.
- **Shared history** — browse the room's recent clips on any device, tap to
  re-copy, multi-select to delete, or clear everything everywhere.
- **Background sync on Android** — an accessibility-service trigger captures
  copies (including Chrome's address bar) while the app is closed, and new
  screenshots auto-sync. Desktop apps live in the menu bar / system tray and
  keep syncing after the window closes.
- **Offline-safe** — copies made while a device is offline are queued durably
  and delivered when the connection returns. Delivery uses an explicit
  ack protocol: a clip is retried until the relay confirms it, and re-sends
  are idempotent (no duplicates).
- **Self-updating** — every client checks the relay's update manifest and
  installs new releases in-app on all three platforms.

## Privacy model

Clippy's relay is a zero-knowledge router:

- Devices pair by scanning a QR code that carries a 256-bit master key. The
  key never leaves the devices.
- Every clip is encrypted on-device with **AES-256-GCM** (keys derived from
  the master key via HMAC-SHA256). The relay sees only opaque ciphertext and
  an opaque room token — never plaintext, keys, or identities.
- The relay keeps the room's recent encrypted clips (so reconnecting devices
  catch up) on a persistent volume; deletes are flushed to disk immediately.

## Architecture

```
┌─ Flutter clients (macOS / Windows / Android) ─┐
│  capture → encrypt → WebSocket                │
│  history UI · clipboard write · self-update   │
└───────────────┬───────────────────────────────┘
                │ wss (E2E-encrypted payloads)
        ┌───────▼────────┐
        │  Dart relay    │  rooms · recent-history catch-up · ack/reject
        │  (Railway)     │  also serves the download page + update manifest
        └────────────────┘
```

- `lib/` — the Flutter app (sync engine, crypto, history, per-platform
  capture/paste, updaters).
- `android/` — native capture: accessibility service, screenshot observer,
  share-sheet targets, APK self-install.
- `server/` — the relay (`dart`, no framework), its own test suite, the
  download page, and the Dockerfile Railway builds.

## Building from source

```bash
flutter pub get
flutter run                 # current desktop platform or a connected device
flutter build macos|windows|apk
```

Run the relay locally and point clients at it:

```bash
dart run server/bin/relay.dart          # listens on :8080, in-memory history
flutter run --dart-define=CLIPPY_RELAY_URL=ws://localhost:8080
```

Set `DB_PATH=/some/path/clippy.json` to persist relay history across restarts.

## Tests

Two suites — run both when touching `server/`:

```bash
flutter test                # app: engine, crypto, store, queue, UI
cd server && dart test      # relay: protocol, repository, durability
```

## Releasing

Merging to `main` is the release. CI builds all three platforms, generates the
update manifest from `pubspec.yaml` + `release.json`, and deploys the relay
with the artifacts to Railway; clients see the update banner on next launch.
To cut a release: raise the version in `pubspec.yaml` (at least the build
number), write the changelog lists in `release.json`, and merge via PR.
