# Exercise both launcher architectures from one process-capture harness.
# wbuild: binary=wsh_test tag=tests dep=wsh dep=wsh_x64
# wbuild: step="bin/wsh_test"
# wbuild: step="script -qec ./bin/wsh /dev/null" stdin="echo wsh-interactive\n:quit\n" expect_stdout="sh> " expect_stdout="wsh-interactive" reject_stdout="error:"
# wbuild: step="script -qec ./bin/wsh_x64 /dev/null" stdin="echo wsh-interactive64\n:quit\n" expect_stdout="sh> " expect_stdout="wsh-interactive64" reject_stdout="error:"
# The shared frontend must redirect wsh to a shell build, even when REPL
# coverage is also enabled. Keep this regression in the ordinary test suite.
# wbuild: step="bin/wv2 --coverage wsh.w -o bin/wsh_coverage_test"
# wbuild: step="bin/wsh -c false" env="W_COVERAGE_OUT=" env="W_COVERAGE_REPL=bin/no_such_repl_coverage" env="W_COVERAGE_WSH=bin/wsh_coverage_test" expect_status=1
# wbuild: step="bin/wsh -c 'echo covered-shell'" env="W_COVERAGE_OUT=" env="W_COVERAGE_REPL=bin/no_such_repl_coverage" env="W_COVERAGE_WSH=bin/wsh_coverage_test" expect_stdout="covered-shell"
# wbuild: step="bin/wv2 x64 --coverage wsh.w -o bin/wsh_coverage_test64"
# wbuild: step="bin/wsh_x64 -c false" env="W_COVERAGE_OUT=" env="W_COVERAGE_REPL_64=bin/no_such_repl_coverage" env="W_COVERAGE_WSH_64=bin/wsh_coverage_test64" expect_status=1
# wbuild: step="bin/wsh_x64 -c 'echo covered-shell64'" env="W_COVERAGE_OUT=" env="W_COVERAGE_REPL_64=bin/no_such_repl_coverage" env="W_COVERAGE_WSH_64=bin/wsh_coverage_test64" expect_stdout="covered-shell64"
# wbuild: target=wsh dep=wv2 input=wsh.w output=bin/wsh
# wbuild: step="bin/wv2 wsh.w -o bin/wsh"
# wbuild: target=wsh_x64 dep=wv2 input=wsh.w output=bin/wsh_x64
# wbuild: step="bin/wv2 x64 wsh.w -o bin/wsh_x64"
import lib.testing
import lib.process
import lib.file
import structures.json


# argv is passed directly, so the host shell cannot consume the syntax under test.
void wsh_case(char* option, char* command, char* input, int status, char* output):
	int arch = 0
	while (arch < 2):
		char* program = c"bin/wsh"
		if (arch): program = c"bin/wsh_x64"
		int count = 1
		if (option != 0): count = count + 1
		if (command != 0): count = count + 1
		char** argv = strv_new(count)
		strv_set(argv, 0, program)
		if (option != 0): strv_set(argv, 1, option)
		if (command != 0): strv_set(argv, 2, command)
		process_result* result = process_run(program, argv, 0, input, 30000)
		free(cast(void*, argv))
		asserts(c"wsh launched", result != 0)
		if (result.status != status):
			println2(program)
			if (command != 0): println2(command)
			if (input != 0): println2(input)
			print2(result.stderr_text)
		assert_equal(status, result.status)
		if (output != 0): assert_strings_equal(output, result.stdout_text)
		process_result_free(result)
		arch = arch + 1


void test_wsh_command_status():
	wsh_case(c"-c", c"true", 0, 0, c"")
	wsh_case(c"-c", c"false", 0, 1, c"")
	wsh_case(c"-c", c"sh -c 'exit 7'", 0, 7, c"")
	wsh_case(c"-c", c"__wsh_missing_command_335__", 0, 127, c"")
	wsh_case(c"-c", c"", 0, 0, c"")
	wsh_case(c"-c", 0, 0, 2, 0)


void test_wsh_command_lists():
	wsh_case(c"-c", c"false; echo recovered", 0, 0, c"recovered\n")
	wsh_case(c"-c", c"false && echo wrong", 0, 1, c"")
	wsh_case(c"-c", c"false || echo recovered", 0, 0, c"recovered\n")
	wsh_case(c"-c", c"echo first\necho second", 0, 0, c"first\nsecond\n")
	wsh_case(c"-c", c"echo command-only", c"echo must-not-run\n", 0, c"command-only\n")
	wsh_case(c"-c", c"echo command.w", 0, 0, c"command.w\n")


