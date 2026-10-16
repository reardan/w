# wbuild: x64
# wbuild: step="bin/re_ops_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
/*
Tests for the multi-match half of libs/standard/text/re.w (chunk P1.1b):
iteration, findall, sub/subn with templates and callbacks, split,
escape and the one-shot string forms. The test_*_table functions were
generated from CPython 3.13's `re` with re.ASCII (spans converted to
UTF-8 byte offsets), so they pin Python 3.7+'s empty-match rules: an
empty match may follow a non-empty one, but never sits at the position
where the previous empty match was.

List results are written as <item> per string and N for a 0 (None)
entry; findall rows wrap each match's items in ( ).
*/
import lib.testing
import libs.standard.text.re


# Growable formatting buffer for the expected-string comparisons.
char* re_ops_join(list[char*] items, int rows_open, int rows_close):
	re_buf* b = re_buf_new()
	if (rows_open): re_buf_add_char(b, '(')
	for i in range(items.length):
		char* s = items[i]
		if (s == 0):
			re_buf_add_char(b, 'N')
		else:
			re_buf_add_char(b, '<')
			re_buf_add(b, s, strlen(s))
			re_buf_add_char(b, '>')
	if (rows_close): re_buf_add_char(b, ')')
	return re_buf_take(b)


char* re_ops_rows(list[list[char*]] rows):
	re_buf* b = re_buf_new()
	for i in range(rows.length):
		char* row = re_ops_join(rows[i], 1, 1)
		re_buf_add(b, row, strlen(row))
		free(row)
	return re_buf_take(b)


char* re_ops_spans(list[re_result*] results):
	re_buf* b = re_buf_new()
	for i in range(results.length):
		if (i > 0): re_buf_add_char(b, ' ')
		char* s = itoa(re_start(results[i], 0))
		re_buf_add(b, s, strlen(s))
		free(s)
		re_buf_add_char(b, ',')
		s = itoa(re_end(results[i], 0))
		re_buf_add(b, s, strlen(s))
		free(s)
	return re_buf_take(b)


re_pattern* re_ops_compile(char* pattern, int flags):
	re_pattern* p = re_compile(pattern, flags)
	if (re_error(p) != 0):
		print_error(f"pattern {pattern} failed to compile: {re_error(p)}\n")
		assert1(0)
	return p


void re_ops_expect(char* what, char* pattern, char* text, char* want, char* got):
	if (strcmp(want, got) != 0): print_error(f"{what}: pattern {pattern} on {text}\n")
	assert_strings_equal(want, got)


void re_findall_case(char* pattern, int flags, char* text, char* want_flat, char* want_rows, char* want_spans):
	re_pattern* p = re_ops_compile(pattern, flags)
	list[char*] flat = re_findall(p, text)
	char* got = re_ops_join(flat, 0, 0)
	re_ops_expect(c"findall", pattern, text, want_flat, got)
	free(got)
	re_strings_free(flat)
	list[list[char*]] rows = re_findall_rows(p, text)
	got = re_ops_rows(rows)
	re_ops_expect(c"findall_rows", pattern, text, want_rows, got)
	free(got)
	re_rows_free(rows)
	list[re_result*] results = re_finditer(p, text)
	got = re_ops_spans(results)
	re_ops_expect(c"finditer", pattern, text, want_spans, got)
	free(got)
	re_results_free(results)
	re_free(p)


void re_sub_case(char* pattern, int flags, char* repl, char* text, int count, char* want, int want_n):
	re_pattern* p = re_ops_compile(pattern, flags)
	int n = -1
	char* got = re_subn(p, repl, text, count, &n)
	re_ops_expect(c"subn", pattern, text, want, got)
	assert_equal(want_n, n)
	free(got)
	got = re_sub(p, repl, text, count)
	re_ops_expect(c"sub", pattern, text, want, got)
	free(got)
	re_free(p)


void re_template_error_case(char* pattern, char* repl, char* want):
	re_pattern* p = re_ops_compile(pattern, 0)
	char* message = re_template_error(p, repl)
	if (message == 0):
		print_error(f"template {repl} for {pattern} was accepted\n")
		assert1(0)
	else:
		re_ops_expect(c"template error", pattern, repl, want, message)
	int n = 7
	char* out = re_subn(p, repl, c"a", 0, &n)
	assert1(out == 0)
	assert_equal(0, n)
	# Python validates the template before matching, so no match still fails.
	assert1(re_sub(p, repl, c"zzz") == 0)
	re_free(p)


