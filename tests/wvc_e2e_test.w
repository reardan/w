/*
tools/wvc.w: end-to-end porcelain test (issue #252 V2c). Hand-written
(build.base.json, not wbuildgen's convention) because it needs "wvc"
itself built first and spawns it as a real subprocess against a real
temp directory, rather than just linking against a library and running
in-process like the vcs_{cas,tree,commit,dag,diff}_test.w unit tests.

Exercises init -> snapshot -> status -> snapshot -> log -> diff against
one fixture directory under bin/ (pid-scoped, like the vcs_*_test.w
roots, so parallel runs never collide), then two small usage-error
checks that need no fixture. process_run (lib.process) spawns the
compiled bin/wvc and captures stdout/status; `log`/`diff` take no <dir>
argument (wvc.w's header comment: they operate on "<cwd>/.wvc"), so
those two calls set spawn_options.cwd to the fixture directory and pass
an ABSOLUTE path to the wvc binary -- chdir happens before execve in
process_spawn, so a relative binary path would resolve against the NEW
cwd otherwise.
*/
import lib.testing
import lib.process
import lib.path
import lib.file
import structures.string
import libs.extras.vcs.cas


char* wvct_repo_root_cache
char* wvct_repo_root():
	if (wvct_repo_root_cache == 0):
		char* buf = malloc(4096)
		int n = getcwd(buf, 4096)
		assert1(n > 0)
		wvct_repo_root_cache = buf
	return wvct_repo_root_cache


char* wvct_bin_cache
char* wvct_bin():
	if (wvct_bin_cache == 0):
		wvct_bin_cache = path_join(wvct_repo_root(), c"bin/wvc")
	return wvct_bin_cache


