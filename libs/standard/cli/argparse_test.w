import lib.testing
import lib.lib
import libs.standard.cli.argparse
import libs.standard.runtime.sys


int argparse_test_contains(char* haystack, char* needle):
	int i = 0
	while (haystack[i] != 0):
		int j = 0
		while ((needle[j] != 0) & (haystack[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		i = i + 1
	return 0


char** argparse_test_argv(int count):
	return cast(char**, malloc(count * __word_size__))


arg_parser* make_copy_parser():
	arg_parser* p = argparse_new(c"copy")
	argparse_description(p, c"copy files")
	argparse_add_flag(p, c"--verbose", c"enable verbose output")
	argparse_add_option(p, c"--output", c"PATH", c"write output path")
	argparse_add_required_option(p, c"--mode", c"MODE", c"copy mode")
	argparse_add_positional(p, c"source", c"source path")
	return p


void test_argparse_parses_declared_flags_options_and_positionals():
	char** argv = argparse_test_argv(6)
	argv[0] = c"copy"
	argv[1] = c"--verbose"
	argv[2] = c"--output=out.txt"
	argv[3] = c"--mode"
	argv[4] = c"fast"
	argv[5] = c"input.txt"
	arg_parser* p = make_copy_parser()
	arg_namespace* ns = argparse_parse(p, 6, cast(int, argv))
	assert_equal(0, cast(int, ns.error))
	assert_equal(1, argparse_has(ns, c"verbose"))
	assert_strings_equal(c"out.txt", argparse_get(ns, c"--output"))
	assert_strings_equal(c"fast", argparse_get(ns, c"mode"))
	assert_equal(1, argparse_positional_count(ns))
	assert_strings_equal(c"input.txt", argparse_positional(ns, 0))
	assert_strings_equal(c"input.txt", argparse_get(ns, c"source"))


void test_argparse_reports_unknown_and_missing_required():
	char** argv = argparse_test_argv(3)
	argv[0] = c"copy"
	argv[1] = c"--bad"
	argv[2] = c"input.txt"
	arg_namespace* ns = argparse_parse(make_copy_parser(), 3, cast(int, argv))
	assert_strings_equal(c"unknown argument: --bad", ns.error)

	char** argv2 = argparse_test_argv(2)
	argv2[0] = c"copy"
	argv2[1] = c"input.txt"
	ns = argparse_parse(make_copy_parser(), 2, cast(int, argv2))
	assert_strings_equal(c"missing required argument: mode", ns.error)


void test_argparse_help_is_deterministic():
	arg_parser* p = make_copy_parser()
	char* help = argparse_help(p)
	assert_equal(1, argparse_test_contains(help, c"usage: copy [--verbose] [--output PATH] [--mode MODE] <source>"))
	assert_equal(1, argparse_test_contains(help, c"copy files"))
	assert_equal(1, argparse_test_contains(help, c"--output PATH"))
	assert_equal(1, argparse_test_contains(help, c"-h, --help"))

	char** argv = argparse_test_argv(2)
	argv[0] = c"copy"
	argv[1] = c"--help"
	arg_namespace* ns = argparse_parse(p, 2, cast(int, argv))
	assert_equal(1, ns.help_requested)
	assert_equal(1, argparse_has(ns, c"help"))
	assert_equal(0, cast(int, ns.error))


void test_argparse_subcommand_parse():
	arg_parser* root = argparse_new(c"tool")
	arg_parser* init = argparse_new(c"tool init")
	argparse_add_flag(init, c"--bare", c"create bare repository")
	argparse_add_required_option(init, c"--template", c"PATH", c"template path")
	argparse_add_subcommand(root, c"init", init)

	char** argv = argparse_test_argv(5)
	argv[0] = c"tool"
	argv[1] = c"init"
	argv[2] = c"--bare"
	argv[3] = c"--template"
	argv[4] = c"base"
	arg_namespace* ns = argparse_parse(root, 5, cast(int, argv))
	assert_equal(0, cast(int, ns.error))
	assert_strings_equal(c"init", ns.subcommand)
	assert1(ns.subnamespace != 0)
	assert_equal(1, argparse_has(ns.subnamespace, c"bare"))
	assert_strings_equal(c"base", argparse_get(ns.subnamespace, c"template"))
	assert_equal(1, argparse_test_contains(argparse_help(root), c"commands:\x0a  init"))


void test_argparse_dashdash_stops_option_parsing():
	arg_parser* p = argparse_new(c"show")
	argparse_add_positional(p, c"name", c"name to show")

	char** argv = argparse_test_argv(3)
	argv[0] = c"show"
	argv[1] = c"--"
	argv[2] = c"--literal"
	arg_namespace* ns = argparse_parse(p, 3, cast(int, argv))
	assert_equal(0, cast(int, ns.error))
	assert_strings_equal(c"--literal", argparse_positional(ns, 0))


void test_runtime_sys_argv_and_platform_helpers():
	char** argv = argparse_test_argv(3)
	argv[0] = c"prog"
	argv[1] = c"alpha"
	argv[2] = c"beta"
	list[char*] words = sys_argv(3, cast(int, argv))
	assert_equal(3, words.length)
	assert_strings_equal(c"alpha", words[1])

	sys_init(3, cast(int, argv))
	assert_equal(3, sys_argc())
	assert_strings_equal(c"prog", sys_executable())
	assert_equal(__word_size__, sys_word_size())
	if (__word_size__ == 8):
		assert_strings_equal(c"linux-x64", sys_platform())
	else:
		assert_strings_equal(c"linux-x86", sys_platform())
