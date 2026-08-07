# lib/array.w's array_free must refuse a PROPER sub-slice: its data
# pointer lands mid-payload, so the {data, length} words read back from
# just before it (payload elements here, zero-initialized) cannot match
# the view, and the header sanity assert dies instead of handing a
# non-malloc pointer to free.
# wbuild: expect_fail
# wbuild: expect_stderr="array_free: not an unsliced heap array"
import lib.lib
import lib.array


void main():
	int[] a = new int[8]
	array_free[int](a[2:6])
