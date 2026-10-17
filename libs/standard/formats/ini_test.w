# wbuild: x64
# wbuild: step="bin/ini_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import libs.standard.formats.ini


ini_config* ini_test_ok(char* text):
	ini_config* cfg = ini_parse(text)
	if ini_error(cfg) != INI_OK: print_error(ini_error_message(cfg))
	assert_equal(INI_OK, ini_error(cfg))
	assert_equal(0, ini_error_line(cfg))
	assert_strings_equal(c"", ini_error_message(cfg))
	return cfg


void ini_test_fails(char* text, int status, int line, char* message):
	ini_config* cfg = ini_parse(text)
	assert_equal(status, ini_error(cfg))
	assert_equal(line, ini_error_line(cfg))
	assert_strings_equal(message, ini_error_message(cfg))
	ini_free(cfg)


void test_ini_basic_sections_and_delimiters():
	ini_config* cfg = ini_test_ok(c"[server]\nhost = example.com\nport: 8080\nname=  spaced value  \n\n[client]\nretries=3\n")
	assert_strings_equal(c"example.com", ini_get(cfg, c"server", c"host"))
	assert_strings_equal(c"8080", ini_get(cfg, c"server", c"port"))
	assert_strings_equal(c"spaced value", ini_get(cfg, c"server", c"name"))
	assert_strings_equal(c"3", ini_get(cfg, c"client", c"retries"))
	list[char*] secs = ini_sections(cfg)
	assert_equal(2, secs.length)
	assert_strings_equal(c"server", secs[0])
	assert_strings_equal(c"client", secs[1])
	secs.free()
	ini_free(cfg)


void test_ini_first_delimiter_wins():
	ini_config* cfg = ini_test_ok(c"[s]\nurl = http://x/?a=b\ntime: 12:30\nk=v=w\n")
	assert_strings_equal(c"http://x/?a=b", ini_get(cfg, c"s", c"url"))
	assert_strings_equal(c"12:30", ini_get(cfg, c"s", c"time"))
	assert_strings_equal(c"v=w", ini_get(cfg, c"s", c"k"))
	ini_free(cfg)


void test_ini_empty_value_and_missing():
	ini_config* cfg = ini_test_ok(c"[s]\nempty =\nother:\n")
	assert_strings_equal(c"", ini_get(cfg, c"s", c"empty"))
	assert_strings_equal(c"", ini_get(cfg, c"s", c"other"))
	assert_equal(0, cast(int, ini_get(cfg, c"s", c"nope")))
	assert_equal(0, cast(int, ini_get(cfg, c"nosuch", c"empty")))
	assert_strings_equal(c"fb", ini_get_or(cfg, c"s", c"nope", c"fb"))
	assert_strings_equal(c"", ini_get_or(cfg, c"s", c"empty", c"fb"))
	ini_free(cfg)


void test_ini_comments():
	char* text = c"# leading\n; also\n[s]\n  # indented comment\na = 1 # not a comment\nb = x ; kept\n;c = 3\n"
	ini_config* cfg = ini_test_ok(text)
	assert_strings_equal(c"1 # not a comment", ini_get(cfg, c"s", c"a"))
	assert_strings_equal(c"x ; kept", ini_get(cfg, c"s", c"b"))
	assert_equal(0, ini_has_option(cfg, c"s", c"c"))
	list[char*] opts = ini_options(cfg, c"s")
	assert_equal(2, opts.length)
	opts.free()
	ini_free(cfg)


void test_ini_case_insensitive_keys_case_sensitive_sections():
	ini_config* cfg = ini_test_ok(c"[Sec]\nMixedCase = 1\n[sec]\nkey = 2\n")
	assert_strings_equal(c"1", ini_get(cfg, c"Sec", c"mixedcase"))
	assert_strings_equal(c"1", ini_get(cfg, c"Sec", c"MIXEDCASE"))
	assert_strings_equal(c"2", ini_get(cfg, c"sec", c"KEY"))
	assert_equal(0, cast(int, ini_get(cfg, c"sec", c"mixedcase")))
	assert1(ini_has_section(cfg, c"Sec"))
	assert1(ini_has_section(cfg, c"sec"))
	assert_equal(0, ini_has_section(cfg, c"SEC"))
	list[char*] opts = ini_options(cfg, c"Sec")
	assert_strings_equal(c"mixedcase", opts[0])
	opts.free()
	ini_free(cfg)


