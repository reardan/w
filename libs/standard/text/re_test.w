# wbuild: x64
# wbuild: step="bin/re_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
/*
Tests for libs/standard/text/re.w. The tables in test_python_table and
test_search_from_pos were generated from CPython
3.13's `re` compiled with re.ASCII (this module's \d \w \s \b are
ASCII-only): pattern, flags, text, mode -> spans of every group, with
codepoint offsets converted to UTF-8 byte offsets, so they pin the
engine to Python's leftmost-first / greedy-lazy priority semantics.
*/
import lib.testing
import libs.standard.text.re


# Appends the decimal form of v to buf at *at.
void re_test_put_int(char* buf, int* at, int v):
	char* s = itoa(v)
	int i = 0
	while (s[i] != 0):
		buf[at[0]] = s[i]
		at[0] = at[0] + 1
		i = i + 1
	free(s)


# "s,e s,e ..." for every group of m, or "none".
char* re_test_format(re_result* m):
	char* buf = cast(char*, malloc(1024))
	if (m == 0):
		buf[0] = 'n'
		buf[1] = 'o'
		buf[2] = 'n'
		buf[3] = 'e'
		buf[4] = 0
		return buf
	int at = 0
	for g in range(re_groups(m) + 1):
		if (g > 0):
			buf[at] = ' '
			at = at + 1
		re_test_put_int(buf, &at, re_start(m, g))
		buf[at] = ','
		at = at + 1
		re_test_put_int(buf, &at, re_end(m, g))
	buf[at] = 0
	return buf


re_result* re_test_run(re_pattern* p, char* text, int len, int pos, int mode):
	if (mode == 'm'): return re_match_at(p, text, len, pos)
	if (mode == 'f'): return re_fullmatch_at(p, text, len, pos)
	return re_search_at(p, text, len, pos)


void re_check(char* pattern, int flags, char* text, int len, int pos, int mode, char* want):
	re_pattern* p = re_compile(pattern, flags)
	if (re_error(p) != 0):
		print_error(f"pattern {pattern} failed to compile: {re_error(p)}\n")
		assert1(0)
	re_result* m = re_test_run(p, text, len, pos, mode)
	char* got = re_test_format(m)
	if (strcmp(got, want) != 0):
		print_error(f"pattern {pattern} on {text} (mode {mode:c}, pos {pos})\n")
	assert_strings_equal(want, got)
	free(got)
	re_result_free(m)
	re_free(p)


void re_case(char* pattern, int flags, char* text, int len, int mode, char* want):
	re_check(pattern, flags, text, len, 0, mode, want)


void re_case_at(char* pattern, int flags, char* text, int pos, int mode, char* want):
	re_check(pattern, flags, text, strlen(text), pos, mode, want)


void re_error_case(char* pattern):
	re_pattern* p = re_compile(pattern, 0)
	if (re_error(p) == 0):
		print_error(f"pattern {pattern} should not compile\n")
	asserts(pattern, re_error(p) != 0)
	re_result* m = re_search(p, c"aaa")
	assert1(m == 0)
	re_free(p)


void test_group_text():
	re_pattern* p = re_compile(c"(\\w+)@(\\w+)(\\.com)?", 0)
	assert1(re_error(p) == 0)
	assert_equal(3, re_group_count(p))
	re_result* m = re_search(p, c"mail: joe@example now")
	assert1(m != 0)
	assert_equal(3, re_groups(m))
	char* all = re_group(m, 0)
	char* user = re_group(m, 1)
	char* host = re_group(m, 2)
	assert_strings_equal(c"joe@example", all)
	assert_strings_equal(c"joe", user)
	assert_strings_equal(c"example", host)
	assert1(re_group(m, 3) == 0)
	assert_equal(-1, re_start(m, 3))
	assert_equal(-1, re_end(m, 3))
	assert_equal(-1, re_start(m, 4))
	assert_equal(-1, re_end(m, -1))
	free(all)
	free(user)
	free(host)
	re_result_free(m)
	assert1(re_match(p, c"mail: joe@example") == 0)
	assert1(re_fullmatch(p, c"joe@example.com!") == 0)
	m = re_fullmatch(p, c"joe@example.com")
	assert1(m != 0)
	assert_equal(11, re_start(m, 3))
	re_result_free(m)
	re_free(p)


void test_free_null():
	re_free(cast(re_pattern*, 0))
	re_result_free(cast(re_result*, 0))


