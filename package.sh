#!/bin/zsh
set -euo pipefail

# Package Desk Bot as a DMG (drag-to-Applications) and a zip.
# Signs with Developer ID Application and notarizes only if a
# Developer ID identity is already on this Mac. Does not create
# certificates. Does not install or launch the app. Does not
# publish anything.

ROOT="${0:A:h}"
APP_NAME="Desk Bot"
IDENT="com.thewoodlab.DeskBot"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
DIST="$ROOT/dist"
BUILD_APP="$ROOT/build/$APP_NAME.app"
STATUS="$DIST/SIGNING-STATUS.txt"

mkdir -p "$DIST"

"$ROOT/build.sh"

if [ ! -d "$BUILD_APP" ]; then
  echo "Build failed; no $BUILD_APP" >&2
  exit 1
fi

# Detect a Developer ID Application identity. Do not create one.
DEV_ID=""
if command -v security >/dev/null; then
  DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'\"' '/Developer ID Application/ { print $2; exit }' || true)"
fi

NOTARIZED=0
LABEL="NOT-NOTARIZED-REVIEW"

if [ -n "$DEV_ID" ]; then
  echo "Found Developer ID identity: $DEV_ID"
  echo "Signing with hardened runtime …"
  codesign --force --sign "$DEV_ID" --identifier "$IDENT" \
    --options runtime --timestamp "$BUILD_APP"
  codesign --verify --verbose=2 "$BUILD_APP"

  # Prefer an existing notarytool keychain profile. Do not invent credentials.
  PROFILE=""
  for cand in "notarytool" "AC_PASSWORD" "TheWoodLab" "woodlab"; do
    if xcrun notarytool history --keychain-profile "$cand" >/dev/null 2>&1; then
      PROFILE="$cand"
      break
    fi
  done

  if [ -n "$PROFILE" ]; then
    echo "Submitting to Apple notary service with profile $PROFILE …"
    ZIP_FOR_NOTARY="$DIST/Desk-Bot-${VERSION}-for-notary.zip"
    ditto -c -k --keepParent "$BUILD_APP" "$ZIP_FOR_NOTARY"
    SUBMIT_OUT="$(xcrun notarytool submit "$ZIP_FOR_NOTARY" --keychain-profile "$PROFILE" --wait)"
    echo "$SUBMIT_OUT"
    if echo "$SUBMIT_OUT" | grep -q "status: Accepted"; then
      xcrun stapler staple "$BUILD_APP"
      NOTARIZED=1
      LABEL="notarized"
    else
      echo "Notarization did not succeed. Packaging a signed but un-notarized review build."
    fi
    rm -f "$ZIP_FOR_NOTARY"
  else
    echo "No notarytool keychain profile found. Skipping notarization."
    echo "An App Store Connect issuer id (or a stored notary profile) is also required if you use an API key."
  fi
else
  echo "No 'Developer ID Application' certificate in the keychain."
  echo "Packaging an ad-hoc signed review build. It is not notarized."
  echo "Do not publish this build. Create a Developer ID Application certificate in the Apple Developer account, then re-run package.sh."
fi

STAGE="$DIST/dmgroot"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$BUILD_APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/Desk-Bot-${VERSION}-${LABEL}.dmg"
ZIP="$DIST/Desk-Bot-${VERSION}-${LABEL}.zip"
rm -f "$DMG" "$ZIP"

hdiutil create -volname "Desk Bot" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

ditto -c -k --keepParent "$BUILD_APP" "$ZIP"

{
  echo "Desk Bot ${VERSION} package"
  echo "Date: $(date)"
  echo "App: $BUILD_APP"
  echo "DMG: $DMG"
  echo "ZIP: $ZIP"
  if [ -n "$DEV_ID" ]; then
    echo "Signing identity: $DEV_ID"
  else
    echo "Signing identity: ad-hoc (no Developer ID Application certificate found)"
  fi
  if [ "$NOTARIZED" -eq 1 ]; then
    echo "Notarization: stapled"
  else
    echo "Notarization: not performed"
  fi
  echo
  echo "This script never installs or launches the app, and never writes to ~/Applications/Bruce Buddy.app."
} | tee "$STATUS"

ls -lh "$DMG" "$ZIP" "$STATUS"
