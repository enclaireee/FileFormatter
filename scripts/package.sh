#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/build.sh Release
APP="$ROOT/.build/DerivedData/Build/Products/Release/FileFormatter.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

[ -d "$APP/Contents/Resources/Models/BiRefNetLite.mlmodelc" ] || { echo "error: HD background model missing; run make bootstrap-model"; exit 1; }

rm -rf dist
mkdir -p dist
ditto "$APP" "dist/FileFormatter.app"
codesign --force --deep --sign - "dist/FileFormatter.app"
ditto -c -k --keepParent "dist/FileFormatter.app" "dist/FileFormatter-$VERSION.zip"
# DMG opens to the app next to an Applications shortcut for drag-to-install.
STAGE="$(mktemp -d)"
ditto "dist/FileFormatter.app" "$STAGE/FileFormatter.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname FileFormatter -srcfolder "$STAGE" -ov -format UDZO "dist/FileFormatter-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
# Keep only publishable artifacts in dist: Spotlight indexes a staged .app bundle
# and shows it as a second installed copy.
rm -rf "dist/FileFormatter.app"
(cd dist && shasum -a 256 "FileFormatter-$VERSION.zip" "FileFormatter-$VERSION.dmg" > checksums.txt)
echo "packaged dist/FileFormatter-$VERSION.dmg"
cat dist/checksums.txt

# Sparkle feed (D-027): signs the zip with the EdDSA key in the login Keychain. Publishing stays manual.
SPARKLE_BIN="$ROOT/.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
FEED="$(mktemp -d)"
cp "dist/FileFormatter-$VERSION.zip" "$FEED/"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/enclaireee/FileFormatter/releases/download/v$VERSION/" "$FEED"
mv "$FEED/appcast.xml" dist/appcast.xml
grep -q 'sparkle:edSignature' dist/appcast.xml && grep -q 'sparkle-signatures' dist/appcast.xml \
  || { echo "error: appcast or update unsigned; is the Sparkle key in the login Keychain?"; exit 1; }
rm -rf "$FEED"
echo "publish with:"
echo "  gh release create v$VERSION dist/FileFormatter-$VERSION.zip dist/FileFormatter-$VERSION.dmg dist/appcast.xml dist/checksums.txt"
