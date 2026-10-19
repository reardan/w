# wbuild: x64
# wbuild: step="bin/regex_engine_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
/*
lib/regex.w on top of libs/standard/text/re.w (stdlib parity plan
P1.1c). tests/regex_test.w pins the old matcher's semantics and stays
unchanged; this file covers what the port adds: re.w's RE_BYTES flag
(expected spans from CPython 3.13 `re` over bytes patterns), the
translation keeping lib/regex.w's own syntax (`( ) | { }` literals, `$`
only at the very end of the text) and answers the old step budget used
to get wrong on pathological patterns.
*/
import lib.testing
import lib.lib
import lib.regex
import libs.standard.text.re


# A NUL-terminated copy of the given bytes (pass -1 to end the list).
char* bytes_of(int b0, int b1, int b2, int b3, int b4, int b5):
	char* out = cast(char*, malloc(7))
	int[6] v
	v[0] = b0
	v[1] = b1
	v[2] = b2
	v[3] = b3
	v[4] = b4
	v[5] = b5
	int n = 0
	while ((n < 6) && (v[n] >= 0)):
		out[n] = v[n]
		n = n + 1
	out[n] = 0
	return out


# "start,end" of re_search(pattern, text, flags), "none" or "error".
void assert_byte_span(char* pattern, int flags, char* text, int start, int end):
	re_pattern* p = re_compile(pattern, flags)
	asserts(pattern, re_error(p) == 0)
	re_result* m = re_search(p, text)
	if (start < 0):
		asserts(pattern, m == 0)
	else:
		asserts(pattern, m != 0)
		if (m != 0):
			assert_equal(start, re_start(m, 0))
			assert_equal(end, re_end(m, 0))
	re_result_free(m)
	re_free(p)


void test_re_bytes_dot_and_classes():
	# CPython: re.fullmatch(b'.', b'\xc3') matches; b'\xc3\xa9' needs two.
	char* lone = bytes_of(195, -1, 0, 0, 0, 0)
	char* eacute = bytes_of(195, 169, -1, 0, 0, 0)
	assert_byte_span(c"^.$", RE_BYTES, lone, 0, 1)
	assert_byte_span(c"^.$", RE_BYTES, eacute, -1, -1)
	assert_byte_span(c"^..$", RE_BYTES, eacute, 0, 2)
	# Without RE_BYTES the same text is one UTF-8 character.
	assert_byte_span(c"^.$", 0, eacute, 0, 2)
	# re.search(b'[\x80-\xff]+', b'ab\xc3\xa9c').span() == (2, 4)
	char* mixed = bytes_of('a', 'b', 195, 169, 'c', -1)
	assert_byte_span(c"[\\x80-\\xff]+", RE_BYTES, mixed, 2, 4)
	# re.search(b'[^a-z]+', b'ab\xff\n!c').span() == (2, 5)
	char* neg = bytes_of('a', 'b', 255, 10, '!', 'c')
	assert_byte_span(c"[^a-z]+", RE_BYTES, neg, 2, 5)
	# re.search(b'(?s).+', b'\xff\n').span() == (0, 2)
	char* dotall = bytes_of(255, 10, -1, 0, 0, 0)
	assert_byte_span(c"(?s).+", RE_BYTES, dotall, 0, 2)
	assert_byte_span(c".+", RE_BYTES, dotall, 0, 1)
	# re.search(b'[\\D]+', b'1\xfe\xff2').span() == (1, 3)
	char* digits = bytes_of('1', 254, 255, '2', -1, 0)
	assert_byte_span(c"[\\D]+", RE_BYTES, digits, 1, 3)
	# re.search(b'\\W+', b'a\xe9\xe8b').span() == (1, 3)
	char* word = bytes_of('a', 233, 232, 'b', -1, 0)
	assert_byte_span(c"\\W+", RE_BYTES, word, 1, 3)
	# re.search(b'(?i)\xc9', b'\xe9') is None: case folding is ASCII only.
	char* upper = bytes_of(201, -1, 0, 0, 0, 0)
	char* lower = bytes_of(233, -1, 0, 0, 0, 0)
	assert_byte_span(upper, RE_BYTES | RE_IGNORECASE, lower, -1, -1)
	assert_byte_span(upper, RE_BYTES, upper, 0, 1)
	# A raw (invalid UTF-8) byte in a byte pattern is a literal, and \xhh
	# names one byte.
	assert_byte_span(lone, RE_BYTES, eacute, 0, 1)
	assert_byte_span(c"\\xa9", RE_BYTES, eacute, 1, 2)
	free(lone)
	free(eacute)
	free(mixed)
	free(neg)
	free(dotall)
	free(digits)
	free(word)
	free(upper)
	free(lower)


