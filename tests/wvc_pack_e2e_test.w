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
import lib.path
import lib.file
import lib.container
import structures.string
import libs.extras.vcs.cas
import libs.extras.vcs.pack


char* wvcp_repo_root_cache
char* wvcp_repo_root():
	if (wvcp_repo_root_cache == 0):
		char* buf = malloc(4096)
		int n = getcwd(buf, 4096)
		assert1(n > 0)
		wvcp_repo_root_cache = buf
	return wvcp_repo_root_cache


char* wvcp_bin_cache
char* wvcp_bin():
	if (wvcp_bin_cache == 0):
		wvcp_bin_cache = path_join(wvcp_repo_root(), c"bin/wvc")
	return wvcp_bin_cache


char* wvcp_dir_cache
char* wvcp_dir():
	if (wvcp_dir_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_pack_e2e_test_")
		string_append_int(p, getpid())
		wvcp_dir_cache = p.data
		free(p)
	return wvcp_dir_cache


char** wvcp_argv(list[char*] args):
	char** v = strv_new(args.length)
	int i = 0
	for char* a in args:
		strv_set(v, i, a)
		i = i + 1
	return v


process_result* wvcp_run(list[char*] args, char* cwd):
	spawn_options* opts = 0
	if (cwd != 0):
		opts = spawn_options_new()
		opts.cwd = cwd
	char** argv = wvcp_argv(args)
	process_result* r = process_run(wvcp_bin(), argv, opts, 0, 10000)
	assert1(r != 0)
	if (opts != 0):
		free(opts)
	free(cast(void*, argv))
	return r


int wvcp_index_of(char* haystack, char* needle):
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


void wvcp_assert_contains(char* haystack, char* needle):
	int found = wvcp_index_of(haystack, needle) >= 0
	if (found == 0):
		wstream* err = stderr_writer()
		stream_write_cstr(err, c"expected to find '")
		stream_write_cstr(err, needle)
		stream_write_cstr(err, c"' in: ")
		stream_write_line(err, haystack)
		stream_flush(err)
	assert1(found)


void wvcp_rm_rf(char* path):
	list[char*] args = new list[char*]
	args.push(c"/bin/rm")
	args.push(c"-rf")
	args.push(path)
	char** argv = wvcp_argv(args)
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 10000)
	if (r != 0):
		process_result_free(r)
	free(cast(void*, argv))
	list_free[char*](args)


# One wvc invocation that must exit 0; returns the (owned) stdout text.
char* wvcp_run_ok(list[char*] args, char* cwd):
	process_result* r = wvcp_run(args, cwd)
	assert_equal(0, r.status)
	char* out = strclone(r.stdout_text)
	process_result_free(r)
	list_free[char*](args)
	return out


# The store's loose ids, sorted (owned list of owned ids).
list[char*] wvcp_loose_ids(wcas* s):
	wresult[list[char*]]* r = pack_loose_ids(s)
	assert1(result_is_ok[list[char*]](r))
	list[char*] ids = result_value[list[char*]](r)
	result_free[list[char*]](r)
	ids.sort_by(strcmp)
	return ids


