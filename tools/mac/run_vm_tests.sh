#!/bin/sh
# Mandatory native Apple Silicon VM gate. No hardware/signing skips.
# Outputs (including a fresh pinned-seed fixpoint) remain in ignored bin/.
# W_DARWIN_COMPILER optionally supplies a bootstrap compiler; its hash is
# recorded, and the fixpoint still runs. The default verifies SEEDS first.
set -eu
cd "$(dirname "$0")/../.."
exec python3 tools/mac/vm_test_runner.py "$@"
