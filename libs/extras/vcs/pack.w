/*
Pack files: many CAS objects in one deflate-compressed, indexed file
(VCS wave-3 remainder, issue #252 "compress-based object packing";
design: docs/projects/version_control.md "Wave 3 -- the performance
structures"). Companion to libs/extras/vcs/cas.w -- read that file's
header comment first, especially the "<type> <len>\0" logical framing
and the "Layered read-through" section this module is the registrar
for.

Why: a loose-object store pays one file (plus a fanout directory) per
object. Packing rewrites the whole loose population into ONE file with
an index, so old history stops costing inodes and open(2)s, exactly
git's loose-vs-pack split -- but in a deliberately minimal W-native
format. Git interop is an explicit NON-goal (version_control.md's
design decisions: it would force zlib+SHA-1+git's exact varint pack
encoding); nothing in this format is or pretends to be a git packfile.

File format (one "<sha256 of the file's own bytes>.wpack" file under
"<root>/packs/", written atomically via the same write-to-temp +
rename protocol cas.w uses for objects/):

	wpack 1\n
	count <N>\n
	<id> <offset> <clen> <ulen>\n      (exactly N lines, ids ascending)
	\n
	<body: the N entries' zlib streams, back to back>

Header lines are ASCII text in the same package.wmeta-flavored
"parseable without a general parser" spirit as commit.w/tree.w/delta.w:
one forward pass, fixed field order, a blank line ends the header. Each
index line names one object: its 64-hex id, the byte offset of its
entry inside the body (relative to the first body byte, so the header's
own size never shifts offsets), the entry's compressed length, and the
length of the LOGICAL bytes it inflates back to. An entry's bytes are
libs/extras/compress/zlib.w's zlib_compress, at DEFLATE_LEVEL_BEST, of
the object's logical "<type> <len>\0" + payload sequence -- the same
bytes a loose object's on-disk encoding compresses (cas.w's "On-disk
encoding"), so packing and unpacking are pure re-encodings that can
never change an object's identity, and unpacking an object written by
this cas.w reproduces the loose file byte-for-byte (same deterministic
zlib encoder, same level).

Ids are treated as NAMES, not re-verified content hashes, on both the
pack and unpack paths: a store legitimately contains objects whose id
is not the hash of their own logical bytes -- cas_put_raw build-cache
entries keyed by input hashes (issue #251 direction 3), and delta.w
chains, whose id is the hash of the RECONSTRUCTED object rather than
the stored "delta" payload. Integrity inside a pack rests on the zlib
streams' own adler32 checksums plus the recorded ulen; full digest
verification stays cas_verify's job, exactly as for loose raw-put
objects. Delta-encoded objects pack as-is (their "delta"-typed logical
bytes), so a packed chain still resolves through delta.w's
cas_get_resolved unchanged; pack-internal re-deltification is left out
of this v1 on purpose (version_control.md notes plain per-object
compression as the acceptable v1).

Read path: pack_attach(s) registers this module on an open cas handle
through cas.w's fallback seam (struct wcas's fallback_* fields), so
cas_get/cas_has/cas_verify transparently consult every
"<root>/packs/*.wpack" file whenever a loose object is missing --
tree.w, commit.w, index.w, delta.w and sync.w all read through those
three calls, so status/log/merge/pull/push work against a fully packed
store with no changes of their own. Pack files are scanned and loaded
lazily, on the first fallback consultation (a store whose reads all hit
loose files never pays for so much as a directory listing), and each
loaded pack keeps its whole file in memory (fine at this repo's scale;
per-entry file reads behind the same API are the natural follow-up if
pack sizes ever demand it). A pack file that fails to load or an entry
that fails to inflate reads as "object missing" through the fallback
(the seam has no error channel); wvc unpack, which CAN report, treats
the same conditions as hard errors instead.

Write path: pack_store_loose(s, prune) enumerates every loose object
(the objects/<2-hex>/<62-hex> layout walked with the same getdents
pattern as tree_snapshot), validates each one end-to-end (undo the
on-disk encoding, parse the logical framing) before it is admitted,
writes one new pack file named by the sha256 of its own bytes, and only
after the rename has made that pack durable optionally prunes the loose
files it subsumed (unlinking each object and rmdir-ing emptied fanout
directories; failures there are ignored -- a leftover loose file is
merely redundant, never wrong). pack_unpack_all(s) is the inverse:
every entry of every pack is inflated, framing-validated, and restored
with cas_put_raw (the atomic loose-write path), and each pack file is
unlinked only after every one of its objects is safely loose again.

Registrar assumption: cas.w's fallback seam holds one layer, and this
module is the only registrar in the tree today. pack_store_loose and
pack_unpack_all reset an attached layer's lazy-scan state (so a
long-lived handle sees new/removed packs on its next read) by treating
s.fallback_state as this module's own wpack_set* -- a handle carrying
some OTHER future layer must not be passed to them without teaching
this module about it first.

Error handling follows docs/error_results.txt: wresult[T]* carrying
negative errnos unchanged from the failing syscall, -22 (EINVAL) for
malformed arguments, and PACK_ERR_MALFORMED (-74, EBADMSG -- the same
code as cas.w's CAS_ERR_CORRUPT and delta.w's DELTA_ERR_MALFORMED) for
a pack whose bytes do not match the format above or whose entries do
not inflate/frame back.

Nothing here enters the seed import graph (a libs/extras/vcs/ leaf,
same as every sibling module).
*/
import lib.container
import lib.lib
import lib.path
import lib.result
import structures.string
import libs.standard.crypto.sha2
import libs.extras.compress.deflate
import libs.extras.compress.zlib
import libs.extras.vcs.cas
import libs.extras.vcs.__arch__.fsops


