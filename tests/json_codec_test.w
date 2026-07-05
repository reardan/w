/*
Round-trip tests for the to_json/from_json builtins ("type <=> json").
The compiler generates the codecs from its type table; the runtime lives
in structures/json_codec.w and is imported on demand.
*/
import lib.testing
import lib.utf8
import structures.json
import structures.string


struct jc_point:
	int x
	int y


struct jc_widths:
	char tiny
	int16 small
	int32 medium
	int word
	bool flag


struct jc_person:
	char* name
	string title
	int age


struct jc_rect:
	jc_point top_left
	jc_point bottom_right
	char* label


struct jc_series:
	char* name
	list[int] values


struct jc_polygon:
	char* name
	list[jc_point] points


struct jc_matrix:
	list[list[int]] rows


void test_flat_struct_round_trip():
	jc_point p
	p.x = 3
	p.y = -7
	json_value* v = to_json(p)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22x\x22:3,\x22y\x22:-7}", text)
	free(text)
	jc_point* q = from_json(jc_point, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(3, q.x)
	assert_equal(-7, q.y)
	free(cast(char*, cast(int, q)))
	json_free(v)


void test_struct_pointer_argument():
	jc_point p
	p.x = 11
	p.y = 22
	jc_point* ptr = &p
	json_value* v = to_json(ptr)
	jc_point* q = from_json(jc_point, v)
	assert_equal(11, q.x)
	assert_equal(22, q.y)
	free(cast(char*, cast(int, q)))
	json_free(v)


void test_fixed_width_ints_and_bool():
	jc_widths w
	w.tiny = 42
	w.small = -1234
	w.medium = -100000
	w.word = 1000000
	w.flag = true
	json_value* v = to_json(w)
	jc_widths* r = from_json(jc_widths, v)
	assert_equal(1, cast(int, r) != 0)
	assert_equal(42, r.tiny)
	assert_equal(-1234, r.small)
	assert_equal(-100000, r.medium)
	assert_equal(1000000, r.word)
	assert_equal(1, r.flag)
	free(cast(char*, cast(int, r)))
	json_free(v)


void test_strings_round_trip():
	jc_person p
	p.name = c"ada"
	p.title = s"countess"
	p.age = 36
	json_value* v = to_json(p)
	jc_person* q = from_json(jc_person, v)
	assert_equal(1, cast(int, q) != 0)
	assert_strings_equal(c"ada", q.name)
	assert_equal(1, utf8_equals(q.title, s"countess"))
	assert_equal(36, q.age)
	json_free(v)


void test_null_strings_round_trip():
	jc_person p
	p.name = 0
	p.title = cast(string, 0)
	p.age = 1
	json_value* v = to_json(p)
	assert_equal(json_type_null(), json_object_get(v, c"name").type)
	assert_equal(json_type_null(), json_object_get(v, c"title").type)
	jc_person* q = from_json(jc_person, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(0, cast(int, q.name))
	assert_equal(0, cast(int, q.title))
	free(cast(char*, cast(int, q)))
	json_free(v)


void test_nested_struct_round_trip():
	jc_rect r
	r.top_left.x = 1
	r.top_left.y = 2
	r.bottom_right.x = 30
	r.bottom_right.y = 40
	r.label = c"screen"
	json_value* v = to_json(r)
	json_value* corner = json_object_get(v, c"top_left")
	assert_equal(json_type_object(), corner.type)
	assert_equal(2, json_object_get(corner, c"y").int_value)
	jc_rect* q = from_json(jc_rect, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(1, q.top_left.x)
	assert_equal(2, q.top_left.y)
	assert_equal(30, q.bottom_right.x)
	assert_equal(40, q.bottom_right.y)
	assert_strings_equal(c"screen", q.label)
	json_free(v)


void test_list_of_ints_round_trip():
	jc_series s
	s.name = c"fib"
	s.values = list[int]{1, 1, 2, 3, 5}
	json_value* v = to_json(s)
	json_value* array = json_object_get(v, c"values")
	assert_equal(json_type_array(), array.type)
	assert_equal(5, json_array_length(array))
	assert_equal(5, json_array_get(array, 4).int_value)
	jc_series* q = from_json(jc_series, v)
	assert_equal(1, cast(int, q) != 0)
	assert_strings_equal(c"fib", q.name)
	assert_equal(5, q.values.length)
	assert_equal(1, q.values[0])
	assert_equal(3, q.values[3])
	assert_equal(5, q.values[4])
	json_free(v)


void test_list_of_structs_round_trip():
	jc_polygon poly
	poly.name = c"triangle"
	poly.points = new list[jc_point]
	jc_point p
	p.x = 0
	p.y = 0
	poly.points.push(p)
	p.x = 4
	p.y = 0
	poly.points.push(p)
	p.x = 0
	p.y = 3
	poly.points.push(p)
	json_value* v = to_json(poly)
	jc_polygon* q = from_json(jc_polygon, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(3, q.points.length)
	jc_point got = q.points[1]
	assert_equal(4, got.x)
	assert_equal(0, got.y)
	got = q.points[2]
	assert_equal(0, got.x)
	assert_equal(3, got.y)
	json_free(v)


void test_nested_lists_round_trip():
	jc_matrix m
	m.rows = new list[list[int]]
	m.rows.push(list[int]{1, 2})
	m.rows.push(list[int]{3, 4, 5})
	json_value* v = to_json(m)
	jc_matrix* q = from_json(jc_matrix, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(2, q.rows.length)
	list[int] row = q.rows[1]
	assert_equal(3, row.length)
	assert_equal(5, row[2])
	json_free(v)


void test_null_list_round_trip():
	jc_series s
	s.name = c"empty"
	s.values = cast(list[int], 0)
	json_value* v = to_json(s)
	assert_equal(json_type_null(), json_object_get(v, c"values").type)
	jc_series* q = from_json(jc_series, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(0, cast(int, q.values))
	free(cast(char*, cast(int, q)))
	json_free(v)


void test_decode_from_parsed_text():
	json_value* v = json_parse(c"{\x22x\x22: 8, \x22y\x22: 9}")
	assert_equal(1, cast(int, v) != 0)
	jc_point* p = from_json(jc_point, v)
	assert_equal(1, cast(int, p) != 0)
	assert_equal(8, p.x)
	assert_equal(9, p.y)
	free(cast(char*, cast(int, p)))
	json_free(v)


void test_decode_missing_field_fails():
	json_value* v = json_parse(c"{\x22x\x22: 8}")
	jc_point* p = from_json(jc_point, v)
	assert_equal(0, cast(int, p))
	json_free(v)


void test_decode_wrong_type_fails():
	json_value* v = json_parse(c"{\x22x\x22: \x22eight\x22, \x22y\x22: 9}")
	jc_point* p = from_json(jc_point, v)
	assert_equal(0, cast(int, p))
	json_free(v)


void test_decode_non_object_fails():
	json_value* v = json_parse(c"[1, 2]")
	jc_point* p = from_json(jc_point, v)
	assert_equal(0, cast(int, p))
	json_free(v)
	assert_equal(0, cast(int, from_json(jc_point, cast(json_value*, 0))))


void test_decode_bad_element_fails():
	json_value* v = json_parse(c"{\x22name\x22: \x22s\x22, \x22values\x22: [1, \x22two\x22]}")
	jc_series* s = from_json(jc_series, v)
	assert_equal(0, cast(int, s))
	json_free(v)


void test_extra_members_are_ignored():
	json_value* v = json_parse(c"{\x22x\x22: 1, \x22y\x22: 2, \x22z\x22: 3}")
	jc_point* p = from_json(jc_point, v)
	assert_equal(1, cast(int, p) != 0)
	assert_equal(1, p.x)
	assert_equal(2, p.y)
	free(cast(char*, cast(int, p)))
	json_free(v)


void test_same_type_shares_descriptor():
	# Two uses of the same struct type must agree (the compiler caches
	# the descriptor blob per type)
	jc_point a
	a.x = 1
	a.y = 2
	jc_point b
	b.x = 3
	b.y = 4
	json_value* va = to_json(a)
	json_value* vb = to_json(b)
	assert_equal(1, json_object_get(va, c"x").int_value)
	assert_equal(3, json_object_get(vb, c"x").int_value)
	json_free(va)
	json_free(vb)