void test_ini_multiline_values():
	char* text = c"[s]\nlong = first\n  second\n\tthird\n\n  after blank\nnext = 1\n  # comment inside\n  more\n\n\ntail = a\n   b\n\n\n"
	ini_config* cfg = ini_test_ok(text)
	assert_strings_equal(c"first\nsecond\nthird\n\nafter blank", ini_get(cfg, c"s", c"long"))
	assert_strings_equal(c"1\nmore", ini_get(cfg, c"s", c"next"))
	assert_strings_equal(c"a\nb", ini_get(cfg, c"s", c"tail"))
	ini_free(cfg)


void test_ini_indented_keys_and_continuation_levels():
	# an indented key line sets the level its continuations must exceed
	ini_config* cfg = ini_test_ok(c"[s]\n  a = 1\n  b = 2\n    more\n")
	assert_strings_equal(c"1", ini_get(cfg, c"s", c"a"))
	assert_strings_equal(c"2\nmore", ini_get(cfg, c"s", c"b"))
	ini_free(cfg)
	# like Python, an indented key line after a key is a continuation
	cfg = ini_test_ok(c"[s]\na = 1\n  b = 2\n")
	assert_strings_equal(c"1\nb = 2", ini_get(cfg, c"s", c"a"))
	assert_equal(0, ini_has_option(cfg, c"s", c"b"))
	ini_free(cfg)
	# a line indented under a section header is a key, not a continuation
	cfg = ini_test_ok(c"[s]\n\tk = v\n")
	assert_strings_equal(c"v", ini_get(cfg, c"s", c"k"))
	ini_free(cfg)


void test_ini_crlf():
	ini_config* cfg = ini_test_ok(c"[s]\r\na = 1\r\nb = two\r\n  lines\r\n")
	assert_strings_equal(c"1", ini_get(cfg, c"s", c"a"))
	assert_strings_equal(c"two\nlines", ini_get(cfg, c"s", c"b"))
	assert1(ini_has_section(cfg, c"s"))
	ini_free(cfg)


void test_ini_section_header_forms():
	ini_config* cfg = ini_test_ok(c"[a b]\nk=1\n[x]y]\nk=2\n[ spaced ]\nk=3\n[last] trailing ] text\nk=4\n")
	assert_strings_equal(c"1", ini_get(cfg, c"a b", c"k"))
	assert_strings_equal(c"2", ini_get(cfg, c"x]y", c"k"))
	assert_strings_equal(c"3", ini_get(cfg, c" spaced ", c"k"))
	assert_strings_equal(c"4", ini_get(cfg, c"last] trailing ", c"k"))
	ini_free(cfg)


void test_ini_default_fallback():
	char* text = c"[DEFAULT]\nhost = localhost\nport = 80\n[web]\nport = 8080\n[db]\n"
	ini_config* cfg = ini_test_ok(text)
	assert_strings_equal(c"localhost", ini_get(cfg, c"web", c"host"))
	assert_strings_equal(c"8080", ini_get(cfg, c"web", c"port"))
	assert_strings_equal(c"80", ini_get(cfg, c"db", c"port"))
	assert_strings_equal(c"80", ini_get(cfg, c"DEFAULT", c"port"))
	assert_equal(0, cast(int, ini_get(cfg, c"missing", c"port")))
	# DEFAULT is not a listed section
	assert_equal(0, ini_has_section(cfg, c"DEFAULT"))
	list[char*] secs = ini_sections(cfg)
	assert_equal(2, secs.length)
	secs.free()
	assert_equal(0, cast(int, ini_options(cfg, c"DEFAULT")))
	assert_equal(0, cast(int, ini_options(cfg, c"missing")))
	# options(): own keys, then DEFAULT keys not overridden
	list[char*] opts = ini_options(cfg, c"web")
	assert_equal(2, opts.length)
	assert_strings_equal(c"port", opts[0])
	assert_strings_equal(c"host", opts[1])
	opts.free()
	# has_option
	assert1(ini_has_option(cfg, c"db", c"HOST"))
	assert1(ini_has_option(cfg, c"", c"host"))
	assert1(ini_has_option(cfg, 0, c"host"))
	assert1(ini_has_option(cfg, c"DEFAULT", c"port"))
	assert_equal(0, ini_has_option(cfg, c"missing", c"host"))
	assert_equal(0, ini_has_option(cfg, c"db", c"nope"))
	ini_free(cfg)


