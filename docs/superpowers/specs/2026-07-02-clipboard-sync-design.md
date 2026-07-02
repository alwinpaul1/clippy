# Clippy — Cross-Device Clipboard Sync (Design Spec)

**Date:** 2026-07-02
**Author:** Alwin (with Claude)
**Status:** Approved for planning
**Scope of this spec:** v1 — text-only, two personal devices (one macOS, one Android), same Google account, with a synced **browsable clipboard history**. Structured so a multi-user product is a later, additive phase, not a rewrite.

---

## 1. Goal

Log in with the same Google account on a Mac and an Android phone. Copy text on one device and it syncs to the other, in both directions, whether on the same network or on mobile data. Two things happen for every synced clip:

1. **Latest clip → system clipboard.** The most-recent copy is placed on the other device's *system clipboard*, so it's the current clip your normal keyboard pastes — on Android that means it's available in the Samsung keyboard (or any keyboard) with no extra taps.
2. **Full history → Clippy.** Clippy keeps a synced, browsable list of your recent clips on both devices, because Android's per-keyboard clipboard-history panels are closed to third-party apps (see §1.1). You browse this history in the Clippy app, a macOS menu-bar list, and an Android floating bubble you can tap while typing.

**In scope (v1):** plain text and URLs; automatic Mac → Android; best-effort-automatic Android → Mac (via one-time elevated setup); synced browsable history (capped at the most recent N items); end-to-end encryption; sensitive-clip skipping.

**Out of scope (v1):** images, files, multi-user sign-ups, Windows/Linux, web, a Clippy keyboard (IME). These are deliberately deferred (YAGNI) and the design leaves room for each.

### 1.1 Why history lives in Clippy, not the Samsung keyboard

The Android **system clipboard holds exactly one item** — there is no clipboard-history in any public Android API. The scrollable history grid inside Samsung Keyboard (and Gboard) is *that keyboard's own private store* (Samsung's `SemClipboard` system service), not reachable or writable by third-party apps. So Clippy **cannot** inject a multi-item history into Samsung's panel, nor read what's in it. What Clippy *can* do is keep the current system clip in sync (so the latest item is available in any keyboard) and maintain its **own** browsable history surface. This is a hard platform constraint, not a design choice.

---

## 2. Success Criteria

The build is "done" for v1 when, on Alwin's own Mac + Android phone:

1. Signing in with the same Google account on both devices pairs them into one encrypted channel.
2. Copying text on the Mac makes it the Android **system clipboard** within a few seconds (pasteable directly from the Samsung keyboard) while the phone is awake, and on next screen-on if it was in deep Doze.
3. Copying text on Android (after the one-time elevated setup) makes it the Mac clipboard within a few seconds.
4. Both devices show the **same synced history list** (most-recent N clips); a clip copied on either device appears in the other's Clippy history.
5. Tapping any history item (Android bubble/app, or macOS menu) puts that item on the local system clipboard, ready to paste.
6. Copying a password from a password manager does **not** sync (concealed-clip skip) and does **not** enter history.
7. Clip contents are unreadable in the Firebase console (stored as ciphertext).
8. Re-copying the same text later syncs correctly (no permanent echo suppression).
9. On reconnect / cold start, a stale clip does **not** silently overwrite what's currently on the clipboard.

Each is an observable behavior, testable by hand and (where possible) by automated test.

---

## 3. Architecture Overview

One Flutter codebase, two targets (macOS + Android), native platform-channel code for the clipboard-and-OS-specific parts. Firebase free (Spark) plan is the backend. No custom server in v1.

```
  macOS menu-bar app                 Firebase (free Spark plan)                Android app
  ┌────────────────────┐            ┌───────────────────────────┐            ┌────────────────────────┐
  │ Flutter UI:        │            │  Firebase Auth (Google)   │            │ Flutter UI + FGS       │
  │  tray + history    │            │  → uid per account        │            │  history screen        │
  │ NSPasteboard poll  │  Google    │                           │  Google    │ Floating bubble (overlay)│
  │ (changeCount, 1s)  │  Sign-In   │  Firestore:               │  Sign-In   │ Tiered capture engine  │
  │                    │◀──────────▶│   clips/{uid}/items/{id}  │◀──────────▶│ setPrimaryClip write   │
  │ SyncEngine (Dart)  │  listener  │   { ciphertext, iv, hash, │  listener  │ SyncEngine (Dart)      │
  │ HistoryStore       │  + append  │     source, timestamp }   │  + append  │ HistoryStore           │
  │ E2E crypto (Keychn)│  (cap N)   │  latest N, ordered desc   │  (cap N)   │ E2E crypto (Keystore)  │
  └────────────────────┘            │  Rules: uid-scope+size    │            └────────────────────────┘
                                    └───────────────────────────┘
        Shared AES-256-GCM key established once via QR pairing (Mac shows, phone scans),
        stored in macOS Keychain / Android Keystore. Firebase never sees plaintext or the key.
```

