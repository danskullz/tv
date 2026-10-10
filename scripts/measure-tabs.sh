#!/bin/zsh
# Measures Marquee's tab-switch cost from the perf log.
#
#   scripts/measure-tabs.sh [launch flags...]
#
# Bundles the release binary, launches it with MARQUEE_PERF=1 and MARQUEE_TABS=<passes>, and lets
# the app walk every sidebar item in-app. Driving it in-app (rather than with synthetic keystrokes)
# avoids needing an Accessibility grant, and goes through the same AppModel.go(to:) as a real click.
#
#   scripts/measure-tabs.sh -mockData YES
#   scripts/measure-tabs.sh -tmdbFixtures YES

set -u
ROOT="$(cd "$(dirname "${AASH_SOURCE[0]:-${(%):-%N}}")/.." && pwd)"
BIN="$ROOT/.build/release/Marquee"
APP=/tmp/MarqueePerf.app
LOG=/tmp/marquee-perf.log
PASSES="${PASSES:-2}"

[ -x "$BIN" ] || { echo "error: build first (swift build -c release)" >&2; exit 1; }
"$ROOT/scripts/bundle.sh" "$BIN" "$APP" 0.0.0 >/dev/null 2>&1 || { echo "error: bundle failed" >&2; exit 1; }

pkill -f "MarqueePerf" 2>/dev/null
sleep 1
: > "$LOG"

MARQUEE_PERF=1 MARQUEE_TABS="$PASSES" \
  "$APP/Contents/MacOS/Marquee" -ApplePersistenceIgnoreState YES "$@" >>"$LOG" 2>&1 &

# Long enough for launch, the initial load, and PASSES x 7 x 0.7s of walking.
WAIT=$(( 14 + PASSES * 6 ))
sleep "$WAIT"
pkill -f "MarqueePerf"
sleep 1

echo "=== screen data loads (press -> data ready) ==="
grep -E "Screen\.load" "$LOG" | sed 's/^/  /'
echo "=== data layer ==="
grep -E "RealLibrary|discoverSnapshot|calendarEvents" "$LOG" | sed 's/^/  /'
echo "=== main-thread stalls over 16ms ==="
grep -E "^perf stall" "$LOG" | sed 's/^/  /' | sort -t' ' -k3 -rn | head -25
echo "=== totals ==="
grep -E "SUMMARY" "$LOG" | sed 's/^/  /'
STALLS=$(grep -c "^perf stall" "$LOG")
echo "  stall events: $STALLS"