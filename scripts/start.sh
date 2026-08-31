#!/bin/zsh
# Build, sign and launch Bot-Harness. The one command to run the app.
#
#   scripts/start.sh             build and launch
#   scripts/start.sh --reset     empty every bot, conversation and trace first (undoable)
#   scripts/start.sh --fresh     launch against a throwaway home, leaving your real data alone
#   scripts/start.sh --debug     debug build, faster to compile
#
# --fresh is for trying something out: the app gets an empty data directory under /tmp, so
# nothing it does touches the bots you actually keep. --reset is the real thing, and it moves
# your data to a timestamped backup rather than deleting it (see scripts/reset.sh).

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
FRESH=0
RESET=0

for arg in "$@"; do
  case "$arg" in
    --reset) RESET=1 ;;
    --fresh) FRESH=1 ;;
    --debug) CONFIG=debug ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "unknown option: $arg  (try --help)"; exit 2 ;;
  esac
done

(( RESET )) && scripts/reset.sh

scripts/bundle.sh "$CONFIG"

# A second copy running against the same data directory is two writers on one state file, so
# whatever is already open is closed first.
if pgrep -f "BotHarness.app/Contents/MacOS/BotHarness" >/dev/null 2>&1; then
  osascript -e 'tell application "BotHarness" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "BotHarness.app/Contents/MacOS/BotHarness" >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

if (( FRESH )); then
  SCRATCH="/tmp/bot-harness-fresh-$(date +%H%M%S)"
  mkdir -p "$SCRATCH"
  # `open --env` rather than exporting HOME and exec'ing the binary: launching the executable
  # directly gives a process with no window, and only `open` hands the app a real launch
  # context. CFFIXED_USER_HOME is the one Foundation actually reads for Application Support.
  open -n build/BotHarness.app --env HOME="$SCRATCH" --env CFFIXED_USER_HOME="$SCRATCH"
  print -P "%F{green}launched%f  throwaway home at $SCRATCH — your real bots are untouched"
else
  open build/BotHarness.app
  print -P "%F{green}launched%f  Bot-Harness"
fi
