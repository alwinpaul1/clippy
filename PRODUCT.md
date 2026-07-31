# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

Primary design target is the Flutter client, which ships to **Android, macOS, and
Windows from one shared design language** — not per-OS native chrome. Android is
recorded as the platform because it is the only target with native affordances
that constrain design (foreground service, accessibility service, share sheet,
system install prompt); macOS and Windows render the same widgets inside a tray
app shell. The web download page at `clippy.alwinpaul.me` (`server/web/index.html`)
is a **second, separately-designed surface** and gets its own surface brief; it
does not share this platform value.

## Users

Public users being actively grown — not a private tool. The primary user runs
**more than one OS at once** (typically a Mac or Windows desktop plus an Android
phone) and hits the same wall daily: something copied on one machine is
unreachable on the other. Their job is small and constant — move a link, a code,
an address, or a screenshot across the gap without emailing or messaging it to
themselves.

They arrive cold, from a link or a search, with no account and no prior trust in
the maintainer. Two moments therefore carry disproportionate weight: **deciding
to install an unsigned binary from an unknown domain**, and **pairing two devices
successfully on the first try**. Everything after that is a background utility
they should rarely have to look at.

## Product Purpose

Keep one shared, end-to-end encrypted clipboard across the devices a person
pairs, so a copy on any device is a paste on any other. Success is invisibility:
the clip is simply already there. The product is doing its job when the user
stops opening it.

## Positioning

A **zero-knowledge clipboard room with no account at all.** Devices exchange a
256-bit master key by QR (or pasted text); clips are encrypted on-device with
AES-256-GCM (per-purpose keys derived via HMAC-SHA256), and the relay sees only
opaque room tokens and ciphertext — never plaintext, keys, or an identity.

The neighbours cannot truthfully copy this: Apple's Universal Clipboard requires
one vendor's ecosystem, and the cross-platform alternatives require a sign-in and
a server that can read the clip. Clippy crosses **macOS ↔ Windows ↔ Android** and
has nothing to sign in to. Free, MIT-licensed, source public.

Name collision is a known, permanent fact of the market: search results mix this
product with Microsoft Office's assistant and the Rust `clippy` linter. Anything
public-facing must disambiguate on its own rather than assume the name does.

## Operating Context

- **First run is a pairing ritual, not an onboarding funnel.** One device
  generates the group key and shows a QR; the other scans it or pastes the key.
  Same key = same room. There is no recovery flow — the key is the product.
- **The app is normally not in the foreground.** macOS menu-bar / Windows system
  tray with hide-on-close; on Android a foreground service plus an accessibility
  service capture copies (including the Chrome URL bar) and synced screenshots
  while the app is closed.
- **Android asks for unusual trust before it works.** Enabling background sync
  walks the user through an accessibility-service grant, a display-over-apps
  overlay grant, battery-optimization exemption, and media access — permissions
  that read as alarming out of context and need to be explained where they are
  requested, not in a help page.
- **Distribution is direct-download, not a store.** All three builds come from
  `clippy.alwinpaul.me`; the app then self-updates in place from the same host.
  Windows shows a SmartScreen warning while the installer is unsigned.
- **Networks are unreliable by assumption.** Clips queue on-device and deliver on
  reconnect; the UI has a real, frequently-seen reconnecting state.

## Capabilities and Constraints

Confirmed and shipping (current release `1.0.35+42`, `pubspec.yaml`):

- Text and image clips; images sync as original bytes with no re-encode.
- Browsable history with re-copy, multi-select delete, and clear-the-room.
- Ack protocol with retries and idempotent resends — no silent drops or dupes.
- Light / Dark / System appearance, user-selectable in Settings.
- In-app update on all three platforms. The manifest carries a per-platform
  SHA-256 digest, and artifact downloads are pinned to the manifest's exact
  origin — scheme, host, **and** port (`lib/core/update/update_service.dart`).
- Relay: single Dart WebSocket service (`wss://clippy.alwinpaul.me`) in Docker
  behind Caddy, which also serves the download page and the update manifest.

Hard constraints:

