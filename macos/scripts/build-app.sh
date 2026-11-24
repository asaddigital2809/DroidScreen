#!/usr/bin/env bash
# Builds DroidScreen.app from the SwiftPM package.
#
#   scripts/build-app.sh
#       Release build. Signing identity, in order of preference:
#         1. $SIGN_IDENTITY if set ("-" forces ad-hoc)
#         2. "DroidScreen Local Signing" (created by scripts/create-local-signing-identity.sh)
#         3. ad-hoc
#       A stable identity (1 or 2) keeps Screen Recording / Accessibility permissions across rebuilds.
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#       Hardened runtime + secure timestamp, ready for notarization.
#
# Output: macos/build/DroidScreen.app
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/DroidScreen.app"
LOCAL_IDENTITY="DroidScreen Local Signing"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  # Use the certificate hash so an identically named certificate elsewhere cannot be picked.
  LOCAL_HASH="$(security find-identity -p codesigning 2>/dev/null | awk -v n="\"$LOCAL_IDENTITY\"" '$0 ~ n {print $2; exit}')"
  SIGN_IDENTITY="${LOCAL_HASH:--}"
fi

swift build -c "$CONFIG" --product DroidScreenHost
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DroidScreenHost"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DroidScreenHost"
cp Resources/Info.plist "$APP/Contents/Info.plist"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --entitlements Resources/DroidScreenHost.entitlements)
if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP" 2>/dev/null || codesign --verify "$APP"
echo "Signed with: $([[ "$SIGN_IDENTITY" == "-" ]] && echo ad-hoc || echo "$SIGN_IDENTITY")"
echo "Built $(pwd)/$APP"
