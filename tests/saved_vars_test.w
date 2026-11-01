# wbuild: x64
# lib/saved_vars.w (docs/projects/scripting.md S2): the host-side store,
# the layout-tolerant restore and file persistence.
import lib.testing
import lib.saved_vars


struct sv_v1:
	int kills
	char* name
	int legacy


struct sv_v2:
	int kills
	char* name
	int level
	list[int] marks


void assert_true(int condition):
	asserts(c"expected true", condition)


void test_restore_without_store_returns_defaults():
	char* got = saved_vars_restore(c"sv_none", c"{\"a\":1}")
	assert_strings_equal(c"{\"a\":1}", got)
	assert_equal(0, saved_vars_has(c"sv_none"))


void test_store_and_restore_same_layout():
	sv_v1* v = new sv_v1(7, c"orc", 3)
	saved_vars_store(c"sv_same", json_stringify(to_json(v)))
	assert_equal(1, saved_vars_has(c"sv_same"))
	sv_v1* fresh = new sv_v1(0, c"default", 0)
	sv_v1* back = from_json(sv_v1, json_parse(saved_vars_restore(c"sv_same", json_stringify(to_json(fresh)))))
	assert_true(back != 0)
	assert_equal(7, back.kills)
	assert_strings_equal(c"orc", back.name)
	assert_equal(3, back.legacy)


void test_layout_change_matches_fields_by_name():
	sv_v1* old = new sv_v1(12, c"troll", 99)
	saved_vars_store(c"sv_layout", json_stringify(to_json(old)))
	# the new layout drops 'legacy' and adds 'level' and 'marks': from_json
	# is strict, so only the reshaped value decodes
	sv_v2* fresh = new sv_v2(0, c"x", 5, new list[int])
	fresh.marks.push(1)
	char* defaults = json_stringify(to_json(fresh))
	assert_true(from_json(sv_v2, json_parse(saved_vars_get(c"sv_layout"))) == 0)
	sv_v2* back = from_json(sv_v2, json_parse(saved_vars_restore(c"sv_layout", defaults)))
	assert_true(back != 0)
	assert_equal(12, back.kills)
	assert_strings_equal(c"troll", back.name)
	assert_equal(5, back.level)
	assert_equal(1, back.marks.length)
	assert_equal(1, back.marks[0])


void test_merge_type_rules():
	json_value* defaults = json_parse(c"{\"n\":1,\"f\":1.5,\"s\":\"d\",\"b\":true,\"o\":{\"x\":1,\"y\":2},\"a\":[1,2],\"z\":null,\"k\":\"keep\"}")
	json_value* stored = json_parse(c"{\"n\":2.0,\"f\":3,\"s\":7,\"b\":false,\"o\":{\"y\":20,\"w\":9},\"a\":[5],\"z\":\"set\",\"k\":null,\"extra\":1}")
	json_value* merged = saved_vars_merge(defaults, stored)
	char* text = json_stringify(merged)
	# numbers convert, a type change keeps the default, objects merge by
	# member, arrays are taken whole, null defaults take references, a
	# stored null clears a reference, members the defaults lack are dropped
	assert_contains(text, c"\"n\":2")
	assert_contains(text, c"\"f\":3")
	assert_contains(text, c"\"s\":\"d\"")
	assert_contains(text, c"\"b\":false")
	assert_contains(text, c"\"o\":{\"x\":1,\"y\":20}")
	assert_contains(text, c"\"a\":[5]")
	assert_contains(text, c"\"z\":\"set\"")
	assert_contains(text, c"\"k\":null")
	assert_lacks(text, c"extra")
	assert_lacks(text, c"\"w\"")


void test_unparsable_store_keeps_defaults():
	saved_vars_store(c"sv_junk", c"{not json")
	assert_strings_equal(c"{\"a\":2}", saved_vars_restore(c"sv_junk", c"{\"a\":2}"))
	saved_vars_forget(c"sv_junk")
	assert_equal(0, saved_vars_has(c"sv_junk"))


void test_file_round_trip():
	saved_vars_store(c"sv_file_a", c"{\"kills\":3}")
	saved_vars_store(c"sv_file_b", c"[1,2,3]")
	char* path = c"bin/saved_vars_test.json"
	assert_equal(1, saved_vars_write_file(path))
	saved_vars_forget(c"sv_file_a")
	saved_vars_store(c"sv_file_b", c"[]")
	assert_equal(1, saved_vars_read_file(path))
	assert_strings_equal(c"{\"kills\":3}", saved_vars_get(c"sv_file_a"))
	assert_strings_equal(c"[1,2,3]", saved_vars_get(c"sv_file_b"))
	unlink(path)
	assert_equal(0, saved_vars_read_file(path))
