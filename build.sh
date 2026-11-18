#!/bin/zsh
set -euo pipefail

# Build Desk Bot into ./build only.
# Does NOT install, does NOT touch ~/Applications/Bruce Buddy.app,
# and does not launch the app.

ROOT="${0:A:h}"
APP_NAME="Desk Bot"
IDENT="com.thewoodlab.DeskBot"
MIN_OS="14.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "Building $APP_NAME (universal, macOS ${MIN_OS}+) into $BUILD_DIR …"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS" "$RES" "$BUILD_DIR/obj"

FRAMEWORKS=(
  -framework AppKit
  -framework QuartzCore
  -framework CoreGraphics
  -framework ApplicationServices
  -framework CoreVideo
  -framework ServiceManagement
  -framework UniformTypeIdentifiers
)

SOURCES=(
  "$ROOT/main.swift"
  "$ROOT/Support.swift"
  "$ROOT/Prefs.swift"
  "$ROOT/About.swift"
)

for arch in arm64 x86_64; do
  echo "  compiling $arch …"
  swiftc -parse-as-library -O -swift-version 5 \
    -target "${arch}-apple-macosx${MIN_OS}" \
    "${FRAMEWORKS[@]}" \
    -o "$BUILD_DIR/obj/DeskBot-${arch}" \
    "${SOURCES[@]}"
done

lipo -create \
  -output "$MACOS/$APP_NAME" \
  "$BUILD_DIR/obj/DeskBot-arm64" \
  "$BUILD_DIR/obj/DeskBot-x86_64"
rm -rf "$BUILD_DIR/obj"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/orb-body.png" "$RES/orb-body.png"
cp "$ROOT/Resources/orb-highlights.png" "$RES/orb-highlights.png"
if [ -f "$ROOT/Resources/app-icon.png" ]; then
  cp "$ROOT/Resources/app-icon.png" "$RES/app-icon.png"
fi

ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC="$ROOT/Resources/app-icon.png"
sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns -o "$RES/AppIcon.icns" "$ICONSET"
rm -rf "$ICONSET"

printf 'APPL????' > "$CONTENTS/PkgInfo"

# Ad-hoc sign so the bundle is runnable on this Mac for review.
# Official Developer ID signing and notarization live in package.sh,
# which will stop if no Developer ID Application certificate is present.
codesign --force --sign - --identifier "$IDENT" "$APP"
codesign --verify --verbose=2 "$APP" || true
lipo -info "$MACOS/$APP_NAME"

echo "Built $APP"
echo "This script does not install or launch the app."
