# bench sieve: sieve of Eratosthenes over a byte array -- a loop nest
# whose inner loop is a strided store with two live locals (the stride and
# the index). size = the sieve limit; the checksum folds the prime count
# and every prime found. C twin: tests/bench/c/sieve.c.
# wbuild: target=bench_sieve tag=bench dep=wv2
# wbuild: step="bin/wv2 tests/bench/sieve.w -o bin/bench_sieve"
# wbuild: step="bin/bench_sieve" expect_stdout="sieve size=40000000 checksum=ea9b9c0f"
# wbuild: step="bin/wv2 x64 tests/bench/sieve.w -o bin/bench_sieve_64"
# wbuild: step="bin/bench_sieve_64" expect_stdout="sieve size=40000000 checksum=ea9b9c0f"
# wbuild: target=bench_sieve_smoke_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/bench/sieve.w -o bin/bench_sieve_smoke"
# wbuild: step="bin/bench_sieve_smoke 1000" expect_stdout="sieve size=1000 checksum=be29980b"
# wbuild: step="bin/wv2 x64 tests/bench/sieve.w -o bin/bench_sieve_smoke_64"
# wbuild: step="bin/bench_sieve_smoke_64 1000" expect_stdout="sieve size=1000 checksum=be29980b"
import lib.lib
import tests.bench.bench_lib


int sieve(int n):
	char* composite = malloc(n + 1)
	int i = 0
	while (i <= n):
		composite[i] = 0
		i = i + 1
	i = 2
	while (i * i <= n):
		if (composite[i] == 0):
			int j = i * i
			while (j <= n):
				composite[j] = 1
				j = j + i
		i = i + 1
	int count = 0
	int h = 0
	i = 2
	while (i <= n):
		if (composite[i] == 0):
			count = count + 1
			h = bench_fold(h, i)
		i = i + 1
	free(composite)
	return bench_fold(h, count)


int main(int argc, char** argv):
	int n = bench_size(argc, argv, 40000000)
	bench_report(c"sieve", n, sieve(n))
	return 0
