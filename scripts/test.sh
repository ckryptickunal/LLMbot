#!/bin/zsh
# Run the test suite.
#
# Tests need XCTest, which ships with Xcode and NOT with Command Line Tools. Since
# `xcode-select` on this machine points at Command Line Tools, `swift test` fails with
# "no such module 'XCTest'" unless DEVELOPER_DIR is pointed at Xcode for the invocation.
# That is what this script exists to do. See docs/guides/ENVIRONMENT.md.

set -euo pipefail
cd "$(dirname "$0")/.."

XCODE="/Applications/Xcode.app/Contents/Developer"

if [[ ! -d "$XCODE" ]]; then
  print -u2 "Xcode not found at $XCODE — tests need XCTest, which Command Line Tools does not provide."
  print -u2 "Either install Xcode, or run the app's checks manually."
  exit 1
fi

DEVELOPER_DIR="$XCODE" swift test "$@"
