# wbuild: x64
/*
libs/extras/vcs/commit.w: commit objects, refs as files, and the
append-only reflog (issue #252 wave 2, V2b), layered on wave 1's
content-addressed store (libs/extras/vcs/cas.w).

Covers: commit encode/parse round-trips (0, 1, and 2 parents;
multi-line messages including embedded blank lines; a message whose
lines look like commit headers, proving the header/body split is not
fooled by it), commit_new's own input validation, store/load through a
real cas.w store (including the wrong-CAS-type rejection), ref
create/read/update/list, reflog append ordering across several updates
(including the zero-id sentinel for a ref's first entry and message
newline-flattening), and malformed-object/ref/reflog rejection.

Filesystem state lives under three independent pid-scoped roots under
bin/ (cas objects, refs+reflog, and a third root dedicated to the
ref_list test so its result can be asserted as an exact set without
interference from ref names other tests create) so the 32- and 64-bit
twins -- and concurrent runs -- never collide. The three cleanup tests
at the end remove everything they created and assert the directories
rmdir cleanly, which doubles as a check that no temp files leaked from
ref_write_atomic.
*/
import lib.testing
import libs.extras.vcs.commit
import libs.extras.vcs.cas


/* Shared fixtures */


char* vcst_pid_suffix_cache
char* vcst_pid_suffix():
	if (vcst_pid_suffix_cache == 0):
		vcst_pid_suffix_cache = itoa(getpid())
	return vcst_pid_suffix_cache


char* vcst_named_root(char* label):
	string_builder* p = string_new()
	string_append(p, c"bin/vcs_commit_test_")
	string_append(p, vcst_pid_suffix())
	string_append_char(p, '_')
	string_append(p, label)
	char* result = p.data
	free(p)
	return result


char* vcst_cas_root_cache
char* vcst_cas_root():
	if (vcst_cas_root_cache == 0):
		vcst_cas_root_cache = vcst_named_root(c"cas")
	return vcst_cas_root_cache


char* vcst_refs_root_cache
char* vcst_refs_root():
	if (vcst_refs_root_cache == 0):
		vcst_refs_root_cache = vcst_named_root(c"refs")
	return vcst_refs_root_cache


char* vcst_reflist_root_cache
char* vcst_reflist_root():
	if (vcst_reflist_root_cache == 0):
		vcst_reflist_root_cache = vcst_named_root(c"reflist")
	return vcst_reflist_root_cache


wcas* vcst_open_cas():
	wresult[wcas*]* r = cas_open(vcst_cas_root())
	assert1(result_is_ok[wcas*](r))
	wcas* s = result_value[wcas*](r)
	result_free[wcas*](r)
	return s


wrefs* vcst_open_refs():
	wresult[wrefs*]* r = refs_open(vcst_refs_root())
	assert1(result_is_ok[wrefs*](r))
	wrefs* rf = result_value[wrefs*](r)
	result_free[wrefs*](r)
	return rf


wrefs* vcst_open_reflist():
	wresult[wrefs*]* r = refs_open(vcst_reflist_root())
	assert1(result_is_ok[wrefs*](r))
	wrefs* rf = result_value[wrefs*](r)
	result_free[wrefs*](r)
	return rf


# Every commit id put into vcst_cas_root() during the run, so the final
# cleanup test can remove exactly what was created.
list[char*] vcst_commit_ids
void vcst_track_commit(char* id):
	if (vcst_commit_ids == 0):
		vcst_commit_ids = new list[char*]
	vcst_commit_ids.push(strclone(id))


# Every ref name created under vcst_refs_root() during the run.
list[char*] vcst_ref_names
void vcst_track_ref(char* name):
	if (vcst_ref_names == 0):
		vcst_ref_names = new list[char*]
	vcst_ref_names.push(strclone(name))


# A well-formed-but-arbitrary 64-hex id, derived from `seed` via cas.w's
# pure cas_id_hex -- no store needed. Used for tree/parent fields in
# tests that only care about the id's *shape*, not its provenance.
char* vcst_fake_id(char* seed):
	return cas_id_hex(c"blob", seed, strlen(seed))


/* Commit object: encode / parse round-trips */


