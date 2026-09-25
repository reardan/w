/*
tools/wvc.w's `pack`/`unpack` subcommands: end-to-end test (VCS wave-3
remainder, issue #252 "object packing"; format and design:
libs/extras/vcs/pack.w's header comment). Generated (wbuildgen's
convention) via the '# wbuild: tool=tools/wvc.w' directive below, which
adds "wvc" itself (built first) to this target's "deps" -- like
tests/wvc_e2e_test.w, it spawns the real binary as a subprocess against
a throwaway pid-scoped directory under bin/.

The flow the porcelain must survive: init -> two snapshots -> `wvc pack
--prune` (every loose object rewritten into one pack file, loose copies
deleted) -> `log` and `status` still answering correctly from the pack
alone -> `wvc unpack` restoring every loose object file BYTE-identically
(each object's on-disk bytes are recorded before packing and compared
after unpacking -- the encoding is deterministic, so this is exact) and
removing the pack -> `wvc pack` without --prune keeping the loose copies
in place. Loose-object enumeration and the byte baseline go through
libs/extras/vcs/{cas,pack}.w directly against the same on-disk store the
subprocesses operate on, the same library-alongside-CLI pattern
wvc_e2e_test.w's merge tests already use. A trailing usage-error check
asserts exit status 2 for surplus arguments.
*/
# wbuild: tool=tools/wvc.w
import lib.testing
import lib.process
import lib.str
import tests.tool_e2e
import lib.path
import lib.file
import lib.container
import structures.string
import libs.extras.vcs.cas
import libs.extras.vcs.pack


char* wvcp_dir():
	return tool_scratch(c"wvc_pack_e2e_test_")


# The store's loose ids, sorted (owned list of owned ids).
list[char*] wvcp_loose_ids(wcas* s):
	list[char*] ids = result_expect[list[char*]](pack_loose_ids(s))
	ids.sort_by(strcmp)
	return ids


void test_wvc_pack_unpack_end_to_end():
	char* dir = wvcp_dir()
	dir_remove_all(dir)

	char* init_out = tool_ok(0, c"wvc", c"init", dir)
	assert_contains(init_out, c"Initialized empty wvc repository")
	free(init_out)

	char* a_path = path_join(dir, c"a.txt")
	assert_equal(1, file_write_text(a_path, c"alpha\n"))
	char* sub_dir = path_join(dir, c"sub")
	assert_equal(0, mkdir(sub_dir, 493))
	char* b_path = path_join(sub_dir, c"b.txt")
	assert_equal(1, file_write_text(b_path, c"beta\n"))

	free(tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"first packed commit"))

	assert_equal(1, file_write_text(a_path, c"alpha, revised\n"))
	free(tool_ok(0, c"wvc", c"snapshot", dir, c"-m", c"second packed commit"))

	# Baseline: every loose id and its exact on-disk file bytes.
	char* meta = path_join(dir, c".wvc")
	wcas* store = result_expect[wcas*](cas_open(meta))
	list[char*] before_ids = wvcp_loose_ids(store)
	assert1(before_ids.length > 0)
	list[string_builder*] before_bytes = new list[string_builder*]
	for char* id in before_ids:
		char* obj_path = cas_object_path(store, id)
		string_builder* contents = cas_read_file(obj_path)
		assert1(contents != 0)
		before_bytes.push(contents)
		free(obj_path)

	# Pack with pruning: loose store empties, one pack file appears.
	char* pack_out = tool_ok(0, c"wvc", c"pack", dir, c"--prune")
	assert_contains(pack_out, c"packed ")
	assert_contains(pack_out, c".wpack")
	assert_contains(pack_out, c"pruned loose copies")
	free(pack_out)
	list[char*] emptied = wvcp_loose_ids(store)
	assert_equal(0, emptied.length)
	list_free[char*](emptied)

	# log and status still answer, from the pack alone.
	char* log_out = tool_ok(dir, c"wvc", c"log")
	assert_contains(log_out, c"first packed commit")
	assert_contains(log_out, c"second packed commit")
	free(log_out)
	char* status_out = tool_ok(0, c"wvc", c"status", dir)
	assert_contains(status_out, c"nothing to snapshot, working tree clean")
	free(status_out)

	# Unpack: the pack explodes back into the identical loose files.
	char* unpack_out = tool_ok(0, c"wvc", c"unpack", dir)
	assert_contains(unpack_out, c"unpacked ")
	assert_contains(unpack_out, c" pack(s)")
	free(unpack_out)
	list[char*] after_ids = wvcp_loose_ids(store)
	assert_equal(before_ids.length, after_ids.length)
	int i = 0
	while (i < before_ids.length):
		assert_strings_equal(before_ids[i], after_ids[i])
		char* obj_path = cas_object_path(store, after_ids[i])
		string_builder* restored = cas_read_file(obj_path)
		assert1(restored != 0)
		string_builder* original = before_bytes[i]
		assert_equal(original.length, restored.length)
		int j = 0
		while (j < original.length):
			assert_equal(original.data[j] & 255, restored.data[j] & 255)
			j = j + 1
		string_free(restored)
		free(obj_path)
		i = i + 1

	# Without --prune the loose copies stay put next to the new pack.
	char* repack_out = tool_ok(0, c"wvc", c"pack", dir)
	assert_contains(repack_out, c"packed ")
	free(repack_out)
	list[char*] kept = wvcp_loose_ids(store)
	assert_equal(before_ids.length, kept.length)
	for char* id in kept:
		free(id)
	list_free[char*](kept)

	for char* id in before_ids:
		free(id)
	list_free[char*](before_ids)
	for char* id in after_ids:
		free(id)
	list_free[char*](after_ids)
	for string_builder* b in before_bytes:
		string_free(b)
	list_free[string_builder*](before_bytes)
	cas_close(store)
	free(meta)
	free(a_path)
	free(b_path)
	free(sub_dir)
	dir_remove_all(dir)


void test_wvc_pack_usage_errors():
	process_result* r = tool_run(0, c"wvc", c"pack", c"one_dir", c"surplus_dir")
	assert_equal(2, r.status)
	process_result_free(r)
	r = tool_run(0, c"wvc", c"unpack", c"one_dir", c"surplus_dir")
	assert_equal(2, r.status)
	process_result_free(r)