/* Constants */


# -74: Linux EBADMSG, shared with CAS_ERR_CORRUPT / DELTA_ERR_MALFORMED
# for the same "stored bytes do not match the format" class of problem.
int PACK_ERR_MALFORMED():
	return -74


char* PACK_DIR_NAME():
	return c"packs"


char* PACK_SUFFIX():
	return c".wpack"


char* PACK_MAGIC_LINE():
	return c"wpack 1"


# "<root>/packs" (owned by the caller).
char* pack_dir_path(char* root):
	return path_join(root, PACK_DIR_NAME())


/* Structures */


# One indexed object inside a pack: where its zlib stream lives in the
# body, how long that stream is, and how many logical bytes it inflates
# back to.
struct wpack_entry:
	int offset
	int clen
	int ulen


# One loaded pack file, kept fully in memory (see the header comment's
# read-path section). entries maps 64-hex id -> wpack_entry* (keys are
# cloned by the map, values owned here).
struct wpack_file:
	char* path        # owned
	char* data        # owned, the whole file's bytes
	int length
	int body_start    # first body byte; entry offsets are relative to it
	map[char*, wpack_entry*] entries


# The read-side state pack_attach registers on a cas handle: the packs
# directory plus every successfully loaded pack in it. `scanned` stays 0
# until the first fallback consultation (lazy -- see header comment).
struct wpack_set:
	char* dir         # owned "<root>/packs"
	int scanned
	list[wpack_file*] packs


# pack_store_loose / pack_unpack_all summary: how many objects moved,
# how many pack files were created or removed, and (store direction
# only) the created pack's path.
struct pack_stats:
	int objects
	int packs
	char* pack_path   # owned; 0 when no pack was created


void pack_file_free(wpack_file* p):
	for char* id in p.entries:
		free(p.entries[id])
	map_free[char*, wpack_entry*](p.entries)
	free(p.path)
	free(p.data)
	free(p)


void pack_set_free(wpack_set* ps):
	for wpack_file* p in ps.packs:
		pack_file_free(p)
	list_free[wpack_file*](ps.packs)
	free(ps.dir)
	free(ps)


void pack_stats_free(pack_stats* st):
	if (st.pack_path != 0):
		free(st.pack_path)
	free(st)


/* Header parsing */


# True when data[offset .. offset+strlen(prefix)) equals prefix, without
# reading past `length` (mirrors delta.w's delta_starts_with).
int pack_starts_with(char* data, int length, int offset, char* prefix):
	int n = strlen(prefix)
	if ((offset + n) > length):
		return 0
	int i = 0
	while (i < n):
		if (data[offset + i] != prefix[i]):
			return 0
		i = i + 1
	return 1


