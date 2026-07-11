# wbuild: x64 arch=arm64
/*
libs/extras/vcs/cas.w: the content-addressed object store (issue #252
wave 1, dual-use with issue #251 direction 3's build cache).

Covers: store layout creation, put/get/has round-trips (including
binary payloads with NUL bytes), id stability against known-answer
digests computed externally with `printf '<type> <len>\0<payload>' |
sha256sum`, dedup and rename-over-existing atomicity plus a real
concurrent double-put through fork(), missing- and malformed-id
behavior, the build-cache client flow (cas_put_raw under a precomputed
wexec-style input-hash key), and corrupted-object detection (framing
errors from cas_get, digest mismatch from cas_verify).

The store root is pid-scoped under bin/ so the 32- and 64-bit twins can
run in parallel; the final test removes everything it created and
asserts the directories rmdir cleanly, which doubles as a check that no
temp files leaked.
*/
import lib.testing
import libs.extras.vcs.cas
import libs.standard.crypto.sha2


# Known answers, computed outside W:
#   printf 'blob 11\0hello world' | sha256sum
#   printf 'blob 0\0' | sha256sum
char* VCST_HELLO_ID():
	return c"fee53a18d32820613c0527aa79be5cb30173c823a9b448fa4817767cc84c6f03"


char* VCST_EMPTY_ID():
	return c"473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"


