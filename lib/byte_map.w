/*
A hash map keyed by arbitrary binary byte strings
(docs/projects/reliable_services.md, W2): embedded NUL bytes are ordinary
key bytes, keys compare by unsigned lexicographic order (bytes_compare),
and the hash is keyed so untrusted keys cannot be chosen to collide.

OWNERSHIP
- Keys are COPIED on insert: the caller's key buffer may be reused or
  freed as soon as byte_map_put returns. The map frees its key copies on
  byte_map_remove and byte_map_free.
- Values are plain words the map never interprets or frees (store a
  pointer with cast(int, p) and free it yourself, e.g. by walking
  byte_map_sorted before byte_map_free).
- Entries handed out by byte_map_find / byte_map_sorted are BORROWED:
  they become invalid at the next put, remove, or free on the map.

HASHING
- byte_map_new(k0, k1) keys HalfSipHash-2-4 (32-bit output, 64-bit key;
  Aumasson & Bernstein's 32-bit-word SipHash variant, chosen because it
  runs on masked 32-bit words identically on x86 and x64). For keys an
  attacker controls, draw k0/k1 from a CSPRNG, e.g. random_bytes in
  libs/standard/crypto/random.w (lib/ stays below libs/, so this module
  takes the seed rather than fetching it).
- Bucket order therefore depends on the seed. Nothing persisted, sent on
  the wire, or compared across processes may depend on a process-random
  seed: iterate with byte_map_sorted (seed-independent order), and use
  bytes_hash_stable (FNV-1a 32, fixed forever) when a format needs a
  stored hash. bytes_hash_stable is NOT flood-resistant; never use it to
  index untrusted keys in memory.

LIMITS
byte_map_set_limits caps the entry count and key length; put reports
BYTES_TOO_LARGE past either cap and BYTES_NO_MEMORY on allocation
failure, leaving the map unchanged.
*/
import lib.lib
import lib.memory
import lib.bytes
import lib.checked
import lib.byte_buf


# ---- hashes -----------------------------------------------------------------

# FNV-1a, 32-bit: offset basis 0x811c9dc5, prime 16777619. A fixed
# function of the bytes on every target, for persisted/stable use. The
# result is a masked 32-bit word.
int bytes_hash_stable(char* data, int length):
	int mask = bytes_mask32()
	int h = ((0x811c << 16) | 0x9dc5) & mask
	for i in range(length):
		h = h ^ (data[i] & 255)
		h = (h * 16777619) & mask
	return h


struct bytes_halfsip:
	int v0
	int v1
	int v2
	int v3


void bytes_halfsip_round(bytes_halfsip* s):
	int mask = bytes_mask32()
	s.v0 = (s.v0 + s.v1) & mask
	s.v1 = rotl(s.v1, 5) ^ s.v0
	s.v0 = rotl(s.v0, 16)
	s.v2 = (s.v2 + s.v3) & mask
	s.v3 = rotl(s.v3, 8) ^ s.v2
	s.v0 = (s.v0 + s.v3) & mask
	s.v3 = rotl(s.v3, 7) ^ s.v0
	s.v2 = (s.v2 + s.v1) & mask
	s.v1 = rotl(s.v1, 13) ^ s.v2
	s.v2 = rotl(s.v2, 16)


void bytes_halfsip_absorb(bytes_halfsip* s, int m):
	s.v3 = s.v3 ^ m
	bytes_halfsip_round(s)
	bytes_halfsip_round(s)
	s.v0 = s.v0 ^ m


# HalfSipHash-2-4 with a 32-bit output. k0/k1 are the key's two
# little-endian 32-bit words (masked words: only their low 32 bits are
# used). The result is a masked 32-bit word.
int bytes_hash_seeded(int k0, int k1, char* data, int length):
	int mask = bytes_mask32()
	bytes_halfsip s
	s.v0 = k0 & mask
	s.v1 = k1 & mask
	s.v2 = 0x6c796765 ^ (k0 & mask)
	s.v3 = 0x74656462 ^ (k1 & mask)
	int full = length - (length & 3)
	int i = 0
	while (i < full):
		bytes_halfsip_absorb(&s, load_le32(&data[i]))
		i = i + 4
	int b = (length << 24) & mask
	int shift = 0
	while (i < length):
		b = b | ((data[i] & 255) << shift)
		shift = shift + 8
		i = i + 1
	bytes_halfsip_absorb(&s, b)
	s.v2 = s.v2 ^ 255
	for r in range(4): bytes_halfsip_round(&s)
	return (s.v1 ^ s.v3) & mask


