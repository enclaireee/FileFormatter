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
hdiutil create -volname FileFormatter -srcfolder "dist/FileFormatter.app" -ov -format UDZO "dist/FileFormatter-$VERSION.dmg" >/dev/null
codesign --force --deep --sign - "dist/FileFormatter.app"
(cd dist && shasum -a 256 "FileFormatter-$VERSION.zip" "FileFormatter-$VERSION.dmg" > checksums.txt)
echo "packaged dist/FileFormatter-$VERSION.dmg"
cat dist/checksums.txt
