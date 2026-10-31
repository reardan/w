# Fast paths in the container runtime (structures/string.w,
# structures/w_list.w, structures/hash_table.w) must match the generic
# paths they shortcut: string_builder appends across capacity
# boundaries, the size helpers' edge values, the word-key merge sort
# (stability, signed words, C strings, separate key lists, narrow
# elements still on the generic path), the keyed word-key hash, and
# rehash placement (every key reachable, no hole on its probe path) with
# tombstones and string keys.
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


# string_append_int formats on the stack instead of through itoa; the
# digits must match itoa's for edge values on both word sizes, including
# the word minimum (whose negation overflows) and maximum.
void rf_check_append_int(int v):
	string_builder* s = string_new_sized(8)
	string_append(s, c"<")
	string_append_int(s, v)
	char* digits = itoa(v)
	assert_equal(strlen(digits) + 1, s.length)
	assert_strings_equal(digits, s.data + 1)
	free(digits)
	string_free(s)


void test_string_append_int_matches_itoa():
	int top = 1 << (__word_size__ * 8 - 1)
	rf_check_append_int(0)
	rf_check_append_int(7)
	rf_check_append_int(-7)
	rf_check_append_int(10)
	rf_check_append_int(-10)
	rf_check_append_int(1234567)
	rf_check_append_int(top)
	rf_check_append_int(top - 1)
	rf_check_append_int(top + 1)
	int v = 1
	while (v < 1000000000):
		rf_check_append_int(v * 9)
		rf_check_append_int(0 - v * 9 - 1)
		v = v * 10


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


# The word-key hash is keyed by the table's seed, fits 31 bits, and
# spreads sequential and strided keys over the low bits the index uses.
void test_word_hash_seeded():
	__w_hash_table* table = __w_hash_table_new(1, 0, 16)
	int stride = 0
	while (stride < 3):
		table.seed0 = stride * 0x1e3779b9 + 1
		table.seed1 = stride * 0x7f4a7c15 + 2
		set[int] buckets = new set[int]
		int k = 0
		while (k < 4096):
			int key = k
			if (stride == 1): key = k << 12
			if (stride == 2): key = (k * 104729) - 2000000
			int h = __w_hash_word(table, key)
			assert1(h >= 0)
			assert_equal(h, __w_hash_key_hash(table, key))
			buckets.add(h & 4095)
			k = k + 1
		# 4096 random throws into 4096 buckets fill about 2589.
		assert1(buckets.length > 2400)
		buckets.free()
		int before = __w_hash_word(table, 12345)
		table.seed0 = table.seed0 + 1
		assert1(before != __w_hash_word(table, 12345))
		stride = stride + 1
	__w_map_free(table)


# Every live entry is found at its own index, its index slot carries its
# hash, and the probe path from the hash's home slot to that slot holds
# no empty slot.
void rf_check_placement(__w_hash_table* table):
	int mask = table.capacity * 2 - 1
	int32* index = table.index
	int live = 0
	int i = 0
	while (i < table.used):
		int* e = __w_hash_entry(table, i)
		if (e[0] >= 0):
			assert_equal(i, __w_hash_table_find(table, e[1]))
			assert_equal(e[0], __w_hash_key_hash(table, e[1]))
			int q = (e[0] * 2) & mask
			while (index[q] != i + 1):
				assert1(index[q] != 0)
				q = (q + 2) & mask
			assert_equal(e[0], index[q + 1])
			live = live + 1
		else: assert_equal(-1, e[0])
		i = i + 1
	assert_equal(table.count, live)
	assert1(table.used <= table.entry_cap)


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


# Add/remove churn on a small live set rebuilds the table at the same
# size (compacting dead entries) once it has room, instead of growing
# without bound, and keeps the insertion order: removed-and-re-added
# keys move to the end.
void test_churn_compacts_in_order():
	map[int, int] m = new map[int, int]
	int i = 0
	while (i < 10):
		m[i] = i
		i = i + 1
	__w_hash_table* table = cast(__w_hash_table*, m)
	int capacity = 0
	int round = 0
	while (round < 1000):
		if (round == 100): capacity = table.capacity
		int key = round % 10
		assert_equal(1, m.remove(key))
		m[key] = round
		round = round + 1
	assert_equal(capacity, table.capacity)
	assert_equal(10, m.length)
	rf_check_placement(table)
	# Round 999 re-added key 9 last, so the order is 0..9 again.
	list[int] keys = m.keys()
	i = 0
	while (i < 10):
		assert_equal(i, keys[i])
		assert_equal(990 + i, m[i])
		i = i + 1
	m.free()


# Removing the current key, or a later one, inside the loop is safe;
# keys added inside the loop (without growing the table) are visited.
void test_iteration_with_mutation():
	map[int, int] m = new map[int, int]
	int i = 0
	while (i < 6):
		m[i] = i * 10
		i = i + 1
	list[int] seen = new list[int]
	for key, value in m:
		seen.push(key)
		assert_equal(key * 10, value)
		if (key == 1): m.remove(1)
		if (key == 2): m.remove(4)
		if (key == 5): m[6] = 60
	assert_equal(6, seen.length)
	assert_equal(0, seen[0])
	assert_equal(1, seen[1])
	assert_equal(2, seen[2])
	assert_equal(3, seen[3])
	assert_equal(5, seen[4])
	assert_equal(6, seen[5])
	assert_equal(5, m.length)
	m.free()
