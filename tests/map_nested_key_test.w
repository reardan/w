# wbuild: x64
# A map read nested inside another map's KEY ('m[h[k]]'): the '['
# handler keeps the pending element's slots in locals while the key
# expression parses and commits the hash_index_* globals only after
# ']' (grammar/postfix_expr.w), so the nested element's own park and
# finalize cannot clobber the outer element's state. Found 2026-08 as
# a runtime crash; the ndarray comma-index sugar always had this
# discipline (grammar/ndarray_index.w).
import lib.testing
import lib.ndarray


void test_nested_key_read_int():
	map[int, int] m = new map[int, int]
	map[int, int] h = new map[int, int]
	h[5] = 100
	m[100] = 42
	assert_equal(42, m[h[5]])
	# nested read as an arithmetic operand inside the key
	m[101] = 43
	assert_equal(43, m[h[5] + 1])
	# nested reads on both sides of an outer binary expression
	h[6] = 101
	assert_equal(85, m[h[5]] + m[h[6]])


void test_nested_key_read_cstr():
	map[char*, char*] h = new map[char*, char*]
	map[char*, int] m = new map[char*, int]
	h[c"name"] = c"alice"
	m[c"alice"] = 7
	assert_equal(7, m[h[c"name"]])
	# int-keyed inner map feeding a char*-keyed outer map
	map[int, char*] g = new map[int, char*]
	g[1] = c"alice"
	assert_equal(7, m[g[1]])


void test_nested_key_same_map():
	map[int, int] m = new map[int, int]
	m[5] = 6
	m[6] = 9
	assert_equal(9, m[m[5]])


void test_nested_key_assignment():
	map[int, int] m = new map[int, int]
	map[int, int] h = new map[int, int]
	h[1] = 10
	m[h[1]] = 55
	assert_equal(55, m[10])
	# like '=', the expression yields the stored value
	int y = 0
	y = m[h[1]] = 66
	assert_equal(66, y)
	assert_equal(66, m[10])


void test_nested_key_compound():
	map[int, int] m = new map[int, int]
	map[int, int] h = new map[int, int]
	h[1] = 10
	m[10] = 5
	m[h[1]] += 3
	assert_equal(8, m[10])
	m[h[1]] -= 2
	assert_equal(6, m[10])
	# nested read in the compound's right-hand side as well
	m[20] = 4
	h[2] = 20
	m[h[1]] += m[h[2]]
	assert_equal(10, m[10])


void test_deeper_nesting():
	map[int, int] m = new map[int, int]
	map[int, int] h = new map[int, int]
	map[int, int] g = new map[int, int]
	g[1] = 2
	h[2] = 3
	m[3] = 99
	assert_equal(99, m[h[g[1]]])
	m[h[g[1]]] = 44
	assert_equal(44, m[3])


void test_nested_key_in_set():
	map[int, int] h = new map[int, int]
	set[int] s = set[int]{7, 9}
	h[1] = 7
	h[2] = 8
	assert_equal(1, h[1] in s)
	assert_equal(0, h[2] in s)


void test_nested_key_rhs_of_map_assignment():
	map[int, int] m = new map[int, int]
	map[int, int] h = new map[int, int]
	map[int, int] out = new map[int, int]
	h[5] = 100
	m[100] = 42
	# the outer target parks its slots, then the RHS parks and
	# finalizes the nested element's before the store
	out[7] = m[h[5]]
	assert_equal(42, out[7])
	out[7] += m[h[5]]
	assert_equal(84, out[7])


void test_chained_index_nested_key():
	map[int, map[int, int]] mm = new map[int, map[int, int]]
	map[int, int] inner = new map[int, int]
	map[int, int] h = new map[int, int]
	inner[3] = 30
	mm[2] = inner
	h[1] = 2
	h[2] = 3
	# chained reads and nested keys combined
	assert_equal(30, mm[2][3])
	assert_equal(30, mm[h[1]][3])
	assert_equal(30, mm[h[1]][h[2]])
	mm[h[1]][h[2]] = 31
	assert_equal(31, inner[3])


void test_ndarray_interplay():
	# the map-side mirror of tests/ndarray_index_test.w's
	# test_map_interplay: an ndarray element read feeds a map KEY (the
	# nd pending slots park and finalize inside the map's key
	# expression), read, write and compound
	ndi a = ndi_new2(2, 2)
	a[0, 1] = 9
	map[int, int] m = new map[int, int]
	m[9] = 5
	assert_equal(5, m[a[0, 1]])
	m[a[0, 1]] = 6
	assert_equal(6, m[9])
	m[a[0, 1]] += 2
	assert_equal(8, m[9])
