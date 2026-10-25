# wbuild: target=wfmt_test tag=tests dep=wfmt
# wbuild: step="bin/wv2 tests/wfmt_test.w -o bin/wfmt_test"
# wbuild: step="bin/wfmt_test"
# wbuild: step="bin/wv2 tools/wfmt_tree_check.w -o bin/wfmt_tree_check"
# wbuild: step="bin/wv2 deps w.w" stdout_file="bin/wfmt_tree_deps.txt"
# wbuild: step="bin/wfmt_tree_check bin/wfmt_tree_deps.txt" timeout=600000
/*
wfmt (tools/wfmt_lib.w, issue #716): each case formats an input and
compares it with the canonical text, then formats that text again to
check that the formatter is idempotent. The second target step,
bin/wfmt_tree_check, formats a copy of the compiler's own import
closure and checks that it compiles to the same binary.
*/
import lib.lib
import lib.testing
import tools.wfmt_lib


void assert_formats(char* input, char* want):
	char* got = wfmt_format(input, c"case.w")
	if (got == 0): println2(wfmt_error)
	assert1(got != 0)
	assert_strings_equal(want, got)
	char* again = wfmt_format(got, c"case.w")
	assert1(again != 0)
	assert_strings_equal(got, again)


void assert_unchanged(char* input):
	assert_formats(input, input)


void test_binary_operators_and_commas():
	assert_formats(c"int f(int a,int b):\x0a\x09return a+b*c-d\x0a", c"int f(int a, int b):\x0a\x09return a + b * c - d\x0a")
	assert_formats(c"int x=1\x0ax+=2\x0ay:=x<<2\x0a", c"int x = 1\x0ax += 2\x0ay := x << 2\x0a")
	assert_formats(c"if(a&&b)||c:\x0a\x09pass\x0a", c"if (a && b) || c:\x0a\x09pass\x0a")


void test_unary_operators():
	assert_formats(c"x = - 1\x0ay = ! a\x0az = * p + & q\x0a", c"x = -1\x0ay = !a\x0az = *p + &q\x0a")
	assert_formats(c"return a - -b\x0a", c"return a - -b\x0a")
	# 'a - - b' must not collapse into the '--' token
	assert_formats(c"x = - - b\x0a", c"x = - -b\x0a")
	assert_formats(c"i ++\x0a", c"i++\x0a")


void test_brackets_calls_and_members():
	assert_formats(c"f ( a ) [ 1 ] . b\x0a", c"f(a)[1].b\x0a")
	assert_formats(c"list[int] xs = new list[int]\x0a", c"list[int] xs = new list[int]\x0a")
	assert_formats(c"int n = cast (int, sizeof (T))\x0a", c"int n = cast(int, sizeof(T))\x0a")
	assert_formats(c"while(i < n):\x0a\x09i = i + 1\x0a", c"while (i < n):\x0a\x09i = i + 1\x0a")
	assert_formats(c"return(x)\x0a", c"return (x)\x0a")


void test_pointer_types():
	assert_formats(c"char *s = cast(char *, p)\x0a", c"char* s = cast(char*, p)\x0a")
	assert_formats(c"int strlen(char *s);\x0a", c"int strlen(char* s);\x0a")
	assert_formats(c"map[char *,int] m\x0a", c"map[char*, int] m\x0a")


void test_colons():
	assert_formats(c"if x :\x0a\x09return\x0aelse :return 1\x0a", c"if x:\x0a\x09return\x0aelse: return 1\x0a")
	assert_formats(c"y = c ? a:b\x0a", c"y = c ? a : b\x0a")
	assert_formats(c"y = v [1 : n]\x0a", c"y = v[1:n]\x0a")
	assert_formats(c"y = v[i*w:j*w]\x0a", c"y = v[i * w : j * w]\x0a")
	assert_formats(c"p = new Point(x:1, y:2)\x0a", c"p = new Point(x: 1, y: 2)\x0a")


void test_operator_definitions_and_varargs():
	assert_formats(c"V operator + (V a, V b):\x0a\x09return a\x0a", c"V operator+(V a, V b):\x0a\x09return a\x0a")
	assert_formats(c"extern int printf(char* fmt,...)\x0a", c"extern int printf(char* fmt, ...)\x0a")


void test_numbers_keep_their_exponents():
	assert_unchanged(c"float64 x = 1.5e-05 + 0x1e - 5\x0a")
	assert_formats(c"y = x.f+1e+3\x0a", c"y = x.f + 1e+3\x0a")


void test_indentation_and_trailing_whitespace():
	assert_formats(c"int f():\x0a    return 1  \x0a", c"int f():\x0a\x09return 1\x0a")
	assert_formats(c"int f():\x0d\x0a\x09return 1\x0d\x0a", c"int f():\x0a\x09return 1\x0a")
	# an indent narrower than one tab is left alone, like 'check --fix'
	assert_unchanged(c"x = f(a,\x0a  b)\x0a")


void test_blank_lines():
	assert_formats(c"\x0a\x0aint a\x0a\x0a\x0a\x0a\x0aint b\x0a\x0a\x0a", c"int a\x0a\x0a\x0aint b\x0a")
	assert_formats(c"int a", c"int a\x0a")
	assert_formats(c"", c"")


void test_comments():
	assert_unchanged(c"int x = 1    # aligned\x0aint yy = 2\x09# tabbed\x0a")
	assert_formats(c"x = 1# tight\x0a", c"x = 1 # tight\x0a")
	assert_formats(c"#   keep  text   \x0a/* a  \x0a b */ x=1\x0a", c"#   keep  text\x0a/* a\x0a b */ x = 1\x0a")


void test_strings_are_untouched():
	assert_unchanged(c"s = c\"a,b  +c\"\x0at = f\"{a+b}\"\x0a")
	assert_formats(c"s = \"line one   \x0aline two\"\x0a", c"s = \"line one   \x0aline two\"\x0a")


void test_opt_outs():
	assert_unchanged(c"x=1 # nolint\x0a")
	assert_formats(c"# wfmt: off\x0ax=1\x0a# wfmt: on\x0ay=2\x0a", c"# wfmt: off\x0ax=1\x0a# wfmt: on\x0ay = 2\x0a")


void test_keyword_misparse_keeps_condition_spacing():
	# The permissive grammar reads this condition as a call of 'if'
	assert_unchanged(c"if (a == 5) || (b == 6):\x0a\x09pass\x0a")
	# 'range' as a variable: the grammar reads '* n' as a prefix
	assert_unchanged(c"x = a / range * n\x0a")


void test_parse_error_leaves_input():
	assert1(wfmt_format(c"int f(:\x0a", c"bad.w") == 0)
	assert1(wfmt_error != 0)