# Parses a non-negative decimal at data[*pos], advancing *pos past the
# digits. Returns -1 for "no digits" or a value that would overflow the
# word-sized int (the running value is capped at 100000000 BEFORE each
# multiply, so the arithmetic itself can never wrap even on 32-bit --
# fields up to ~1e9 parse, far beyond any pack this v1 writes).
int pack_parse_uint(char* data, int length, int* pos):
	int i = *pos
	int value = 0
	int digits = 0
	while (i < length):
		int c = data[i] & 255
		if ((c < '0') || (c > '9')):
			break
		if (value > 100000000):
			return -1
		value = value * 10 + (c - '0')
		digits = digits + 1
		i = i + 1
	if (digits == 0):
		return -1
	*pos = i
	return value


# Expects exactly `ch` at data[*pos] and advances past it.
int pack_expect_char(char* data, int length, int* pos, int ch):
	int i = *pos
	if ((i >= length) || ((data[i] & 255) != ch)):
		return 0
	*pos = i + 1
	return 1


# Parses a whole pack file's bytes into a wpack_file, validating the
# format end to end: magic/version line, count, every index line (valid
# id, three in-range numeric fields, ids unique), the blank header
# terminator, and every entry's [offset, offset+clen) staying inside
# the body. On success the returned wpack_file OWNS `data` (and `path`
# is cloned); on error the caller keeps ownership of `data`.
wresult[wpack_file*]* pack_parse(char* path, char* data, int length):
	int pos = 0
	int valid = pack_starts_with(data, length, pos, PACK_MAGIC_LINE())
	if (valid):
		pos = pos + strlen(PACK_MAGIC_LINE())
		valid = pack_expect_char(data, length, &pos, 10)
	if (valid):
		valid = pack_starts_with(data, length, pos, c"count ")
	int count = 0
	if (valid):
		pos = pos + strlen(c"count ")
		count = pack_parse_uint(data, length, &pos)
		valid = (count >= 0) && pack_expect_char(data, length, &pos, 10)
	if (valid == 0):
		return result_new_error[wpack_file*](PACK_ERR_MALFORMED())

	map[char*, wpack_entry*] entries = new map[char*, wpack_entry*]
	int i = 0
	while (valid && (i < count)):
		valid = ((pos + 64) <= length)
		char* id = 0
		if (valid):
			id = path_clone_range(data + pos, 64)
			pos = pos + 64
			valid = cas_valid_id(id) && ((id in entries) == 0)
		int offset = -1
		int clen = -1
		int ulen = -1
		valid = valid && pack_expect_char(data, length, &pos, ' ')
		if (valid):
			offset = pack_parse_uint(data, length, &pos)
			valid = (offset >= 0) && pack_expect_char(data, length, &pos, ' ')
		if (valid):
			clen = pack_parse_uint(data, length, &pos)
			valid = (clen >= 0) && pack_expect_char(data, length, &pos, ' ')
		if (valid):
			ulen = pack_parse_uint(data, length, &pos)
			valid = (ulen >= 0) && pack_expect_char(data, length, &pos, 10)
		if (valid):
			wpack_entry* e = new wpack_entry
			e.offset = offset
			e.clen = clen
			e.ulen = ulen
			entries[id] = e
		if (id != 0):
			free(id)
		i = i + 1
	valid = valid && pack_expect_char(data, length, &pos, 10)

	int body_len = length - pos
	if (valid):
		for char* id in entries:
			wpack_entry* e = entries[id]
			if ((e.offset > body_len) || (e.clen > (body_len - e.offset))):
				valid = 0
	if (valid == 0):
		for char* id in entries:
			free(entries[id])
		map_free[char*, wpack_entry*](entries)
		return result_new_error[wpack_file*](PACK_ERR_MALFORMED())

	wpack_file* p = new wpack_file
	p.path = strclone(path)
	p.data = data
	p.length = length
	p.body_start = pos
	p.entries = entries
	return result_new_ok[wpack_file*](p)


# Reads and parses the pack file at `path`. Errors: the read errno, or
# pack_parse's PACK_ERR_MALFORMED.
wresult[wpack_file*]* pack_load(char* path):
	string_builder* contents = cas_read_file(path)
	if (contents == 0):
		return result_new_error[wpack_file*](cas_read_errno)
	wresult[wpack_file*]* parsed = pack_parse(path, contents.data, contents.length)
	if (result_is_error[wpack_file*](parsed)):
		string_free(contents)
	else:
		# The wpack_file took ownership of the byte buffer; only the
		# string_builder shell itself is released here.
		free(contents)
	return parsed


