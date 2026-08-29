#!/bin/zsh
# Run the test suite.
#
# Tests need XCTest, which ships with Xcode and NOT with Command Line Tools. Since
# `xcode-select` on this machine points at Command Line Tools, `swift test` fails with
# "no such module 'XCTest'" unless DEVELOPER_DIR is pointed at Xcode for the invocation.
# That is what this script exists to do. See docs/guides/ENVIRONMENT.md.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_toolchain.sh

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  print -u2 "Xcode not found — tests need XCTest, which Command Line Tools does not provide."
  print -u2 "Install Xcode, or skip tests and rely on scripts/doctor.sh."
  exit 1
fi

swift test "$@"
