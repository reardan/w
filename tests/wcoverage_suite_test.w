import lib.testing
import tools.wcoverage_suite


char* suite_env_value(char** env, char* name):
	for i in range(env_vector_count(env)):
		char* entry = env_entry_at(env, i)
		int offset = env_match_name(entry, name)
		if (offset >= 0): return entry + offset
	return c""


void test_suite_preserves_shell_launcher_and_hides_counter_writes():
	list[wcov_suite_build*] builds = wcov_suite_builds(c"bin/coverage")
	char** env = wcov_suite_env(strv_new(0), c"bin/coverage/.dumps", builds)
	assert_strings_equal(c"bin/coverage/repl_x86_cov", suite_env_value(env, c"W_COVERAGE_REPL"))
	assert_strings_equal(c"bin/coverage/wsh_x86_cov", suite_env_value(env, c"W_COVERAGE_WSH"))
	assert_strings_equal(c"bin/coverage/wsh_x64_cov", suite_env_value(env, c"W_COVERAGE_WSH_64"))
	assert_strings_equal(c"bin/coverage/.dumps", suite_env_value(env, c"W_COVERAGE_OUT"))
	int shells = 0
	for wcov_suite_build* b in builds:
		assert1(starts_with(b.dumps, c"bin/coverage/.dumps/"))
		if (strcmp(b.tag, c"wsh") == 0):
			assert_strings_equal(c"wsh.w", b.source)
			shells = shells + 1
	assert_equal(2, shells)


void test_suite_timeout_default_and_caller_override():
	list[wcov_suite_build*] builds = wcov_suite_builds(c"bin/coverage")
	char** base = env_copy_with(strv_new(0), c"UNRELATED", c"kept")
	char** env = wcov_suite_env(base, c"bin/coverage/.dumps", builds)
	assert_strings_equal(c"3600000", suite_env_value(env, c"WEXEC_STEP_TIMEOUT_MS"))
	assert_strings_equal(c"kept", suite_env_value(env, c"UNRELATED"))
	for char* value in list[char*]{c"1234", c"0", c"-1"}:
		base = env_copy_with(base, c"WEXEC_STEP_TIMEOUT_MS", value)
		env = wcov_suite_env(base, c"bin/coverage/.dumps", builds)
		assert_strings_equal(value, suite_env_value(env, c"WEXEC_STEP_TIMEOUT_MS"))
	base = env_copy_with(base, c"WEXEC_STEP_TIMEOUT_MS", c"")
	env = wcov_suite_env(base, c"bin/coverage/.dumps", builds)
	assert_strings_equal(c"3600000", suite_env_value(env, c"WEXEC_STEP_TIMEOUT_MS"))
