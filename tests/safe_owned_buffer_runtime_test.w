# wbuild: step="bin/wv2 --ast-required --safe --strict tests/safe_owned_buffer_runtime_fixture.w -o bin/safe_owned_buffer_runtime"
# wbuild: step="bin/safe_owned_buffer_runtime"
# wbuild: step="bin/wv2 x64 --ast-required --safe --strict tests/safe_owned_buffer_runtime_fixture.w -o bin/safe_owned_buffer_runtime64"
# wbuild: step="bin/safe_owned_buffer_runtime64"
# wbuild: step="bin/wv2 --ast-required --no-regs --no-inline tests/safe_owned_buffer_runtime_fixture.w -o bin/safe_owned_buffer_runtime_plain"
# wbuild: step="bin/safe_owned_buffer_runtime_plain"
# wbuild: step="bin/wv2 x64 --ast-required --no-regs --no-inline tests/safe_owned_buffer_runtime_fixture.w -o bin/safe_owned_buffer_runtime_plain64"
# wbuild: step="bin/safe_owned_buffer_runtime_plain64"
# wbuild: step="bin/wv2 --ast-required --inline tests/safe_owned_buffer_runtime_fixture.w -o bin/safe_owned_buffer_runtime_inline"
# wbuild: step="bin/safe_owned_buffer_runtime_inline"
# wbuild: step="bin/wv2 x64 --ast-required --inline tests/safe_owned_buffer_runtime_fixture.w -o bin/safe_owned_buffer_runtime_inline64"
# wbuild: step="bin/safe_owned_buffer_runtime_inline64"
# wbuild: target=safe_owned_buffer_win64_test tag=tests_win64 dep=wv2
# wbuild: step="bin/wv2 win64 --ast-required --safe --strict tests/safe_owned_buffer_runtime_fixture.w -o bin/safe_owned_buffer_runtime.exe"
# wbuild: step="wine bin/safe_owned_buffer_runtime.exe"
import lib.testing

void test_owned_buffer_runtime_steps():
	assert1(1)