void re_split_case(char* pattern, int flags, char* text, int maxsplit, char* want):
	re_pattern* p = re_ops_compile(pattern, flags)
	list[char*] pieces = re_split(p, text, maxsplit)
	char* got = re_ops_join(pieces, 0, 0)
	re_ops_expect(c"split", pattern, text, want, got)
	free(got)
	re_strings_free(pieces)
	re_free(p)


void re_escape_case(char* s, char* want):
	char* got = re_escape(s)
	re_ops_expect(c"escape", s, s, want, got)
	# the escaped form matches s literally
	re_pattern* p = re_ops_compile(got, 0)
	re_result* m = re_fullmatch(p, s)
	assert1(m != 0)
	re_result_free(m)
	re_free(p)
	free(got)


void test_findall_table():
	re_findall_case(c"\\d+", 0, c"a1 b22 c333 d", c"<1><22><333>", c"(<1>)(<22>)(<333>)", c"1,2 4,6 8,11")
	re_findall_case(c"x*", 0, c"abxd", c"<><><x><><>", c"(<>)(<>)(<x>)(<>)(<>)", c"0,0 1,1 2,3 3,3 4,4")
	re_findall_case(c"|a", 0, c"a", c"<><a><>", c"(<>)(<a>)(<>)", c"0,0 0,1 1,1")
	re_findall_case(c"a|", 0, c"aab", c"<a><a><><>", c"(<a>)(<a>)(<>)(<>)", c"0,1 1,2 2,2 3,3")
	re_findall_case(c"a*", 0, c"baaac", c"<><aaa><><>", c"(<>)(<aaa>)(<>)(<>)", c"0,0 1,4 4,4 5,5")
	re_findall_case(c"a*?", 0, c"aa", c"<><a><><a><>", c"(<>)(<a>)(<>)(<a>)(<>)", c"0,0 0,1 1,1 1,2 2,2")
	re_findall_case(c"", 0, c"abc", c"<><><><>", c"(<>)(<>)(<>)(<>)", c"0,0 1,1 2,2 3,3")
	re_findall_case(c"", 0, c"", c"<>", c"(<>)", c"0,0")
	re_findall_case(c"\\b", 0, c"hi there", c"<><><><>", c"(<>)(<>)(<>)(<>)", c"0,0 2,2 3,3 8,8")
	re_findall_case(c"\\B", 0, c"abc d", c"<><>", c"(<>)(<>)", c"1,1 2,2")
	re_findall_case(c"^", RE_MULTILINE, c"a\nb\n", c"<><><>", c"(<>)(<>)(<>)", c"0,0 2,2 4,4")
	re_findall_case(c"$", RE_MULTILINE, c"a\nb\n", c"<><><>", c"(<>)(<>)(<>)", c"1,1 3,3 4,4")
	re_findall_case(c"$", 0, c"a\nb\n", c"<><>", c"(<>)(<>)", c"3,3 4,4")
	re_findall_case(c"(\\w+)=(\\d*)", 0, c"a=1, b=, c=33", c"<a><1><b><><c><33>", c"(<a><1>)(<b><>)(<c><33>)", c"0,3 5,7 9,13")
	re_findall_case(c"(\\w)(x)?", 0, c"axbc", c"<a><x><b><><c><>", c"(<a><x>)(<b><>)(<c><>)", c"0,2 2,3 3,4")
	re_findall_case(c"(a)|b", 0, c"abba", c"<a><><><a>", c"(<a>)(<>)(<>)(<a>)", c"0,1 1,2 2,3 3,4")
	re_findall_case(c"(?:ab)+", 0, c"ababxab", c"<abab><ab>", c"(<abab>)(<ab>)", c"0,4 5,7")
	re_findall_case(c"(ab)+", 0, c"ababxab", c"<ab><ab>", c"(<ab>)(<ab>)", c"0,4 5,7")
	re_findall_case(c"[aeiou]", RE_IGNORECASE, c"HEllo wOrld", c"<E><o><O>", c"(<E>)(<o>)(<O>)", c"1,2 4,5 7,8")
	re_findall_case(c"\\s+", 0, c" a  b\t\nc ", c"< ><  ><\t\n>< >", c"(< >)(<  >)(<\t\n>)(< >)", c"0,1 2,4 5,7 8,9")
	re_findall_case(c".", 0, c"hé€😀", c"<h><é><€><😀>", c"(<h>)(<é>)(<€>)(<😀>)", c"0,1 1,3 3,6 6,10")
	re_findall_case(c".", RE_DOTALL, c"a\nb", c"<a><\n><b>", c"(<a>)(<\n>)(<b>)", c"0,1 1,2 2,3")
	re_findall_case(c"(.)\\w*", 0, c"café au lait", c"<c><é>< >< >", c"(<c>)(<é>)(< >)(< >)", c"0,3 3,5 5,8 8,13")
	re_findall_case(c"\\w+$", RE_MULTILINE, c"one two\nthree four\n", c"<two><four>", c"(<two>)(<four>)", c"4,7 14,18")
	re_findall_case(c"(a*)(b*)", 0, c"aabxb", c"<aa><b><><><><b><><>", c"(<aa><b>)(<><>)(<><b>)(<><>)", c"0,3 3,3 4,5 5,5")
	re_findall_case(c"(a|ab)(c|bcd)(d*)", 0, c"abcd abcd", c"<a><bcd><><a><bcd><>", c"(<a><bcd><>)(<a><bcd><>)", c"0,4 5,9")
	re_findall_case(c"x", 0, c"yyy", c"", c"", c"")
	re_findall_case(c"(x)?y", 0, c"yxy", c"<><x>", c"(<>)(<x>)", c"0,1 1,3")


