import lib.testing


void test_map_new_assignment_and_read():
	map[char*, int] m = new map[char*, int]
	m["one"] = 1
	m["two"] = 2
	assert_equal(1, m["one"])
	assert_equal(2, m["two"])
	assert_equal(3, m["one"] + m["two"])
	assert_equal(1, "one" in m)
	assert_equal(0, "gone" in m)
	assert_equal(2, m.length)


void test_map_overwrite():
	map[char*, int] m = new map[char*, int]
	m["key"] = 10
	m["key"] = m["key"] + 5
	assert_equal(15, m["key"])
	assert_equal(1, m.length)


void test_map_literal():
	map[char*, int] m = map[char*, int]{"red": 3, "blue": 4}
	assert_equal(3, m["red"])
	assert_equal(4, m["blue"])
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
	map[char*, int] m = map[char*, int]{"one": 1, "two": 2, "three": 3}
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