void test_empty_group_text():
	re_pattern* p = re_compile(c"a(b*)c", 0)
	re_result* m = re_search(p, c"xacx")
	char* g = re_group(m, 1)
	assert_strings_equal(c"", g)
	free(g)
	re_result_free(m)
	re_free(p)


void test_embedded_nul():
	re_pattern* p = re_compile(c"a\\x00+b", 0)
	char* text = c"za\x00\x00\x62"
	re_result* m = re_search_at(p, text, 5, 0)
	assert1(m != 0)
	assert_equal(1, re_start(m, 0))
	assert_equal(5, re_end(m, 0))
	re_result_free(m)
	re_free(p)


void test_compile_n():
	re_pattern* p = re_compile_n(c"ab|cd", 2, 0)
	re_result* m = re_search(p, c"xcdab")
	assert_equal(3, re_start(m, 0))
	re_result_free(m)
	re_free(p)


# A findall-style loop built on re_search_at (what P1.1b will do).
void test_iterate_matches():
	re_pattern* p = re_compile(c"\\d+", 0)
	char* text = c"a1 b22 c333 d"
	int len = strlen(text)
	int pos = 0
	int count = 0
	int total = 0
	while (pos <= len):
		re_result* m = re_search_at(p, text, len, pos)
		if (m == 0): break
		count = count + 1
		total = total + re_end(m, 0) - re_start(m, 0)
		pos = re_end(m, 0)
		if (re_end(m, 0) == re_start(m, 0)): pos = pos + 1
		re_result_free(m)
	assert_equal(3, count)
	assert_equal(6, total)
	re_free(p)


void test_flags_values():
	assert_equal(2, RE_IGNORECASE)
	assert_equal(8, RE_MULTILINE)
	assert_equal(16, RE_DOTALL)
	assert_equal(64, RE_VERBOSE)
	re_pattern* p = re_compile(c"A", RE_IGNORECASE | RE_ASCII)
	re_result* m = re_match(p, c"a")
	assert1(m != 0)
	re_result_free(m)
	re_free(p)


void test_error_positions():
	re_pattern* p = re_compile(c"ab[cd", 0)
	assert_strings_equal(c"unterminated character set", re_error(p))
	assert_equal(2, re_error_pos(p))
	re_free(p)
	p = re_compile(c"a(b", 0)
	assert_strings_equal(c"missing ), unterminated subpattern", re_error(p))
	assert_equal(1, re_error_pos(p))
	re_free(p)
	p = re_compile(c"ab)", 0)
	assert_strings_equal(c"unbalanced parenthesis", re_error(p))
	assert_equal(2, re_error_pos(p))
	re_free(p)
	p = re_compile(c"x**", 0)
	assert_strings_equal(c"multiple repeat", re_error(p))
	assert_equal(2, re_error_pos(p))
	re_free(p)
	p = re_compile(c"*", 0)
	assert_strings_equal(c"nothing to repeat", re_error(p))
	assert_equal(0, re_error_pos(p))
	re_free(p)
	p = re_compile(c"ab\\q", 0)
	assert_strings_equal(c"bad escape", re_error(p))
	assert_equal(2, re_error_pos(p))
	re_free(p)
	p = re_compile(c"(a)\\1", 0)
	assert_strings_equal(c"backreferences are not supported", re_error(p))
	re_free(p)
	p = re_compile(c"[b-a]", 0)
	assert_strings_equal(c"bad character range", re_error(p))
	assert_equal(1, re_error_pos(p))
	re_free(p)
	p = re_compile(c"a{99999999}", 0)
	assert_strings_equal(c"the repetition number is too large", re_error(p))
	re_free(p)
	p = re_compile(c"(?:a{1000}){1000}", 0)
	assert_strings_equal(c"pattern too large", re_error(p))
	re_free(p)
	p = re_compile(c"a\xffb", 0)
	assert_strings_equal(c"invalid UTF-8 in pattern", re_error(p))
	assert_equal(1, re_error_pos(p))
	re_free(p)


char* re_test_repeat(int ch, int n, int tail):
	char* s = cast(char*, malloc(n + 2))
	for i in range(n): s[i] = ch
	int len = n
	if (tail != 0):
		s[n] = tail
		len = n + 1
	s[len] = 0
	return s