void test_sub_table():
	re_sub_case(c"x*", 0, c"-", c"abxd", 0, c"-a-b--d-", 5)
	re_sub_case(c"x*", 0, c"-", c"", 0, c"-", 1)
	re_sub_case(c"", 0, c"-", c"abc", 0, c"-a-b-c-", 4)
	re_sub_case(c"", 0, c"-", c"abc", 2, c"-a-bc", 2)
	re_sub_case(c"a", 0, c"b", c"aaa", 2, c"bba", 2)
	re_sub_case(c"a", 0, c"b", c"aaa", 0, c"bbb", 3)
	re_sub_case(c"(\\w+) (\\w+)", 0, c"\\2 \\1", c"hello world, foo bar", 0, c"world hello, bar foo", 2)
	re_sub_case(c"(\\w+)@(\\w+)", 0, c"\\g<2> at \\g<1> (\\g<0>)", c"me@host you@there", 0, c"host at me (me@host) there at you (you@there)", 2)
	re_sub_case(c"(a)|b", 0, c"[\\1]", c"abab", 0, c"[a][][a][]", 4)
	re_sub_case(c"b", 0, c"\\n\\t\\\\", c"abc", 0, c"a\n\t\\c", 1)
	re_sub_case(c"b", 0, c"\\-\\&\\.", c"abc", 0, c"a\\-\\&\\.c", 1)
	re_sub_case(c"b", 0, c"\\0", c"abc", 0, c"a\x00c", 1)
	re_sub_case(c"b", 0, c"\\101\\0102", c"abc", 0, c"aA\x082c", 1)
	re_sub_case(c"b", 0, c"\\351", c"abc", 0, c"aéc", 1)
	re_sub_case(c"(b)", 0, c"\\1!", c"abc", 0, c"ab!c", 1)
	re_sub_case(c"(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)", 0, c"\\11\\10\\1", c"abcdefghijk!", 0, c"kja!", 1)
	re_sub_case(c"(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)", 0, c"\\g<11>\\g<1>0", c"abcdefghijk!", 0, c"ka0!", 1)
	re_sub_case(c"\\s+", 0, c" ", c"  lots   of\t\nspace ", 0, c" lots of space ", 4)
	re_sub_case(c"^", RE_MULTILINE, c"> ", c"line one\nline two\n", 0, c"> line one\n> line two\n> ", 3)
	re_sub_case(c"$", RE_MULTILINE, c";", c"a\nb\n", 0, c"a;\nb;\n;", 3)
	re_sub_case(c"\\b", 0, c"|", c"hi there", 0, c"|hi| |there|", 4)
	re_sub_case(c"a*", 0, c"X", c"baaac", 0, c"XbXXcX", 4)
	re_sub_case(c"a*?", 0, c"X", c"baac", 0, c"XbXXXXXcX", 7)
	re_sub_case(c"(?i)HELLO", 0, c"bye", c"Hello hello HELLO", 0, c"bye bye bye", 3)
	re_sub_case(c"[é]", 0, c"e", c"café crème brûlée", 0, c"cafe crème brûlee", 2)
	re_sub_case(c"x", 0, c"y", c"no match here", 0, c"no match here", 0)
	re_sub_case(c"(x)?y", 0, c"<\\1>", c"yxy", 0, c"<><x>", 2)
	re_sub_case(c".", 0, c"\\g<0>\\g<0>", c"abé", 0, c"aabbéé", 3)
	re_sub_case(c"\\d", 0, c"", c"a1b2c3", 0, c"abc", 3)
	re_sub_case(c"\\d", 0, c"#", c"a1b2c3", -1, c"a1b2c3", 0)


