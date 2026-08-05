# ndarray elements are out of scope for '++'/'--' v1, exactly like
# map/set elements (grammar/increment.w): spell it 'm[i, j] += 1'.
# expect_fail
# expect_stderr: '++' and '--' are not supported on ndarray elements
import lib.ndarray

int main():
	ndi a = ndi_new2(2, 2)
	a[0, 1]++
	return 0
