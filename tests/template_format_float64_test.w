# wbuild: arch_only=x64
# f-string float64 interpolation: a separate on-demand runtime
# (structures/template_float64.w), since float64 exists only on the
# 64-bit-word targets.
import lib.testing


void check(char* want, string got):
	assert_strings_equal(want, got.data)
	assert_equal(strlen(want), got.length)


void test_float64_values():
	float64 d = 2.718281828
	check(c"2.718282 2.71828183 [   2.72] [-02.718]", f"{d} {d:.8} [{d:7.2}] [{-d:07.3}]")


void test_float64_next_to_float32():
	float f = 1.5
	float64 d = 0.25
	check(c"1.50/0.250", f"{f:.2}/{d:.3}")
