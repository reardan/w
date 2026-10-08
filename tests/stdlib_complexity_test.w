# wbuild: x64 timeout=60000
# Issue #528: the built-in list sort is O(n log n) and stable, the
# built-in map hash is keyed (HalfSipHash-1-3) so precomputed colliding
# keys stay fast, and lib/str.w split is linear. The scale tests use
# sizes the old quadratic code needed minutes for (200k-int sort ~80 s,
# 1 MB split ~150 s, 128k djb2-colliding keys ~170 s, 128k aligned
# int keys ~40 s on x86 and minutes on x64) while the new code
# needs well under a second, so the generous timeout catches a
# regression without being timing-sensitive.
import lib.testing
import lib.str


struct sc_pair:
	int key
	int order


int sc_by_key(sc_pair* a, sc_pair* b):
	return a.key - b.key


# Compares only the tens digit, so values with equal tens are ties.
int sc_by_tens(int a, int b):
	return a / 10 - b / 10


int sc_mask32():
	int h = 1 << 16
	return h * h - 1


void sc_assert_low32(int expected, int got):
	assert_equal(0, (expected - got) & sc_mask32())


# ---- sort ---------------------------------------------------------------

void test_sort_empty_and_single():
	list[int] empty = new list[int]
	empty.sort()
	assert_equal(0, empty.length)
	list[int] one = list[int]{42}
	one.sort()
	assert_equal(1, one.length)
	assert_equal(42, one[0])
	one.sort_by(sc_by_tens)
	assert_equal(42, one[0])


void test_sort_duplicates_and_odd_lengths():
	list[int] l = list[int]{5, 3, 5, 1, 3, 5, 0, -2, 3}
	l.sort()
	list[int] want = list[int]{-2, 0, 1, 3, 3, 3, 5, 5, 5}
	assert_equal(want.length, l.length)
	for i in range(l.length): assert_equal(want[i], l[i])


void test_sort_by_value_is_stable():
	list[int] l = list[int]{31, 12, 35, 17, 10, 33, 14}
	l.sort_by(sc_by_tens)
	list[int] want = list[int]{12, 17, 10, 14, 31, 35, 33}
	for i in range(l.length): assert_equal(want[i], l[i])


void test_sort_by_struct_is_stable():
	list[sc_pair] l = new list[sc_pair]
	sc_pair p
	for i in range(1000):
		p.key = (i * 7) % 10
		p.order = i
		l.push(p)
	l.sort_by(sc_by_key)
	for i in range(1, l.length):
		assert1(l[i - 1].key <= l[i].key)
		if (l[i - 1].key == l[i].key): assert1(l[i - 1].order < l[i].order)


void test_sort_by_key_expression_is_stable():
	list[int] l = list[int]{23, 11, 22, 13, 21, 12}
	l.sort_by(it % 10)
	list[int] want = list[int]{11, 21, 22, 12, 23, 13}
	for i in range(l.length): assert_equal(want[i], l[i])
	list[int] s = l.sorted_by(0 - it)
	assert_equal(23, s[0])
	assert_equal(11, s[5])


void test_sort_cstr_and_sorted_copy():
	list[char*] words = list[char*]{c"pear", c"apple", c"fig", c"apple", c"date"}
	list[char*] copy = words.sorted()
	assert_strings_equal(c"pear", words[0])
	assert_strings_equal(c"apple", copy[0])
	assert_strings_equal(c"apple", copy[1])
	assert_strings_equal(c"date", copy[2])
	assert_strings_equal(c"fig", copy[3])
	assert_strings_equal(c"pear", copy[4])


void test_sort_small_element_sizes():
	list[char] c = list[char]{'d', 'a', 'c', 'b', 'a'}
	c.sort()
	assert_equal('a', c[0])
	assert_equal('a', c[1])
	assert_equal('d', c[4])


void test_sort_200k_ints():
	int n = 200000
	list[int] l = new list[int]
	int x = 12345
	for i in range(n):
		x = (x * 1103515245 + 12345) & 0x7fffffff
		l.push((x >> 4) - 50000000)
	l.sort()
	assert_equal(n, l.length)
	for i in range(1, n): assert1(l[i - 1] <= l[i])
	# Already sorted and reversed inputs (the insertion sort's best and
	# worst cases) both stay O(n log n).
	l.sort()
	l.reverse()
	l.sort()
	for i in range(1, n): assert1(l[i - 1] <= l[i])


# ---- split --------------------------------------------------------------

