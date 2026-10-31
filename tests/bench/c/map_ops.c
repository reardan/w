/* C twin of tests/bench/map_ops.w (see bench.h), on the port of the
 * container runtime's hash table in w_hash_table.h. */
#include "w_hash_table.h"

int main(int argc, char** argv) {
	word n = bench_size(argc, argv, 2000000);
	uint32_t h = 0;

	table* ints = table_new(KEY_WORD);
	word i = 0;
	while (i < n) {
		map_set(ints, (uword)i, (uint32_t)((uword)i * 2654435));
		i = i + 1;
	}
	i = 0;
	while (i < n) {
		h = bench_fold(h, (uint32_t)map_get(ints, (uword)i));
		i = i + 1;
	}

	table* counts = table_new(KEY_WORD);
	i = 0;
	while (i < n) {
		map_add(counts, (uword)((i * 7) & 1023), (uword)(i & 15));
		i = i + 1;
	}
	i = 0;
	while (i < 1024) {
		h = bench_fold(h, (uint32_t)map_get_or(counts, (uword)i, 0));
		i = i + 1;
	}

	i = 0;
	while (i < n) {
		map_remove(ints, (uword)i);
		map_set(ints, (uword)(n + i), (uword)i);
		i = i + 2;
	}
	h = bench_fold(h, (uint32_t)ints->count);
	for (word c = map_next_live(ints, 0); c >= 0; c = map_next_live(ints, c + 1)) {
		uword key = (uword)ints->entries[3 * c + 1];
		uword value = (uword)ints->entries[3 * c + 2];
		h = bench_fold(h, (uint32_t)(key * 31 + value));
	}

	/* The W program builds each key with itoa + strjoin (two mallocs) and
	 * frees them; keep the allocation in the loop here too. */
	table* strs = table_new(KEY_CSTR);
	word m = n / 4;
	i = 0;
	while (i < m) {
		char* key = malloc(32);
		snprintf(key, 32, "item-%ld", (long)i);
		map_set(strs, (uword)key, (uword)i);
		free(key);
		i = i + 1;
	}
	i = 0;
	while (i < m) {
		char* key = malloc(32);
		snprintf(key, 32, "item-%ld", (long)i);
		h = bench_fold(h, (uint32_t)map_get(strs, (uword)key));
		free(key);
		i = i + 1;
	}
	h = bench_fold(h, (uint32_t)strs->count);
	bench_report("map_ops", n, h);
	return 0;
}
