import lib.testing
import structures.array_list
import libs.extras.c_preprocessor.pp_lexer
import libs.extras.c_preprocessor.pp_directives


char* cpp_test(char* source):
	cpp_result* result = cpp_preprocess_text(source, "<test>")
	return result.text


void test_object_macro_expands():
	assert_strings_equal("int a = 3;\n", cpp_test("#define X 3\nint a = X;\n"))


void test_conditionals_and_if_eval():
	assert_strings_equal("int v = 7;\n", cpp_test("#define X 5\n#if defined(X) && X + 2 == 7\nint v = 7;\n#else\nint v = 0;\n#endif\n"))


void test_stringize_and_argument_prescan():
	assert_strings_equal("\"N\"\n\"42\"\n", cpp_test("#define N 42\n#define STR(s) #s\n#define XSTR(s) STR(s)\nSTR(N)\nXSTR(N)\n"))


void test_paste_result_rescans():
	assert_strings_equal("99\n", cpp_test("#define AB 99\n#define cat(x,y) x ## y\ncat(A,B)\n"))


void test_object_like_paste_result_rescans():
	assert_strings_equal("77\n", cpp_test("#define CI_HEADER_CONSTANT 77\n#define CI_HEADER_PASTED CI_HEADER_ ## CONSTANT\nCI_HEADER_PASTED\n"))


void test_function_name_rescans_with_following_source():
	assert_strings_equal("5(6)\n", cpp_test("#define g(x) x\n#define call g\ncall(5)(6)\n"))


void test_blue_paint_blocks_recursive_function_macro():
	assert_strings_equal("bar foo (2)\n", cpp_test("#define foo(x) bar x\nfoo(foo) (2)\n"))


void test_placemarker_paste():
	assert_strings_equal("int j[]={45,67,89};\n", cpp_test("#define t(x,y,z) x ## y ## z\nint j[]={t(,4,5),t(6,,7),t(8,9,)};\n"))


void test_gnu_variadic_comma_swallow():
	assert_strings_equal("printf(\"hi\")\n", cpp_test("#define LOG(fmt, ...) printf(fmt, ## __VA_ARGS__)\nLOG(\"hi\")\n"))


void test_pragma_once_include():
	cpp_result* result = cpp_preprocess_text("#include \"tests/c_preprocessor/once.h\"\n#include \"tests/c_preprocessor/once.h\"\n", "<test>")
	assert_strings_equal("9\n", result.text)


void test_include_next_searches_after_current_directory():
	cpp_preprocessor* pp = cpp_preprocessor_new()
	array_list_insert(pp.include_paths, 0, "tests/c_preprocessor/next2")
	array_list_insert(pp.include_paths, 0, "tests/c_preprocessor/next1")
	cpp_preprocess_tokens(pp, cpp_tokenize_text("#include <wrap.h>\n", "<test>"))
	assert_strings_equal("2\n1\n", pp.output.data)


void test_stdio_header_preprocesses():
	cpp_result* result = cpp_preprocess_file("/usr/include/stdio.h")
	assert1(strlen(result.text) > 0)
