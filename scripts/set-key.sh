#!/bin/zsh
# Store a provider API key in the macOS Keychain under the service Bot-Harness reads.
# The key is never echoed, never written to a file, and never appears in shell history
# (it is read from a terminal prompt, not an argument).
#
# PREFER SETTINGS (Cmd-,) IN THE APP. An item created here is owned by /usr/bin/security,
# so BotHarness.app is a stranger to it and macOS asks for the login password the first
# time the app reads it. An item created by the app itself is owned by the app and never
# prompts. This script exists for headless setup; the app is the better path.
#
#   scripts/set-key.sh gemini
#   scripts/set-key.sh anthropic
#   scripts/set-key.sh openai
#
# To remove one:  security delete-generic-password -s app.botharness.keys -a gemini

set -euo pipefail

SERVICE="app.botharness.keys"
ACCOUNT="${1:-}"

if [[ -z "$ACCOUNT" ]]; then
  print -u2 "usage: $0 <gemini|anthropic|openai|...>"
  exit 2
fi

print -n "Paste the ${ACCOUNT} API key (input hidden): "
read -rs VALUE
print ""

if [[ -z "$VALUE" ]]; then
  print -u2 "nothing entered; no change made"
  exit 1
fi

# Trust the signed app up front, so reading the key does not raise a password dialog.
# -T records the application's designated requirement, not its path, and bundle.sh signs
# with a real Apple Development certificate — so the grant survives rebuilds. It would not
# survive them for an ad-hoc-signed binary, whose requirement contains a per-build hash;
# that is exactly why `swift run Evals` used to ask on every single run.
TRUSTED=(-T /usr/bin/security)
APP="$(cd "$(dirname "$0")/.." && pwd)/build/BotHarness.app"
if [[ -d "$APP" ]]; then
  TRUSTED+=(-T "$APP")
else
  print -u2 "note: $APP is not built, so the app is not on this item's trusted list."
  print -u2 "      Run scripts/bundle.sh first, or just enter the key in Settings instead."
fi

security delete-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1 || true
security add-generic-password -s "$SERVICE" -a "$ACCOUNT" -w "$VALUE" -U "${TRUSTED[@]}"
unset VALUE

print "stored ${ACCOUNT} in Keychain service ${SERVICE}"
print "verify with: security find-generic-password -s $SERVICE -a $ACCOUNT >/dev/null && echo present"
