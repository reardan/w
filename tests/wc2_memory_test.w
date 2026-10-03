# wbuild: x64 tool=tools/wc2.w expect_stdout="wc2_memory_test: OK"
# A fresh process makes a zero-leak assertion meaningful: no testing
# harness, unrelated parser trees, or formatting allocations precede it.
import lib.assert
import tools.wc2.lower
import tools.wc2.dump
import tools.wc2.emit


int main():
	malloc_force_debug_mode()
	wc2_module* retained = wc2_parse(c"int keep(): return 7\n", c"keep.w")
	assert1(wc2_module_ok(retained))
	for i in range(3):
		# Successful alternatives, failed alternatives, error recovery,
		# lexer errors and an empty file all have the same ownership API.
		wc2_module* m = wc2_parse(c"int f(int x):\n\tif x: return 2 + 3 * 4\n\treturn 0\n", c"ok.w")
		assert1(wc2_module_ok(m))
		char* dump = wc2_dump(m)
		free(dump)
		wc2_module_free(m)
		m = wc2_parse(c"int main(): return (0 && (1 / 0)) + ((~3 ^ 5) * 7 >> 2)\n", c"emit.w")
		asm_buffer* image = wc2_emit(m)
		assert1(image != 0)
		asm_buffer* again = wc2_emit(m)
		assert1(again != 0)
		assert_equal(image.length, again.length)
		assert1(mem_eq(image.data, again.data, image.length))
		wc2_module_free(m)
		asm_buffer_free(image)
		asm_buffer_free(again)
		m = wc2_parse(c"int main(): return 4294967296\n", c"overflow.w")
		assert1(wc2_emit(m) == 0)
		wc2_module_free(m)
		m = wc2_parse(c"int f(\nint good(): return 1\n", c"syntax.w")
		assert_equal(0, wc2_module_ok(m))
		wc2_module_free(m)
		m = wc2_parse(c"int f(): return @\n", c"lexer.w")
		assert_equal(0, wc2_module_ok(m))
		wc2_module_free(m)
		m = wc2_parse(c"int f(): return 1.5\n", c"unsupported.w")
		assert_equal(0, wc2_module_ok(m))
		wc2_module_free(m)
		m = wc2_parse(c"", c"empty.w")
		assert1(wc2_module_ok(m))
		wc2_module_free(m)
	assert1(wc2_module_ok(retained))
	wc2_module_free(retained)
	assert_equal(0, debug_alloc_report_leaks())
	println(c"wc2_memory_test: OK")
	return 0
