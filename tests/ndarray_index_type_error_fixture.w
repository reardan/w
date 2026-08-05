# A comma-separated index list is the ndarray sugar only
# (grammar/ndarray_index.w): on any other type it is a compile error
# naming the offending type, not a silent extra-index parse.
# expect_fail
# expect_stderr: comma-separated indexing requires an ndarray (ndf, ndi or ndf64), got 'int*'
int main():
	int[4] buf
	int* p = &buf[0]
	int v = p[1, 2]
	return v
