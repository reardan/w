# Exercise the fallback even when this Mac supports per-thread MAP_JIT
# protection. VM hosts select it automatically via libpthread's query.
import repl.embed
import lib.assert


int main():
	jit_host_use_mprotect = 1
	assert_equal(1, engine_init(0, 0))
	char* source = c"int mp_count\nint mp_value(int n):\n\tmp_count = mp_count + n\n\treturn mp_count\n\nint mp_write(int n):\n\tchar* p = cast(char*, mp_value)\n\tp[0] = 0\n\treturn n\n"
	assert_equal(engine_ok, engine_load(c"mprotect", source).status)
	int ok = 0
	# The writable phase must also reject instruction fetches.
	jit_host_write_protect(0)
	engine_call1(engine_symbol(c"mp_value"), 1, &ok)
	assert_equal(0, ok)
	jit_host_write_protect(1)
	for i in range(2):
		assert_equal(42, engine_call1(engine_symbol(c"mp_value"), 42, &ok))
		assert_equal(1, ok)
		engine_call1(engine_symbol(c"mp_write"), 0, &ok)
		assert_equal(0, ok)
		assert_contains(engine_fault_text, c"function mp_write")
		assert_equal(engine_ok, engine_reload(c"mprotect", source).status)
	engine_shutdown()
	println(c"Darwin JIT mprotect fallback OK")
	return 0

# wbuild: target=jit_mprotect_darwin_compile_test tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64_darwin tests/jit_mprotect_darwin_fixture.w -o bin/jit_mprotect_darwin_fixture"
# wbuild: target=jit_mprotect_darwin_test tag=tests_darwin dep=jit_mprotect_darwin_compile_test
# wbuild: step="bin/jit_mprotect_darwin_fixture" expect_stdout="Darwin JIT mprotect fallback OK"
