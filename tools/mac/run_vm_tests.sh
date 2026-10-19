#!/bin/sh
# Mandatory native Apple Silicon VM gate. No hardware/signing skips.
# Outputs (including a fresh pinned-seed fixpoint) remain in ignored bin/.
# W_DARWIN_COMPILER optionally supplies a bootstrap compiler; its hash is
# recorded, and the fixpoint still runs. The default verifies SEEDS first.
set -eu
cd "$(dirname "$0")/../.."
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo 'run_vm_tests: requires Apple Silicon macOS' >&2
    exit 1
fi
w_vm_compiler=${W_DARWIN_COMPILER:-bin/wv2_darwin}
if [ ! -x "$w_vm_compiler" ]; then ./wbuild build_darwin; fi
"$w_vm_compiler" arm64_darwin --strict tools/mac/vm_test_runner.w -o bin/darwin_vm_gate.new
mv -f bin/darwin_vm_gate.new bin/darwin_vm_gate
exec bin/darwin_vm_gate "$@"
