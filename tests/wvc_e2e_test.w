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
import lib.str
import tests.tool_e2e
import lib.path
import lib.file
import lib.time
import lib.result
import lib.container
import structures.string
import libs.extras.vcs.cas
import libs.extras.vcs.tree
import libs.extras.vcs.commit


char* wvct_dir():
	return tool_scratch(c"wvc_e2e_test_")


void test_wvc_end_to_end():
	char* dir = wvct_dir()

	# Best-effort cleanup from a previous failed run.
	dir_remove_all(dir)

	char* r_init = tool_ok(0, c"wvc", c"init", dir)
	assert_contains(r_init, c"Initialized empty wvc repository")

	char* a_path = path_join(dir, c"a.txt")
	char* b_path = path_join(dir, c"b.txt")
	assert_equal(1, file_write_text(a_path, c"hello\n"))
	assert_equal(1, file_write_text(b_path, c"world\n"))

	char* commit1 = trim_eol(tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"first commit"))
	assert1(cas_valid_id(commit1))

	# Modify a.txt, remove b.txt, add c.txt.
	assert_equal(1, file_write_text(a_path, c"hello world\n"))
	assert_equal(0, unlink(b_path))
	char* c_path = path_join(dir, c"c.txt")
	assert_equal(1, file_write_text(c_path, c"new file\n"))

	char* r_status = tool_ok(0, c"wvc", c"status", dir)
	assert_contains(r_status, c"M a.txt")
	assert_contains(r_status, c"D b.txt")
	assert_contains(r_status, c"A c.txt")

	char* commit2 = trim_eol(tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"second commit", c"-a", c"Test Author"))
	assert1(cas_valid_id(commit2))

	# Nothing changed since the second snapshot: status is clean.
	char* r_status2 = tool_ok(0, c"wvc", c"status", dir)
	assert_contains(r_status2, c"nothing to snapshot, working tree clean")

	# log runs with cwd = dir (no <dir> argument on this subcommand).
	char* r_log = tool_ok(dir, c"wvc", c"log")
	assert_contains(r_log, commit1)
	assert_contains(r_log, commit2)
	assert_contains(r_log, c"first commit")
	assert_contains(r_log, c"second commit")
	assert_contains(r_log, c"Test Author")
	# Oldest-parent-last: commit2 (newest) prints before commit1.
	assert1(index_of(r_log, commit2) < index_of(r_log, commit1))

	# diff also runs with cwd = dir; revs are the two commit ids.
	char* r_diff = tool_ok(dir, c"wvc", c"diff", commit1, commit2)
	assert_contains(r_diff, c"M a.txt")
	assert_contains(r_diff, c"D b.txt")
	assert_contains(r_diff, c"A c.txt")
	# The modified-file nice-to-have: a real unified line diff for a.txt.
	assert_contains(r_diff, c"-hello")
	assert_contains(r_diff, c"+hello world")

	# diff also accepts the ref name "main" as a rev.
	process_result* r_diff_ref = tool_run(dir, c"wvc", c"diff", c"main", c"main")
	assert_equal(0, r_diff_ref.status)
	assert_equal(0, r_diff_ref.stdout_length)
	process_result_free(r_diff_ref)

	free(commit1)
	free(commit2)
	free(a_path)
	free(b_path)
	free(c_path)

	dir_remove_all(dir)


void test_wvc_usage_errors():
	process_result* r_none = tool_run(0, c"wvc")
	assert_equal(2, r_none.status)
	process_result_free(r_none)

	process_result* r_bogus = tool_run(0, c"wvc", c"bogus")
	assert_equal(2, r_bogus.status)
	process_result_free(r_bogus)


void test_wvc_status_on_missing_repo_fails():
	process_result* r = tool_run(0, c"wvc", c"status", c"bin/wvc_e2e_test_no_such_dir")
	assert_equal(1, r.status)
	assert_contains(r.stderr_text, c"wvc: cannot open object store")
	process_result_free(r)


