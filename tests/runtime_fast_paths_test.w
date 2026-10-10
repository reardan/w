# Fast paths in the container runtime (structures/string.w,
# structures/w_list.w, structures/hash_table.w) must match the generic
# paths they shortcut: string_builder appends across capacity
# boundaries, the size helpers' edge values, the word-key merge sort
# (stability, signed words, C strings, separate key lists, narrow
# elements still on the generic path), the word-key HalfSipHash against
# the byte-reading one, and rehash placement (every key reachable, no
# hole on its probe path) with tombstones and string keys.
# wbuild: x64
import lib.testing
import structures.string


struct rf_pair:
	int key
	int tag


void test_string_append_char_boundaries():
	string_builder* s = string_new_sized(8)
	int i = 0
	while (i < 300):
		string_append_char(s, 'a' + (i % 26))
		assert_equal(i + 1, s.length)
		assert1(s.length < s.capacity)
		assert_equal(0, s.data[s.length])
		i = i + 1
	i = 0
	while (i < 300):
		assert_equal('a' + (i % 26), s.data[i])
		i = i + 1
	string_free(s)


void test_string_append_bulk():
	string_builder* s = string_new_sized(8)
	string_append(s, c"")
	assert_equal(0, s.length)
	string_append(s, c"1234567")
	assert_equal(7, s.length)
	assert_equal(8, s.capacity)
	string_append(s, c"8")
	assert_equal(8, s.length)
	assert1(s.capacity >= 9)
	string_append_bytes(s, c"xyz", 3)
	string_append_bytes(s, c"q", 0)
	assert_strings_equal(c"12345678xyz", s.data)
	string_reserve(s, 0)
	string_reserve(s, -5)
	assert_strings_equal(c"12345678xyz", s.data)
	string_free(s)


void test_size_helpers():
	int max = __w_word_max()
	assert_equal(max, __w_size_add(max - 1, 1))
	assert_equal(max, __w_size_add(0, max))
	assert_equal(0, __w_size_add(0, 0))
	assert_equal(max - 1, __w_size_mul(1, max - 1))
	assert_equal(max / 2 * 2, __w_size_mul(max / 2, 2))
	assert_equal(16, __w_grow_capacity(8, 9))
	assert_equal(100, __w_grow_capacity(8, 100))
	assert_equal(max, __w_grow_capacity(max / 2 + 1, max))


void test_sort_words_signed_and_stable():
	list[int] l = new list[int]
	int state = 12345
	int i = 0
	while (i < 1000):
		state = state * 1103515245 + 12345
		l.push(((state >> 8) & 255) - 128)
		i = i + 1
	l.sort()
	i = 1
	while (i < l.length):
		assert1(l[i - 1] <= l[i])
		i = i + 1
	list[int] big = list[int]{5, 0 - __w_word_max() - 1, __w_word_max(), 0, -1, 1}
	big.sort()
	assert_equal(0 - __w_word_max() - 1, big[0])
	assert_equal(-1, big[1])
	assert_equal(0, big[2])
	assert_equal(1, big[3])
	assert_equal(5, big[4])
	assert_equal(__w_word_max(), big[5])


void test_sort_cstrings():
	list[char*] l = list[char*]{c"pear", c"apple", c"pea", c"", c"apple", c"zebra", c"ape"}
	char* first_apple = l[1]
	l.sort()
	assert_strings_equal(c"", l[0])
	assert_strings_equal(c"ape", l[1])
	assert_strings_equal(c"apple", l[2])
	assert1(l[2] == first_apple)
	assert_strings_equal(c"apple", l[3])
	assert_strings_equal(c"pea", l[4])
	assert_strings_equal(c"pear", l[5])
	assert_strings_equal(c"zebra", l[6])


void test_sort_by_word_keys_stable():
	# Separate word-sized keys: ties keep their original order.
	list[int] l = new list[int]
	int i = 0
	while (i < 200):
		l.push(i)
		i = i + 1
	l.sort_by(it % 7)
	i = 1
	while (i < l.length):
		int a = l[i - 1]
		int b = l[i]
		assert1((a % 7 < b % 7) || ((a % 7 == b % 7) && (a < b)))
		i = i + 1


