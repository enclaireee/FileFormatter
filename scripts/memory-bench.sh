#!/usr/bin/env bash
# Memory regression check. Builds a Release app with the BENCH flag (separate bundle id and a temp home, so your
# settings, history and installed app are untouched), loops every heavy feature for N minutes, and fails if the
# footprint keeps climbing. Usage: scripts/memory-bench.sh [minutes, default 5]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MINUTES="${1:-5}"
DERIVED="$ROOT/.build/BenchDerivedData"
OUT="$ROOT/.build/memory-bench"
BUNDLE_ID="com.taufan.fileformatter.bench"
mkdir -p "$OUT"

xcodebuild \
  -project FileFormatter.xcodeproj \
  -scheme FileFormatter \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) BENCH' \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  -quiet build >"$OUT/build.log" 2>&1 || { grep -E "error:" "$OUT/build.log" | head -20; exit 1; }

APP="$DERIVED/Build/Products/Release/FileFormatter.app"
codesign --force --deep --sign - "$APP" 2>/dev/null  # same ad-hoc signing as package.sh, so Sparkle loads
FAKE_HOME="$(mktemp -d)"
CSV="$OUT/bench-$(date +%Y%m%d-%H%M%S).csv"
cleanup() { rm -rf "$FAKE_HOME"; defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Only LaunchServices applies Info.plist's LSEnvironment, so pass it on by hand to measure what ships.
LARGE_CACHE="$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:MallocLargeCache' "$APP/Contents/Info.plist" 2>/dev/null || true)"
env ${LARGE_CACHE:+MallocLargeCache="$LARGE_CACHE"} CFFIXED_USER_HOME="$FAKE_HOME" "$APP/Contents/MacOS/FileFormatter" --memory-bench "$MINUTES" "$CSV" >"$OUT/bench.log" 2>&1 &
PID=$!

# The app logs its own footprint; this adds child processes (ffmpeg) to catch the whole-tree peak.
footprint_mb() {
  footprint "$1" 2>/dev/null | awk '/Footprint:/{for(i=1;i<=NF;i++) if($i=="Footprint:"){v=$(i+1);u=$(i+2)}
    if(u=="KB")v/=1024; if(u=="GB")v*=1024; print v; exit}'
}
TREE_PEAK=0
while kill -0 "$PID" 2>/dev/null; do
  total=0
  for p in $PID $(pgrep -P "$PID" || true); do total=$(echo "$total + $(footprint_mb "$p" || echo 0)" | bc); done
  TREE_PEAK=$(echo "if ($total > $TREE_PEAK) $total else $TREE_PEAK" | bc)
  sleep 2
done
wait "$PID" || { echo "bench failed:"; tail -20 "$OUT/bench.log"; exit 1; }

echo "csv: $CSV"
awk -F, -v tree="$TREE_PEAK" '
  NR == 1 { next }
  $1 == "launch" || $1 == "popover-first" || $1 == "idle-30s" { printf "%-14s %8.1f MB\n", $1, $3; next }
  {
    if (!($1 in first)) { first[$1] = $3; order[++n] = $1 }
    last[$1] = $3; if ($4 > peak[$1]) peak[$1] = $4; passes = $2
    if ($1 == "popover") end[$2] = $3
  }
  END {
    printf "%-14s %8s %8s %8s\n", "step", "first", "last", "peak"
    for (i = 1; i <= n; i++) printf "%-14s %8.1f %8.1f %8.1f\n", order[i], first[order[i]], last[order[i]], peak[order[i]]
    printf "passes %d, process-tree peak %.1f MB\n", passes, tree
    if (passes < 3) { print "plateau: too few passes to judge"; exit 0 }
    # Mean footprint after each pass: the last third must not sit >10% above the middle third.
    a = int(passes / 3); b = int(2 * passes / 3)
    for (p = a + 1; p <= b; p++) { mid += end[p]; mn++ }
    for (p = b + 1; p <= passes; p++) { tail += end[p]; tn++ }
    mid /= mn; tail /= tn
    printf "plateau: middle third %.1f MB, last third %.1f MB\n", mid, tail
    if (tail > mid * 1.10) { print "FAIL: memory still growing"; exit 1 }
    print "PASS"
  }' "$CSV"
