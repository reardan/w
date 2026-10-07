# bench matmul_256: 256x256 integer matrix product, repeated size times
# with the result fed back as the next left operand. The inner loop is
# the classic three-index nest with an accumulator and two strided loads;
# every element is kept masked to 32 bits so both word sizes print the
# same checksum. C twin: tests/bench/c/matmul_256.c.
# wbuild: target=bench_matmul_256 tag=bench dep=wv2
# wbuild: step="bin/wv2 tests/bench/matmul_256.w -o bin/bench_matmul_256"
# wbuild: step="bin/bench_matmul_256" expect_stdout="matmul_256 size=10 checksum=79f2d642"
# wbuild: step="bin/wv2 x64 tests/bench/matmul_256.w -o bin/bench_matmul_256_64"
# wbuild: step="bin/bench_matmul_256_64" expect_stdout="matmul_256 size=10 checksum=79f2d642"
# wbuild: target=bench_matmul_256_smoke_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/bench/matmul_256.w -o bin/bench_matmul_256_smoke"
# wbuild: step="bin/bench_matmul_256_smoke 1" expect_stdout="matmul_256 size=1 checksum=f01965ec"
# wbuild: step="bin/wv2 x64 tests/bench/matmul_256.w -o bin/bench_matmul_256_smoke_64"
# wbuild: step="bin/bench_matmul_256_smoke_64 1" expect_stdout="matmul_256 size=1 checksum=f01965ec"
import lib.lib
import tests.bench.bench_lib


const int MM_N = 256


void matmul(int* a, int* b, int* out, int n):
	int mask = bench_mask32()
	int i = 0
	while (i < n):
		int j = 0
		while (j < n):
			int acc = 0
			int k = 0
			while (k < n):
				acc = acc + a[i * n + k] * b[k * n + j]
				k = k + 1
			out[i * n + j] = acc & mask
			j = j + 1
		i = i + 1


int main(int argc, char** argv):
	int reps = bench_size(argc, argv, 10)
	int n = MM_N
	int* a = cast(int*, malloc(n * n * __word_size__))
	int* b = cast(int*, malloc(n * n * __word_size__))
	int* out = cast(int*, malloc(n * n * __word_size__))
	int state = 123456789
	int i = 0
	while (i < n * n):
		a[i] = bench_rand(&state) & 0xffff
		b[i] = bench_rand(&state) & 0xffff
		i = i + 1
	int r = 0
	while (r < reps):
		matmul(a, b, out, n)
		int* swap = a
		a = out
		out = swap
		r = r + 1
	int h = 0
	i = 0
	while (i < n * n):
		h = bench_fold(h, a[i])
		i = i + 1
	bench_report(c"matmul_256", reps, h)
	return 0
