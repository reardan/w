# Unit tests for the did-you-mean suggester behind the '= help' line of
# compile diagnostics (compiler/diagnostics.w, #377), plus a check that
# 'w check --json' carries the suggestion as the optional "help" field.
# wbuild: x64
# The env steps pin the terminal colors: FORCE_COLOR turns them on for
# a pipe, and NO_COLOR wins over it (https://no-color.org).
# wbuild: step="env FORCE_COLOR=1 bin/wv2 tests/did_you_mean_symbol_fixture.w -o bin/did_you_mean_color" expect_fail expect_stderr="[1;31merror"
# wbuild: step="env NO_COLOR=1 FORCE_COLOR=1 bin/wv2 tests/did_you_mean_symbol_fixture.w -o bin/did_you_mean_color" expect_fail reject_stderr="[1;31m"
# wbuild: step="bin/wv2 check --json tests/did_you_mean_symbol_fixture.w" expect_fail expect_stdout="did you mean 'counter'?"
import lib.testing
import compiler.diagnostics


char* suggest(char* name, char* a, char* b, char* c):
	diag_suggest_begin(name)
	diag_suggest_consider(a)
	diag_suggest_consider(b)
	diag_suggest_consider(c)
	char* got = 0
	if (diag_suggest_finish()):
		got = strclone(diag_help_text)
	diag_clear_help()
	return got


void test_edit_distance():
	diag_suggest_begin(c"x")
	assert_equal(0, diag_edit_distance(c"abc", 3, c"abc", 3))
	assert_equal(1, diag_edit_distance(c"countr", 6, c"counter", 7))
	# an adjacent transposition is one edit, not two
	assert_equal(1, diag_edit_distance(c"lenght", 6, c"length", 6))
	# case-only differences are the closest match of all
	assert_equal(0, diag_edit_distance(c"Vector", 6, c"vector", 6))
	assert_equal(3, diag_edit_distance(c"kitten", 6, c"sitting", 7))
	diag_suggest_finish()


void test_suggests_closest_name():
	assert_strings_equal(c"did you mean 'counter'?", suggest(c"countr", c"count_max", c"counter", c"cursor"))


void test_first_candidate_wins_ties():
	assert_strings_equal(c"did you mean 'ab'?", suggest(c"a", c"ab", c"ac", c"b"))


void test_no_suggestion_past_the_edit_budget():
	assert1(suggest(c"qqqzzzx", c"counter", c"main", c"q") == 0)
	# the exact name is never suggested for itself
	assert1(suggest(c"main", c"main", c"zzzz", c"yyyy") == 0)


void test_internal_names_are_skipped():
	assert1(suggest(c"w_list", c"__w_list", c"zzzz", c"yyyy") == 0)
	assert_strings_equal(c"did you mean '__w_list'?", suggest(c"__w_lsit", c"__w_list", c"zzzz", c"yyyy"))
