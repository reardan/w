/*
tools/wvc.w: end-to-end porcelain test (issue #252 V2c, extended for
wave 4's `merge`). Generated (wbuildgen's convention), via the
'# wbuild: tool=tools/wvc.w' directive below, which adds "wvc" itself
(built first) to this target's "deps" -- this test spawns it as a real
subprocess against a real temp directory, rather than just linking
against a library and running in-process like the
vcs_{cas,tree,commit,dag,diff,merge3}_test.w unit tests.

Exercises init -> snapshot -> status -> snapshot -> log -> diff against
one fixture directory under bin/ (pid-scoped, like the vcs_*_test.w
roots, so parallel runs never collide), then two small usage-error
checks that need no fixture. process_run (lib.process) spawns the
compiled bin/wvc and captures stdout/status; `log`/`diff`/`merge` take no
<dir> argument (wvc.w's header comment: they operate on "<cwd>/.wvc"),
so those calls set spawn_options.cwd to the fixture directory and pass
an ABSOLUTE path to the wvc binary -- chdir happens before execve in
process_spawn, so a relative binary path would resolve against the NEW
cwd otherwise.

The merge tests (test_wvc_merge_clean/test_wvc_merge_conflict) need a
genuinely divergent commit graph, but this wave's `wvc` porcelain has no
branch/checkout/reset command to produce one through the CLI alone (only
a single ref, "main", ever moves, always forward from its own current
tip -- see wvc.w's header comment). So "theirs" is built directly
against the SAME on-disk object store the `wvc` subprocess calls use
(cas_open/commit_new/commit_store/tree_snapshot, imported here exactly
like the vcs_*_test.w unit tests do), as a sibling commit whose parent is
the shared base rather than the branch `wvc snapshot` already advanced
"main" past -- never registered under any ref, since `merge <rev>`
accepts a bare 64-hex commit id.
*/
# wbuild: tool=tools/wvc.w
import lib.testing
import lib.process
import lib.path
import lib.file
import lib.time
import lib.result
import lib.container
import structures.string
import libs.extras.vcs.cas
import libs.extras.vcs.tree
import libs.extras.vcs.commit


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


char* wvct_index_dir_cache
char* wvct_index_dir():
	if (wvct_index_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_index_e2e_test_")
		string_append_int(p, getpid())
		wvct_index_dir_cache = p.data
		free(p)
	return wvct_index_dir_cache


# Wave 3 (issue #252, libs/extras/vcs/index.w): proves the fast-path/
# fallback wiring in tools/wvc.w end to end, not just the library in
# isolation (vcs_index_test.w covers the library). `snapshot` refreshes
# ".wvc/index"; `status` uses it when readable (touching exactly one
# tracked file among several is reported as exactly that one change,
# nothing else), and falls back to the pre-index-era slow path -- with
# no crash and the same correct report -- when the index file is
# deleted out from under it.
void test_wvc_status_fast_path_and_index_fallback():
	char* dir = wvct_index_dir()

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
	process_result_free(r_init)

	char* a_path = path_join(dir, c"a.txt")
	char* b_path = path_join(dir, c"b.txt")
	char* c_path = path_join(dir, c"c.txt")
	assert_equal(1, file_write_text(a_path, c"alpha\n"))
	assert_equal(1, file_write_text(b_path, c"beta\n"))
	assert_equal(1, file_write_text(c_path, c"gamma\n"))

	list[char*] snap_args = new list[char*]
	snap_args.push(c"wvc")
	snap_args.push(c"snapshot")
	snap_args.push(dir)
	snap_args.push(c"-m")
	snap_args.push(c"first commit")
	process_result* r_snap = wvct_run(snap_args, 0)
	assert_equal(0, r_snap.status)
	process_result_free(r_snap)

	# snapshot refreshed (created) the dirstate.
	char* index_path = path_join(dir, c".wvc/index")
	assert_equal(1, path_exists(index_path))

	# Touch exactly one of the three tracked files.
	assert_equal(1, file_write_text(b_path, c"beta-changed\n"))

	list[char*] status_args = new list[char*]
	status_args.push(c"wvc")
	status_args.push(c"status")
	status_args.push(dir)
	process_result* r_status = wvct_run(status_args, 0)
	assert_equal(0, r_status.status)
	wvct_assert_contains(r_status.stdout_text, c"M b.txt")
	assert_equal(-1, wvct_index_of(r_status.stdout_text, c"a.txt"))
	assert_equal(-1, wvct_index_of(r_status.stdout_text, c"c.txt"))
	process_result_free(r_status)

	# Re-running status with nothing further changed reports the exact
	# same single change again -- status's own write-back of the
	# refreshed index (it persists what it just computed) does not
	# desync itself or spuriously flag anything else.
	process_result* r_status2 = wvct_run(status_args, 0)
	assert_equal(0, r_status2.status)
	wvct_assert_contains(r_status2.stdout_text, c"M b.txt")
	assert_equal(-1, wvct_index_of(r_status2.stdout_text, c"a.txt"))
	assert_equal(-1, wvct_index_of(r_status2.stdout_text, c"c.txt"))
	process_result_free(r_status2)

	# Snapshotting now (committing b.txt's change) and checking status
	# again DOES go clean -- confirms the fast path's refreshed tree id
	# was correct all along, not just "some non-empty diff".
	list[char*] snap2_args = new list[char*]
	snap2_args.push(c"wvc")
	snap2_args.push(c"snapshot")
	snap2_args.push(dir)
	snap2_args.push(c"-m")
	snap2_args.push(c"second commit")
	process_result* r_snap2 = wvct_run(snap2_args, 0)
	assert_equal(0, r_snap2.status)
	process_result_free(r_snap2)
	process_result* r_status_clean = wvct_run(status_args, 0)
	assert_equal(0, r_status_clean.status)
	wvct_assert_contains(r_status_clean.stdout_text, c"nothing to snapshot, working tree clean")
	process_result_free(r_status_clean)

	# Delete the dirstate: status must still work, via the slow path.
	assert_equal(0, unlink(index_path))
	assert_equal(1, file_write_text(a_path, c"alpha-changed\n"))
	process_result* r_status3 = wvct_run(status_args, 0)
	assert_equal(0, r_status3.status)
	wvct_assert_contains(r_status3.stdout_text, c"M a.txt")
	process_result_free(r_status3)
	# The slow path does not itself recreate the index (only `snapshot`
	# does -- see wvc.w's header comment).
	assert_equal(0, path_exists(index_path))

	free(a_path)
	free(b_path)
	free(c_path)
	free(index_path)

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


/* wvc merge (wave 4, issue #252) -- see the header comment for why
   "theirs" is built directly against the object store rather than
   through the `wvc` subprocess. */


void wvct_rm_rf(char* path):
	list[char*] args = new list[char*]
	args.push(c"/bin/rm")
	args.push(c"-rf")
	args.push(path)
	char** argv = wvct_argv(args)
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 10000)
	if (r != 0):
		process_result_free(r)
	free(cast(void*, argv))


