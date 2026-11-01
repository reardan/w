/* Port of the container runtime's hash table (structures/hash_table.w)
 * for the C twins of the map benchmarks (siphash_keys.c, map_ops.c): a
 * compact dict -- entries [hash][key][value] in insertion order, plus an
 * open-addressing index of (entry + 1, hash) int32 pairs with linear
 * probing and tombstones, rebuilt (doubled, or compacted at the same
 * size when at least half the entries are dead) when the entries array,
 * half the index size, fills up. String keys hash with HalfSipHash-1-3,
 * word keys with the keyed murmur3-style finalizer; char* keys are
 * cloned. The one difference: the W table draws a random seed from
 * getrandom(2) per process; this port uses a fixed seed. The hashing
 * cost does not depend on the seed and neither do the checksums.
 * Values are word-sized (the scalar-value layout). */
#ifndef W_HASH_TABLE_H
#define W_HASH_TABLE_H
#include "bench.h"

#define KEY_WORD 1
#define KEY_CSTR 2

typedef struct {
	word capacity;  /* index slots, a power of two */
	word count;     /* live entries */
	word key_kind;
	int32_t* index; /* capacity pairs: entry word (0 empty, -1 tombstone, k > 0 entry k - 1), hash */
	word* entries;  /* entry i: [3i] hash (-1 when removed), [3i + 1] key, [3i + 2] value */
	word used;      /* entries appended, live and dead */
	word entry_cap; /* capacity / 2 */
	uint32_t seed0;
	uint32_t seed1;
} table;

static uint32_t rotl32(uint32_t x, int n) {
	return (x << n) | (x >> (32 - n));
}

static uint32_t hash_sip(table* t, const unsigned char* p, word length) {
	uint32_t v0 = t->seed0;
	uint32_t v1 = t->seed1;
	uint32_t v2 = 0x6c796765 ^ v0;
	uint32_t v3 = 0x74656462 ^ v1;
	word i = 0;
	int done = 0;
	while (done == 0) {
		uint32_t m = 0;
		if (length - i >= 4) {
			memcpy(&m, p + i, 4);
			i = i + 4;
		} else {
			m = (uint32_t)length << 24;
			int shift = 0;
			while (i < length) {
				m = m | ((uint32_t)p[i] << shift);
				shift = shift + 8;
				i = i + 1;
			}
			done = 1;
		}
		v3 = v3 ^ m;
		v0 = v0 + v1;
		v1 = rotl32(v1, 5) ^ v0;
		v0 = rotl32(v0, 16);
		v2 = v2 + v3;
		v3 = rotl32(v3, 8) ^ v2;
		v0 = v0 + v3;
		v3 = rotl32(v3, 7) ^ v0;
		v2 = v2 + v1;
		v1 = rotl32(v1, 13) ^ v2;
		v2 = rotl32(v2, 16);
		v0 = v0 ^ m;
	}
	v2 = v2 ^ 255;
	int r = 0;
	while (r < 3) {
		v0 = v0 + v1;
		v1 = rotl32(v1, 5) ^ v0;
		v0 = rotl32(v0, 16);
		v2 = v2 + v3;
		v3 = rotl32(v3, 8) ^ v2;
		v0 = v0 + v3;
		v3 = rotl32(v3, 7) ^ v0;
		v2 = v2 + v1;
		v1 = rotl32(v1, 13) ^ v2;
		v2 = rotl32(v2, 16);
		r = r + 1;
	}
	return v1 ^ v3;
}

static word hash_word(table* t, uword key) {
	uint32_t h = (uint32_t)key ^ t->seed0;
	if (sizeof(uword) == 8) {
		h = h * 0x9e3779b1u;
		h = h ^ (h >> 15);
		h = h + (uint32_t)((uint64_t)key >> 32);
	}
	h = h + t->seed1;
	h = h ^ (h >> 16);
	h = h * 0x85ebca6bu;
	h = h ^ (h >> 13);
	h = h * 0xc2b2ae35u;
	h = h ^ (h >> 16);
	return (word)(h & 0x7fffffff);
}

static word key_hash(table* t, uword key) {
	if (t->key_kind == KEY_CSTR) return (word)(hash_sip(t, (const unsigned char*)key, (word)strlen((const char*)key)) & 0x7fffffff);
	return hash_word(t, key);
}

static int key_equal(word kind, uword left, uword right) {
	if (left == right) return 1;
	if (kind == KEY_CSTR) return strcmp((const char*)left, (const char*)right) == 0;
	return 0;
}

static uword key_clone(word kind, uword key) {
	if (kind == KEY_CSTR) {
		size_t n = strlen((const char*)key) + 1;
		char* copy = malloc(n);
		memcpy(copy, (const char*)key, n);
		return (uword)copy;
	}
	return key;
}