void test_commit_roundtrip_no_parents():
	char* tree_id = vcst_fake_id(c"tree-0-parents")
	list[char*] parents = new list[char*]
	char* msg = c"initial commit"
	wresult[commit_object*]* built = commit_new(tree_id, parents, c"Ada Lovelace", 1000, msg, strlen(msg))
	assert1(result_is_ok[commit_object*](built))
	commit_object* co = result_value[commit_object*](built)
	result_free[commit_object*](built)

	string_builder* encoded = commit_encode(co)
	wresult[commit_object*]* parsed = commit_parse(encoded.data, encoded.length)
	assert1(result_is_ok[commit_object*](parsed))
	commit_object* back = result_value[commit_object*](parsed)
	result_free[commit_object*](parsed)

	assert_strings_equal(tree_id, back.tree_id)
	assert_equal(0, back.parent_ids.length)
	assert_strings_equal(c"Ada Lovelace", back.author)
	assert_equal(1000, back.timestamp)
	assert_equal(strlen(msg), back.message_length)
	assert_strings_equal(msg, back.message)

	string_free(encoded)
	commit_free(co)
	commit_free(back)
	free(tree_id)


void test_commit_roundtrip_one_parent():
	char* tree_id = vcst_fake_id(c"tree-1-parent")
	char* parent_id = vcst_fake_id(c"parent-1-of-1")
	list[char*] parents = new list[char*]
	parents.push(parent_id)
	char* msg = c"second commit"
	wresult[commit_object*]* built = commit_new(tree_id, parents, c"Bell Labs", 2000, msg, strlen(msg))
	assert1(result_is_ok[commit_object*](built))
	commit_object* co = result_value[commit_object*](built)
	result_free[commit_object*](built)

	string_builder* encoded = commit_encode(co)
	wresult[commit_object*]* parsed = commit_parse(encoded.data, encoded.length)
	assert1(result_is_ok[commit_object*](parsed))
	commit_object* back = result_value[commit_object*](parsed)
	result_free[commit_object*](parsed)

	assert_strings_equal(tree_id, back.tree_id)
	assert_equal(1, back.parent_ids.length)
	assert_strings_equal(parent_id, back.parent_ids[0])
	assert_strings_equal(c"Bell Labs", back.author)
	assert_equal(2000, back.timestamp)
	assert_strings_equal(msg, back.message)

	string_free(encoded)
	commit_free(co)
	commit_free(back)
	free(tree_id)
	free(parent_id)


void test_commit_roundtrip_two_parents():
	char* tree_id = vcst_fake_id(c"tree-2-parents")
	char* parent_a = vcst_fake_id(c"parent-a-of-2")
	char* parent_b = vcst_fake_id(c"parent-b-of-2")
	list[char*] parents = new list[char*]
	parents.push(parent_a)
	parents.push(parent_b)
	char* msg = c"merge commit"
	wresult[commit_object*]* built = commit_new(tree_id, parents, c"Merge Bot", 3000, msg, strlen(msg))
	assert1(result_is_ok[commit_object*](built))
	commit_object* co = result_value[commit_object*](built)
	result_free[commit_object*](built)

	string_builder* encoded = commit_encode(co)
	wresult[commit_object*]* parsed = commit_parse(encoded.data, encoded.length)
	assert1(result_is_ok[commit_object*](parsed))
	commit_object* back = result_value[commit_object*](parsed)
	result_free[commit_object*](parsed)

	assert_strings_equal(tree_id, back.tree_id)
	assert_equal(2, back.parent_ids.length)
	# Parent order is preserved exactly (git-meaningful: first parent is
	# the "mainline").
	assert_strings_equal(parent_a, back.parent_ids[0])
	assert_strings_equal(parent_b, back.parent_ids[1])
	assert_strings_equal(c"Merge Bot", back.author)
	assert_equal(3000, back.timestamp)
	assert_strings_equal(msg, back.message)

	string_free(encoded)
	commit_free(co)
	commit_free(back)
	free(tree_id)
	free(parent_a)
	free(parent_b)


void test_commit_roundtrip_multiline_message():
	char* tree_id = vcst_fake_id(c"tree-multiline")
	list[char*] parents = new list[char*]
	string_builder* message = string_new()
	string_append(message, c"Title line\n\n")
	string_append(message, c"Body paragraph one.\n")
	string_append(message, c"Body paragraph two.\n\n")
	string_append(message, c"Trailer: ok\n")

	wresult[commit_object*]* built = commit_new(tree_id, parents, c"Author", 4000, message.data, message.length)
	assert1(result_is_ok[commit_object*](built))
	commit_object* co = result_value[commit_object*](built)
	result_free[commit_object*](built)

	string_builder* encoded = commit_encode(co)
	wresult[commit_object*]* parsed = commit_parse(encoded.data, encoded.length)
	assert1(result_is_ok[commit_object*](parsed))
	commit_object* back = result_value[commit_object*](parsed)
	result_free[commit_object*](parsed)

	assert_equal(message.length, back.message_length)
	assert_strings_equal(message.data, back.message)

	string_free(message)
	string_free(encoded)
	commit_free(co)
	commit_free(back)
	free(tree_id)