int pack_file_has(wpack_file* p, char* id):
	return id in p.entries


# The LOGICAL bytes ("<type> <len>\0" + payload) of the object stored
# under `id` in this pack, or 0 when the pack has no such entry OR the
# entry does not inflate back to exactly its recorded ulen (a corrupt
# entry reads as missing here -- see the header comment; wvc unpack
# reports the same condition as a hard error instead). Owned by the
# caller (string_free).
string_builder* pack_file_get(wpack_file* p, char* id):
	if ((id in p.entries) == 0):
		return 0
	wpack_entry* e = p.entries[id]
	wresult[zlib_result*]* z = zlib_decompress(&p.data[p.body_start + e.offset], e.clen, e.ulen)
	if (result_is_error[zlib_result*](z)):
		result_free[zlib_result*](z)
		return 0
	zlib_result* body = result_value[zlib_result*](z)
	result_free[zlib_result*](z)
	if (body.length != e.ulen):
		zlib_result_free(body)
		return 0
	string_builder* out = string_new()
	string_append_bytes(out, body.data, body.length)
	zlib_result_free(body)
	return out


/* Directory listing (the getdents(2) pattern tree_snapshot uses) */


int pack_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


int pack_is_hex_lower(int c):
	return ((c >= '0') && (c <= '9')) || ((c >= 'a') && (c <= 'f'))


# Appends the names of `dir_path`'s entries of getdents kind `want_kind`
# (4 = directory, 8 = regular file) to `out` as owned clones, skipping
# "." and "..". Returns 0 or the failing syscall's negative errno.
int pack_list_names(char* dir_path, int want_kind, list[char*] out):
	# 65536 = O_DIRECTORY: fail up front when dir_path is not a directory.
	int fd = open(dir_path, 65536, 0)
	if (fd < 0):
		return fd
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* record = buffer + off
			int reclen = pack_load_uint16(record + 2 * __word_size__)
			char* entry_name = record + 2 * __word_size__ + 2
			int kind = record[reclen - 1] & 255
			off = off + reclen
			int skip = (strcmp(entry_name, c".") == 0) || (strcmp(entry_name, c"..") == 0)
			if ((skip == 0) && (kind == want_kind)):
				out.push(strclone(entry_name))
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	if (n < 0):
		return n
	return 0


void pack_free_names(list[char*] names):
	for char* name in names:
		free(name)
	list_free[char*](names)


/* The pack set: lazy scan + read-side lookups */


wpack_set* pack_set_new(char* root):
	wpack_set* ps = new wpack_set
	ps.dir = pack_dir_path(root)
	ps.scanned = 0
	ps.packs = new list[wpack_file*]
	return ps


# Loads every "*.wpack" file under ps.dir, once (idempotent until
# pack_set_reset). A missing packs directory is simply zero packs; a
# file that fails to read or parse is skipped (the fallback seam has no
# error channel -- see the header comment).
void pack_set_scan(wpack_set* ps):
	if (ps.scanned):
		return
	ps.scanned = 1
	list[char*] names = new list[char*]
	int err = pack_list_names(ps.dir, 8, names)
	if (err < 0):
		pack_free_names(names)
		return
	names.sort_by(strcmp)
	int suffix_len = strlen(PACK_SUFFIX())
	for char* name in names:
		int n = strlen(name)
		int is_pack = (n > suffix_len) && (strcmp(name + (n - suffix_len), PACK_SUFFIX()) == 0)
		if (is_pack):
			char* path = path_join(ps.dir, name)
			wresult[wpack_file*]* loaded = pack_load(path)
			if (result_is_ok[wpack_file*](loaded)):
				ps.packs.push(result_value[wpack_file*](loaded))
			result_free[wpack_file*](loaded)
			free(path)
	pack_free_names(names)


# Drops every loaded pack and re-arms the lazy scan, so the next lookup
# sees pack files created or removed since the last scan.
void pack_set_reset(wpack_set* ps):
	for wpack_file* p in ps.packs:
		pack_file_free(p)
	ps.packs.clear()
	ps.scanned = 0


int pack_set_has(wpack_set* ps, char* id):
	pack_set_scan(ps)
	for wpack_file* p in ps.packs:
		if (pack_file_has(p, id)):
			return 1
	return 0


