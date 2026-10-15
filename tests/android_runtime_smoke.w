# wbuild: target=android_runtime_compile_test tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64_android tests/android_runtime_smoke.w -o bin/android_runtime_smoke"
# wbuild: target=android_runtime_test tag=tests_android dep=wv2
# wbuild: step="bin/wv2_android arm64_android tests/android_runtime_smoke.w -o bin/android_runtime_smoke"
# wbuild: step="bin/android_runtime_smoke" expect_stdout="android_runtime_smoke: OK"
# Run from the repository in Termux private storage, or a writable adb
# shell directory. It deliberately uses no /tmp or desktop shell paths.
import lib.assert
import lib.process
import lib.shell
import lib.stat
import lib.dir
import lib.page_size


int main(int argc, int argv):
	if (argc == 2):
		println(c"child OK")
		return 7
	assert_equal(1, os_android())
	asserts(c"kernel page size", runtime_page_size_valid(runtime_page_size()))
	int page = runtime_page_size()
	char* p = cast(char*, debug_malloc(page + 8))
	asserts(c"debug malloc", p != 0)
	p[0] = 11
	p[page + 7] = 22
	assert_equal(11, p[0])
	assert_equal(22, p[page + 7])
	assert_equal(0, (cast(int, p) + page + 8) % page)
	int idx = debug_tbl_find(cast(int, p))
	assert_equal(2 * page, debug_tbl_region_size[idx])
	# A reserved PROT_NONE guard stays mapped; exercise the protection
	# in a child so an overflow cannot terminate the test runner.
	int child = fork()
	asserts(c"fork guard probe", child >= 0)
	if (child == 0):
		p[page + 8] = 1
		exit(0)
	int status = 0
	assert_equal(child, wait4(child, &status, 0, 0))
	assert_equal(11, status & 127)
	debug_free(p)
	debug_quarantine_reclaim_to(0)

	char** args = cast(char**, argv)
	file_stat info
	assert_equal(0, file_stat_path(args[0], &info))
	asserts(c"own executable is a nonempty file", file_is_reg(&info) && (info.size > 0))
	assert_equal(0, file_stat_path(c".", &info))
	asserts(c"current directory", file_is_dir(&info))
	char** child_args = strv_new(2)
	strv_set(child_args, 0, args[0])
	strv_set(child_args, 1, c"child")
	process_result* result = process_run(args[0], child_args, 0, 0, 5000)
	asserts(c"spawn child", result != 0)
	assert_equal(7, result.status)
	assert_strings_equal(c"child OK\x0a", result.stdout_text)
	process_result_free(result)
	free(cast(void*, child_args))

	shell_result* shell = sh(c"printf shell-ok")
	asserts(c"Android shell", shell != 0)
	assert_equal(0, shell.status)
	assert_strings_equal(c"shell-ok", shell.out)
	shell_result_free(shell)
	println(c"android_runtime_smoke: OK")
	return 0
