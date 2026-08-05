# expect_fail
# expect_stderr: cannot export a variadic function
# Compiled with 'wv2 wasm' by the wasm_export_test target: a variadic W
# function has no fixed wasm signature to export.
import lib.lib

export int sum_all(int... rest):
	int total = 0
	for int v in rest:
		total = total + v
	return total

int main(int argc, int argv):
	return sum_all(1, 2, 3)