string_builder* pack_set_get(wpack_set* ps, char* id):
	pack_set_scan(ps)
	for wpack_file* p in ps.packs:
		string_builder* found = pack_file_get(p, id)
		if (found != 0):
			return found
	return 0


/* cas.w fallback glue + attach */


string_builder* pack_fallback_load(void* state, char* id):
	return pack_set_get(cast(wpack_set*, state), id)


int pack_fallback_has(void* state, char* id):
	return pack_set_has(cast(wpack_set*, state), id)


void pack_fallback_close(void* state):
	pack_set_free(cast(wpack_set*, state))


# Registers pack-file read-through on an open cas handle: after this,
# cas_get/cas_has/cas_verify consult "<root>/packs/*.wpack" whenever a
# loose object is missing, and cas_close tears the state down (cas.w's
# fallback_close hook), so no separate detach call exists or is needed.
# Infallible by construction -- the packs directory is not touched until
# the first read actually needs it (pack_set_scan's laziness).
void pack_attach(wcas* s):
	wpack_set* ps = pack_set_new(s.root)
	s.fallback_state = ps
	s.fallback_load = pack_fallback_load
	s.fallback_has = pack_fallback_has
	s.fallback_close = pack_fallback_close


# The header comment's registrar assumption, in code: after a write-side
# operation changes the pack population, an attached layer's lazy-scan
# state must be re-armed so the SAME handle's later reads see the
# change. s.fallback_state is this module's own wpack_set* whenever any
# layer is attached at all (pack.w is the tree's only registrar).
void pack_reset_attached(wcas* s):
	if (s.fallback_state != 0):
		pack_set_reset(cast(wpack_set*, s.fallback_state))


/* Loose-object enumeration */


# Every loose object id in the store: the objects/<2-hex>/<62-hex>
# walk, admitting only names that reassemble into a cas_valid_id.
# Returned ids (and the list) are owned by the caller. Pack files,
# in-flight tmp_* files (they live in objects/ itself, never inside a
# fanout directory) and foreign files are all invisible here by
# construction.
wresult[list[char*]]* pack_loose_ids(wcas* s):
	list[char*] fanouts = new list[char*]
	int err = pack_list_names(s.objects, 4, fanouts)
	if (err < 0):
		pack_free_names(fanouts)
		return result_new_error[list[char*]](err)
	list[char*] ids = new list[char*]
	for char* fan in fanouts:
		int fan_ok = (strlen(fan) == 2) && pack_is_hex_lower(fan[0] & 255) && pack_is_hex_lower(fan[1] & 255)
		if (fan_ok && (err == 0)):
			char* fan_dir = path_join(s.objects, fan)
			list[char*] names = new list[char*]
			err = pack_list_names(fan_dir, 8, names)
			if (err == 0):
				for char* name in names:
					string_builder* id_sb = string_new()
					string_append(id_sb, fan)
					string_append(id_sb, name)
					if (cas_valid_id(id_sb.data)):
						ids.push(id_sb.data)
						free(id_sb)
					else:
						string_free(id_sb)
			pack_free_names(names)
			free(fan_dir)
	pack_free_names(fanouts)
	if (err < 0):
		pack_free_names(ids)
		return result_new_error[list[char*]](err)
	return result_new_ok[list[char*]](ids)


/* Pack writing */


# Process-wide sequence for unique temp-file names (same scheme as
# cas.w's cas_temp_sequence; pid + sequence, O_EXCL as the backstop).
int pack_temp_sequence


# Writes `length` bytes to a fresh temp file in `dir` and renames it
# onto `final_path` -- the same atomicity protocol as cas_store_bytes,
# so a reader never observes a partial pack. Returns 0 or a negative
# errno; the temp file is cleaned up on failure.
int pack_write_file_atomic(char* dir, char* final_path, char* data, int length):
	int fd = -17
	char* temp = 0
	int attempts = 0
	while ((fd == -17) && (attempts < 100)):
		string_builder* t = string_new()
		string_append(t, dir)
		string_append(t, c"/tmp_")
		string_append_int(t, getpid())
		string_append_char(t, '_')
		string_append_int(t, pack_temp_sequence)
		pack_temp_sequence = pack_temp_sequence + 1
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
	int err = cas_write_all(fd, data, length)
	int closed = close(fd)
	if ((err == 0) && (closed < 0)):
		err = closed
	if (err == 0):
		err = vcs_rename(temp, final_path)
	if (err < 0):
		vcs_unlink(temp)
	free(temp)
	return err