- **No third-party analytics or telemetry in the app.** `lib/` contains no
  analytics SDK and must not gain one; GA4 exists only on the web download page.
- **Artifact filenames are a contract** with the updater
  (`Clippy-Android.apk`, `Clippy-macOS.zip`, `Clippy-Setup.exe`).
- **Android signing is unrecoverable.** One permanent keystore, held only as a CI
  secret; losing it means no existing install can ever be updated again.
- Release is triggered by `pubspec.yaml` + `release.json` merged to `main`; the
  changelog users read is generated from `release.json`.

Explicitly undecided — do not present as shipped:

- **iOS and Linux.** No `ios/` or `linux/` target exists in the repo. The stale
  brief in `docs/frontend-design-brief.md` calls iPhone "planned"; that is not a
  commitment and must not appear as one.
- Whether the app UI keeps its current visual identity (see Brand Commitments).

## Brand Commitments

Binding — do not change without asking:

- **The paperclip-with-eyes mascot** is the identity mark across the app icon,
  the favicon, and the OG image. Knowingly a wink at the old Office assistant.
- **No account, QR pairing, zero-knowledge relay.** No sign-in, no email, no
  server-readable clip may be designed in. The relay stays a ciphertext router.
- Name and home: **Clippy**, `clippy.alwinpaul.me`, MIT, © Alwin Paul.

Current state, explicitly **not** binding — evidence for a redesign, not a rule:

- The warm editorial palette in `lib/app/theme.dart` (cream `#F4F1EA`, deep-green
  `#1F4B3F`, rust `#9A4432`, ink `#1E1C15`), light and warm-ink dark.
- The landing page's matching cream/green treatment.

**Known-stale document:** `docs/frontend-design-brief.md` describes a Material-3
purple seed (`#6C4DF6` / `#5B8DEF`) that the code abandoned. It is an
out-of-date artifact, not visual authority. Do not design from it.

## Evidence on Hand

Real and usable:

- Live product and download page — `clippy.alwinpaul.me`; source
  `server/web/index.html` (SEO metadata, OG card, JSON-LD, sitemap, robots).
- Three real downloadable builds, plus `version.json` as the live update manifest.
- Icon and mascot artwork in `assets/icon/`; `server/web/og.png`.
- Public source, CI, and license — `github.com/alwinpaul1/clippy`, MIT.
- GA4 web stream on the download page only (page_view + download events).

Absences future work must not paper over:

- **No testimonials, reviews, user counts, star counts, press, or case studies.**
  The repo is young and has effectively no social proof. Do not invent any, and
  do not design a slot that only looks right once filled with fabricated proof.
- **No pricing or licensing tiers.** It is free; there is no paid plan to imply.
- **No uptime, latency, or benchmark numbers** have been measured.
- **The Windows installer is currently unsigned.** A SignPath Foundation
  application was submitted 2026-07-27 and is still pending; nothing may claim
  signed builds until those CI secrets are live and a signed build ships.

## Product Principles

1. **Invisible when it works.** The best session is one the user never opens.
   Ambient state — synced, reconnecting, caught up — outranks decoration.
2. **Earn install-time trust, because nothing else will.** No store badge, no
   brand recognition, an unsigned Windows binary, and a name that collides with
   two other things. Public surfaces must do the reassuring themselves.
3. **Pairing must succeed on the first attempt.** It is the only hard step, it
   happens on two devices at once, and there is no account to fall back on.
4. **Explain scary permissions at the moment of asking.** Accessibility service
   and screen overlay are legitimately alarming; the cost of an unexplained
   prompt is an abandoned install.
5. **The clipboard holds secrets.** It carries passwords and 2FA codes. Never
   design something that broadcasts, previews, or logs clip contents where the
   user did not ask for it.

## Accessibility & Inclusion

No product-specific standard has been established. Two facts are load-bearing
for future work: the app ships a user-controlled **Light / Dark / System** mode
that any new UI must honor dynamically, and "accessibility" in this codebase
usually means Android's **AccessibilityService capture API**, not inclusive
design — keep the two apart in copy and in code review.