**Two independent secrets, two independent jobs:**
- **Google account** → identity + which Firestore path you read/write (`clips/{uid}/…`). This is the "same email = same clipboard" mechanism.
- **QR-paired AES-256-GCM key** → confidentiality of clip contents. Firebase authenticates *who* you are but never holds the key, so it cannot read clips.

**Two data paths per synced clip:**
- **Apply-latest path** (the `SyncEngine`, §7): decides whether the *newest* remote clip should be written to the local system clipboard, guarding against echo loops and stale-clip clobber.
- **History path** (the `HistoryStore` + UI, §7.1): the ordered, capped list of recent clips for browsing; older items are apply-on-tap, not auto-applied.

---

## 4. Components

Each component has one purpose, a defined interface, and known dependencies. Designed so each can be understood and tested in isolation.

### 4.1 `SyncEngine` (shared Dart, both platforms)
- **Does:** owns the apply-latest state machine — echo-guard, freshness gate, dedup (§7). Decides which actions to emit for the *newest* clip. Platform-agnostic; the single most important unit to unit-test.
- **Interface:** `onLocalClip(ClipEvent)`, `onRemoteSnapshot(RemoteClip newest)`, emits `UploadClip`, `ApplyToClipboard`, `OfferRestore`.
- **Depends on:** `CryptoBox`, `StateStore` (persisted `lastAppliedHash`), an injected clock, `selfDeviceId`.

### 4.2 `HistoryStore` (shared Dart)
- **Does:** maintains the decrypted, ordered, capped in-memory history for the UI from the `ClipStore` stream; de-dups consecutive identical hashes; exposes the list for the bubble/menu/app.
- **Interface:** `Stream<List<HistoryItem>> history`, `Future<void> applyItem(HistoryItem)` (→ set system clipboard via `ClipboardPort`).
- **Depends on:** `ClipStore`, `CryptoBox`, `ClipboardPort`.

### 4.3 `ClipboardPort` (platform channel, per-OS impl)
- **Does:** read/write the system clipboard and report changes, hiding OS differences behind one interface.
- **Interface:** `Stream<ClipEvent> changes`, `Future<void> setText(String)`, per-event metadata `{isText, isConcealed, byteSize}`.
- **macOS impl:** poll `NSPasteboard.general.changeCount` every ~1s (back off when app inactive); read `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType` markers → `isConcealed`.
- **Android impl:** the tiered capture engine (§6); reports `EXTRA_IS_SENSITIVE` (API 33+) as `isConcealed`; writes via `setPrimaryClip()`.

### 4.4 `CryptoBox` (shared Dart + platform keystore)
- **Does:** AES-256-GCM encrypt/decrypt; `HMAC(key, plaintext)` fingerprint; store/load the shared key from Keychain (macOS) / Keystore (Android, hardware-backed where available).
- **Interface:** `Future<EncryptedClip> seal(String, {source})`, `Future<String> open(RemoteClip)`, `Future<String> fingerprint(String)`, `bool get isPaired`.

### 4.5 `ClipStore` (shared Dart, wraps Firestore)
- **Does:** append to `clips/{uid}/items`, stream the latest-N ordered `items`, and trim beyond the cap. Adds `FieldValue.serverTimestamp()` on write. Enforces the client-side size cap before upload.
- **Interface:** `Stream<List<RemoteClip>> watchHistory(uid, {limit})`, `Future<void> append(uid, EncryptedClip)`, `Future<void> trim(uid, {keep})`.

### 4.6 `AuthController` (shared Dart)
- **Does:** Google Sign-In → Firebase `signInWithCredential` → exposes `uid`. Handles sign-out teardown.
- **Interface:** `Future<User?> signIn()`, `Future<void> signOut()`, `Stream<User?> authState`.

### 4.7 `PairingController` (shared Dart + platform)
- **Does:** first-run device pairing. Mac generates the AES key and shows a QR (key + salt); Android scans it and stores the same key. Manual-code fallback if no camera.
- **Interface:** `Future<void> showPairingQr()` (Mac), `Future<void> scanPairingQr()` (Android).

