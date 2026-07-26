# wbuild: x64
# Inferred 'for' loop variables: 'for x in ...' drops the redundant
# type when the range/container already fixes it (issue #360,
# docs/projects/golf_ergonomics.md). The typed form stays canonical;
# this asserts the inferred twin matches its behavior shape for shape.
import lib.testing
import lib.utf8
import structures.array_list


struct fi_point:
	int x
	int y


void test_infer_range():
	int total = 0
	for i in range(4):
		total += i
	assert_equal(6, total)


void test_infer_range_start_step():
	int total = 0
	for i in range(2, 11, 3):
		total += i
	assert_equal(15, total)


void test_infer_range_var_survives_loop():
	for i in range(3):
		pass
	assert_equal(3, i)


void test_infer_list():
	l := list[int]{5, 6, 7}
	int total = 0
	for x in l:
		total += x
	assert_equal(18, total)


void test_infer_list_of_cstr():
	names := list[char*]{c"ab", c"cde"}
	int total = 0
	for s in names:
		total += strlen(s)
	assert_equal(5, total)


void test_infer_list_of_structs():
	pts := new list[fi_point]
	fi_point p
	p.x = 3
	p.y = 4
	pts.push(p)
	p.x = 10
	p.y = 20
	pts.push(p)
	int total = 0
	# Struct elements infer the element-pointer type, like 'for fi_point* q'
	for q in pts:
		total += q.x + q.y
	assert_equal(37, total)


void test_infer_map_key():
	m := map[int, int]{1: 10, 2: 20}
	int keys = 0
	for k in m:
		keys += k
	assert_equal(3, keys)


void test_infer_map_key_value():
	m := map[int, int]{1: 10, 2: 20}
	int keys = 0
	int values = 0
	for k, v in m:
		keys += k
		values += v
	assert_equal(3, keys)
	assert_equal(30, values)


void test_infer_map_cstr_keys():
	m := map[char*, int]{c"a": 1, c"bc": 2}
	int total = 0
	for k, v in m:
		total += strlen(k) * v
	assert_equal(5, total)


void test_infer_map_mixed_typed_and_inferred():
	m := map[int, int]{4: 40}
	int keys = 0
	int values = 0
	for int k, v in m:
		keys += k
		values += v
	for k2, int v2 in m:
		keys += k2
		values += v2
	assert_equal(8, keys)
	assert_equal(80, values)


void test_infer_set():
	s := set[int]{3, 9}
	int total = 0
	for x in s:
		total += x
	assert_equal(12, total)


void test_infer_string_code_points():
	string t = s"abc"
	int total = 0
	for cp in t:
		total += cp
	assert_equal('a' + 'b' + 'c', total)


void test_infer_array_slice():
	int[3] a
	a[0] = 7
	a[1] = 8
	a[2] = 9
	int total = 0
	for x in a:
		total += x
	assert_equal(24, total)


void test_infer_custom_container():
	array_list* a = array_list_new()
	array_list_push(a, 4)
	array_list_push(a, 5)
	int total = 0
	for x in a:
		total += x
	assert_equal(9, total)
	array_list_free(a)


void test_infer_nested_and_break_continue():
	int total = 0
	for i in range(3):
		for j in range(4):
			if j == 3:
				break
			if j == 1:
				continue
			total += i * 10 + j
	assert_equal(66, total)