char* wvct_index_dir():
	return tool_scratch(c"wvc_index_e2e_test_")


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

	dir_remove_all(dir)

	tool_ok(0, c"wvc", c"init", dir)

	char* a_path = path_join(dir, c"a.txt")
	char* b_path = path_join(dir, c"b.txt")
	char* c_path = path_join(dir, c"c.txt")
	assert_equal(1, file_write_text(a_path, c"alpha\n"))
	assert_equal(1, file_write_text(b_path, c"beta\n"))
	assert_equal(1, file_write_text(c_path, c"gamma\n"))

	tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"first commit")

	# snapshot refreshed (created) the dirstate.
	char* index_path = path_join(dir, c".wvc/index")
	assert_equal(1, path_exists(index_path))

	# Touch exactly one of the three tracked files.
	assert_equal(1, file_write_text(b_path, c"beta-changed\n"))

	char* r_status = tool_ok(0, c"wvc", c"status", dir)
	assert_contains(r_status, c"M b.txt")
	assert_equal(-1, index_of(r_status, c"a.txt"))
	assert_equal(-1, index_of(r_status, c"c.txt"))

	# Re-running status with nothing further changed reports the exact
	# same single change again -- status's own write-back of the
	# refreshed index (it persists what it just computed) does not
	# desync itself or spuriously flag anything else.
	char* r_status2 = tool_ok(0, c"wvc", c"status", dir)
	assert_contains(r_status2, c"M b.txt")
	assert_equal(-1, index_of(r_status2, c"a.txt"))
	assert_equal(-1, index_of(r_status2, c"c.txt"))

	# Snapshotting now (committing b.txt's change) and checking status
	# again DOES go clean -- confirms the fast path's refreshed tree id
	# was correct all along, not just "some non-empty diff".
	tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"second commit")
	char* r_status_clean = tool_ok(0, c"wvc", c"status", dir)
	assert_contains(r_status_clean, c"nothing to snapshot, working tree clean")

	# Delete the dirstate: status must still work, via the slow path.
	assert_equal(0, unlink(index_path))
	assert_equal(1, file_write_text(a_path, c"alpha-changed\n"))
	char* r_status3 = tool_ok(0, c"wvc", c"status", dir)
	assert_contains(r_status3, c"M a.txt")
	# The slow path does not itself recreate the index (only `snapshot`
	# does -- see wvc.w's header comment).
	assert_equal(0, path_exists(index_path))

	free(a_path)
	free(b_path)
	free(c_path)
	free(index_path)

	dir_remove_all(dir)


/* wvc merge (wave 4, issue #252) -- see the header comment for why
   "theirs" is built directly against the object store rather than
   through the `wvc` subprocess. */


# Snapshots `content_dir` directly into `store` (bypassing the `wvc`
# subprocess entirely, so this never moves any ref) and stores a new
# commit with a single parent, `parent_commit_id`. Returns the malloc'd
# 64-hex commit id.
char* wvct_build_sibling_commit(wcas* store, char* parent_commit_id, char* content_dir, char* message):
	char* tree_id = result_expect[char*](tree_snapshot(store, content_dir, 0))

	list[char*] parents = new list[char*]
	parents.push(parent_commit_id)
	commit_object* co = result_expect[commit_object*](commit_new(tree_id, parents, c"wvc-test", time_now(), message, strlen(message)))

	char* commit_id = result_expect[char*](commit_store(store, co))

	commit_free(co)
	list_free[char*](parents)
	free(tree_id)
	return commit_id


wcas* wvct_open_store_direct(char* meta):
	wcas* store = result_expect[wcas*](cas_open(meta))
	return store


commit_object* wvct_load_commit_direct(wcas* store, char* commit_id):
	commit_object* co = result_expect[commit_object*](commit_load(store, commit_id))
	return co


char* wvct_merge_clean_dir():
	return tool_scratch(c"wvc_merge_clean_test_")


char* wvct_merge_clean_theirs_dir():
	return tool_scratch(c"wvc_merge_clean_theirs_")


