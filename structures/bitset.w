/*
Fixed-size bitset over int words (#249).

Bits are stored 32 per word — the masked-32-bit-word convention
(lib/sha256.w): only each word's low 32 bits carry bit-set state, on
every target, so popcount()/ctz() (grammar/bit_builtin.w) see whole
words and the serialized form is identical on 32- and 64-bit targets.
Bit i lives in word i >> 5 at position i & 31.

Imported explicitly by consumers — this file is not in the seed's
import closure, so it is free to use the bit intrinsics and 0b binary
literals.

The word-wise combiners (and/or/xor/andnot) require both operands to
have the same size. serialize writes 4 bytes of little-endian bit
count followed by each word as 4 little-endian bytes; deserialize
reconstructs an equal bitset from that buffer.
*/
import lib.lib
import lib.assert


struct bitset:
	int size    # number of addressable bits
	int words   # number of 32-bit payload words in data
	int* data


# 0xffffffff as this target represents a masked 32-bit word
int bitset_mask32():
	int h = 1 << 16
	return h * h - 1


bitset* bitset_new(int size):
	assert1(size >= 0)
	bitset* b = new bitset()
	b.size = size
	b.words = (size + 31) >> 5
	int alloc_words = b.words
	if (alloc_words < 1):
		alloc_words = 1
	b.data = malloc(alloc_words * __word_size__)
	int i = 0
	while (i < b.words):
		b.data[i] = 0
		i = i + 1
	return b


void bitset_free(bitset* b):
	free(b.data)
	free(b)


void bitset_set(bitset* b, int index):
	assert1(index >= 0)
	assert1(index < b.size)
	b.data[index >> 5] = b.data[index >> 5] | (1 << (index & 31))


void bitset_clear(bitset* b, int index):
	assert1(index >= 0)
	assert1(index < b.size)
	b.data[index >> 5] = b.data[index >> 5] & ((1 << (index & 31)) ^ bitset_mask32())


void bitset_toggle(bitset* b, int index):
	assert1(index >= 0)
	assert1(index < b.size)
	b.data[index >> 5] = b.data[index >> 5] ^ (1 << (index & 31))


int bitset_get(bitset* b, int index):
	assert1(index >= 0)
	assert1(index < b.size)
	return shr(b.data[index >> 5], index & 31) & 1


# b = b & other, word-wise
void bitset_and(bitset* b, bitset* other):
	assert1(b.size == other.size)
	int i = 0
	while (i < b.words):
		b.data[i] = b.data[i] & other.data[i]
		i = i + 1


# b = b | other, word-wise
void bitset_or(bitset* b, bitset* other):
	assert1(b.size == other.size)
	int i = 0
	while (i < b.words):
		b.data[i] = b.data[i] | other.data[i]
		i = i + 1


# b = b ^ other, word-wise
void bitset_xor(bitset* b, bitset* other):
	assert1(b.size == other.size)
	int i = 0
	while (i < b.words):
		b.data[i] = b.data[i] ^ other.data[i]
		i = i + 1


# b = b & ~other, word-wise: clears every bit that is set in other
void bitset_andnot(bitset* b, bitset* other):
	assert1(b.size == other.size)
	int i = 0
	while (i < b.words):
		b.data[i] = b.data[i] & (other.data[i] ^ bitset_mask32())
		i = i + 1


# Number of set bits
int bitset_count(bitset* b):
	int total = 0
	int i = 0
	while (i < b.words):
		total = total + popcount(b.data[i])
		i = i + 1
	return total


# Index of the first set bit at or after 'from'; -1 when there is none.
# Iterate all set bits with:
#   int i = bitset_next_set_bit(b, 0)
#   while (i >= 0):
#       ...
#       i = bitset_next_set_bit(b, i + 1)
int bitset_next_set_bit(bitset* b, int from):
	if (from < 0):
		from = 0
	int w = from >> 5
	int bit = from & 31
	while (w < b.words):
		# drop the bits below 'from' in the first word, then ctz finds
		# the lowest survivor
		int word = shr(b.data[w], bit) << bit
		if (word != 0):
			return (w << 5) + ctz(word)
		w = w + 1
		bit = 0
	return -1


void bitset_put_le32(char* p, int v):
	p[0] = v & 255
	p[1] = (v >> 8) & 255
	p[2] = (v >> 16) & 255
	p[3] = (v >> 24) & 255


int bitset_read_le32(char* p):
	return (p[0] & 255) | ((p[1] & 255) << 8) | ((p[2] & 255) << 16) | ((p[3] & 255) << 24)


# Bytes bitset_serialize writes for b: 4 for the bit count plus 4 per word
int bitset_serialized_size(bitset* b):
	return 4 + b.words * 4


void bitset_serialize(bitset* b, char* buffer):
	bitset_put_le32(buffer, b.size)
	int i = 0
	while (i < b.words):
		bitset_put_le32(buffer + 4 + i * 4, b.data[i])
		i = i + 1


bitset* bitset_deserialize(char* buffer):
	int size = bitset_read_le32(buffer)
	assert1(size >= 0)
	bitset* b = bitset_new(size)
	int i = 0
	while (i < b.words):
		b.data[i] = bitset_read_le32(buffer + 4 + i * 4)
		i = i + 1
	return b