void test_re_bytes_errors():
	# Python byte patterns reject \u and \U; UTF-8 patterns reject a
	# lone continuation byte that RE_BYTES accepts.
	re_pattern* p = re_compile(c"\\u00e9", RE_BYTES)
	asserts(c"\\u in a byte pattern", re_error(p) != 0)
	re_free(p)
	p = re_compile(c"\\U000000e9", RE_BYTES)
	asserts(c"\\U in a byte pattern", re_error(p) != 0)
	re_free(p)
	p = re_compile(c"\\u00e9", 0)
	asserts(c"\\u in a text pattern", re_error(p) == 0)
	re_free(p)
	char* lone = bytes_of(169, -1, 0, 0, 0, 0)
	p = re_compile(lone, 0)
	asserts(c"invalid UTF-8 text pattern", re_error(p) != 0)
	re_free(p)
	p = re_compile(lone, RE_BYTES)
	asserts(c"raw byte pattern", re_error(p) == 0)
	re_free(p)
	free(lone)


void test_translation_keeps_old_syntax():
	# Python metacharacters the old syntax treats as literals.
	assert_equal(1, regex_match(c"a|b", c"a|b"))
	assert_equal(0, regex_match(c"a|b", c"a"))
	assert_equal(1, regex_match(c"x{2}", c"x{2}"))
	assert_equal(0, regex_match(c"x{2}", c"xx"))
	assert_equal(1, regex_match(c"(a)+", c"(a)))"))
	assert_equal(0, regex_match(c"(?:a)", c"a"))
	# `$` is end of text only, never "before a trailing newline" as in
	# Python, and `^` / `$` away from the ends are literals.
	assert_equal(-1, regex_search(c"a$", c"a\n"))
	assert_equal(0, regex_search(c"a$", c"a"))
	assert_equal(1, regex_search(c"a^b$", c"xa^b"))
	assert_equal(2, regex_search(c"b$c", c"abb$c"))
	assert_equal(-1, regex_search(c"^b", c"ab"))
	# Classes: `]` first, `-` first/last, escapes as range endpoints.
	assert_equal(4, regex_match_length(c"[]a-]+", c"]-a]x", 0))
	assert_equal(2, regex_match_length(c"[\\t-\\n]*", c"\t\nx", 0))
	assert_equal(1, regex_match(c"[^]]", c"x"))
	assert_equal(0, regex_match(c"[^]]", c"]"))
	assert_equal(1, regex_match(c"\\.\\(\\[", c".(["))
	# Greedy, backtracking-order spans.
	assert_equal(2, regex_match_length(c"a?ab", c"ab", 0))
	assert_equal(5, regex_match_length(c"a*ab*", c"aaabb", 0))
	assert_equal(3, regex_search(c"b+c", c"aaabbc"))
	# A match that starts mid-text through regex_match_length.
	assert_equal(2, regex_match_length(c"b+", c"abbc", 1))
	assert_equal(-1, regex_match_length(c"^b", c"abbc", 1))


void test_pathological_patterns_get_the_right_answer():
	# The old backtracker's step budget answered -1 here; the Pike VM
	# finds the b after the run of a's.
	int n = 3000
	char* text = cast(char*, malloc(n + 3))
	for i in range(n): text[i] = 'a'
	text[n] = 'x'
	text[n + 1] = 'b'
	text[n + 2] = 0
	assert_equal(n + 1, regex_search(c"a*a*a*a*a*a*a*a*a*b", text))
	assert_equal(1, regex_match_length(c"a*a*a*a*a*a*a*a*a*b", text, n + 1))
	text[n] = 'b'
	text[n + 1] = 0
	assert_equal(n + 1, regex_match_length(c"a*a*a*a*a*a*a*a*a*b", text, 0))
	assert_equal(1, regex_match(c"a*a*a*a*a*a*a*a*a*b", text))
	text[n] = 0
	assert_equal(0, regex_match(c"a*a*a*a*a*a*a*a*a*b", text))
	free(text)