void test_wsh_piped_input_and_exit():
	wsh_case(0, 0, c"", 0, c"")
	wsh_case(0, 0, c"echo piped\n", 0, c"piped\n")
	wsh_case(0, 0, c"false\n", 1, c"")
	wsh_case(0, 0, c"sh -c 'exit 7'\n:quit\n", 7, c"")
	wsh_case(0, 0, c"false\ntrue\n:quit\n", 0, c"")


void test_wsh_w_escape():
	wsh_case(0, 0, c"!int answer = 41\n!answer + 1\necho shell-again\n:quit\n", 0, c"42\nshell-again\n")


void test_wsh_session_state():
	wsh_case(c"-c", c"export WSH_SPACES='two words '; printenv WSH_SPACES", 0, 0, c"two words \n")
	wsh_case(c"-c", c"cd ''", 0, 1, c"")
	wsh_case(c"-c", c"cd /; pwd", 0, 0, c"/\n")
	wsh_case(c"-c", c"export WSH_TEST_VALUE=shared; printenv WSH_TEST_VALUE", 0, 0, c"shared\n")


void test_wsh_native_pipeline():
	wsh_case(c"-c", c"printf pipeline | cat", 0, 0, c"pipeline")
	wsh_case(c"-c", c"true | false", 0, 1, c"")
	wsh_case(c"-c", c"false | true", 0, 0, c"")


void test_wsh_find_and_sed_translation():
	char* dir = f"bin/wsh_tools_{getpid()}"
	assert_equal(0, mkdir(dir, 493))
	char* path = f"{dir}/sample.txt"
	assert1(file_write_text(path, c"alpha\nbeta\n"))
	wsh_case(c"-c", f"find {dir} -name '*.txt' -type f -mindepth 1 -maxdepth 2 -print", 0, 0, f"{path}\n")
	wsh_case(c"-c", f"find {dir} -type d -maxdepth 0", 0, 0, f"{dir}\n")
	wsh_case(c"-c", f"find {dir} -type l", 0, 0, c"")
	wsh_case(c"-c", f"sed 's/a/A/g' {path}", 0, 0, c"AlphA\nbetA\n")
	wsh_case(c"-c", f"sed -n p {path}", 0, 0, c"alpha\nbeta\n")
	wsh_case(c"-c", f"cat {path} | sed d", 0, 0, c"")
	# Unsupported forms must retain the external tool's behavior.
	wsh_case(c"-c", f"find {dir} -maxdepth 0 -name '*' -name '*'", 0, 0, f"{dir}\n")
	wsh_case(c"-c", f"sed -n '1p' {path}", 0, 0, c"alpha\n")
	unlink(path)
	assert_equal(0, rmdir(dir))
	free(path)
	free(dir)


void test_wsh_mode_toggle_and_function_pipeline():
	# Toggle into W to define a multiline function, then back into shell syntax.
	# Toggle messages are part of the shared REPL UI, so assert these separately.
	char* input = c":sh\nint wsh_emit():\n\tprintln(c\"function-pipeline\")\n\treturn 0\n\n:sh\nwsh_emit | cat\n:quit\n"
	int arch = 0
	while (arch < 2):
		char* program = c"bin/wsh"
		if (arch): program = c"bin/wsh_x64"
		char** argv = strv_new(1)
		strv_set(argv, 0, program)
		process_result* result = process_run(program, argv, 0, input, 30000)
		free(cast(void*, argv))
		asserts(c"wsh launched", result != 0)
		assert_equal(0, result.status)
		assert_contains(result.stdout_text, c"function-pipeline\n")
		assert_lacks(result.stderr_text, c"error:")
		process_result_free(result)
		arch = arch + 1


