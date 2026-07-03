# Clippy — Build Status

**Updated:** 2026-07-02
**Repo:** github.com/alwinpaul1/clippy (private) · branch `main`

## Architecture (current)

Zero-knowledge **Railway relay** backend — no Firebase, no login. Devices that
scan/enter the same pairing key share a room; the relay routes E2E-encrypted
clips by an opaque room token and never sees the key, plaintext, or identity.

```
 Device A  ──wss──▶  Railway relay (clippy-relay)  ◀──wss──  Device B
  copy → seal(AES-256-GCM) → append          route + last-25 history
  incoming → SyncEngine → set clipboard       (zero-knowledge)
   pairing key (QR/text) shared device→device; relay only sees room token + ciphertext
```

## ✅ Done and live

- **Relay deployed & working end-to-end over the internet:**
  `wss://clippy-relay-production.up.railway.app` (health 200; verified a clip
  routed A→B with server timestamp). 6 relay tests.
- **Pure-Dart core:** SyncEngine (echo-guard/freshness/dedup), AES-256-GCM
  CryptoBox, HistoryStore, PrefsStateStore — 44 tests.
- **Pairing + client:** PairingKey (room token + content keys from one master
  key), WebSocketClipStore — 8 + 5 unit tests + 3 in-process relay integration
  tests. **60 tests total, analyzer clean.**
- **App wired:** pairing screen (generate/enter key), home screen (synced
  history, tap-to-copy, manual add, add-device), desktop auto-capture via
  clipboard_watcher, master key in Keychain/Keystore. Firebase removed.
- **App icon** (paperclip-with-eyes) on macOS + Android.
- **CI/CD** green: app analyze+test, relay analyze+test, deploy-relay job
  (arms once `RAILWAY_TOKEN` secret is set).
- **Railway:** `clippy` project + `clippy-relay` service + public domain.
  nexdash deleted (per Alwin).

## Remaining

| Item | Notes |
|------|-------|
| Install on devices | macOS: `flutter run -d macos`. Android: connect phone (USB debugging) → `flutter run -d <device>` or sideload the debug APK. |
| Android background capture | v1 captures via the in-app box + receives automatically; true background copy-capture (READ_LOGS+overlay / Shizuku) is the elevated follow-up (spec §6). |
| Real QR pairing UI | v1 uses a copy/paste key; a camera QR scan is a UX nicety on top. |
| Durable relay history | v1 keeps last-25 in memory (survives while the relay runs); SQLite-on-volume is the durability follow-up. |
| Windows/iOS/Linux | The relay client is cross-platform; add the targets when wanted (spec §13). |

## Secrets to add (optional, for CI auto-deploy)

Repo → Settings → Secrets → Actions: `RAILWAY_TOKEN` = a Railway project token
(`railway tokens` or dashboard). Until set, the deploy job is a green no-op.

## How to run

- **macOS:** `flutter run -d macos` (sandbox network entitlement already set).
- **Android:** enable Developer Options → USB debugging, plug in, authorize, then
  `flutter devices` should show it → `flutter run -d <id>`.
- **Pair two devices:** on the first, tap "Generate a new key" → Pair. On the
  second, paste the same key → Pair. Copy on one, watch it appear on the other.