void test_ini_repeated_default_header_is_allowed():
	ini_config* cfg = ini_test_ok(c"[DEFAULT]\na = 1\n[DEFAULT]\nb = 2\n[s]\n")
	assert_strings_equal(c"1", ini_get(cfg, c"s", c"a"))
	assert_strings_equal(c"2", ini_get(cfg, c"s", c"b"))
	ini_free(cfg)


void test_ini_get_int():
	ini_config* cfg = ini_test_ok(c"[n]\na = 42\nb = -17\nc = +5\nd = 1_000\ne = 007\nbad1 = 1.5\nbad2 = 1__0\nbad3 = _1\nbad4 = 1_\nbad5 = \nbad6 = 12abc\nbad7 = -\nbig = 99999999999999999999999\n")
	int v = 0
	assert_equal(INI_OK, ini_get_int(cfg, c"n", c"a", &v))
	assert_equal(42, v)
	assert_equal(INI_OK, ini_get_int(cfg, c"n", c"b", &v))
	assert_equal(-17, v)
	assert_equal(INI_OK, ini_get_int(cfg, c"n", c"c", &v))
	assert_equal(5, v)
	assert_equal(INI_OK, ini_get_int(cfg, c"n", c"d", &v))
	assert_equal(1000, v)
	assert_equal(INI_OK, ini_get_int(cfg, c"n", c"e", &v))
	assert_equal(7, v)
	v = 123
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"bad1", &v))
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"bad2", &v))
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"bad3", &v))
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"bad4", &v))
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"bad5", &v))
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"bad6", &v))
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"bad7", &v))
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"big", &v))
	assert_equal(123, v)
	assert_equal(INI_NO_OPTION, ini_get_int(cfg, c"n", c"zz", &v))
	assert_equal(INI_NO_SECTION, ini_get_int(cfg, c"zz", c"a", &v))
	ini_free(cfg)


void test_ini_get_int_word_limits():
	ini_config* cfg = ini_new()
	assert_equal(INI_OK, ini_add_section(cfg, c"n"))
	int v = 0
	if __word_size__ == 4:
		ini_set(cfg, c"n", c"max", c"2147483647")
		ini_set(cfg, c"n", c"min", c"-2147483648")
		ini_set(cfg, c"n", c"over", c"2147483648")
		ini_set(cfg, c"n", c"under", c"-2147483649")
	else:
		ini_set(cfg, c"n", c"max", c"9223372036854775807")
		ini_set(cfg, c"n", c"min", c"-9223372036854775808")
		ini_set(cfg, c"n", c"over", c"9223372036854775808")
		ini_set(cfg, c"n", c"under", c"-9223372036854775809")
	int maxv = ~(1 << (__word_size__ * 8 - 1))
	assert_equal(INI_OK, ini_get_int(cfg, c"n", c"max", &v))
	assert_equal(maxv, v)
	assert_equal(INI_OK, ini_get_int(cfg, c"n", c"min", &v))
	assert_equal(-maxv - 1, v)
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"over", &v))
	assert_equal(INI_BAD_VALUE, ini_get_int(cfg, c"n", c"under", &v))
	ini_free(cfg)


