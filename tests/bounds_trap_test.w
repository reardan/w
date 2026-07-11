# The run must trap: the directives below generate the expect_fail /
# expect_stderr assertions and the compile-only --bounds=off variant
# that used to be a hand-written build.base.json target (PR #265).
# wbuild: expect_fail
# wbuild: expect_stderr="index out of range: index 2, length 2"
# wbuild: expect_stderr="stack trace (most recent call first):"
# wbuild: expect_stderr="at main ("
# wbuild: extra_compile="--bounds=off tests/bounds_trap_test.w -o bin/bounds_trap_test_off"
import lib.lib


void main():
	int[2] values
	values[2] = 1
