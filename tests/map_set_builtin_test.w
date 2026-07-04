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
