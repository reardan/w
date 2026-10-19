#!/bin/sh
# Build and invoke the native, staged grammars-v4 sweep.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
cd "$ROOT"
./wbuild antlr_sweep
exec bin/antlr_sweep "$@"
