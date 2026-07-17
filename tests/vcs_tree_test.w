# wbuild: x64
/*
libs/extras/vcs/tree.w: Merkle tree objects over the content-addressed
store (issue #252 wave 2, V2a).

Covers: the canonical line format pinned against cas_id_hex known
answers (including the empty tree), insertion-order independence of
serialization, entry validation (names the format cannot store,
duplicate names, bad modes/ids), put/get round-trips plus rejection of
non-canonical stored payloads, directory snapshots (nested directories,
creation-order determinism, the ignore list, empty directories, error
paths), and tree_diff: added/removed/modified files, removed
directories expanding recursively, null-id ("no tree") sides, a
file<->directory kind change, a 100644<->100755 mode flip, and the
Merkle skip property -- two roots sharing an equal subtree id diff
correctly even though that subtree's object was NEVER STORED, which is
possible only if equal ids are skipped without reading children (a
differing unstored subtree, by contrast, must fail with -2).

The store root and the snapshot fixture directories are pid-scoped
under bin/ so the 32- and 64-bit twins can run in parallel; the final
test removes everything the run created and asserts the roots rmdir
cleanly.
*/
import lib.testing
import libs.extras.vcs.cas
import libs.extras.vcs.tree


# Pid-scoped roots, computed once: the object store and the directory
# fixtures the snapshot tests build.
char* vtt_root_cache
char* vtt_root():
	if (vtt_root_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/vcs_tree_test_")
		string_append_int(p, getpid())
		string_append_char(p, '_')
		string_append_int(p, __word_size__ * 8)
		vtt_root_cache = p.data
		free(p)
	return vtt_root_cache


char* vtt_work_cache
char* vtt_work():
	if (vtt_work_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/vcs_tree_work_")
		string_append_int(p, getpid())
		string_append_char(p, '_')
		string_append_int(p, __word_size__ * 8)
		vtt_work_cache = p.data
		free(p)
		mkdir(vtt_work_cache, 493)
	return vtt_work_cache


wcas* vtt_open():
	wresult[wcas*]* r = cas_open(vtt_root())
	assert1(result_is_ok[wcas*](r))
	wcas* s = result_value[wcas*](r)
	result_free[wcas*](r)
	return s


# A syntactically valid 64-hex id built from one hex digit, for tree
# entries whose children never need to exist in the store.
char* vtt_fake_id(int digit):
	char* id = malloc(65)
	int i = 0
	while (i < 64):
		id[i] = digit
		i = i + 1
	id[64] = 0
	return id


# A fixture directory under vtt_work(); returns the owned joined path.
char* vtt_mkdir(char* parent, char* name):
	char* path = path_join(parent, name)
	assert_equal(0, mkdir(path, 493))
	return path


void vtt_write(char* dir, char* name, char* contents):
	char* path = path_join(dir, name)
	wstream* out = stream_open_write(path)
	assert1(cast(int, out) != 0)
	stream_write(out, contents, strlen(contents))
	stream_close(out)
	free(path)


char* vtt_snapshot(wcas* s, char* path, list[char*] ignore):
	wresult[char*]* r = tree_snapshot(s, path, ignore)
	assert1(result_is_ok[char*](r))
	char* id = result_value[char*](r)
	result_free[char*](r)
	return id


wtree* vtt_get(wcas* s, char* id):
	wresult[wtree*]* r = tree_get(s, id)
	assert1(result_is_ok[wtree*](r))
	wtree* t = result_value[wtree*](r)
	result_free[wtree*](r)
	return t


# Runs tree_diff, asserts success and the expected change count.
list[tree_change*] vtt_diff(wcas* s, char* old_id, char* new_id, int expected):
	list[tree_change*] out = new list[tree_change*]
	wresult[int]* r = tree_diff(s, old_id, new_id, out)
	assert1(result_is_ok[int](r))
	assert_equal(expected, result_value[int](r))
	result_free[int](r)
	assert_equal(expected, out.length)
	return out


void vtt_assert_change(list[tree_change*] out, int index, char* path, int status):
	assert_strings_equal(path, out[index].path)
	assert_equal(status, out[index].status)


void test_tree_serialize_known_answer():
	char* id_a = vtt_fake_id('a')
	char* id_b = vtt_fake_id('b')
	char* id_c = vtt_fake_id('c')

	# Entries added out of order; serialization sorts by byte-wise name.
	wtree* t = tree_new()
	assert_equal(0, tree_add(t, c"run", TREE_MODE_EXEC(), id_c))
	assert_equal(0, tree_add(t, c"b", TREE_MODE_DIR(), id_b))
	assert_equal(0, tree_add(t, c"a.txt", TREE_MODE_FILE(), id_a))

	string_builder* want = string_new()
	string_append(want, c"100644 ")
	string_append(want, id_a)
	string_append(want, c" a.txt\n40000 ")
	string_append(want, id_b)
	string_append(want, c" b\n100755 ")
	string_append(want, id_c)
	string_append(want, c" run\n")

	char* payload = tree_serialize(t)
	assert_strings_equal(want.data, payload)
	free(payload)

	# The id is exactly the cas id of that canonical payload.
	char* id = tree_id_hex(t)
	char* expect = cas_id_hex(c"tree", want.data, want.length)
	assert_strings_equal(expect, id)

	# Insertion order does not matter: a permuted build hashes the same.
	wtree* permuted = tree_new()
	assert_equal(0, tree_add(permuted, c"a.txt", TREE_MODE_FILE(), id_a))
	assert_equal(0, tree_add(permuted, c"run", TREE_MODE_EXEC(), id_c))
	assert_equal(0, tree_add(permuted, c"b", TREE_MODE_DIR(), id_b))
	char* permuted_id = tree_id_hex(permuted)
	assert_strings_equal(id, permuted_id)

	# The empty tree serializes to the empty payload.
	wtree* empty = tree_new()
	char* empty_payload = tree_serialize(empty)
	assert_equal(0, strlen(empty_payload))
	char* empty_id = tree_id_hex(empty)
	char* empty_expect = cas_id_hex(c"tree", c"", 0)
	assert_strings_equal(empty_expect, empty_id)

	free(empty_payload)
	free(empty_id)
	free(empty_expect)
	free(permuted_id)
	free(id)
	free(expect)
	string_free(want)
	tree_free(t)
	tree_free(permuted)
	tree_free(empty)
	free(id_a)
	free(id_b)
	free(id_c)


void test_tree_entry_validation():
	char* id = vtt_fake_id('d')

	# Names the format cannot store.
	assert_equal(0, cast(int, tree_entry_new(c"", TREE_MODE_FILE(), id)))
	assert_equal(0, cast(int, tree_entry_new(c".", TREE_MODE_FILE(), id)))
	assert_equal(0, cast(int, tree_entry_new(c"..", TREE_MODE_FILE(), id)))
	assert_equal(0, cast(int, tree_entry_new(c"a/b", TREE_MODE_FILE(), id)))
	assert_equal(0, cast(int, tree_entry_new(c"a\nb", TREE_MODE_FILE(), id)))

	# Unknown mode, malformed ids.
	assert_equal(0, cast(int, tree_entry_new(c"ok", 99, id)))
	assert_equal(0, cast(int, tree_entry_new(c"ok", TREE_MODE_FILE(), c"short")))
	assert_equal(0, cast(int, tree_entry_new(c"ok", TREE_MODE_FILE(), 0)))

	# Spaces in names are fine (the name field is last on the line).
	tree_entry* spaced = tree_entry_new(c"has space.txt", TREE_MODE_FILE(), id)
	assert1(cast(int, spaced) != 0)
	tree_entry_free(spaced)

	wtree* t = tree_new()
	assert_equal(-22, tree_add(t, c"a/b", TREE_MODE_FILE(), id))
	assert_equal(0, t.entries.length)

	# Duplicate names have no canonical form: serialization refuses.
	assert_equal(0, tree_add(t, c"twin", TREE_MODE_FILE(), id))
	assert_equal(0, tree_add(t, c"twin", TREE_MODE_FILE(), id))
	assert_equal(0, cast(int, tree_serialize(t)))
	assert_equal(0, cast(int, tree_id_hex(t)))
	wcas* s = vtt_open()
	wresult[char*]* put = tree_put(s, t)
	assert1(result_is_error[char*](put))
	assert_equal(-22, result_code[char*](put))
	result_free[char*](put)
	cas_close(s)
	tree_free(t)
	free(id)


void test_tree_put_get_roundtrip():
	wcas* s = vtt_open()
	char* id_a = vtt_fake_id('1')
	char* id_b = vtt_fake_id('2')

	wtree* t = tree_new()
	assert_equal(0, tree_add(t, c"zz", TREE_MODE_DIR(), id_b))
	assert_equal(0, tree_add(t, c"aa.txt", TREE_MODE_FILE(), id_a))
	wresult[char*]* put = tree_put(s, t)
	assert1(result_is_ok[char*](put))
	char* id = result_value[char*](put)
	result_free[char*](put)
	assert_equal(1, cas_has(s, id))
	assert_equal(1, cas_verify(s, id))

	# Read back: canonical (sorted) order, fields intact.
	wtree* got = vtt_get(s, id)
	assert_equal(2, got.entries.length)
	assert_strings_equal(c"aa.txt", got.entries[0].name)
	assert_equal(TREE_MODE_FILE(), got.entries[0].mode)
	assert_strings_equal(id_a, got.entries[0].id)
	assert_strings_equal(c"zz", got.entries[1].name)
	assert_equal(TREE_MODE_DIR(), got.entries[1].mode)
	assert_strings_equal(id_b, got.entries[1].id)
	tree_free(got)

	# A blob is not a tree: wrong type tag reports corruption.
	wresult[char*]* blob = cas_put(s, c"blob", c"not a tree", 10)
	assert1(result_is_ok[char*](blob))
	char* blob_id = result_value[char*](blob)
	result_free[char*](blob)
	wresult[wtree*]* not_tree = tree_get(s, blob_id)
	assert1(result_is_error[wtree*](not_tree))
	assert_equal(CAS_ERR_CORRUPT(), result_code[wtree*](not_tree))
	result_free[wtree*](not_tree)
	free(blob_id)

	# Missing and malformed ids pass cas_get's errors through.
	char* absent = c"00000000000000000000000000000000000000000000000000000000000000aa"
	wresult[wtree*]* miss = tree_get(s, absent)
	assert1(result_is_error[wtree*](miss))
	assert_equal(-2, result_code[wtree*](miss))
	result_free[wtree*](miss)
	wresult[wtree*]* bad = tree_get(s, c"not-an-id")
	assert1(result_is_error[wtree*](bad))
	assert_equal(-22, result_code[wtree*](bad))
	result_free[wtree*](bad)

	# Non-canonical payloads stored as "tree" objects are rejected:
	# entries out of order...
	string_builder* unsorted = string_new()
	string_append(unsorted, c"100644 ")
	string_append(unsorted, id_b)
	string_append(unsorted, c" zz\n100644 ")
	string_append(unsorted, id_a)
	string_append(unsorted, c" aa\n")
	wresult[char*]* stored = cas_put(s, c"tree", unsorted.data, unsorted.length)
	assert1(result_is_ok[char*](stored))
	char* unsorted_id = result_value[char*](stored)
	result_free[char*](stored)
	wresult[wtree*]* rejected = tree_get(s, unsorted_id)
	assert1(result_is_error[wtree*](rejected))
	assert_equal(CAS_ERR_CORRUPT(), result_code[wtree*](rejected))
	result_free[wtree*](rejected)
	string_free(unsorted)
	free(unsorted_id)

	# ...and lines that do not parse at all.
	wresult[char*]* junk = cas_put(s, c"tree", c"no format here\n", 15)
	assert1(result_is_ok[char*](junk))
	char* junk_id = result_value[char*](junk)
	result_free[char*](junk)
	wresult[wtree*]* garbage = tree_get(s, junk_id)
	assert1(result_is_error[wtree*](garbage))
	assert_equal(CAS_ERR_CORRUPT(), result_code[wtree*](garbage))
	result_free[wtree*](garbage)
	free(junk_id)

	free(id)
	free(id_a)
	free(id_b)
	tree_free(t)
	cas_close(s)


void test_tree_snapshot_nested_and_deterministic():
	wcas* s = vtt_open()

	# w1/: file1.txt, sub/inner.txt, sub/deep/deep.txt
	char* w1 = vtt_mkdir(vtt_work(), c"w1")
	vtt_write(w1, c"file1.txt", c"hello")
	char* sub = vtt_mkdir(w1, c"sub")
	vtt_write(sub, c"inner.txt", c"world")
	char* deep = vtt_mkdir(sub, c"deep")
	vtt_write(deep, c"deep.txt", c"deepest")

	char* root_id = vtt_snapshot(s, w1, 0)

	# The root tree records exactly the two children, and the file blob
	# is stored under the content id cas_id_hex predicts.
	wtree* root = vtt_get(s, root_id)
	assert_equal(2, root.entries.length)
	assert_strings_equal(c"file1.txt", root.entries[0].name)
	assert_equal(TREE_MODE_FILE(), root.entries[0].mode)
	char* hello_id = cas_id_hex(c"blob", c"hello", 5)
	assert_strings_equal(hello_id, root.entries[0].id)
	assert_equal(1, cas_has(s, hello_id))
	free(hello_id)
	assert_strings_equal(c"sub", root.entries[1].name)
	assert_equal(TREE_MODE_DIR(), root.entries[1].mode)

	# Descend: sub/ holds deep/ and inner.txt, itself readable as a tree.
	wtree* subtree = vtt_get(s, root.entries[1].id)
	assert_equal(2, subtree.entries.length)
	assert_strings_equal(c"deep", subtree.entries[0].name)
	assert_equal(TREE_MODE_DIR(), subtree.entries[0].mode)
	assert_strings_equal(c"inner.txt", subtree.entries[1].name)
	assert_equal(TREE_MODE_FILE(), subtree.entries[1].mode)
	tree_free(subtree)
	tree_free(root)

	# Determinism: the same content built in a different creation order
	# (and under a different fixture name) snapshots to the same id.
	char* w2 = vtt_mkdir(vtt_work(), c"w2")
	char* sub2 = vtt_mkdir(w2, c"sub")
	char* deep2 = vtt_mkdir(sub2, c"deep")
	vtt_write(deep2, c"deep.txt", c"deepest")
	vtt_write(sub2, c"inner.txt", c"world")
	vtt_write(w2, c"file1.txt", c"hello")
	char* root_id2 = vtt_snapshot(s, w2, 0)
	assert_strings_equal(root_id, root_id2)

	# Different content -> different id.
	char* w3 = vtt_mkdir(vtt_work(), c"w3")
	vtt_write(w3, c"file1.txt", c"HELLO")
	char* root_id3 = vtt_snapshot(s, w3, 0)
	assert1(strcmp(root_id, root_id3) != 0)

	# Error paths: a missing path and a non-directory path.
	wresult[char*]* missing = tree_snapshot(s, c"bin/vcs_tree_no_such_dir", 0)
	assert1(result_is_error[char*](missing))
	assert_equal(-2, result_code[char*](missing))
	result_free[char*](missing)
	char* file_path = path_join(w1, c"file1.txt")
	wresult[char*]* not_dir = tree_snapshot(s, file_path, 0)
	assert1(result_is_error[char*](not_dir))
	assert_equal(-20, result_code[char*](not_dir))
	result_free[char*](not_dir)
	free(file_path)

	free(root_id)
	free(root_id2)
	free(root_id3)
	free(w1)
	free(sub)
	free(deep)
	free(w2)
	free(sub2)
	free(deep2)
	free(w3)
	cas_close(s)


void test_tree_snapshot_ignore_list():
	wcas* s = vtt_open()

	# Two fixtures with identical tracked content; the second also has
	# bin/ and .git/ noise at the root AND nested one level down.
	char* clean = vtt_mkdir(vtt_work(), c"ig_clean")
	vtt_write(clean, c"main.w", c"code")
	char* clean_sub = vtt_mkdir(clean, c"src")
	vtt_write(clean_sub, c"lib.w", c"lib")

	char* noisy = vtt_mkdir(vtt_work(), c"ig_noisy")
	vtt_write(noisy, c"main.w", c"code")
	char* noisy_sub = vtt_mkdir(noisy, c"src")
	vtt_write(noisy_sub, c"lib.w", c"lib")
	char* noisy_bin = vtt_mkdir(noisy, c"bin")
	vtt_write(noisy_bin, c"junk", c"artifact")
	char* noisy_git = vtt_mkdir(noisy, c".git")
	vtt_write(noisy_git, c"config", c"[core]")
	char* nested_bin = vtt_mkdir(noisy_sub, c"bin")
	vtt_write(nested_bin, c"more", c"junk")

	list[char*] ignore = new list[char*]
	ignore.push(c"bin")
	ignore.push(c".git")

	char* clean_id = vtt_snapshot(s, clean, ignore)
	char* noisy_id = vtt_snapshot(s, noisy, ignore)
	assert_strings_equal(clean_id, noisy_id)

	# Without the ignore list the ids differ (and the junk blob is only
	# stored by THIS unfiltered snapshot -- pruning skips reads).
	char* junk_id = cas_id_hex(c"blob", c"artifact", 8)
	assert_equal(0, cas_has(s, junk_id))
	char* unfiltered_id = vtt_snapshot(s, noisy, 0)
	assert1(strcmp(clean_id, unfiltered_id) != 0)
	assert_equal(1, cas_has(s, junk_id))
	free(junk_id)

	free(clean_id)
	free(noisy_id)
	free(unfiltered_id)
	free(clean)
	free(clean_sub)
	free(noisy)
	free(noisy_sub)
	free(noisy_bin)
	free(noisy_git)
	free(nested_bin)
	cas_close(s)


void test_tree_snapshot_empty_directory():
	wcas* s = vtt_open()

	# An entirely empty directory snapshots to the empty tree id...
	char* bare = vtt_mkdir(vtt_work(), c"empty_root")
	char* bare_id = vtt_snapshot(s, bare, 0)
	wtree* none = tree_new()
	char* empty_id = tree_id_hex(none)
	tree_free(none)
	assert_strings_equal(empty_id, bare_id)
	assert_equal(1, cas_has(s, bare_id))

	# ...and an empty subdirectory is PRESERVED as a 40000 entry
	# pointing at that same empty tree (divergence from git, documented
	# in tree.w's header).
	char* holder = vtt_mkdir(vtt_work(), c"empty_holder")
	vtt_write(holder, c"kept.txt", c"kept")
	char* hollow = vtt_mkdir(holder, c"hollow")
	free(hollow)
	char* holder_id = vtt_snapshot(s, holder, 0)
	wtree* root = vtt_get(s, holder_id)
	assert_equal(2, root.entries.length)
	assert_strings_equal(c"hollow", root.entries[0].name)
	assert_equal(TREE_MODE_DIR(), root.entries[0].mode)
	assert_strings_equal(empty_id, root.entries[0].id)
	assert_strings_equal(c"kept.txt", root.entries[1].name)
	tree_free(root)

	free(empty_id)
	free(bare_id)
	free(holder_id)
	free(bare)
	free(holder)
	cas_close(s)


void test_tree_diff_added_removed_modified():
	wcas* s = vtt_open()

	# Version 1: a.txt, b.txt, del.txt, olddir/o.txt, sub/c.txt
	char* d1 = vtt_mkdir(vtt_work(), c"diff_v1")
	vtt_write(d1, c"a.txt", c"one")
	vtt_write(d1, c"b.txt", c"two")
	vtt_write(d1, c"del.txt", c"gone soon")
	char* olddir = vtt_mkdir(d1, c"olddir")
	vtt_write(olddir, c"o.txt", c"old")
	char* sub1 = vtt_mkdir(d1, c"sub")
	vtt_write(sub1, c"c.txt", c"three")

	# Version 2: b.txt modified, del.txt and olddir/ removed, new.txt
	# and subnew/n.txt added, a.txt and sub/ untouched.
	char* d2 = vtt_mkdir(vtt_work(), c"diff_v2")
	vtt_write(d2, c"a.txt", c"one")
	vtt_write(d2, c"b.txt", c"two changed")
	vtt_write(d2, c"new.txt", c"fresh")
	char* sub2 = vtt_mkdir(d2, c"sub")
	vtt_write(sub2, c"c.txt", c"three")
	char* subnew = vtt_mkdir(d2, c"subnew")
	vtt_write(subnew, c"n.txt", c"brand new")

	char* v1 = vtt_snapshot(s, d1, 0)
	char* v2 = vtt_snapshot(s, d2, 0)

	# Identical ids: zero changes (and, per tree.w, zero object reads).
	list[tree_change*] same = vtt_diff(s, v1, v1, 0)
	tree_changes_free(same)

	# The full change set, in deterministic depth-first order: the merge
	# walk interleaves both sides by name at each level (new.txt sorts
	# between del.txt and olddir). Removed directories expand
	# recursively; unchanged a.txt and sub/ produce nothing.
	list[tree_change*] changes = vtt_diff(s, v1, v2, 7)
	vtt_assert_change(changes, 0, c"b.txt", TREE_MODIFIED())
	vtt_assert_change(changes, 1, c"del.txt", TREE_REMOVED())
	vtt_assert_change(changes, 2, c"new.txt", TREE_ADDED())
	vtt_assert_change(changes, 3, c"olddir", TREE_REMOVED())
	vtt_assert_change(changes, 4, c"olddir/o.txt", TREE_REMOVED())
	vtt_assert_change(changes, 5, c"subnew", TREE_ADDED())
	vtt_assert_change(changes, 6, c"subnew/n.txt", TREE_ADDED())
	tree_changes_free(changes)

	# A null id is "no tree": everything on the other side is one-sided.
	list[tree_change*] all_added = vtt_diff(s, 0, v2, 7)
	vtt_assert_change(all_added, 0, c"a.txt", TREE_ADDED())
	vtt_assert_change(all_added, 4, c"sub/c.txt", TREE_ADDED())
	tree_changes_free(all_added)
	list[tree_change*] all_removed = vtt_diff(s, v1, 0, 7)
	vtt_assert_change(all_removed, 0, c"a.txt", TREE_REMOVED())
	vtt_assert_change(all_removed, 6, c"sub/c.txt", TREE_REMOVED())
	tree_changes_free(all_removed)
	list[tree_change*] nothing = vtt_diff(s, 0, 0, 0)
	tree_changes_free(nothing)

	free(v1)
	free(v2)
	free(d1)
	free(olddir)
	free(sub1)
	free(d2)
	free(sub2)
	free(subnew)
	cas_close(s)


void test_tree_diff_kind_and_mode_changes():
	wcas* s = vtt_open()

	# Kind change: "x" is a file in k1 and a directory in k2 -- the diff
	# is a removal of the old entry then the addition of the new one,
	# expanded.
	char* k1 = vtt_mkdir(vtt_work(), c"kind_v1")
	vtt_write(k1, c"x", c"plain file")
	char* k2 = vtt_mkdir(vtt_work(), c"kind_v2")
	char* x_dir = vtt_mkdir(k2, c"x")
	vtt_write(x_dir, c"y.txt", c"inside")
	char* kv1 = vtt_snapshot(s, k1, 0)
	char* kv2 = vtt_snapshot(s, k2, 0)
	list[tree_change*] kind = vtt_diff(s, kv1, kv2, 3)
	vtt_assert_change(kind, 0, c"x", TREE_REMOVED())
	vtt_assert_change(kind, 1, c"x", TREE_ADDED())
	vtt_assert_change(kind, 2, c"x/y.txt", TREE_ADDED())
	tree_changes_free(kind)

	# Mode flip: same blob id, 100644 -> 100755, reported as MODIFIED.
	# (Hand-built trees: the snapshot walker cannot observe the exec
	# bit yet -- see tree.w's header.)
	char* blob = vtt_fake_id('e')
	wtree* plain = tree_new()
	assert_equal(0, tree_add(plain, c"tool", TREE_MODE_FILE(), blob))
	wtree* exec = tree_new()
	assert_equal(0, tree_add(exec, c"tool", TREE_MODE_EXEC(), blob))
	wresult[char*]* p1 = tree_put(s, plain)
	assert1(result_is_ok[char*](p1))
	char* plain_id = result_value[char*](p1)
	result_free[char*](p1)
	wresult[char*]* p2 = tree_put(s, exec)
	assert1(result_is_ok[char*](p2))
	char* exec_id = result_value[char*](p2)
	result_free[char*](p2)
	assert1(strcmp(plain_id, exec_id) != 0)
	list[tree_change*] flipped = vtt_diff(s, plain_id, exec_id, 1)
	vtt_assert_change(flipped, 0, c"tool", TREE_MODIFIED())
	tree_changes_free(flipped)

	tree_free(plain)
	tree_free(exec)
	free(blob)
	free(plain_id)
	free(exec_id)
	free(kv1)
	free(kv2)
	free(k1)
	free(k2)
	free(x_dir)
	cas_close(s)


void test_tree_diff_skips_equal_subtrees():
	wcas* s = vtt_open()

	# The Merkle-skip proof: build two roots that SHARE a subtree id --
	# but never store that subtree's object (its id comes from the pure
	# tree_id_hex; its blob is never stored either). If the diff tried
	# to descend into the shared subtree, tree_get would fail with -2;
	# succeeding is only possible by skipping equal ids unread.
	char* shared_blob = cas_id_hex(c"blob", c"shared payload", 14)
	wtree* shared = tree_new()
	assert_equal(0, tree_add(shared, c"f", TREE_MODE_FILE(), shared_blob))
	char* shared_id = tree_id_hex(shared)
	tree_free(shared)
	assert_equal(0, cas_has(s, shared_id))

	char* blob1 = cas_id_hex(c"blob", c"v1", 2)
	char* blob2 = cas_id_hex(c"blob", c"v2", 2)
	wtree* r1 = tree_new()
	assert_equal(0, tree_add(r1, c"data", TREE_MODE_FILE(), blob1))
	assert_equal(0, tree_add(r1, c"shared", TREE_MODE_DIR(), shared_id))
	wtree* r2 = tree_new()
	assert_equal(0, tree_add(r2, c"data", TREE_MODE_FILE(), blob2))
	assert_equal(0, tree_add(r2, c"shared", TREE_MODE_DIR(), shared_id))
	wresult[char*]* pr1 = tree_put(s, r1)
	assert1(result_is_ok[char*](pr1))
	char* r1_id = result_value[char*](pr1)
	result_free[char*](pr1)
	wresult[char*]* pr2 = tree_put(s, r2)
	assert1(result_is_ok[char*](pr2))
	char* r2_id = result_value[char*](pr2)
	result_free[char*](pr2)

	list[tree_change*] changes = vtt_diff(s, r1_id, r2_id, 1)
	vtt_assert_change(changes, 0, c"data", TREE_MODIFIED())
	tree_changes_free(changes)

	# Negative control: point r3's "shared" at a DIFFERENT unstored id.
	# Now the pair differs, the walk must descend, and the missing
	# object surfaces as -2 -- proving differing subtrees ARE read.
	char* other_id = vtt_fake_id('f')
	wtree* r3 = tree_new()
	assert_equal(0, tree_add(r3, c"data", TREE_MODE_FILE(), blob1))
	assert_equal(0, tree_add(r3, c"shared", TREE_MODE_DIR(), other_id))
	wresult[char*]* pr3 = tree_put(s, r3)
	assert1(result_is_ok[char*](pr3))
	char* r3_id = result_value[char*](pr3)
	result_free[char*](pr3)
	list[tree_change*] out = new list[tree_change*]
	wresult[int]* denied = tree_diff(s, r1_id, r3_id, out)
	assert1(result_is_error[int](denied))
	assert_equal(-2, result_code[int](denied))
	result_free[int](denied)
	tree_changes_free(out)

	tree_free(r1)
	tree_free(r2)
	tree_free(r3)
	free(shared_blob)
	free(shared_id)
	free(blob1)
	free(blob2)
	free(other_id)
	free(r1_id)
	free(r2_id)
	free(r3_id)
	cas_close(s)


# Recursively deletes a fixture/store directory: collect this level's
# names first (deleting while iterating a getdents cursor is
# unreliable), then remove children before the directory itself.
void vtt_remove_all(char* path):
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
			vtt_remove_all(child)
			rmdir(child)
		else:
			vcs_unlink(child)
		free(child)
		free(names[i])
		i = i + 1


# Runs last (tests execute in definition order): removes the snapshot
# fixtures and the object store and asserts both roots rmdir cleanly,
# so the run leaves nothing behind under bin/.
void test_tree_cleanup():
	vtt_remove_all(vtt_work())
	assert_equal(0, rmdir(vtt_work()))
	vtt_remove_all(vtt_root())
	assert_equal(0, rmdir(vtt_root()))
