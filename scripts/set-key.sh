#!/bin/zsh
# Store a provider API key in the file Bot-Harness reads.
#
# The key is read from a hidden terminal prompt, so it never reaches shell history, and it is
# written only to ~/Library/Application Support/Bot-Harness/credentials.json with mode 0600.
#
#   scripts/set-key.sh gemini
#   scripts/set-key.sh anthropic
#   scripts/set-key.sh openai
#
#   scripts/set-key.sh --list          show which accounts are set (never the values)
#   scripts/set-key.sh --remove gemini
#
# Settings (Cmd-,) in the app does the same thing and is the friendlier path. This script is
# for headless setup. Unlike the keychain it replaced, both routes write the same file, so
# neither one prompts for a password and there is no owner to get wrong.

set -euo pipefail

STORE="$HOME/Library/Application Support/Bot-Harness/credentials.json"

command -v python3 >/dev/null 2>&1 || {
  print -u2 "python3 is required (it ships with the Xcode command line tools)"
  exit 1
}

# Reads the store, applies one change, writes it back with the directory at 0700 and the file
# at 0600. Writes to a temporary file and renames, so an interrupted run cannot leave a
# half-written file that would read as "no keys configured".
_apply() {  # _apply <account> <value|"">   empty value removes
  ACCOUNT="$1" VALUE="$2" STORE="$STORE" python3 - <<'PY'
import json, os, pathlib, tempfile

store = pathlib.Path(os.environ["STORE"])
account, value = os.environ["ACCOUNT"], os.environ["VALUE"]

store.parent.mkdir(parents=True, exist_ok=True)
os.chmod(store.parent, 0o700)

try:
    values = json.loads(store.read_text())
    if not isinstance(values, dict): values = {}
except (FileNotFoundError, ValueError):
    values = {}

if value: values[account] = value
else:     values.pop(account, None)

handle, temporary = tempfile.mkstemp(dir=str(store.parent))
with os.fdopen(handle, "w") as f:
    json.dump(values, f, indent=2, sort_keys=True)
os.chmod(temporary, 0o600)
os.replace(temporary, store)
PY
}

case "${1:-}" in
  --list)
    if [[ ! -f "$STORE" ]]; then print "no credentials file yet ($STORE)"; exit 0; fi
    print "accounts set in $STORE:"
    STORE="$STORE" python3 -c 'import json,os;print("\n".join("  "+k for k in sorted(json.load(open(os.environ["STORE"])))) or "  (none)")'
    ls -l "$STORE" | awk '{print "\nmode: " $1}'
    exit 0 ;;
  --remove)
    ACCOUNT="${2:-}"
    [[ -n "$ACCOUNT" ]] || { print -u2 "usage: $0 --remove <account>"; exit 2 }
    _apply "$ACCOUNT" ""
    print "removed ${ACCOUNT}"
    exit 0 ;;
  "")
    print -u2 "usage: $0 <gemini|anthropic|openai|...>   |   --list   |   --remove <account>"
    exit 2 ;;
esac

ACCOUNT="$1"

print -n "Paste the ${ACCOUNT} API key (input hidden): "
read -rs VALUE
print ""

if [[ -z "$VALUE" ]]; then
  print -u2 "nothing entered; no change made"
  exit 1
fi

_apply "$ACCOUNT" "$VALUE"
unset VALUE

print "stored ${ACCOUNT} in $STORE"
print "verify with: $0 --list"
