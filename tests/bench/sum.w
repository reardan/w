# bench sum: the two-local summation loop of
# docs/projects/register_allocation_pgo.md §1.1/§1.3 -- the smallest loop
# the register allocator can improve. size = n; the sum wraps in the
# word, the checksum is its low 32 bits. C twin: tests/bench/c/sum.c.
# wbuild: target=bench_sum tag=bench dep=wv2
# wbuild: step="bin/wv2 tests/bench/sum.w -o bin/bench_sum"
# wbuild: step="bin/bench_sum" expect_stdout="sum size=600000000 checksum=c9b05d00"
# wbuild: step="bin/wv2 x64 tests/bench/sum.w -o bin/bench_sum_64"
# wbuild: step="bin/bench_sum_64" expect_stdout="sum size=600000000 checksum=c9b05d00"
# wbuild: target=bench_sum_smoke_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/bench/sum.w -o bin/bench_sum_smoke"
# wbuild: step="bin/bench_sum_smoke 1000" expect_stdout="sum size=1000 checksum=00079f2c"
# wbuild: step="bin/wv2 x64 tests/bench/sum.w -o bin/bench_sum_smoke_64"
# wbuild: step="bin/bench_sum_smoke_64 1000" expect_stdout="sum size=1000 checksum=00079f2c"
import lib.lib
import tests.bench.bench_lib


int sum_to(int n):
	int i = 0
	int s = 0
	while (i < n):
		s = s + i
		i = i + 1
	return s


int main(int argc, char** argv):
	int n = bench_size(argc, argv, 600000000)
	int s = sum_to(n)
	bench_report(c"sum", n, s & bench_mask32())
	return 0
