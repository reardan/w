# wbuild: x64
# lib/byte_map.w: binary keys with embedded NULs, key ownership, limits,
# seed-independent sorted iteration, and the HalfSipHash-2-4 / FNV-1a
# known-answer vectors (masked 32-bit words, so x86 and x64 agree).
import lib.testing
import lib.byte_map
import libs.standard.crypto.random


int word32(int high, int low):
	return ((high << 16) | low) & bytes_mask32()


# HalfSipHash reference key 00 01 .. 07 as little-endian words.
int ref_k0():
	return 0x03020100


int ref_k1():
	return 0x07060504


int ref_hash(int n):
	char* msg = malloc(16)
	for i in range(n): msg[i] = i
	int h = bytes_hash_seeded(ref_k0(), ref_k1(), msg, n)
	free(msg)
	return h


# Vectors from the SipHash reference implementation's vectors_hsip32
# (output bytes little-endian), message = 00 01 .. n-1.
void test_halfsiphash_vectors():
	assert_equal(word32(0x5b9f, 0x35a9), ref_hash(0))
	assert_equal(word32(0xb85a, 0x4727), ref_hash(1))
	assert_equal(word32(0x03a6, 0x62fa), ref_hash(2))
	assert_equal(word32(0x04e7, 0xfe8a), ref_hash(3))
	assert_equal(word32(0x8946, 0x6e2a), ref_hash(4))
	assert_equal(word32(0xc563, 0xcf8b), ref_hash(7))
	assert_equal(word32(0x8f84, 0xb8d0), ref_hash(8))


void test_seeded_hash_depends_on_seed():
	int a = bytes_hash_seeded(1, 2, c"a\x00b", 3)
	int b = bytes_hash_seeded(1, 3, c"a\x00b", 3)
	assert1(a != b)
	assert1(bytes_hash_seeded(1, 2, c"a\x00b", 3) != bytes_hash_seeded(1, 2, c"a\x00c", 3))
	# Sign-extended and masked spellings of a key word hash alike.
	int m = bytes_mask32()
	int neg = cast(int, 0x80000001)
	assert_equal(bytes_hash_seeded(neg & m, 2, c"x", 1), bytes_hash_seeded(neg, 2, c"x", 1))


void test_stable_hash_vectors():
	assert_equal(word32(0x811c, 0x9dc5), bytes_hash_stable(c"", 0))
	assert_equal(word32(0xe40c, 0x292c), bytes_hash_stable(c"a", 1))
	assert_equal(word32(0xbf9c, 0xf968), bytes_hash_stable(c"foobar", 6))
	assert_equal(word32(0x10f3, 0xabd2), bytes_hash_stable(c"a\x00b", 3))


void test_embedded_nul_keys_are_distinct():
	byte_map* m = byte_map_new(11, 22)
	assert_equal(BYTES_OK, byte_map_put(m, c"a\x00b", 3, 1))
	assert_equal(BYTES_OK, byte_map_put(m, c"a\x00c", 3, 2))
	assert_equal(BYTES_OK, byte_map_put(m, c"a", 1, 3))
	assert_equal(BYTES_OK, byte_map_put(m, c"a\x00", 2, 4))
	assert_equal(BYTES_OK, byte_map_put(m, c"", 0, 5))
	assert_equal(5, byte_map_count(m))
	int v = 0
	assert_equal(1, byte_map_get(m, c"a\x00b", 3, &v))
	assert_equal(1, v)
	assert_equal(1, byte_map_get(m, c"a\x00c", 3, &v))
	assert_equal(2, v)
	assert_equal(1, byte_map_get(m, c"a", 1, &v))
	assert_equal(3, v)
	assert_equal(1, byte_map_get(m, c"a\x00", 2, &v))
	assert_equal(4, v)
	assert_equal(1, byte_map_get(m, c"", 0, &v))
	assert_equal(5, v)
	assert_equal(0, byte_map_get(m, c"a\x00\x00", 3, &v))
	assert_equal(0, v)
	assert_equal(0, byte_map_contains(m, c"b", 1))
	# Overwrite keeps the count.
	assert_equal(BYTES_OK, byte_map_put(m, c"a\x00b", 3, 10))
	assert_equal(5, byte_map_count(m))
	assert_equal(1, byte_map_get(m, c"a\x00b", 3, &v))
	assert_equal(10, v)
	byte_map_free(m)


void test_keys_are_copied():
	byte_map* m = byte_map_new(1, 2)
	char* key = malloc(4)
	key[0] = 'k'
	key[1] = 0
	key[2] = 'z'
	key[3] = 0
	assert_equal(BYTES_OK, byte_map_put(m, key, 3, 7))
	key[2] = 'y'  # the caller's buffer no longer matters
	free(key)
	int v = 0
	assert_equal(1, byte_map_get(m, c"k\x00z", 3, &v))
	assert_equal(7, v)
	byte_map_entry* e = byte_map_find(m, c"k\x00z", 3)
	assert_equal(3, e.key_length)
	assert_bytes_equal(c"k\x00z", e.key, 3)
	byte_map_free(m)