void test_ini_get_bool():
	ini_config* cfg = ini_test_ok(c"[b]\nt1 = yes\nt2 = TRUE\nt3 = On\nt4 = 1\nf1 = no\nf2 = False\nf3 = OFF\nf4 = 0\nbad = maybe\nbad2 = 2\nbad3 =\n")
	int v = 7
	assert_equal(INI_OK, ini_get_bool(cfg, c"b", c"t1", &v))
	assert_equal(1, v)
	assert_equal(INI_OK, ini_get_bool(cfg, c"b", c"t2", &v))
	assert_equal(1, v)
	assert_equal(INI_OK, ini_get_bool(cfg, c"b", c"t3", &v))
	assert_equal(1, v)
	assert_equal(INI_OK, ini_get_bool(cfg, c"b", c"t4", &v))
	assert_equal(1, v)
	assert_equal(INI_OK, ini_get_bool(cfg, c"b", c"f1", &v))
	assert_equal(0, v)
	assert_equal(INI_OK, ini_get_bool(cfg, c"b", c"f2", &v))
	assert_equal(0, v)
	assert_equal(INI_OK, ini_get_bool(cfg, c"b", c"f3", &v))
	assert_equal(0, v)
	assert_equal(INI_OK, ini_get_bool(cfg, c"b", c"f4", &v))
	assert_equal(0, v)
	assert_equal(INI_BAD_VALUE, ini_get_bool(cfg, c"b", c"bad", &v))
	assert_equal(INI_BAD_VALUE, ini_get_bool(cfg, c"b", c"bad2", &v))
	assert_equal(INI_BAD_VALUE, ini_get_bool(cfg, c"b", c"bad3", &v))
	assert_equal(INI_NO_OPTION, ini_get_bool(cfg, c"b", c"none", &v))
	assert_equal(INI_NO_SECTION, ini_get_bool(cfg, c"x", c"t1", &v))
	ini_free(cfg)


void ini_test_float(ini_config* cfg, char* key, float want):
	float f = 0.0
	assert_equal(INI_OK, ini_get_float(cfg, c"f", key, &f))
	assert_near(want, f)


void ini_test_float_text(float f, char* want):
	char* text = ftoa(f)
	assert_strings_equal(want, text)
	free(text)


void test_ini_get_float():
	ini_config* cfg = ini_test_ok(c"[f]\na = 1.5\nb = -2\nc = 1e3\nd = .25\ne = 5.\ng = 1_000.5\nh = 2.5E-1\ni = 5.e1\nbad = abc\nbad2 = 1.5x\nbad3 =\nbad4 = 1__0\nbad5 = .\ninf = inf\nninf = -Infinity\nnan = NaN\n")
	ini_test_float(cfg, c"a", 1.5)
	ini_test_float(cfg, c"b", -2.0)
	ini_test_float(cfg, c"c", 1000.0)
	ini_test_float(cfg, c"d", 0.25)
	ini_test_float(cfg, c"e", 5.0)
	ini_test_float(cfg, c"g", 1000.5)
	ini_test_float(cfg, c"h", 0.25)
	ini_test_float(cfg, c"i", 50.0)
	float f = 0.0
	assert_equal(INI_OK, ini_get_float(cfg, c"f", c"inf", &f))
	ini_test_float_text(f, c"inf")
	assert_equal(INI_OK, ini_get_float(cfg, c"f", c"ninf", &f))
	ini_test_float_text(f, c"-inf")
	assert_equal(INI_OK, ini_get_float(cfg, c"f", c"nan", &f))
	ini_test_float_text(f, c"nan")
	assert_equal(INI_BAD_VALUE, ini_get_float(cfg, c"f", c"bad", &f))
	assert_equal(INI_BAD_VALUE, ini_get_float(cfg, c"f", c"bad2", &f))
	assert_equal(INI_BAD_VALUE, ini_get_float(cfg, c"f", c"bad3", &f))
	assert_equal(INI_BAD_VALUE, ini_get_float(cfg, c"f", c"bad4", &f))
	assert_equal(INI_BAD_VALUE, ini_get_float(cfg, c"f", c"bad5", &f))
	assert_equal(INI_NO_OPTION, ini_get_float(cfg, c"f", c"none", &f))
	assert_equal(INI_NO_SECTION, ini_get_float(cfg, c"none", c"a", &f))
	ini_free(cfg)


void test_ini_typed_getters_use_default():
	ini_config* cfg = ini_test_ok(c"[DEFAULT]\nworkers = 4\ndebug = on\n[app]\n")
	int v = 0
	assert_equal(INI_OK, ini_get_int(cfg, c"app", c"Workers", &v))
	assert_equal(4, v)
	assert_equal(INI_OK, ini_get_bool(cfg, c"app", c"debug", &v))
	assert_equal(1, v)
	ini_free(cfg)


void test_ini_error_duplicate_section():
	ini_test_fails(c"[a]\nx = 1\n[b]\n[a]\n", INI_DUPLICATE_SECTION, 4, c"line 4: section 'a' already exists")


