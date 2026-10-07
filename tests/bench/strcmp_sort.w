# bench strcmp_sort: list[char*].sort() over size pseudo-random lowercase
# words (6-13 letters). The work is the runtime's stable merge sort
# (structures/w_list.w __w_list_merge_sort) and its inline string
# compare (lib/lib.w strcmp was 6% of the self-compile, §1.2). The
# checksum folds every byte of the sorted sequence. C twin:
# tests/bench/c/strcmp_sort.c, a port of the runtime's sort.
# wbuild: target=bench_strcmp_sort tag=bench dep=wv2
# wbuild: step="bin/wv2 tests/bench/strcmp_sort.w -o bin/bench_strcmp_sort"
# wbuild: step="bin/bench_strcmp_sort" expect_stdout="strcmp_sort size=500000 checksum=69090b9d"
# wbuild: step="bin/wv2 x64 tests/bench/strcmp_sort.w -o bin/bench_strcmp_sort_64"
# wbuild: step="bin/bench_strcmp_sort_64" expect_stdout="strcmp_sort size=500000 checksum=69090b9d"
# wbuild: target=bench_strcmp_sort_smoke_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/bench/strcmp_sort.w -o bin/bench_strcmp_sort_smoke"
# wbuild: step="bin/bench_strcmp_sort_smoke 1000" expect_stdout="strcmp_sort size=1000 checksum=e9e8d5c2"
# wbuild: step="bin/wv2 x64 tests/bench/strcmp_sort.w -o bin/bench_strcmp_sort_smoke_64"
# wbuild: step="bin/bench_strcmp_sort_smoke_64 1000" expect_stdout="strcmp_sort size=1000 checksum=e9e8d5c2"
import lib.lib
import tests.bench.bench_lib


int main(int argc, char** argv):
	int n = bench_size(argc, argv, 500000)
	list[char*] words = new list[char*]
	int state = 123456789
	int i = 0
	while (i < n):
		int len = 6 + (bench_rand(&state) & 7)
		char* w = malloc(len + 1)
		int j = 0
		while (j < len):
			# Mask off bit 31 before the modulo: the 32-bit host would see a
			# negative word and divide it differently from the 64-bit one.
			w[j] = 'a' + ((bench_rand(&state) & 0x7fffffff) % 26)
			j = j + 1
		w[len] = 0
		words.push(w)
		i = i + 1
	words.sort()
	int h = 0
	i = 0
	while (i < n):
		char* w = words[i]
		int j = 0
		while (w[j] != 0):
			h = bench_fold(h, w[j])
			j = j + 1
		h = bench_fold(h, 0)
		i = i + 1
	bench_report(c"strcmp_sort", n, h)
	return 0
