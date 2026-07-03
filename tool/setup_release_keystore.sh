#!/usr/bin/env bash
#
# One-shot: create a PERMANENT Android release keystore and store it (plus its
# credentials) as GitHub Actions secrets, so every CI build is signed with the
# same key. Once this is done, app updates install over the old version -- no
# more uninstall/reinstall.
#
# Run it ONCE, on your own machine:   ! bash tool/setup_release_keystore.sh
#
# Nothing sensitive is printed. The password is randomly generated here, goes
# straight into the keystore + the GitHub secret, and is never echoed. The
# keystore file is saved OUTSIDE the repo -- back it up (see the final note).
#
# ASCII only on purpose: macOS's /bin/bash folds multibyte chars into adjacent
# $variables under `set -u`, so no fancy punctuation in this file.
set -euo pipefail

REPO="alwinpaul1/clippy"
KEYSTORE="$HOME/.clippy/clippy-release.jks"
ALIAS="clippy"

command -v keytool >/dev/null || { echo "keytool not found (install a JDK)"; exit 1; }
command -v gh      >/dev/null || { echo "gh not found"; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first."; exit 1; }

if [ -f "$KEYSTORE" ]; then
  echo "A keystore already exists at:"
  echo "  $KEYSTORE"
  echo "Refusing to overwrite it -- reusing an existing key is the whole point."
  exit 1
fi

mkdir -p "$(dirname "$KEYSTORE")"

# Strong random password; never printed.
PASS="$(openssl rand -base64 24)"

echo "Generating a 4096-bit RSA release key (valid ~27 years)..."
keytool -genkeypair \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$PASS" -keypass "$PASS" \
  -dname "CN=Clippy, OU=Clippy, O=Clippy, L=., ST=., C=US"

echo "Uploading secrets to ${REPO} ..."
base64 < "$KEYSTORE"  | gh secret set ANDROID_KEYSTORE_BASE64   --repo "$REPO"
printf '%s' "$PASS"   | gh secret set ANDROID_KEYSTORE_PASSWORD --repo "$REPO"
printf '%s' "$ALIAS"  | gh secret set ANDROID_KEY_ALIAS         --repo "$REPO"

echo ""
echo "[OK] Done. The next CI build will be release-signed with this permanent key."
echo "     Keystore : $KEYSTORE"
echo "     Secrets  : ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS"
echo ""
echo "[!!] BACK UP THAT KEYSTORE FILE (copy it to a password manager / cloud vault)."
echo "     If you ever lose it, you can never ship an update to installed apps"
echo "     again. The password lives only in the keystore and the GitHub secret;"
echo "     it was never shown here."
