# wbuild: x64
# wbuild: step="bin/wv2 --safe tests/safe_cli_fixture.w -o bin/safe_cli_fixture"
# wbuild: step="bin/safe_cli_fixture"
# wbuild: step="bin/wv2 tests/safe_cli_fixture.w --safe -o bin/safe_cli_fixture"
# wbuild: step="bin/wv2 check --json --safe tests/safe_cli_fixture.w"
# wbuild: step="bin/wv2 check --json tests/safe_cli_fixture.w --safe"
# wbuild: step="bin/wv2 --help" expect_stdout="--safe"
# wbuild: step="bin/wv2 check --help" expect_stdout="--safe"
# wbuild: step="bin/wv2 --safe --bounds=off tests/safe_cli_fixture.w" expect_fail expect_stderr="--safe cannot be combined with --bounds=off"
# wbuild: step="bin/wv2 --bounds=off tests/safe_cli_fixture.w --safe" expect_fail expect_stderr="--safe cannot be combined with --bounds=off"
# wbuild: step="bin/wv2 --bounds=off --bounds=on --safe tests/safe_cli_fixture.w" expect_fail expect_stderr="--safe cannot be combined with --bounds=off"
# wbuild: step="bin/wv2 --safe --streaming tests/safe_cli_fixture.w" expect_fail expect_stderr="cannot be combined with '--safe'"
# wbuild: step="bin/wv2 --streaming tests/safe_cli_fixture.w --safe" expect_fail expect_stderr="cannot be combined with '--safe'"
# wbuild: step="bin/wv2 check --json --safe --bounds=off tests/safe_cli_fixture.w" expect_fail expect_stdout="<command-line>"
# wbuild: step="bin/wv2 check --json --streaming tests/safe_cli_fixture.w --safe" expect_fail expect_stdout="<command-line>"
# wbuild: step="bin/wv2 repl.w -o bin/safe_cli_repl"
# wbuild: step="bin/safe_cli_repl --safe" expect_fail expect_stderr="--safe is not supported by in-process REPL or debugger sessions"
# wbuild: step="bin/wv2 wdbg.w -o bin/safe_cli_wdbg"
# wbuild: step="bin/safe_cli_wdbg --safe tests/safe_cli_fixture.w" expect_fail expect_stderr="--safe is not supported by in-process REPL or debugger sessions"
import lib.testing
import lib.process
import lib.file


void test_safe_cli_json_conflict_is_structured():
	char** args = strv_new(6)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--json")
	strv_set(args, 3, c"--bounds=off")
	strv_set(args, 4, c"--safe")
	strv_set(args, 5, c"tests/safe_cli_fixture.w")
	process_result* result = process_run(args[0], args, 0, 0, 30000)
	free(cast(void*, args))
	assert1(result != 0)
	assert_equal(1, result.status)
	json_value* diagnostic = json_parse(result.stdout_text)
	assert1(diagnostic != 0)
	assert_strings_equal(c"error", json_get_string(diagnostic, c"severity"))
	assert_strings_equal(c"<command-line>", json_get_string(diagnostic, c"file"))
	assert_strings_equal(c"", result.stderr_text)
	json_free(diagnostic)
	process_result_free(result)