# Patterns that take exponential time in a backtracking engine finish in
# linear time here.
void test_pathological_patterns():
	char* as = re_test_repeat('a', 20000, 0)
	char* asb = re_test_repeat('a', 20000, 'b')
	re_pattern* p = re_compile(c"(a*)*b", 0)
	assert1(re_search(p, as) == 0)
	re_result* m = re_search(p, asb)
	assert_equal(0, re_start(m, 0))
	assert_equal(20001, re_end(m, 0))
	assert_equal(20000, re_start(m, 1))
	assert_equal(20000, re_end(m, 1))
	re_result_free(m)
	re_free(p)
	p = re_compile(c"(a|a)*b", 0)
	assert1(re_search(p, as) == 0)
	m = re_match(p, asb)
	assert_equal(20001, re_end(m, 0))
	assert_equal(19999, re_start(m, 1))
	re_result_free(m)
	re_free(p)
	p = re_compile(c"(a+)+$x", 0)
	assert1(re_search(p, as) == 0)
	re_free(p)
	p = re_compile(c"(?:a?){30}a{30}", 0)
	char* a30 = re_test_repeat('a', 30, 0)
	m = re_fullmatch(p, a30)
	assert1(m != 0)
	re_result_free(m)
	re_free(p)
	free(a30)
	free(as)
	free(asb)


void test_deep_nesting():
	char* pat = cast(char*, malloc(2 * 500 + 2))
	for i in range(500):
		pat[i] = '('
		pat[500 + 1 + i] = ')'
	pat[500] = 'a'
	pat[1001] = 0
	re_pattern* p = re_compile(pat, 0)
	assert_strings_equal(c"pattern nested too deeply", re_error(p))
	re_free(p)
	free(pat)


