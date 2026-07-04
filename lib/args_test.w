import lib.testing
import lib.args


# Stage the same argument vector the Makefile smoke test passes:
#   prog arg1 arg2 arg3 -o output -i=input --input=doubledash
void stage_makefile_args():
	int argv = cast(int, malloc(8 * 4))
	save_int(argv + 0, "prog")
	save_int(argv + 4, "arg1")
	save_int(argv + 8, "arg2")
	save_int(argv + 12, "arg3")
	save_int(argv + 16, "-o")
	save_int(argv + 20, "output")
	save_int(argv + 24, "-i=input")
	save_int(argv + 28, "--input=doubledash")
	args_init(8, argv)


void test_args_count_and_program():
	stage_makefile_args()
	assert_equal(8, args_count())
	assert_strings_equal("prog", args_program())
	assert_strings_equal("arg2", args_get(2))
	assert_equal(0, cast(int, args_get(8)))
	assert_equal(0, cast(int, args_get(0-1)))


void test_args_positionals():
	stage_makefile_args()
	assert_equal(3, args_positional_count())
	assert_strings_equal("arg1", args_positional(0))
	assert_strings_equal("arg2", args_positional(1))
	assert_strings_equal("arg3", args_positional(2))
	assert_equal(0, cast(int, args_positional(3)))


void test_args_has_flag():
	stage_makefile_args()
	assert_equal(1, args_has_flag("o"))
	assert_equal(1, args_has_flag("i"))
	assert_equal(1, args_has_flag("input"))
	assert_equal(0, args_has_flag("missing"))
	assert_equal(0, args_has_flag("arg1"))


void test_args_values():
	stage_makefile_args()
	assert_strings_equal("output", args_value("o"))
	assert_strings_equal("input", args_value("i"))
	assert_strings_equal("doubledash", args_value("input"))
	assert_equal(0, cast(int, args_value("missing")))


void test_args_bare_flag_without_value():
	int argv = cast(int, malloc(3 * 4))
	save_int(argv + 0, "prog")
	save_int(argv + 4, "file.w")
	save_int(argv + 8, "-v")
	args_init(3, argv)
	assert_equal(1, args_has_flag("v"))
	assert_equal(0, cast(int, args_value("v")))
	assert_equal(1, args_positional_count())
	assert_strings_equal("file.w", args_positional(0))


void test_args_flag_value_not_positional():
	int argv = cast(int, malloc(4 * 4))
	save_int(argv + 0, "prog")
	save_int(argv + 4, "-o")
	save_int(argv + 8, "out.bin")
	save_int(argv + 12, "input.w")
	args_init(4, argv)
	assert_strings_equal("out.bin", args_value("o"))
	assert_equal(1, args_positional_count())
	assert_strings_equal("input.w", args_positional(0))
