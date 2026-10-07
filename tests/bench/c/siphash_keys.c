/* C twin of tests/bench/siphash_keys.w (see bench.h): a port of the
 * container runtime's hash table (structures/hash_table.w) -- HalfSipHash-1-3
 * over the key bytes, linear probing with tombstone states, growth at 3/4
 * load that re-inserts in insertion order, insertion-order links, and
 * cloned string keys. The one difference: the W table draws a random
 * seed from getrandom(2) per process; this port uses a fixed seed. The
 * hashing cost does not depend on the seed and neither checksum does. */
#include "bench.h"

#define KEY_WORD 1
#define KEY_CSTR 2

typedef struct {
	word capacity;
	word count;
	word key_kind;
	uword* keys;
	uword* values;
	char* states;
	word* order_next;
	word* order_prev;
	word order_head;
	word order_tail;
	word deleted;
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

static uint32_t key_hash(table* t, uword key) {
	if (t->key_kind == KEY_CSTR) return hash_sip(t, (const unsigned char*)key, (word)strlen((const char*)key));
	uword w = key;
	return hash_sip(t, (const unsigned char*)&w, sizeof(uword));
}

static int key_equal(word kind, uword left, uword right) {
	if (kind == KEY_CSTR) return strcmp((const char*)left, (const char*)right) == 0;
	return left == right;
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

static void order_link(table* t, word i) {
	t->order_next[i] = -1;
	t->order_prev[i] = t->order_tail;
	if (t->order_tail >= 0) t->order_next[t->order_tail] = i;
	else t->order_head = i;
	t->order_tail = i;
}

static void table_alloc(table* t, word capacity) {
	t->capacity = capacity;
	t->count = 0;
	t->deleted = 0;
	t->keys = calloc(capacity, sizeof(uword));
	t->values = calloc(capacity, sizeof(uword));
	t->states = calloc(capacity, 1);
	t->order_next = malloc(capacity * sizeof(word));
	t->order_prev = malloc(capacity * sizeof(word));
	t->order_head = -1;
	t->order_tail = -1;
}

static table* table_new(word key_kind) {
	table* t = calloc(1, sizeof(table));
	t->key_kind = key_kind;
	t->seed0 = 0x243f6a88;
	t->seed1 = 0x85a308d3;
	table_alloc(t, 16);
	return t;
}

static word table_slot(table* t, uword key) {
	word mask = t->capacity - 1;
	word i = key_hash(t, key) & mask;
	word first_deleted = -1;
	word probes = 0;
	while (t->states[i] != 0 && probes < t->capacity) {
		if (t->states[i] == 1) {
			if (key_equal(t->key_kind, t->keys[i], key)) return i;
		} else if (first_deleted < 0) first_deleted = i;
		i = (i + 1) & mask;
		probes = probes + 1;
	}
	if (first_deleted >= 0) return first_deleted;
	return i;
}

static void move_owned(table* t, uword key, uword value) {
	word i = table_slot(t, key);
	if (t->states[i] != 1) {
		t->states[i] = 1;
		t->keys[i] = key;
		t->count = t->count + 1;
		order_link(t, i);
	}
	t->values[i] = value;
}

static void rehash(table* t, word new_capacity) {
	uword* old_keys = t->keys;
	uword* old_values = t->values;
	char* old_states = t->states;
	word* old_next = t->order_next;
	word* old_prev = t->order_prev;
	word old_head = t->order_head;
	table_alloc(t, new_capacity);
	word i = old_head;
	while (i >= 0) {
		move_owned(t, old_keys[i], old_values[i]);
		i = old_next[i];
	}
	free(old_keys);
	free(old_values);
	free(old_states);
	free(old_next);
	free(old_prev);
}

static void reserve_one(table* t) {
	if ((t->count + t->deleted) * 4 < t->capacity * 3) return;
	if (t->deleted > t->count) rehash(t, t->capacity);
	else rehash(t, t->capacity * 2);
}

static word insert_slot(table* t, uword key) {
	reserve_one(t);
	word i = table_slot(t, key);
	if (t->states[i] != 1) {
		if (t->states[i] == 2) t->deleted = t->deleted - 1;
		t->states[i] = 1;
		t->keys[i] = key_clone(t->key_kind, key);
		t->count = t->count + 1;
		order_link(t, i);
	}
	return i;
}

static void map_set(table* t, uword key, uword value) {
	word i = insert_slot(t, key);
	t->values[i] = value;
}

static uword map_get(table* t, uword key) {
	word i = table_slot(t, key);
	if (t->states[i] != 1) {
		fprintf(stderr, "siphash_keys: missing key\n");
		exit(1);
	}
	return t->values[i];
}

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