# A message whose own lines look exactly like commit headers ("tree ",
# "parent ", "author ", "timestamp ") must never be reinterpreted: the
# header/body split happens once, at the real blank-line separator, and
# everything after that is message text no matter its shape.
void test_commit_message_with_header_lookalike_lines():
	char* tree_id = vcst_fake_id(c"lookalike-tree")
	char* fake_inner_tree = vcst_fake_id(c"fake-inner-tree")
	list[char*] parents = new list[char*]
	string_builder* message = string_new()
	string_append(message, c"Summary line\n\n")
	string_append(message, c"tree ")
	string_append(message, fake_inner_tree)
	string_append(message, c"\n")
	string_append(message, c"parent 1234\n")
	string_append(message, c"author impostor\n")
	string_append(message, c"timestamp 99\n")
	string_append(message, c"\n")
	string_append(message, c"Still part of the message.\n")

	wresult[commit_object*]* built = commit_new(tree_id, parents, c"Real Author", 42, message.data, message.length)
	assert1(result_is_ok[commit_object*](built))
	commit_object* co = result_value[commit_object*](built)
	result_free[commit_object*](built)

	string_builder* encoded = commit_encode(co)
	wresult[commit_object*]* parsed = commit_parse(encoded.data, encoded.length)
	assert1(result_is_ok[commit_object*](parsed))
	commit_object* back = result_value[commit_object*](parsed)
	result_free[commit_object*](parsed)

	# The outer commit's real fields are unaffected by the message's
	# header-shaped lines.
	assert_strings_equal(tree_id, back.tree_id)
	assert_equal(0, back.parent_ids.length)
	assert_strings_equal(c"Real Author", back.author)
	assert_equal(42, back.timestamp)
	assert_equal(message.length, back.message_length)
	assert_strings_equal(message.data, back.message)

	string_free(message)
	string_free(encoded)
	commit_free(co)
	commit_free(back)
	free(tree_id)
	free(fake_inner_tree)


void test_commit_new_rejects_invalid_ids():
	list[char*] parents = new list[char*]
	wresult[commit_object*]* bad_tree = commit_new(c"not-a-valid-tree-id", parents, c"a", 1, c"m", 1)
	assert1(result_is_error[commit_object*](bad_tree))
	assert_equal(-22, result_code[commit_object*](bad_tree))
	result_free[commit_object*](bad_tree)

	char* tree_id = vcst_fake_id(c"commit-new-validation")
	list[char*] bad_parents = new list[char*]
	bad_parents.push(c"still-not-hex")
	wresult[commit_object*]* bad_parent = commit_new(tree_id, bad_parents, c"a", 1, c"m", 1)
	assert1(result_is_error[commit_object*](bad_parent))
	assert_equal(-22, result_code[commit_object*](bad_parent))
	result_free[commit_object*](bad_parent)
	free(tree_id)


/* Store / load through a real cas.w store */


void test_commit_store_load_via_cas():
	wcas* store = vcst_open_cas()
	char* tree_id = vcst_fake_id(c"integration-tree")
	list[char*] parents = new list[char*]
	char* msg = c"first"
	wresult[commit_object*]* built = commit_new(tree_id, parents, c"Grace Hopper", 500, msg, strlen(msg))
	assert1(result_is_ok[commit_object*](built))
	commit_object* co = result_value[commit_object*](built)
	result_free[commit_object*](built)

	wresult[char*]* stored = commit_store(store, co)
	assert1(result_is_ok[char*](stored))
	char* id = result_value[char*](stored)
	result_free[char*](stored)
	vcst_track_commit(id)
	assert1(cas_valid_id(id));
	assert_equal(1, cas_has(store, id))

	wresult[commit_object*]* loaded = commit_load(store, id)
	assert1(result_is_ok[commit_object*](loaded))
	commit_object* back = result_value[commit_object*](loaded)
	result_free[commit_object*](loaded)
	assert_strings_equal(tree_id, back.tree_id)
	assert_strings_equal(c"Grace Hopper", back.author)
	assert_equal(500, back.timestamp)
	assert_strings_equal(msg, back.message)

	commit_free(co)
	commit_free(back)
	free(tree_id)
	free(id)
	cas_close(store)