void test_split_1mb():
	int n = 1 << 20
	char* s = cast(char*, malloc(n + 1))
	for i in range(n):
		if (i % 8 == 7): s[i] = ','
		else: s[i] = 'a' + i % 8
	s[n] = 0
	list[char*] pieces = split(s, ',')
	assert_equal(n / 8 + 1, pieces.length)
	assert_strings_equal(c"abcdefg", pieces[0])
	assert_strings_equal(c"abcdefg", pieces[pieces.length - 2])
	assert_strings_equal(c"", pieces[pieces.length - 1])
	list[char*] words = split(s)
	assert_equal(1, words.length)


void test_split_edges():
	assert_equal(1, split(c"", ',').length)
	assert_equal(0, split(c"").length)
	list[char*] p = split(c",a,", ',')
	assert_equal(3, p.length)
	assert_strings_equal(c"", p[0])
	assert_strings_equal(c"a", p[1])
	assert_strings_equal(c"", p[2])
	assert_strings_equal(c"bc", str_copy_range(c"abcd", 1, 3))


# ---- hash ---------------------------------------------------------------

# Known-answer vectors for HalfSipHash-1-3 with key bytes 00..07,
# from a reference implementation (the same code reproduces the
# published HalfSipHash-2-4 vector 0x5b9f35a9 for the empty input).
void test_hash_known_answers():
	__w_hash_set_seed(0x03020100, 0x07060504)
	__w_hash_table* t = __w_map_new(__w_hash_key_cstr, __word_size__)
	sc_assert_low32(1477757078, __w_hash_sip(t, cast(int, c""), 0))
	sc_assert_low32(-77271002, __w_hash_sip(t, cast(int, c"a"), 1))
	sc_assert_low32(-1022865351, __w_hash_sip(t, cast(int, c"abc"), 3))
	sc_assert_low32(154581159, __w_hash_sip(t, cast(int, c"abcd"), 4))
	sc_assert_low32(1111019042, __w_hash_sip(t, cast(int, c"hello, world!"), 13))
	# Word keys hash their __word_size__ little-endian bytes.
	__w_hash_table* w = __w_map_new(__w_hash_key_word, __word_size__)
	if (__word_size__ == 4): sc_assert_low32(-1908146445, __w_hash_key_hash(w, 7))
	else: sc_assert_low32(-1943404248, __w_hash_key_hash(w, 7))
	__w_map_free(w)
	__w_map_free(t)


# Tables keep the seed they were created with, and map behaviour does
# not depend on it: same contents, same insertion-order iteration.
void test_hash_seed_does_not_change_behaviour():
	__w_hash_set_seed(1, 2)
	map[char*, int] a = new map[char*, int]
	__w_hash_set_seed(99, 1234567)
	map[char*, int] b = new map[char*, int]
	for i in range(500):
		char* key = strclone(itoa(i * 37))
		a[key] = i
		b[key] = i
	assert_equal(500, a.length)
	assert_equal(500, b.length)
	list[char*] ka = a.keys()
	list[char*] kb = b.keys()
	for i in range(500):
		assert_strings_equal(ka[i], kb[i])
		assert_equal(i, a[ka[i]])
		assert_equal(i, b[kb[i]])


# 2^17 distinct 34-byte keys built from the blocks "Ez" and "FY", which
# collide under the old unseeded djb2 (h*33 + c): every key had the same
# hash, so each insert probed past all earlier keys.
void test_hash_flood_djb2_collisions():
	int bits = 17
	int n = 1 << bits
	map[char*, int] m = new map[char*, int]
	char* key = cast(char*, malloc(2 * bits + 1))
	key[2 * bits] = 0
	for i in range(n):
		for b in range(bits):
			if ((i >> b) & 1):
				key[2 * b] = 'F'
				key[2 * b + 1] = 'Y'
			else:
				key[2 * b] = 'E'
				key[2 * b + 1] = 'z'
		m[key] = i
	assert_equal(n, m.length)
	assert_equal(1 << 15, m[c"EzEzEzEzEzEzEzEzEzEzEzEzEzEzEzFYEz"])
	assert_equal(n - 1, m[c"FYFYFYFYFYFYFYFYFYFYFYFYFYFYFYFYFY"])


# Integer keys that are multiples of a large power of two shared their
# low bits under the old key * 33 hash, so they crowded a few probe
# chains: 2^17 multiples of 2^20 (x64; all in ONE chain) or of 2^15
# (x86, where 2^17 * 2^15 = 2^32 keeps them distinct).
void test_hash_flood_aligned_int_keys():
	int shift = 15
	if (__word_size__ == 8): shift = 20
	map[int, int] m = new map[int, int]
	int n = 1 << 17
	for i in range(n): m[i << shift] = i
	assert_equal(n, m.length)
	assert_equal(12345, m[12345 << shift])
	assert_equal(n - 1, m[(n - 1) << shift])
	assert_equal(-1, m.get(12345, -1))