# Snapshots `content_dir` directly into `store` (bypassing the `wvc`
# subprocess entirely, so this never moves any ref) and stores a new
# commit with a single parent, `parent_commit_id`. Returns the malloc'd
# 64-hex commit id.
char* wvct_build_sibling_commit(wcas* store, char* parent_commit_id, char* content_dir, char* message):
	wresult[char*]* tree_r = tree_snapshot(store, content_dir, 0)
	assert1(result_is_ok[char*](tree_r))
	char* tree_id = result_value[char*](tree_r)
	result_free[char*](tree_r)

	list[char*] parents = new list[char*]
	parents.push(parent_commit_id)
	wresult[commit_object*]* co_r = commit_new(tree_id, parents, c"wvc-test", time_now(), message, strlen(message))
	assert1(result_is_ok[commit_object*](co_r))
	commit_object* co = result_value[commit_object*](co_r)
	result_free[commit_object*](co_r)

	wresult[char*]* stored_r = commit_store(store, co)
	assert1(result_is_ok[char*](stored_r))
	char* commit_id = result_value[char*](stored_r)
	result_free[char*](stored_r)

	commit_free(co)
	list_free[char*](parents)
	free(tree_id)
	return commit_id


wcas* wvct_open_store_direct(char* meta):
	wresult[wcas*]* r = cas_open(meta)
	assert1(result_is_ok[wcas*](r))
	wcas* store = result_value[wcas*](r)
	result_free[wcas*](r)
	return store


commit_object* wvct_load_commit_direct(wcas* store, char* commit_id):
	wresult[commit_object*]* r = commit_load(store, commit_id)
	assert1(result_is_ok[commit_object*](r))
	commit_object* co = result_value[commit_object*](r)
	result_free[commit_object*](r)
	return co


