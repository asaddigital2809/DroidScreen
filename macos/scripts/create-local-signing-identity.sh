#!/usr/bin/env bash
# Creates a self-signed code-signing identity "DroidScreen Local Signing" in the login keychain.
#
# Why: macOS privacy permissions (Screen Recording, Accessibility) are tied to the app's code
# signature. Ad-hoc builds get a new identity on every rebuild, so the permissions stop applying.
# A fixed local certificate keeps the identity stable across rebuilds on this Mac.
#
# The certificate is for local development only (not for distribution; use Developer ID for that).
# Remove it with:  security delete-identity -c "DroidScreen Local Signing"
set -euo pipefail

NAME="DroidScreen Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="$(openssl rand -hex 16)"

# /usr/bin/openssl is LibreSSL; Homebrew OpenSSL 3 needs -legacy for a PKCS#12 macOS can import.
LEGACY=""
if openssl version | grep -q "^OpenSSL 3"; then LEGACY="-legacy"; fi

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

# -T /usr/bin/codesign lets codesign use the key without a keychain prompt.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\" in the login keychain."
