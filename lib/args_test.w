# wbuild: x64
import lib.testing
import lib.args


# Stage the same argument vector the testing_ground target passes:
#   prog arg1 arg2 arg3 -o output -i=input --input=doubledash
void stage_makefile_args():
	char** argv = cast(char**, malloc(8 * __word_size__))
	argv[0] = c"prog"
	argv[1] = c"arg1"
	argv[2] = c"arg2"
	argv[3] = c"arg3"
	argv[4] = c"-o"
	argv[5] = c"output"
	argv[6] = c"-i=input"
	argv[7] = c"--input=doubledash"
	args_init(8, cast(int, argv))


void test_args_count_and_program():
	stage_makefile_args()
	assert_equal(8, args_count())
	assert_strings_equal(c"prog", args_program())
	assert_strings_equal(c"arg2", args_get(2))
	assert_equal(0, cast(int, args_get(8)))
	assert_equal(0, cast(int, args_get(0-1)))


void test_args_positionals():
	stage_makefile_args()
	assert_equal(3, args_positional_count())
	assert_strings_equal(c"arg1", args_positional(0))
	assert_strings_equal(c"arg2", args_positional(1))
	assert_strings_equal(c"arg3", args_positional(2))
	assert_equal(0, cast(int, args_positional(3)))


void test_args_has_flag():
	stage_makefile_args()
	assert_equal(1, args_has_flag(c"o"))
	assert_equal(1, args_has_flag(c"i"))
	assert_equal(1, args_has_flag(c"input"))
	assert_equal(0, args_has_flag(c"missing"))
	assert_equal(0, args_has_flag(c"arg1"))


void test_args_values():
	stage_makefile_args()
	assert_strings_equal(c"output", args_value(c"o"))
	assert_strings_equal(c"input", args_value(c"i"))
	assert_strings_equal(c"doubledash", args_value(c"input"))
	assert_equal(0, cast(int, args_value(c"missing")))


void test_args_bare_flag_without_value():
	char** argv = cast(char**, malloc(3 * __word_size__))
	argv[0] = c"prog"
	argv[1] = c"file.w"
	argv[2] = c"-v"
	args_init(3, cast(int, argv))
	assert_equal(1, args_has_flag(c"v"))
	assert_equal(0, cast(int, args_value(c"v")))
	assert_equal(1, args_positional_count())
	assert_strings_equal(c"file.w", args_positional(0))


void test_args_flag_value_not_positional():
	char** argv = cast(char**, malloc(4 * __word_size__))
	argv[0] = c"prog"
	argv[1] = c"-o"
	argv[2] = c"out.bin"
	argv[3] = c"input.w"
	args_init(4, cast(int, argv))
	assert_strings_equal(c"out.bin", args_value(c"o"))
	assert_equal(1, args_positional_count())
	assert_strings_equal(c"input.w", args_positional(0))
