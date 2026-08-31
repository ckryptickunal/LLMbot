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
# Any account name works, not just those three: the app redacts every value it holds, whatever
# the account is called, so a key stored here as "openrouter" is covered like any other.
#
# Settings (Cmd-,) in the app does the same thing and is the friendlier path. This script is
# for headless setup. Unlike the keychain it replaced, both routes write the same file, so
# neither one prompts for a password and there is no owner to get wrong. Both routes also take
# the same lock, so running this while the app is open cannot lose either one's keys.

set -euo pipefail

STORE="$HOME/Library/Application Support/Bot-Harness/credentials.json"

command -v python3 >/dev/null 2>&1 || {
  print -u2 "python3 is required (it ships with the Xcode command line tools)"
  exit 1
}

# Trim leading and trailing whitespace. A key pasted out of a browser almost always carries a
# trailing newline, and the app trims before storing — so without this the two routes wrote two
# different spellings of the same key into the same file, and "the app says my key is invalid"
# had no visible cause. Whitespace-only input is "no change", which is what Settings does with it.
_trim() {
  setopt local_options extended_glob
  TRIMMED="${${1##[[:space:]]#}%%[[:space:]]#}"
}

# Reads the store, applies one change, writes it back with the directory at 0700 and the file
# at 0600. Writes to a temporary file and renames, so an interrupted run cannot leave a
# half-written file that would read as "no keys configured".
_apply() {  # _apply <account> <value|"">   empty value removes
  ACCOUNT="$1" VALUE="$2" STORE="$STORE" python3 - <<'PY'
import fcntl, json, os, pathlib, plistlib, subprocess, sys, tempfile

store = pathlib.Path(os.environ["STORE"])
account, value = os.environ["ACCOUNT"], os.environ["VALUE"]

store.parent.mkdir(parents=True, exist_ok=True)
os.chmod(store.parent, 0o700)

# The same lock the app takes (CredentialStore.Store.withExclusiveLock): flock(2) on the
# directory, not on a file of its own, because the store file is replaced by a rename on every
# write and a lock on its descriptor would guard an inode nobody opens next. Without this, the
# app and this script could read, merge and write across each other, and whichever finished
# second silently deleted the other's key.
lock = os.open(str(store.parent), os.O_RDONLY)
fcntl.flock(lock, fcntl.LOCK_EX)
try:
    try:
        raw = store.read_bytes()
    except FileNotFoundError:
        raw = b""

    if raw.strip():
        try:
            values = json.loads(raw)
        except ValueError:
            values = None
        if not isinstance(values, dict):
            # Refuse rather than start from an empty document. Silently replacing a file we
            # cannot parse turns one typo in a hand-edited file into the loss of every key in it.
            sys.exit("%s is not a JSON object, so it was left alone.\n"
                     "Fix or move the file, then run this again." % store)
    else:
        # No bytes at all holds no keys, so writing over it cannot lose anything.
        values = {}

    if value: values[account] = value
    else:     values.pop(account, None)

    # mkstemp creates the file readable and writable only by this user, so the keys are never on
    # disk at a wider mode for even an instant. The chmod keeps that true if that ever changes.
    #
    # The prefix is fixed rather than random on purpose. A bot's permanent deny list names
    # credentials.json and credentials.json.tmp; a randomly named tmpXXXXXXXX sibling holding a
    # complete copy of every key matches no deny rule at all. It exists for milliseconds, but
    # "the window is small" is not a boundary, and the deny list can only name what it can
    # predict. See Authority.alwaysDenied.
    handle, temporary = tempfile.mkstemp(dir=str(store.parent),
                                         prefix="credentials.json.", suffix=".tmp")
    with os.fdopen(handle, "w") as f:
        json.dump(values, f, indent=2, sort_keys=True)
    os.chmod(temporary, 0o600)
    os.replace(temporary, store)
finally:
    os.close(lock)

# Keep the cleartext keys off Time Machine and out of Migration Assistant, exactly as the app
# does with URLResourceValues.isExcludedFromBackup — the bytes below were compared against what
# Foundation writes and are identical. Only the file: state.json, the traces and the screenshots
# live in the same folder and are what someone would actually want restored after a disk failure.
# Best effort, because the key is already stored by this point and failing the whole save over a
# backup attribute would be the worse outcome.
subprocess.run(["/usr/bin/xattr", "-wx", "com.apple.metadata:com_apple_backup_excludeItem",
                plistlib.dumps("com.apple.backupd", fmt=plistlib.FMT_BINARY).hex(), str(store)],
               check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
}

case "${1:-}" in
  --list)
    if [[ ! -f "$STORE" ]]; then print "no credentials file yet ($STORE)"; exit 0; fi
    print "accounts set in $STORE:"
    STORE="$STORE" python3 - <<'PY'
import json, os, pathlib, sys

store = pathlib.Path(os.environ["STORE"])
try:
    values = json.loads(store.read_bytes())
except ValueError:
    sys.exit("  the file is not valid JSON — the app will refuse to write to it until that is fixed")
if not isinstance(values, dict):
    sys.exit("  the file is not a JSON object — the app will refuse to write to it until that is fixed")

# Entries whose value is not a string are not credentials. They are listed apart rather than
# ignored, because the app carries them through untouched and someone should know they are there.
accounts = sorted(k for k, v in values.items() if isinstance(v, str))
print("\n".join("  " + k for k in accounts) or "  (none)")
other = sorted(k for k, v in values.items() if not isinstance(v, str))
if other:
    print("\nnot credentials (left untouched): " + ", ".join(other))
PY
    ls -l "$STORE" | awk '{print "\nmode: " $1}'
    # A temporary left by a killed save is a second plaintext copy of every key that nothing
    # rewrites and nobody would think to look for. Written as an `if` and not a `&&` chain:
    # under `set -e` a false test at the end of a list exits the script with its status.
    if [[ -e "$STORE.tmp" ]]; then
      print "\nwarning: $STORE.tmp was left by an interrupted save and holds a copy of every key."
      print "Remove it: rm \"$STORE.tmp\""
    fi
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

_trim "$VALUE"
VALUE="$TRIMMED"
unset TRIMMED

if [[ -z "$VALUE" ]]; then
  print -u2 "nothing entered; no change made"
  exit 1
fi

_apply "$ACCOUNT" "$VALUE"
unset VALUE

print "stored ${ACCOUNT} in $STORE"
print "verify with: $0 --list"