char* wvct_merge_clean_dir_cache
char* wvct_merge_clean_dir():
	if (wvct_merge_clean_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_merge_clean_test_")
		string_append_int(p, getpid())
		wvct_merge_clean_dir_cache = p.data
		free(p)
	return wvct_merge_clean_dir_cache


char* wvct_merge_clean_theirs_dir_cache
char* wvct_merge_clean_theirs_dir():
	if (wvct_merge_clean_theirs_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_merge_clean_theirs_")
		string_append_int(p, getpid())
		wvct_merge_clean_theirs_dir_cache = p.data
		free(p)
	return wvct_merge_clean_theirs_dir_cache


# Two commits that both descend from the same base but touch DIFFERENT
# files (ours: a.txt, theirs: b.txt) merge cleanly: both edits land in
# the working tree, and the resulting merge commit has exactly two
# parents, [HEAD, theirs] in that order (wvc_cmd_merge's own
# parent_ids.push order).
void test_wvc_merge_clean():
	char* dir = wvct_merge_clean_dir()
	char* theirs_dir = wvct_merge_clean_theirs_dir()
	wvct_rm_rf(dir)
	wvct_rm_rf(theirs_dir)

	list[char*] init_args = new list[char*]
	init_args.push(c"wvc")
	init_args.push(c"init")
	init_args.push(dir)
	process_result* r_init = wvct_run(init_args, 0)
	assert_equal(0, r_init.status)
	process_result_free(r_init)

	char* a_path = path_join(dir, c"a.txt")
	char* b_path = path_join(dir, c"b.txt")
	assert_equal(1, file_write_text(a_path, c"alpha\n"))
	assert_equal(1, file_write_text(b_path, c"beta\n"))

	list[char*] snap_base_args = new list[char*]
	snap_base_args.push(c"wvc")
	snap_base_args.push(c"snapshot")
	snap_base_args.push(dir)
	snap_base_args.push(c"-m")
	snap_base_args.push(c"base")
	process_result* r_base = wvct_run(snap_base_args, 0)
	assert_equal(0, r_base.status)
	char* commit_base = wvct_trim(r_base.stdout_text)
	process_result_free(r_base)

	# "ours": snapshot again with only a.txt changed -- this becomes the
	# current HEAD (main), parent = commit_base.
	assert_equal(1, file_write_text(a_path, c"alpha-ours\n"))
	list[char*] snap_ours_args = new list[char*]
	snap_ours_args.push(c"wvc")
	snap_ours_args.push(c"snapshot")
	snap_ours_args.push(dir)
	snap_ours_args.push(c"-m")
	snap_ours_args.push(c"ours change")
	process_result* r_ours = wvct_run(snap_ours_args, 0)
	assert_equal(0, r_ours.status)
	char* commit_head = wvct_trim(r_ours.stdout_text)
	process_result_free(r_ours)

	# "theirs": a sibling commit, parent = commit_base too, that only
	# touches b.txt -- built directly against the same object store.
	char* meta = path_join(dir, c".wvc")
	wcas* store = wvct_open_store_direct(meta)
	assert_equal(0, mkdir(theirs_dir, 493))
	char* t_a_path = path_join(theirs_dir, c"a.txt")
	char* t_b_path = path_join(theirs_dir, c"b.txt")
	assert_equal(1, file_write_text(t_a_path, c"alpha\n"))
	assert_equal(1, file_write_text(t_b_path, c"beta-theirs\n"))
	char* commit_theirs = wvct_build_sibling_commit(store, commit_base, theirs_dir, c"theirs change")
	cas_close(store)

	list[char*] merge_args = new list[char*]
	merge_args.push(c"wvc")
	merge_args.push(c"merge")
	merge_args.push(commit_theirs)
	process_result* r_merge = wvct_run(merge_args, dir)
	assert_equal(0, r_merge.status)
	char* commit_merge = wvct_trim(r_merge.stdout_text)
	assert1(cas_valid_id(commit_merge))
	process_result_free(r_merge)

	char* a_after = file_read_text(a_path)
	wvct_assert_contains(a_after, c"alpha-ours")
	free(a_after)
	char* b_after = file_read_text(b_path)
	wvct_assert_contains(b_after, c"beta-theirs")
	free(b_after)

	# The merge commit has exactly two parents: HEAD, then the merged
	# commit, in that order.
	wcas* store2 = wvct_open_store_direct(meta)
	commit_object* merge_co = wvct_load_commit_direct(store2, commit_merge)
	assert_equal(2, merge_co.parent_ids.length)
	assert_strings_equal(commit_head, merge_co.parent_ids[0])
	assert_strings_equal(commit_theirs, merge_co.parent_ids[1])
	commit_free(merge_co)
	cas_close(store2)

	# `wvc merge` again with the same rev: already an ancestor now (it
	# IS one of the two parents), so this is a clean, quiet no-op.
	process_result* r_again = wvct_run(merge_args, dir)
	assert_equal(0, r_again.status)
	wvct_assert_contains(r_again.stdout_text, c"Already up to date.")
	process_result_free(r_again)

	free(a_path)
	free(b_path)
	free(t_a_path)
	free(t_b_path)
	free(meta)
	free(commit_base)
	free(commit_head)
	free(commit_theirs)
	free(commit_merge)
	wvct_rm_rf(dir)
	wvct_rm_rf(theirs_dir)


char* wvct_merge_conflict_dir_cache
char* wvct_merge_conflict_dir():
	if (wvct_merge_conflict_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_merge_conflict_test_")
		string_append_int(p, getpid())
		wvct_merge_conflict_dir_cache = p.data
		free(p)
	return wvct_merge_conflict_dir_cache


char* wvct_merge_conflict_theirs_dir_cache
char* wvct_merge_conflict_theirs_dir():
	if (wvct_merge_conflict_theirs_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_merge_conflict_theirs_")
		string_append_int(p, getpid())
		wvct_merge_conflict_theirs_dir_cache = p.data
		free(p)
	return wvct_merge_conflict_theirs_dir_cache


# Two commits that both edit the SAME line of the SAME file differently
# conflict: `wvc merge` exits 1, prints a "CONFLICT (content): a.txt"
# line, and leaves standard git-compatible conflict markers in the
# working tree file -- no commit is created (HEAD does not move).
void test_wvc_merge_conflict():
	char* dir = wvct_merge_conflict_dir()
	char* theirs_dir = wvct_merge_conflict_theirs_dir()
	wvct_rm_rf(dir)
	wvct_rm_rf(theirs_dir)

	list[char*] init_args = new list[char*]
	init_args.push(c"wvc")
	init_args.push(c"init")
	init_args.push(dir)
	process_result* r_init = wvct_run(init_args, 0)
	assert_equal(0, r_init.status)
	process_result_free(r_init)

	char* a_path = path_join(dir, c"a.txt")
	assert_equal(1, file_write_text(a_path, c"line1\nline2\nline3\n"))

	list[char*] snap_base_args = new list[char*]
	snap_base_args.push(c"wvc")
	snap_base_args.push(c"snapshot")
	snap_base_args.push(dir)
	snap_base_args.push(c"-m")
	snap_base_args.push(c"base")
	process_result* r_base = wvct_run(snap_base_args, 0)
	assert_equal(0, r_base.status)
	char* commit_base = wvct_trim(r_base.stdout_text)
	process_result_free(r_base)

	# "ours": HEAD changes line2.
	assert_equal(1, file_write_text(a_path, c"line1\nOURS\nline3\n"))
	list[char*] snap_ours_args = new list[char*]
	snap_ours_args.push(c"wvc")
	snap_ours_args.push(c"snapshot")
	snap_ours_args.push(dir)
	snap_ours_args.push(c"-m")
	snap_ours_args.push(c"ours change")
	process_result* r_ours = wvct_run(snap_ours_args, 0)
	assert_equal(0, r_ours.status)
	char* commit_head = wvct_trim(r_ours.stdout_text)
	process_result_free(r_ours)

	# "theirs": a sibling commit, parent = commit_base, that changes the
	# SAME line differently.
	char* meta = path_join(dir, c".wvc")
	wcas* store = wvct_open_store_direct(meta)
	assert_equal(0, mkdir(theirs_dir, 493))
	char* t_a_path = path_join(theirs_dir, c"a.txt")
	assert_equal(1, file_write_text(t_a_path, c"line1\nTHEIRS\nline3\n"))
	char* commit_theirs = wvct_build_sibling_commit(store, commit_base, theirs_dir, c"theirs change")
	cas_close(store)

	list[char*] merge_args = new list[char*]
	merge_args.push(c"wvc")
	merge_args.push(c"merge")
	merge_args.push(commit_theirs)
	process_result* r_merge = wvct_run(merge_args, dir)
	assert_equal(1, r_merge.status)
	wvct_assert_contains(r_merge.stdout_text, c"CONFLICT (content): a.txt")
	process_result_free(r_merge)

	# The working tree file carries standard git-compatible markers.
	char* a_after = file_read_text(a_path)
	wvct_assert_contains(a_after, c"<<<<<<< ours")
	wvct_assert_contains(a_after, c"OURS")
	wvct_assert_contains(a_after, c"=======")
	wvct_assert_contains(a_after, c"THEIRS")
	wvct_assert_contains(a_after, c">>>>>>> theirs")
	free(a_after)

	# HEAD did not move: a conflicted merge creates no commit.
	list[char*] log_args = new list[char*]
	log_args.push(c"wvc")
	log_args.push(c"log")
	process_result* r_log = wvct_run(log_args, dir)
	assert_equal(0, r_log.status)
	wvct_assert_contains(r_log.stdout_text, commit_head);
	assert_equal(-1, wvct_index_of(r_log.stdout_text, c"theirs change"))
	process_result_free(r_log)

	free(a_path)
	free(t_a_path)
	free(meta)
	free(commit_base)
	free(commit_head)
	free(commit_theirs)
	wvct_rm_rf(dir)
	wvct_rm_rf(theirs_dir)
