# wbuild: x64 group=wasm_json_test@wasm
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


struct jc_reading:
	char* sensor
	float low
	float high


struct jc_counts:
	map[char*, int] tally


struct jc_titles:
	map[string, string] names


struct jc_places:
	map[char*, jc_point] sites


struct jc_graph:
	map[char*, list[int]] edges


struct jc_nested_map:
	map[char*, map[string, float]] outer


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


void test_float_fields_round_trip():
	jc_reading r
	r.sensor = c"t0"
	r.low = -0.25
	r.high = 1.5
	json_value* v = to_json(r)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22sensor\x22:\x22t0\x22,\x22low\x22:-0.25,\x22high\x22:1.5}", text)
	free(text)
	jc_reading* q = from_json(jc_reading, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(1, q.low == -0.25)
	assert_equal(1, q.high == 1.5)
	json_free(v)


void test_float_whole_values_keep_a_fraction_part():
	# Whole floats serialize with a trailing .0 so they re-parse as
	# floats (structures/json.w), and the codec round-trips them
	jc_reading r
	r.sensor = c"t1"
	r.low = 2.0
	r.high = -100.0
	json_value* v = to_json(r)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22sensor\x22:\x22t1\x22,\x22low\x22:2.0,\x22high\x22:-100.0}", text)
	free(text)
	jc_reading* q = from_json(jc_reading, v)
	assert_equal(1, q.low == 2.0)
	assert_equal(1, q.high == -100.0)
	json_free(v)


void test_float_field_accepts_json_int():
	# Other producers (e.g. JavaScript's JSON.stringify) write whole
	# doubles with no fraction part, so a JSON integer converts into a
	# float field
	json_value* v = json_parse(c"{\x22sensor\x22: \x22t2\x22, \x22low\x22: 3, \x22high\x22: 2.5}")
	jc_reading* q = from_json(jc_reading, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(1, q.low == 3.0)
	assert_equal(1, q.high == 2.5)
	json_free(v)


void test_float_field_wrong_type_fails():
	json_value* v = json_parse(c"{\x22sensor\x22: \x22t3\x22, \x22low\x22: \x22cold\x22, \x22high\x22: 1.5}")
	jc_reading* q = from_json(jc_reading, v)
	assert_equal(0, cast(int, q))
	json_free(v)


void test_int_field_rejects_json_float():
	# Decode stays strict in the other direction: 8.5 does not truncate
	# into an int field
	json_value* v = json_parse(c"{\x22x\x22: 8.5, \x22y\x22: 9}")
	jc_point* p = from_json(jc_point, v)
	assert_equal(0, cast(int, p))
	json_free(v)


void test_map_char_keys_round_trip():
	jc_counts c
	c.tally = new map[char*, int]
	c.tally[c"a"] = 1
	c.tally[c"b"] = -2
	json_value* v = to_json(c)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22tally\x22:{\x22a\x22:1,\x22b\x22:-2}}", text)
	free(text)
	jc_counts* q = from_json(jc_counts, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(2, q.tally.length)
	assert_equal(1, q.tally[c"a"])
	assert_equal(-2, q.tally[c"b"])
	json_free(v)


void test_map_string_keys_round_trip():
	jc_titles t
	t.names = new map[string, string]
	t.names[s"ada"] = s"countess"
	t.names[s"grace"] = s"admiral"
	json_value* v = to_json(t)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22names\x22:{\x22ada\x22:\x22countess\x22,\x22grace\x22:\x22admiral\x22}}", text)
	free(text)
	jc_titles* q = from_json(jc_titles, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(2, q.names.length)
	assert_equal(1, utf8_equals(q.names[s"ada"], s"countess"))
	assert_equal(1, utf8_equals(q.names[s"grace"], s"admiral"))
	json_free(v)


void test_map_struct_values_round_trip():
	jc_places p
	p.sites = new map[char*, jc_point]
	jc_point site
	site.x = 3
	site.y = 4
	p.sites[c"home"] = site
	site.x = -1
	site.y = 0
	p.sites[c"work"] = site
	json_value* v = to_json(p)
	jc_places* q = from_json(jc_places, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(2, q.sites.length)
	jc_point got = q.sites[c"home"]
	assert_equal(3, got.x)
	assert_equal(4, got.y)
	got = q.sites[c"work"]
	assert_equal(-1, got.x)
	assert_equal(0, got.y)
	json_free(v)


void test_map_list_values_round_trip():
	jc_graph g
	g.edges = new map[char*, list[int]]
	g.edges[c"a"] = list[int]{1, 2}
	g.edges[c"b"] = list[int]{3}
	json_value* v = to_json(g)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22edges\x22:{\x22a\x22:[1,2],\x22b\x22:[3]}}", text)
	free(text)
	jc_graph* q = from_json(jc_graph, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(2, q.edges.length)
	list[int] row = q.edges[c"a"]
	assert_equal(2, row.length)
	assert_equal(2, row[1])
	row = q.edges[c"b"]
	assert_equal(1, row.length)
	assert_equal(3, row[0])
	json_free(v)


void test_nested_map_with_float_values_round_trip():
	jc_nested_map n
	n.outer = new map[char*, map[string, float]]
	map[string, float] inner = new map[string, float]
	inner[s"pi"] = 3.25
	inner[s"e"] = 2.75
	n.outer[c"consts"] = inner
	json_value* v = to_json(n)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22outer\x22:{\x22consts\x22:{\x22pi\x22:3.25,\x22e\x22:2.75}}}", text)
	free(text)
	jc_nested_map* q = from_json(jc_nested_map, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(1, q.outer.length)
	map[string, float] got = q.outer[c"consts"]
	assert_equal(2, got.length)
	assert_equal(1, got[s"pi"] == 3.25)
	assert_equal(1, got[s"e"] == 2.75)
	json_free(v)


void test_null_map_round_trip():
	jc_counts c
	c.tally = cast(map[char*, int], 0)
	json_value* v = to_json(c)
	assert_equal(json_type_null(), json_object_get(v, c"tally").type)
	jc_counts* q = from_json(jc_counts, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(0, cast(int, q.tally))
	free(cast(char*, cast(int, q)))
	json_free(v)


void test_empty_map_round_trip():
	jc_counts c
	c.tally = new map[char*, int]
	json_value* v = to_json(c)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22tally\x22:{}}", text)
	free(text)
	jc_counts* q = from_json(jc_counts, v)
	assert_equal(1, cast(int, q) != 0)
	assert_equal(1, cast(int, q.tally) != 0)
	assert_equal(0, q.tally.length)
	json_free(v)


void test_map_decode_non_object_fails():
	json_value* v = json_parse(c"{\x22tally\x22: [1, 2]}")
	jc_counts* q = from_json(jc_counts, v)
	assert_equal(0, cast(int, q))
	json_free(v)


void test_map_decode_bad_member_fails():
	json_value* v = json_parse(c"{\x22tally\x22: {\x22a\x22: 1, \x22b\x22: \x22two\x22}}")
	jc_counts* q = from_json(jc_counts, v)
	assert_equal(0, cast(int, q))
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
