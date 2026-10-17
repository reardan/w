# wbuild: tool=tools/wfixture.w
# wbuild: step="bin/wfixture bin/wv2 tests/safe_scoped_defer_streaming_error_fixture.w"
# wbuild: step="bin/wv2 --strict tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_scoped_defer_runtime"
# wbuild: step="bin/wv2 --strict --no-regs --no-inline tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_scoped_defer_runtime"
# wbuild: step="bin/wv2 --strict --inline tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_scoped_defer_runtime"
# wbuild: step="bin/wv2 x64 --strict tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_scoped_defer_runtime64"
# wbuild: step="bin/wv2 x64 --strict --no-regs --no-inline tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_scoped_defer_runtime64"
# wbuild: step="bin/wv2 x64 --strict --inline tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_scoped_defer_runtime64"
# wbuild: step="bin/wv2 win64 --strict tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_cross.exe"
# wbuild: step="bin/wv2 arm64 --strict tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_arm64"
# wbuild: step="bin/wv2 arm64 --strict --no-regs --no-inline tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_arm64_plain"
# wbuild: step="bin/wv2 arm64 --strict --inline tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_arm64_inline"
# wbuild: target=safe_scoped_defer_win64_runtime_test tag=tests_win64 dep=wv2
# wbuild: step="bin/wv2 win64 --strict tests/safe_scoped_defer_runtime_fixture.w -o bin/safe_scoped_defer_runtime.exe"
# wbuild: step="wine bin/safe_scoped_defer_runtime.exe"
# wbuild: target=safe_scoped_defer_arm64_runtime_test tag=tests_arm64 dep=safe_scoped_defer_runtime_test dep=wrun
# wbuild: step="env W_DEBUG_ALLOC=1 bin/wrun arm64 bin/safe_scoped_defer_arm64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/wrun arm64 bin/safe_scoped_defer_arm64_plain"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/wrun arm64 bin/safe_scoped_defer_arm64_inline"
int main():
	return 0