void test_python_table():
	re_case(c"abc", 0, c"xxabcxx", 7, 's', c"2,5")
	re_case(c"abc", 0, c"abxabc", 6, 's', c"3,6")
	re_case(c"abc", 0, c"ab", 2, 's', c"none")
	re_case(c"", 0, c"abc", 3, 's', c"0,0")
	re_case(c"", 0, c"", 0, 'f', c"0,0")
	re_case(c"a", 0, c"", 0, 's', c"none")
	re_case(c"abc", 0, c"abcd", 4, 'm', c"0,3")
	re_case(c"abc", 0, c"xabc", 4, 'm', c"none")
	re_case(c"abc", 0, c"abcd", 4, 'f', c"none")
	re_case(c"abc", 0, c"abc", 3, 'f', c"0,3")
	re_case(c"a.c", 0, c"abc", 3, 's', c"0,3")
	re_case(c"a.c", 0, c"a\nc", 3, 's', c"none")
	re_case(c"a.c", 16, c"a\nc", 3, 's', c"0,3")
	re_case(c".", 0, c"\n", 1, 's', c"none")
	re_case(c"a|ab", 0, c"ab", 2, 'm', c"0,1")
	re_case(c"ab|a", 0, c"ab", 2, 'm', c"0,2")
	re_case(c"a|ab", 0, c"ab", 2, 'f', c"0,2")
	re_case(c"(a|ab)(c|bcd)", 0, c"abcd", 4, 's', c"0,4 0,1 1,4")
	re_case(c"x|y|z", 0, c"__z", 3, 's', c"2,3")
	re_case(c"|a", 0, c"a", 1, 'm', c"0,0")
	re_case(c"a|", 0, c"b", 1, 's', c"0,0")
	re_case(c"a*", 0, c"aaab", 4, 'm', c"0,3")
	re_case(c"a*?", 0, c"aaab", 4, 'm', c"0,0")
	re_case(c"a+", 0, c"baaa", 4, 's', c"1,4")
	re_case(c"a+?", 0, c"baaa", 4, 's', c"1,2")
	re_case(c"a?", 0, c"ab", 2, 'm', c"0,1")
	re_case(c"a??", 0, c"ab", 2, 'm', c"0,0")
	re_case(c"a*b", 0, c"xaaab", 5, 's', c"1,5")
	re_case(c"a*?b", 0, c"aaab", 4, 's', c"0,4")
	re_case(c"<.*>", 0, c"<a><b>", 6, 's', c"0,6")
	re_case(c"<.*?>", 0, c"<a><b>", 6, 's', c"0,3")
	re_case(c"(a+)(a*)", 0, c"aaaa", 4, 's', c"0,4 0,4 4,4")
	re_case(c"(a+?)(a*)", 0, c"aaaa", 4, 's', c"0,4 0,1 1,4")
	re_case(c"(a*)+", 0, c"b", 1, 'm', c"0,0 0,0")
	re_case(c"(a*)*", 0, c"b", 1, 'm', c"0,0 0,0")
	re_case(c"(a*)*", 0, c"aa", 2, 'm', c"0,2 2,2")
	re_case(c"(a|b)*", 0, c"abba", 4, 'm', c"0,4 3,4")
	re_case(c"(a|b)*?c", 0, c"abc", 3, 'm', c"0,3 1,2")
	re_case(c"(?:a|b)+", 0, c"xxabab", 6, 's', c"2,6")
	re_case(c"(a?)*", 0, c"aab", 3, 'm', c"0,2 2,2")
	re_case(c"a{3}", 0, c"aaaa", 4, 's', c"0,3")
	re_case(c"a{2,3}", 0, c"aaaa", 4, 's', c"0,3")
	re_case(c"a{2,3}?", 0, c"aaaa", 4, 's', c"0,2")
	re_case(c"a{2,}", 0, c"aaaaa", 5, 's', c"0,5")
	re_case(c"a{,2}", 0, c"aaa", 3, 'm', c"0,2")
	re_case(c"a{0}", 0, c"aaa", 3, 'm', c"0,0")
	re_case(c"(ab){2}", 0, c"abababx", 7, 's', c"0,4 2,4")
	re_case(c"a{3}", 0, c"aa", 2, 's', c"none")
	re_case(c"x{", 0, c"x{", 2, 's', c"0,2")
	re_case(c"x{a}", 0, c"x{a}", 4, 's', c"0,4")
	re_case(c"x{}", 0, c"x{}", 3, 's', c"0,3")
	re_case(c"x{1,2", 0, c"x{1,2", 5, 's', c"0,5")
	re_case(c"a{,}", 0, c"aaa", 3, 'm', c"0,3")
	re_case(c"(a{1,2}){2}", 0, c"aaa", 3, 'm', c"0,3 2,3")
	re_case(c"(?:a{2}){2,3}?", 0, c"aaaaaa", 6, 'm', c"0,4")
	re_case(c"(a)(b)?", 0, c"ac", 2, 's', c"0,1 0,1 -1,-1")
	re_case(c"(a)|(b)", 0, c"b", 1, 's', c"0,1 -1,-1 0,1")
	re_case(c"((a)b)c", 0, c"abc", 3, 's', c"0,3 0,2 0,1")
	re_case(c"(?:(a)|b)+", 0, c"ab", 2, 'm', c"0,2 0,1")
	re_case(c"(a)*", 0, c"aaa", 3, 'm', c"0,3 2,3")
	re_case(c"(a)*", 0, c"b", 1, 'm', c"0,0 -1,-1")
	re_case(c"()", 0, c"x", 1, 's', c"0,0 0,0")
	re_case(c"(?:)", 0, c"x", 1, 's', c"0,0")
	re_case(c"(x)(?:y)(z)", 0, c"xyz", 3, 's', c"0,3 0,1 2,3")
	re_case(c"[abc]+", 0, c"xxcabz", 6, 's', c"2,5")
	re_case(c"[a-c]+", 0, c"dcbae", 5, 's', c"1,4")
	re_case(c"[^a-c]+", 0, c"abxyzc", 6, 's', c"2,5")
	re_case(c"[]a]+", 0, c"]a]b", 4, 's', c"0,3")
	re_case(c"[^]a]+", 0, c"]xy", 3, 's', c"1,3")
	re_case(c"[a-]+", 0, c"-a-b", 4, 's', c"0,3")
	re_case(c"[-a]+", 0, c"-a-b", 4, 's', c"0,3")
	re_case(c"[\\]]", 0, c"x]", 2, 's', c"1,2")
	re_case(c"[\\d]+", 0, c"ab123c", 6, 's', c"2,5")
	re_case(c"[\\D]+", 0, c"12ab3", 5, 's', c"2,4")
	re_case(c"[\\w.]+", 0, c"  a.b_c ", 8, 's', c"2,7")
	re_case(c"[^\\s]+", 0, c"  ab  ", 6, 's', c"2,4")
	re_case(c"[\\s\\d]+", 0, c"a 1 2b", 6, 's', c"1,5")
	re_case(c"[\\W]+", 0, c"ab, cd", 6, 's', c"2,4")
	re_case(c"[\\b]", 0, c"a\x08\x62", 3, 's', c"1,2")
	re_case(c"[\\x41-\\x43]+", 0, c"zABCD", 5, 's', c"1,4")
	re_case(c"[.]", 0, c"a.b", 3, 's', c"1,2")
	re_case(c"[*+?{}()|^$]+", 0, c"a*+?{}()|^$b", 12, 's', c"1,11")
	re_case(c"[\\n]", 0, c"a\nb", 3, 's', c"1,2")
	re_case(c"[\\101]", 0, c"xA", 2, 's', c"1,2")
	re_case(c"\\d+", 0, c"abc123def", 9, 's', c"3,6")
	re_case(c"\\D+", 0, c"123abc", 6, 's', c"3,6")
	re_case(c"\\w+", 0, c"  foo_bar9 ", 11, 's', c"2,10")
	re_case(c"\\W+", 0, c"abc, def", 8, 's', c"3,5")
	re_case(c"\\s+", 0, c"a \t\n b", 6, 's', c"1,5")
	re_case(c"\\S+", 0, c"  ab  ", 6, 's', c"2,4")
	re_case(c"\\.", 0, c"a.b", 3, 's', c"1,2")
	re_case(c"a\\*", 0, c"aa*", 3, 's', c"1,3")
	re_case(c"\\(\\)", 0, c"f()", 3, 's', c"1,3")
	re_case(c"\\t", 0, c"a\tb", 3, 's', c"1,2")
	re_case(c"\\n", 0, c"a\nb", 3, 's', c"1,2")
	re_case(c"\\x41", 0, c"zA", 2, 's', c"1,2")
	re_case(c"\\u0041", 0, c"zA", 2, 's', c"1,2")
	re_case(c"\\U00000041", 0, c"zA", 2, 's', c"1,2")
	re_case(c"\\0", 0, c"a\x00\x62", 3, 's', c"1,2")
	re_case(c"\\101", 0, c"zA", 2, 's', c"1,2")
	re_case(c"\\\\", 0, c"a\\b", 3, 's', c"1,2")
	re_case(c"\\-", 0, c"a-b", 3, 's', c"1,2")
	re_case(c"\\#", 0, c"a#b", 3, 's', c"1,2")
	re_case(c"a\\|b", 0, c"a|b", 3, 's', c"0,3")
	re_case(c"^abc", 0, c"abc", 3, 's', c"0,3")
	re_case(c"^abc", 0, c"xabc", 4, 's', c"none")
	re_case(c"abc$", 0, c"xabc", 4, 's', c"1,4")
	re_case(c"abc$", 0, c"abc\n", 4, 's', c"0,3")
	re_case(c"abc$", 0, c"abc\n\n", 5, 's', c"none")
	re_case(c"abc\\Z", 0, c"abc\n", 4, 's', c"none")
	re_case(c"\\Aabc", 0, c"abc", 3, 's', c"0,3")
	re_case(c"^b", 0, c"a\nb", 3, 's', c"none")
	re_case(c"^b", 8, c"a\nb", 3, 's', c"2,3")
	re_case(c"a$", 8, c"a\nb", 3, 's', c"0,1")
	re_case(c"a$", 0, c"a\nb", 3, 's', c"none")
	re_case(c"^$", 8, c"a\n\nb", 4, 's', c"2,2")
	re_case(c"^", 8, c"\n", 1, 's', c"0,0")
	re_case(c"$", 0, c"a\n", 2, 's', c"1,1")
	re_case(c"a|^b", 0, c"cb", 2, 's', c"none")
	re_case(c"(^a|b)+", 0, c"abab", 4, 's', c"0,2 1,2")
	re_case(c"x^", 0, c"x", 1, 's', c"none")
	re_case(c"$x", 0, c"x", 1, 's', c"none")
	re_case(c"\\Ax|y", 8, c"a\ny", 3, 's', c"2,3")
	re_case(c"\\bfoo\\b", 0, c"a foo b", 7, 's', c"2,5")
	re_case(c"\\bfoo\\b", 0, c"afoo b", 6, 's', c"none")
	re_case(c"\\Boo\\B", 0, c"foo food", 8, 's', c"5,7")
	re_case(c"\\b", 0, c"", 0, 's', c"none")
	re_case(c"\\B", 0, c"", 0, 's', c"none")
	re_case(c"\\b", 0, c"  ", 2, 's', c"none")
	re_case(c"\\B", 0, c"ab", 2, 's', c"1,1")
	re_case(c"\\w+\\b", 0, c"ab cd", 5, 's', c"0,2")
	re_case(c"o\\b", 0, c"foo", 3, 's', c"2,3")
	re_case(c"abc", 2, c"xABCx", 5, 's', c"1,4")
	re_case(c"[a-c]+", 2, c"xABCx", 5, 's', c"1,4")
	re_case(c"[^a-c]+", 2, c"ABCxyz", 6, 's', c"3,6")
	re_case(c"[A-Z]+", 2, c"abc", 3, 's', c"0,3")
	re_case(c"Hello", 2, c"hELLO", 5, 'f', c"0,5")
	re_case(c"(?i)abc", 0, c"ABC", 3, 'm', c"0,3")
	re_case(c"a(?i:b)c", 0, c"aBc", 3, 'm', c"0,3")
	re_case(c"a(?i:b)c", 0, c"aBC", 3, 'm', c"none")
	re_case(c"(?i:a(?-i:b)c)", 0, c"AbC", 3, 'm', c"0,3")
	re_case(c"(?i:a(?-i:b)c)", 0, c"ABC", 3, 'm', c"none")
	re_case(c"\\w+", 2, c"AbC", 3, 'm', c"0,3")
	re_case(c"[_-z]+", 2, c"_aZ", 3, 'm', c"0,3")
	re_case(c"(?m)^b", 0, c"a\nb", 3, 's', c"2,3")
	re_case(c"(?s).+", 0, c"a\nb", 3, 'm', c"0,3")
	re_case(c"(?s:.)", 0, c"\n", 1, 'm', c"0,1")
	re_case(c"(?im)^B$", 0, c"a\nb\n", 4, 's', c"2,3")
	re_case(c"(?x) a b  c # comment", 0, c"abc", 3, 'm', c"0,3")
	re_case(c"a b", 64, c"ab", 2, 'm', c"0,2")
	re_case(c"[ ]", 64, c"a b", 3, 's', c"1,2")
	re_case(c"a\\ b", 64, c"a b", 3, 'm', c"0,3")
	re_case(c"(?x)a *", 0, c"aaa", 3, 'm', c"0,3")
	re_case(c"(?#comment)ab", 0, c"ab", 2, 'm', c"0,2")
	re_case(c"(?a)\\w", 0, c"x", 1, 'm', c"0,1")
	re_case(c"\xc3\xa9", 0, c"caf\xc3\xa9", 5, 's', c"3,5")
	re_case(c"\xc3\xa9+", 0, c"\xc3\xa9\xc3\xa9\xc3\xa9x", 7, 'm', c"0,6")
	re_case(c".", 0, c"\xc3\xa9", 2, 'm', c"0,2")
	re_case(c"..", 0, c"\xc3\xa9", 2, 'm', c"none")
	re_case(c"^.$", 0, c"\xe2\x82\xac", 3, 's', c"0,3")
	re_case(c"caf.", 0, c"caf\xc3\xa9!", 6, 's', c"0,5")
	re_case(c"[\xc3\xa9\xe2\x82\xac]+", 0, c"x\xc3\xa9\xe2\x82\xac\xc3\xa9", 8, 's', c"1,8")
	re_case(c"[^a]", 0, c"\xc3\xa9", 2, 'm', c"0,2")
	re_case(c"[\xce\xb1-\xcf\x89]+", 0, c"x\xce\xb1\xce\xb2\xce\xb3x", 8, 's', c"1,7")
	re_case(c"\\W", 0, c"\xc3\xa9", 2, 'm', c"0,2")
	re_case(c"[^\xc3\xa9]+", 0, c"\xf0\x9f\x98\x80\xc3\xa9", 6, 's', c"0,4")
	re_case(c".+", 0, c"a\xf0\x9f\x98\x80\x62", 6, 'm', c"0,6")
	re_case(c"\\u00e9", 0, c"caf\xc3\xa9", 5, 's', c"3,5")
	re_case(c"[\\u0100-\\U0010ffff]+", 0, c"a\xc4\x80\xf0\x9f\x98\x80\x62", 8, 's', c"1,7")
	re_case(c"[^\\x00-\\x7f]+", 0, c"ab\xf0\x9f\x92\xa1\xe1\xba\x9e\x63", 10, 's', c"2,9")
	re_case(c"(.)(.)", 0, c"\xf0\x9f\x98\x80x", 5, 'm', c"0,5 0,4 4,5")
	re_case(c"a*", 0, c"aaa", 3, 'f', c"0,3")
	re_case(c"a*?", 0, c"aaa", 3, 'f', c"0,3")
	re_case(c"a|ab|abc", 0, c"abc", 3, 'f', c"0,3")
	re_case(c"(a|ab)(c|bcd)", 0, c"abcd", 4, 'f', c"0,4 0,1 1,4")
	re_case(c"a", 0, c"ab", 2, 'f', c"none")
	re_case(c"a+?b", 0, c"aab", 3, 'f', c"0,3")
	re_case(c"abc$", 0, c"abc", 3, 'f', c"0,3")
	re_case(c"(a)b(c)", 0, c"abc", 3, 'm', c"0,3 0,1 2,3")
	re_case(c"a.+?c", 0, c"abcabc", 6, 'm', c"0,3")
	re_case(c"(?:ab)*c", 0, c"ababc", 5, 's', c"0,5")
	re_case(c"(a|b|c|d|e)f", 0, c"ef", 2, 'm', c"0,2 0,1")
	re_case(c"((((((((((a))))))))))", 0, c"a", 1, 'm', c"0,1 0,1 0,1 0,1 0,1 0,1 0,1 0,1 0,1 0,1 0,1")
	re_case(c"(.*)c(.*)", 0, c"abcde", 5, 'm', c"0,5 0,2 3,5")
	re_case(c"\\((.*), (.*)\\)", 0, c"(a, b)", 6, 'm', c"0,6 1,2 4,5")
	re_case(c"[k]", 0, c"ab", 2, 's', c"none")
	re_case(c"a[-]?c", 0, c"ac", 2, 'm', c"0,2")
	re_case(c"(abc)\\w+", 0, c"abcabc", 6, 'm', c"0,6 0,3")
	re_case(c"([abc])*d", 0, c"abbbcd", 6, 'm', c"0,6 4,5")
	re_case(c"([abc])*bcd", 0, c"abcd", 4, 'm', c"0,4 0,1")
	re_case(c"a|b|c|d|e", 0, c"e", 1, 'm', c"0,1")
	re_case(c"(bc+d$|ef*g.|h?i(j|k))", 0, c"effgz", 5, 'm', c"0,5 0,5 -1,-1")
	re_case(c"(bc+d$|ef*g.|h?i(j|k))", 0, c"ij", 2, 'm', c"0,2 0,2 1,2")
	re_case(c"(bc+d$|ef*g.|h?i(j|k))", 0, c"reffgz", 6, 's', c"1,6 1,6 -1,-1")
	re_case(c"((a)|b)*", 0, c"ab", 2, 'm', c"0,2 1,2 0,1")
	re_case(c"(a+|b)*", 0, c"ab", 2, 'm', c"0,2 1,2")
	re_case(c"(a+|b){0,}", 0, c"ab", 2, 'm', c"0,2 1,2")
	re_case(c"(a+|b)+", 0, c"ab", 2, 'm', c"0,2 1,2")
	re_case(c"(a+|b){1,}", 0, c"ab", 2, 'm', c"0,2 1,2")
	re_case(c"(a+|b)?", 0, c"ab", 2, 'm', c"0,1 0,1")
	re_case(c"(a+|b){0,1}", 0, c"ab", 2, 'm', c"0,1 0,1")
	re_case(c"[^ab]*", 0, c"cde", 3, 'm', c"0,3")
	re_case(c"a*", 0, c"", 0, 'm', c"0,0")
	re_case(c"([abc]|d)e", 0, c"abcde", 5, 's', c"3,5 3,4")
	re_case(c"(a|b)c*d", 0, c"abcd", 4, 's', c"1,4 1,2")
	re_case(c"(ab|abc)*", 0, c"abcabab", 7, 'm', c"0,2 0,2")
	re_case(c"(a*)(b*)(c*)", 0, c"aacc", 4, 'm', c"0,4 0,2 2,2 2,4")
	re_case(c"(x?)*", 0, c"xxy", 3, 'm', c"0,2 2,2")
	re_case(c"(x?)+?y", 0, c"xxy", 3, 'm', c"0,3 1,2")
	re_case(c"(?:x*)*y", 0, c"xxy", 3, 'm', c"0,3")
	re_case(c"(|a)+", 0, c"aa", 2, 'm', c"0,0 0,0")
	re_case(c"(a|)+", 0, c"aa", 2, 'm', c"0,2 2,2")
	re_case(c"(a|)*b", 0, c"aab", 3, 'm', c"0,3 2,2")
	re_case(c"(?:a?)*?b", 0, c"aab", 3, 'm', c"0,3")
	re_case(c"(a*?)*", 0, c"aa", 2, 'm', c"0,0 0,0")