# ---- map --------------------------------------------------------------------

struct byte_map_entry:
	char* key           # owned copy (at least one byte allocated)
	int key_length
	int value           # caller's word; never freed by the map
	int hash
	byte_map_entry* next


struct byte_map:
	byte_map_entry** buckets
	int bucket_count    # power of two
	int count
	int seed0
	int seed1
	int max_entries     # <= 0: unlimited
	int max_key_length  # <= 0: unlimited


byte_map_entry** byte_map_alloc_buckets(int n):
	int size = 0
	if (checked_size(n, __word_size__, &size) == 0): return cast(byte_map_entry**, 0)
	byte_map_entry** b = cast(byte_map_entry**, malloc(size))
	if (b == 0): return b
	for i in range(n): b[i] = cast(byte_map_entry*, 0)
	return b


# A map whose hash is keyed by (k0, k1); see HASHING. 0 on allocation
# failure.
byte_map* byte_map_new(int k0, int k1):
	byte_map* m = new byte_map()
	m.bucket_count = 16
	m.buckets = byte_map_alloc_buckets(16)
	if (m.buckets == 0):
		free(m)
		return cast(byte_map*, 0)
	m.count = 0
	m.seed0 = k0
	m.seed1 = k1
	m.max_entries = 0
	m.max_key_length = 0
	return m


void byte_map_set_limits(byte_map* m, int max_entries, int max_key_length):
	m.max_entries = max_entries
	m.max_key_length = max_key_length


int byte_map_count(byte_map* m):
	return m.count


int byte_map_hash(byte_map* m, char* key, int length):
	return bytes_hash_seeded(m.seed0, m.seed1, key, length)


# The entry for key, or 0. Borrowed (see OWNERSHIP).
byte_map_entry* byte_map_find(byte_map* m, char* key, int length):
	if (length < 0): return cast(byte_map_entry*, 0)
	int h = byte_map_hash(m, key, length)
	byte_map_entry* e = m.buckets[h & (m.bucket_count - 1)]
	while (e != 0):
		if ((e.hash == h) && bytes_equal(e.key, e.key_length, key, length)): return e
		e = e.next
	return e


int byte_map_contains(byte_map* m, char* key, int length):
	if (byte_map_find(m, key, length) != 0): return 1
	return 0


# 1 and the value in value_out when key is present; 0 (value_out 0) when not.
int byte_map_get(byte_map* m, char* key, int length, int* value_out):
	byte_map_entry* e = byte_map_find(m, key, length)
	if (e == 0):
		value_out[0] = 0
		return 0
	value_out[0] = e.value
	return 1


# Doubles the bucket array. Allocation failure keeps the old array (the
# map stays correct, only chains get longer).
void byte_map_grow(byte_map* m):
	int n = 0
	if (checked_mul(m.bucket_count, 2, &n) == 0): return
	byte_map_entry** fresh = byte_map_alloc_buckets(n)
	if (fresh == 0): return
	for i in range(m.bucket_count):
		byte_map_entry* e = m.buckets[i]
		while (e != 0):
			byte_map_entry* next = e.next
			int slot = e.hash & (n - 1)
			e.next = fresh[slot]
			fresh[slot] = e
			e = next
	free(cast(void*, m.buckets))
	m.buckets = fresh
	m.bucket_count = n


