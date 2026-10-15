# wbuild: step="bin/wv2 tests/safe_runtime_fixture.w -o bin/safe_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_runtime_fixture"
# wbuild: step="bin/wv2 x64 tests/safe_runtime_fixture.w -o bin/safe_runtime_fixture64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_runtime_fixture64"
# wbuild: step="bin/wv2 --no-regs --no-inline tests/safe_runtime_fixture.w -o bin/safe_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_runtime_fixture"
# wbuild: step="bin/wv2 --inline tests/safe_runtime_fixture.w -o bin/safe_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_runtime_fixture"
# wbuild: step="bin/wv2 --safe tests/safe_cost_fixture.w -o bin/safe_cost"
# wbuild: step="bin/safe_cost"
# wbuild: step="bin/wv2 tests/safe_cost_manual_fixture.w -o bin/safe_cost_manual"
# wbuild: step="bin/safe_cost_manual"
# wbuild: step="bin/wv2 x64 --safe tests/safe_cost_fixture.w -o bin/safe_cost64"
# wbuild: step="bin/safe_cost64"
# wbuild: step="bin/wv2 x64 tests/safe_cost_manual_fixture.w -o bin/safe_cost_manual64"
# wbuild: step="bin/safe_cost_manual64"
# wbuild: step="bin/wv2 --safe tests/safe_syntax_fixture.w -o bin/safe_syntax_fixture"
# wbuild: step="bin/safe_syntax_fixture"
import lib.testing

void test_safe_runtime_is_exercised_by_steps():
	assert1(1)
