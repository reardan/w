#!/usr/bin/env bash
# Compatibility entry point. Python's standard library supplies robust argv,
# timeouts, parallel jobs, JSON provenance and CSV escaping. See README.md.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 "$SCRIPT_DIR/sweep_grammars_v4.py" "$@"
