# wbuild: step="bin/wv2 --strict tests/safe_nested_replacement_runtime_fixture.w -o bin/safe_nested_replacement_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_nested_replacement_runtime"
# wbuild: step="bin/wv2 --strict --no-regs --no-inline tests/safe_nested_replacement_runtime_fixture.w -o bin/safe_nested_replacement_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_nested_replacement_runtime"
# wbuild: step="bin/wv2 --strict --inline tests/safe_nested_replacement_runtime_fixture.w -o bin/safe_nested_replacement_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_nested_replacement_runtime"
# wbuild: step="bin/wv2 x64 --strict tests/safe_nested_replacement_runtime_fixture.w -o bin/safe_nested_replacement_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_nested_replacement_runtime64"
# wbuild: step="bin/wv2 x64 --strict --no-regs --no-inline tests/safe_nested_replacement_runtime_fixture.w -o bin/safe_nested_replacement_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_nested_replacement_runtime64"
# wbuild: step="bin/wv2 x64 --strict --inline tests/safe_nested_replacement_runtime_fixture.w -o bin/safe_nested_replacement_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_nested_replacement_runtime64"
# wbuild: step="bin/wv2 win64 --strict tests/safe_nested_replacement_runtime_fixture.w -o bin/safe_nested_replacement_cross.exe"
# wbuild: target=safe_nested_replacement_win64_runtime_test tag=tests_win64 dep=wv2
# wbuild: step="bin/wv2 win64 --strict tests/safe_nested_replacement_runtime_fixture.w -o bin/safe_nested_replacement_runtime.exe"
# wbuild: step="wine bin/safe_nested_replacement_runtime.exe"
int main():
	return 0
