# wbuild: x64
/*
lib/regex.w: the reusable backtracking pattern matcher (the core
shell-mode grep from issue #335 and future find/sed consume).

Covers: literal and whole-text match semantics, `.` (never newline),
character classes with ranges, negation, literal `]`/`-` positions and
in-class escapes, backslash escapes (metacharacters plus \t \n \r,
reserved alphanumeric escapes rejected), `^`/`$` anchors at their
anchor positions and as literals elsewhere, each greedy quantifier,
greedy span lengths via regex_match_length, leftmost search including
empty matches, empty pattern/text edges, high (non-ASCII) bytes
matched byte-wise, malformed patterns (unclosed class, dangling
quantifier, trailing backslash, out-of-order range) failing cleanly
from every entry point, the backtracking step budget giving up quickly
on pathological patterns, and a grep-shaped loop over the lines of a
real repo file (this test's own source, so wtest already tracks the
data dependency).
*/
import lib.testing
import lib.lib
import lib.regex
import lib.file


void test_literal_match():
	assert_equal(1, regex_match(c"abc", c"abc"))
	assert_equal(0, regex_match(c"abc", c"abd"))
	assert_equal(0, regex_match(c"abc", c"ab"))
	# regex_match is whole-text: a prefix match is not enough
	assert_equal(0, regex_match(c"ab", c"abc"))
	# unsupported metacharacters are ordinary literals
	assert_equal(1, regex_match(c"(){}|", c"(){}|"))


void test_dot():
	assert_equal(1, regex_match(c"a.c", c"abc"))
	assert_equal(1, regex_match(c"a.c", c"a.c"))
	assert_equal(0, regex_match(c"a.c", c"ac"))
	# . matches any byte except newline
	assert_equal(0, regex_match(c"a.c", c"a\nc"))
	assert_equal(0, regex_match(c".", c""))
	assert_equal(1, regex_match(c"...", c"abc"))


void test_classes():
	assert_equal(1, regex_match(c"[abc]", c"a"))
	assert_equal(1, regex_match(c"[abc]", c"c"))
	assert_equal(0, regex_match(c"[abc]", c"d"))
	assert_equal(1, regex_match(c"[a-z]*", c"hello"))
	assert_equal(0, regex_match(c"[a-z]", c"A"))
	assert_equal(1, regex_match(c"[A-Za-z0-9_]*", c"Mixed_Case_123"))


void test_class_negation():
	assert_equal(1, regex_match(c"[^abc]", c"d"))
	assert_equal(0, regex_match(c"[^abc]", c"a"))
	assert_equal(0, regex_match(c"[^a-z]", c"q"))
	# a negated class matches newline (only . refuses it)
	assert_equal(1, regex_match(c"[^a]", c"\n"))


void test_class_literal_positions():
	# ] first in the class body is a literal member
	assert_equal(1, regex_match(c"[]a]", c"]"))
	assert_equal(1, regex_match(c"[]a]", c"a"))
	assert_equal(0, regex_match(c"[]a]", c"b"))
	# - first or last in the body is a literal member
	assert_equal(1, regex_match(c"[-a]", c"-"))
	assert_equal(1, regex_match(c"[a-]", c"-"))
	assert_equal(0, regex_match(c"[a-]", c"b"))


void test_class_escapes():
	assert_equal(1, regex_match(c"[\\t ]", c"\t"))
	assert_equal(1, regex_match(c"[\\t ]", c" "))
	assert_equal(1, regex_match(c"[\\]]", c"]"))
	assert_equal(0, regex_match(c"[\\]]", c"a"))
	assert_equal(1, regex_match(c"[\\\\]", c"\\"))


void test_escapes():
	assert_equal(1, regex_match(c"a\\.c", c"a.c"))
	assert_equal(0, regex_match(c"a\\.c", c"abc"))
	assert_equal(1, regex_match(c"\\\\", c"\\"))
	assert_equal(1, regex_match(c"\\[a\\]", c"[a]"))
	assert_equal(1, regex_match(c"\\*\\+\\?", c"*+?"))
	assert_equal(1, regex_match(c"\\t", c"\t"))
	assert_equal(1, regex_match(c"a\\nb", c"a\nb"))


