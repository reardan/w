# Captured scalars are device-local copies: a write inside a 'gpu for'
# body would silently vanish on the host side, so scalar captures are
# const-qualified and the write is rejected by the existing
# assignment-to-const enforcement.
# wfixture: x64
# expect_fail
# expect_stderr: assignment to const
import lib.lib
import lib.cuda

int main(int argc, int argv):
	int n = 8
	int total = 0
	int* v = cast(int*, gpu_alloc(n * 8))
	gpu for int i in range(n):
		total = total + v[i]
	return 0