void test_wsh_help():
	int arch = 0
	while (arch < 2):
		char* program = c"bin/wsh"
		if (arch): program = c"bin/wsh_x64"
		char** argv = strv_new(2)
		strv_set(argv, 0, program)
		strv_set(argv, 1, c"--help")
		process_result* result = process_run(program, argv, 0, c"echo must-not-run\n", 30000)
		free(cast(void*, argv))
		asserts(c"wsh help launched", result != 0)
		assert_equal(0, result.status)
		assert_contains(result.stdout_text, c"wsh")
		assert_contains(result.stdout_text, c"-c")
		assert_lacks(result.stdout_text, c"must-not-run")
		process_result_free(result)
		argv = strv_new(1)
		strv_set(argv, 0, program)
		result = process_run(program, argv, 0, c":help\n:quit\n", 30000)
		free(cast(void*, argv))
		assert1(result != 0)
		assert_equal(0, result.status)
		assert_contains(result.stdout_text, c":sh                 toggle shell mode")
		assert_contains(result.stdout_text, c":quit               exit the repl")
		process_result_free(result)
		arch = arch + 1


void test_wsh_json_pipeline():
	char* command = c"printf json-output | cat; sh -c 'printf json-error >&2; exit 7'"
	int arch = 0
	while (arch < 2):
		char* program = c"bin/wsh"
		if (arch): program = c"bin/wsh_x64"
		char** argv = strv_new(4)
		strv_set(argv, 0, program)
		strv_set(argv, 1, c"--json")
		strv_set(argv, 2, c"-c")
		strv_set(argv, 3, command)
		process_result* result = process_run(program, argv, 0, 0, 30000)
		free(cast(void*, argv))
		asserts(c"wsh JSON launched", result != 0)
		assert_equal(7, result.status)
		json_value* record = json_parse(result.stdout_text)
		asserts(c"wsh emits a JSON record", record != 0)
		assert_strings_equal(command, json_object_get(record, c"entry").string_value)
		assert_strings_equal(c"json-output", json_object_get(record, c"output").string_value)
		assert_strings_equal(c"json-error", json_object_get(record, c"stderr").string_value)
		assert_equal(7, json_object_get(record, c"status").int_value)
		assert_equal(json_type_null(), json_object_get(record, c"echo").type)
		assert_equal(json_type_null(), json_object_get(record, c"error").type)
		json_free(record)
		process_result_free(result)
		arch = arch + 1


# Capture a whole launcher session, checking stderr as well as stdout. All
# filesystem fixtures below live under bin/ and include this harness's PID.
void wsh_adversarial_case(list[char*] arguments, char* input, int status, char* output, char* error):
	for arch in range(2):
		char* program = c"bin/wsh"
		if (arch): program = c"bin/wsh_x64"
		char** argv = strv_new(arguments.length + 1)
		strv_set(argv, 0, program)
		for i in range(arguments.length): strv_set(argv, i + 1, arguments[i])
		process_result* result = process_run(program, argv, 0, input, 30000)
		free(cast(void*, argv))
		asserts(c"adversarial wsh launched", result != 0)
		if ((result.status != status) || (strcmp(output, result.stdout_text) != 0)):
			println2(program)
			print2(result.stderr_text)
		assert_equal(status, result.status)
		assert_strings_equal(output, result.stdout_text)
		if (error != 0): assert_contains(result.stderr_text, error)
		process_result_free(result)


void test_wsh_adversarial_option_values():
	wsh_case(c"-c=echo inline.w", 0, 0, 0, c"inline.w\n")
	wsh_case(c"--c=echo long-inline.w", 0, 0, 0, c"long-inline.w\n")
	# /bin/sh rejects a command string beginning -- as an illegal option;
	# the diagnostic must come from that shell, not the launcher's parser.
	wsh_adversarial_case(list[char*]{c"-c", c"--help"}, 0, 2, c"", c"/bin/sh:")
	wsh_adversarial_case(list[char*]{c"-c", c"--json"}, 0, 2, c"", c"/bin/sh:")
	wsh_adversarial_case(list[char*]{c"-c", c"--quiet"}, 0, 2, c"", c"/bin/sh:")
	wsh_adversarial_case(list[char*]{c"-c", c"--ast-required"}, 0, 2, c"", c"/bin/sh:")
	wsh_case(c"-c=", 0, c"echo must-not-run\n", 0, c"")


void test_wsh_adversarial_multiple_native_stages():
	char* input = c":sh\nint wsh_produce():\n\tprintln(c\"multi-stage\")\n\treturn 0\n\nint wsh_forward():\n\treturn shell_commands_cat()\n\n:sh\nwsh_produce | wsh_forward | cat\nwsh_produce | cat | wsh_forward\nwsh_produce\n:quit\n"
	wsh_case(0, 0, input, 0, c"shell mode off\nshell mode on (:sh to leave, ! runs one line of W)\nmulti-stage\nmulti-stage\nmulti-stage\n")


