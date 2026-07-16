# Constructors fatally assert positive extents (docs/projects/ndarray.md
# "Construction and allocation": "a silent garbage descriptor is
# indistinguishable from a real one").
# wbuild: expect_fail
# wbuild: expect_stderr="ndarray: extents must be positive"
# wbuild: expect_stderr="stack trace (most recent call first):"
# wbuild: expect_stderr="at main ("
import lib.lib
import lib.ndarray


void main():
	ndf a = ndf_new2(3, 0)
