# Clippy — Build Status & Handoff

**Updated:** 2026-07-02
**Branch:** `feat/foundation-core`
**Tests:** 44 passing, `flutter analyze` clean.

## ✅ Built and verified (pure Dart, no external accounts needed)

The entire **transport-agnostic core** is done and unit-tested. This is the hard,
correctness-critical part — and it's independent of Firebase/Railway/platform,
so none of it is throwaway.

| Module | File | What it does | Tests |
|--------|------|--------------|-------|
| Models | `lib/core/models/` | `ClipEvent`, `EncryptedClip`, `RemoteClip` | 7 |
| Sync engine | `lib/core/sync/sync_engine.dart` | §7 state machine: echo-guard (one-shot, 2s), freshness gate (60s first-snapshot), persisted dedup, apply-latest | 15 |
| Encryption | `lib/core/crypto/aes_gcm_crypto_box.dart` | Real AES-256-GCM, HMAC-derived enc/mac subkeys from the paired master key, deterministic fingerprint | 10 |
| History | `lib/core/history/history_store.dart` | decrypt + order + cap(25) + consecutive-dedup + apply-on-tap | 7 |
| State | `lib/core/state/prefs_state_store.dart` | persist `lastAppliedHash` across restarts | 4 |
| Smoke | `test/smoke_test.dart` | harness | 1 |

Interfaces the platform/backend plug into (already defined + faked in tests):
`CryptoBox`, `StateStore`, `ClipboardWriter`, and the `SyncAction` outputs.

## ⛔ Gated on you (external accounts / devices I can't access)

These need your credentials or hardware. I've written the exact steps.

### Gate 1 — Firebase project (for auth + backend, testing phase)
1. Go to <https://console.firebase.google.com> → **Add project** → name it `clippy` (Google Analytics optional).
2. Install the CLIs (in this session, type the `!` lines so output lands here):
   - `! npm i -g firebase-tools` (or `curl -sL https://firebase.tools | bash`)
   - `! dart pub global activate flutterfire_cli`
   - `! firebase login`
3. From the project root: `! flutterfire configure --project=clippy`
   → generates `lib/firebase_options.dart` and drops `google-services.json` (Android) + `GoogleService-Info.plist` (macOS). *(These are git-ignored — secrets.)*
4. In the Firebase console → **Authentication** → enable **Google** sign-in.

### Gate 2 — Google Sign-In client details
- **Android:** add your debug **SHA-1** to the Firebase Android app:
  `! keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android | grep SHA1`
  → paste it into Firebase console → Project settings → your Android app → Add fingerprint, then re-run `flutterfire configure`.
- **macOS:** the generated `GoogleService-Info.plist` gives the `CLIENT_ID`; it goes into `macos/Runner/Info.plist` as `GIDClientID` (I'll wire this once the file exists).

### Gate 3 — Apple code-signing (macOS app)
- Open `macos/Runner.xcworkspace` in Xcode → Signing & Capabilities → select your Apple ID team. Keychain-based Google/Firebase auth fails on unsigned builds.

### Gate 4 — Physical Android phone (capture engine)
- Your Samsung phone + USB, for the one-time ADB grant and on-device testing of the background capture engine. Emulators can't validate the READ_LOGS/overlay path.

## 🔜 Remaining to build (I do these; some need the gates above)

| Component | Needs gate | Notes |
|-----------|-----------|-------|
| `ClipStore` (Firestore `clips/{uid}/items`) + security rules | Gate 1 (or local emulator) | append / ordered history stream / trim |
| `AuthController` (Google → Firebase uid) | Gate 1+2 | |
| `PairingController` (QR key exchange) + Keychain/Keystore key storage | — (code now, run needs devices) | |
| macOS app: `ClipboardPort` (NSPasteboard), menu-bar shell + history | Gate 3 | can run on this Mac once signed |
| Android app: tiered capture engine, FGS, floating bubble, pairing scan | Gate 1+4 | |

## CI/CD (`.github/workflows/ci.yml`)

On every push/PR to `main`:
1. **analyze-test** — `flutter analyze` + `flutter test` (the 44 Dart tests).
2. **firestore-rules** — spins up the Firestore emulator and runs the 9 rules tests.
3. **deploy-rules** — on push to `main` (after 1+2 pass), deploys `firestore.rules` to your Firebase project. **No-ops until you add these repo secrets** (Settings → Secrets and variables → Actions):
   - `FIREBASE_PROJECT_ID` — your real project id (e.g. `clippy`).
   - `FIREBASE_TOKEN` — from `! firebase login:ci` (paste the printed token).
   *(Token auth is simplest for a personal project; a service-account secret is the production-grade upgrade later.)*

Note: CI does not build the macOS/Android apps (they need your git-ignored Firebase config + signing). It validates the Dart core and the rules — the parts that must stay correct on every change.

## Notes
- Backend decision: **Firebase now, Railway relay when going public** — swap is contained to `ClipStore` (see spec §4.5, decisions log).
- Multi-user: architecture is per-uid isolated + per-user E2E keys from day one (spec §1).
