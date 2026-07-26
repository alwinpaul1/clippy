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

### Option A — classic PFX (already wired in CI)

1. Obtain an **OV** Authenticode cert (HSM/cloud export to PFX if required).
2. Base64 the PFX:
   ```bash
   base64 -i ClippyCodeSign.pfx | pbcopy   # macOS
   ```
3. GitHub → repo → Settings → Secrets:
   - `WINDOWS_CERT_PFX_BASE64`
   - `WINDOWS_CERT_PASSWORD`
4. Push to `main` — Windows job logs `Clippy-Setup.exe signed and verified`.

### Option B — Azure Artifact Signing (~$10/mo if eligible)

Not wired by default (needs Azure identity setup). Pattern:

1. Azure Artifact Signing account + certificate profile  
2. Entra app + OIDC federated credential for this GitHub repo  
3. Secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`  
4. Job uses `azure/login` + `azure/artifact-signing-action` on `Clippy-Setup.exe`  

Geo/eligibility limits apply (see Microsoft docs).

## Installer identity

`windows/installer.iss` uses a permanent `AppId` and injects `AppVersion` from
`pubspec.yaml` at build time. Do not change the AppId GUID.
