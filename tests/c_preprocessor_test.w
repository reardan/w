import lib.testing
import libs.extras.c_preprocessor.pp_lexer
import libs.extras.c_preprocessor.pp_directives


char* cpp_test(char* source):
	cpp_result* result = cpp_preprocess_text(source, c"<test>")
	return result.text


# list[char*] has no insert(i, v) pseudo-method yet; push then shift the
# new value to the front.
void insert_path_front(list[char*] paths, char* path):
	paths.push(path)
	int i = paths.length - 1
	while (i > 0):
		paths[i] = paths[i - 1]
		i = i - 1
	paths[0] = path


void test_object_macro_expands():
	assert_strings_equal(c"int a = 3;\n", cpp_test(c"#define X 3\nint a = X;\n"))


void test_conditionals_and_if_eval():
	assert_strings_equal(c"int v = 7;\n", cpp_test(c"#define X 5\n#if defined(X) && X + 2 == 7\nint v = 7;\n#else\nint v = 0;\n#endif\n"))


void test_stringize_and_argument_prescan():
	assert_strings_equal(c"\"N\"\n\"42\"\n", cpp_test(c"#define N 42\n#define STR(s) #s\n#define XSTR(s) STR(s)\nSTR(N)\nXSTR(N)\n"))


void test_paste_result_rescans():
	assert_strings_equal(c"99\n", cpp_test(c"#define AB 99\n#define cat(x,y) x ## y\ncat(A,B)\n"))


void test_object_like_paste_result_rescans():
	assert_strings_equal(c"77\n", cpp_test(c"#define CI_HEADER_CONSTANT 77\n#define CI_HEADER_PASTED CI_HEADER_ ## CONSTANT\nCI_HEADER_PASTED\n"))


void test_function_name_rescans_with_following_source():
	assert_strings_equal(c"5(6)\n", cpp_test(c"#define g(x) x\n#define call g\ncall(5)(6)\n"))


void test_prescan_expands_argument_that_is_whole_invocation():
	# glibc math.h pattern: the raw argument is itself a complete macro call
	# and must be expanded during prescan before ## pastes around it
	assert_strings_equal(c"__lgammaf\n", cpp_test(c"#define CAT(x,y) x ## y\n#define PRE(name) name##f\n#define DECL(function) PRE(function)\nDECL(CAT(__,lgamma))\n"))


void test_math_precname_chain_expands():
	assert_strings_equal(c"extern float lgammaf_r (float, int *__signgamp); extern float __lgammaf_r (float, int *__signgamp);\n", cpp_test(c"#define __CONCAT(x,y) x ## y\n#define __MATH_PRECNAME(name,r) name##f##r\n#define __MATHCALL(function,suffix, args) __MATHDECL (float,function,suffix, args)\n#define __MATHDECL(type, function,suffix, args) __MATHDECL_1(type, function,suffix, args); __MATHDECL_1(type, __CONCAT(__,function),suffix, args)\n#define __MATHDECL_1(type, function, suffix, args) extern type __MATH_PRECNAME(function,suffix) args\n__MATHCALL (lgamma,_r, (float, int *__signgamp));\n"))


void test_blue_paint_blocks_recursive_function_macro():
	assert_strings_equal(c"bar foo (2)\n", cpp_test(c"#define foo(x) bar x\nfoo(foo) (2)\n"))


void test_placemarker_paste():
	assert_strings_equal(c"int j[]={45,67,89};\n", cpp_test(c"#define t(x,y,z) x ## y ## z\nint j[]={t(,4,5),t(6,,7),t(8,9,)};\n"))


void test_gnu_variadic_comma_swallow():
	assert_strings_equal(c"printf(\"hi\")\n", cpp_test(c"#define LOG(fmt, ...) printf(fmt, ## __VA_ARGS__)\nLOG(\"hi\")\n"))


void test_pragma_once_include():
	cpp_result* result = cpp_preprocess_text(c"#include \"tests/c_preprocessor/once.h\"\n#include \"tests/c_preprocessor/once.h\"\n", c"<test>")
	assert_strings_equal(c"9\n", result.text)


void test_include_next_searches_after_current_directory():
	cpp_preprocessor* pp = cpp_preprocessor_new()
	insert_path_front(pp.include_paths, c"tests/c_preprocessor/next2")
	insert_path_front(pp.include_paths, c"tests/c_preprocessor/next1")
	cpp_preprocess_tokens(pp, cpp_tokenize_text(c"#include <wrap.h>\n", c"<test>"))
	assert_strings_equal(c"2\n1\n", pp.output.data)


void test_stdio_header_preprocesses():
	cpp_result* result = cpp_preprocess_file(c"/usr/include/stdio.h")
	assert1(strlen(result.text) > 0)


void test_unistd_header_preprocesses():
	cpp_result* result = cpp_preprocess_file(c"/usr/include/unistd.h")
	assert1(strlen(result.text) > 0)


void test_math_header_preprocesses():
	cpp_result* result = cpp_preprocess_file(c"/usr/include/math.h")
	assert1(strlen(result.text) > 0)
