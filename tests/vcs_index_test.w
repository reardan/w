# wbuild: x64
/*
libs/extras/vcs/index.w: the stat-cached dirstate (issue #252 wave 3).

Covers: the line format round-trip (encode/parse and real write/read
through a temp file) including sorted-order and malformed-input
rejection, the racy-mtime guard's decision function directly
(index_entry_trusted) plus an end-to-end proof using a REAL file's own
stat data (deterministic -- no sleeping across a wall-clock second
boundary, see test_index_racy_mtime_forces_rehash's comment),
index_refresh's equivalence to tree.w's tree_snapshot when there is no
prior index, cache reuse (unchanged files keep their cached blob id
across a refresh) and status-shaped correctness (touching exactly one
tracked file is reported as exactly one change), and absent/corrupt
index files reported as distinct, recoverable errors.

The store root and the walk fixture directories are pid-scoped under
bin/ so the 32- and 64-bit twins (and a parallel wvc_index_e2e run) never
collide; the final test removes everything this run created.
*/
import lib.testing
import libs.extras.vcs.cas
import libs.extras.vcs.tree
import libs.extras.vcs.index


char* vit_root_cache
char* vit_root():
	if (vit_root_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/vcs_index_test_")
		string_append_int(p, getpid())
		string_append_char(p, '_')
		string_append_int(p, __word_size__ * 8)
		vit_root_cache = p.data
		free(p)
	return vit_root_cache


char* vit_work_cache
char* vit_work():
	if (vit_work_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/vcs_index_work_")
		string_append_int(p, getpid())
		string_append_char(p, '_')
		string_append_int(p, __word_size__ * 8)
		vit_work_cache = p.data
		free(p)
		mkdir(vit_work_cache, 493)
	return vit_work_cache


wcas* vit_open():
	wresult[wcas*]* r = cas_open(vit_root())
	assert1(result_is_ok[wcas*](r))
	wcas* s = result_value[wcas*](r)
	result_free[wcas*](r)
	return s


char* vit_mkdir(char* parent, char* name):
	char* path = path_join(parent, name)
	assert_equal(0, mkdir(path, 493))
	return path


void vit_write(char* dir, char* name, char* contents):
	char* path = path_join(dir, name)
	wstream* out = stream_open_write(path)
	assert1(cast(int, out) != 0)
	stream_write(out, contents, strlen(contents))
	stream_close(out)
	free(path)


char* vit_fake_id(int digit):
	char* id = malloc(65)
	int i = 0
	while (i < 64):
		id[i] = digit
		i = i + 1
	id[64] = 0
	return id


index_entry* vit_entry(char* path, int size, int mtime, char* blob_id):
	index_entry* e = new index_entry
	e.path = strclone(path)
	e.size = size
	e.mtime = mtime
	e.blob_id = strclone(blob_id)
	return e


wtree* vit_get(wcas* s, char* id):
	wresult[wtree*]* r = tree_get(s, id)
	assert1(result_is_ok[wtree*](r))
	wtree* t = result_value[wtree*](r)
	result_free[wtree*](r)
	return t


char* vit_snapshot(wcas* s, char* path, list[char*] ignore):
	wresult[char*]* r = tree_snapshot(s, path, ignore)
	assert1(result_is_ok[char*](r))
	char* id = result_value[char*](r)
	result_free[char*](r)
	return id


index_refresh_result* vit_refresh(wcas* s, char* dir, list[char*] ignore, windex* prev):
	wresult[index_refresh_result*]* r = index_refresh(s, dir, ignore, prev)
	assert1(result_is_ok[index_refresh_result*](r))
	index_refresh_result* rr = result_value[index_refresh_result*](r)
	result_free[index_refresh_result*](r)
	return rr


void test_index_encode_parse_roundtrip():
	windex* idx = index_new()
	idx.write_time = 12345
	char* id_a = vit_fake_id('a')
	char* id_b = vit_fake_id('b')
	# Pushed out of order; encode sorts by path.
	idx.entries.push(vit_entry(c"z/late.txt", 20, 200, id_b))
	idx.entries.push(vit_entry(c"a.txt", 10, 100, id_a))

	string_builder* enc = index_encode(idx)
	wresult[windex*]* parsed_r = index_parse(enc.data, enc.length)
	assert1(result_is_ok[windex*](parsed_r))
	windex* parsed = result_value[windex*](parsed_r)
	result_free[windex*](parsed_r)

	assert_equal(12345, parsed.write_time)
	assert_equal(2, parsed.entries.length)
	assert_strings_equal(c"a.txt", parsed.entries[0].path)
	assert_equal(10, parsed.entries[0].size)
	assert_equal(100, parsed.entries[0].mtime)
	assert_strings_equal(id_a, parsed.entries[0].blob_id)
	assert_strings_equal(c"z/late.txt", parsed.entries[1].path)
	assert_equal(20, parsed.entries[1].size)
	assert_equal(200, parsed.entries[1].mtime)
	assert_strings_equal(id_b, parsed.entries[1].blob_id)

	# encode(parse(x)) == encode(x): the round trip is byte-exact.
	string_builder* re_enc = index_encode(parsed)
	assert_strings_equal(enc.data, re_enc.data)

	string_free(enc)
	string_free(re_enc)
	index_free(idx)
	index_free(parsed)
	free(id_a)
	free(id_b)


void test_index_parse_rejects_malformed():
	# Wrong/missing header.
	wresult[windex*]* bad_header = index_parse(c"not an index\n", 13)
	assert1(result_is_error[windex*](bad_header))
	assert_equal(INDEX_ERR_MALFORMED(), result_code[windex*](bad_header))
	result_free[windex*](bad_header)

	# Missing write_time line.
	char* no_wt = c"index 1\nentry 1 2 "
	wresult[windex*]* r1 = index_parse(no_wt, strlen(no_wt))
	assert1(result_is_error[windex*](r1))
	assert_equal(INDEX_ERR_MALFORMED(), result_code[windex*](r1))
	result_free[windex*](r1)

	# Non-numeric write_time.
	char* bad_wt = c"index 1\nwrite_time abc\n"
	wresult[windex*]* r2 = index_parse(bad_wt, strlen(bad_wt))
	assert1(result_is_error[windex*](r2))
	assert_equal(INDEX_ERR_MALFORMED(), result_code[windex*](r2))
	result_free[windex*](r2)

	# A short/invalid blob id.
	char* bad_id = c"index 1\nwrite_time 0\nentry 1 2 short a.txt\n"
	wresult[windex*]* r3 = index_parse(bad_id, strlen(bad_id))
	assert1(result_is_error[windex*](r3))
	assert_equal(INDEX_ERR_MALFORMED(), result_code[windex*](r3))
	result_free[windex*](r3)

	# Entries out of order.
	char* id_a = vit_fake_id('a')
	string_builder* unsorted = string_new()
	string_append(unsorted, c"index 1\nwrite_time 0\nentry 1 2 ")
	string_append(unsorted, id_a)
	string_append(unsorted, c" z.txt\nentry 1 2 ")
	string_append(unsorted, id_a)
	string_append(unsorted, c" a.txt\n")
	wresult[windex*]* r4 = index_parse(unsorted.data, unsorted.length)
	assert1(result_is_error[windex*](r4))
	assert_equal(INDEX_ERR_MALFORMED(), result_code[windex*](r4))
	result_free[windex*](r4)
	string_free(unsorted)

	# Duplicate path: strictly ascending order rejects equal names too.
	string_builder* dup = string_new()
	string_append(dup, c"index 1\nwrite_time 0\nentry 1 2 ")
	string_append(dup, id_a)
	string_append(dup, c" a.txt\nentry 1 2 ")
	string_append(dup, id_a)
	string_append(dup, c" a.txt\n")
	wresult[windex*]* r5 = index_parse(dup.data, dup.length)
	assert1(result_is_error[windex*](r5))
	assert_equal(INDEX_ERR_MALFORMED(), result_code[windex*](r5))
	result_free[windex*](r5)
	string_free(dup)

	# A well-formed, empty index (no entries) is valid.
	char* empty = c"index 1\nwrite_time 42\n"
	wresult[windex*]* r6 = index_parse(empty, strlen(empty))
	assert1(result_is_ok[windex*](r6))
	windex* e = result_value[windex*](r6)
	result_free[windex*](r6)
	assert_equal(42, e.write_time)
	assert_equal(0, e.entries.length)
	index_free(e)

	free(id_a)


void test_index_write_read_roundtrip():
	wcas* s = vit_open()   # ensures vit_root() actually exists on disk
	windex* idx = index_new()
	idx.write_time = 999
	char* id_a = vit_fake_id('c')
	idx.entries.push(vit_entry(c"dir/inner file.txt", 7, 70, id_a))

	char* path = path_join(vit_root(), c"index_rt")
	wresult[int]* w = index_write(idx, path)
	assert1(result_is_ok[int](w))
	result_free[int](w)

	wresult[windex*]* r = index_read(path)
	assert1(result_is_ok[windex*](r))
	windex* got = result_value[windex*](r)
	result_free[windex*](r)
	assert_equal(999, got.write_time)
	assert_equal(1, got.entries.length)
	assert_strings_equal(c"dir/inner file.txt", got.entries[0].path)
	assert_equal(7, got.entries[0].size)
	assert_equal(70, got.entries[0].mtime)
	assert_strings_equal(id_a, got.entries[0].blob_id)

	# Overwriting an existing index file succeeds (the temp+rename
	# protocol replaces, not appends).
	windex* idx2 = index_new()
	idx2.write_time = 1000
	wresult[int]* w2 = index_write(idx2, path)
	assert1(result_is_ok[int](w2))
	result_free[int](w2)
	wresult[windex*]* r2 = index_read(path)
	assert1(result_is_ok[windex*](r2))
	windex* got2 = result_value[windex*](r2)
	result_free[windex*](r2)
	assert_equal(1000, got2.write_time)
	assert_equal(0, got2.entries.length)

	index_free(idx)
	index_free(idx2)
	index_free(got)
	index_free(got2)
	free(id_a)
	free(path)
	cas_close(s)


void test_index_read_absent_and_corrupt():
	char* missing = path_join(vit_root(), c"no_such_index")
	wresult[windex*]* r1 = index_read(missing)
	assert1(result_is_error[windex*](r1))
	assert_equal(-2, result_code[windex*](r1))
	result_free[windex*](r1)
	free(missing)

	char* corrupt = path_join(vit_root(), c"corrupt_index")
	wstream* out = stream_open_write(corrupt)
	assert1(cast(int, out) != 0)
	stream_write(out, c"garbage\n", 8)
	stream_close(out)
	wresult[windex*]* r2 = index_read(corrupt)
	assert1(result_is_error[windex*](r2))
	assert_equal(INDEX_ERR_MALFORMED(), result_code[windex*](r2))
	result_free[windex*](r2)
	free(corrupt)


void test_index_entry_trusted_decision():
	char* id_a = vit_fake_id('a')
	index_entry* e = vit_entry(c"f.txt", 10, 500, id_a)

	# No prior entry: never trusted.
	assert_equal(0, index_entry_trusted(0, 10, 500, 0))

	# Stat matches and the entry's mtime is strictly older than the
	# reference index's write time: trusted.
	assert_equal(1, index_entry_trusted(e, 10, 500, 600))

	# Size differs: not trusted, regardless of mtime.
	assert_equal(0, index_entry_trusted(e, 11, 500, 600))

	# Mtime differs: not trusted.
	assert_equal(0, index_entry_trusted(e, 10, 501, 600))

	# Racy: the entry's mtime equals the reference write_time, even
	# though the stat otherwise matches exactly.
	assert_equal(0, index_entry_trusted(e, 10, 500, 500))

	index_entry_free(e)
	free(id_a)


# Deterministic racy-mtime proof using a REAL file's own stat data,
# rather than racing the wall clock across a second boundary (see the
# file header comment): the file's actual mtime becomes BOTH the cached
# entry's mtime AND the contrived reference write_time, so
# index_entry_trusted's condition (prev.mtime == prev_write_time) is hit
# exactly, deterministically, every run. The cached blob id is
# deliberately WRONG (a fake id, not the real hash of "one") so that
# reuse vs. re-hash is directly observable in the resulting tree.
void test_index_racy_mtime_forces_rehash():
	wcas* s = vit_open()
	char* racy_dir = vit_mkdir(vit_work(), c"racy")
	vit_write(racy_dir, c"f.txt", c"one")
	char* real_path = path_join(racy_dir, c"f.txt")
	int size = 0
	int mtime = 0
	assert_equal(0, index_stat(real_path, &size, &mtime))
	assert_equal(3, size)

	char* wrong_id = vit_fake_id('9')
	windex* prev = index_new()
	prev.entries.push(vit_entry(c"f.txt", size, mtime, wrong_id))
	prev.write_time = mtime   # racy: equals the cached entry's own mtime

	index_refresh_result* racy = vit_refresh(s, racy_dir, 0, prev)
	wtree* racy_tree = vit_get(s, racy.tree_id)
	assert_equal(1, racy_tree.entries.length)
	char* real_blob_id = cas_id_hex(c"blob", c"one", 3)
	# Rehashed: the entry is the REAL content hash, not the wrong cached id.
	assert_strings_equal(real_blob_id, racy_tree.entries[0].id)
	assert1(strcmp(wrong_id, racy_tree.entries[0].id) != 0)
	tree_free(racy_tree)
	free(racy.tree_id)
	index_free(racy.index)
	free(racy)

	# Positive control: the exact same setup, but write_time is NOT
	# equal to the cached mtime -- now the (wrong) cache IS trusted,
	# proving the fast path really does skip re-hashing when the guard
	# does not fire.
	windex* prev2 = index_new()
	prev2.entries.push(vit_entry(c"f.txt", size, mtime, wrong_id))
	prev2.write_time = mtime - 1000
	index_refresh_result* trusted = vit_refresh(s, racy_dir, 0, prev2)
	wtree* trusted_tree = vit_get(s, trusted.tree_id)
	assert_strings_equal(wrong_id, trusted_tree.entries[0].id)
	tree_free(trusted_tree)
	free(trusted.tree_id)
	index_free(trusted.index)
	free(trusted)

	free(real_blob_id)
	free(wrong_id)
	free(real_path)
	free(racy_dir)
	index_free(prev)
	index_free(prev2)
	cas_close(s)


void test_index_refresh_matches_tree_snapshot_with_no_prior_index():
	wcas* s = vit_open()
	char* d = vit_mkdir(vit_work(), c"equiv")
	vit_write(d, c"a.txt", c"alpha")
	char* sub = vit_mkdir(d, c"sub")
	vit_write(sub, c"b.txt", c"beta")

	char* slow_id = vit_snapshot(s, d, 0)
	index_refresh_result* fast = vit_refresh(s, d, 0, 0)
	assert_strings_equal(slow_id, fast.tree_id)
	assert_equal(2, fast.index.entries.length)
	assert_strings_equal(c"a.txt", fast.index.entries[0].path)
	assert_strings_equal(c"sub/b.txt", fast.index.entries[1].path)

	free(slow_id)
	free(fast.tree_id)
	index_free(fast.index)
	free(fast)
	free(sub)
	free(d)
	cas_close(s)


void test_index_refresh_reuses_cache_and_reports_only_changed():
	wcas* s = vit_open()
	char* d = vit_mkdir(vit_work(), c"cache")
	vit_write(d, c"a.txt", c"one")
	vit_write(d, c"b.txt", c"two")
	vit_write(d, c"c.txt", c"three")

	index_refresh_result* first = vit_refresh(s, d, 0, 0)
	assert_equal(3, first.index.entries.length)

	# Only b.txt changes; a.txt and c.txt are untouched on disk.
	vit_write(d, c"b.txt", c"TWO-CHANGED")
	index_refresh_result* second = vit_refresh(s, d, 0, first.index)

	assert1(strcmp(first.tree_id, second.tree_id) != 0)
	assert_equal(3, second.index.entries.length)
	# a.txt and c.txt: same cached blob id (the fast path reused it,
	# not just "happened to compute the same value" -- their disk
	# content never changed so a fresh hash would agree either way, but
	# combined with test_index_racy_mtime_forces_rehash's direct proof
	# that mismatched cache entries win in the trust check, this is
	# adequate end-to-end confirmation of reuse).
	assert_strings_equal(first.index.entries[0].blob_id, second.index.entries[0].blob_id)  # a.txt
	assert_strings_equal(first.index.entries[2].blob_id, second.index.entries[2].blob_id)  # c.txt
	char* changed_id = cas_id_hex(c"blob", c"TWO-CHANGED", 11)
	assert_strings_equal(changed_id, second.index.entries[1].blob_id)  # b.txt

	# Status-shaped correctness: diffing old vs. new tree reports
	# EXACTLY the one touched path.
	list[tree_change*] changes = new list[tree_change*]
	wresult[int]* diffed = tree_diff(s, first.tree_id, second.tree_id, changes)
	assert1(result_is_ok[int](diffed))
	assert_equal(1, result_value[int](diffed))
	result_free[int](diffed)
	assert_equal(1, changes.length)
	assert_strings_equal(c"b.txt", changes[0].path)
	assert_equal(TREE_MODIFIED(), changes[0].status)
	tree_changes_free(changes)
	list_free[tree_change*](changes)

	free(changed_id)
	free(first.tree_id)
	index_free(first.index)
	free(first)
	free(second.tree_id)
	index_free(second.index)
	free(second)
	free(d)
	cas_close(s)


void test_index_refresh_ignore_list_and_dropped_files():
	wcas* s = vit_open()
	char* d = vit_mkdir(vit_work(), c"ign")
	vit_write(d, c"keep.txt", c"kept")
	char* noise = vit_mkdir(d, c"bin")
	vit_write(noise, c"junk", c"artifact")

	list[char*] ignore = new list[char*]
	ignore.push(c"bin")

	index_refresh_result* first = vit_refresh(s, d, ignore, 0)
	assert_equal(1, first.index.entries.length)
	assert_strings_equal(c"keep.txt", first.index.entries[0].path)

	# Remove the tracked file: the next refresh's index simply drops it
	# (mirrors tree_snapshot's natural omission of missing paths).
	char* keep_path = path_join(d, c"keep.txt")
	assert_equal(0, unlink(keep_path))
	index_refresh_result* second = vit_refresh(s, d, ignore, first.index)
	assert_equal(0, second.index.entries.length)
	wtree* empty_root = vit_get(s, second.tree_id)
	assert_equal(0, empty_root.entries.length)
	tree_free(empty_root)

	free(keep_path)
	list_free[char*](ignore)
	free(first.tree_id)
	index_free(first.index)
	free(first)
	free(second.tree_id)
	index_free(second.index)
	free(second)
	free(noise)
	free(d)
	cas_close(s)


# Recursively deletes a fixture/store directory (vcs_tree_test.w's
# vtt_remove_all, duplicated here since it is test-local plumbing, not
# library code).
void vit_remove_all(char* path):
	int fd = open(path, 65536, 0)
	if (fd < 0):
		return
	list[char*] names = new list[char*]
	list[int] kinds = new list[int]
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* record = buffer + off
			int reclen = (record[2 * __word_size__] & 255) + ((record[2 * __word_size__ + 1] & 255) << 8)
			char* entry_name = record + 2 * __word_size__ + 2
			int kind = record[reclen - 1] & 255
			if ((strcmp(entry_name, c".") != 0) && (strcmp(entry_name, c"..") != 0)):
				names.push(strclone(entry_name))
				kinds.push(kind)
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	int i = 0
	while (i < names.length):
		char* child = path_join(path, names[i])
		if (kinds[i] == 4):
			vit_remove_all(child)
			rmdir(child)
		else:
			vcs_unlink(child)
		free(child)
		free(names[i])
		i = i + 1


void test_index_cleanup():
	vit_remove_all(vit_work())
	assert_equal(0, rmdir(vit_work()))
	vit_remove_all(vit_root())
	assert_equal(0, rmdir(vit_root()))
