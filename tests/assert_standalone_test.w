# Regression test: lib.assert must compile standalone (docs/projects/
# ai_tooling_next_steps.md, "lib.assert does not compile standalone").
# lib/assert.w calls println2/print2/itoa/hex/strcmp/exit from lib.lib,
# so it has to import lib.lib itself; this file deliberately imports
# ONLY lib.assert (not lib.lib, not lib.testing) and used to fail
# `w check` with "Cannot find symbol: 'println2'". Everything below,
# including the final println2 call, resolves through lib.assert's own
# imports. Only the success paths run: any assertion failure exits 1.
import lib.assert


int main(int argc, int argv):
	asserts(c"asserts holds on a true condition", 1 == 1)
	asserts(c"asserts holds on a nonzero condition", 42)
	assert1(1 == 1)
	assert1(7 < 9)
	assert_equal(5, 2 + 3)
	assert_equal(-1, 0 - 1)
	assert_equal_hex(0xff, 255)
	assert_equal_hex(0, 0)
	assert_strings_equal(c"same", c"same")
	assert_strings_equal(c"", c"")
	println2(c"assert_standalone_test passed")
	return 0
