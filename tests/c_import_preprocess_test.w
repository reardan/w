import lib.testing
import libs.extras.c_import.preprocessor


int ci_pp_test_contains(char* haystack, char* needle):
	int i = 0
	while (haystack[i]):
		if (starts_with(haystack + i, needle)):
			return 1
		i = i + 1
	return strlen(needle) == 0


void assert_preprocess_contains(char* source, char* expected):
	char* output = ci_preprocess_text(source, "memory.h")
	assert_equal(1, ci_pp_test_contains(output, expected))


void test_preprocess_object_and_function_macros():
	assert_preprocess_contains("#define COUNT 4\x0a#define ADD(a, b) ((a) + (b))\x0aint values[COUNT];\x0aint sum = ADD(2, COUNT);\x0a", "int values[4];")
	assert_preprocess_contains("#define COUNT 4\x0a#define ADD(a, b) ((a) + (b))\x0aint sum = ADD(2, COUNT);\x0a", "int sum = ((2) + (4));")


void test_preprocess_conditionals_and_defined():
	assert_preprocess_contains("#define ENABLED 1\x0a#if defined(ENABLED) && ENABLED\x0aint kept;\x0a#else\x0aint skipped;\x0a#endif\x0a", "int kept;")
	char* output = ci_preprocess_text("#define ENABLED 1\x0a#if defined(ENABLED) && ENABLED\x0aint kept;\x0a#else\x0aint skipped;\x0a#endif\x0a", "memory.h")
	assert_equal(0, ci_pp_test_contains(output, "int skipped;"))


void test_preprocess_variadic_stringify_and_paste():
	assert_preprocess_contains("#define CALL(fn, ...) fn(__VA_ARGS__)\x0aint x = CALL(add, 1, 2);\x0a", "int x = add(1, 2);")
	assert_preprocess_contains("#define STR(x) #x\x0achar* s = STR(hello);\x0a", "char* s = \"hello\";")
	assert_preprocess_contains("#define CAT(a, b) a##b\x0aint CAT(pre, fix);\x0a", "int prefix;")


void test_preprocess_comments_and_line_splicing():
	assert_preprocess_contains("#define VALUE 4 /* block */\x0aint x = VALUE; // line\x0a", "int x = 4;")
	assert_preprocess_contains("#define VALUE 1 + \x5c\x0a2\x0aint x = VALUE;\x0a", "int x = 1 + 2;")


void test_preprocess_include_fixture():
	char* output = ci_preprocess_header("tests/c_import_preprocess_fixture.h")
	assert_equal(1, ci_pp_test_contains(output, "typedef unsigned long pp_size_t;"))
	assert_equal(1, ci_pp_test_contains(output, "enum pp_color"))
	assert_equal(1, ci_pp_test_contains(output, "pp_red = 12"))
