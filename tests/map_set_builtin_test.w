import lib.testing


void test_map_new_assignment_and_read():
	map[char*, int] m = new map[char*, int]
	m[c"one"] = 1
	m[c"two"] = 2
	assert_equal(1, m[c"one"])
	assert_equal(2, m[c"two"])
	assert_equal(3, m[c"one"] + m[c"two"])
	assert_equal(1, c"one" in m)
	assert_equal(0, c"gone" in m)
	assert_equal(2, m.length)


void test_map_overwrite():
	map[char*, int] m = new map[char*, int]
	m[c"key"] = 10
	m[c"key"] = m[c"key"] + 5
	assert_equal(15, m[c"key"])
	assert_equal(1, m.length)


void test_map_literal():
	map[char*, int] m = map[char*, int]{c"red": 3, c"blue": 4}
	assert_equal(3, m[c"red"])
	assert_equal(4, m[c"blue"])
	assert_equal(2, m.length)


void test_set_literal_and_membership():
	set[int] s = set[int]{2, 4, 4, 6}
	assert_equal(1, 2 in s)
	assert_equal(1, 4 in s)
	assert_equal(0, 5 in s)
	assert_equal(3, s.length)


void test_string_keys_compare_by_contents():
	map[string, int] m = new map[string, int]
	string a = s"alpha"
	string b = s"alpha"
	string c = s"beta"
	m[a] = 9
	assert_equal(9, m[b])
	assert_equal(1, b in m)
	assert_equal(0, c in m)


void test_map_iteration_yields_keys():
	map[char*, int] m = map[char*, int]{c"one": 1, c"two": 2, c"three": 3}
	int count = 0
	int sum = 0
	for char* key in m:
		count = count + 1
		sum = sum + m[key]
	assert_equal(3, count)
	assert_equal(6, sum)


void test_set_iteration_yields_members():
	set[int] s = set[int]{1, 2, 3}
	int count = 0
	int sum = 0
	for int value in s:
		count = count + 1
		sum = sum + value
	assert_equal(3, count)
	assert_equal(6, sum)


struct map_test_point:
	int x
	int y


void test_map_struct_values_stored_by_value():
	map[char*, map_test_point] locations = new map[char*, map_test_point]
	map_test_point p
	p.x = 1
	p.y = 2
	locations[c"home"] = p
	p.x = 3
	p.y = 4
	locations[c"work"] = p
	assert_equal(1, locations[c"home"].x)
	assert_equal(4, locations[c"work"].y)
	assert_equal(2, locations.length)
	# stored by value: mutating the source must not change the map
	p.y = 777
	assert_equal(4, locations[c"work"].y)


void test_map_struct_value_reads_copy():
	map[char*, map_test_point] m = new map[char*, map_test_point]
	map_test_point p
	p.x = 5
	p.y = 6
	m[c"a"] = p
	map_test_point copy = m[c"a"]
	copy.y = 999
	assert_equal(6, m[c"a"].y)


void test_map_struct_value_overwrite():
	map[char*, map_test_point] m = new map[char*, map_test_point]
	map_test_point p
	p.x = 1
	p.y = 2
	m[c"k"] = p
	p.x = 9
	m[c"k"] = p
	assert_equal(9, m[c"k"].x)
	assert_equal(1, m.length)


struct map_test_wide:
	int a
	int b
	int c


void test_map_struct_values_survive_rehash():
	map[int, map_test_wide] table = new map[int, map_test_wide]
	map_test_wide w
	for int k in range(50):
		w.a = k
		w.b = k + 1
		w.c = k + 2
		table[k] = w
	assert_equal(50, table.length)
	assert_equal(2, table[0].c)
	assert_equal(51, table[49].c)


void test_map_struct_value_literal():
	map_test_point p
	p.x = 1
	p.y = 2
	map_test_point q
	q.x = 3
	q.y = 4
	map[char*, map_test_point] m = map[char*, map_test_point]{c"p": p, c"q": q}
	assert_equal(1, m[c"p"].x)
	assert_equal(4, m[c"q"].y)


void test_map_remove():
	map[char*, int] m = map[char*, int]{c"one": 1, c"two": 2, c"three": 3}
	assert_equal(1, m.remove(c"two"))
	assert_equal(2, m.length)
	assert_equal(0, c"two" in m)
	assert_equal(1, m[c"one"])
	assert_equal(3, m[c"three"])
	# Removing a missing key reports false and changes nothing
	assert_equal(0, m.remove(c"two"))
	assert_equal(2, m.length)
	# A removed key can be inserted again
	m[c"two"] = 22
	assert_equal(22, m[c"two"])
	assert_equal(3, m.length)


void test_set_add_and_remove():
	set[int] s = new set[int]
	s.add(4)
	s.add(7)
	s.add(4)
	assert_equal(2, s.length)
	assert_equal(1, 4 in s)
	assert_equal(1, s.remove(4))
	assert_equal(0, 4 in s)
	assert_equal(1, s.length)
	assert_equal(0, s.remove(4))


void test_set_add_string_keys():
	set[char*] s = new set[char*]
	s.add(c"alpha")
	s.add(c"beta")
	assert_equal(1, c"alpha" in s)
	assert_equal(0, c"gamma" in s)
	assert_equal(1, s.remove(c"alpha"))
	assert_equal(0, c"alpha" in s)


