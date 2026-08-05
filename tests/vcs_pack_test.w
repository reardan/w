# wbuild: x64
/*
libs/extras/vcs/pack.w: pack files over the cas.w loose-object store
(VCS wave-3 remainder, issue #252 "compress-based object packing" --
see pack.w's header comment for the file format).

Covers, in definition order (lib.testing runs test_* functions in the
order they are defined):
  - populating a store with every object species the pack path must
    preserve: plain blobs (one with embedded NUL bytes), a cas_put_raw
    entry whose id is a NAME rather than a content hash (the
    build-cache client), and a delta.w chain (whose id is the hash of
    the RECONSTRUCTED content, not the stored "delta" payload) -- the
    two cases that forbid pack/unpack from re-verifying ids by rehash;
  - pack_store_loose with pruning: every loose file gone, then
    cas_has/cas_get/cas_verify (and delta.w's cas_get_resolved) all
    answering through cas.w's fallback seam from the pack alone,
    including cas_verify's 1-for-content-hash / 0-for-raw-put split
    surviving the re-encoding;
  - cas_put dedup against a packed object: re-putting bytes that only
    exist packed must NOT re-grow a loose copy (the cas_put change from
    path_exists to cas_has, asserted at the file level);
  - unpack: pack_unpack_all restores every loose file BYTE-identically
    (the deterministic zlib encoder makes the on-disk encoding
    reproducible, not just the logical bytes) and removes the pack
    file; re-packing the restored store reproduces the SAME pack file
    name (the pack is named by the sha256 of its own bytes, and its
    bytes are a deterministic function of the object set);
  - corrupt packs: a garbage .wpack and a well-formed-header pack whose
    entry lies about its bounds both read as "object missing" through
    the fallback seam (no error channel there) but fail
    pack_unpack_all loudly with PACK_ERR_MALFORMED.

The store root is pid- and word-size-scoped under bin/ so the 32- and
64-bit twins can run in parallel; the final test removes everything the
run created and asserts the directories rmdir cleanly, which doubles as
a check that no temp files leaked from the pack write path.
*/
import lib.testing
import lib.path
import structures.string
import libs.extras.vcs.cas
import libs.extras.vcs.delta
import libs.extras.vcs.pack
import libs.extras.vcs.__arch__.fsops