void test_wvc_pack_unpack_end_to_end():
	char* dir = wvcp_dir()
	wvcp_rm_rf(dir)

	list[char*] init_args = new list[char*]
	init_args.push(c"wvc")
	init_args.push(c"init")
	init_args.push(dir)
	char* init_out = wvcp_run_ok(init_args, 0)
	wvcp_assert_contains(init_out, c"Initialized empty wvc repository")
	free(init_out)

	char* a_path = path_join(dir, c"a.txt")
	assert_equal(1, file_write_text(a_path, c"alpha\n"))
	char* sub_dir = path_join(dir, c"sub")
	assert_equal(0, mkdir(sub_dir, 493))
	char* b_path = path_join(sub_dir, c"b.txt")
	assert_equal(1, file_write_text(b_path, c"beta\n"))

	list[char*] snap1_args = new list[char*]
	snap1_args.push(c"wvc")
	snap1_args.push(c"snapshot")
	snap1_args.push(dir)
	snap1_args.push(c"-m")
	snap1_args.push(c"first packed commit")
	free(wvcp_run_ok(snap1_args, 0))

	assert_equal(1, file_write_text(a_path, c"alpha, revised\n"))
	list[char*] snap2_args = new list[char*]
	snap2_args.push(c"wvc")
	snap2_args.push(c"snapshot")
	snap2_args.push(dir)
	snap2_args.push(c"-m")
	snap2_args.push(c"second packed commit")
	free(wvcp_run_ok(snap2_args, 0))

	# Baseline: every loose id and its exact on-disk file bytes.
	char* meta = path_join(dir, c".wvc")
	wresult[wcas*]* store_r = cas_open(meta)
	assert1(result_is_ok[wcas*](store_r))
	wcas* store = result_value[wcas*](store_r)
	result_free[wcas*](store_r)
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
	list[char*] pack_args = new list[char*]
	pack_args.push(c"wvc")
	pack_args.push(c"pack")
	pack_args.push(dir)
	pack_args.push(c"--prune")
	char* pack_out = wvcp_run_ok(pack_args, 0)
	wvcp_assert_contains(pack_out, c"packed ")
	wvcp_assert_contains(pack_out, c".wpack")
	wvcp_assert_contains(pack_out, c"pruned loose copies")
	free(pack_out)
	list[char*] emptied = wvcp_loose_ids(store)
	assert_equal(0, emptied.length)
	list_free[char*](emptied)

	# log and status still answer, from the pack alone.
	list[char*] log_args = new list[char*]
	log_args.push(c"wvc")
	log_args.push(c"log")
	char* log_out = wvcp_run_ok(log_args, dir)
	wvcp_assert_contains(log_out, c"first packed commit")
	wvcp_assert_contains(log_out, c"second packed commit")
	free(log_out)
	list[char*] status_args = new list[char*]
	status_args.push(c"wvc")
	status_args.push(c"status")
	status_args.push(dir)
	char* status_out = wvcp_run_ok(status_args, 0)
	wvcp_assert_contains(status_out, c"nothing to snapshot, working tree clean")
	free(status_out)

	# Unpack: the pack explodes back into the identical loose files.
	list[char*] unpack_args = new list[char*]
	unpack_args.push(c"wvc")
	unpack_args.push(c"unpack")
	unpack_args.push(dir)
	char* unpack_out = wvcp_run_ok(unpack_args, 0)
	wvcp_assert_contains(unpack_out, c"unpacked ")
	wvcp_assert_contains(unpack_out, c" pack(s)")
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
	list[char*] repack_args = new list[char*]
	repack_args.push(c"wvc")
	repack_args.push(c"pack")
	repack_args.push(dir)
	char* repack_out = wvcp_run_ok(repack_args, 0)
	wvcp_assert_contains(repack_out, c"packed ")
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
	wvcp_rm_rf(dir)


void test_wvc_pack_usage_errors():
	list[char*] bad_pack = new list[char*]
	bad_pack.push(c"wvc")
	bad_pack.push(c"pack")
	bad_pack.push(c"one_dir")
	bad_pack.push(c"surplus_dir")
	process_result* r = wvcp_run(bad_pack, 0)
	assert_equal(2, r.status)
	process_result_free(r)
	list_free[char*](bad_pack)

	list[char*] bad_unpack = new list[char*]
	bad_unpack.push(c"wvc")
	bad_unpack.push(c"unpack")
	bad_unpack.push(c"one_dir")
	bad_unpack.push(c"surplus_dir")
	r = wvcp_run(bad_unpack, 0)
	assert_equal(2, r.status)
	process_result_free(r)
	list_free[char*](bad_unpack)
