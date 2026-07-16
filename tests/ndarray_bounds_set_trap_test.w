# Mirrors ndarray_bounds_get_trap_test.w for the set side: setN traps
# on the same per-axis check as atN (docs/projects/ndarray.md "Bounds
# policy").
# wbuild: expect_fail
# wbuild: expect_stderr="ndf_set2: index out of range"
# wbuild: expect_stderr="stack trace (most recent call first):"
# wbuild: expect_stderr="at main ("
import lib.lib
import lib.ndarray


void main():
	ndf a = ndf_new2(3, 2)
	ndf_set2(&a, 0, 3, 1.0)
