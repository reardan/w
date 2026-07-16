/*
Content-addressed object store (VCS wave 1, issue #252; design:
docs/projects/version_control.md).

One library, two clients (issue #251 direction 3): version-control
objects (blob/tree/commit) and the build cache both live in the same
store. An object is stored under the SHA-256 of a git-style typed
header plus payload:

	id = sha256("<type> <len>\0" + payload)    # 64 lowercase hex chars

so identity, deduplication, and integrity checking all fall out of the
addressing scheme. Types are short ASCII tags the caller defines
("blob", "tree", "commit", "out", ...); the store is type-agnostic.

Layout is git's loose-object scheme, uncompressed (compression is a
wave-3 encoding slot, not a semantic requirement):

	<root>/objects/<first 2 hex>/<remaining 62 hex>

Writes go to a unique temp file in <root>/objects/ and are moved into
place with rename(2), so a reader never observes a partial object and
concurrent writers of the same id both succeed (the last rename wins;
for content-addressed ids the bytes are identical by construction).

Two put surfaces:
  - cas_put(store, type, bytes, len) -> id: content-addressed. The id
    is computed from the bytes, and an already-present id skips the
    write (dedup is free).
  - cas_put_raw(store, id, type, bytes, len): stores under a
    caller-supplied 64-hex id. This is the build-cache client's needs
    designed in (issue #251 direction 3): a cache keys its entries by a
    hash of the *inputs* (wexec-style content keys), which is not the
    hash of the stored bytes, so a pure content-addressed put cannot
    serve it. Raw puts always replace atomically -- a keyed id carries
    no guarantee that existing bytes match the new ones, so keeping
    stale bytes silently would be wrong.

Reads (cas_get) validate the framing: the header must parse and the
declared payload length must match the file size exactly, so truncated
or garbage objects are reported as corrupt (CAS_ERR_CORRUPT). The
parsing itself lives in cas_parse_framed(bytes, length), factored out of
cas_get so a caller with bytes that are not (yet, or ever) a file on
disk -- notably libs/extras/vcs/sync.w's HTTP object-upload handler --
can validate an untrusted buffer against the same grammar before ever
writing it to the store: recompute cas_id_hex(type, payload, length)
from the parsed result and compare against the claimed id, and only
cas_put_raw it on a match. Full digest verification of an object already
on disk is the separate cas_verify(store, id): it cannot be
unconditional in cas_get because raw-put ids are names, not content
hashes, and would always "fail". Callers that only ever use cas_put can
treat cas_verify(id) == 1 as the fsck primitive.

Error handling follows docs/error_results.txt: operations a caller can
recover from (missing object = cache miss, unwritable store) return
wresult[T]*, carrying negative Linux errno codes unchanged, -22
(EINVAL) for malformed arguments, and CAS_ERR_CORRUPT (-74, EBADMSG)
for objects whose stored bytes do not match their framing.

Nothing here enters the seed import graph; the per-target rename
wrapper lives in libs/extras/vcs/__arch__/ (x86, x64, arm64,
arm64_darwin -- win64 and wasm are unsupported for now).
*/
import lib.lib
import lib.path
import lib.result
import lib.stream
import structures.string
import libs.standard.crypto.sha2
import libs.extras.vcs.__arch__.fsops


# Error code for an object whose stored bytes do not match the
# "<type> <len>\0" framing (or, from cas_verify, whose digest does not
# match its id): -74, Linux EBADMSG ("not a data message").
int CAS_ERR_CORRUPT():
	return -74


# An open store handle. Create with cas_open, release with cas_close.
struct wcas:
	char* root      # store root directory (owned clone)
	char* objects   # "<root>/objects" (owned)


# One object read back from the store: the caller-defined type tag and
# the payload bytes. data is NUL-terminated for convenience, but length
# is authoritative -- payloads may contain NUL bytes. Release with
# cas_object_free.
struct wcas_object:
	char* object_type
	char* data
	int length


# Process-wide sequence for unique temp-file names (combined with the
# pid, so concurrent processes and concurrent handles never collide on
# a temp path; O_EXCL catches any residue from a crashed run).
int cas_temp_sequence


/* Ids and framing */


