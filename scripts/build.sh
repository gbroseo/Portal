#!/bin/bash
# Builds a universal (Intel + Apple Silicon) 传送门.app and DMG. Only needs the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUM="${BUILD_NUM:-$(date +%Y%m%d%H%M)}"
APP_NAME="传送门"
EXE="Portal"
OUT="build"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/Portal-$VERSION-universal.dmg"

rm -rf "$OUT"
mkdir -p "$OUT"

SOURCES=(Sources/*.swift)
FLAGS=(-swift-version 5 -O -whole-module-optimization -framework AppKit -framework Network -framework ServiceManagement)

echo "==> compiling x86_64"
swiftc "${FLAGS[@]}" -target x86_64-apple-macos12 "${SOURCES[@]}" -o "$OUT/$EXE-x86_64"
echo "==> compiling arm64"
swiftc "${FLAGS[@]}" -target arm64-apple-macos12 "${SOURCES[@]}" -o "$OUT/$EXE-arm64"
lipo -create "$OUT/$EXE-x86_64" "$OUT/$EXE-arm64" -output "$OUT/$EXE"

echo "==> bundling"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/$EXE" "$APP/Contents/MacOS/$EXE"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> icon"
swiftc -O scripts/make_icon.swift -o "$OUT/make_icon"
"$OUT/make_icon" "$OUT/AppIcon.iconset" >/dev/null
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Stable identity (shared with 全能截图) keeps macOS privacy grants across updates; ad-hoc elsewhere.
SIGN_KC="$HOME/Library/Keychains/quanneng-signing.keychain-db"
SIGN_ID="QuanNengJieTu Local Signing"
if [ -f "$SIGN_KC" ]; then
  echo "==> signing ($SIGN_ID)"
  security unlock-keychain -p quanneng-local "$SIGN_KC"
  codesign --force --sign "$SIGN_ID" --keychain "$SIGN_KC" --identifier com.gbroseo.portal "$APP"
else
  echo "==> signing (ad-hoc)"
  codesign --force --sign - --identifier com.gbroseo.portal "$APP"
fi
codesign --verify --strict "$APP"

echo "==> dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/安装说明.txt" "$STAGE/"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "==> done: $DMG"
