# wbuild: step="bin/wv2 --ast-required --strict tests/safe_optional_runtime_fixture.w -o bin/safe_optional_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_runtime_fixture"
# wbuild: step="bin/wv2 --ast-required --strict x64 tests/safe_optional_runtime_fixture.w -o bin/safe_optional_runtime_fixture64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_runtime_fixture64"
# wbuild: step="bin/wv2 --ast-required --strict --no-regs --no-inline tests/safe_optional_runtime_fixture.w -o bin/safe_optional_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_runtime_fixture"
# wbuild: step="bin/wv2 --ast-required --strict --inline tests/safe_optional_runtime_fixture.w -o bin/safe_optional_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_runtime_fixture"
# wbuild: step="bin/wv2 --ast-required --strict x64 --no-regs --no-inline tests/safe_optional_runtime_fixture.w -o bin/safe_optional_runtime_fixture64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_runtime_fixture64"
# wbuild: step="bin/wv2 --ast-required --strict x64 --inline tests/safe_optional_runtime_fixture.w -o bin/safe_optional_runtime_fixture64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_optional_runtime_fixture64"
int main():
	return 0
