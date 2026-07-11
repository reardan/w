/*
Bloom filter over structures/bitset.w — the Bigtable §6 SSTable-lookup
optimization: a compact probabilistic member set that answers
"definitely absent" or "possibly present", so a read can skip any
SSTable (disk seek, network hop) whose filter rejects the key.

Probes use Kirsch-Mitzenmacher double hashing derived from ONE sha256
of the key: h1 is the first 4 digest bytes big-endian masked to 31
bits, h2 the next 4 likewise, forced odd (h2 | 1) so it is nonzero.
Probe i (0 <= i < k) addresses bit (h1 + i*h2) mod m, computed without
overflow: idx and step are reduced mod m up front, then each probe
does idx = idx + step; if (idx >= m): idx = idx - m. idx + step < 2m
and m is capped at 2^24, so the sum never wraps on any target. With
the usual power-of-two m the reduced step stays odd — nonzero and
coprime to m, so a single key's k probes are all distinct; an odd m
can reduce the step to 0, which only weakens the filter (probes
repeat one bit), never breaks the no-false-negative guarantee.

Everything bit-addressing is sha256-derived and masked to 31 bits (the
ring.w convention; lib/sha256.w explains why raw masked 32-bit words
can be stored negative), so add / maybe_contains verdicts are
identical on every target.

Wire format (bloom_serialize): an 8-byte header — m then k, each as 4
little-endian bytes — followed by the backing bitset's own serialized
form (bitset_serialize). bloom_deserialize round-trips m, k and every
bit; the items counter is NOT serialized and resets to 0 on load.

items counts bloom_add calls, duplicates included — it is the number
of insertions performed, not of distinct keys.
*/
import lib.lib
import lib.memory
import lib.assert
import lib.sha256
import structures.bitset


struct bloom_filter:
	int m         # bits in the filter
	int k         # probes per key
	bitset* bits  # backing bit array, m bits
	int items     # bloom_add calls (duplicates included); 0 after deserialize


# 0x7fffffff built at runtime — a hex literal with bit 31 set would
# sign-extend into a negative int on every target.
int bloom_mask31():
	int q = 1 << 30
	return (q - 1) + q


bloom_filter* bloom_new(int m, int k):
	assert1(m >= 8)
	assert1(m <= (1 << 24))
	assert1(k >= 1)
	assert1(k <= 16)
	bloom_filter* b = new bloom_filter()
	b.m = m
	b.k = k
	b.bits = bitset_new(m)
	b.items = 0
	return b


void bloom_free(bloom_filter* b):
	bitset_free(b.bits)
	free(b)


# One sha256 of key -> the two double-hashing parameters, already
# reduced mod b.m: out[0] = first probe index, out[1] = probe step
# (out must hold 2 ints). sha256_be32 may return a negative int when
# digest bit 31 is set; the 31-bit mask keeps only the low bits, so
# both values are the same non-negative int on every target.
void bloom_probe_start(bloom_filter* b, char* key, int* out):
	char* digest = malloc(32)
	sha256(key, strlen(key), digest)
	int h1 = sha256_be32(digest) & bloom_mask31()
	int h2 = (sha256_be32(digest + 4) & bloom_mask31()) | 1
	free(digest)
	out[0] = h1 % b.m
	out[1] = h2 % b.m


void bloom_add(bloom_filter* b, char* key):
	int* probe = cast(int*, malloc(2 * __word_size__))
	bloom_probe_start(b, key, probe)
	int idx = probe[0]
	int step = probe[1]
	free(probe)
	int i = 0
	while (i < b.k):
		bitset_set(b.bits, idx)
		idx = idx + step
		if (idx >= b.m):
			idx = idx - b.m
		i = i + 1
	b.items = b.items + 1


# 1 = possibly present (may be a false positive), 0 = DEFINITELY
# absent: a key that was ever added always answers 1.
int bloom_maybe_contains(bloom_filter* b, char* key):
	int* probe = cast(int*, malloc(2 * __word_size__))
	bloom_probe_start(b, key, probe)
	int idx = probe[0]
	int step = probe[1]
	free(probe)
	int i = 0
	while (i < b.k):
		if (bitset_get(b.bits, idx) == 0):
			return 0
		idx = idx + step
		if (idx >= b.m):
			idx = idx - b.m
		i = i + 1
	return 1


# Insertions performed so far: bloom_add calls, duplicates included.
int bloom_item_count(bloom_filter* b):
	return b.items


# Number of set bits in the backing bitset.
int bloom_bit_count(bloom_filter* b):
	return bitset_count(b.bits)


# Bytes bloom_serialize writes: the 8-byte m/k header plus the
# bitset's own serialized form.
int bloom_serialized_size(bloom_filter* b):
	return 8 + bitset_serialized_size(b.bits)


void bloom_serialize(bloom_filter* b, char* out):
	bitset_put_le32(out, b.m)
	bitset_put_le32(out + 4, b.k)
	bitset_serialize(b.bits, out + 8)


# Rebuild a filter from a bloom_serialize buffer. m, k and every bit
# round-trip exactly; items restarts at 0 (it is not serialized).
bloom_filter* bloom_deserialize(char* buf):
	int m = bitset_read_le32(buf)
	int k = bitset_read_le32(buf + 4)
	bloom_filter* b = bloom_new(m, k)
	bitset_free(b.bits)
	b.bits = bitset_deserialize(buf + 8)
	assert1(b.bits.size == m)
	return b
