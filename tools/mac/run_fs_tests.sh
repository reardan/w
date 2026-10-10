#!/bin/sh
# Native filesystem qualification; static manifest target because the
# Darwin executor does not scan source-owned targets yet.
set -eu
cd "$(dirname "$0")/../.."
for name in fs io; do
	bin/wv2_darwin check --json arm64_darwin "lib/${name}_test.w"
	bin/wv2_darwin arm64_darwin --strict "lib/${name}_test.w" -o "bin/${name}_test_darwin"
	tools/mac/run_darwin_tests.sh "bin/${name}_test_darwin"
done
python3 tools/mac/test_fs_durability.py