void test_commit_load_wrong_type():
	wcas* store = vcst_open_cas()
	char* payload = c"not a commit"
	wresult[char*]* put = cas_put(store, c"blob", payload, strlen(payload))
	assert1(result_is_ok[char*](put))
	char* id = result_value[char*](put)
	result_free[char*](put)
	vcst_track_commit(id)

	wresult[commit_object*]* loaded = commit_load(store, id)
	assert1(result_is_error[commit_object*](loaded))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[commit_object*](loaded))
	result_free[commit_object*](loaded)
	free(id)
	cas_close(store)


/* Malformed commit objects */


void test_commit_malformed_rejection():
	# Missing "tree " prefix entirely.
	char* bad1 = c"not a commit at all"
	wresult[commit_object*]* r1 = commit_parse(bad1, strlen(bad1))
	assert1(result_is_error[commit_object*](r1))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[commit_object*](r1))
	result_free[commit_object*](r1)

	# tree id present but the wrong length/shape.
	char* bad2 = c"tree deadbeef\nauthor a\ntimestamp 1\n\nmsg"
	wresult[commit_object*]* r2 = commit_parse(bad2, strlen(bad2))
	assert1(result_is_error[commit_object*](r2))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[commit_object*](r2))
	result_free[commit_object*](r2)

	char* tree_id = vcst_fake_id(c"malformed-tests")

	# Missing author line (jumps straight to timestamp).
	string_builder* bad3 = string_new()
	string_append(bad3, c"tree ")
	string_append(bad3, tree_id)
	string_append(bad3, c"\ntimestamp 1\n\nmsg")
	wresult[commit_object*]* r3 = commit_parse(bad3.data, bad3.length)
	assert1(result_is_error[commit_object*](r3))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[commit_object*](r3))
	result_free[commit_object*](r3)
	string_free(bad3)

	# Missing timestamp line entirely.
	string_builder* bad4 = string_new()
	string_append(bad4, c"tree ")
	string_append(bad4, tree_id)
	string_append(bad4, c"\nauthor a\n\nmsg")
	wresult[commit_object*]* r4 = commit_parse(bad4.data, bad4.length)
	assert1(result_is_error[commit_object*](r4))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[commit_object*](r4))
	result_free[commit_object*](r4)
	string_free(bad4)

	# Non-numeric timestamp.
	string_builder* bad5 = string_new()
	string_append(bad5, c"tree ")
	string_append(bad5, tree_id)
	string_append(bad5, c"\nauthor a\ntimestamp soon\n\nmsg")
	wresult[commit_object*]* r5 = commit_parse(bad5.data, bad5.length)
	assert1(result_is_error[commit_object*](r5))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[commit_object*](r5))
	result_free[commit_object*](r5)
	string_free(bad5)

	# Missing blank-line separator: EOF right after the timestamp line.
	string_builder* bad6 = string_new()
	string_append(bad6, c"tree ")
	string_append(bad6, tree_id)
	string_append(bad6, c"\nauthor a\ntimestamp 1\n")
	wresult[commit_object*]* r6 = commit_parse(bad6.data, bad6.length)
	assert1(result_is_error[commit_object*](r6))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[commit_object*](r6))
	result_free[commit_object*](r6)
	string_free(bad6)

	# Invalid parent id.
	string_builder* bad7 = string_new()
	string_append(bad7, c"tree ")
	string_append(bad7, tree_id)
	string_append(bad7, c"\nparent not-hex\nauthor a\ntimestamp 1\n\nmsg")
	wresult[commit_object*]* r7 = commit_parse(bad7.data, bad7.length)
	assert1(result_is_error[commit_object*](r7))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[commit_object*](r7))
	result_free[commit_object*](r7)
	string_free(bad7)

	# Completely empty object.
	wresult[commit_object*]* r8 = commit_parse(c"", 0)
	assert1(result_is_error[commit_object*](r8))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[commit_object*](r8))
	result_free[commit_object*](r8)

	free(tree_id)


/* Refs as files */


