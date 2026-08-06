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
rename protocol cas.w uses for objects/). The current writer emits
version 2; version 1 (PR #401's format) stays readable forever -- see
"Version 1 compatibility" below.

	wpack 2\n
	count <N>\n
	<id> f <offset> <clen> <ulen>\n                       (full entry)
	<id> d <offset> <clen> <ulen> <rlen> <base-id>\n      (delta entry)
	\n
	<body: the N entries' zlib streams, back to back>

Header lines are ASCII text in the same package.wmeta-flavored
"parseable without a general parser" spirit as commit.w/tree.w/delta.w:
one forward pass, fixed field order, a blank line ends the header. Each
index line names one object: its 64-hex id, a one-character encoding
kind, the byte offset of its entry inside the body (relative to the
first body byte, so the header's own size never shifts offsets), the
entry's compressed length, and the length of the bytes its zlib stream
inflates back to. An entry's bytes are libs/extras/compress/zlib.w's
zlib_compress, at DEFLATE_LEVEL_BEST, of:

  - kind 'f' (full): the object's logical "<type> <len>\0" + payload
    sequence -- the same bytes a loose object's on-disk encoding
    compresses (cas.w's "On-disk encoding"), so packing and unpacking
    are pure re-encodings that can never change an object's identity,
    and unpacking an object written by this cas.w reproduces the loose
    file byte-for-byte (same deterministic zlib encoder, same level).
  - kind 'd' (delta -- pack-internal re-deltification, issue #252's
    last VCS remainder): a delta.w opcode stream (delta_encode_ops's
    wire format, applied with delta_apply) whose BASE is the LOGICAL
    bytes of the pack entry named by the line's trailing <base-id>,
    and whose reconstruction is this object's own logical bytes. The
    two extra fields are <rlen>, the reconstructed logical length
    (checked after every apply), and the 64-hex base id, which MUST
    name an entry in the SAME pack file (the parser rejects a base id
    the index does not contain, so resolution never leaves the file).
    Base entries may themselves be deltas; chains bottom out at a
    full entry within DELTA_MAX_CHAIN_DEPTH() hops -- the reader
    walks with its own hop budget exactly like delta.w's
    cas_get_resolved, so a corrupt or hand-crafted pack with a base
    cycle reads as "object missing" instead of recursing forever.

Base selection (the writer's pairing heuristic, git's sliding-window
scheme scaled down): objects are sorted by (logical type tag, size
descending, id) so related objects -- successive versions of similar
content -- land next to each other, then each object tries a delta
against the up-to-PACK_DELTA_WINDOW() immediately preceding objects
in that order (skipping candidates whose own chain depth is already
at the bound). The smallest raw opcode stream that also beats the
object's own size is the one candidate that gets deflated, and the
entry is stored as a delta only when that deflated delta is STRICTLY
smaller than the object's plain deflate -- so a v2 pack is never
larger than the v1 pack of the same objects (modulo the few bytes of
index-line tag), and objects with no similar neighbor degrade to
exactly the v1 encoding. Everything in the pipeline (the sort, the
window scan, delta_diff, zlib_compress) is deterministic, so the pack
file's bytes -- and therefore its content-hash name -- remain a pure
function of the object set, the same promise v1 made.

Version 1 compatibility: the parser accepts "wpack 1" headers
unchanged -- a v1 index line is exactly a v2 'f' line without the
kind field ("<id> <offset> <clen> <ulen>"), and v1 bodies are all
full entries. Reading, unpacking, and pruning mixed stores (old v1
packs next to new v2 packs) all work; nothing ever rewrites a v1
file in place (repacking naturally replaces it with a v2 one).

Ids are treated as NAMES, not re-verified content hashes, on both the
pack and unpack paths: a store legitimately contains objects whose id
is not the hash of their own logical bytes -- cas_put_raw build-cache
entries keyed by input hashes (issue #251 direction 3), and delta.w
chains, whose id is the hash of the RECONSTRUCTED object rather than
the stored "delta" payload. Integrity inside a pack rests on the zlib
streams' own adler32 checksums plus the recorded ulen (and rlen for
delta entries); full digest verification stays cas_verify's job,
exactly as for loose raw-put objects. delta.w CHAIN objects (the
"delta"-typed CAS species) pack as ordinary entries of their stored
logical bytes -- pack-internal deltification is a second, independent
layer below them, invisible above pack_file_get, so a packed chain
still resolves through delta.w's cas_get_resolved unchanged.

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
import libs.extras.vcs.delta
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


# The two accepted header magic lines: v1 (PR #401's format, read-only
# compatibility) and v2 (the current writer's format, adding per-entry
# delta encoding -- see the header comment).
char* PACK_MAGIC_V1():
	return c"wpack 1"


char* PACK_MAGIC_V2():
	return c"wpack 2"


# Index-line encoding kinds (v2): 'f' = full (the zlib stream inflates
# to the object's logical bytes), 'd' = delta (it inflates to a delta.w
# opcode stream against another entry of the same pack).
int PACK_ENTRY_FULL():
	return 'f'


int PACK_ENTRY_DELTA():
	return 'd'


# How many immediately preceding objects (in the writer's sorted order)
# are tried as delta bases for each object -- git's sliding window,
# scaled to this store's size. Purely a write-time effort/ratio knob:
# packs written under any window read back identically.
int PACK_DELTA_WINDOW():
	return 8


# "<root>/packs" (owned by the caller).
char* pack_dir_path(char* root):
	return path_join(root, PACK_DIR_NAME())


/* Structures */


# One indexed object inside a pack: where its zlib stream lives in the
# body, how long that stream is, how many bytes it inflates back to,
# and (for kind == PACK_ENTRY_DELTA()) which same-pack entry is its
# base plus the reconstructed logical length. For full entries (every
# v1 entry, and v2 'f' lines) rlen == ulen and base_id == 0.
struct wpack_entry:
	int kind
	int offset
	int clen
	int ulen
	int rlen
	char* base_id     # owned; 0 for full entries


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


void pack_entry_free(wpack_entry* e):
	if (e.base_id != 0):
		free(e.base_id)
	free(e)


void pack_entries_free(map[char*, wpack_entry*] entries):
	for char* id in entries:
		pack_entry_free(entries[id])
	map_free[char*, wpack_entry*](entries)


void pack_file_free(wpack_file* p):
	pack_entries_free(p.entries)
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
# format end to end: magic/version line (v1 and v2 both accepted --
# see the header comment's compatibility section), count, every index
# line (valid id, kind for v2, in-range numeric fields, ids unique, a
# valid same-pack base id on every delta line), the blank header
# terminator, and every entry's [offset, offset+clen) staying inside
# the body. On success the returned wpack_file OWNS `data` (and `path`
# is cloned); on error the caller keeps ownership of `data`.
wresult[wpack_file*]* pack_parse(char* path, char* data, int length):
	int pos = 0
	int version = 0
	if (pack_starts_with(data, length, pos, PACK_MAGIC_V1())):
		version = 1
		pos = pos + strlen(PACK_MAGIC_V1())
	else if (pack_starts_with(data, length, pos, PACK_MAGIC_V2())):
		version = 2
		pos = pos + strlen(PACK_MAGIC_V2())
	int valid = version != 0
	if (valid):
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
		int kind = PACK_ENTRY_FULL()
		if (version == 2):
			valid = valid && pack_expect_char(data, length, &pos, ' ')
			if (valid && (pos < length)):
				kind = data[pos] & 255
				valid = (kind == PACK_ENTRY_FULL()) || (kind == PACK_ENTRY_DELTA())
				pos = pos + 1
			else:
				valid = 0
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
			valid = valid && (ulen >= 0)
		int rlen = ulen
		char* base_id = 0
		if (valid && (kind == PACK_ENTRY_DELTA())):
			valid = pack_expect_char(data, length, &pos, ' ')
			if (valid):
				rlen = pack_parse_uint(data, length, &pos)
				valid = (rlen >= 0) && pack_expect_char(data, length, &pos, ' ')
			valid = valid && ((pos + 64) <= length)
			if (valid):
				base_id = path_clone_range(data + pos, 64)
				pos = pos + 64
				valid = cas_valid_id(base_id)
		valid = valid && pack_expect_char(data, length, &pos, 10)
		if (valid):
			wpack_entry* e = new wpack_entry
			e.kind = kind
			e.offset = offset
			e.clen = clen
			e.ulen = ulen
			e.rlen = rlen
			e.base_id = base_id
			entries[id] = e
		else if (base_id != 0):
			free(base_id)
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
			# Delta resolution never leaves the file: a base id that is
			# not itself an entry of THIS pack is malformed by definition
			# (the writer only ever pairs same-pack objects).
			if ((e.base_id != 0) && ((e.base_id in entries) == 0)):
				valid = 0
	if (valid == 0):
		pack_entries_free(entries)
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


# Inflates one entry's zlib stream, or 0 when it does not inflate back
# to exactly its recorded ulen. For a full entry these are the object's
# logical bytes; for a delta entry, its opcode stream. Owned by the
# caller (string_free).
string_builder* pack_entry_inflate(wpack_file* p, wpack_entry* e):
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


# The recursive half of pack_file_get: resolves an entry to its logical
# bytes, walking delta bases with an explicit hop budget -- decremented
# once per delta link actually followed, independent of anything the
# file claims, so a corrupt or hand-crafted pack with a base cycle
# (which pack_parse cannot see: every id in the cycle IS in the index)
# fails cleanly as "missing" after at most DELTA_MAX_CHAIN_DEPTH()
# steps instead of recursing forever (the same discipline as delta.w's
# delta_resolve).
string_builder* pack_file_get_hops(wpack_file* p, char* id, int hops_remaining):
	if ((id in p.entries) == 0):
		return 0
	wpack_entry* e = p.entries[id]
	string_builder* stream = pack_entry_inflate(p, e)
	if (stream == 0):
		return 0
	if (e.kind != PACK_ENTRY_DELTA()):
		return stream
	if (hops_remaining <= 0):
		string_free(stream)
		return 0
	string_builder* base = pack_file_get_hops(p, e.base_id, hops_remaining - 1)
	if (base == 0):
		string_free(stream)
		return 0
	wresult[delta_apply_result*]* applied = delta_apply(base.data, base.length, stream.data, stream.length)
	string_free(base)
	string_free(stream)
	if (result_is_error[delta_apply_result*](applied)):
		result_free[delta_apply_result*](applied)
		return 0
	delta_apply_result* r = result_value[delta_apply_result*](applied)
	result_free[delta_apply_result*](applied)
	if (r.length != e.rlen):
		delta_apply_result_free(r)
		return 0
	string_builder* out = string_new()
	string_append_bytes(out, r.data, r.length)
	delta_apply_result_free(r)
	return out


# The LOGICAL bytes ("<type> <len>\0" + payload) of the object stored
# under `id` in this pack, or 0 when the pack has no such entry OR the
# entry fails to resolve -- a stream that does not inflate back to its
# recorded ulen, a delta whose apply fails or whose reconstruction
# misses its recorded rlen, or a base chain deeper than
# DELTA_MAX_CHAIN_DEPTH() (a corrupt entry reads as missing here -- see
# the header comment; wvc unpack reports the same condition as a hard
# error instead). Owned by the caller (string_free).
string_builder* pack_file_get(wpack_file* p, char* id):
	return pack_file_get_hops(p, id, DELTA_MAX_CHAIN_DEPTH())


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


/* Delta base selection (the write-side pairing heuristic) */


# One object staged for packing: its id (borrowed from the caller's id
# list), its logical bytes and their leading type tag (both owned), and
# the delta-chain depth it ended up stored at (0 = full entry; assigned
# as entries are emitted, consulted when later objects consider this
# one as a base).
struct pack_plan:
	char* id
	string_builder* logical
	char* type_tag    # owned
	int depth


void pack_plan_list_free(list[pack_plan*] plans):
	for pack_plan* pl in plans:
		string_free(pl.logical)
		free(pl.type_tag)
		free(pl)
	list_free[pack_plan*](plans)


# The leading type tag of already-validated logical bytes (framing was
# checked by pack_read_loose_logical, so the scan always stops at the
# header's ' '). Owned by the caller.
char* pack_logical_tag(string_builder* logical):
	int i = 0
	while ((i < logical.length) && cas_valid_tag_char(logical.data[i] & 255)):
		i = i + 1
	return path_clone_range(logical.data, i)


# Packing order: type tag, then size DESCENDING, then id -- so objects
# likely to share content (several versions of similar payloads have
# the same type and similar sizes) become window neighbors, and deltas
# tend to point from smaller objects at larger bases. Ids are unique,
# so this is a total (and therefore deterministic) order.
int pack_plan_compare(pack_plan* a, pack_plan* b):
	int t = strcmp(a.type_tag, b.type_tag)
	if (t != 0):
		return t
	if (a.logical.length > b.logical.length):
		return -1
	if (a.logical.length < b.logical.length):
		return 1
	return strcmp(a.id, b.id)


# Picks the best delta base for plans[i] among the up-to-
# PACK_DELTA_WINDOW() preceding objects in packing order, skipping
# candidates whose own chain is already DELTA_MAX_CHAIN_DEPTH() deep.
# "Best" is the smallest RAW opcode stream that is also smaller than
# the object's own logical bytes (a delta at least as large as the
# content itself can never win after deflate); ties keep the earliest
# candidate. Returns the winning candidate's index via *best_index and
# the caller-owned opcode stream, or 0 when no candidate qualifies --
# the final delta-vs-full call stays with the caller, which deflates
# the one winner and compares COMPRESSED sizes.
string_builder* pack_pick_delta(list[pack_plan*] plans, int i, int* best_index):
	pack_plan* target = plans[i]
	string_builder* best = 0
	int j = i - PACK_DELTA_WINDOW()
	if (j < 0):
		j = 0
	while (j < i):
		pack_plan* cand = plans[j]
		if ((cand.depth + 1) <= DELTA_MAX_CHAIN_DEPTH()):
			delta_ops* ops = delta_diff(cand.logical.data, cand.logical.length, target.logical.data, target.logical.length)
			string_builder* payload = delta_encode_ops(ops)
			delta_ops_free(ops)
			int better = payload.length < target.logical.length
			better = better && ((best == 0) || (payload.length < best.length))
			if (better):
				if (best != 0):
					string_free(best)
				best = payload
				*best_index = j
			else:
				string_free(payload)
		j = j + 1
	return best


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

	# Load every object's logical bytes, then sort into packing order
	# (pack_plan_compare) so the delta window sees related objects as
	# neighbors. Whole-population-in-memory matches the read side's
	# posture (a loaded pack keeps its file in memory too).
	list[pack_plan*] plans = new list[pack_plan*]
	int err = 0
	for char* id in ids:
		if (err == 0):
			wresult[string_builder*]* logical_r = pack_read_loose_logical(s, id)
			if (result_is_error[string_builder*](logical_r)):
				err = result_code[string_builder*](logical_r)
			else:
				pack_plan* pl = new pack_plan
				pl.id = id
				pl.logical = result_value[string_builder*](logical_r)
				pl.type_tag = pack_logical_tag(pl.logical)
				pl.depth = 0
				plans.push(pl)
			result_free[string_builder*](logical_r)
	if (err < 0):
		pack_plan_list_free(plans)
		pack_free_names(ids)
		free(st)
		return result_new_error[pack_stats*](err)
	plans.sort_by(pack_plan_compare)

	# Emit: each object stores as a delta against its best window
	# candidate when that delta's deflate is STRICTLY smaller than the
	# object's own deflate, else as a full entry (exactly the v1
	# encoding). Every step here is deterministic -- see the header
	# comment's determinism paragraph.
	string_builder* index_lines = string_new()
	string_builder* body = string_new()
	int i = 0
	while (i < plans.length):
		pack_plan* pl = plans[i]
		zlib_result* full_z = zlib_compress(pl.logical.data, pl.logical.length, DEFLATE_LEVEL_BEST())
		int best_index = -1
		string_builder* payload = pack_pick_delta(plans, i, &best_index)
		zlib_result* delta_z = 0
		if (payload != 0):
			delta_z = zlib_compress(payload.data, payload.length, DEFLATE_LEVEL_BEST())
			if (delta_z.length >= full_z.length):
				zlib_result_free(delta_z)
				delta_z = 0
		string_append(index_lines, pl.id)
		string_append_char(index_lines, ' ')
		if (delta_z != 0):
			string_append_char(index_lines, PACK_ENTRY_DELTA())
		else:
			string_append_char(index_lines, PACK_ENTRY_FULL())
		string_append_char(index_lines, ' ')
		string_append_int(index_lines, body.length)
		string_append_char(index_lines, ' ')
		if (delta_z != 0):
			string_append_int(index_lines, delta_z.length)
			string_append_char(index_lines, ' ')
			string_append_int(index_lines, payload.length)
			string_append_char(index_lines, ' ')
			string_append_int(index_lines, pl.logical.length)
			string_append_char(index_lines, ' ')
			string_append(index_lines, plans[best_index].id)
			string_append_bytes(body, delta_z.data, delta_z.length)
			pl.depth = plans[best_index].depth + 1
			zlib_result_free(delta_z)
		else:
			string_append_int(index_lines, full_z.length)
			string_append_char(index_lines, ' ')
			string_append_int(index_lines, pl.logical.length)
			string_append_bytes(body, full_z.data, full_z.length)
			pl.depth = 0
		string_append_char(index_lines, 10)
		if (payload != 0):
			string_free(payload)
		zlib_result_free(full_z)
		i = i + 1
	pack_plan_list_free(plans)

	string_builder* file_bytes = string_new()
	string_append(file_bytes, PACK_MAGIC_V2())
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