char* wvct_dir_cache
char* wvct_dir():
	if (wvct_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_e2e_test_")
		string_append_int(p, getpid())
		wvct_dir_cache = p.data
		free(p)
	return wvct_dir_cache


char** wvct_argv(list[char*] args):
	char** v = strv_new(args.length)
	int i = 0
	for char* a in args:
		strv_set(v, i, a)
		i = i + 1
	return v


process_result* wvct_run(list[char*] args, char* cwd):
	spawn_options* opts = 0
	if (cwd != 0):
		opts = spawn_options_new()
		opts.cwd = cwd
	char** argv = wvct_argv(args)
	process_result* r = process_run(wvct_bin(), argv, opts, 0, 10000)
	assert1(r != 0)
	if (opts != 0):
		free(opts)
	free(cast(void*, argv))
	return r


int wvct_index_of(char* haystack, char* needle):
	int hl = strlen(haystack)
	int nl = strlen(needle)
	if (nl == 0):
		return 0
	int i = 0
	while ((i + nl) <= hl):
		int j = 0
		while ((j < nl) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == nl):
			return i
		i = i + 1
	return -1


void wvct_assert_contains(char* haystack, char* needle):
	int found = wvct_index_of(haystack, needle) >= 0
	if (found == 0):
		wstream* err = stderr_writer()
		stream_write_cstr(err, c"expected to find '")
		stream_write_cstr(err, needle)
		stream_write_cstr(err, c"' in: ")
		stream_write_line(err, haystack)
		stream_flush(err)
	assert1(found)


# Strips a single trailing '\n' (and a preceding '\r' for good measure):
# `wvc snapshot` prints the commit id via stream_write_line.
char* wvct_trim(char* s):
	char* out = strclone(s)
	int n = strlen(out)
	while ((n > 0) && ((out[n - 1] == 10) || (out[n - 1] == 13))):
		n = n - 1
		out[n] = 0
	return out


void test_wvc_end_to_end():
	char* dir = wvct_dir()

	# Best-effort cleanup from a previous failed run.
	list[char*] preclean = new list[char*]
	preclean.push(c"/bin/rm")
	preclean.push(c"-rf")
	preclean.push(dir)
	char** preclean_argv = wvct_argv(preclean)
	process_result* pre = process_run(c"/bin/rm", preclean_argv, 0, 0, 10000)
	if (pre != 0):
		process_result_free(pre)
	free(cast(void*, preclean_argv))

	list[char*] init_args = new list[char*]
	init_args.push(c"wvc")
	init_args.push(c"init")
	init_args.push(dir)
	process_result* r_init = wvct_run(init_args, 0)
	assert_equal(0, r_init.status)
	wvct_assert_contains(r_init.stdout_text, c"Initialized empty wvc repository")
	process_result_free(r_init)

	char* a_path = path_join(dir, c"a.txt")
	char* b_path = path_join(dir, c"b.txt")
	assert_equal(1, file_write_text(a_path, c"hello\n"))
	assert_equal(1, file_write_text(b_path, c"world\n"))

	list[char*] snap1_args = new list[char*]
	snap1_args.push(c"wvc")
	snap1_args.push(c"snapshot")
	snap1_args.push(dir)
	snap1_args.push(c"-m")
	snap1_args.push(c"first commit")
	process_result* r_snap1 = wvct_run(snap1_args, 0)
	assert_equal(0, r_snap1.status)
	char* commit1 = wvct_trim(r_snap1.stdout_text)
	assert1(cas_valid_id(commit1))
	process_result_free(r_snap1)

	# Modify a.txt, remove b.txt, add c.txt.
	assert_equal(1, file_write_text(a_path, c"hello world\n"))
	assert_equal(0, unlink(b_path))
	char* c_path = path_join(dir, c"c.txt")
	assert_equal(1, file_write_text(c_path, c"new file\n"))

	list[char*] status_args = new list[char*]
	status_args.push(c"wvc")
	status_args.push(c"status")
	status_args.push(dir)
	process_result* r_status = wvct_run(status_args, 0)
	assert_equal(0, r_status.status)
	wvct_assert_contains(r_status.stdout_text, c"M a.txt")
	wvct_assert_contains(r_status.stdout_text, c"D b.txt")
	wvct_assert_contains(r_status.stdout_text, c"A c.txt")
	process_result_free(r_status)

	list[char*] snap2_args = new list[char*]
	snap2_args.push(c"wvc")
	snap2_args.push(c"snapshot")
	snap2_args.push(dir)
	snap2_args.push(c"-m")
	snap2_args.push(c"second commit")
	snap2_args.push(c"-a")
	snap2_args.push(c"Test Author")
	process_result* r_snap2 = wvct_run(snap2_args, 0)
	assert_equal(0, r_snap2.status)
	char* commit2 = wvct_trim(r_snap2.stdout_text)
	assert1(cas_valid_id(commit2))
	process_result_free(r_snap2)

	# Nothing changed since the second snapshot: status is clean.
	list[char*] status2_args = new list[char*]
	status2_args.push(c"wvc")
	status2_args.push(c"status")
	status2_args.push(dir)
	process_result* r_status2 = wvct_run(status2_args, 0)
	assert_equal(0, r_status2.status)
	wvct_assert_contains(r_status2.stdout_text, c"nothing to snapshot, working tree clean")
	process_result_free(r_status2)

	# log runs with cwd = dir (no <dir> argument on this subcommand).
	list[char*] log_args = new list[char*]
	log_args.push(c"wvc")
	log_args.push(c"log")
	process_result* r_log = wvct_run(log_args, dir)
	assert_equal(0, r_log.status)
	wvct_assert_contains(r_log.stdout_text, commit1)
	wvct_assert_contains(r_log.stdout_text, commit2)
	wvct_assert_contains(r_log.stdout_text, c"first commit")
	wvct_assert_contains(r_log.stdout_text, c"second commit")
	wvct_assert_contains(r_log.stdout_text, c"Test Author")
	# Oldest-parent-last: commit2 (newest) prints before commit1.
	assert1(wvct_index_of(r_log.stdout_text, commit2) < wvct_index_of(r_log.stdout_text, commit1))
	process_result_free(r_log)

	# diff also runs with cwd = dir; revs are the two commit ids.
	list[char*] diff_args = new list[char*]
	diff_args.push(c"wvc")
	diff_args.push(c"diff")
	diff_args.push(commit1)
	diff_args.push(commit2)
	process_result* r_diff = wvct_run(diff_args, dir)
	assert_equal(0, r_diff.status)
	wvct_assert_contains(r_diff.stdout_text, c"M a.txt")
	wvct_assert_contains(r_diff.stdout_text, c"D b.txt")
	wvct_assert_contains(r_diff.stdout_text, c"A c.txt")
	# The modified-file nice-to-have: a real unified line diff for a.txt.
	wvct_assert_contains(r_diff.stdout_text, c"-hello")
	wvct_assert_contains(r_diff.stdout_text, c"+hello world")
	process_result_free(r_diff)

	# diff also accepts the ref name "main" as a rev.
	list[char*] diff_ref_args = new list[char*]
	diff_ref_args.push(c"wvc")
	diff_ref_args.push(c"diff")
	diff_ref_args.push(c"main")
	diff_ref_args.push(c"main")
	process_result* r_diff_ref = wvct_run(diff_ref_args, dir)
	assert_equal(0, r_diff_ref.status)
	assert_equal(0, r_diff_ref.stdout_length)
	process_result_free(r_diff_ref)

	free(commit1)
	free(commit2)
	free(a_path)
	free(b_path)
	free(c_path)

	list[char*] postclean = new list[char*]
	postclean.push(c"/bin/rm")
	postclean.push(c"-rf")
	postclean.push(dir)
	char** postclean_argv = wvct_argv(postclean)
	process_result* post = process_run(c"/bin/rm", postclean_argv, 0, 0, 10000)
	assert1(post != 0)
	assert_equal(0, post.status)
	process_result_free(post)
	free(cast(void*, postclean_argv))


void test_wvc_usage_errors():
	list[char*] no_args = new list[char*]
	no_args.push(c"wvc")
	process_result* r_none = wvct_run(no_args, 0)
	assert_equal(2, r_none.status)
	process_result_free(r_none)

	list[char*] bogus_args = new list[char*]
	bogus_args.push(c"wvc")
	bogus_args.push(c"bogus")
	process_result* r_bogus = wvct_run(bogus_args, 0)
	assert_equal(2, r_bogus.status)
	process_result_free(r_bogus)


void test_wvc_status_on_missing_repo_fails():
	list[char*] args = new list[char*]
	args.push(c"wvc")
	args.push(c"status")
	args.push(c"bin/wvc_e2e_test_no_such_dir")
	process_result* r = wvct_run(args, 0)
	assert_equal(1, r.status)
	wvct_assert_contains(r.stderr_text, c"wvc: cannot open object store")
	process_result_free(r)