# Reads one loose object's LOGICAL bytes straight off disk (raw file ->
# cas_inflate_stored), validating the framing before admitting it to a
# pack. Deliberately NOT cas_get: the id list came from the loose walk,
# so the fallback layer must not be consulted, and the logical bytes are
# needed whole (header included) rather than parsed apart.
wresult[string_builder*]* pack_read_loose_logical(wcas* s, char* id):
	char* path = cas_object_path(s, id)
	string_builder* contents = cas_read_file(path)
	free(path)
	if (contents == 0):
		return result_new_error[string_builder*](cas_read_errno)
	string_builder* logical = cas_inflate_stored(contents.data, contents.length)
	string_free(contents)
	if (logical == 0):
		return result_new_error[string_builder*](PACK_ERR_MALFORMED())
	wresult[wcas_object*]* framed = cas_parse_framed(logical.data, logical.length)
	if (result_is_error[wcas_object*](framed)):
		int code = result_code[wcas_object*](framed)
		result_free[wcas_object*](framed)
		string_free(logical)
		return result_new_error[string_builder*](code)
	cas_object_free(result_value[wcas_object*](framed))
	result_free[wcas_object*](framed)
	return result_new_ok[string_builder*](logical)


# Repacks every loose object into one new pack file (see the header
# comment's write-path section). `prune` != 0 additionally removes the
# loose copies -- only after the pack file's rename has made it durable,
# and with unlink/rmdir failures ignored (a survivor is redundant, not
# wrong). A store with no loose objects at all is a successful no-op
# (stats with objects == 0, packs == 0, pack_path == 0). The returned
# stats are owned by the caller (pack_stats_free).
wresult[pack_stats*]* pack_store_loose(wcas* s, int prune):
	wresult[list[char*]]* ids_r = pack_loose_ids(s)
	if (result_is_error[list[char*]](ids_r)):
		int code = result_code[list[char*]](ids_r)
		result_free[list[char*]](ids_r)
		return result_new_error[pack_stats*](code)
	list[char*] ids = result_value[list[char*]](ids_r)
	result_free[list[char*]](ids_r)

	pack_stats* st = new pack_stats
	st.objects = 0
	st.packs = 0
	st.pack_path = 0
	if (ids.length == 0):
		pack_free_names(ids)
		return result_new_ok[pack_stats*](st)
	ids.sort_by(strcmp)

	string_builder* index_lines = string_new()
	string_builder* body = string_new()
	int err = 0
	for char* id in ids:
		if (err == 0):
			wresult[string_builder*]* logical_r = pack_read_loose_logical(s, id)
			if (result_is_error[string_builder*](logical_r)):
				err = result_code[string_builder*](logical_r)
			else:
				string_builder* logical = result_value[string_builder*](logical_r)
				zlib_result* z = zlib_compress(logical.data, logical.length, DEFLATE_LEVEL_BEST())
				string_append(index_lines, id)
				string_append_char(index_lines, ' ')
				string_append_int(index_lines, body.length)
				string_append_char(index_lines, ' ')
				string_append_int(index_lines, z.length)
				string_append_char(index_lines, ' ')
				string_append_int(index_lines, logical.length)
				string_append_char(index_lines, 10)
				string_append_bytes(body, z.data, z.length)
				zlib_result_free(z)
				string_free(logical)
			result_free[string_builder*](logical_r)
	if (err < 0):
		string_free(index_lines)
		string_free(body)
		pack_free_names(ids)
		free(st)
		return result_new_error[pack_stats*](err)

	string_builder* file_bytes = string_new()
	string_append(file_bytes, PACK_MAGIC_LINE())
	string_append_char(file_bytes, 10)
	string_append(file_bytes, c"count ")
	string_append_int(file_bytes, ids.length)
	string_append_char(file_bytes, 10)
	string_append_bytes(file_bytes, index_lines.data, index_lines.length)
	string_append_char(file_bytes, 10)
	string_append_bytes(file_bytes, body.data, body.length)
	string_free(index_lines)
	string_free(body)

	char* digest = malloc(32)
	whash_oneshot(WHASH_SHA256(), file_bytes.data, file_bytes.length, digest)
	char* name_hex = cas_hex_encode(digest)
	free(digest)

	char* dir = pack_dir_path(s.root)
	err = mkdir(dir, 493)
	if ((err < 0) && (err != -17)):
		free(dir)
		free(name_hex)
		string_free(file_bytes)
		pack_free_names(ids)
		free(st)
		return result_new_error[pack_stats*](err)

	string_builder* final_sb = string_new()
	string_append(final_sb, dir)
	string_append_char(final_sb, '/')
	string_append(final_sb, name_hex)
	string_append(final_sb, PACK_SUFFIX())
	char* final_path = final_sb.data
	free(final_sb)
	free(name_hex)

	err = pack_write_file_atomic(dir, final_path, file_bytes.data, file_bytes.length)
	free(dir)
	string_free(file_bytes)
	if (err < 0):
		free(final_path)
		pack_free_names(ids)
		free(st)
		return result_new_error[pack_stats*](err)

	if (prune):
		for char* id in ids:
			char* obj_path = cas_object_path(s, id)
			vcs_unlink(obj_path)
			free(obj_path)
			char* fan_dir = cas_fanout_dir(s, id)
			rmdir(fan_dir)
			free(fan_dir)

	st.objects = ids.length
	st.packs = 1
	st.pack_path = final_path
	pack_free_names(ids)
	pack_reset_attached(s)
	return result_new_ok[pack_stats*](st)


