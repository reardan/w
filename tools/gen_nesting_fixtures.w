# wbuild: target=nesting_fixtures dep=wv2 input=tools/gen_nesting_fixtures.w output=bin/statement_nesting_error_fixture.w output=bin/statement_nesting_clean_fixture.w output=bin/deep_nesting_test.w
# wbuild: step="bin/wv2 tools/gen_nesting_fixtures.w -o bin/gen_nesting_fixtures"
# wbuild: step="bin/gen_nesting_fixtures bin"
# wbuild: target=deep_nesting_test tag=tests dep=nesting_fixtures input=bin/deep_nesting_test.w output=bin/deep_nesting_test
# wbuild: step="bin/wv2 bin/deep_nesting_test.w -o bin/deep_nesting_test"
# wbuild: step="bin/deep_nesting_test"
# wbuild: target=deep_nesting_64_test tag=tests_x64 dep=nesting_fixtures input=bin/deep_nesting_test.w output=bin/deep_nesting_64_test
# wbuild: step="bin/wv2 x64 bin/deep_nesting_test.w -o bin/deep_nesting_64_test"
# wbuild: step="bin/deep_nesting_64_test"
/*
Writes the three machine-shaped nesting sources into the directory
named by its argument (bin/): statement_nesting_error_fixture.w and
statement_nesting_clean_fixture.w (tests/expression_nesting_error_
fixture.w.wbuild's recursion_depth_test runs them through bin/wfixture)
and deep_nesting_test.w (the deep_nesting_test / deep_nesting_64_test
targets above). Each is an 'if'/'else if' chain or a nest of fors and
ifs hundreds of lines long, so the tree carries this generator instead
of the output; the headers below document each file's shape.
*/
import lib.lib
import lib.file
import lib.path
import structures.string


# One line: tabs of indentation, text, newline.
void gn_line(string_builder* s, int tabs, char* text):
	int i = 0
	while (i < tabs):
		string_append_char(s, 9)
		i = i + 1
	string_append(s, text)
	string_append_char(s, 10)


# 'prefix<n>suffix' as one line.
void gn_line_n(string_builder* s, int tabs, char* prefix, int n, char* suffix):
	int i = 0
	while (i < tabs):
		string_append_char(s, 9)
		i = i + 1
	string_append(s, prefix)
	string_append_int(s, n)
	string_append(s, suffix)
	string_append_char(s, 10)


# The header comment of statement_nesting_error_fixture, verbatim.
void statement_nesting_error_fixture_header(string_builder* s):
	gn_line(s, 0, c"# Recursion-depth guard (wave plan C task 2h, docs/projects/")
	gn_line(s, 0, c"# ai_tooling_next_steps.md \"No recursion-depth guard in the recursive-")
	gn_line(s, 0, c"# descent parser\"): grammar/statement.w's statement() -- the single")
	gn_line(s, 0, c"# function every nested '{...}'/if/while/for/switch body recurses back")
	gn_line(s, 0, c"# through, including an 'else if' chain's own right-recursion through")
	gn_line(s, 0, c"# the 'else' arm -- now counts stmt_nesting_depth and errors past 200.")
	gn_line(s, 0, c"# This fixture's 220-branch 'if'/'else if' chain drives statement()")
	gn_line(s, 0, c"# recursion to 221 (the function's own top-level body costs one level,")
	gn_line(s, 0, c"# each branch after the first one more) -- comfortably past the limit,")
	gn_line(s, 0, c"# but still safely under 256, where this exact chain shape would")
	gn_line(s, 0, c"# otherwise hit code_generator/x86.w's separate, pre-existing fixed-")
	gn_line(s, 0, c"# size ctrl_kind_stack/ctrl_val_stack bound instead (measured: 255")
	gn_line(s, 0, c"# branches of this shape compile, 256 hits that array's own bounds")
	gn_line(s, 0, c"# trap). tests/statement_nesting_clean_fixture.w is the paired")
	gn_line(s, 0, c"# near-limit fixture proving legitimate deep chains still compile --")
	gn_line(s, 0, c"# lib/lib.w's real errno-to-string dispatch, the deepest in-tree case,")
	gn_line(s, 0, c"# is 132 branches, comfortably under both fixtures' depths.")
	gn_line(s, 0, c"# expect_fail")
	gn_line(s, 0, c"# expect_stderr: statement nesting too deep")


# The header comment of statement_nesting_clean_fixture, verbatim.
void statement_nesting_clean_fixture_header(string_builder* s):
	gn_line(s, 0, c"# Near-limit companion to tests/statement_nesting_error_fixture.w:")
	gn_line(s, 0, c"# grammar/statement.w's stmt_nesting_depth guard errors past 200 nested")
	gn_line(s, 0, c"# statement() recursions, so this 150-branch 'if'/'else if' chain (151")
	gn_line(s, 0, c"# total with the function's own top-level body) must still compile")
	gn_line(s, 0, c"# cleanly -- proving the limit does not clip legitimate (if extreme)")
	gn_line(s, 0, c"# real nesting. lib/lib.w's errno-to-string dispatch, the deepest")
	gn_line(s, 0, c"# in-tree 'else if' chain, is 132 branches -- under this fixture's")
	gn_line(s, 0, c"# depth too, so this is still a realistic upper bound, not a")
	gn_line(s, 0, c"# contrived one.")
	gn_line(s, 0, c"# reject_stderr: nesting too deep")


