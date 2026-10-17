# wbuild: x64
# wbuild: step="bin/argparse_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# Tests for libs/standard/cli/argparse.w: argv vectors in, parsed values,
# help text and usage errors out.
import lib.testing
import libs.standard.cli.argparse


# argv words from a space-separated line (no program name); "" -> none.
list[char*] words_of(char* line):
	list[char*] out = new list[char*]
	int start = 0
	int i = 0
	while (1):
		if (line[i] == ' ' || line[i] == 0):
			if (i > start): out.push(ap_substr(line, start, i))
			if (line[i] == 0): break
			start = i + 1
		i = i + 1
	return out


arg_namespace* parse_line(arg_parser* p, char* line):
	list[char*] argv = words_of(line)
	arg_namespace* ns = argparse_parse_list(p, argv)
	ap_free_strings(argv)
	return ns


void assert_ok(arg_namespace* ns):
	if (ns.error): assert_strings_equal(c"(no error)", ns.error)
	assert_equal(0, ns.help)


void assert_error(arg_parser* p, char* line, char* want):
	arg_namespace* ns = parse_line(p, line)
	assert_strings_equal(want, ns.error)
	argparse_namespace_free(ns)


arg_parser* sample_parser():
	arg_parser* p = argparse_new(c"tool")
	argparse_description(p, c"Process some files.")
	argparse_add_flag(p, c"-v, --verbose", c"be chatty")
	argparse_arg_required(argparse_add_option(p, c"-n, --name", 0, c"your name"))
	argparse_arg_default(argparse_add_int(p, c"-c, --count", c"N", c"how many"), c"1")
	argparse_add_float(p, c"--ratio", 0, c"scale factor")
	argparse_add_list(p, c"-t, --tag", c"TAG", c"repeatable tag")
	argparse_add_positional(p, c"input", c"input file")
	argparse_add_positional_nargs(p, c"rest", ARGPARSE_ZERO_OR_MORE, c"more files")
	return p


void test_basic_values():
	arg_parser* p = sample_parser()
	arg_namespace* ns = parse_line(p, c"-v --name alice --count=3 --ratio 2.5 in.txt a b")
	assert_ok(ns)
	assert_equal(1, argparse_get_bool(ns, c"verbose"))
	assert_strings_equal(c"alice", argparse_get(ns, c"name"))
	assert_equal(3, argparse_get_int(ns, c"count"))
	assert_near(2.5, argparse_get_float(ns, c"ratio"))
	assert_strings_equal(c"in.txt", argparse_get(ns, c"input"))
	list[char*] rest = argparse_get_list(ns, c"rest")
	assert_equal(2, rest.length)
	assert_strings_equal(c"a", rest[0])
	assert_strings_equal(c"b", rest[1])
	assert_equal(0, argparse_get_list(ns, c"tag").length)
	assert_equal(1, argparse_is_set(ns, c"count"))
	assert_equal(0, argparse_is_set(ns, c"tag"))
	argparse_namespace_free(ns)
	argparse_free(p)


void test_defaults_and_absent():
	arg_parser* p = sample_parser()
	arg_namespace* ns = parse_line(p, c"-n bob x")
	assert_ok(ns)
	assert_equal(0, argparse_get_bool(ns, c"verbose"))
	assert_equal(1, argparse_get_int(ns, c"count"))
	assert_equal(0, argparse_is_set(ns, c"count"))
	assert_equal(0, cast(int, argparse_get(ns, c"ratio")))
	assert_near(0.0, argparse_get_float(ns, c"ratio"))
	assert_equal(0, argparse_get_list(ns, c"rest").length)
	argparse_namespace_free(ns)
	argparse_free(p)