static void table_alloc(table* t, word capacity) {
	t->capacity = capacity;
	t->index = calloc(capacity, 2 * sizeof(int32_t));
	t->entry_cap = capacity / 2;
	t->entries = malloc(t->entry_cap * 3 * sizeof(word));
	t->used = 0;
	t->count = 0;
}

static table* table_new(word key_kind) {
	table* t = calloc(1, sizeof(table));
	t->key_kind = key_kind;
	t->seed0 = 0x243f6a88;
	t->seed1 = 0x85a308d3;
	table_alloc(t, 16);
	return t;
}

/* Index position of key (even), or -1 - (the slot a new key takes). */
static word table_probe(table* t, uword key, word hv) {
	word mask = t->capacity * 2 - 1;
	word q = (hv + hv) & mask;
	word tomb = -1;
	for (;;) {
		word slot = t->index[q];
		if (slot > 0) {
			if (t->index[q + 1] == hv && key_equal(t->key_kind, (uword)t->entries[3 * (slot - 1) + 1], key)) return q;
		} else if (slot == 0) {
			return tomb >= 0 ? -1 - tomb : -1 - q;
		} else if (tomb < 0) tomb = q;
		q = (q + 2) & mask;
	}
}

static void rehash(table* t, word new_capacity) {
	int32_t* old_index = t->index;
	word* old = t->entries;
	word old_used = t->used;
	table_alloc(t, new_capacity);
	word mask = new_capacity * 2 - 1;
	word n = 0;
	for (word i = 0; i < old_used; i++) {
		word hv = old[3 * i];
		if (hv < 0) continue;
		t->entries[3 * n] = hv;
		t->entries[3 * n + 1] = old[3 * i + 1];
		t->entries[3 * n + 2] = old[3 * i + 2];
		word q = (hv + hv) & mask;
		while (t->index[q] != 0) q = (q + 2) & mask;
		n = n + 1;
		t->index[q] = (int32_t)n;
		t->index[q + 1] = (int32_t)hv;
	}
	t->used = n;
	t->count = n;
	free(old_index);
	free(old);
}

static inline word table_find(table* t, uword key) {
	word q = table_probe(t, key, key_hash(t, key));
	if (q < 0) return -1;
	return t->index[q] - 1;
}

static word insert_slot(table* t, uword key) {
	word hv = key_hash(t, key);
	word q = table_probe(t, key, hv);
	if (q >= 0) return t->index[q] - 1;
	if (t->used >= t->entry_cap) {
		if (t->count * 2 <= t->used) rehash(t, t->capacity);
		else rehash(t, t->capacity * 2);
		q = table_probe(t, key, hv);
	}
	q = -1 - q;
	word i = t->used;
	t->entries[3 * i] = hv;
	t->entries[3 * i + 1] = (word)key_clone(t->key_kind, key);
	t->entries[3 * i + 2] = 0;
	t->index[q] = (int32_t)(i + 1);
	t->index[q + 1] = (int32_t)hv;
	t->used = i + 1;
	t->count = t->count + 1;
	return i;
}

static inline void map_set(table* t, uword key, uword value) {
	word i = insert_slot(t, key);
	t->entries[3 * i + 2] = (word)value;
}

static inline uword map_add(table* t, uword key, uword delta) {
	word i = insert_slot(t, key);
	t->entries[3 * i + 2] = (word)((uword)t->entries[3 * i + 2] + delta);
	return (uword)t->entries[3 * i + 2];
}

static inline uword map_get(table* t, uword key) {
	word i = table_find(t, key);
	if (i < 0) {
		fprintf(stderr, "map key not found\n");
		exit(1);
	}
	return (uword)t->entries[3 * i + 2];
}

static inline uword map_get_or(table* t, uword key, uword fallback) {
	word i = table_find(t, key);
	if (i < 0) return fallback;
	return (uword)t->entries[3 * i + 2];
}

static inline int map_remove(table* t, uword key) {
	word q = table_probe(t, key, key_hash(t, key));
	if (q < 0) return 0;
	word i = t->index[q] - 1;
	if (t->key_kind == KEY_CSTR) free((void*)t->entries[3 * i + 1]);
	t->entries[3 * i] = -1;
	t->entries[3 * i + 1] = 0;
	t->index[q] = -1;
	t->count = t->count - 1;
	return 1;
}

/* Iteration cursor: the next live entry at or after i, -1 at the end. */
static inline word map_next_live(table* t, word i) {
	while (i < t->used) {
		if (t->entries[3 * i] >= 0) return i;
		i = i + 1;
	}
	return -1;
}

#endif