void test_for_key_value_over_map():
	map[char*, int] m = map[char*, int]{c"a": 1, c"b": 2, c"c": 3}
	int key_length_sum = 0
	int value_sum = 0
	for char* k, int v in m:
		key_length_sum = key_length_sum + strlen(k)
		value_sum = value_sum + v
	assert_equal(3, key_length_sum)
	assert_equal(6, value_sum)


void test_for_key_value_int_keys():
	map[int, int] m = new map[int, int]
	for int i in range(10):
		m[i] = i * i
	int checked = 0
	for int k, int v in m:
		assert_equal(k * k, v)
		checked = checked + 1
	assert_equal(10, checked)


struct kv_test_point:
	int x
	int y


void test_for_key_value_struct_values():
	map[char*, kv_test_point] m = new map[char*, kv_test_point]
	kv_test_point p
	p.x = 1
	p.y = 2
	m[c"a"] = p
	p.x = 3
	p.y = 4
	m[c"b"] = p
	int x_sum = 0
	int y_sum = 0
	for char* k, kv_test_point* v in m:
		x_sum = x_sum + v.x
		y_sum = y_sum + v.y
	assert_equal(4, x_sum)
	assert_equal(6, y_sum)


void test_map_get():
	map[char*, int] m = map[char*, int]{c"one": 1, c"two": 2}
	assert_equal(1, m.get(c"one"))
	assert_equal(2, m.get(c"two"))


void test_map_get_with_default():
	map[char*, int] m = map[char*, int]{c"one": 1}
	assert_equal(1, m.get(c"one", 99))
	assert_equal(99, m.get(c"missing", 99))
	# a present key still overrides the default even when it is falsy
	map[char*, int] zero_map = map[char*, int]{c"zero": 0}
	assert_equal(0, zero_map.get(c"zero", 5))


void test_map_get_struct_values():
	map[char*, kv_test_point] m = new map[char*, kv_test_point]
	kv_test_point p
	p.x = 1
	p.y = 2
	m[c"a"] = p
	kv_test_point got = m.get(c"a")
	assert_equal(1, got.x)
	assert_equal(2, got.y)
	# reads copy: mutating the result must not change the stored value
	got.y = 999
	assert_equal(2, m[c"a"].y)


void test_map_get_struct_default():
	map[char*, kv_test_point] m = new map[char*, kv_test_point]
	kv_test_point stored
	stored.x = 1
	stored.y = 2
	m[c"a"] = stored
	kv_test_point fallback
	fallback.x = 9
	fallback.y = 8
	kv_test_point present = m.get(c"a", fallback)
	assert_equal(1, present.x)
	kv_test_point missing = m.get(c"z", fallback)
	assert_equal(9, missing.x)
	assert_equal(8, missing.y)


void test_map_iterates_in_insertion_order():
	map[char*, int] m = new map[char*, int]
	m[c"zebra"] = 1
	m[c"apple"] = 2
	m[c"mango"] = 3
	int step = 0
	for char* key in m:
		if (step == 0):
			assert_strings_equal(c"zebra", key)
		if (step == 1):
			assert_strings_equal(c"apple", key)
		if (step == 2):
			assert_strings_equal(c"mango", key)
		step = step + 1
	assert_equal(3, step)


void test_map_update_keeps_insertion_position():
	map[int, int] m = new map[int, int]
	m[7] = 70
	m[3] = 30
	m[9] = 90
	m[7] = 71
	int step = 0
	for int k in m:
		if (step == 0):
			assert_equal(7, k)
		if (step == 1):
			assert_equal(3, k)
		if (step == 2):
			assert_equal(9, k)
		step = step + 1
	assert_equal(3, step)
	assert_equal(71, m[7])


void test_map_remove_reinsert_moves_to_end():
	map[int, int] m = new map[int, int]
	m[1] = 10
	m[2] = 20
	m[3] = 30
	m.remove(1)
	m[1] = 11
	int step = 0
	for int k in m:
		if (step == 0):
			assert_equal(2, k)
		if (step == 1):
			assert_equal(3, k)
		if (step == 2):
			assert_equal(1, k)
		step = step + 1
	assert_equal(3, step)


void test_map_insertion_order_survives_growth():
	# 100 int keys force several rehashes past the initial capacity of 16;
	# iteration must still replay the insertion sequence exactly.
	map[int, int] m = new map[int, int]
	for int i in range(100):
		m[i * 7] = i
	int expect = 0
	for int k in m:
		assert_equal(expect * 7, k)
		expect = expect + 1
	assert_equal(100, expect)


void test_set_iterates_in_insertion_order():
	set[char*] s = new set[char*]
	s.add(c"walnut")
	s.add(c"acorn")
	s.add(c"pecan")
	int step = 0
	for char* member in s:
		if (step == 0):
			assert_strings_equal(c"walnut", member)
		if (step == 1):
			assert_strings_equal(c"acorn", member)
		if (step == 2):
			assert_strings_equal(c"pecan", member)
		step = step + 1
	assert_equal(3, step)