void test_short_forms():
	arg_parser* p = sample_parser()
	# Glued value, -n=value, and a value-taking letter ending a group.
	arg_namespace* ns = parse_line(p, c"-nbob -c=7 -vtred f")
	assert_ok(ns)
	assert_strings_equal(c"bob", argparse_get(ns, c"name"))
	assert_equal(7, argparse_get_int(ns, c"count"))
	assert_equal(1, argparse_get_bool(ns, c"verbose"))
	assert_strings_equal(c"red", argparse_get_list(ns, c"tag")[0])
	argparse_namespace_free(ns)
	ns = parse_line(p, c"-vt blue -n x f")
	assert_ok(ns)
	assert_strings_equal(c"blue", argparse_get_list(ns, c"tag")[0])
	argparse_namespace_free(ns)
	argparse_free(p)


void test_combined_flags_and_count():
	arg_parser* p = argparse_new(c"c")
	argparse_add_flag(p, c"-a", 0)
	argparse_add_flag(p, c"-b", 0)
	argparse_add_count(p, c"-v, --verbose", c"more output")
	arg_namespace* ns = parse_line(p, c"-abvv --verbose")
	assert_ok(ns)
	assert_equal(1, argparse_get_bool(ns, c"a"))
	assert_equal(1, argparse_get_bool(ns, c"b"))
	assert_equal(3, argparse_get_int(ns, c"verbose"))
	argparse_namespace_free(ns)
	ns = parse_line(p, c"")
	assert_ok(ns)
	assert_equal(0, argparse_get_int(ns, c"verbose"))
	argparse_namespace_free(ns)
	assert_error(p, c"-abx", c"argument -b: ignored explicit argument 'x'")
	assert_error(p, c"--verbose=2", c"argument -v/--verbose: ignored explicit argument '2'")
	argparse_free(p)


void test_list_append_and_last_wins():
	arg_parser* p = sample_parser()
	arg_namespace* ns = parse_line(p, c"-t a --tag b --tag=c -n one -n two f")
	assert_ok(ns)
	list[char*] tags = argparse_get_list(ns, c"tag")
	assert_equal(3, tags.length)
	assert_strings_equal(c"a", tags[0])
	assert_strings_equal(c"b", tags[1])
	assert_strings_equal(c"c", tags[2])
	assert_strings_equal(c"two", argparse_get(ns, c"name"))
	assert_equal(2, argparse_is_set(ns, c"name"))
	argparse_namespace_free(ns)
	argparse_free(p)


void test_double_dash_terminator():
	arg_parser* p = sample_parser()
	arg_namespace* ns = parse_line(p, c"-n x -- -v --name")
	assert_ok(ns)
	assert_equal(0, argparse_get_bool(ns, c"verbose"))
	assert_strings_equal(c"-v", argparse_get(ns, c"input"))
	assert_strings_equal(c"--name", argparse_get_list(ns, c"rest")[0])
	argparse_namespace_free(ns)
	argparse_free(p)


void test_negative_numbers_are_values():
	arg_parser* p = argparse_new(c"neg")
	argparse_add_int(p, c"-x", 0, 0)
	argparse_arg_type(argparse_add_positional(p, c"n", 0), ARGPARSE_FLOAT)
	arg_namespace* ns = parse_line(p, c"-x -5 -2.5")
	assert_ok(ns)
	assert_equal(-5, argparse_get_int(ns, c"x"))
	assert_near(-2.5, argparse_get_float(ns, c"n"))
	argparse_namespace_free(ns)
	argparse_free(p)


void test_long_prefix_and_ambiguity():
	arg_parser* p = argparse_new(c"pre")
	argparse_add_flag(p, c"--verbose", 0)
	argparse_add_flag(p, c"--version", 0)
	argparse_add_option(p, c"--output", 0, 0)
	arg_namespace* ns = parse_line(p, c"--verb --out=o.txt")
	assert_ok(ns)
	assert_equal(1, argparse_get_bool(ns, c"verbose"))
	assert_equal(0, argparse_get_bool(ns, c"version"))
	assert_strings_equal(c"o.txt", argparse_get(ns, c"output"))
	argparse_namespace_free(ns)
	assert_error(p, c"--ver", c"ambiguous option: --ver could match --verbose, --version")
	argparse_free(p)


