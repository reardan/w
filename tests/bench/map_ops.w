# bench map_ops: the script-shaped map workloads of
# docs/projects/scripting.md (§1, Phase R1) on the built-in containers
# (structures/hash_table.w): size sequential int keys inserted into a
# map[int, int] and read back (the study's map(2M) row), m.add counting
# into 1024 buckets, add/remove churn that rebuilds the table at the same
# size, an insertion-order walk, and size/4 "item-<i>" keys in a
# map[char*, int]. The checksum folds every value read back and the
# iteration order, neither of which depends on the process's random
# hash seed. C twin: tests/bench/c/map_ops.c, on a port of the runtime's
# table (tests/bench/c/w_hash_table.h, with a fixed seed).
# wbuild: target=bench_map_ops tag=bench dep=wv2
# wbuild: step="bin/wv2 tests/bench/map_ops.w -o bin/bench_map_ops"
# wbuild: step="bin/bench_map_ops" expect_stdout="map_ops size=2000000 checksum=6c881a90"
# wbuild: step="bin/wv2 x64 tests/bench/map_ops.w -o bin/bench_map_ops_64"
# wbuild: step="bin/bench_map_ops_64" expect_stdout="map_ops size=2000000 checksum=6c881a90"
# wbuild: target=bench_map_ops_smoke_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/bench/map_ops.w -o bin/bench_map_ops_smoke"
# wbuild: step="bin/bench_map_ops_smoke 1000" expect_stdout="map_ops size=1000 checksum=98a9059d"
# wbuild: step="bin/wv2 x64 tests/bench/map_ops.w -o bin/bench_map_ops_smoke_64"
# wbuild: step="bin/bench_map_ops_smoke_64 1000" expect_stdout="map_ops size=1000 checksum=98a9059d"
import lib.lib
import tests.bench.bench_lib


int main(int argc, char** argv):
	int n = bench_size(argc, argv, 2000000)
	int mask = bench_mask32()
	int h = 0

	# Sequential int keys: insert, then read every one back.
	map[int, int] ints = new map[int, int]
	int i = 0
	while (i < n):
		ints[i] = (i * 2654435) & mask
		i = i + 1
	i = 0
	while (i < n):
		h = bench_fold(h, ints[i])
		i = i + 1

	# Counting: m.add on a small hot key set.
	map[int, int] counts = new map[int, int]
	i = 0
	while (i < n):
		counts.add((i * 7) & 1023, i & 15)
		i = i + 1
	i = 0
	while (i < 1024):
		h = bench_fold(h, counts.get(i, 0))
		i = i + 1

	# Churn: remove every other key, add as many new ones (the dead
	# entries are compacted away), then walk the result in insertion
	# order.
	i = 0
	while (i < n):
		ints.remove(i)
		ints[n + i] = i
		i = i + 2
	h = bench_fold(h, ints.length)
	for int key, int value in ints:
		h = bench_fold(h, (key * 31 + value) & mask)

	# String keys: "item-<i>", built (and freed) per operation.
	map[char*, int] strs = new map[char*, int]
	int m = n / 4
	i = 0
	while (i < m):
		char* num = itoa(i)
		char* key = strjoin(c"item-", num)
		strs[key] = i
		free(key)
		free(num)
		i = i + 1
	i = 0
	while (i < m):
		char* num = itoa(i)
		char* key = strjoin(c"item-", num)
		h = bench_fold(h, strs[key])
		free(key)
		free(num)
		i = i + 1
	h = bench_fold(h, strs.length)
	bench_report(c"map_ops", n, h)
	return 0