# The header comment of deep_nesting_test, verbatim.
void deep_nesting_test_header(string_builder* s):
	gn_line(s, 0, c"# wbuild: x64")
	gn_line(s, 0, c"/*")
	gn_line(s, 0, c"Genuinely nested control flow (a for whose body is another for, and so")
	gn_line(s, 0, c"on) used to trap at compile time: the codegen's ctrl region stacks")
	gn_line(s, 0, c"(code_generator/x86.w) were fixed int[256] arrays, and every open")
	gn_line(s, 0, c"if/while/for/switch region holds slots until it closes (2 per if, 3")
	gn_line(s, 0, c"per for), so 86 nested fors overflowed them with an index-out-of-")
	gn_line(s, 0, c"range trap. The stacks now grow dynamically, leaving the tokenizer's")
	gn_line(s, 0, c"200-unit statement-nesting guard as the only nesting bound.")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"Shapes (all measured against the pre-fix compiler):")
	gn_line(s, 0, c"  deep_for   95 nested single-iteration fors -- 285 ctrl slots at")
	gn_line(s, 0, c"             peak, past the old 256 bound (trapped at for #86")
	gn_line(s, 0, c"             before the fix); guard depth 1+2*95 = 191, under 200.")
	gn_line(s, 0, c"  deep_mixed 88 fors wrapping 9 ifs -- the if regions occupy ctrl")
	gn_line(s, 0, c"             slots 264..281, so if pushes too are exercised past the")
	gn_line(s, 0, c"             old bound (also trapped before the fix).")
	gn_line(s, 0, c"  deep_if    97 nested ifs, the deepest the front end permits: each")
	gn_line(s, 0, c"             genuinely nested level costs 2 statement-recursion units")
	gn_line(s, 0, c"             (the if and its ':' block both recurse statement()), so")
	gn_line(s, 0, c"             the 200-unit guard fires at 100 pure nested ifs -- below")
	gn_line(s, 0, c"             the old 129-if array bound. A pure if nest therefore")
	gn_line(s, 0, c"             cannot cross the old bound; deep_mixed covers that, and")
	gn_line(s, 0, c"             this shape pins the guard-max depth still executing")
	gn_line(s, 0, c"             correctly.")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"Each level increments a counter exactly once, so the asserted totals")
	gn_line(s, 0, c"prove every level's body ran. Generated programmatically.")
	gn_line(s, 0, c"*/")


# void main() over an 'if'/'else if' chain of the given branch count.
void gn_else_if_chain(string_builder* s, int branches):
	gn_line(s, 0, c"void main():")
	gn_line(s, 1, c"int x = 0")
	gn_line(s, 1, c"if (x == 0): pass")
	int i = 1
	while (i < branches):
		gn_line_n(s, 1, c"else if (x == ", i, c"): pass")
		i = i + 1


# 'for int <var><k> in range(1):' levels k = 0..count-1 from depth
# on, each counting one n; returns the next depth.
int gn_fors(string_builder* s, char* var, int count, int depth):
	string_builder* head = string_new()
	string_append(head, c"for int ")
	string_append(head, var)
	int k = 0
	while (k < count):
		gn_line_n(s, depth, head.data, k, c" in range(1):")
		gn_line(s, depth + 1, c"n = n + 1")
		depth = depth + 1
		k = k + 1
	string_free(head)
	return depth


# 'if (n == <k>):' levels k = first..last-1 from depth on, each
# counting one n; returns the next depth.
int gn_ifs(string_builder* s, int first, int last, int depth):
	int k = first
	while (k < last):
		gn_line_n(s, depth, c"if (n == ", k, c"):")
		gn_line(s, depth + 1, c"n = n + 1")
		depth = depth + 1
		k = k + 1
	return depth


void gn_deep_nesting_test(string_builder* s):
	deep_nesting_test_header(s)
	gn_line(s, 0, c"import lib.assert")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"int deep_for():")
	gn_line(s, 1, c"int n = 0")
	gn_fors(s, c"i", 95, 1)
	gn_line(s, 1, c"return n")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"int deep_mixed():")
	gn_line(s, 1, c"int n = 0")
	gn_ifs(s, 88, 97, gn_fors(s, c"m", 88, 1))
	gn_line(s, 1, c"return n")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"int deep_if():")
	gn_line(s, 1, c"int n = 0")
	gn_ifs(s, 0, 97, 1)
	gn_line(s, 1, c"return n")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"")
	gn_line(s, 0, c"int main():")
	gn_line(s, 1, c"asserts(c\"deep_for runs all 95 levels\", deep_for() == 95)")
	gn_line(s, 1, c"asserts(c\"deep_mixed runs all 97 levels\", deep_mixed() == 97)")
	gn_line(s, 1, c"asserts(c\"deep_if reaches depth 97\", deep_if() == 97)")
	gn_line(s, 1, c"println2(c\"deep_nesting_test passed\")")
	gn_line(s, 1, c"return 0")


int gn_write(char* dir, char* name, string_builder* s):
	char* path = path_join(dir, name)
	if (file_write_text(path, s.data) == 0):
		print_error(c"gen_nesting_fixtures: cannot write ")
		println2(path)
		return 1
	string_free(s)
	return 0


int main(int argc, int argv):
	if (argc != 2):
		println2(c"usage: gen_nesting_fixtures <dir>")
		return 1
	char** arg = argv + __word_size__
	char* dir = *arg
	string_builder* s = string_new()
	statement_nesting_error_fixture_header(s)
	gn_else_if_chain(s, 220)
	if (gn_write(dir, c"statement_nesting_error_fixture.w", s)):
		return 1
	s = string_new()
	statement_nesting_clean_fixture_header(s)
	gn_else_if_chain(s, 150)
	if (gn_write(dir, c"statement_nesting_clean_fixture.w", s)):
		return 1
	s = string_new()
	gn_deep_nesting_test(s)
	return gn_write(dir, c"deep_nesting_test.w", s)
