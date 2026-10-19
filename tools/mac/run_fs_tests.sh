#!/bin/sh
# Native filesystem qualification; static manifest target because the
# Darwin executor does not scan source-owned targets yet.
set -eu
cd "$(dirname "$0")/../.."
bin/wv2_darwin check --json arm64_darwin tests/host_files_test.w
bin/wv2_darwin arm64_darwin --strict tests/host_files_test.w -o bin/host_files_test_darwin.new
mv -f bin/host_files_test_darwin.new bin/host_files_test_darwin
tools/mac/run_darwin_tests.sh bin/host_files_test_darwin
for name in fs io; do
	bin/wv2_darwin check --json arm64_darwin "lib/${name}_test.w"
	bin/wv2_darwin arm64_darwin --strict "lib/${name}_test.w" -o "bin/${name}_test_darwin"
	tools/mac/run_darwin_tests.sh "bin/${name}_test_darwin"
done
bin/wv2_darwin arm64_darwin --strict tools/mac/test_fs_durability.w -o bin/darwin_fs_qualification.new
mv -f bin/darwin_fs_qualification.new bin/darwin_fs_qualification
bin/darwin_fs_qualification