void test_template_errors():
	re_template_error_case(c"a", c"\\", c"bad escape (end of pattern)")  # bad escape (end of pattern)
	re_template_error_case(c"a", c"\\q", c"bad escape")  # bad escape \q
	re_template_error_case(c"a", c"\\1", c"invalid group reference")  # invalid group reference 1
	re_template_error_case(c"(a)", c"\\2", c"invalid group reference")  # invalid group reference 2
	re_template_error_case(c"(a)", c"\\g<2>", c"invalid group reference")  # invalid group reference 2
	re_template_error_case(c"a", c"\\g<", c"missing group name")  # missing group name
	re_template_error_case(c"a", c"\\g<1", c"missing >, unterminated name")  # missing >, unterminated name
	re_template_error_case(c"a", c"\\g<>", c"missing group name")  # missing group name
	re_template_error_case(c"a", c"\\g", c"missing <")  # missing <
	re_template_error_case(c"a", c"\\gx", c"missing <")  # missing <
	re_template_error_case(c"a", c"\\g<name>", c"unknown group name")  # unknown group name 'name'
	re_template_error_case(c"a", c"\\g<1a>", c"bad character in group name")  # bad character in group name '1a'
	re_template_error_case(c"a", c"\\g<->", c"bad character in group name")  # bad character in group name '-'
	re_template_error_case(c"a", c"\\400", c"octal escape value outside of range 0-0o377")  # octal escape value \400 outside of range 0-0o377
	re_template_error_case(c"a", c"\\x41", c"bad escape")  # bad escape \x
	re_template_error_case(c"(a)", c"\\12", c"invalid group reference")  # invalid group reference 12
	re_template_error_case(c"(b)", c"\\10", c"invalid group reference")  # invalid group reference 10


void test_split_table():
	re_split_case(c"\\W+", 0, c"Words, words, words.", 0, c"<Words><words><words><>")
	re_split_case(c"(\\W+)", 0, c"Words, words, words.", 0, c"<Words><, ><words><, ><words><.><>")
	re_split_case(c"\\W+", 0, c"Words, words, words.", 1, c"<Words><words, words.>")
	re_split_case(c"[a-f]+", RE_IGNORECASE, c"0a3B9", 0, c"<0><3><9>")
	re_split_case(c"(-)|(\\+)", 0, c"1-2+3", 0, c"<1><->N<2>N<+><3>")
	re_split_case(c"x*", 0, c"axbc", 0, c"<><a><><b><c><>")
	re_split_case(c"\\b", 0, c"a b", 0, c"<><a>< ><b><>")
	re_split_case(c"", 0, c"abc", 0, c"<><a><b><c><>")
	re_split_case(c"", 0, c"abc", 2, c"<><a><bc>")
	re_split_case(c"", 0, c"", 0, c"<><>")
	re_split_case(c"x", 0, c"", 0, c"<>")
	re_split_case(c",", 0, c"a,b,,c,", 0, c"<a><b><><c><>")
	re_split_case(c",", 0, c",a,b", 2, c"<><a><b>")
	re_split_case(c"^$", RE_MULTILINE, c"foo\n\nbar\n", 0, c"<foo\n><\nbar\n><>")
	re_split_case(c"\\s*", 0, c" a b ", 0, c"<><><a><><b><><>")
	re_split_case(c"(?:a)(b)?", 0, c"xaxabx", 0, c"<x>N<x><b><x>")
	re_split_case(c"(\\s)*", 0, c"a  b", 0, c"<>N<a>< ><>N<b>N<>")
	re_split_case(c"\\d", 0, c"a1b2c3", -1, c"<a1b2c3>")