void test_ini_error_duplicate_option():
	ini_test_fails(c"[a]\nx = 1\ny = 2\nX = 3\n", INI_DUPLICATE_OPTION, 4, c"line 4: option 'x' in section 'a' already exists")
	ini_test_fails(c"[DEFAULT]\nx = 1\n[DEFAULT]\nx = 2\n", INI_DUPLICATE_OPTION, 4, c"line 4: option 'x' in section 'DEFAULT' already exists")
	# the same key in different sections is fine
	ini_config* cfg = ini_test_ok(c"[a]\nx = 1\n[b]\nx = 2\n")
	ini_free(cfg)


void test_ini_error_missing_header():
	ini_test_fails(c"# c\n\nkey = value\n[s]\n", INI_MISSING_SECTION_HEADER, 3, c"line 3: file contains no section headers")
	ini_test_fails(c"  key = value\n", INI_MISSING_SECTION_HEADER, 1, c"line 1: file contains no section headers")


void test_ini_error_parse():
	ini_test_fails(c"[s]\na = 1\njust words\n", INI_PARSE_ERROR, 3, c"line 3: parsing error: 'just words'")
	ini_test_fails(c"[s]\n= value\n", INI_PARSE_ERROR, 2, c"line 2: parsing error: '= value'")
	ini_test_fails(c"[s]\n  : value\n", INI_PARSE_ERROR, 2, c"line 2: parsing error: ': value'")
	ini_test_fails(c"[s]\n[]\n", INI_PARSE_ERROR, 2, c"line 2: parsing error: '[]'")
	ini_test_fails(c"[unterminated\n", INI_MISSING_SECTION_HEADER, 1, c"line 1: file contains no section headers")


void test_ini_empty_and_comment_only_input():
	ini_config* cfg = ini_test_ok(c"")
	list[char*] secs = ini_sections(cfg)
	assert_equal(0, secs.length)
	secs.free()
	ini_free(cfg)
	cfg = ini_test_ok(c"# only\n; comments\n\n")
	char* out = ini_write(cfg)
	assert_strings_equal(c"", out)
	free(out)
	ini_free(cfg)


void test_ini_second_read_merges():
	ini_config* cfg = ini_test_ok(c"[a]\nx = 1\ny = 2\n")
	assert_equal(INI_OK, ini_read_string(cfg, c"[a]\nx = 10\n[b]\nz = 3\n"))
	assert_strings_equal(c"10", ini_get(cfg, c"a", c"x"))
	assert_strings_equal(c"2", ini_get(cfg, c"a", c"y"))
	assert_strings_equal(c"3", ini_get(cfg, c"b", c"z"))
	# an error clears on the next successful read
	assert_equal(INI_PARSE_ERROR, ini_read_string(cfg, c"[a]\nbroken\n"))
	assert_equal(2, ini_error_line(cfg))
	assert_equal(INI_OK, ini_read_string(cfg, c"[c]\n"))
	assert_equal(INI_OK, ini_error(cfg))
	assert_strings_equal(c"", ini_error_message(cfg))
	ini_free(cfg)


