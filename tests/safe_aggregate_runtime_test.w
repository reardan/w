# wbuild: step="bin/wv2 --strict tests/safe_aggregate_runtime_fixture.w -o bin/safe_aggregate_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_aggregate_runtime_fixture"
# wbuild: step="bin/wv2 --strict x64 tests/safe_aggregate_runtime_fixture.w -o bin/safe_aggregate_runtime_fixture64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_aggregate_runtime_fixture64"
# wbuild: step="bin/wv2 --strict --no-regs --no-inline tests/safe_aggregate_runtime_fixture.w -o bin/safe_aggregate_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_aggregate_runtime_fixture"
# wbuild: step="bin/wv2 --strict --inline tests/safe_aggregate_runtime_fixture.w -o bin/safe_aggregate_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_aggregate_runtime_fixture"
# wbuild: step="bin/wv2 --strict x64 --no-regs --no-inline tests/safe_aggregate_runtime_fixture.w -o bin/safe_aggregate_runtime_fixture64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_aggregate_runtime_fixture64"
# wbuild: step="bin/wv2 --strict x64 --inline tests/safe_aggregate_runtime_fixture.w -o bin/safe_aggregate_runtime_fixture64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_aggregate_runtime_fixture64"
int main():
	return 0