void test_dest_names():
	arg_parser* p = argparse_new(c"d")
	argparse_add_flag(p, c"--dry-run", 0)
	argparse_add_option(p, c"-o", 0, 0)
	argparse_arg_dest(argparse_add_option(p, c"-i", 0, 0), c"input_file")
	arg_namespace* ns = parse_line(p, c"--dry-run -o out -i in")
	assert_ok(ns)
	assert_equal(1, argparse_get_bool(ns, c"dry_run"))
	assert_strings_equal(c"out", argparse_get(ns, c"o"))
	assert_strings_equal(c"in", argparse_get(ns, c"input_file"))
	argparse_namespace_free(ns)
	argparse_free(p)


arg_parser* arity_parser(int a, int b):
	arg_parser* p = argparse_new(c"ar")
	argparse_add_positional_nargs(p, c"first", a, 0)
	argparse_add_positional_nargs(p, c"second", b, 0)
	return p


# Parses line and returns "first|second" with list values joined by ','.
char* arity_result(arg_parser* p, char* line):
	arg_namespace* ns = parse_line(p, line)
	ap_buf* b = ap_buf_new()
	if (ns.error):
		ap_buf_add(b, ns.error)
	else:
		int i = 0
		for char* s in argparse_get_list(ns, c"first"):
			if (i > 0): ap_buf_addc(b, ',')
			ap_buf_add(b, s)
			i = i + 1
		ap_buf_addc(b, '|')
		i = 0
		for char* s in argparse_get_list(ns, c"second"):
			if (i > 0): ap_buf_addc(b, ',')
			ap_buf_add(b, s)
			i = i + 1
	argparse_namespace_free(ns)
	return ap_buf_take(b)


void check_arity(int a, int b, char* line, char* want):
	arg_parser* p = arity_parser(a, b)
	char* got = arity_result(p, line)
	assert_strings_equal(want, got)
	free(got)
	argparse_free(p)


void test_positional_arity():
	check_arity(ARGPARSE_ONE_OR_MORE, ARGPARSE_ONE, c"a b c", c"a,b|c")
	check_arity(ARGPARSE_ONE_OR_MORE, ARGPARSE_ONE, c"a", c"the following arguments are required: second")
	check_arity(ARGPARSE_ONE_OR_MORE, ARGPARSE_ONE, c"", c"the following arguments are required: first, second")
	check_arity(ARGPARSE_OPTIONAL, ARGPARSE_ONE, c"a", c"|a")
	check_arity(ARGPARSE_OPTIONAL, ARGPARSE_ONE, c"a b", c"a|b")
	check_arity(ARGPARSE_OPTIONAL, ARGPARSE_ONE, c"a b c", c"unrecognized arguments: c")
	check_arity(ARGPARSE_ZERO_OR_MORE, ARGPARSE_ZERO_OR_MORE, c"a b", c"a,b|")
	check_arity(ARGPARSE_ONE, ARGPARSE_ONE_OR_MORE, c"a b c", c"a|b,c")
	check_arity(ARGPARSE_ONE, ARGPARSE_OPTIONAL, c"a", c"a|")
	check_arity(ARGPARSE_ZERO_OR_MORE, ARGPARSE_OPTIONAL, c"", c"|")


void test_positional_default():
	arg_parser* p = argparse_new(c"pd")
	argparse_arg_default(argparse_add_positional(p, c"mode", 0), c"fast")
	argparse_arg_default(argparse_add_positional_nargs(p, c"files", ARGPARSE_ZERO_OR_MORE, 0), c"a.w, b.w")
	arg_namespace* ns = parse_line(p, c"")
	assert_ok(ns)
	assert_strings_equal(c"fast", argparse_get(ns, c"mode"))
	list[char*] files = argparse_get_list(ns, c"files")
	assert_equal(2, files.length)
	assert_strings_equal(c"b.w", files[1])
	argparse_namespace_free(ns)
	ns = parse_line(p, c"slow x.w")
	assert_strings_equal(c"slow", argparse_get(ns, c"mode"))
	assert_equal(1, argparse_get_list(ns, c"files").length)
	argparse_namespace_free(ns)
	argparse_free(p)