/* Unpacking */


# Explodes every pack back into loose objects (see the header comment's
# write-path section): each entry is inflated, framing-validated, and
# restored through cas_put_raw's atomic loose write; a pack file is
# unlinked only once every one of its objects is loose again, so a
# failure partway leaves the store readable (some objects redundantly
# both loose and packed -- harmless). Hard errors here, unlike the
# fallback read path: a pack that fails to load or an entry that fails
# to inflate/frame is PACK_ERR_MALFORMED (or the underlying errno), not
# a silent skip. A store with no packs is a successful no-op. The
# returned stats are owned by the caller (pack_stats_free).
wresult[pack_stats*]* pack_unpack_all(wcas* s):
	pack_stats* st = new pack_stats
	st.objects = 0
	st.packs = 0
	st.pack_path = 0

	char* dir = pack_dir_path(s.root)
	list[char*] names = new list[char*]
	int err = pack_list_names(dir, 8, names)
	if (err == -2):
		# No packs directory at all: nothing to unpack.
		pack_free_names(names)
		free(dir)
		return result_new_ok[pack_stats*](st)
	if (err < 0):
		pack_free_names(names)
		free(dir)
		free(st)
		return result_new_error[pack_stats*](err)
	names.sort_by(strcmp)

	int suffix_len = strlen(PACK_SUFFIX())
	for char* name in names:
		int n = strlen(name)
		int is_pack = (n > suffix_len) && (strcmp(name + (n - suffix_len), PACK_SUFFIX()) == 0)
		if (is_pack && (err == 0)):
			char* path = path_join(dir, name)
			wresult[wpack_file*]* loaded = pack_load(path)
			if (result_is_error[wpack_file*](loaded)):
				err = result_code[wpack_file*](loaded)
			else:
				wpack_file* p = result_value[wpack_file*](loaded)
				int restored = 0
				for char* id in p.entries:
					if (err == 0):
						string_builder* logical = pack_file_get(p, id)
						if (logical == 0):
							err = PACK_ERR_MALFORMED()
						else:
							wresult[wcas_object*]* framed = cas_parse_framed(logical.data, logical.length)
							string_free(logical)
							if (result_is_error[wcas_object*](framed)):
								err = result_code[wcas_object*](framed)
							else:
								wcas_object* obj = result_value[wcas_object*](framed)
								wresult[char*]* put = cas_put_raw(s, id, obj.object_type, obj.data, obj.length)
								if (result_is_error[char*](put)):
									err = result_code[char*](put)
								else:
									free(result_value[char*](put))
									restored = restored + 1
								result_free[char*](put)
								cas_object_free(obj)
							result_free[wcas_object*](framed)
				pack_file_free(p)
				if (err == 0):
					vcs_unlink(path)
					st.objects = st.objects + restored
					st.packs = st.packs + 1
			result_free[wpack_file*](loaded)
			free(path)
	pack_free_names(names)
	free(dir)
	if (err < 0):
		free(st)
		return result_new_error[pack_stats*](err)
	pack_reset_attached(s)
	return result_new_ok[pack_stats*](st)
