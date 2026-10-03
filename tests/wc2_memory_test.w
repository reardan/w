# wbuild: x64 tool=tools/wc2.w expect_stdout="wc2_memory_test: OK"
# A fresh process makes a zero-leak assertion meaningful: no testing
# harness, unrelated parser trees, or formatting allocations precede it.
import lib.assert
import tools.wc2.lower
import tools.wc2.dump


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
