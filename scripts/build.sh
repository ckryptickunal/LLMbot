#!/bin/zsh
# Build with the pinned toolchain. Use this rather than a bare `swift build`, which picks up
# whatever `xcode-select` points at and will not link objects the other toolchain compiled.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_toolchain.sh
swift build "$@"
