#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-Debug}"
DERIVED="$ROOT/.build/DerivedData"

xcodebuild \
  -project FileFormatter.xcodeproj \
  -scheme FileFormatter \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED" \
  build

APP="$DERIVED/Build/Products/$CONFIGURATION/FileFormatter.app"
echo "built: $APP"
