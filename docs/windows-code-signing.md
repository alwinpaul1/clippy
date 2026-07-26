# Windows code signing & SmartScreen

## Problem

Windows SmartScreen warns on `Clippy-Setup.exe` when the file is **unsigned**
or the publisher has **no reputation**. Users see "Windows protected your PC"
and must click **More info → Run anyway**.

## Best free path: SignPath Foundation (open source)

Microsoft documents [SignPath Foundation](https://signpath.org) as free
OV-level signing for **qualifying open-source** projects.

### Clippy is prepared for this

| Requirement | Status in repo |
|-------------|----------------|
| Public GitHub repo | Yes (`alwinpaul1/clippy`) |
| OSI-approved license | **MIT** (`LICENSE`) |
| Code signing policy | Maintainer docs only (not public) |
| GitHub Actions build of installer | Yes (`build-windows` job) |
| CI hook for SignPath | Yes (optional secrets) |

### What you (Alwin) must still do once

1. Enable **2FA** on GitHub.
2. Apply at <https://signpath.org/> (or SignPath.io open-source program).
3. Install the [SignPath GitHub App](https://github.com/apps/signpath) on the repo.
4. Create the SignPath project + artifact configuration for `Clippy-Setup.exe`
   (often a zip wrapper per their docs).
5. Add GitHub secrets (from the SignPath dashboard after approval):

   | Secret | Meaning |
   |--------|---------|
   | `SIGNPATH_API_TOKEN` | API token with submit permission |
   | `SIGNPATH_ORGANIZATION_ID` | Org UUID |
   | `SIGNPATH_PROJECT_SLUG` | Project slug |
   | `SIGNPATH_SIGNING_POLICY_SLUG` | Policy slug (e.g. `release-signing`) |
   | `SIGNPATH_ARTIFACT_CONFIGURATION_SLUG` | Artifact config slug |

6. Approve the first signing requests in the SignPath UI (OSS requires approvers).

Until approval, CI still ships an installer (unsigned or PFX-signed).

### SignPath constraints to accept

- Publisher name may appear as **SignPath Foundation** (their cert).
- Only **GitHub-hosted** runners for OSS.
- Each release may need a **manual approver** click.
- Project must stay MIT/OSI without proprietary dual-license.

## Other free option: Microsoft Store (MSIX)

Store **MSIX** packages are re-signed by Microsoft (no cert purchase). That is a
**different distribution channel** from VPS `Clippy-Setup.exe`. See Microsoft’s
code-signing options doc.

## Paid fallbacks (if SignPath rejects you)

| Path | Ballpark |
|------|----------|
| Azure Artifact Signing | ~$9.99/mo (geo limits: individuals US/CA) |
| OV Authenticode + CI PFX | ~$150–300+/yr |

### PFX secrets already supported in CI

- `WINDOWS_CERT_PFX_BASE64`
- `WINDOWS_CERT_PASSWORD`

## Installer identity

`windows/installer.iss` uses a permanent `AppId` and injects `AppVersion` from
`pubspec.yaml`. **Never regenerate the AppId.**

## Honest limits (2026)

- **EV does not** auto-clear SmartScreen anymore.
- Even signed builds may warn until **download reputation** builds.
- **Self-signed** is free but **worse** for public users — do not use for VPS downloads.
