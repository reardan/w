# End-to-end test of real-signature exports on the wasm target
# (docs/projects/wasm_backend.md stage 5): each 'export' function below
# appears in the module's export section under its W name, bound to a
# typed wrapper whose wasm signature comes from the declaration
# (int/pointers -> i32, float32 -> f32, void -> no result), so the host
# calls it directly — no table.get / $ax readback needed. Compiled with
# 'wv2 wasm' and driven by tools/web/run_export_test.mjs (the
# wasm_export_test target in build.base.json; the source is in
# generate.exclude like the other host-driven wasm tests).
import lib.lib
import lib.assert

int counter


# int params and result
export int add3(int a, int b, int c):
	return a + b + c


# f32 param and result mixed with an int param: the wrapper moves real
# f32 values across the boundary (reinterpreted to raw bits on the W
# side, where floats ride the integer pipeline)
export float32 scale(float32 x, int k):
	return x * k


# void result + module state: calls after _start returned must see (and
# keep mutating) the same instance state
export void bump(int by):
	counter = counter + by


# no parameters
export int get_counter():
	return counter


# The exported functions stay ordinary W functions: _start (main) calls
# them like anything else, before the host ever does.
int main(int argc, int argv):
	assert_equal(6, add3(1, 2, 3))
	bump(3)
	assert_equal(3, get_counter())
	float32 y = scale(1.5, 4)
	assert_equal(1, y == 6.0)
	println(c"wasm export test: main OK")
	return 0
