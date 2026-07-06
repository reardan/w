# Binary search helpers for sorted int buffers.
#
# The caller owns sortedness. Bounds are [0, length); negative lengths are
# treated as empty because no valid insertion point can be beyond zero.

int bisect_left_int(int* values, int length, int x):
	int lo = 0
	int hi = length
	if (hi < 0):
		hi = 0
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (values[mid] < x):
			lo = mid + 1
		else:
			hi = mid
	return lo


int bisect_right_int(int* values, int length, int x):
	int lo = 0
	int hi = length
	if (hi < 0):
		hi = 0
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (values[mid] <= x):
			lo = mid + 1
		else:
			hi = mid
	return lo