void test_refs_create_read_update():
	wrefs* refs = vcst_open_refs()
	char* id1 = vcst_fake_id(c"ref-create-1")
	char* id2 = vcst_fake_id(c"ref-create-2")

	assert_equal(0, ref_exists(refs, c"main"))
	wresult[int]* created = ref_create(refs, c"main", id1, c"init")
	assert1(result_is_ok[int](created))
	result_free[int](created)
	vcst_track_ref(c"main")
	assert_equal(1, ref_exists(refs, c"main"))

	wresult[char*]* read1 = ref_read(refs, c"main")
	assert1(result_is_ok[char*](read1))
	char* got1 = result_value[char*](read1)
	result_free[char*](read1)
	assert_strings_equal(id1, got1)
	free(got1)

	wresult[int]* updated = ref_update(refs, c"main", id2, c"advance")
	assert1(result_is_ok[int](updated))
	result_free[int](updated)

	wresult[char*]* read2 = ref_read(refs, c"main")
	assert1(result_is_ok[char*](read2))
	char* got2 = result_value[char*](read2)
	result_free[char*](read2)
	assert_strings_equal(id2, got2)
	free(got2)

	free(id1)
	free(id2)
	refs_close(refs)


void test_refs_reject_bad_operations():
	wrefs* refs = vcst_open_refs()
	char* id1 = vcst_fake_id(c"ref-reject-1")

	wresult[int]* created = ref_create(refs, c"guarded", id1, c"init")
	assert1(result_is_ok[int](created))
	result_free[int](created)
	vcst_track_ref(c"guarded")

	# Creating an already-existing ref fails.
	wresult[int]* dup = ref_create(refs, c"guarded", id1, c"again")
	assert1(result_is_error[int](dup))
	assert_equal(-17, result_code[int](dup))
	result_free[int](dup)

	# Updating a ref that was never created fails.
	wresult[int]* missing = ref_update(refs, c"never-created", id1, c"noop")
	assert1(result_is_error[int](missing))
	assert_equal(-2, result_code[int](missing))
	result_free[int](missing)
	wresult[char*]* missing_read = ref_read(refs, c"never-created")
	assert1(result_is_error[char*](missing_read))
	assert_equal(-2, result_code[char*](missing_read))
	result_free[char*](missing_read)

	# Name validation.
	assert_equal(0, ref_valid_name(c""))
	assert_equal(0, ref_valid_name(c"has/slash"))
	assert_equal(0, ref_valid_name(c".leadingdot"))
	assert_equal(0, ref_valid_name(c"trailingdot."))
	assert_equal(0, ref_valid_name(c"tmp_reserved"))
	assert_equal(1, ref_valid_name(c"release-1.0"))

	wresult[int]* bad_name = ref_create(refs, c"has/slash", id1, c"x")
	assert1(result_is_error[int](bad_name))
	assert_equal(-22, result_code[int](bad_name))
	result_free[int](bad_name)

	# Id validation.
	char* not_hex = c"not-hex"
	wresult[int]* bad_id = ref_create(refs, c"another", not_hex, c"x")
	assert1(result_is_error[int](bad_id))
	assert_equal(-22, result_code[int](bad_id))
	result_free[int](bad_id)

	free(id1)
	refs_close(refs)


void test_ref_corrupted_file_rejected():
	wrefs* refs = vcst_open_refs()
	char* id1 = vcst_fake_id(c"ref-corrupt-1")
	wresult[int]* created = ref_create(refs, c"corrupt-me", id1, c"init")
	assert1(result_is_ok[int](created))
	result_free[int](created)
	vcst_track_ref(c"corrupt-me")

	char* path = ref_path(refs, c"corrupt-me")
	wstream* out = stream_open_write(path)
	assert1(cast(int, out) != 0)
	char* garbage = c"not sixty four hex chars\n"
	stream_write(out, garbage, strlen(garbage))
	stream_close(out)
	free(path)

	wresult[char*]* read = ref_read(refs, c"corrupt-me")
	assert1(result_is_error[char*](read))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[char*](read))
	result_free[char*](read)

	free(id1)
	refs_close(refs)


/* Reflog */


