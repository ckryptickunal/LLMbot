#!/bin/zsh
# Run the eval suite.
#
#   scripts/eval.sh                 deterministic harness tasks (free, fast, no model)
#   scripts/eval.sh --live          tasks needing a real model and a real Mac
#   scripts/eval.sh --all --repeat 3
#   scripts/eval.sh --task H04
#
# Exits non-zero on any failure, so it can gate a commit.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_toolchain.sh
swift run Evals "$@"
