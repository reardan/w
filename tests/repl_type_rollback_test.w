# wbuild: x64
/*
REPL rollback of in-place type redefinitions (grammar/type_redefine.w):
a struct, union or enum redefinition resets the existing type record in
place, so the per-entry rollback and :reset must put its earlier layout,
its enum constants and its to_json descriptor back, not only truncate the
type table by count.
*/
import lib.testing
import repl.core


int rollback_ready


void rollback_session():
	if (rollback_ready): return;
	repl_init()
	rollback_ready = 1


int rollback_eval(char* text):
	repl_result r = repl_eval(text)
	assert_equal(1, r.status)
	return r.value


char* rollback_text(char* text):
	return cast(char*, rollback_eval(text))


void rollback_rejected(char* text):
	repl_result r = repl_eval(text)
	assert_equal(0, r.status)


void test_failed_entry_restores_struct_layout():
	rollback_session()
	rollback_eval(c"struct rb_pair:\n\tint a\n\tint b\n")
	assert_equal(2 * __word_size__, rollback_eval(c"sizeof(rb_pair)"))
	# The redefinition compiles, then a later item of the same entry fails
	rollback_rejected(c"struct rb_pair:\n\tchar* name\n\tint a\n\tint b\n\tint c\n\nint rb_broken = rb_missing_name\n")
	assert_equal(2 * __word_size__, rollback_eval(c"sizeof(rb_pair)"))
	assert_equal(7, rollback_eval(c"rb_pair rb_p\nrb_p.a = 3\nrb_p.b = 4\nrb_p.a + rb_p.b"))
	rollback_rejected(c"rb_p.c")


void test_failed_entry_restores_union_and_enum():
	rollback_session()
	rollback_eval(c"union rb_word:\n\tint i\n\tchar c\n")
	rollback_eval(c"enum rb_color:\n\trb_red = 1\n\trb_blue = 2\n")
	assert_equal(__word_size__, rollback_eval(c"sizeof(rb_word)"))
	rollback_rejected(c"union rb_word:\n\tchar c\n\nenum rb_color:\n\trb_green = 7\n\nint rb_bad = rb_missing_name\n")
	assert_equal(__word_size__, rollback_eval(c"sizeof(rb_word)"))
	assert_strings_equal(c"rb_blue", rollback_text(c"enum_name(rb_blue)"))
	assert_strings_equal(c"7", rollback_text(c"enum_name(cast(rb_color, 7))"))


void test_redefinition_refreshes_json_descriptor():
	rollback_session()
	rollback_eval(c"import structures.json\nstruct rb_point:\n\tint x\n\nrb_point* rb_v = new rb_point(5)\n")
	assert_strings_equal(c"{\"x\":5}", rollback_text(c"json_stringify(to_json(rb_v))"))
	# A successful redefinition must not reuse the descriptor cached for
	# the old layout
	rollback_eval(c"struct rb_point:\n\tint x\n\tint y\n\nrb_point* rb_w = new rb_point(1, 2)\n")
	assert_strings_equal(c"{\"x\":1,\"y\":2}", rollback_text(c"json_stringify(to_json(rb_w))"))
	# A failed one must not leave the new layout's descriptor behind
	rollback_rejected(c"struct rb_point:\n\tint q\n\nchar* rb_q = json_stringify(to_json(new rb_point(9)))\nint rb_bad2 = rb_missing_name\n")
	assert_strings_equal(c"{\"x\":1,\"y\":2}", rollback_text(c"json_stringify(to_json(rb_w))"))


void test_reset_restores_layout_constants_and_descriptor():
	rollback_session()
	rollback_eval(c"struct rb_cfg:\n\tint volume\n\nrb_cfg* rb_c = new rb_cfg(50)\n")
	rollback_eval(c"enum rb_mode:\n\trb_on = 1\n")
	assert_strings_equal(c"{\"volume\":50}", rollback_text(c"json_stringify(to_json(rb_c))"))
	repl_genesis_checkpoint()
	rollback_eval(c"struct rb_cfg:\n\tint level\n\tint volume\n\tint muted\n")
	rollback_eval(c"enum rb_mode:\n\trb_off = 0\n")
	assert_equal(3 * __word_size__, rollback_eval(c"sizeof(rb_cfg)"))
	assert_strings_equal(c"{\"level\":0,\"volume\":0,\"muted\":0}", rollback_text(c"json_stringify(to_json(new rb_cfg))"))
	assert_equal(1, repl_reset_to_genesis())
	assert_equal(__word_size__, rollback_eval(c"sizeof(rb_cfg)"))
	assert_strings_equal(c"{\"volume\":50}", rollback_text(c"json_stringify(to_json(rb_c))"))
	assert_strings_equal(c"rb_on", rollback_text(c"enum_name(rb_on)"))