void test_errors():
	arg_parser* p = sample_parser()
	assert_error(p, c"f", c"the following arguments are required: -n/--name")
	assert_error(p, c"", c"the following arguments are required: -n/--name, input")
	assert_error(p, c"-n x f --bogus", c"unrecognized arguments: --bogus")
	assert_error(p, c"-n x -q f", c"unrecognized arguments: -q")
	assert_error(p, c"-n x --count abc f", c"argument -c/--count: invalid int value: 'abc'")
	assert_error(p, c"-n x --count 99999999999999999999999 f", c"argument -c/--count: invalid int value: '99999999999999999999999'")
	assert_error(p, c"-n x --ratio 1.5x f", c"argument --ratio: invalid float value: '1.5x'")
	assert_error(p, c"-n", c"argument -n/--name: expected one argument")
	assert_error(p, c"-n -v f", c"argument -n/--name: expected one argument")
	assert_error(p, c"-n x -c -- f", c"argument -c/--count: expected one argument")
	argparse_free(p)


void test_int_forms():
	arg_parser* p = argparse_new(c"i")
	argparse_add_int(p, c"-x", 0, 0)
	arg_namespace* ns = parse_line(p, c"-x +1_000")
	assert_ok(ns)
	assert_equal(1000, argparse_get_int(ns, c"x"))
	argparse_namespace_free(ns)
	assert_error(p, c"-x 1__0", c"argument -x: invalid int value: '1__0'")
	assert_error(p, c"-x 0x10", c"argument -x: invalid int value: '0x10'")
	assert_error(p, c"-x=", c"argument -x: invalid int value: ''")
	argparse_free(p)


void test_choices_and_typed_list():
	arg_parser* p = argparse_new(c"ch")
	argparse_arg_choices(argparse_add_option(p, c"--color", 0, 0), c"red, green,blue")
	argparse_arg_type(argparse_add_list(p, c"-p, --port", 0, 0), ARGPARSE_INT)
	arg_namespace* ns = parse_line(p, c"--color green -p 80 -p443")
	assert_ok(ns)
	assert_strings_equal(c"green", argparse_get(ns, c"color"))
	list[char*] ports = argparse_get_list(ns, c"port")
	assert_strings_equal(c"443", ports[1])
	argparse_namespace_free(ns)
	assert_error(p, c"--color pink", c"argument --color: invalid choice: 'pink' (choose from red, green, blue)")
	assert_error(p, c"-p http", c"argument -p/--port: invalid int value: 'http'")
	argparse_free(p)


void test_bad_default_reported():
	arg_parser* p = argparse_new(c"bd")
	argparse_arg_default(argparse_add_int(p, c"-x", 0, 0), c"many")
	assert_error(p, c"", c"argument -x: invalid int value: 'many'")
	arg_namespace* ns = parse_line(p, c"-x 4")
	assert_ok(ns)
	assert_equal(4, argparse_get_int(ns, c"x"))
	argparse_namespace_free(ns)
	argparse_free(p)


void test_bool_default_and_count_default():
	arg_parser* p = argparse_new(c"bc")
	argparse_arg_default(argparse_add_flag(p, c"--color", 0), c"true")
	argparse_arg_default(argparse_add_count(p, c"-v", 0), c"2")
	arg_namespace* ns = parse_line(p, c"-v")
	assert_ok(ns)
	assert_equal(1, argparse_get_bool(ns, c"color"))
	assert_equal(3, argparse_get_int(ns, c"v"))
	argparse_namespace_free(ns)
	argparse_free(p)