void test_sort_by_struct_keys():
	list[rf_pair] l = new list[rf_pair]
	int i = 0
	while (i < 50):
		rf_pair p
		p.key = (i * 37) % 10
		p.tag = i
		l.push(p)
		i = i + 1
	l.sort_by(it.key)
	i = 1
	while (i < l.length):
		assert1((l[i - 1].key < l[i].key) || ((l[i - 1].key == l[i].key) && (l[i - 1].tag < l[i].tag)))
		i = i + 1


void test_sort_narrow_elements_generic_path():
	list[char] l = list[char]{'d', 'a', 'c', 'b', 'a'}
	l.sort()
	assert_equal('a', l[0])
	assert_equal('a', l[1])
	assert_equal('b', l[2])
	assert_equal('c', l[3])
	assert_equal('d', l[4])


void test_sip_word_matches_bytes():
	__w_hash_table* table = __w_hash_table_new(1, 0, 16)
	int seed = 0
	while (seed < 4):
		table.seed0 = seed * 0x1e3779b9 + 1
		table.seed1 = seed * 0x7f4a7c15 + 2
		int k = 0 - 600
		while (k < 600):
			int key = k * 104729 + (k << 20)
			int word = key
			assert_equal(__w_hash_sip(table, cast(int, &word), __word_size__), __w_hash_sip_word(table, key))
			k = k + 1
		seed = seed + 1


# Every live key is found, and the probe path from its home slot to
# where it sits holds no empty slot.
void rf_check_placement(__w_hash_table* table):
	int mask = table.capacity - 1
	int live = 0
	int i = table.order_head
	while (i >= 0):
		assert_equal(1, table.states[i])
		int key = table.keys[i]
		assert_equal(i, __w_hash_table_slot(table, key))
		int p = __w_hash_key_hash(table, key) & mask
		while (p != i):
			assert1(table.states[p] != 0)
			p = (p + 1) & mask
		live = live + 1
		i = table.order_next[i]
	assert_equal(table.count, live)


void test_rehash_int_keys():
	map[int, int] m = new map[int, int]
	int i = 0
	while (i < 2000):
		m[i * 7919] = i
		i = i + 1
	i = 0
	while (i < 2000):
		if (i % 3 == 0): m.remove(i * 7919)
		i = i + 1
	i = 0
	while (i < 3000):
		m[i * 31] = 0 - i
		i = i + 1
	rf_check_placement(cast(__w_hash_table*, m))
	int first = -1
	for key, value in m:
		if (first < 0): first = key
	assert_equal(7919, first)
	assert_equal(0 - 2999, m[2999 * 31])


void test_rehash_string_keys():
	map[char*, int] m = new map[char*, int]
	int i = 0
	while (i < 500):
		char* num = itoa(i)
		m[num] = i
		free(num)
		i = i + 1
	i = 0
	while (i < 500):
		if (i % 2 == 0):
			char* num = itoa(i)
			m.remove(num)
			free(num)
		i = i + 1
	i = 500
	while (i < 1200):
		char* num = itoa(i)
		m[num] = i
		free(num)
		i = i + 1
	rf_check_placement(cast(__w_hash_table*, m))
	assert_equal(950, m.length)
	assert_equal(777, m[c"777"])
	assert_equal(1, m[c"1"])
	assert_equal(-1, m.get(c"2", -1))


struct rf_vec:
	int x
	int y
	int z


void test_rehash_struct_values():
	map[int, rf_vec] m = new map[int, rf_vec]
	int i = 0
	while (i < 300):
		rf_vec v
		v.x = i
		v.y = i * 2
		v.z = 0 - i
		m[i] = v
		i = i + 1
	rf_check_placement(cast(__w_hash_table*, m))
	i = 0
	while (i < 300):
		rf_vec v = m[i]
		assert_equal(i, v.x)
		assert_equal(i * 2, v.y)
		assert_equal(0 - i, v.z)
		i = i + 1