void test_reflog_append_ordering():
	wcas* store = vcst_open_cas()
	wrefs* refs = vcst_open_refs()

	list[char*] no_parents = new list[char*]
	char* tree1 = vcst_fake_id(c"reflog-tree-1")
	wresult[commit_object*]* b1 = commit_new(tree1, no_parents, c"Alice", 100, c"c1", strlen(c"c1"))
	commit_object* co1 = result_value[commit_object*](b1)
	result_free[commit_object*](b1)
	wresult[char*]* s1 = commit_store(store, co1)
	char* commit1 = result_value[char*](s1)
	result_free[char*](s1)
	vcst_track_commit(commit1)

	list[char*] parents2 = new list[char*]
	parents2.push(commit1)
	char* tree2 = vcst_fake_id(c"reflog-tree-2")
	wresult[commit_object*]* b2 = commit_new(tree2, parents2, c"Bob", 200, c"c2", strlen(c"c2"))
	commit_object* co2 = result_value[commit_object*](b2)
	result_free[commit_object*](b2)
	wresult[char*]* s2 = commit_store(store, co2)
	char* commit2 = result_value[char*](s2)
	result_free[char*](s2)
	vcst_track_commit(commit2)

	list[char*] parents3 = new list[char*]
	parents3.push(commit2)
	char* tree3 = vcst_fake_id(c"reflog-tree-3")
	wresult[commit_object*]* b3 = commit_new(tree3, parents3, c"Carol", 300, c"c3", strlen(c"c3"))
	commit_object* co3 = result_value[commit_object*](b3)
	result_free[commit_object*](b3)
	wresult[char*]* s3 = commit_store(store, co3)
	char* commit3 = result_value[char*](s3)
	result_free[char*](s3)
	vcst_track_commit(commit3)

	# Before any create/update, the reflog is empty -- not an error.
	wresult[list[reflog_entry*]]* before = reflog_read(refs, c"history")
	assert1(result_is_ok[list[reflog_entry*]](before))
	assert_equal(0, result_value[list[reflog_entry*]](before).length)
	result_free[list[reflog_entry*]](before)

	wresult[int]* c1r = ref_create(refs, c"history", commit1, c"commit: c1")
	assert1(result_is_ok[int](c1r))
	result_free[int](c1r)
	vcst_track_ref(c"history")
	wresult[int]* c2r = ref_update(refs, c"history", commit2, c"commit: c2")
	assert1(result_is_ok[int](c2r))
	result_free[int](c2r)
	wresult[int]* c3r = ref_update(refs, c"history", commit3, c"commit:\nc3 has\nembedded newlines")
	assert1(result_is_ok[int](c3r))
	result_free[int](c3r)

	wresult[list[reflog_entry*]]* after = reflog_read(refs, c"history")
	assert1(result_is_ok[list[reflog_entry*]](after))
	list[reflog_entry*] entries = result_value[list[reflog_entry*]](after)
	assert_equal(3, entries.length)

	# A brand-new ref's first reflog entry has the all-zero sentinel as
	# its old id.
	assert_strings_equal(REF_ZERO_ID(), entries[0].old_id)
	assert_strings_equal(commit1, entries[0].new_id)
	assert_strings_equal(c"commit: c1", entries[0].message)

	assert_strings_equal(commit1, entries[1].old_id)
	assert_strings_equal(commit2, entries[1].new_id)
	assert_strings_equal(c"commit: c2", entries[1].message)

	# Embedded '\n' in the caller's message is flattened to spaces, so
	# the log stays exactly one line per update.
	assert_strings_equal(commit2, entries[2].old_id)
	assert_strings_equal(commit3, entries[2].new_id)
	assert_strings_equal(c"commit: c3 has embedded newlines", entries[2].message)

	assert1(entries[0].timestamp <= entries[1].timestamp)
	assert1(entries[1].timestamp <= entries[2].timestamp)

	for reflog_entry* e in entries:
		reflog_entry_free(e)
	list_free[reflog_entry*](entries)
	result_free[list[reflog_entry*]](after)

	commit_free(co1)
	commit_free(co2)
	commit_free(co3)
	free(tree1)
	free(tree2)
	free(tree3)
	refs_close(refs)
	cas_close(store)


void test_reflog_malformed_line_rejected():
	wrefs* refs = vcst_open_refs()
	char* id1 = vcst_fake_id(c"reflog-malformed-1")
	wresult[int]* created = ref_create(refs, c"bad-log", id1, c"init")
	assert1(result_is_ok[int](created))
	result_free[int](created)
	vcst_track_ref(c"bad-log")

	char* path = reflog_path(refs, c"bad-log")
	wstream* out = stream_open_write(path)
	assert1(cast(int, out) != 0)
	stream_write_cstr(out, c"this is not a reflog line\n")
	stream_close(out)
	free(path)

	wresult[list[reflog_entry*]]* r = reflog_read(refs, c"bad-log")
	assert1(result_is_error[list[reflog_entry*]](r))
	assert_equal(COMMIT_ERR_MALFORMED(), result_code[list[reflog_entry*]](r))
	result_free[list[reflog_entry*]](r)

	free(id1)
	refs_close(refs)