void test_anchors():
	assert_equal(0, regex_search(c"^ab", c"abx"))
	assert_equal(-1, regex_search(c"^ab", c"xab"))
	assert_equal(1, regex_search(c"ab$", c"xab"))
	assert_equal(-1, regex_search(c"ab$", c"abx"))
	assert_equal(1, regex_match(c"^abc$", c"abc"))
	assert_equal(0, regex_match(c"^abc$", c"abcd"))
	# ^ and $ away from their anchor positions are literals
	assert_equal(1, regex_match(c"a^b", c"a^b"))
	assert_equal(1, regex_match(c"a$b", c"a$b"))
	# $ alone matches the empty string at end of text
	assert_equal(3, regex_search(c"$", c"abc"))
	assert_equal(1, regex_match(c"^$", c""))
	assert_equal(0, regex_match(c"^$", c"a"))


void test_star():
	assert_equal(1, regex_match(c"ab*c", c"ac"))
	assert_equal(1, regex_match(c"ab*c", c"abc"))
	assert_equal(1, regex_match(c"ab*c", c"abbbbc"))
	assert_equal(0, regex_match(c"ab*c", c"abxc"))
	assert_equal(1, regex_match(c"a*", c""))
	assert_equal(1, regex_match(c"a*", c"aaaa"))
	assert_equal(0, regex_match(c"a*", c"aab"))


void test_plus():
	assert_equal(0, regex_match(c"ab+c", c"ac"))
	assert_equal(1, regex_match(c"ab+c", c"abc"))
	assert_equal(1, regex_match(c"ab+c", c"abbbc"))
	assert_equal(0, regex_match(c"a+", c""))
	assert_equal(1, regex_match(c"[0-9]+", c"12345"))
	assert_equal(0, regex_match(c"[0-9]+", c"12a45"))


void test_question():
	assert_equal(1, regex_match(c"ab?c", c"ac"))
	assert_equal(1, regex_match(c"ab?c", c"abc"))
	assert_equal(0, regex_match(c"ab?c", c"abbc"))
	assert_equal(1, regex_match(c"colou?r", c"color"))
	assert_equal(1, regex_match(c"colou?r", c"colour"))


void test_quantified_elements():
	assert_equal(1, regex_match(c"[ab]+", c"abba"))
	assert_equal(1, regex_match(c".*", c"anything at all"))
	assert_equal(1, regex_match(c"\\.*", c"..."))
	assert_equal(0, regex_match(c"\\.*", c"a"))


void test_greedy_lengths():
	assert_equal(3, regex_match_length(c"a*", c"aaab", 0))
	# greedy .* backtracks just enough: the whole "abab" is taken
	assert_equal(4, regex_match_length(c".*b", c"abab", 0))
	assert_equal(1, regex_match_length(c"a?", c"aa", 0))
	# empty match has length 0, distinct from no-match -1
	assert_equal(0, regex_match_length(c"b*", c"ab", 0))
	assert_equal(0, regex_search(c"b*", c"ab"))


void test_search():
	assert_equal(2, regex_search(c"cd", c"abcdef"))
	# leftmost match wins
	assert_equal(0, regex_search(c"ab", c"abab"))
	assert_equal(-1, regex_search(c"xy", c"abcdef"))
	assert_equal(4, regex_search(c"e.", c"abcdef"))
	assert_equal(-1, regex_search(c"a", c""))
	assert_equal(0, regex_search(c"", c"abc"))
	assert_equal(0, regex_search(c"", c""))


void test_match_length_positions():
	assert_equal(3, regex_match_length(c"abc", c"abcdef", 0))
	assert_equal(-1, regex_match_length(c"abc", c"abcdef", 1))
	assert_equal(2, regex_match_length(c"cd", c"abcdef", 2))
	# an anchored pattern only matches at start 0
	assert_equal(-1, regex_match_length(c"^ab", c"xab", 1))
	assert_equal(2, regex_match_length(c"^ab", c"abx", 0))