# Two commits that both descend from the same base but touch DIFFERENT
# files (ours: a.txt, theirs: b.txt) merge cleanly: both edits land in
# the working tree, and the resulting merge commit has exactly two
# parents, [HEAD, theirs] in that order (wvc_cmd_merge's own
# parent_ids.push order).
void test_wvc_merge_clean():
	char* dir = wvct_merge_clean_dir()
	char* theirs_dir = wvct_merge_clean_theirs_dir()
	dir_remove_all(dir)
	dir_remove_all(theirs_dir)

	tool_ok(0, c"wvc", c"init", dir)

	char* a_path = path_join(dir, c"a.txt")
	char* b_path = path_join(dir, c"b.txt")
	assert_equal(1, file_write_text(a_path, c"alpha\n"))
	assert_equal(1, file_write_text(b_path, c"beta\n"))

	char* commit_base = trim_eol(tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"base"))

	# "ours": snapshot again with only a.txt changed -- this becomes the
	# current HEAD (main), parent = commit_base.
	assert_equal(1, file_write_text(a_path, c"alpha-ours\n"))
	char* commit_head = trim_eol(tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"ours change"))

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

	char* commit_merge = trim_eol(tool_ok(dir, c"wvc", c"merge", commit_theirs))
	assert1(cas_valid_id(commit_merge))

	char* a_after = file_read_text(a_path)
	assert_contains(a_after, c"alpha-ours")
	free(a_after)
	char* b_after = file_read_text(b_path)
	assert_contains(b_after, c"beta-theirs")
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
	char* r_again = tool_ok(dir, c"wvc", c"merge", commit_theirs)
	assert_contains(r_again, c"Already up to date.")

	free(a_path)
	free(b_path)
	free(t_a_path)
	free(t_b_path)
	free(meta)
	free(commit_base)
	free(commit_head)
	free(commit_theirs)
	free(commit_merge)
	dir_remove_all(dir)
	dir_remove_all(theirs_dir)


char* wvct_merge_conflict_dir():
	return tool_scratch(c"wvc_merge_conflict_test_")


char* wvct_merge_conflict_theirs_dir():
	return tool_scratch(c"wvc_merge_conflict_theirs_")


# Two commits that both edit the SAME line of the SAME file differently
# conflict: `wvc merge` exits 1, prints a "CONFLICT (content): a.txt"
# line, and leaves standard git-compatible conflict markers in the
# working tree file -- no commit is created (HEAD does not move).
void test_wvc_merge_conflict():
	char* dir = wvct_merge_conflict_dir()
	char* theirs_dir = wvct_merge_conflict_theirs_dir()
	dir_remove_all(dir)
	dir_remove_all(theirs_dir)

	tool_ok(0, c"wvc", c"init", dir)

	char* a_path = path_join(dir, c"a.txt")
	assert_equal(1, file_write_text(a_path, c"line1\nline2\nline3\n"))

	char* commit_base = trim_eol(tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"base"))

	# "ours": HEAD changes line2.
	assert_equal(1, file_write_text(a_path, c"line1\nOURS\nline3\n"))
	char* commit_head = trim_eol(tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"ours change"))

	# "theirs": a sibling commit, parent = commit_base, that changes the
	# SAME line differently.
	char* meta = path_join(dir, c".wvc")
	wcas* store = wvct_open_store_direct(meta)
	assert_equal(0, mkdir(theirs_dir, 493))
	char* t_a_path = path_join(theirs_dir, c"a.txt")
	assert_equal(1, file_write_text(t_a_path, c"line1\nTHEIRS\nline3\n"))
	char* commit_theirs = wvct_build_sibling_commit(store, commit_base, theirs_dir, c"theirs change")
	cas_close(store)

	process_result* r_merge = tool_run(dir, c"wvc", c"merge", commit_theirs)
	assert_equal(1, r_merge.status)
	assert_contains(r_merge.stdout_text, c"CONFLICT (content): a.txt")
	process_result_free(r_merge)

	# The working tree file carries standard git-compatible markers.
	char* a_after = file_read_text(a_path)
	assert_contains(a_after, c"<<<<<<< ours")
	assert_contains(a_after, c"OURS")
	assert_contains(a_after, c"=======")
	assert_contains(a_after, c"THEIRS")
	assert_contains(a_after, c">>>>>>> theirs")
	free(a_after)

	# HEAD did not move: a conflicted merge creates no commit.
	char* r_log = tool_ok(dir, c"wvc", c"log")
	assert_contains(r_log, commit_head);
	assert_equal(-1, index_of(r_log, c"theirs change"))

	free(a_path)
	free(t_a_path)
	free(meta)
	free(commit_base)
	free(commit_head)
	free(commit_theirs)
	dir_remove_all(dir)
	dir_remove_all(theirs_dir)
