/* C twin of tests/bench/siphash_keys.w (see bench.h), on the port of the
 * container runtime's hash table in w_hash_table.h (HalfSipHash-1-3 for
 * the string keys, the keyed word finalizer for the int keys, a fixed
 * seed instead of getrandom(2)). The hashing cost does not depend on the
 * seed and neither checksum does. */
#include "w_hash_table.h"

int main(int argc, char** argv) {
	word n = bench_size(argc, argv, 500000);
	table* ints = table_new(KEY_WORD);
	word i = 0;
	while (i < n) {
		map_set(ints, (uword)i * 7919, (uint32_t)((uword)i * 2654435));
		i = i + 1;
	}
	uint32_t h = 0;
	i = 0;
	while (i < n) {
		h = bench_fold(h, (uint32_t)map_get(ints, (uword)i * 7919));
		i = i + 1;
	}
	h = bench_fold(h, (uint32_t)ints->count);

	/* The W program builds each key with itoa + strjoin (two mallocs) and
	 * frees them; keep the allocation in the loop here too. */
	table* strs = table_new(KEY_CSTR);
	word m = n / 2;
	i = 0;
	while (i < m) {
		char* key = malloc(32);
		snprintf(key, 32, "key-%ld", (long)i);
		map_set(strs, (uword)key, (uword)i);
		free(key);
		i = i + 1;
	}
	i = 0;
	while (i < m) {
		char* key = malloc(32);
		snprintf(key, 32, "key-%ld", (long)i);
		h = bench_fold(h, (uint32_t)map_get(strs, (uword)key));
		free(key);
		i = i + 1;
	}
	h = bench_fold(h, (uint32_t)strs->count);
	bench_report("siphash_keys", n, h);
	return 0;
}