void test_escape_table():
	re_escape_case(c"", c"")
	re_escape_case(c"v\x0bf\x0cr\x0d", c"v\\\x0bf\\\x0cr\\\x0d")
	re_escape_case(c"abc", c"abc")
	re_escape_case(c"a.b*c", c"a\\.b\\*c")
	re_escape_case(c"1+1=2", c"1\\+1=2")
	re_escape_case(c"x\ty\nz", c"x\\\ty\\\nz")
	re_escape_case(c"[a-z]{2,3}|(?:q)$^~&#", c"\\[a\\-z\\]\\{2,3\\}\\|\\(\\?:q\\)\\$\\^\\~\\&\\#")
	re_escape_case(c"café _-", c"café\\ _\\-")


void test_iterator():
	re_pattern* p = re_ops_compile(c"(\\d)(\\d)?", 0)
	char* text = c"1 23 456"
	re_iter* it = re_iter_new(p, text, -1)
	re_result* m = re_iter_next(it)
	assert_equal(0, re_start(m, 0))
	assert_equal(-1, re_start(m, 2))
	re_result_free(m)
	m = re_iter_next(it)
	assert_equal(2, re_start(m, 0))
	assert_equal(4, re_end(m, 0))
	re_result_free(m)
	m = re_iter_next(it)
	char* g = re_group(m, 0)
	assert_strings_equal(c"45", g)
	free(g)
	re_result_free(m)
	m = re_iter_next(it)
	assert_equal(7, re_start(m, 1))
	re_result_free(m)
	assert1(re_iter_next(it) == 0)
	# stays exhausted
	assert1(re_iter_next(it) == 0)
	re_iter_free(it)
	# an explicit length stops before the rest of the buffer
	it = re_iter_new(p, text, 3)
	m = re_iter_next(it)
	re_result_free(m)
	m = re_iter_next(it)
	assert_equal(2, re_start(m, 0))
	assert_equal(3, re_end(m, 0))
	re_result_free(m)
	assert1(re_iter_next(it) == 0)
	re_iter_free(it)
	re_iter_free(cast(re_iter*, 0))
	re_free(p)


char* re_ops_upper(re_result* m, void* context):
	int* calls = cast(int*, context)
	calls[0] = calls[0] + 1
	char* s = re_group(m, 0)
	int i = 0
	while (s[i] != 0):
		if ((s[i] >= 'a') && (s[i] <= 'z')): s[i] = s[i] - 32
		i = i + 1
	return s


char* re_ops_drop(re_result* m, void* context):
	return cast(char*, 0)


void test_sub_callback():
	re_pattern* p = re_ops_compile(c"\\b[a-z]", 0)
	int calls = 0
	int n = -1
	char* out = re_sub_fn(p, re_ops_upper, &calls, c"hello big world", 0, &n)
	assert_strings_equal(c"Hello Big World", out)
	assert_equal(3, calls)
	assert_equal(3, n)
	free(out)
	out = re_sub_fn(p, re_ops_upper, &calls, c"hello big world", 2, cast(int*, 0))
	assert_strings_equal(c"Hello Big world", out)
	assert_equal(5, calls)
	free(out)
	out = re_sub_fn(p, re_ops_drop, cast(void*, 0), c"a b c", 0, &n)
	assert_strings_equal(c"  ", out)
	assert_equal(3, n)
	free(out)
	re_free(p)
	# empty matches reach the callback too, at Python's positions
	p = re_ops_compile(c"x*", 0)
	calls = 0
	out = re_sub_fn(p, re_ops_upper, &calls, c"abxd", 0, &n)
	assert_strings_equal(c"abXd", out)
	assert_equal(5, calls)
	free(out)
	re_free(p)