void test_search_from_pos():
	re_case_at(c"^a", 0, c"aa", 1, 's', c"none")
	re_case_at(c"^a", 0, c"aa", 1, 'm', c"none")
	re_case_at(c"^a", 0, c"aa", 1, 'f', c"none")
	re_case_at(c"\\ba", 0, c"aa a", 1, 's', c"3,4")
	re_case_at(c"\\ba", 0, c"aa a", 1, 'm', c"none")
	re_case_at(c"\\ba", 0, c"aa a", 1, 'f', c"none")
	re_case_at(c"a", 0, c"aaa", 3, 's', c"none")
	re_case_at(c"a", 0, c"aaa", 3, 'm', c"none")
	re_case_at(c"a", 0, c"aaa", 3, 'f', c"none")
	re_case_at(c"", 0, c"ab", 2, 's', c"2,2")
	re_case_at(c"", 0, c"ab", 2, 'm', c"2,2")
	re_case_at(c"", 0, c"ab", 2, 'f', c"2,2")
	re_case_at(c"^b", 8, c"a\nb", 1, 's', c"2,3")
	re_case_at(c"^b", 8, c"a\nb", 1, 'm', c"none")
	re_case_at(c"^b", 8, c"a\nb", 1, 'f', c"none")
	re_case_at(c"^b", 8, c"a\nb", 2, 's', c"2,3")
	re_case_at(c"^b", 8, c"a\nb", 2, 'm', c"2,3")
	re_case_at(c"^b", 8, c"a\nb", 2, 'f', c"2,3")
	re_case_at(c"$", 0, c"ab", 1, 's', c"2,2")
	re_case_at(c"$", 0, c"ab", 1, 'm', c"none")
	re_case_at(c"$", 0, c"ab", 1, 'f', c"none")
	re_case_at(c"\\Bb", 0, c"ab", 1, 's', c"1,2")
	re_case_at(c"\\Bb", 0, c"ab", 1, 'm', c"1,2")
	re_case_at(c"\\Bb", 0, c"ab", 1, 'f', c"1,2")
	re_case_at(c"x*", 0, c"axx", 1, 's', c"1,3")
	re_case_at(c"x*", 0, c"axx", 1, 'm', c"1,3")
	re_case_at(c"x*", 0, c"axx", 1, 'f', c"1,3")
	re_case_at(c"b+", 0, c"abbcbb", 3, 's', c"4,6")
	re_case_at(c"b+", 0, c"abbcbb", 3, 'm', c"none")
	re_case_at(c"b+", 0, c"abbcbb", 3, 'f', c"none")