void test_empty_edges():
	assert_equal(1, regex_match(c"", c""))
	assert_equal(0, regex_match(c"", c"a"))
	assert_equal(0, regex_match(c"a", c""))
	assert_equal(1, regex_match(c"a*b*", c""))
	assert_equal(0, regex_match_length(c"", c"abc", 0))
	# start may sit exactly at the terminator, but not past it
	assert_equal(0, regex_match_length(c"", c"abc", 3))
	assert_equal(-1, regex_match_length(c"", c"abc", 4))
	assert_equal(-1, regex_match_length(c"a", c"abc", -1))


void test_high_bytes_match_bytewise():
	# 0xc3 0xa9: UTF-8 e-acute. Matching is byte-oriented, so it is
	# two "any byte" elements, and high bytes work in negated classes.
	char* buf = malloc(3)
	buf[0] = 195
	buf[1] = 169
	buf[2] = 0
	assert_equal(0, regex_match(c".", buf))
	assert_equal(1, regex_match(c"..", buf))
	assert_equal(1, regex_match(c"[^a][^a]", buf))
	free(buf)


void test_malformed_patterns():
	assert_equal(0, regex_valid(c"[abc"))
	assert_equal(0, regex_valid(c"*a"))
	assert_equal(0, regex_valid(c"+a"))
	assert_equal(0, regex_valid(c"?"))
	assert_equal(0, regex_valid(c"a**"))
	assert_equal(0, regex_valid(c"^*"))
	assert_equal(0, regex_valid(c"\\"))
	# alphanumeric escapes are reserved, not literals
	assert_equal(0, regex_valid(c"\\d"))
	assert_equal(0, regex_valid(c"[z-a]"))
	assert_equal(0, regex_valid(c"[a-\\d]"))
	# every entry point reports plain no-match for malformed patterns
	assert_equal(0, regex_match(c"[abc", c"a"))
	assert_equal(-1, regex_search(c"*a", c"aaa"))
	assert_equal(-1, regex_match_length(c"a[", c"a[", 0))
	# and well-formed patterns validate
	assert_equal(1, regex_valid(c""))
	assert_equal(1, regex_valid(c"a*b+c?"))
	assert_equal(1, regex_valid(c"[a-z][^0-9]"))
	assert_equal(1, regex_valid(c"^a\\.b$"))


void test_pathological_backtracking_finishes():
	# The classic blowup shape: without a guard this backtracks
	# exponentially. Small enough to finish inside the budget, so the
	# answer is a genuine no-match.
	assert_equal(0, regex_match(c"a*a*a*a*b", c"aaaaaaaaaaaaaaaaaaaa"))
	assert_equal(-1, regex_search(c"a*a*a*a*b", c"aaaaaaaaaaaaaaaaaaaa"))


void test_step_budget_gives_up_cleanly():
	# Nine stacked stars over 40 a's: far past RX_STEP_BUDGET, so the
	# matcher must abort via the budget and still report plain
	# no-match, quickly.
	char* runs = c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	assert_equal(0, regex_match(c"a*a*a*a*a*a*a*a*a*b", runs))


void test_grep_loop_over_own_source():
	# A grep-shaped loop over a real repo file: this test's own
	# source, so the data dependency is already tracked by wtest.
	list[char*] lines = file_read_lines(c"tests/regex_test.w")
	asserts(c"read tests/regex_test.w", lines.length > 50)
	int matches = 0
	int i = 0
	while (i < lines.length):
		char* line = lines[i]
		int at = regex_search(c"^void test_[a-z0-9_]*(", line)
		if (at >= 0):
			assert_equal(0, at)
			int length = regex_match_length(c"^void test_[a-z0-9_]*(", line, at)
			asserts(c"span covers at least 'void test_('", length >= 11)
			matches = matches + 1
		asserts(c"absent pattern matches nothing", regex_search(c"^zzzz_never_here$", line) == -1)
		i = i + 1
	asserts(c"found the test_* definitions", matches >= 15)