void test_ini_set_add_remove():
	ini_config* cfg = ini_new()
	assert_equal(INI_NO_SECTION, ini_set(cfg, c"s", c"k", c"v"))
	assert_equal(INI_OK, ini_add_section(cfg, c"s"))
	assert_equal(INI_DUPLICATE_SECTION, ini_add_section(cfg, c"s"))
	assert_equal(INI_BAD_VALUE, ini_add_section(cfg, c"DEFAULT"))
	assert_equal(INI_INVALID_NAME, ini_add_section(cfg, c""))
	assert_equal(INI_INVALID_NAME, ini_add_section(cfg, c"a\nb"))
	assert_equal(INI_OK, ini_set(cfg, c"s", c"Key", c"v1"))
	assert_strings_equal(c"v1", ini_get(cfg, c"s", c"key"))
	assert_equal(INI_OK, ini_set(cfg, c"s", c"KEY", c"v2"))
	assert_strings_equal(c"v2", ini_get(cfg, c"s", c"key"))
	assert_equal(INI_OK, ini_set(cfg, c"DEFAULT", c"d", c"dv"))
	assert_equal(INI_OK, ini_set(cfg, c"", c"e", c"ev"))
	assert_strings_equal(c"dv", ini_get(cfg, c"s", c"d"))
	assert_strings_equal(c"ev", ini_get(cfg, c"s", c"e"))
	assert_equal(INI_INVALID_NAME, ini_set(cfg, c"s", c"a=b", c"v"))
	assert_equal(INI_INVALID_NAME, ini_set(cfg, c"s", c"a:b", c"v"))
	assert_equal(INI_INVALID_NAME, ini_set(cfg, c"s", c"", c"v"))
	assert_equal(INI_INVALID_NAME, ini_set(cfg, c"s", c" a", c"v"))
	assert_equal(INI_INVALID_NAME, ini_set(cfg, c"s", c"#a", c"v"))
	assert_equal(INI_INVALID_NAME, ini_set(cfg, c"s", c"[a", c"v"))
	assert_equal(INI_INVALID_NAME, ini_set(cfg, c"s", c"a\nb", c"v"))
	assert_equal(1, ini_remove_option(cfg, c"s", c"KEY"))
	assert_equal(0, ini_remove_option(cfg, c"s", c"key"))
	assert_equal(0, ini_remove_option(cfg, c"nosuch", c"key"))
	# removing from a section does not touch DEFAULT
	assert_equal(0, ini_remove_option(cfg, c"s", c"d"))
	assert1(ini_has_option(cfg, c"s", c"d"))
	assert_equal(1, ini_remove_option(cfg, c"DEFAULT", c"d"))
	assert_equal(0, ini_has_option(cfg, c"s", c"d"))
	assert_equal(INI_OK, ini_add_section(cfg, c"t"))
	assert_equal(0, ini_remove_section(cfg, c"DEFAULT"))
	assert_equal(0, ini_remove_section(cfg, c"nosuch"))
	assert_equal(1, ini_remove_section(cfg, c"s"))
	assert_equal(0, ini_has_section(cfg, c"s"))
	list[char*] secs = ini_sections(cfg)
	assert_equal(1, secs.length)
	assert_strings_equal(c"t", secs[0])
	secs.free()
	ini_free(cfg)


void test_ini_write_layout():
	ini_config* cfg = ini_test_ok(c"[DEFAULT]\nbase = /srv\n[web]\nPort: 80\nmotd = hello\n  world\n\n  again\nempty =\n[empty]\n")
	char* out = ini_write(cfg)
	assert_strings_equal(c"[DEFAULT]\nbase = /srv\n\n[web]\nport = 80\nmotd = hello\n\tworld\n\t\n\tagain\nempty = \n\n[empty]\n\n", out)
	free(out)
	ini_free(cfg)


void ini_test_same(ini_config* a, ini_config* b):
	list[char*] sa = ini_sections(a)
	list[char*] sb = ini_sections(b)
	assert_equal(sa.length, sb.length)
	for int i in range(sa.length):
		assert_strings_equal(sa[i], sb[i])
		list[char*] oa = ini_options(a, sa[i])
		list[char*] ob = ini_options(b, sb[i])
		assert_equal(oa.length, ob.length)
		for int j in range(oa.length):
			assert_strings_equal(oa[j], ob[j])
			assert_strings_equal(ini_get(a, sa[i], oa[j]), ini_get(b, sb[i], ob[j]))
		oa.free()
		ob.free()
	sa.free()
	sb.free()


void test_ini_round_trip():
	char* text = c"; header comment\n[DEFAULT]\nRoot = /opt\n\n[paths]\nbin: %(root)s/bin\nlist = a\n    b\n\n    c\n\n# trailing\n[x]y]\nk = v=1\n"
	ini_config* a = ini_test_ok(text)
	char* out1 = ini_write(a)
	ini_config* b = ini_test_ok(out1)
	ini_test_same(a, b)
	char* out2 = ini_write(b)
	assert_strings_equal(out1, out2)
	free(out1)
	free(out2)
	ini_free(a)
	ini_free(b)