# Patterns CPython rejects, mixed with features this engine rejects on purpose
# (backreferences, named groups, lookaround, possessive, atomic, \N).
void test_syntax_errors():
	re_error_case(c"(")
	re_error_case(c")")
	re_error_case(c"a)")
	re_error_case(c"(?:a")
	re_error_case(c"[a")
	re_error_case(c"[z-a]")
	re_error_case(c"*a")
	re_error_case(c"a**")
	re_error_case(c"a{2}{3}")
	re_error_case(c"+")
	re_error_case(c"?")
	re_error_case(c"{1}")
	re_error_case(c"a{3,2}")
	re_error_case(c"\\")
	re_error_case(c"\\q")
	re_error_case(c"\\1")
	re_error_case(c"(a)\\1")
	re_error_case(c"(?P<n>a)")
	re_error_case(c"(?=a)")
	re_error_case(c"(?!a)")
	re_error_case(c"(?<=a)")
	re_error_case(c"(?<!a)")
	re_error_case(c"a*+")
	re_error_case(c"a++")
	re_error_case(c"(?L)a")
	re_error_case(c"^*")
	re_error_case(c"\\b+")
	re_error_case(c"[\\d-z]")
	re_error_case(c"\\x4")
	re_error_case(c"(?#abc")
	re_error_case(c"a(?i)b")
	re_error_case(c"(?z)")
	re_error_case(c"\\N{DIGIT ONE}")
	re_error_case(c"(?>a)")