# The pid-scoped store root, computed once (the fork()ed child must
# keep using the parent's root, so later calls reuse the cached value).
char* vcst_root_cache
char* vcst_root():
	if (vcst_root_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/vcs_cas_test_")
		string_append_int(p, getpid())
		string_append_char(p, '_')
		string_append_int(p, __word_size__ * 8)
		vcst_root_cache = p.data
		free(p)
	return vcst_root_cache


wcas* vcst_open():
	wresult[wcas*]* r = cas_open(vcst_root())
	assert1(result_is_ok[wcas*](r))
	wcas* s = result_value[wcas*](r)
	result_free[wcas*](r)
	return s


# Every id stored during the run, so the final test can remove exactly
# what was created and prove the store directory ends up empty.
list[char*] vcst_ids
void vcst_track(char* id):
	if (vcst_ids == 0):
		vcst_ids = new list[char*]
	vcst_ids.push(strclone(id))


# put + assert ok + track; returns the malloc'd id.
char* vcst_put(wcas* s, char* object_type, char* data, int length):
	wresult[char*]* r = cas_put(s, object_type, data, length)
	assert1(result_is_ok[char*](r))
	char* id = result_value[char*](r)
	result_free[char*](r)
	vcst_track(id)
	return id


# Lowercase hex of a whash digest (for deriving wexec-style cache keys).
char* vcst_hex(char* digest, int len):
	char* hex_digits = c"0123456789abcdef"
	char* out = malloc(len * 2 + 1)
	int i = 0
	while (i < len):
		int b = digest[i] & 255
		out[i * 2] = hex_digits[(b >> 4) & 15]
		out[i * 2 + 1] = hex_digits[b & 15]
		i = i + 1
	out[len * 2] = 0
	return out


void test_cas_open_creates_layout():
	wcas* s = vcst_open()
	char* objects = path_join(vcst_root(), c"objects")
	assert1(path_exists(vcst_root()))
	# objects/ is a directory, so open(read) succeeds on Linux.
	assert1(path_exists(objects))
	free(objects)
	cas_close(s)
	# Reopening an existing store succeeds (mkdir EEXIST is not an error).
	wcas* again = vcst_open()
	cas_close(again)
	# A root whose parent is missing reports the mkdir errno (-2 ENOENT).
	wresult[wcas*]* bad = cas_open(c"bin/vcs_cas_no_such_parent/store")
	assert1(result_is_error[wcas*](bad))
	assert_equal(-2, result_code[wcas*](bad))
	result_free[wcas*](bad)


void test_cas_put_get_has_roundtrip():
	wcas* s = vcst_open()
	char* id = vcst_put(s, c"blob", c"hello world", 11)
	assert_equal(1, cas_has(s, id))

	wresult[wcas_object*]* got = cas_get(s, id)
	assert1(result_is_ok[wcas_object*](got))
	wcas_object* o = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	assert_strings_equal(c"blob", o.object_type)
	assert_equal(11, o.length)
	assert_strings_equal(c"hello world", o.data)
	cas_object_free(o)

	# The object landed at the documented loose layout:
	# objects/<2 hex>/<62 hex>.
	string_builder* p = string_new()
	string_append(p, vcst_root())
	string_append(p, c"/objects/")
	string_append_char(p, id[0])
	string_append_char(p, id[1])
	string_append_char(p, '/')
	string_append(p, id + 2)
	assert1(path_exists(p.data))
	string_free(p)
	free(id)
	cas_close(s)


void test_cas_id_known_answers():
	# Fixed input -> expected id, so the header scheme
	# "<type> <len>\0" + payload is pinned against an external SHA-256.
	char* hello = cas_id_hex(c"blob", c"hello world", 11)
	assert_strings_equal(VCST_HELLO_ID(), hello)
	free(hello)
	char* empty = cas_id_hex(c"blob", c"", 0)
	assert_strings_equal(VCST_EMPTY_ID(), empty)
	free(empty)
	# printf 'out 4\0\x00\x01\xfe\xff' | sha256sum
	char* binary = cas_id_hex(c"out", c"\x00\x01\xfe\xff", 4)
	assert_strings_equal(c"71484e0e0f01977e88fc863530f62b863d679415404e2b6af850a134e04dcce4", binary)
	free(binary)
	# cas_put stores under exactly the id cas_id_hex predicts.
	wcas* s = vcst_open()
	char* stored = vcst_put(s, c"blob", c"hello world", 11)
	assert_strings_equal(VCST_HELLO_ID(), stored)
	free(stored)
	# Invalid tags produce no id at all.
	assert_equal(0, cast(int, cas_id_hex(c"bad tag", c"x", 1)))
	assert_equal(0, cast(int, cas_id_hex(c"", c"x", 1)))
	cas_close(s)


void test_cas_binary_payload_roundtrip():
	# Payloads are length-delimited, not NUL-terminated: all 256 byte
	# values, twice, must survive unchanged.
	wcas* s = vcst_open()
	int n = 512
	char* buf = malloc(n)
	int i = 0
	while (i < n):
		buf[i] = i & 255
		i = i + 1
	char* id = vcst_put(s, c"blob", buf, n)
	wresult[wcas_object*]* got = cas_get(s, id)
	assert1(result_is_ok[wcas_object*](got))
	wcas_object* o = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	assert_equal(n, o.length)
	i = 0
	while (i < n):
		assert_equal(buf[i] & 255, o.data[i] & 255)
		i = i + 1
	cas_object_free(o)
	free(buf)
	assert_equal(1, cas_verify(s, id))
	free(id)
	cas_close(s)


void test_cas_dedup_and_double_put():
	wcas* s = vcst_open()
	# Same content put twice: both succeed with the same id (the second
	# put takes the dedup path -- the object already exists).
	char* first = vcst_put(s, c"blob", c"dedup me", 8)
	char* second = vcst_put(s, c"blob", c"dedup me", 8)
	assert_strings_equal(first, second)
	assert_equal(1, cas_verify(s, first))
	free(second)

	# Simulated concurrent double-put: a real fork(), so parent and
	# child race the full write-temp + rename protocol on one id. Both
	# must succeed, and the object must be intact afterwards.
	char* racy = c"raced object payload"
	int child = fork()
	if (child == 0):
		wresult[char*]* cr = cas_put(s, c"blob", racy, 20)
		int code = 1
		if (result_is_ok[char*](cr)):
			code = 0
		exit(code)
	assert1(child > 0)
	wresult[char*]* pr = cas_put(s, c"blob", racy, 20)
	assert1(result_is_ok[char*](pr))
	char* raced_id = result_value[char*](pr)
	result_free[char*](pr)
	vcst_track(raced_id)
	# Pre-zero: the kernel writes a 32-bit status, W ints are word-sized
	# (the lib/process.w convention).
	int child_status = 0
	int waited = wait4(child, &child_status, 0, 0)
	assert_equal(child, waited)
	assert_equal(0, child_status)
	assert_equal(1, cas_has(s, raced_id))
	assert_equal(1, cas_verify(s, raced_id))
	free(raced_id)
	free(first)
	cas_close(s)


void test_cas_missing_and_malformed_ids():
	wcas* s = vcst_open()
	# Valid-form id that was never stored: the cache-miss case. -2 is
	# ENOENT, passed through unchanged per docs/error_results.txt.
	char* absent = c"00000000000000000000000000000000000000000000000000000000000000aa"
	assert_equal(0, cas_has(s, absent))
	wresult[wcas_object*]* miss = cas_get(s, absent)
	assert1(result_is_error[wcas_object*](miss))
	assert_equal(-2, result_code[wcas_object*](miss))
	result_free[wcas_object*](miss)
	assert_equal(-2, cas_verify(s, absent))

	# Malformed ids are rejected before touching the filesystem: -22
	# (EINVAL) from cas_get/cas_verify/cas_put_raw, 0 from cas_has.
	assert_equal(0, cas_has(s, c"short"))
	assert_equal(0, cas_has(s, c"FEE53A18D32820613C0527AA79BE5CB30173C823A9B448FA4817767CC84C6F03"))
	wresult[wcas_object*]* bad = cas_get(s, c"not-an-id")
	assert1(result_is_error[wcas_object*](bad))
	assert_equal(-22, result_code[wcas_object*](bad))
	result_free[wcas_object*](bad)
	assert_equal(-22, cas_verify(s, c"not-an-id"))
	wresult[char*]* raw = cas_put_raw(s, c"not-an-id", c"out", c"x", 1)
	assert1(result_is_error[char*](raw))
	assert_equal(-22, result_code[char*](raw))
	result_free[char*](raw)

	# Invalid put arguments: bad tag, negative length.
	wresult[char*]* bad_tag = cas_put(s, c"has space", c"x", 1)
	assert1(result_is_error[char*](bad_tag))
	assert_equal(-22, result_code[char*](bad_tag))
	result_free[char*](bad_tag)
	wresult[char*]* neg = cas_put(s, c"blob", c"x", -1)
	assert1(result_is_error[char*](neg))
	assert_equal(-22, result_code[char*](neg))
	result_free[char*](neg)
	cas_close(s)


# The dual-use case (issue #251 direction 3): a build cache stores an
# output artifact under a key derived from the *inputs* (a wexec-style
# content hash of sources + command), not from the artifact bytes. The
# store serves that client through cas_put_raw with zero changes to the
# content-addressed core.
void test_cas_build_cache_client():
	wcas* s = vcst_open()

	# A fake build-output tarball: 1 KiB of structured binary data.
	int n = 1024
	char* tarball = malloc(n)
	int i = 0
	while (i < n):
		tarball[i] = (i * 7 + (i >> 6)) & 255
		i = i + 1

	# The cache key, derived exactly the way tools/wexec.w would: a
	# SHA-256 over the target's command line and input hashes.
	char* manifest = c"target hello\ncmd bin/wv2 tests/hello.w -o bin/hello\ninput tests/hello.w 9d1e4d\n"
	char* key_digest = malloc(32)
	whash_oneshot(WHASH_SHA256(), manifest, strlen(manifest), key_digest)
	char* key = vcst_hex(key_digest, 32)
	free(key_digest)
	# The key is a precomputed id, not the hash of the tarball.
	char* content_id = cas_id_hex(c"out", tarball, n)
	assert1(strcmp(key, content_id) != 0)

	# Populate (CI side): store the artifact under the input key.
	wresult[char*]* put = cas_put_raw(s, key, c"out", tarball, n)
	assert1(result_is_ok[char*](put))
	char* returned = result_value[char*](put)
	result_free[char*](put)
	assert_strings_equal(key, returned)
	vcst_track(key)
	free(returned)

	# Probe + fetch (fresh-clone side): cas_has answers the cache probe,
	# cas_get returns the artifact bytes intact.
	assert_equal(1, cas_has(s, key))
	wresult[wcas_object*]* hit = cas_get(s, key)
	assert1(result_is_ok[wcas_object*](hit))
	wcas_object* o = result_value[wcas_object*](hit)
	result_free[wcas_object*](hit)
	assert_strings_equal(c"out", o.object_type)
	assert_equal(n, o.length)
	i = 0
	while (i < n):
		assert_equal(tarball[i] & 255, o.data[i] & 255)
		i = i + 1
	cas_object_free(o)

	# A rebuilt artifact under the same key replaces the entry
	# atomically (keyed ids say nothing about the stored bytes, so raw
	# put must never keep stale data). This is also the
	# rename-over-existing path the concurrent double-put relies on.
	wresult[char*]* again = cas_put_raw(s, key, c"out", c"rebuilt", 7)
	assert1(result_is_ok[char*](again))
	free(result_value[char*](again))
	result_free[char*](again)
	wresult[wcas_object*]* fresh = cas_get(s, key)
	assert1(result_is_ok[wcas_object*](fresh))
	wcas_object* o2 = result_value[wcas_object*](fresh)
	result_free[wcas_object*](fresh)
	assert_strings_equal(c"rebuilt", o2.data)
	cas_object_free(o2)

	# The same bytes can ALSO live as a normal content-addressed object
	# (the VCS client), side by side in one store.
	char* stored_content_id = vcst_put(s, c"out", tarball, n)
	assert_strings_equal(content_id, stored_content_id)
	assert_equal(1, cas_verify(s, stored_content_id))
	free(stored_content_id)
	free(content_id)
	free(key)
	free(tarball)
	cas_close(s)


void test_cas_corrupt_detection():
	wcas* s = vcst_open()

	# Digest mismatch: flip one stored payload byte in place. The
	# framing stays valid (cas_get still succeeds) but cas_verify
	# reports the corruption.
	char* id = vcst_put(s, c"blob", c"soon to be corrupted", 20)
	assert_equal(1, cas_verify(s, id))
	string_builder* p = string_new()
	string_append(p, vcst_root())
	string_append(p, c"/objects/")
	string_append_char(p, id[0])
	string_append_char(p, id[1])
	string_append_char(p, '/')
	string_append(p, id + 2)
	int fd = open(p.data, 1, 0)
	assert1(fd >= 0)
	seek(fd, 0 - 1, 2)          # last payload byte
	write(fd, c"X", 1)
	close(fd)
	assert_equal(0, cas_verify(s, id))
	wresult[wcas_object*]* still = cas_get(s, id)
	assert1(result_is_ok[wcas_object*](still))
	cas_object_free(result_value[wcas_object*](still))
	result_free[wcas_object*](still)
	free(id)

	# Truncation: the declared length no longer matches the payload, so
	# cas_get reports CAS_ERR_CORRUPT.
	char* short_id = vcst_put(s, c"blob", c"about to be truncated", 21)
	string_builder* p2 = string_new()
	string_append(p2, vcst_root())
	string_append(p2, c"/objects/")
	string_append_char(p2, short_id[0])
	string_append_char(p2, short_id[1])
	string_append_char(p2, '/')
	string_append(p2, short_id + 2)
	wstream* out = stream_open_write(p2.data)
	assert1(cast(int, out) != 0)
	stream_write(out, c"blob 21", 7)
	stream_write_byte(out, 0)
	stream_write(out, c"about", 5)   # 5 of the declared 21 bytes
	stream_close(out)
	wresult[wcas_object*]* trunc = cas_get(s, short_id)
	assert1(result_is_error[wcas_object*](trunc))
	assert_equal(CAS_ERR_CORRUPT(), result_code[wcas_object*](trunc))
	result_free[wcas_object*](trunc)
	assert_equal(0, cas_verify(s, short_id))
	free(short_id)

	# Garbage framing: a file with no "<type> <len>\0" header at all.
	char* junk_id = vcst_put(s, c"blob", c"placeholder", 11)
	string_builder* p3 = string_new()
	string_append(p3, vcst_root())
	string_append(p3, c"/objects/")
	string_append_char(p3, junk_id[0])
	string_append_char(p3, junk_id[1])
	string_append_char(p3, '/')
	string_append(p3, junk_id + 2)
	wstream* junk = stream_open_write(p3.data)
	assert1(cast(int, junk) != 0)
	stream_write(junk, c"no header here", 14)
	stream_close(junk)
	wresult[wcas_object*]* bad = cas_get(s, junk_id)
	assert1(result_is_error[wcas_object*](bad))
	assert_equal(CAS_ERR_CORRUPT(), result_code[wcas_object*](bad))
	result_free[wcas_object*](bad)
	free(junk_id)

	string_free(p)
	string_free(p2)
	string_free(p3)
	cas_close(s)


# Runs last (tests execute in definition order): removes exactly the
# objects the run created, then asserts the store directories rmdir
# cleanly -- which also proves no temp files leaked from the put paths.
void test_cas_cleanup_store():
	wcas* s = vcst_open()
	assert1(vcst_ids != 0)
	for char* id in vcst_ids:
		string_builder* p = string_new()
		string_append(p, vcst_root())
		string_append(p, c"/objects/")
		string_append_char(p, id[0])
		string_append_char(p, id[1])
		string_append_char(p, '/')
		string_append(p, id + 2)
		vcs_unlink(p.data)   # duplicates return -2; ignored
		string_free(p)
	for char* fan_id in vcst_ids:
		string_builder* d = string_new()
		string_append(d, vcst_root())
		string_append(d, c"/objects/")
		string_append_char(d, fan_id[0])
		string_append_char(d, fan_id[1])
		rmdir(d.data)    # duplicates return -2; ignored
		string_free(d)
	char* objects = path_join(vcst_root(), c"objects")
	assert_equal(0, rmdir(objects))
	free(objects)
	assert_equal(0, rmdir(vcst_root()))
	cas_close(s)
