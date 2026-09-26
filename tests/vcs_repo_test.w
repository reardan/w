# wbuild: x64
/*
libs/extras/vcs/repo.w: the working-tree and repo-layout helpers
tools/wvc.w is built on (issue #338).

Covers: the layout convention (meta dir, index path, ignore list),
status letters, path splitting, blob lookups by path through a
snapshotted tree (present, missing, directory, empty path), content
equality and binary sniffing, the sorted/deduplicated merge path union,
and writing/removing working-tree files through missing parents.

Fixture and store roots are pid-scoped under bin/ so the 32- and 64-bit
twins can run in parallel; the last test removes everything it created.
*/
import lib.testing
import lib.dir
import libs.extras.vcs.cas
import libs.extras.vcs.tree
import libs.extras.vcs.repo


char* vrt_scoped(char* prefix):
	string_builder* p = string_new()
	string_append(p, prefix)
	string_append_int(p, getpid())
	string_append_char(p, '_')
	string_append_int(p, __word_size__ * 8)
	char* s = p.data
	free(p)
	return s


char* vrt_root_cache
char* vrt_root():
	if (vrt_root_cache == 0): vrt_root_cache = vrt_scoped(c"bin/vcs_repo_test_")
	return vrt_root_cache


char* vrt_work_cache
char* vrt_work():
	if (vrt_work_cache == 0):
		vrt_work_cache = vrt_scoped(c"bin/vcs_repo_work_")
		mkdir(vrt_work_cache, 493)
	return vrt_work_cache


wcas_object* vrt_blob(char* data, int length):
	wcas_object* o = new wcas_object
	o.object_type = c"blob"
	o.data = data
	o.length = length
	return o


void test_repo_layout():
	assert_strings_equal(c".wvc", REPO_META_DIR_NAME())
	assert_strings_equal(c"main", REPO_DEFAULT_REF())
	char* meta = repo_meta_dir(c"work")
	assert_strings_equal(c"work/.wvc", meta)
	char* index = repo_index_path(meta)
	assert_strings_equal(c"work/.wvc/index", index)
	list[char*] ignore = repo_ignore_list()
	assert_equal(2, ignore.length)
	assert_strings_equal(c".wvc", ignore[0])
	assert_strings_equal(c"bin", ignore[1])
	assert_equal('A', repo_status_char(TREE_ADDED()))
	assert_equal('D', repo_status_char(TREE_REMOVED()))
	assert_equal('M', repo_status_char(TREE_MODIFIED()))


void test_repo_split_path():
	list[char*] parts = repo_split_path(c"a//b/c.txt/")
	assert_equal(3, parts.length)
	assert_strings_equal(c"a", parts[0])
	assert_strings_equal(c"b", parts[1])
	assert_strings_equal(c"c.txt", parts[2])
	assert_equal(0, repo_split_path(c"").length)


void test_repo_content_and_binary():
	wcas_object* a = vrt_blob(c"hello", 5)
	wcas_object* b = vrt_blob(c"hello", 5)
	wcas_object* c = vrt_blob(c"hellp", 5)
	assert_equal(1, repo_blob_content_equal(0, 0))
	assert_equal(0, repo_blob_content_equal(a, 0))
	assert_equal(1, repo_blob_content_equal(a, b))
	assert_equal(0, repo_blob_content_equal(a, c))
	assert_equal(0, repo_blob_content_equal(a, vrt_blob(c"hell", 4)))
	assert_equal(0, repo_is_binaryish(0))
	assert_equal(0, repo_is_binaryish(a))
	assert_equal(1, repo_is_binaryish(vrt_blob(c"ab\x00cd", 5)))
	# Only the first REPO_BINARY_SNIFF_LEN() bytes are sniffed.
	int n = REPO_BINARY_SNIFF_LEN + 2
	char* big = malloc(n)
	for i in range(n): big[i] = 'x'
	big[n - 1] = 0
	assert_equal(0, repo_is_binaryish(vrt_blob(big, n)))


tree_change* vrt_change(char* path):
	tree_change* c = new tree_change
	c.path = path
	return c


void test_repo_merge_collect_paths():
	list[tree_change*] ours = new list[tree_change*]
	ours.push(vrt_change(c"z.txt"))
	ours.push(vrt_change(c"a.txt"))
	list[tree_change*] theirs = new list[tree_change*]
	theirs.push(vrt_change(c"m.txt"))
	theirs.push(vrt_change(c"a.txt"))
	list[char*] paths = repo_merge_collect_paths(ours, theirs)
	assert_equal(3, paths.length)
	assert_strings_equal(c"a.txt", paths[0])
	assert_strings_equal(c"m.txt", paths[1])
	assert_strings_equal(c"z.txt", paths[2])


void test_repo_write_lookup_remove():
	# Write through missing parents, then snapshot and look the blobs up.
	repo_write_file_bytes(vrt_work(), c"dir/sub/f.bin", vrt_blob(c"a\x00b", 3))
	repo_write_file_bytes(vrt_work(), c"top.txt", vrt_blob(c"top", 3))
	wcas* store = result_expect[wcas*](cas_open(vrt_root()))
	char* root_id = result_expect[char*](tree_snapshot(store, vrt_work(), repo_ignore_list()))

	wcas_object* f = repo_maybe_blob(store, root_id, c"dir/sub/f.bin")
	assert1(f != 0)
	assert_equal(1, repo_blob_content_equal(f, vrt_blob(c"a\x00b", 3)))
	cas_object_free(f)
	# A directory resolves to a tree id, never a blob.
	assert1(repo_maybe_blob_id(store, root_id, c"dir") != 0)
	assert1(repo_maybe_blob(store, root_id, c"dir") == 0)
	assert1(repo_maybe_blob_id(store, root_id, c"dir/missing") == 0)
	assert1(repo_maybe_blob_id(store, 0, c"top.txt") == 0)
	wresult[char*]* missing = repo_lookup_blob(store, root_id, c"nope/x")
	assert_equal(-2, result_code[char*](missing))
	wresult[char*]* empty = repo_lookup_blob(store, root_id, c"")
	assert_equal(-22, result_code[char*](empty))
	cas_close(store)

	repo_remove_file(vrt_work(), c"dir/sub/f.bin")
	repo_remove_file(vrt_work(), c"top.txt")
	repo_remove_file(vrt_work(), c"not-there.txt")


# Runs last: the files repo_remove_file deleted leave only the empty
# parents repo_write_file_bytes created, and the object store.
void test_repo_cleanup():
	char* sub = path_join(vrt_work(), c"dir/sub")
	assert_equal(0, rmdir(sub))
	char* dir = path_join(vrt_work(), c"dir")
	assert_equal(0, rmdir(dir))
	assert_equal(0, rmdir(vrt_work()))
	assert_equal(0, dir_remove_all(vrt_root()))
	assert_equal(0, path_exists(vrt_root()))