### 4.8 History surfaces (platform UI)
- **macOS:** menu-bar dropdown lists recent history; click an item → copy to clipboard. Menu-bar-only app (`LSUIElement=1`; `tray_manager`). Always-running accessory → the Firestore listener lives in the **main isolate**.
- **Android:** (a) Clippy app history screen; (b) **floating bubble** via `SYSTEM_ALERT_WINDOW` (the same overlay permission the capture engine needs) — tap the bubble while typing → history pops up → tap an item → it becomes the system clipboard, paste normally; (c) optional Quick Settings tile. `flutter_foreground_task` keeps the process + main-isolate listener alive (FGS type `connectedDevice`/`dataSync`, mandatory API 34+).

---

## 5. Data Model & Backend

**Firestore — a capped history subcollection per account:**
```
clips/{uid}/items/{autoId}   // autoId = Firestore-generated document id
```
Each `item`:
```jsonc
{
  "ciphertext": "<base64 AES-256-GCM>",   // encrypted clip text
  "iv":         "<base64 96-bit nonce>",
  "hash":       "<base64 HMAC(key, plaintext)>",  // echo-guard + history de-dup key; not a plaintext oracle
  "source":     "<deviceId>",             // random per-install id
  "timestamp":  "<serverTimestamp>"       // server clock; ordering + freshness, never device clock
}
```

- **Cap `N = 25`** most-recent items (configurable). Devices listen with `orderBy(timestamp, desc).limit(N)`.
- **Trim:** after an append, the writing device deletes items older than the newest `N` (`orderBy(timestamp).limitToLast(...)` beyond cap). Concurrent trims from two devices converge (deletes are idempotent); acceptable for personal use.
- **De-dup:** a device does not append a clip whose `hash` equals the current newest item's `hash` (prevents echo/duplicate entries).

**Security rules:**
```
match /clips/{uid}/items/{item} {
  allow read: if request.auth != null && request.auth.uid == uid;
  allow create: if request.auth != null && request.auth.uid == uid
    && request.resource.data.ciphertext.size() < 150000;   // ~100KB plaintext cap
  allow delete: if request.auth != null && request.auth.uid == uid;  // trimming
  allow update: if false;                                   // items are immutable
}
```

**App Check:** enable Play Integrity (Android) / App Attest (macOS) — free, blocks non-app clients using a leaked config.

**Free-tier budget (re-verified for history):** Spark = 50k reads / 20k writes / 20k deletes per day, 1 GiB stored. Heavy personal use (~200 copies/day × 2 devices): appends ≈ 200/day, trims ≈ up to 200 deletes/day, listener reads ≈ 25 on each (re)connect + 1 per new item ≈ low thousands/day worst case. All comfortably under caps even at 10×. Storage: 25 short text items = kilobytes. Debounce writes to respect Firestore's ~1 write/sec/document soft limit (appends target distinct doc ids, so contention is minimal).

---

## 6. Android Capture Engine (the hard half)

**Verified constraint:** On Android 10+, `getPrimaryClip()` returns empty unless the app has window focus or is the default IME. Granting `READ_CLIPBOARD` via appops/Shizuku does **not** lift this focus gate. Background *reading* therefore requires either momentarily grabbing focus, or running the read as a privileged (shell/root) uid. Background *writing* (`setPrimaryClip()` from the foreground service) generally works and is the easy half.

**Tiered capture — best-available-wins, one shared foreground service:**

| Tier | Mechanism | Setup | Notes |
|------|-----------|-------|-------|
| Write (Mac→Android) | `setPrimaryClip()` from FGS | none | Try first; escalate only if a device drops it. |
| Read tier 1 (optional) | **Shizuku** UserService reads `IClipboard` as shell uid | Shizuku app + re-activate each boot | "Power mode": silent, no overlay flicker, no per-start log prompt. Hidden-API reflection; guard `AttributionSource` (API 31) and the added `deviceId` arg (API 34). |
| Read tier 2 (**primary build target**) | **READ_LOGS + SYSTEM_ALERT_WINDOW overlay focus-grab** | one-time ADB grant; log-consent prompt once per process start on API 13+ | Proven by KDE Connect + ClipCascade (open-source, portable). Watches own logcat for the clipboard-denied line, pops an invisible focusable overlay, reads, dismisses. The `SYSTEM_ALERT_WINDOW` grant is **also** what powers the history floating bubble (§4.8) — one permission, two uses. |
| Fallback (always available) | Manual: Quick Settings tile / share-sheet "Send to Clippy" | none | 100% reliable, one tap. Free byproduct of the app. |

