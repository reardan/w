# bench siphash_keys: map inserts and lookups -- size int keys into a
# map[int, int] and size/2 string keys into a map[char*, int]. The work
# is the container runtime's HalfSipHash (structures/hash_table.w
# __w_hash_sip, 12% of the self-compile, §1.2) and its linear-probing
# slot search, including table growth and insertion-order links. The
# checksum folds every value read back, so it does not depend on the
# process's random hash seed. C twin: tests/bench/c/siphash_keys.c, a
# port of the runtime's table (with a fixed seed).
# wbuild: target=bench_siphash_keys tag=bench dep=wv2
# wbuild: step="bin/wv2 tests/bench/siphash_keys.w -o bin/bench_siphash_keys"
# wbuild: step="bin/bench_siphash_keys" expect_stdout="siphash_keys size=500000 checksum=462cc7d8"
# wbuild: step="bin/wv2 x64 tests/bench/siphash_keys.w -o bin/bench_siphash_keys_64"
# wbuild: step="bin/bench_siphash_keys_64" expect_stdout="siphash_keys size=500000 checksum=462cc7d8"
# wbuild: target=bench_siphash_keys_smoke_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/bench/siphash_keys.w -o bin/bench_siphash_keys_smoke"
# wbuild: step="bin/bench_siphash_keys_smoke 1000" expect_stdout="siphash_keys size=1000 checksum=814a4fae"
# wbuild: step="bin/wv2 x64 tests/bench/siphash_keys.w -o bin/bench_siphash_keys_smoke_64"
# wbuild: step="bin/bench_siphash_keys_smoke_64 1000" expect_stdout="siphash_keys size=1000 checksum=814a4fae"
import lib.lib
import tests.bench.bench_lib


int main(int argc, char** argv):
	int n = bench_size(argc, argv, 500000)
	int mask = bench_mask32()
	map[int, int] ints = new map[int, int]
	int i = 0
	while (i < n):
		ints[i * 7919] = (i * 2654435) & mask
		i = i + 1
	int h = 0
	i = 0
	while (i < n):
		h = bench_fold(h, ints[i * 7919])
		i = i + 1
	h = bench_fold(h, ints.length)

	map[char*, int] strs = new map[char*, int]
	int m = n / 2
	i = 0
	while (i < m):
		char* num = itoa(i)
		char* key = strjoin(c"key-", num)
		strs[key] = i
		free(key)
		free(num)
		i = i + 1
	i = 0
	while (i < m):
		char* num = itoa(i)
		char* key = strjoin(c"key-", num)
		h = bench_fold(h, strs[key])
		free(key)
		free(num)
		i = i + 1
	h = bench_fold(h, strs.length)
	bench_report(c"siphash_keys", n, h)
	return 0
