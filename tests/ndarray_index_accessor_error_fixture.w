# Comma-index dispatch is by struct name, but the lowering is a plain
# symbol lookup: a struct merely NAMED ndf without lib/ndarray.w's
# accessor family in scope is a compile error naming the missing
# accessor (grammar/ndarray_index.w).
# expect_fail
# expect_stderr: ndarray index requires accessor 'ndf_at2' in scope
struct ndf:
	int rank
	int n0

int main():
	ndf a
	a.rank = 2
	int v = a[1, 2]
	return v
