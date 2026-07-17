# wbuild: x64
import lib.testing
import lib.shell


list[char*] argv2(char* a0, char* a1):
	list[char*] argv = new list[char*]
	argv.push(a0)
	argv.push(a1)
	return argv


void test_sh_echo_round_trip():
	shell_result* r = sh(c"echo hello from sh")
	assert1(r != 0)
	assert_equal(0, r.status)
	assert_strings_equal(c"hello from sh\x0a", r.out)
	assert_equal(0, r.err_length)
	shell_result_free(r)


void test_sh_nonzero_exit_status_decoded():
	shell_result* r = sh(c"exit 3")
	assert1(r != 0)
	assert_equal(3, r.status)
	shell_result_free(r)


void test_sh_signal_death_decoded():
	# 128 + signum (kill -TERM $$ -> SIGTERM, signal 15), the same
	# convention lib/process.w's process_decode_status documents.
	shell_result* r = sh(c"kill -TERM $$")
	assert1(r != 0)
	assert_equal(143, r.status)
	shell_result_free(r)


void test_sh_captures_stderr_separately():
	shell_result* r = sh(c"echo to-out; echo to-err 1>&2")
	assert1(r != 0)
	assert_equal(0, r.status)
	assert_strings_equal(c"to-out\x0a", r.out)
	assert_strings_equal(c"to-err\x0a", r.err)
	shell_result_free(r)


void test_run_argv_basic():
	shell_result* r = run_argv(argv2(c"/bin/echo", c"hi from run_argv"))
	assert1(r != 0)
	assert_equal(0, r.status)
	assert_strings_equal(c"hi from run_argv\x0a", r.out)
	shell_result_free(r)


void test_run_argv_empty_returns_zero():
	list[char*] empty = new list[char*]
	assert1(run_argv(empty) == 0)


void test_cd_changes_directory():
	char* original = malloc(4096)
	getcwd(original, 4096)

	assert_equal(0, cd(c"/tmp"))
	char* now = malloc(4096)
	getcwd(now, 4096)
	assert_strings_equal(c"/tmp", now)
	free(now)

	# Later sh() calls see the new cwd too.
	shell_result* r = sh(c"pwd")
	assert_equal(0, r.status)
	assert_strings_equal(c"/tmp\x0a", r.out)
	shell_result_free(r)

	assert_equal(0, cd(original))
	free(original)


void test_sh_interactive_exit_status():
	# No capture to assert against here (by design -- see the module
	# comment); the REPL's !cmd repl_test cases cover that the child's
	# output really does reach an inherited stdout. This just checks the
	# decoded exit status, the same convention sh()/run_argv() use.
	assert_equal(0, sh_interactive(c"exit 0"))
	assert_equal(3, sh_interactive(c"exit 3"))


void test_getenv_setenv_round_trip():
	assert1(getenv(c"W_SHELL_TEST_VAR") == 0)

	setenv(c"W_SHELL_TEST_VAR", c"shell-value")
	assert_strings_equal(c"shell-value", getenv(c"W_SHELL_TEST_VAR"))

	# The real process environment lib/env.w reads is untouched.
	assert1(env_get(c"W_SHELL_TEST_VAR") == 0)

	# The session override reaches children spawned through sh().
	shell_result* r = sh(c"echo $W_SHELL_TEST_VAR")
	assert_equal(0, r.status)
	assert_strings_equal(c"shell-value\x0a", r.out)
	shell_result_free(r)