void test_help_text():
	arg_parser* p = sample_parser()
	argparse_epilog(p, c"See the manual.")
	char* help = argparse_help(p)
	assert_strings_equal(c"usage: tool [-h] [-v] -n NAME [-c N] [--ratio RATIO] [-t TAG] input [rest ...]\n\nProcess some files.\n\npositional arguments:\n  input            input file\n  rest             more files\n\noptions:\n  -h, --help       show this help message and exit\n  -v, --verbose    be chatty\n  -n, --name NAME  your name\n  -c, --count N    how many\n  --ratio RATIO    scale factor\n  -t, --tag TAG    repeatable tag\n\nSee the manual.\n", help)
	free(help)
	argparse_free(p)


void test_help_narrow_and_long_invocation():
	arg_parser* p = argparse_new(c"n")
	argparse_add_flag(p, c"-q", c"quiet")
	argparse_add_positional_nargs(p, c"x", ARGPARSE_ONE_OR_MORE, 0)
	argparse_add_positional_nargs(p, c"y", ARGPARSE_OPTIONAL, c"why")
	char* help = argparse_help(p)
	assert_strings_equal(c"usage: n [-h] [-q] x [x ...] [y]\n\npositional arguments:\n  x\n  y           why\n\noptions:\n  -h, --help  show this help message and exit\n  -q          quiet\n", help)
	free(help)
	argparse_add_option(p, c"--a-very-long-option-name", c"VALUE", c"long one")
	help = argparse_help(p)
	assert_contains(help, c"  --a-very-long-option-name VALUE\n                        long one\n")
	assert_contains(help, c"  -q                    quiet\n")
	free(help)
	argparse_free(p)


void test_help_flag():
	arg_parser* p = sample_parser()
	# -h wins even when required arguments are missing.
	arg_namespace* ns = parse_line(p, c"--count 2 -h --bogus")
	assert_equal(1, ns.help)
	assert_equal(0, cast(int, ns.error))
	char* help = argparse_help_for(ns)
	assert_contains(help, c"usage: tool [-h]")
	free(help)
	argparse_namespace_free(ns)
	ns = parse_line(p, c"-vh")
	assert_equal(1, ns.help)
	argparse_namespace_free(ns)
	argparse_free(p)


void test_disable_help():
	arg_parser* p = argparse_new(c"nh")
	argparse_disable_help(p)
	argparse_add_flag(p, c"-h, --host", c"host mode")
	arg_namespace* ns = parse_line(p, c"-h")
	assert_ok(ns)
	assert_equal(1, argparse_get_bool(ns, c"host"))
	argparse_namespace_free(ns)
	char* help = argparse_help(p)
	assert_strings_equal(c"usage: nh [-h]\n\noptions:\n  -h, --host  host mode\n", help)
	free(help)
	argparse_free(p)


void test_error_text():
	arg_parser* p = sample_parser()
	arg_namespace* ns = parse_line(p, c"f")
	char* text = argparse_error_text(ns)
	assert_strings_equal(c"usage: tool [-h] [-v] -n NAME [-c N] [--ratio RATIO] [-t TAG] input [rest ...]\ntool: error: the following arguments are required: -n/--name\n", text)
	free(text)
	argparse_namespace_free(ns)
	ns = parse_line(p, c"-n x f")
	assert_equal(0, cast(int, argparse_error_text(ns)))
	argparse_namespace_free(ns)
	argparse_free(p)


arg_parser* git_parser():
	arg_parser* p = argparse_new(c"git")
	argparse_add_flag(p, c"-C, --chdir", c"change directory")
	arg_parser* commit = argparse_new(c"commit")
	argparse_description(commit, c"Record changes\nLonger text.")
	argparse_arg_required(argparse_add_option(commit, c"-m, --message", c"MSG", c"commit message"))
	argparse_add_flag(commit, c"-a, --all", c"stage everything")
	arg_parser* push = argparse_new(c"push")
	argparse_description(push, c"Update remote refs")
	argparse_arg_default(argparse_add_positional(push, c"remote", c"where to"), c"origin")
	argparse_add_subcommand(p, c"commit", commit)
	argparse_add_subcommand(p, c"push", push)
	return p


