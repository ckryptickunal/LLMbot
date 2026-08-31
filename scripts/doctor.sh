#!/bin/zsh
# Bot-Harness environment check.
# Re-verifies every claim in docs/guides/ENVIRONMENT.md against the live machine.
# Exits non-zero if anything required is missing, so CI can gate on it.

set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/_toolchain.sh

fail=0
ok()   { print -P "  %F{green}ok%f      $1"; }
warn() { print -P "  %F{yellow}warn%f    $1"; }
bad()  { print -P "  %F{red}MISSING%f $1"; fail=1; }

print -P "%F{cyan}Bot-Harness doctor%f  —  $(date '+%Y-%m-%d %H:%M:%S')\n"

print -P "%Bmachine%b"
ok "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"

print -P "\n%Brequired toolchain%b"
if swift --version >/dev/null 2>&1; then
  ok "swift $(swift --version 2>&1 | grep -o 'Apple Swift version [0-9.]*' | cut -d' ' -f4)"
else
  bad "swift — install Command Line Tools: xcode-select --install"
fi

xp=$(xcode-select -p 2>/dev/null)
case "$xp" in
  *CommandLineTools*) ok "developer dir: Command Line Tools (no Xcode — expected)" ;;
  *Xcode*)            ok "developer dir: full Xcode at $xp" ;;
  *)                  bad "no developer directory — run: xcode-select --install" ;;
esac

command -v codesign >/dev/null 2>&1 && ok "codesign present" || bad "codesign"
command -v plutil   >/dev/null 2>&1 && ok "plutil present"   || bad "plutil"

print -P "\n%Bbrains%b"
if command -v claude >/dev/null 2>&1; then
  ok "claude CLI $(claude --version 2>&1 | head -1)"
  claude --help 2>&1 | grep -q -- '--output-format' \
    && ok "claude headless streaming supported (--print --output-format stream-json)" \
    || warn "claude CLI present but --output-format not found; headless brain unavailable"
else
  warn "claude CLI not found — the Claude Code subscription brain will be unavailable"
fi

STORE="$HOME/Library/Application Support/Bot-Harness/credentials.json"
STORE_DIR="${STORE:h}"

# The rule the app applies, character for character: no group bits and no other bits, rather
# than exactly 600. A 0400 file is stricter than we ask for, not broken, and doctor disagreeing
# with CredentialStore.permissionsAreCorrect() about the word "correct" is how someone ends up
# chmod-ing a stricter mode back to a looser one because a check told them to.
owner_only() { (( ( 8#$(stat -f "%OLp" "$1") & 8#077 ) == 0 )) }

if [[ -f "$STORE" ]]; then
  if grep -q '"gemini"' "$STORE" 2>/dev/null; then
    ok "Gemini API key present ($STORE)"
  else
    warn "no Gemini key — add it in the app (Cmd-,), or: scripts/set-key.sh gemini"
  fi

  if owner_only "$STORE"; then
    ok "credentials file is owner-only (mode $(stat -f "%OLp" "$STORE"))"
  else
    warn "credentials file is mode $(stat -f "%OLp" "$STORE") — other accounts on this Mac can read your keys; fix with: chmod 600 \"$STORE\""
  fi

  if owner_only "$STORE_DIR"; then
    ok "credentials folder is owner-only (mode $(stat -f "%OLp" "$STORE_DIR"))"
  else
    warn "credentials folder is mode $(stat -f "%OLp" "$STORE_DIR") — fix with: chmod 700 \"$STORE_DIR\""
  fi
else
  warn "no Gemini key — add it in the app (Cmd-,), or: scripts/set-key.sh gemini"
fi

# A temporary left behind by a save that was killed is a second plaintext copy of every key,
# which nothing rewrites and nobody would think to look for. The app reports it in Settings; this
# catches the case where the app is not the thing running.
if [[ -e "$STORE.tmp" ]]; then
  warn "$STORE.tmp was left by an interrupted save and holds a copy of every key — remove it: rm \"$STORE.tmp\""
fi

print -P "\n%Boptional sidecars%b"
for t in node npm pnpm python3 docker gh; do
  if command -v $t >/dev/null 2>&1; then ok "$t $($t --version 2>&1 | head -1 | tr -d '\n')"
  else warn "$t not found"; fi
done

print -P "\n%Btests%b"
if [[ -d /Applications/Xcode.app ]]; then
  ok "Xcode present — scripts/test.sh can run XCTest"
else
  warn "no Xcode — XCTest is unavailable, so scripts/test.sh will not run"
fi

print -P "\n%Bproject%b"
[[ -f Package.swift || -f app/Package.swift ]] && ok "Swift package present" || warn "no Package.swift yet"
[[ -d var/traces ]] && ok "trace directory var/traces" || bad "var/traces missing"
[[ -x .claude/hooks/trace.py ]] && ok "decision-trace hook is executable" || warn ".claude/hooks/trace.py not executable"

if [[ -f var/traces/agent-activity.jsonl ]]; then
  ok "trace has $(wc -l < var/traces/agent-activity.jsonl | tr -d ' ') recorded events"
else
  warn "no trace events recorded yet"
fi

print -P "\n%Bpermissions (non-prompting checks only)%b"
if [[ -x .build/release/Probe ]]; then
  .build/release/Probe | sed 's/^/  /'
else
  warn "capability probe not built — run: swift build -c release --product Probe"
fi

print ""
if (( fail )); then
  print -P "%F{red}doctor: required components missing%f"
  exit 1
else
  print -P "%F{green}doctor: environment is good%f"
fi
