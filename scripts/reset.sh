#!/bin/zsh
# Empty the app's data: every bot, conversation, message and trace.
#
# Nothing is deleted. The whole data directory is *moved* to a timestamped folder beside it,
# so a reset is undoable — the restore command is printed at the end. That is deliberate:
# this directory holds the only copy of every conversation the user has had, and a script
# that shreds it on a typo is not a script worth having.
#
# The API key is put back into the fresh directory, because losing it means going to fetch a
# new one from a website, which is not what "reset the app" is supposed to cost. Pass --keys
# to drop it as well.
#
#   scripts/reset.sh             empty everything, keep the saved API keys
#   scripts/reset.sh --keys      empty everything including the keys
#   scripts/reset.sh --list      show the backups already taken, and do nothing

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$HOME/Library/Application Support/Bot-Harness"
KEEP_KEYS=1

for arg in "$@"; do
  case "$arg" in
    --keys) KEEP_KEYS=0 ;;
    --list)
      # NULL_GLOB, because zsh treats a pattern that matches nothing as an error before the
      # command ever runs — so without it "no backups yet" prints as a failure.
      setopt local_options null_glob
      print -P "%F{cyan}backups in $(dirname "$ROOT")%f"
      backups=("$ROOT".backup-*)
      if (( ${#backups} )); then
        for b in "${backups[@]}"; do print "  $b"; done
      else
        print "  (none)"
      fi
      exit 0 ;;
    *) print -u2 "unknown option: $arg"; exit 2 ;;
  esac
done

if pgrep -f "BotHarness.app/Contents/MacOS/BotHarness" >/dev/null 2>&1; then
  print -P "%F{yellow}Bot-Harness is running — quitting it first so it cannot write over the reset.%f"
  osascript -e 'tell application "BotHarness" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "BotHarness.app/Contents/MacOS/BotHarness" >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

if [[ ! -d "$ROOT" ]]; then
  print -P "%F{green}nothing to reset%f — no data directory at $ROOT"
  exit 0
fi

# What is about to be set aside, counted before it moves so the numbers are real.
BOTS=$(/usr/bin/python3 -c "
import json,sys
try:
    print(len(json.load(open('$ROOT/state.json')).get('bots', [])))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
RUNS=$(ls "$ROOT/traces" 2>/dev/null | wc -l | tr -d ' ')

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT.backup-$STAMP"
mv "$ROOT" "$BACKUP"
mkdir -p "$ROOT"
chmod 700 "$ROOT"

if (( KEEP_KEYS )) && [[ -f "$BACKUP/credentials.json" ]]; then
  cp -p "$BACKUP/credentials.json" "$ROOT/credentials.json"
  chmod 600 "$ROOT/credentials.json"
  KEYNOTE="kept your saved API keys"
else
  KEYNOTE="removed the saved API keys too"
fi

print -P "%F{green}reset%f  $BOTS bots and $RUNS runs set aside; $KEYNOTE"
print   "        moved to: $BACKUP"
print   "        undo:     rm -rf \"$ROOT\" && mv \"$BACKUP\" \"$ROOT\""