void test_wsh_adversarial_loaded_generics_pipeline():
	char* path = f"bin/wsh_generic_{getpid()}.w"
	char* source = c"import lib.lib\nT wsh_twice[T](T value):\n\treturn value + value\nint wsh_loaded(int value):\n\tprintln(itoa(wsh_twice[int](value)))\n\treturn 0\nint main():\n\treturn 0\n"
	asserts(c"write generic startup fixture", file_write_text(path, source))
	wsh_adversarial_case(list[char*]{path}, c"wsh_loaded 21 | cat | cat\nwsh_loaded 9 | cat\nwsh_loaded 7\n:quit\n", 0, c"42\n18\n14\n", 0)
	unlink(path)
	free(path)


void test_wsh_adversarial_redirect_order_and_append():
	char* path = f"bin/wsh_redirect_{getpid()}.txt"
	char* command = f"sh -c 'printf out; printf err >&2' > {path} 2>&1; cat {path}; echo restored"
	wsh_case(c"-c", command, 0, 0, c"outerrrestored\n")
	free(command)
	command = f"sh -c 'printf out; printf err >&2' 2>&1 > {path}; cat {path}; echo restored"
	wsh_case(c"-c", command, 0, 0, c"erroutrestored\n")
	free(command)
	command = f"echo first > {path}; echo second >> {path}; sh -c 'printf third >&2' 2>> {path}; cat < {path}; echo restored"
	wsh_case(c"-c", command, 0, 0, c"first\nsecond\nthirdrestored\n")
	free(command)
	unlink(path)
	free(path)


void test_wsh_adversarial_redirect_failure_restores_parent():
	char* path = f"bin/wsh_restore_{getpid()}.txt"
	# The first redirect succeeds, the second fails: neither the command
	# body nor later stdout/stderr may remain attached to the opened file.
	char* command = f"echo hidden > {path} 2> {path}/missing; echo restored; sh -c 'printf restored-error >&2'"
	wsh_adversarial_case(list[char*]{c"-c", command}, 0, 0, c"restored\n", c"restored-error")
	char* content = file_read_text(path)
	assert_strings_equal(c"", content)
	free(content)
	free(command)
	# Repeat with stdin redirection in a prompt session: the next entry
	# must still be read from the original pipe after the failed command.
	char* input = f"cat < {path}/missing\necho input-restored\n:quit\n"
	wsh_adversarial_case(new list[char*], input, 0, c"input-restored\n", c"cannot open")
	free(input)
	unlink(path)
	free(path)


void test_wsh_adversarial_malformed_has_no_side_effects():
	char* path = f"bin/wsh_never_created_{getpid()}.txt"
	unlink(path)
	char* command = f"echo forbidden > {path}; echo bad >"
	wsh_case(c"-c", command, 0, 2, c"")
	asserts(c"malformed line must not create an earlier redirect", open(path, 0, 0) < 0)
	free(command)
	wsh_case(c"-c", c"echo forbidden; echo 'unterminated", 0, 2, c"")
	wsh_case(c"-c", c"echo forbidden; true |", 0, 2, c"")
	free(path)


void test_wsh_adversarial_unsupported_whole_line():
	# A session override makes partial native execution observable. The
	# prefix 'echo before' must also go to /bin/sh for each unsupported line.
	char* input = c":sh\nint echo(char* word):\n\tprintln(c\"session-override\")\n\treturn 0\n\n:sh\necho before; (echo subshell)\necho before; echo $(printf expanded)\necho before; if true; then echo conditional; fi\necho native\n:quit\n"
	wsh_case(0, 0, input, 0, c"shell mode off\nshell mode on (:sh to leave, ! runs one line of W)\nbefore\nsubshell\nbefore\nexpanded\nbefore\nconditional\nsession-override\n")


void test_wsh_adversarial_assignment_list():
	wsh_case(c"-c", c"WSH_TEMP=value; printf '%s' \"$WSH_TEMP\"", 0, 0, c"value")


void test_wsh_adversarial_early_pipeline_consumer():
	wsh_case(c"-c", c"yes | head -n 1", 0, 0, c"y\n")