char* vcpt_root_cache
char* vcpt_root():
	if (vcpt_root_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/vcs_pack_test_")
		string_append_int(p, getpid())
		string_append_char(p, '_')
		string_append_int(p, __word_size__ * 8)
		vcpt_root_cache = p.data
		free(p)
	return vcpt_root_cache


wcas* vcpt_open():
	wresult[wcas*]* r = cas_open(vcpt_root())
	assert1(result_is_ok[wcas*](r))
	wcas* s = result_value[wcas*](r)
	result_free[wcas*](r)
	return s


void vcpt_assert_bytes_equal(char* want, int want_len, char* got, int got_len):
	assert_equal(want_len, got_len)
	int i = 0
	while (i < want_len):
		assert_equal(want[i] & 255, got[i] & 255)
		i = i + 1


# The ids stored by test_pack_populate_store, and each one's loose
# on-disk file bytes as recorded BEFORE packing -- the byte-identity
# baseline test_pack_unpack_round_trip compares against.
list[char*] vcpt_ids
list[string_builder*] vcpt_loose_bytes
char* vcpt_blob_id
char* vcpt_nul_id
char* vcpt_raw_id
char* vcpt_base_id
char* vcpt_delta_id
char* vcpt_pack_path


char* VCPT_BLOB_CONTENT():
	return c"pack me: the same line repeats. the same line repeats. the same line repeats."


char* VCPT_RAW_KEY():
	return c"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"


char* VCPT_RAW_CONTENT():
	return c"keyed cache entry (id is a name, not a content hash)"


# A NUL-riddled binary payload (deterministic, so later tests can
# rebuild the same bytes to compare against).
int VCPT_NUL_LEN():
	return 96


char* vcpt_nul_content():
	char* buf = malloc(VCPT_NUL_LEN() + 1)
	int i = 0
	while (i < VCPT_NUL_LEN()):
		if ((i % 7) == 0):
			buf[i] = 0
		else:
			buf[i] = 'A' + (i % 23)
		i = i + 1
	buf[VCPT_NUL_LEN()] = 0
	return buf


# Base/target pair for the delta chain: enough shared block-aligned
# content that delta_diff really emits COPY ops (DELTA_BLOCK_SIZE is
# 64), though the test only relies on round-trip correctness.
string_builder* vcpt_base_content():
	string_builder* b = string_new()
	int i = 0
	while (i < 192):
		string_append_char(b, 'x' + (i % 3))
		i = i + 1
	string_append(b, c" shared tail of the base object")
	return b


string_builder* vcpt_target_content():
	string_builder* t = vcpt_base_content()
	string_append(t, c" plus new target bytes only the delta carries")
	return t


char* vcpt_put_blob(wcas* s, char* data, int length):
	wresult[char*]* r = cas_put(s, c"blob", data, length)
	assert1(result_is_ok[char*](r))
	char* id = result_value[char*](r)
	result_free[char*](r)
	return id


# Reads one loose object's raw on-disk bytes (0 for "no such file"
# asserted away -- callers only use this on ids they know are loose).
string_builder* vcpt_read_loose(wcas* s, char* id):
	char* path = cas_object_path(s, id)
	string_builder* contents = cas_read_file(path)
	free(path)
	assert1(contents != 0)
	return contents


int vcpt_loose_exists(wcas* s, char* id):
	char* path = cas_object_path(s, id)
	int present = path_exists(path)
	free(path)
	return present


void test_pack_populate_store():
	wcas* s = vcpt_open()
	vcpt_ids = new list[char*]
	vcpt_loose_bytes = new list[string_builder*]

	char* blob = VCPT_BLOB_CONTENT()
	vcpt_blob_id = vcpt_put_blob(s, blob, strlen(blob))
	vcpt_ids.push(vcpt_blob_id)

	char* nul_content = vcpt_nul_content()
	vcpt_nul_id = vcpt_put_blob(s, nul_content, VCPT_NUL_LEN())
	free(nul_content)
	vcpt_ids.push(vcpt_nul_id)

	# The build-cache species: a keyed put whose id is not the hash of
	# its bytes.
	wresult[char*]* raw_r = cas_put_raw(s, VCPT_RAW_KEY(), c"out", VCPT_RAW_CONTENT(), strlen(VCPT_RAW_CONTENT()))
	assert1(result_is_ok[char*](raw_r))
	vcpt_raw_id = result_value[char*](raw_r)
	result_free[char*](raw_r)
	vcpt_ids.push(vcpt_raw_id)

	# The delta species: stored payload is a "delta" chain, id is the
	# reconstructed target's content hash.
	string_builder* base = vcpt_base_content()
	vcpt_base_id = vcpt_put_blob(s, base.data, base.length)
	vcpt_ids.push(vcpt_base_id)
	string_builder* target = vcpt_target_content()
	wresult[char*]* delta_r = cas_put_delta(s, vcpt_base_id, c"blob", target.data, target.length)
	assert1(result_is_ok[char*](delta_r))
	vcpt_delta_id = result_value[char*](delta_r)
	result_free[char*](delta_r)
	vcpt_ids.push(vcpt_delta_id)
	string_free(base)
	string_free(target)

	# Record every loose file's exact on-disk bytes before packing.
	for char* id in vcpt_ids:
		vcpt_loose_bytes.push(vcpt_read_loose(s, id))
	cas_close(s)


void test_pack_store_prune_and_read_through():
	wcas* s = vcpt_open()
	pack_attach(s)

	wresult[pack_stats*]* st_r = pack_store_loose(s, 1)
	assert1(result_is_ok[pack_stats*](st_r))
	pack_stats* st = result_value[pack_stats*](st_r)
	result_free[pack_stats*](st_r)
	assert_equal(vcpt_ids.length, st.objects)
	assert_equal(1, st.packs)
	assert1(st.pack_path != 0)
	assert1(path_exists(st.pack_path))
	vcpt_pack_path = strclone(st.pack_path)
	pack_stats_free(st)

	# Every loose file is gone, yet every object still answers through
	# the fallback seam.
	for char* id in vcpt_ids:
		assert_equal(0, vcpt_loose_exists(s, id))
		assert_equal(1, cas_has(s, id))

	wresult[wcas_object*]* got = cas_get(s, vcpt_blob_id)
	assert1(result_is_ok[wcas_object*](got))
	wcas_object* obj = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	assert_strings_equal(c"blob", obj.object_type)
	vcpt_assert_bytes_equal(VCPT_BLOB_CONTENT(), strlen(VCPT_BLOB_CONTENT()), obj.data, obj.length)
	cas_object_free(obj)

	char* nul_content = vcpt_nul_content()
	got = cas_get(s, vcpt_nul_id)
	assert1(result_is_ok[wcas_object*](got))
	obj = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	vcpt_assert_bytes_equal(nul_content, VCPT_NUL_LEN(), obj.data, obj.length)
	cas_object_free(obj)
	free(nul_content)

	got = cas_get(s, vcpt_raw_id)
	assert1(result_is_ok[wcas_object*](got))
	obj = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	assert_strings_equal(c"out", obj.object_type)
	vcpt_assert_bytes_equal(VCPT_RAW_CONTENT(), strlen(VCPT_RAW_CONTENT()), obj.data, obj.length)
	cas_object_free(obj)

	# The delta object's raw form still reads as a "delta" chain, and
	# the layered read still reconstructs the target -- both from the
	# pack.
	got = cas_get(s, vcpt_delta_id)
	assert1(result_is_ok[wcas_object*](got))
	obj = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	assert_strings_equal(DELTA_OBJECT_TYPE(), obj.object_type)
	cas_object_free(obj)
	string_builder* target = vcpt_target_content()
	got = cas_get_resolved(s, vcpt_delta_id)
	assert1(result_is_ok[wcas_object*](got))
	obj = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	assert_strings_equal(c"blob", obj.object_type)
	vcpt_assert_bytes_equal(target.data, target.length, obj.data, obj.length)
	cas_object_free(obj)
	string_free(target)

	# cas_verify through the pack: content-hash ids verify, the raw-put
	# key (a name) and the delta id (hash of the RECONSTRUCTED content)
	# report 0 -- exactly the loose-store behavior, surviving packing.
	assert_equal(1, cas_verify(s, vcpt_blob_id))
	assert_equal(1, cas_verify(s, vcpt_nul_id))
	assert_equal(0, cas_verify(s, vcpt_raw_id))
	assert_equal(0, cas_verify(s, vcpt_delta_id))

	# An id in no pack is still a clean miss.
	char* missing = c"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
	assert_equal(0, cas_has(s, missing))
	got = cas_get(s, missing)
	assert1(result_is_error[wcas_object*](got))
	assert_equal(-2, result_code[wcas_object*](got))
	result_free[wcas_object*](got)

	cas_close(s)


void test_pack_put_dedups_against_pack():
	wcas* s = vcpt_open()
	pack_attach(s)
	# Re-putting bytes whose object only exists packed must dedup (via
	# cas_has consulting the pack), NOT re-grow a loose copy.
	char* blob = VCPT_BLOB_CONTENT()
	char* id = vcpt_put_blob(s, blob, strlen(blob))
	assert_strings_equal(vcpt_blob_id, id)
	free(id)
	assert_equal(0, vcpt_loose_exists(s, vcpt_blob_id))
	cas_close(s)


void test_pack_unpack_round_trip():
	wcas* s = vcpt_open()
	pack_attach(s)

	wresult[pack_stats*]* st_r = pack_unpack_all(s)
	assert1(result_is_ok[pack_stats*](st_r))
	pack_stats* st = result_value[pack_stats*](st_r)
	result_free[pack_stats*](st_r)
	assert_equal(vcpt_ids.length, st.objects)
	assert_equal(1, st.packs)
	pack_stats_free(st)
	assert_equal(0, path_exists(vcpt_pack_path))

	# Every loose file is back, byte-for-byte as recorded before the
	# pack (same deterministic zlib encoding, same level).
	int i = 0
	while (i < vcpt_ids.length):
		string_builder* restored = vcpt_read_loose(s, vcpt_ids[i])
		string_builder* original = vcpt_loose_bytes[i]
		vcpt_assert_bytes_equal(original.data, original.length, restored.data, restored.length)
		string_free(restored)
		i = i + 1

	# Re-packing the identical object population reproduces the exact
	# same pack file (name = sha256 of its own deterministic bytes),
	# then a second unpack restores the loose store for cleanup.
	wresult[pack_stats*]* again_r = pack_store_loose(s, 0)
	assert1(result_is_ok[pack_stats*](again_r))
	pack_stats* again = result_value[pack_stats*](again_r)
	result_free[pack_stats*](again_r)
	assert_strings_equal(vcpt_pack_path, again.pack_path)
	pack_stats_free(again)
	# No prune was requested: the loose copies must all still be there.
	for char* id in vcpt_ids:
		assert_equal(1, vcpt_loose_exists(s, id))
	wresult[pack_stats*]* redo_r = pack_unpack_all(s)
	assert1(result_is_ok[pack_stats*](redo_r))
	pack_stats_free(result_value[pack_stats*](redo_r))
	result_free[pack_stats*](redo_r)

	cas_close(s)


# Writes `length` bytes to `path` (plain create/truncate write -- test
# fixture only).
void vcpt_write_file(char* path, char* data, int length):
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 420 = rw-r--r--
	int fd = open(path, 577, 420)
	assert1(fd >= 0)
	assert_equal(0, cas_write_all(fd, data, length))
	close(fd)


void test_pack_corrupt_pack_handling():
	wcas* s = vcpt_open()
	pack_attach(s)

	char* packs_dir = pack_dir_path(s.root)
	mkdir(packs_dir, 493)
	char* garbage_path = path_join(packs_dir, c"garbage.wpack")
	vcpt_write_file(garbage_path, c"this is not a pack file", 23)
	# Well-formed header, but the entry's clen reaches past the body.
	char* liar = c"wpack 1\ncount 1\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0 999 10\n\nshort"
	char* liar_path = path_join(packs_dir, c"liar.wpack")
	vcpt_write_file(liar_path, liar, strlen(liar))

	# Read path: both corrupt packs are skipped, so lookups degrade to
	# clean misses (objects are all loose again after the round-trip
	# test, so known ids still resolve -- from disk, not the garbage).
	assert_equal(1, cas_has(s, vcpt_blob_id))
	char* missing = c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	assert_equal(0, cas_has(s, missing))

	# Unpack path: loud failure, nothing deleted.
	wresult[pack_stats*]* st_r = pack_unpack_all(s)
	assert1(result_is_error[pack_stats*](st_r))
	assert_equal(PACK_ERR_MALFORMED(), result_code[pack_stats*](st_r))
	result_free[pack_stats*](st_r)
	assert_equal(1, path_exists(garbage_path))

	assert_equal(0, vcs_unlink(garbage_path))
	assert_equal(0, vcs_unlink(liar_path))
	free(garbage_path)
	free(liar_path)
	free(packs_dir)
	cas_close(s)


# Runs last (tests execute in definition order): removes exactly what
# the run created, then asserts every directory rmdirs cleanly -- which
# also proves no temp files leaked from either the object or the pack
# write paths.
void test_pack_cleanup_store():
	wcas* s = vcpt_open()
	assert1(vcpt_ids != 0)
	for char* id in vcpt_ids:
		char* obj_path = cas_object_path(s, id)
		vcs_unlink(obj_path)
		free(obj_path)
	for char* id in vcpt_ids:
		char* fan_dir = cas_fanout_dir(s, id)
		rmdir(fan_dir)   # shared fanouts return -2/-39 on repeats; ignored
		free(fan_dir)
	char* packs_dir = pack_dir_path(s.root)
	assert_equal(0, rmdir(packs_dir))
	free(packs_dir)
	char* objects = path_join(vcpt_root(), c"objects")
	assert_equal(0, rmdir(objects))
	free(objects)
	cas_close(s)
	assert_equal(0, rmdir(vcpt_root()))
	for string_builder* b in vcpt_loose_bytes:
		string_free(b)
