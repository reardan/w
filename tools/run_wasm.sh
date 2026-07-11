#!/bin/sh
# Run a compiled wasm module under a WASI runtime: wasmtime when
# installed, else Node's built-in WASI (node >= 20). The current
# directory is preopened as the guest's filesystem root, matching the
# lib/__arch__/wasm/syscalls.w path convention (getcwd() = "/", open()
# resolves against the first preopen).
#
# Usage: tools/run_wasm.sh module.wasm [args...]
set -e
module="$1"
shift
if command -v wasmtime >/dev/null 2>&1; then
	exec wasmtime run --dir . "$module" "$@"
fi
if command -v node >/dev/null 2>&1; then
	exec node --no-warnings "$(dirname "$0")/run_wasm.mjs" "$module" "$@"
fi
echo "run_wasm.sh: no WASI runtime found (need wasmtime or node)" >&2
exit 1
