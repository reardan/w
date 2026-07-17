#!/bin/sh
# Run a tools/web Node host script (run_env_test.mjs, run_webgl_stub.mjs).
# These need Node >= 20 specifically — unlike tools/run_wasm.sh there is
# no wasmtime fallback, because the hosts provide custom "env" import
# modules and drive table callbacks, which the wasmtime CLI cannot.
#
# Usage: tools/web/run_node.sh <script.mjs> [args...]
set -e
if ! command -v node >/dev/null 2>&1; then
	echo "tools/web/run_node.sh: node not found (the wasm host tests need Node >= 20)" >&2
	exit 1
fi
script="$1"
shift
exec node --no-warnings "$script" "$@"