void test_expand():
	re_pattern* p = re_ops_compile(c"(\\w+)=(\\w+)?", 0)
	re_result* m = re_search(p, c"  key= ")
	char* out = re_expand(p, m, c"\\2:\\g<1>:\\g<0>!")
	assert_strings_equal(c":key:key=!", out)
	free(out)
	assert1(re_expand(p, m, c"\\3") == 0)
	re_result_free(m)
	re_free(p)


void test_bad_pattern():
	re_pattern* p = re_compile(c"(", 0)
	assert1(re_error(p) != 0)
	list[char*] l = re_findall(p, c"abc")
	assert_equal(0, l.length)
	re_strings_free(l)
	list[list[char*]] rows = re_findall_rows(p, c"abc")
	assert_equal(0, rows.length)
	re_rows_free(rows)
	list[re_result*] results = re_finditer(p, c"abc")
	assert_equal(0, results.length)
	re_results_free(results)
	l = re_split(p, c"abc")
	assert_equal(0, l.length)
	re_strings_free(l)
	int n = 9
	assert1(re_subn(p, c"x", c"abc", 0, &n) == 0)
	assert_equal(0, n)
	assert1(re_sub_fn(p, re_ops_drop, cast(void*, 0), c"abc", 0, &n) == 0)
	re_free(p)
	assert1(re_sub_str(c"[", c"x", c"abc") == 0)
	assert1(re_search_str(c"[", c"abc") == 0)
	l = re_findall_str(c"[", c"abc")
	assert_equal(0, l.length)
	re_strings_free(l)
	l = re_split_str(c"[", c"abc")
	assert_equal(0, l.length)
	re_strings_free(l)
	re_strings_free(cast(list[char*], 0))
	re_rows_free(cast(list[list[char*]], 0))
	re_results_free(cast(list[re_result*], 0))


void test_string_conveniences():
	char* s = re_sub_str(c"(\\w+)@(\\w+)\\.com", c"\\2!\\1", c"mail bob@example.com now")
	assert_strings_equal(c"mail example!bob now", s)
	free(s)
	s = re_sub_str(c"A", c"-", c"aAaA", 3, RE_IGNORECASE)
	assert_strings_equal(c"---A", s)
	free(s)
	s = re_search_str(c"\\d+", c"abc 123 45")
	assert_strings_equal(c"123", s)
	free(s)
	assert1(re_search_str(c"\\d+", c"abc") == 0)
	s = re_search_str(c"B.", c"aab\nc", RE_IGNORECASE | RE_DOTALL)
	assert_strings_equal(c"b\n", s)
	free(s)
	re_pattern* p = re_ops_compile(c"x?", 0)
	s = re_search_text(p, c"abc")
	assert_strings_equal(c"", s)
	free(s)
	re_free(p)
	list[char*] l = re_findall_str(c"[A-Z]", c"aBcDe", 0)
	char* got = re_ops_join(l, 0, 0)
	assert_strings_equal(c"<B><D>", got)
	free(got)
	re_strings_free(l)
	l = re_split_str(c"\\s*,\\s*", c"a , b,c ,d", 2)
	got = re_ops_join(l, 0, 0)
	assert_strings_equal(c"<a><b><c ,d>", got)
	free(got)
	re_strings_free(l)
	l = re_split_str(c"X", c"axbXc", 0, RE_IGNORECASE)
	got = re_ops_join(l, 0, 0)
	assert_strings_equal(c"<a><b><c>", got)
	free(got)
	re_strings_free(l)


# Longer outputs grow the result buffer past its first allocation.
void test_long_output():
	re_buf* want = re_buf_new()
	re_buf* text = re_buf_new()
	for i in range(500):
		re_buf_add(text, c"ab", 2)
		re_buf_add(want, c"<a>b", 4)
	char* input = re_buf_take(text)
	char* expected = re_buf_take(want)
	re_pattern* p = re_ops_compile(c"a", 0)
	int n = 0
	char* out = re_subn(p, c"<\\g<0>>", input, 0, &n)
	assert_equal(500, n)
	assert_strings_equal(expected, out)
	free(out)
	re_free(p)
	free(input)
	free(expected)
