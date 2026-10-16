# wbuild: target=wgrind_test tag=tests dep=wv2 dep=wgrind
# wbuild: step="bin/wv2 tests/wgrind_fixture.w -o bin/wgrind_fixture"
# wbuild: step="bin/wv2 x64 tests/wgrind_fixture.w -o bin/wgrind_fixture_x64"
# wbuild: step="bin/wv2 x64 tests/wgrind_c_fixture.w -o bin/wgrind_c_fixture"
# wbuild: step="bin/wv2 tests/safe_runtime_fixture.w -o bin/wgrind_safe_fixture"
# wbuild: step="bin/wv2 x64 tests/safe_runtime_fixture.w -o bin/wgrind_safe_fixture_x64"
# wbuild: step="bin/wv2 tests/wgrind_test.w -o bin/wgrind_test"
# wbuild: step="bin/wgrind_test" expect_stdout="wgrind_test: OK" timeout=120000
# wbuild: step="bin/wgrind_fixture clean" env="W_DEBUG_ALLOC=valgrind" expect_status=1 expect_stderr="valgrind mode requires Valgrind"
# wbuild: step="bin/wgrind --help" expect_stderr="usage: wgrind"
# wbuild: step="bin/wgrind" expect_status=2 expect_stderr="usage: wgrind"
import lib.assert
import lib.process
import lib.ci_skip


void grind_case(char* binary, char* scenario, int native, int status, char* diagnostic):
	char** args = strv_new(4)
	strv_set(args, 0, c"bin/wgrind")
	int at = 1
	if (native):
		strv_set(args, at, c"--native")
		at = at + 1
	strv_set(args, at, binary)
	strv_set(args, at + 1, scenario)
	process_result* r = process_run(c"bin/wgrind", args, 0, 0, 30000)
	if (r.status != status):
		println2(scenario)
		println2(r.stderr_text)
		assert_equal(status, r.status)
	if (diagnostic != 0): assert_contains(r.stderr_text, diagnostic)
	process_result_free(r)
	free(cast(void*, args))


int main():
	for arch in range(2):
		char* binary = c"bin/wgrind_fixture"
		if (arch): binary = c"bin/wgrind_fixture_x64"
		grind_case(binary, c"underflow", 1, 1, c"heap buffer underflow")
		grind_case(binary, c"underflow_realloc", 1, 1, c"heap buffer underflow")
		grind_case(binary, c"underflow_report", 1, 1, c"heap buffer underflow")
		grind_case(binary, c"overflow", 1, 1, c"heap buffer overflow")
		grind_case(binary, c"clean", 1, 0, 0)
		grind_case(binary, c"churn", 1, 0, 0)
		grind_case(binary, c"status", 1, 7, 0)
		grind_case(binary, c"argument with spaces", 1, 0, 0)
	char* vg = process_which(c"valgrind")
	if (vg == 0):
		test_skip(c"SKIP: Memcheck integration (valgrind not installed)")
	else:
		for arch in range(2):
			char* binary = c"bin/wgrind_fixture"
			if (arch): binary = c"bin/wgrind_fixture_x64"
			grind_case(binary, c"clean", 0, 0, c"ERROR SUMMARY: 0 errors")
			grind_case(binary, c"churn", 0, 0, c"ERROR SUMMARY: 0 errors")
			grind_case(binary, c"underflow", 0, 99, c"Invalid write of size 1")
			grind_case(binary, c"underflow_read", 0, 99, c"Invalid read of size 1")
			grind_case(binary, c"overflow", 0, 99, c"Invalid write of size 1")
			grind_case(binary, c"uaf", 0, 99, c"Invalid write of size 1")
			grind_case(binary, c"uninitialized", 0, 99, c"Uninitialised value was created by a heap allocation")
			grind_case(binary, c"forced_uninitialized", 0, 99, c"Uninitialised value was created by a heap allocation")
			grind_case(binary, c"reused_uninitialized", 0, 99, c"Uninitialised value was created by a heap allocation")
			grind_case(binary, c"realloc_undefined", 0, 99, c"uninitialised value(s)")
			grind_case(binary, c"realloc_tail", 0, 99, c"uninitialised value(s)")
			grind_case(binary, c"leak", 0, 99, c"13 bytes in 1 blocks")
			grind_case(binary, c"status", 0, 7, c"ERROR SUMMARY: 0 errors")
			grind_case(binary, c"argument with spaces", 0, 0, c"ERROR SUMMARY: 0 errors")
			grind_case(binary, c"double_free", 0, 99, c"double free() detected")
			grind_case(binary, c"bad_oldlen", 0, 99, c"realloc() oldlen does not match")
		grind_case(c"bin/wgrind_c_fixture", c"unused", 0, 99, c"Invalid write of size 1")
		grind_case(c"bin/wgrind_safe_fixture", c"unused", 0, 0, c"ERROR SUMMARY: 0 errors")
		grind_case(c"bin/wgrind_safe_fixture_x64", c"unused", 0, 0, c"ERROR SUMMARY: 0 errors")
		free(vg)
	println(c"wgrind_test: OK")
	return 0
