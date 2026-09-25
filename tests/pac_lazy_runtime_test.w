# wbuild: name=pac_lazy_runtime_test_arm64 arch_only=arm64 flags=--pac=full expect_stdout="pac lazy runtime OK"
# --pac=full regression for the deferred runtime helpers: f-strings,
# var and print lower to calls whose callee address is materialized
# through a backpatch chain before the runtime module is imported
# (grammar/lazy_runtime.w). Every such materialization must be signed
# like sym_get_value's, or the blraaz at the call authenticates an
# unsigned pointer and the program dies with SIGILL/SIGSEGV. The source
# runs unchanged on every target.
import lib.lib
import lib.assert


int main(int argc, int argv):
	int n = 42
	string s = f"n={n} s={c"x"}"
	assert_equal(6, s.length - 2)
	var v = 5
	var w = v + 2
	int back = w
	assert_equal(7, back)
	println(f"pac lazy runtime {c"OK"}")
	return 0