/* ref_list, in its own root so the result can be asserted exactly */


void test_ref_list_returns_sorted_names():
	wrefs* refs = vcst_open_reflist()
	char* id1 = vcst_fake_id(c"list-1")
	char* id2 = vcst_fake_id(c"list-2")
	char* id3 = vcst_fake_id(c"list-3")

	wresult[int]* r1 = ref_create(refs, c"main", id1, c"m")
	assert1(result_is_ok[int](r1))
	result_free[int](r1)
	wresult[int]* r2 = ref_create(refs, c"alpha", id2, c"a")
	assert1(result_is_ok[int](r2))
	result_free[int](r2)
	wresult[int]* r3 = ref_create(refs, c"release-1.0", id3, c"r")
	assert1(result_is_ok[int](r3))
	result_free[int](r3)

	wresult[list[char*]]* listed = ref_list(refs)
	assert1(result_is_ok[list[char*]](listed))
	list[char*] names = result_value[list[char*]](listed)
	assert_equal(3, names.length)
	assert_strings_equal(c"alpha", names[0])
	assert_strings_equal(c"main", names[1])
	assert_strings_equal(c"release-1.0", names[2])

	for char* n in names:
		free(n)
	list_free[char*](names)
	result_free[list[char*]](listed)

	free(id1)
	free(id2)
	free(id3)
	refs_close(refs)


/* Cleanup: runs last (tests execute in definition order). Removes
   exactly what each test created and asserts every directory rmdir's
   cleanly, proving nothing (including ref_write_atomic's temp files)
   leaked. */


void test_commit_cleanup_cas_store():
	wcas* s = vcst_open_cas()
	assert1(vcst_commit_ids != 0)
	for char* id in vcst_commit_ids:
		string_builder* p = string_new()
		string_append(p, vcst_cas_root())
		string_append(p, c"/objects/")
		string_append_char(p, id[0])
		string_append_char(p, id[1])
		string_append_char(p, '/')
		string_append(p, id + 2)
		vcs_unlink(p.data)   # duplicates return -2; ignored
		string_free(p)
	for char* fan_id in vcst_commit_ids:
		string_builder* d = string_new()
		string_append(d, vcst_cas_root())
		string_append(d, c"/objects/")
		string_append_char(d, fan_id[0])
		string_append_char(d, fan_id[1])
		rmdir(d.data)   # duplicates return -2; ignored
		string_free(d)
	char* objects = path_join(vcst_cas_root(), c"objects")
	assert_equal(0, rmdir(objects))
	free(objects)
	assert_equal(0, rmdir(vcst_cas_root()))
	cas_close(s)


void test_commit_cleanup_refs_store():
	wrefs* r = vcst_open_refs()
	assert1(vcst_ref_names != 0)
	for char* name in vcst_ref_names:
		char* rp = ref_path(r, name)
		vcs_unlink(rp)
		free(rp)
		char* lp = reflog_path(r, name)
		vcs_unlink(lp)
		free(lp)
	assert_equal(0, rmdir(r.heads_dir))
	char* refs_dir = path_join(r.root, c"refs")
	assert_equal(0, rmdir(refs_dir))
	free(refs_dir)
	assert_equal(0, rmdir(r.logs_dir))
	assert_equal(0, rmdir(r.root))
	refs_close(r)


void test_commit_cleanup_reflist_store():
	wrefs* r = vcst_open_reflist()
	list[char*] names = new list[char*]
	names.push(c"main")
	names.push(c"alpha")
	names.push(c"release-1.0")
	for char* name in names:
		char* rp = ref_path(r, name)
		vcs_unlink(rp)
		free(rp)
		char* lp = reflog_path(r, name)
		vcs_unlink(lp)
		free(lp)
	assert_equal(0, rmdir(r.heads_dir))
	char* refs_dir = path_join(r.root, c"refs")
	assert_equal(0, rmdir(refs_dir))
	free(refs_dir)
	assert_equal(0, rmdir(r.logs_dir))
	assert_equal(0, rmdir(r.root))
	refs_close(r)
