# wbuild: x64
# The string <-> char* interop seams (#146 stage 1): borrowing cstr(),
# owning cstr_clone() (lib/utf8.w), and the reverse str_from_cstr()
# (lib/lib.w, also behind the implicit char* -> string coercion).
import lib.testing
import lib.utf8


void test_cstr_borrows_the_string_buffer():
	string s = "hello"
	char* p = cstr(s)
	assert_equal(cast(int, s.data), cast(int, p))
	assert_equal(5, strlen(p))
	assert_strings_equal(c"hello", p)


void test_cstr_clone_copies_and_terminates():
	string s = "hello"
	char* p = cstr_clone(s)
	assert1(cast(int, p) != cast(int, s.data))
	assert_equal(5, strlen(p))
	assert_strings_equal(c"hello", p)
	free(p)


void test_cstr_clone_empty_string():
	string s = ""
	char* p = cstr_clone(s)
	assert_equal(0, strlen(p))
	assert_equal(0, p[0])
	free(p)


void test_cstr_clone_non_ascii_utf8():
	string s = "caf\u00e9 \U0001f600"
	assert_equal(10, s.length)
	char* p = cstr_clone(s)
	assert_equal(10, strlen(p))
	assert_equal(0xc3, p[3] & 255)
	assert_equal(0xa9, p[4] & 255)
	assert_equal(0xf0, p[6] & 255)
	# round-trip back through the reverse seam
	string back = str_from_cstr(p)
	assert1(utf8_equals(s, back))
	free(p)


# Slices are views into the middle of a buffer, so they are generally not
# NUL-terminated; cstr() would assert on them, cstr_clone() must not.
void test_cstr_clone_accepts_unterminated_slice():
	string s = "hello world"
	string head = s[0:5]
	assert_equal(32, s.data[5]) # the byte after the slice is ' ', not NUL
	char* p = cstr_clone(head)
	assert_strings_equal(c"hello", p)
	free(p)
	string mid = s[6:9]
	char* q = cstr_clone(mid)
	assert_strings_equal(c"wor", q)
	free(q)


# Interior NULs are copied verbatim (all s.length bytes land in the
# buffer); a char* consumer sees the content truncated at the first NUL.
void test_cstr_clone_copies_interior_nul_verbatim():
	string s = "a\0b"
	assert_equal(3, s.length)
	char* p = cstr_clone(s)
	assert_equal(1, strlen(p))
	assert_equal('a', p[0])
	assert_equal(0, p[1])
	assert_equal('b', p[2])
	assert_equal(0, p[3])
	free(p)


# The #146 motivation: an f-string result fed straight into char* APIs.
void test_fstring_through_cstr_into_char_star_apis():
	int build_id = 42
	char* path = cstr(f"bin/.cache_{build_id}.stamp")
	assert_equal(19, strlen(path))
	assert_strings_equal(c"bin/.cache_42.stamp", path)
	char* owned = cstr_clone(f"bin/.cache_{build_id + 1}.stamp")
	assert_strings_equal(c"bin/.cache_43.stamp", owned)
	free(owned)


void test_round_trip_cstr_and_str_from_cstr():
	char* original = c"round trip"
	string s = str_from_cstr(original)
	assert_equal(10, s.length)
	# borrowing both ways: the pointer survives the round trip unchanged
	assert_equal(cast(int, original), cast(int, cstr(s)))
	# owning copy: fresh buffer, identical bytes
	char* copy = cstr_clone(s)
	assert1(cast(int, copy) != cast(int, original))
	assert_strings_equal(original, copy)
	free(copy)