# Inserts key -> value, or replaces the value of an existing key. Returns
# BYTES_OK, BYTES_INVALID (negative length), BYTES_TOO_LARGE (a limit) or
# BYTES_NO_MEMORY; the map is unchanged on failure.
int byte_map_put(byte_map* m, char* key, int length, int value):
	if (length < 0): return BYTES_INVALID
	byte_map_entry* found = byte_map_find(m, key, length)
	if (found != 0):
		found.value = value
		return BYTES_OK
	if ((m.max_key_length > 0) && (length > m.max_key_length)): return BYTES_TOO_LARGE
	if ((m.max_entries > 0) && (m.count >= m.max_entries)): return BYTES_TOO_LARGE
	int size = length
	if (size < 1): size = 1
	char* copy = cast(char*, malloc(size))
	if (copy == 0): return BYTES_NO_MEMORY
	for i in range(length): copy[i] = key[i]
	byte_map_entry* e = new byte_map_entry()
	if (e == 0):
		free(copy)
		return BYTES_NO_MEMORY
	e.key = copy
	e.key_length = length
	e.value = value
	e.hash = byte_map_hash(m, key, length)
	int slot = e.hash & (m.bucket_count - 1)
	e.next = m.buckets[slot]
	m.buckets[slot] = e
	m.count = m.count + 1
	if (m.count > m.bucket_count): byte_map_grow(m)
	return BYTES_OK


void byte_map_entry_free(byte_map_entry* e):
	free(e.key)
	free(e)


# Removes key, freeing the map's copy of it. Returns 1 (and the old value
# in old_value, when non-null) if it was present, else 0.
int byte_map_remove(byte_map* m, char* key, int length, int* old_value):
	if (length < 0): return 0
	int h = byte_map_hash(m, key, length)
	int slot = h & (m.bucket_count - 1)
	byte_map_entry* prev = cast(byte_map_entry*, 0)
	byte_map_entry* e = m.buckets[slot]
	while (e != 0):
		if ((e.hash == h) && bytes_equal(e.key, e.key_length, key, length)):
			if (prev == 0): m.buckets[slot] = e.next
			else: prev.next = e.next
			if (old_value != 0): old_value[0] = e.value
			byte_map_entry_free(e)
			m.count = m.count - 1
			return 1
		prev = e
		e = e.next
	return 0


# Frees every key copy, entry and the map itself (values untouched).
void byte_map_free(byte_map* m):
	for i in range(m.bucket_count):
		byte_map_entry* e = m.buckets[i]
		while (e != 0):
			byte_map_entry* next = e.next
			byte_map_entry_free(e)
			e = next
	free(cast(void*, m.buckets))
	free(m)


int byte_map_entry_compare(byte_map_entry* a, byte_map_entry* b):
	return bytes_compare(a.key, a.key_length, b.key, b.key_length)


# All entries in ascending unsigned-lexicographic key order, independent
# of the seed. Returns a malloc'd array of byte_map_count(m) borrowed
# entry pointers (free the array, not the entries), or 0 on allocation
# failure. Bottom-up merge sort: O(n log n), stable.
byte_map_entry** byte_map_sorted(byte_map* m):
	int n = m.count
	int alloc_n = n
	if (alloc_n < 1): alloc_n = 1
	byte_map_entry** a = byte_map_alloc_buckets(alloc_n)
	if (a == 0): return a
	byte_map_entry** tmp = byte_map_alloc_buckets(alloc_n)
	if (tmp == 0):
		free(cast(void*, a))
		return tmp
	int k = 0
	for i in range(m.bucket_count):
		byte_map_entry* e = m.buckets[i]
		while (e != 0):
			a[k] = e
			k = k + 1
			e = e.next
	int width = 1
	while (width < n):
		int lo = 0
		while (lo < n):
			int mid = lo + width
			if (mid > n): mid = n
			int hi = mid + width
			if (hi > n): hi = n
			int i = lo
			int j = mid
			int out = lo
			while (out < hi):
				if ((i < mid) && ((j >= hi) || (byte_map_entry_compare(a[i], a[j]) <= 0))):
					tmp[out] = a[i]
					i = i + 1
				else:
					tmp[out] = a[j]
					j = j + 1
				out = out + 1
			lo = hi
		for c in range(n): a[c] = tmp[c]
		width = width * 2
	free(cast(void*, tmp))
	return a
