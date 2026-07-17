# lib/ndarray.w's default accessors are per-axis checked unconditionally
# (docs/projects/ndarray.md "Bounds policy"): a wrapped column index that
# would still land inside the flat buffer (j >= n1 with i*s0 + j still
# in range) must still trap, which a bare slice bounds check on `.data`
# alone cannot catch.
# wbuild: expect_fail
# wbuild: expect_stderr="ndf_at2: index out of range"
# wbuild: expect_stderr="stack trace (most recent call first):"
# wbuild: expect_stderr="at main ("
import lib.lib
import lib.ndarray


void main():
	ndf a = ndf_new2(3, 2)
	# flat index 0*a.s0 + 3 == 3, still inside the 6-element buffer, but
	# j == 3 is out of range for axis 1 (n1 == 2): must still trap.
	ndf_at2(&a, 0, 3)