void test_ini_round_trip_built():
	ini_config* a = ini_new()
	ini_add_section(a, c"one")
	ini_add_section(a, c"two")
	ini_set(a, c"one", c"multi", c"line1\nline2\n\nline4")
	ini_set(a, c"one", c"pct", c"100%")
	ini_set(a, c"two", c"x", c"")
	ini_set(a, 0, c"shared", c"yes")
	char* out = ini_write(a)
	ini_config* b = ini_test_ok(out)
	ini_test_same(a, b)
	assert_strings_equal(c"line1\nline2\n\nline4", ini_get(b, c"one", c"multi"))
	assert_strings_equal(c"yes", ini_get(b, c"two", c"shared"))
	free(out)
	ini_free(a)
	ini_free(b)


void ini_test_interp(ini_config* cfg, char* section, char* key, char* want):
	int st = -1
	char* got = ini_get_interpolated(cfg, section, key, &st)
	assert_equal(INI_OK, st)
	assert_strings_equal(want, got)
	free(got)


void ini_test_interp_fails(ini_config* cfg, char* section, char* key, int want):
	int st = -1
	char* got = ini_get_interpolated(cfg, section, key, &st)
	assert_equal(want, st)
	assert_equal(0, cast(int, got))


void test_ini_interpolation():
	char* text = c"[DEFAULT]\nhome = /home/u\n[paths]\nHome_Dir = %(home)s/dir\nnested = %(HOME_DIR)s/sub\npercent = 100%%\nplain = no refs\nmissing = %(nope)s\nbad1 = 50%\nbad2 = %(home)\nbad3 = %x\nbad4 = %()s\nloop = %(loop)s\nmulti = %(home)s:%(home)s\n"
	ini_config* cfg = ini_test_ok(text)
	# off by default: ini_get is raw
	assert_strings_equal(c"%(home)s/dir", ini_get(cfg, c"paths", c"home_dir"))
	assert_strings_equal(c"100%%", ini_get(cfg, c"paths", c"percent"))
	ini_test_interp(cfg, c"paths", c"home_dir", c"/home/u/dir")
	ini_test_interp(cfg, c"paths", c"nested", c"/home/u/dir/sub")
	ini_test_interp(cfg, c"paths", c"percent", c"100%")
	ini_test_interp(cfg, c"paths", c"plain", c"no refs")
	ini_test_interp(cfg, c"paths", c"multi", c"/home/u:/home/u")
	ini_test_interp(cfg, c"DEFAULT", c"home", c"/home/u")
	ini_test_interp_fails(cfg, c"paths", c"missing", INI_INTERPOLATION_MISSING)
	ini_test_interp_fails(cfg, c"paths", c"bad1", INI_INTERPOLATION_SYNTAX)
	ini_test_interp_fails(cfg, c"paths", c"bad2", INI_INTERPOLATION_SYNTAX)
	ini_test_interp_fails(cfg, c"paths", c"bad3", INI_INTERPOLATION_SYNTAX)
	ini_test_interp_fails(cfg, c"paths", c"bad4", INI_INTERPOLATION_SYNTAX)
	ini_test_interp_fails(cfg, c"paths", c"loop", INI_INTERPOLATION_DEPTH)
	ini_test_interp_fails(cfg, c"paths", c"zzz", INI_NO_OPTION)
	ini_test_interp_fails(cfg, c"zzz", c"plain", INI_NO_SECTION)
	ini_free(cfg)


void test_ini_interpolation_depth_limit():
	# 10 levels of values holding references resolve; 11 is too deep
	# (Python's MAX_INTERPOLATION_DEPTH)
	char* text = c"[s]\nv0 = end\nv1 = %(v0)s\nv2 = %(v1)s\nv3 = %(v2)s\nv4 = %(v3)s\nv5 = %(v4)s\nv6 = %(v5)s\nv7 = %(v6)s\nv8 = %(v7)s\nv9 = %(v8)s\nv10 = %(v9)s\nv11 = %(v10)s\n"
	ini_config* cfg = ini_test_ok(text)
	ini_test_interp(cfg, c"s", c"v10", c"end")
	ini_test_interp_fails(cfg, c"s", c"v11", INI_INTERPOLATION_DEPTH)
	ini_free(cfg)


void test_ini_status_names():
	assert_strings_equal(c"ok", ini_status_name(INI_OK))
	assert_strings_equal(c"duplicate section", ini_status_name(INI_DUPLICATE_SECTION))
	assert_strings_equal(c"invalid name", ini_status_name(INI_INVALID_NAME))
	assert_strings_equal(c"unknown", ini_status_name(99))