**Explicitly NOT the primary path:** AccessibilityService — cannot read the clipboard directly, misses Ctrl+C / programmatic copies, OEMs auto-revoke it.

**One-time ADB grant (overlay path), documented for the user:**
```
adb -d shell pm grant <pkg> android.permission.READ_LOGS
adb -d shell appops set <pkg> SYSTEM_ALERT_WINDOW allow
adb -d shell am force-stop <pkg>
```

**Correction baked into the design:** do **not** use a transparent *Activity* to grab focus — Background-Activity-Launch restrictions block it on Android 10+. Use a `SYSTEM_ALERT_WINDOW` *overlay window* made momentarily focusable, exactly as KDE Connect/ClipCascade do.

**Pre-implementation spike:** before committing to the Shizuku tier, spend ~15 min reading AOSP `ClipboardService.clipboardAccessAllowed()` to confirm the shell-uid bypass (ecosystem-supported but not canonically cited). The overlay tier is fully evidenced and is the primary target regardless.

---

## 7. Sync State Machine (apply-latest: echo-guard, freshness, dedup)

The `SyncEngine` governs the **apply-to-system-clipboard** decision for the *newest* clip only. Older history items are never auto-applied — they apply only when the user taps them. This machine prevents the three data-loss/loop bugs: infinite echo, permanent re-copy suppression, and stale-clip clobber on reconnect/cold-start.

**Per-device state:** `selfDeviceId`; `lastAppliedHash` (**persisted** across restarts); `expectedEchoHash` + `expectedEchoExpiry` (in-memory, one-shot). Fingerprint `h = HMAC(key, plaintext)`.

**On local clipboard change:**
1. If non-text, concealed/sensitive, or `byteSize > CAP` → ignore.
2. If `expectedEchoHash != null && h == expectedEchoHash && now < expectedEchoExpiry` → echo of what we just applied → clear `expectedEchoHash`; do **not** upload.
3. Else → upload (append) `{ciphertext, iv, hash:h, source:selfDeviceId, timestamp:serverTimestamp()}`; set `lastAppliedHash = h`.

**On remote snapshot (newest item of the history stream):**
1. If `newest.source == selfDeviceId` → ignore.
2. If `newest.hash == lastAppliedHash` → ignore (already applied; absorbs reconnect/cold-start re-delivery).
3. If **first considered snapshot of this session** AND `now − newest.timestamp > 60s` → do **not** write the clipboard; set `lastAppliedHash = newest.hash`; surface as a "restore last clip" affordance.
4. Else → decrypt; set `expectedEchoHash = newest.hash`, `expectedEchoExpiry = now + 2s`; write system clipboard; set `lastAppliedHash = newest.hash`.

**Why this is correct:** echo suppression is one-shot and 2s-boxed (re-copying the same text later still uploads); `lastAppliedHash` is persisted (reconnect re-delivery is deduped, not clobbered); the 60s freshness gate applies only to the first considered snapshot (a late Doze delivery mid-session still applies). Last-write-wins ordering is by server timestamp.

### 7.1 History path (storage, de-dup, trim)

