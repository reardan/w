#!/bin/sh
# Native optimizer regressions. ./wbuild arm64_optimization_darwin_test
# builds the current Darwin compiler before calling this script. Keeping
# this target in build.base.json also works with the native executor's
# bootstrap recovery manifest as well as full source discovery.
set -eu
cd "$(dirname "$0")/../.."

for name in arm64_load_fold_test arm64_cmp_imm_test local_load_fold_test comparison_branch_test const_fold_test unsigned_compare_test float_nan_compare_test; do
	bin/wv2_darwin arm64_darwin --strict "tests/$name.w" -o "bin/${name}_darwin"
	# The runner executes a fresh inode to avoid macOS signature caching.
	tools/mac/run_darwin_tests.sh "bin/${name}_darwin"
done