void test_remove():
	byte_map* m = byte_map_new(5, 6)
	byte_map_put(m, c"one", 3, 1)
	byte_map_put(m, c"two", 3, 2)
	int old = 0
	assert_equal(1, byte_map_remove(m, c"one", 3, &old))
	assert_equal(1, old)
	assert_equal(0, byte_map_remove(m, c"one", 3, &old))
	assert_equal(1, byte_map_count(m))
	assert_equal(0, byte_map_contains(m, c"one", 3))
	assert_equal(1, byte_map_contains(m, c"two", 3))
	assert_equal(1, byte_map_remove(m, c"two", 3, cast(int*, 0)))
	assert_equal(0, byte_map_count(m))
	assert_equal(BYTES_INVALID, byte_map_put(m, c"x", 0 - 1, 0))
	assert_equal(0, byte_map_remove(m, c"x", 0 - 1, &old))
	byte_map_free(m)


void test_limits():
	byte_map* m = byte_map_new(1, 1)
	byte_map_set_limits(m, 2, 4)
	assert_equal(BYTES_TOO_LARGE, byte_map_put(m, c"12345", 5, 0))
	assert_equal(BYTES_OK, byte_map_put(m, c"1234", 4, 0))
	assert_equal(BYTES_OK, byte_map_put(m, c"ab", 2, 0))
	assert_equal(BYTES_TOO_LARGE, byte_map_put(m, c"cd", 2, 0))
	# Overwriting an existing key is not a new entry.
	assert_equal(BYTES_OK, byte_map_put(m, c"ab", 2, 9))
	assert_equal(2, byte_map_count(m))
	byte_map_free(m)


void fill(byte_map* m, int n):
	char* key = malloc(4)
	for i in range(n):
		store_be32(key, i * 7919)
		assert_equal(BYTES_OK, byte_map_put(m, key, 4, i))
	free(key)


void test_growth_and_lookup():
	byte_map* m = byte_map_new(123, 456)
	fill(m, 2000)
	assert_equal(2000, byte_map_count(m))
	assert1(m.bucket_count >= 2000)
	char* key = malloc(4)
	int v = 0
	for i in range(2000):
		store_be32(key, i * 7919)
		assert_equal(1, byte_map_get(m, key, 4, &v))
		assert_equal(i, v)
	free(key)
	byte_map_free(m)


void test_sorted_is_unsigned_and_seed_independent():
	byte_map* a = byte_map_new(1, 2)
	byte_map* b = byte_map_new(99, 98)
	char* keys = c"\xff|\x7f|\x80|a|a\x00|\x00|ab"
	# Split the 15 bytes on '|' into keys of varying length.
	int n = 15
	int start = 0
	for i in range(n + 1):
		if ((i == n) || (keys[i] == '|')):
			byte_map_put(a, &keys[start], i - start, i)
			byte_map_put(b, &keys[start], i - start, i)
			start = i + 1
	assert_equal(7, byte_map_count(a))
	byte_map_entry** sa = byte_map_sorted(a)
	byte_map_entry** sb = byte_map_sorted(b)
	for i in range(7):
		assert_equal(1, bytes_equal(sa[i].key, sa[i].key_length, sb[i].key, sb[i].key_length))
		if (i > 0): assert_equal(0 - 1, byte_map_entry_compare(sa[i - 1], sa[i]))
	assert_bytes_equal(c"\x00", sa[0].key, 1)
	assert_equal(1, sa[1].key_length)
	assert_bytes_equal(c"a", sa[1].key, 1)
	assert_bytes_equal(c"a\x00", sa[2].key, 2)
	assert_bytes_equal(c"ab", sa[3].key, 2)
	assert_equal(2, sa[3].key_length)
	assert_equal(2, sa[2].key_length)
	assert_bytes_equal(c"\x7f", sa[4].key, 1)
	assert_bytes_equal(c"\x80", sa[5].key, 1)
	assert_bytes_equal(c"\xff", sa[6].key, 1)
	free(cast(void*, sa))
	free(cast(void*, sb))
	byte_map_free(a)
	byte_map_free(b)


void test_sorted_large_and_empty():
	byte_map* m = byte_map_new(7, 7)
	byte_map_entry** none = byte_map_sorted(m)
	assert1(none != 0)
	free(cast(void*, none))
	fill(m, 300)
	byte_map_entry** s = byte_map_sorted(m)
	for i in range(299):
		assert_equal(0 - 1, byte_map_entry_compare(s[i], s[i + 1]))
	free(cast(void*, s))
	byte_map_free(m)


void test_random_seeded_map():
	char* seed = malloc(8)
	assert_equal(1, random_bytes(seed, 8))
	byte_map* m = byte_map_new(load_le32(seed), load_le32(seed + 4))
	free(seed)
	fill(m, 50)
	int v = 0
	char* key = malloc(4)
	store_be32(key, 49 * 7919)
	assert_equal(1, byte_map_get(m, key, 4, &v))
	assert_equal(49, v)
	free(key)
	byte_map_free(m)