Separate from the apply decision, every non-skipped clip flows into history:
- **Append:** on a local upload (local rule 3) the clip is appended to `clips/{uid}/items`. Remote items arrive via the `ClipStore` stream and populate the local `HistoryStore` for display — remote items are *not* re-appended (they already exist in Firestore).
- **De-dup:** skip appending a clip whose `hash` equals the current newest item's `hash`.
- **Cap/Trim:** keep newest `N=25`; the appending device trims older items.
- **Apply-on-tap:** tapping a history item (bubble/menu/app) calls `ClipboardPort.setText` locally; it does **not** re-upload (it's already in history) and does **not** arm echo state beyond the normal local-watcher path.

---

## 8. Security & Privacy (binding decisions)

1. **E2E encryption is in v1.** Clipboards routinely carry passwords, OTPs, seed phrases; plaintext-at-rest would put all of it behind one phished Google account. AES-256-GCM, key established once by QR pairing, stored in Keychain/Keystore. Store `{ciphertext, iv}`; echo/de-dup fingerprint is `HMAC(key, plaintext)` so Firestore never holds a plaintext hash oracle. Every history item is individually encrypted.
2. **Concealed clips are skipped** (never synced, never entered into history). macOS: `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType`. Android: `ClipDescription.EXTRA_IS_SENSITIVE` (API 33+).
3. **Freshness window = 60s, first snapshot only** (§7). Persisted `lastAppliedHash` is the real workhorse against reconnect replay.
4. **No FCM in v1.** Reliable Doze wake-up needs a high-priority FCM from a Firestore-trigger Cloud Function, which requires the paid Blaze plan; the client-to-client alternative needs an un-embeddable service-account credential. Instead: foreground service + `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` + forced resync on app resume. Shape the write path so an FCM trigger drops in cleanly at the product/Blaze phase. Accepted trade-off: delivery to a deep-Doze phone lags to the next maintenance window or next screen-on.
5. **App Check + uid-scoped, size-capped, immutable-item security rules** (§5).
6. **History retention:** the synced history is capped at N=25 items and trimmed; it is not an unbounded archive. A "clear history" action deletes all `items` for the account.

---

## 9. Error Handling & Edge Cases

- **Oversized text (> cap / Firestore 1 MiB doc limit):** skip + notify ("clip too large to sync"). Never truncate.
- **Non-text clipboard (image copied):** detect absence of a plain-text type, ignore gracefully; do not upload, do not clear remote history.
- **History de-dup / rapid re-copies:** consecutive identical hashes are collapsed (§7.1) so the list doesn't fill with duplicates.
- **Trim race across two devices:** both may delete overlapping old items; deletes are idempotent, end state converges to newest N.
- **Sign-out on one device:** tear down listeners + capture, stop the FGS, handle `permission-denied` without crashing, prompt re-auth. Keep the pairing key in Keychain/Keystore so re-signing the same account resumes without re-pairing.
- **OEM task-killers (Xiaomi/Samsung/Oppo/Huawei):** dontkillmyapp-style onboarding (autostart / disable optimization); force a resync on app resume. Cannot be fully solved without FCM.
- **Permission auto-revoke / app hibernation (Android 11+):** prompt to disable "remove permissions if unused" / `setAutoRevokeWhitelisted`.
- **ADB/Shizuku grants are not permanent:** `READ_LOGS` survives reboot but is wiped on uninstall; ADB-started Shizuku must be re-activated each boot. Document the re-grant flow.
- **Clipboard-access toast (Android 12+):** reading surfaces "Clippy pasted from clipboard"; Samsung One UI blocks hiding it. Harmless; note it in onboarding.
- **Samsung Keyboard clipboard-history panel:** v1 sets the *system* primary clip, so the latest synced clip is the next thing the Samsung keyboard pastes. Whether it also appears as a tile in Samsung's own clipboard-*history* grid is undocumented and One-UI-version-dependent — test-on-device, not a guarantee. Clippy's own history surfaces (bubble/menu/app) are the reliable browsable history; we cannot inject into Samsung's panel (§1.1).
- **Floating bubble permission denied:** if `SYSTEM_ALERT_WINDOW` isn't granted, fall back to the Clippy app + Quick Settings tile for history access; capture's overlay tier also degrades to Shizuku/manual.

---

## 10. Testing Strategy

- **`SyncEngine` (highest value):** pure Dart unit tests for every branch of §7 — echo one-shot expiry, re-copy-after-interleave, reconnect dedup via persisted hash, first-snapshot freshness gate, concealed skip, oversize skip, near-simultaneous last-write-wins.
- **`HistoryStore`:** ordering, cap to N, consecutive-hash de-dup, apply-on-tap sets clipboard without re-upload.
- **`CryptoBox`:** round-trip seal/open; fingerprint stability; wrong-key fails to decrypt.
- **`ClipStore`:** against the Firestore emulator — append shape, serverTimestamp, `orderBy/limit` history read, trim, size-cap + immutability rule enforcement, uid-mismatch denied.
- **Platform `ClipboardPort`:** manual + instrumented — macOS changeCount detection & concealed-marker read; Android each capture tier on a real device across Android 12/13/14 and at least one OEM skin; floating bubble apply-on-tap.
- **End-to-end manual matrix:** the 9 success criteria (§2) run by hand on Alwin's Mac + phone before calling v1 done.

---

## 11. Verified Package List (pinned 2026-07-02)

| Package | Version | Role |
|---------|---------|------|
| `google_sign_in` | ^7.2.0 | Google auth (macOS + Android; `authenticate()` flow) |
| `firebase_core` | ^4.11.0 | Firebase init |
| `firebase_auth` | ^6.5.4 | `signInWithCredential` from Google idToken |
| `cloud_firestore` | ^6.6.0 | `clips/{uid}/items` subcollection + history listener |
| `clipboard_watcher` | ^0.3.0 | macOS changeCount polling (or ~15-line custom Swift channel) |
| `tray_manager` | ^0.5.3 | macOS menu-bar icon + history menu |
| `window_manager` | ^0.5.1 | macOS window control |
| `flutter_foreground_task` | ^9.2.2 | Android process keep-alive (main-isolate listener) |
| `mobile_scanner` | select at plan time | QR scan for pairing (Android) |
| `qr_flutter` | select at plan time | QR display for pairing (macOS) |
| Android overlay bubble | native `SYSTEM_ALERT_WINDOW` (+ optional `flutter_overlay_window`) | floating history bubble |
| Shizuku API (native) | — | optional Android "power mode" read tier |

Run `flutterfire configure` to pin mutually compatible Firebase versions rather than hand-editing.

**macOS setup cost to budget:** `keychain-access-groups` + `com.apple.security.network.client` entitlements in both Debug and Release; **mandatory real code-signing** (keychain-based Google/Firebase auth fails on unsigned builds); first `cloud_firestore` macOS build is 10–20 min (full C++ SDK via CocoaPods).

---

## 12. Roadmap (post-v1, non-binding)

- **Product phase (multi-user):** requires Blaze plan. Spark limits are per-project (~80 active users/day before history multiplies reads). Add high-priority FCM wake-up (drops into the v1 write path), per-device envelope keys, account management.
- **Clippy keyboard (IME):** an in-keyboard history view that also captures Android copies for free (keyboards bypass the clipboard focus gate) — the deferred "history in a keyboard" experience, at the cost of a large keyboard build.
- **v2 content:** images (blob storage / chunked), then files.
- **Bigger/pinned history, search, favorites** over the capped list.
- **Railway relay migration (planned):** replace the Firestore `ClipStore` with a Dart WebSocket relay + SQLite-on-volume on Railway Hobby ($5, ~$3 usage). Flat/predictable cost, container-scaled for multi-user, a held-open WebSocket from the Android FGS for instant background delivery (no Blaze/FCM), server-side Google ID-token verification. Contained to the `ClipStore` implementation; `SyncEngine` and UI unaffected.
- **LAN fast-path:** mDNS + direct TLS as a same-network optimization layered under the sync channel.
- **Windows/Linux:** blocked on `google_sign_in` (no desktop-Linux/Windows support) — would need a different auth path.

---

## Appendix: Decisions log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Audience | Personal now, product later | Email-scoped path already isolates per-account. |
| Framework | Flutter, one codebase | "Compatible everywhere"; single Dart `SyncEngine`. |
| Backend | Firebase Spark (free) | Zero cost; comfortably within limits incl. capped history. |
| Backend timing | Firebase now, **Railway relay when going public** | Test fast on the free tier; the `ClipStore` interface (§4.5) + transport-agnostic `SyncEngine` (§7) are the migration seam, so the swap is one implementation class, not a rewrite. A persistent-WebSocket relay also removes the Android background-listener risk and the need for Blaze-gated FCM at that point. |
| Auth | Google Sign-In → Firebase uid | "Same email = same clipboard." |
| Content | Text only (v1) | Covers the vast majority of copy/paste; images deferred. |
| Sync model | **Latest → system clipboard + Clippy-owned browsable history** | Latest item flows into any keyboard (incl. Samsung) with no taps; full history browsable in Clippy since keyboard panels are closed (§1.1). |
| History size | Capped at N=25, trimmed | Keeps Firestore tiny and the listener cheap; bigger/pinned history is roadmap. |
| Phone history access | Floating bubble (`SYSTEM_ALERT_WINDOW`) + app + QS tile | Available while typing without replacing the Samsung keyboard; reuses the capture overlay permission. Clippy keyboard deferred. |
| Android capture | READ_LOGS+overlay primary; Shizuku power-mode; manual fallback | Only proven no-root background-read paths; appops grant does NOT bypass focus. |
| E2E encryption | Yes, v1 | Clipboards carry passwords/OTPs/seed phrases; every history item encrypted. |
| FCM wake-up | No, v1 (Blaze-gated) | Free tier can't run the trigger Function; resync-on-resume instead. |
| Concealed clips | Skip | Never sync or store password-manager clips. |
| Freshness gate | 60s, first snapshot only | Guards cold-start clobber without discarding late Doze deliveries. |
