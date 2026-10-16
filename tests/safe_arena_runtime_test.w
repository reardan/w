# wbuild: step="bin/wv2 --ast-required --safe --strict tests/safe_arena_runtime_fixture.w -o bin/safe_arena_runtime"
# wbuild: step="bin/safe_arena_runtime"
# wbuild: step="bin/wv2 x64 --ast-required --safe --strict tests/safe_arena_runtime_fixture.w -o bin/safe_arena_runtime64"
# wbuild: step="bin/safe_arena_runtime64"
# wbuild: step="bin/wv2 --ast-required --no-regs --no-inline tests/safe_arena_runtime_fixture.w -o bin/safe_arena_runtime_plain"
# wbuild: step="bin/safe_arena_runtime_plain"
# wbuild: step="bin/wv2 x64 --ast-required --inline tests/safe_arena_runtime_fixture.w -o bin/safe_arena_runtime_inline64"
# wbuild: step="bin/safe_arena_runtime_inline64"
# wbuild: target=safe_arena_win64_test tag=tests_win64 dep=wv2
# wbuild: step="bin/wv2 win64 --ast-required --safe --strict tests/safe_arena_runtime_fixture.w -o bin/safe_arena_runtime.exe"
# wbuild: step="wine bin/safe_arena_runtime.exe"
import lib.testing

void test_safe_arena_runtime_steps():
	assert1(1)
