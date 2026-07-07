/*
Bit arrays over machine words plus an ida-style integer ID allocator,
after the Linux kernel's lib/bitmap.c and lib/idr.c (design:
docs/projects/linux_idioms.md).

W has no ~ or ^ operators, so complements are built arithmetically:
in two's complement, -x - 1 flips every bit of x, and word - (word &
mask) clears exactly the bits in mask.

The bitmap grows on demand (set/ida allocate; test/clear of an
out-of-range bit is a harmless no-op / 0). Bit indices are words of
bits_per_word() bits, least significant bit first, so layouts differ
between x86 (32-bit words) and x64 (64-bit words) but the API is
word-size agnostic.
*/
import lib.lib
import lib.assert


int bits_per_word():
	return __word_size__ * 8


struct bitmap:
	int nwords
	int* words


bitmap* bitmap_new(int nbits):
	if (nbits < 1):
		nbits = 1
	bitmap* map = new bitmap()
	map.nwords = (nbits + bits_per_word() - 1) / bits_per_word()
	map.words = cast(int*, malloc(map.nwords * __word_size__))
	int i = 0
	while (i < map.nwords):
		map.words[i] = 0
		i = i + 1
	return map


void bitmap_free(bitmap* map):
	free(map.words)
	free(map)


void bitmap_grow(bitmap* map, int bit):
	int needed = bit / bits_per_word() + 1
	if (needed <= map.nwords):
		return
	int new_words = map.nwords * 2
	if (new_words < needed):
		new_words = needed
	map.words = cast(int*, realloc(map.words, map.nwords * __word_size__, new_words * __word_size__))
	int i = map.nwords
	while (i < new_words):
		map.words[i] = 0
		i = i + 1
	map.nwords = new_words


void bitmap_set(bitmap* map, int bit):
	assert1(bit >= 0)
	bitmap_grow(map, bit)
	int word = bit / bits_per_word()
	int mask = 1 << (bit % bits_per_word())
	map.words[word] = map.words[word] | mask


void bitmap_clear(bitmap* map, int bit):
	assert1(bit >= 0)
	if (bit / bits_per_word() >= map.nwords):
		return
	int word = bit / bits_per_word()
	int mask = 1 << (bit % bits_per_word())
	# word & ~mask without a ~ operator: subtract the set intersection.
	map.words[word] = map.words[word] - (map.words[word] & mask)


int bitmap_test(bitmap* map, int bit):
	assert1(bit >= 0)
	if (bit / bits_per_word() >= map.nwords):
		return 0
	int mask = 1 << (bit % bits_per_word())
	return (map.words[bit / bits_per_word()] & mask) != 0


# Lowest set bit of a nonzero word: isolate with word & -word, then
# count trailing zeros by shifting. >> is arithmetic, so mask the sign
# bits back off after each shift (handles the top bit being set).
int word_find_first_set(int word):
	assert1(word != 0)
	int max_positive = (1 << (bits_per_word() - 1)) - 1
	int isolated = word & (0 - word)
	int bit = 0
	while (isolated != 1):
		isolated = (isolated >> 1) & max_positive
		bit = bit + 1
	return bit


# First set bit at or after start, or -1 when none within the map.
int bitmap_find_next_set(bitmap* map, int start):
	if (start < 0):
		start = 0
	int bit = start
	while (bit / bits_per_word() < map.nwords):
		if (bit % bits_per_word() == 0):
			# Fast-skip whole zero words, then jump straight to the
			# first set bit of the word that stopped the skip.
			while ((bit / bits_per_word() < map.nwords) && (map.words[bit / bits_per_word()] == 0)):
				bit = bit + bits_per_word()
			if (bit / bits_per_word() >= map.nwords):
				return (-1)
			return bit + word_find_first_set(map.words[bit / bits_per_word()])
		if (bitmap_test(map, bit)):
			return bit
		bit = bit + 1
	return (-1)


int bitmap_find_first_set(bitmap* map):
	return bitmap_find_next_set(map, 0)


# First clear bit at or after start. The map is conceptually infinite:
# past the allocated words every bit is clear, so this always succeeds.
int bitmap_find_next_zero(bitmap* map, int start):
	if (start < 0):
		start = 0
	int bit = start
	while (bit / bits_per_word() < map.nwords):
		if (bitmap_test(map, bit) == 0):
			return bit
		bit = bit + 1
	return bit


int bitmap_find_first_zero(bitmap* map):
	return bitmap_find_next_zero(map, 0)


int bitmap_count_set(bitmap* map):
	int count = 0
	int i = 0
	while (i < map.nwords):
		int word = map.words[i]
		while (word != 0):
			word = word & (word - 1)
			count = count + 1
		i = i + 1
	return count


# --- ida: small integer ID allocator over a bitmap ---
# ida_alloc returns the lowest free non-negative id and marks it used;
# ida_free releases it for reuse. Handle tables, fd-style registries.

struct ida:
	bitmap* used


ida* ida_new():
	ida* allocator = new ida()
	allocator.used = bitmap_new(bits_per_word())
	return allocator


void ida_free_all(ida* allocator):
	bitmap_free(allocator.used)
	free(allocator)


int ida_alloc(ida* allocator):
	int id = bitmap_find_first_zero(allocator.used)
	bitmap_set(allocator.used, id)
	return id


void ida_free(ida* allocator, int id):
	assert1(id >= 0)
	bitmap_clear(allocator.used, id)


int ida_is_allocated(ida* allocator, int id):
	return bitmap_test(allocator.used, id)