void test_subcommands():
	arg_parser* p = git_parser()
	arg_namespace* ns = parse_line(p, c"-C commit -am fix")
	assert_ok(ns)
	assert_strings_equal(c"commit", argparse_command(ns))
	assert_equal(1, argparse_get_bool(ns, c"chdir"))
	assert_equal(1, argparse_get_bool(ns, c"all"))
	assert_strings_equal(c"fix", argparse_get(ns, c"message"))
	assert_strings_equal(c"fix", argparse_get(argparse_subnamespace(ns), c"message"))
	argparse_namespace_free(ns)
	ns = parse_line(p, c"push")
	assert_ok(ns)
	assert_strings_equal(c"push", argparse_command(ns))
	assert_strings_equal(c"origin", argparse_get(ns, c"remote"))
	argparse_namespace_free(ns)
	argparse_free(p)


void test_subcommand_errors():
	arg_parser* p = git_parser()
	assert_error(p, c"", c"the following arguments are required: {commit,push}")
	assert_error(p, c"pull", c"argument {commit,push}: invalid choice: 'pull' (choose from commit, push)")
	assert_error(p, c"commit -a", c"the following arguments are required: -m/--message")
	# Parent options after the subcommand belong to the child, which lacks them.
	assert_error(p, c"push -C", c"unrecognized arguments: -C")
	arg_namespace* ns = parse_line(p, c"commit")
	char* text = argparse_error_text(ns)
	assert_strings_equal(c"usage: git commit [-h] -m MSG [-a]\ngit commit: error: the following arguments are required: -m/--message\n", text)
	free(text)
	argparse_namespace_free(ns)
	argparse_subcommand_optional(p)
	ns = parse_line(p, c"-C")
	assert_ok(ns)
	assert_equal(0, cast(int, argparse_command(ns)))
	argparse_namespace_free(ns)
	argparse_free(p)


void test_subcommand_help():
	arg_parser* p = git_parser()
	char* help = argparse_help(p)
	assert_strings_equal(c"usage: git [-h] [-C] {commit,push} ...\n\npositional arguments:\n  {commit,push}\n    commit       Record changes\n    push         Update remote refs\n\noptions:\n  -h, --help     show this help message and exit\n  -C, --chdir    change directory\n", help)
	free(help)
	arg_namespace* ns = parse_line(p, c"commit --help")
	assert_equal(1, ns.help)
	help = argparse_help_for(ns)
	assert_strings_equal(c"usage: git commit [-h] -m MSG [-a]\n\nRecord changes\nLonger text.\n\noptions:\n  -h, --help         show this help message and exit\n  -m, --message MSG  commit message\n  -a, --all          stage everything\n", help)
	free(help)
	argparse_namespace_free(ns)
	argparse_free(p)


void test_parse_raw_argv():
	arg_parser* p = argparse_new(c"raw")
	argparse_add_int(p, c"-n", 0, 0)
	argparse_add_positional(p, c"file", 0)
	char*[4] argv
	argv[0] = c"raw"
	argv[1] = c"-n"
	argv[2] = c"12"
	argv[3] = c"f.txt"
	arg_namespace* ns = argparse_parse(p, 4, cast(int, &argv[0]))
	assert_ok(ns)
	assert_equal(12, argparse_get_int(ns, c"n"))
	assert_strings_equal(c"f.txt", argparse_get(ns, c"file"))
	argparse_namespace_free(ns)
	args_init(4, cast(int, &argv[0]))
	ns = argparse_parse_args(p)
	assert_ok(ns)
	assert_strings_equal(c"f.txt", argparse_get(ns, c"file"))
	argparse_namespace_free(ns)
	argparse_free(p)
