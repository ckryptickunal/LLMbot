#!/bin/zsh
# Store a provider API key in the macOS Keychain under the service Bot-Harness reads.
# The key is never echoed, never written to a file, and never appears in shell history
# (it is read from a terminal prompt, not an argument).
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

security delete-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1 || true
security add-generic-password -s "$SERVICE" -a "$ACCOUNT" -w "$VALUE" -U
unset VALUE

print "stored ${ACCOUNT} in Keychain service ${SERVICE}"
print "verify with: security find-generic-password -s $SERVICE -a $ACCOUNT >/dev/null && echo present"
