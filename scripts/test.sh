#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Rust tests"
(cd rust && cargo test --locked)

echo "==> Swift package tests"
(cd Packages/FileFormatterCore && swift test)

echo "==> App build"
./scripts/build.sh Debug

echo "==> App self-test"
APP="$ROOT/.build/DerivedData/Build/Products/Debug/FileFormatter.app"
rm -f /tmp/fileformatter-selftest.txt
"$APP/Contents/MacOS/FileFormatter" --self-test > /tmp/fileformatter-selftest-stdout.txt 2>&1 &
PID=$!
for _ in $(seq 1 40); do
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  if [ -f /tmp/fileformatter-selftest.txt ] && grep -q "SELF-TEST" /tmp/fileformatter-selftest.txt; then break; fi
  sleep 0.5
done
if kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi
cat /tmp/fileformatter-selftest.txt 2>/dev/null || true
grep -q "SELF-TEST PASS" /tmp/fileformatter-selftest.txt