# Type tags are 1..64 printable non-space ASCII characters: one byte of
# ' ' or NUL would break the "<type> <len>\0" framing.
int cas_valid_tag_char(int c):
	return (c >= 33) && (c <= 126)


int cas_valid_tag(char* object_type):
	if (object_type == 0):
		return 0
	int i = 0
	while (object_type[i] != 0):
		if (cas_valid_tag_char(object_type[i] & 255) == 0):
			return 0
		i = i + 1
	return (i >= 1) && (i <= 64)


# Ids are exactly 64 lowercase hex characters (the canonical display
# and path form of a 32-byte SHA-256; docs/projects/version_control.md).
int cas_valid_id(char* id):
	if (id == 0):
		return 0
	int i = 0
	while (id[i] != 0):
		int c = id[i] & 255
		int is_digit = (c >= '0') && (c <= '9')
		int is_lower_hex = (c >= 'a') && (c <= 'f')
		if ((is_digit || is_lower_hex) == 0):
			return 0
		i = i + 1
	return i == 64


# 32 raw digest bytes -> malloc'd 64-char lowercase hex string.
char* cas_hex_encode(char* digest):
	char* digits = c"0123456789abcdef"
	char* out = malloc(65)
	int i = 0
	while (i < 32):
		int b = digest[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[64] = 0
	return out


# The git-style object header "<type> <len>\0" as a string_builder
# (h.length includes the trailing NUL byte).
string_builder* cas_make_header(char* object_type, int length):
	string_builder* h = string_new()
	string_append(h, object_type)
	string_append_char(h, ' ')
	string_append_int(h, length)
	string_append_char(h, 0)
	return h


# sha256(header + payload) as a malloc'd hex id. Streaming through
# whash, so the payload is never copied.
char* cas_id_from_header(string_builder* header, char* data, int length):
	whash* h = whash_new(WHASH_SHA256())
	whash_update(h, header.data, header.length)
	whash_update(h, data, length)
	char* digest = malloc(32)
	whash_final(h, digest)
	whash_free(h)
	char* id = cas_hex_encode(digest)
	free(digest)
	return id


# The id cas_put would store these bytes under, without touching any
# store: sha256("<type> <len>\0" + payload) in hex. Pure -- exposed so
# clients can key lookups (or known-answer tests) without a write.
# Returns 0 when the type tag is invalid or length is negative.
char* cas_id_hex(char* object_type, char* data, int length):
	if ((cas_valid_tag(object_type) == 0) || (length < 0)):
		return 0
	if ((data == 0) && (length != 0)):
		return 0
	string_builder* header = cas_make_header(object_type, length)
	char* id = cas_id_from_header(header, data, length)
	string_free(header)
	return id


/* Store paths */


# "<objects>/<first 2 hex>" (owned by the caller).
char* cas_fanout_dir(wcas* s, char* id):
	string_builder* p = string_new()
	string_append(p, s.objects)
	string_append_char(p, '/')
	string_append_char(p, id[0])
	string_append_char(p, id[1])
	char* path = p.data
	free(p)
	return path


# "<objects>/<first 2 hex>/<remaining 62 hex>" (owned by the caller).
char* cas_object_path(wcas* s, char* id):
	char* dir = cas_fanout_dir(s, id)
	char* path = path_join(dir, id + 2)
	free(dir)
	return path


/* Open / close */


# Opens (creating if needed) the store rooted at `root`. Only the root
# and its objects/ directory are created; root's parent must already
# exist. Errors carry the mkdir errno.
wresult[wcas*]* cas_open(char* root):
	int err = mkdir(root, 493)
	if ((err < 0) && (err != -17)):
		return result_new_error[wcas*](err)
	char* objects = path_join(root, c"objects")
	err = mkdir(objects, 493)
	if ((err < 0) && (err != -17)):
		free(objects)
		return result_new_error[wcas*](err)
	wcas* s = new wcas
	s.root = strclone(root)
	s.objects = objects
	return result_new_ok[wcas*](s)


void cas_close(wcas* s):
	free(s.root)
	free(s.objects)
	free(s)


void cas_object_free(wcas_object* o):
	free(o.object_type)
	free(o.data)
	free(o)


/* Writing */


int cas_write_all(int fd, char* data, int n):
	int off = 0
	while (off < n):
		int wrote = write(fd, data + off, n - off)
		if (wrote < 0):
			return wrote
		if (wrote == 0):
			return -5   # EIO: a regular file should never short-write
		off = off + wrote
	return 0


# Writes header+payload to a fresh temp file in objects/ and renames it
# onto `path`. The rename is what makes the store safe: readers never
# see a partial object, and two writers racing on one id both succeed
# because each renames its own complete temp file (the last one wins).
# Returns 0 or a negative errno; the temp file is always cleaned up on
# failure.
int cas_store_bytes(wcas* s, char* id, string_builder* header, char* data, int length):
	char* dir = cas_fanout_dir(s, id)
	int err = mkdir(dir, 493)
	free(dir)
	if ((err < 0) && (err != -17)):
		return err

	# A unique temp path: pid + process-wide sequence, O_EXCL as the
	# backstop (retry on the unlikely leftover from a crashed run).
	int fd = -17
	char* temp = 0
	int attempts = 0
	while ((fd == -17) && (attempts < 100)):
		string_builder* t = string_new()
		string_append(t, s.objects)
		string_append(t, c"/tmp_")
		string_append_int(t, getpid())
		string_append_char(t, '_')
		string_append_int(t, cas_temp_sequence)
		cas_temp_sequence = cas_temp_sequence + 1
		temp = t.data
		free(t)
		# 193 = O_WRONLY | O_CREAT | O_EXCL, 420 = rw-r--r--
		fd = open(temp, 193, 420)
		if (fd == -17):
			free(temp)
			temp = 0
		attempts = attempts + 1
	if (fd < 0):
		return fd

	err = cas_write_all(fd, header.data, header.length)
	if (err == 0):
		err = cas_write_all(fd, data, length)
	int closed = close(fd)
	if ((err == 0) && (closed < 0)):
		err = closed
	if (err == 0):
		char* path = cas_object_path(s, id)
		err = vcs_rename(temp, path)
		free(path)
	if (err < 0):
		vcs_unlink(temp)
	free(temp)
	return err


# Stores `length` bytes under their content hash and returns the
# malloc'd 64-hex id (also on the dedup path: an id that already exists
# is complete and identical by construction, so the write is skipped).
# Errors: -22 for an invalid type tag / negative length, otherwise the
# failing syscall's errno.
wresult[char*]* cas_put(wcas* s, char* object_type, char* data, int length):
	if ((cas_valid_tag(object_type) == 0) || (length < 0)):
		return result_new_error[char*](-22)
	if ((data == 0) && (length != 0)):
		return result_new_error[char*](-22)
	string_builder* header = cas_make_header(object_type, length)
	char* id = cas_id_from_header(header, data, length)
	char* path = cas_object_path(s, id)
	int present = path_exists(path)
	free(path)
	int err = 0
	if (present == 0):
		err = cas_store_bytes(s, id, header, data, length)
	string_free(header)
	if (err < 0):
		free(id)
		return result_new_error[char*](err)
	return result_new_ok[char*](id)


# Stores bytes under a caller-supplied id (a precomputed key such as a
# wexec-style input hash -- the build-cache client, issue #251
# direction 3). Framing on disk is identical to cas_put's, so cas_get /
# cas_has serve both kinds of object unchanged. Unlike cas_put this
# always writes: an existing entry is atomically replaced, because a
# keyed id says nothing about the bytes already stored under it.
# Returns a malloc'd clone of `id` for symmetry with cas_put.
wresult[char*]* cas_put_raw(wcas* s, char* id, char* object_type, char* data, int length):
	if ((cas_valid_id(id) == 0) || (cas_valid_tag(object_type) == 0) || (length < 0)):
		return result_new_error[char*](-22)
	if ((data == 0) && (length != 0)):
		return result_new_error[char*](-22)
	string_builder* header = cas_make_header(object_type, length)
	int err = cas_store_bytes(s, id, header, data, length)
	string_free(header)
	if (err < 0):
		return result_new_error[char*](err)
	return result_new_ok[char*](strclone(id))


/* Reading */


# 1 when an object is stored under id, else 0 (including malformed ids).
int cas_has(wcas* s, char* id):
	if (cas_valid_id(id) == 0):
		return 0
	char* path = cas_object_path(s, id)
	int present = path_exists(path)
	free(path)
	return present


# Reads the whole object file at `path` into a string_builder, or 0
# with the open errno in cas_read_errno.
int cas_read_errno
string_builder* cas_read_file(char* path):
	cas_read_errno = 0
	int fd = open(path, 0, 0)
	if (fd < 0):
		cas_read_errno = fd
		return 0
	wstream* in = stream_reader(fd)
	string_builder* contents = string_new()
	stream_read_all(in, contents)
	stream_close(in)
	return contents


# Parses the "<type> <len>\0" + payload framing (see the header comment)
# out of an in-memory buffer -- the same grammar cas_get validates when
# reading a stored object from disk, factored out so a caller whose
# bytes are not (yet, or ever) a file on disk -- an HTTP POST body, for
# libs/extras/vcs/sync.w's object-upload endpoint -- can run the exact
# same validation. Returns CAS_ERR_CORRUPT for anything that does not
# match the grammar exactly (truncation, garbage, a declared length that
# does not match `total` bytes remaining).
wresult[wcas_object*]* cas_parse_framed(char* bytes, int total):
	# "<type> <len>\0": tag, single space, decimal length, NUL.
	int i = 0
	while ((i < total) && cas_valid_tag_char(bytes[i] & 255)):
		i = i + 1
	int tag_len = i
	int valid = (tag_len >= 1) && (tag_len <= 64)
	valid = valid && (i < total) && ((bytes[i] & 255) == ' ')
	i = i + 1
	int declared = 0
	int digits = 0
	while (valid && (i < total)):
		int c = bytes[i] & 255
		if ((c < '0') || (c > '9')):
			break
		# declared can never legitimately exceed the buffer size, so this
		# also guards the multiplication against overflow.
		if (declared > total):
			valid = 0
			break
		declared = declared * 10 + (c - '0')
		digits = digits + 1
		i = i + 1
	valid = valid && (digits >= 1)
	valid = valid && (i < total) && (bytes[i] == 0)
	i = i + 1
	valid = valid && (total - i == declared)
	if (valid == 0):
		return result_new_error[wcas_object*](CAS_ERR_CORRUPT())

	wcas_object* o = new wcas_object
	o.object_type = malloc(tag_len + 1)
	int j = 0
	while (j < tag_len):
		o.object_type[j] = bytes[j]
		j = j + 1
	o.object_type[tag_len] = 0
	o.data = malloc(declared + 1)
	j = 0
	while (j < declared):
		o.data[j] = bytes[i + j]
		j = j + 1
	o.data[declared] = 0
	o.length = declared
	return result_new_ok[wcas_object*](o)


# Loads an object. Errors: -22 for a malformed id, the open errno for a
# missing object (-2, the cache-miss case a caller checks for), and
# CAS_ERR_CORRUPT when the stored bytes do not frame as
# "<type> <len>\0" + exactly <len> payload bytes (truncation, garbage,
# or an interrupted foreign write -- impossible via this module's
# rename protocol, but the store is just files on disk).
wresult[wcas_object*]* cas_get(wcas* s, char* id):
	if (cas_valid_id(id) == 0):
		return result_new_error[wcas_object*](-22)
	char* path = cas_object_path(s, id)
	string_builder* contents = cas_read_file(path)
	free(path)
	if (contents == 0):
		return result_new_error[wcas_object*](cas_read_errno)
	wresult[wcas_object*]* parsed = cas_parse_framed(contents.data, contents.length)
	string_free(contents)
	return parsed


# Full integrity check for a content-addressed object: rehashes the
# stored bytes (header + payload, exactly as hashed at put time) and
# compares the digest to the id. Returns 1 on match, 0 on mismatch
# (corruption -- or a cas_put_raw entry, whose id is a name rather than
# a content hash), -22 for a malformed id, or the open errno.
int cas_verify(wcas* s, char* id):
	if (cas_valid_id(id) == 0):
		return -22
	char* path = cas_object_path(s, id)
	string_builder* contents = cas_read_file(path)
	free(path)
	if (contents == 0):
		return cas_read_errno
	char* digest = malloc(32)
	whash_oneshot(WHASH_SHA256(), contents.data, contents.length, digest)
	char* actual = cas_hex_encode(digest)
	free(digest)
	int match = strcmp(actual, id) == 0
	free(actual)
	string_free(contents)
	return match
