# Windows code signing & SmartScreen

## Problem

Windows SmartScreen warns on `Clippy-Setup.exe` when the file is **unsigned**
or the publisher has **no reputation**. Users see "Windows protected your PC"
and must click **More info → Run anyway**.

## What actually fixes it

| Approach | Fixes "Unknown publisher"? | Instant no-SmartScreen? | Cost |
|----------|----------------------------|-------------------------|------|
| Do nothing (current default) | No | No | €0 |
| Sign with OV/cloud Authenticode | Yes (shows publisher name) | **No** — reputation still builds | ~€200–700/yr |
| Sign with EV | Yes | **No** (as of 2026 Microsoft policy) | higher |
| Azure Trusted Signing | Yes | No (reputation) | Azure metered |
| Microsoft Store | Microsoft-signed | Best UX | Store account |

**There is no free way to fully eliminate SmartScreen.** Signing is the
minimum professional fix; reputation then accumulates as people install.

## Clippy CI (already wired)

After Inno builds `Clippy-Setup.exe`, CI runs `signtool` **if** secrets exist:

- `WINDOWS_CERT_PFX_BASE64`
- `WINDOWS_CERT_PASSWORD`

Without secrets, build succeeds **unsigned** (same as before).

## How to enable signing

1. Buy an **OV code signing** cert that can export a PFX for CI, **or** use
   Azure Trusted Signing (cloud, no USB token in some flows).
2. Export PFX, base64 it:
   ```bash
   base64 -i ClippyCodeSign.pfx | pbcopy   # macOS
   ```
3. GitHub → repo → Settings → Secrets:
   - `WINDOWS_CERT_PFX_BASE64`
   - `WINDOWS_CERT_PASSWORD`
4. Push to `main` — Windows job should log `Clippy-Setup.exe signed and verified`.

## Installer identity

`windows/installer.iss` uses a permanent `AppId` and injects `AppVersion` from
`pubspec.yaml` at build time. Do not change the AppId GUID.
