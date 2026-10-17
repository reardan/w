# wbuild: step="bin/wv2 --strict tests/safe_optional_field_runtime_fixture.w -o bin/safe_optional_field_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_field_runtime"
# wbuild: step="bin/wv2 --strict --no-regs --no-inline tests/safe_optional_field_runtime_fixture.w -o bin/safe_optional_field_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_field_runtime"
# wbuild: step="bin/wv2 --strict --inline tests/safe_optional_field_runtime_fixture.w -o bin/safe_optional_field_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_field_runtime"
# wbuild: step="bin/wv2 x64 --strict tests/safe_optional_field_runtime_fixture.w -o bin/safe_optional_field_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_field_runtime64"
# wbuild: step="bin/wv2 x64 --strict --no-regs --no-inline tests/safe_optional_field_runtime_fixture.w -o bin/safe_optional_field_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_field_runtime64"
# wbuild: step="bin/wv2 x64 --strict --inline tests/safe_optional_field_runtime_fixture.w -o bin/safe_optional_field_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_field_runtime64"
# wbuild: step="bin/wv2 win64 --strict tests/safe_optional_field_runtime_fixture.w -o bin/safe_optional_field_cross.exe"
# wbuild: target=safe_optional_field_win64_runtime_test tag=tests_win64 dep=wv2
# wbuild: step="bin/wv2 win64 --strict tests/safe_optional_field_runtime_fixture.w -o bin/safe_optional_field_runtime.exe"
# wbuild: step="wine bin/safe_optional_field_runtime.exe"
int main():
	return 0
