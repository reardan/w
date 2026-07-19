/*
The dirstate: a stat-cached working-tree index (VCS wave 3, issue #252;
design: docs/projects/version_control.md, "Wave 3 -- the performance
structures"). Built on top of wave 1's content-addressed store
(libs/extras/vcs/cas.w) and wave 2's Merkle tree objects
(libs/extras/vcs/tree.w): index.w's job is to make repeated snapshots of
a mostly-unchanged working tree cheap by remembering, per tracked path,
the (size, mtime) the file had the last time its content was actually
hashed, together with the blob id that hash produced.

tree_snapshot (tree.w) always re-reads and re-hashes every file -- the
correct, simple wave-2 baseline (tools/wvc.w's header comment calls this
out explicitly as `status`'s O(tree) cost). index_walk below performs the
SAME getdents-driven directory walk and builds the SAME kind of tree
object via tree.w's own tree_new/tree_add/tree_put, but for a regular
file it first stats the file (index_stat) and, when a previous index
entry exists for that path AND its cached (size, mtime) matches the
current stat AND the entry survives the racy-mtime check
(index_entry_trusted), reuses the cached blob id instead of opening,
reading and hashing the file again. Content is read (and rehashed) only
for new, changed, or racy paths, which is where the O(changed) win comes
from; the directory walk itself is still O(tree) in stat calls, exactly
like git's own `status` (see version_control.md's fundamentals list,
item 8).

Because index_walk with prev = 0 skips the cache check for every entry
(index_entry_trusted(0, ...) is always false), it degrades EXACTLY to
tree_snapshot's behavior -- same tree-building logic, same ignore-list
handling, same fixed TREE_MODE_FILE() (the executable bit is not learned
here either; see tree.w's header comment -- keeping both walkers agree on
mode is what lets a fast-path tree and a slow-path tree of identical
content hash to the identical id, which tests/vcs_index_test.w asserts
directly). This equivalence is what makes it safe for tools/wvc.w to
switch `snapshot`'s tree-building over to index_walk outright (wired
through index_refresh): a repo with no prior index behaves identically to
today's tree_snapshot-based snapshot, and one WITH a prior index gets the
cache for free.

Racy mtime
----------
A cached entry cannot be trusted just because its (size, mtime) still
matches the file on disk: if the file was modified again in the same
clock tick the INDEX ITSELF was last written to disk, the new content
could legitimately carry the exact same one-second-resolution mtime the
index already recorded for the OLD content, and a bare stat comparison
would miss the change. git's fix (and the one implemented here,
index_entry_trusted): an entry whose cached mtime equals the reference
index's own write_time is never trusted, regardless of whether the
current stat matches -- it is re-hashed every time until a later refresh
observes a strictly newer mtime for it. write_time is captured once, up
front, by whichever index this module is refreshing FROM (windex.write_time
of the `prev` argument) -- not the new index being built -- so the guard
is always checking against "when was the index I'm trusting derived from
disk state", which is the invariant that makes the race actually closed.

mtime resolution here is whole seconds (statx's tv_sec, read via
index_stat), matching lib/time.w's time_now() -- the same granularity
`prev.write_time` and every cached entry share, so the equality check is
comparing like with like.

Stat wrapper
------------
index_stat delegates to lib/stat.w's file_stat_path (Linux statx under
the hood). Size and mtime are the only fields the cache needs; the
general parser lives in lib/stat.w so other callers share one path.
arm64/win64/wasm remain unsupported for the directory walk itself, the
same scope tree.w and commit.w settle for -- this module's test only
builds x86 and x64 twins.

Index file format
------------------
Line-oriented text, the same package.wmeta-flavored philosophy tree.w and
commit.w document: parseable in one forward pass, no escaping needed
because the variable-length field (path) is always last on its line.

	index 1
	write_time <decimal seconds>
	entry <size> <mtime> <64-hex blob id> <path>
	entry <size> <mtime> <64-hex blob id> <path>
	...

Entries are sorted ascending by path (tree.w's byte-wise
tree_name_compare -- the "sorted path table" the design doc asks for) and
every path must be unique; index_parse enforces strict ascending order on
read, exactly like tree.w's tree_get enforces canonical entry order.
Paths are index.w's own root-relative, '/'-joined form (tree.w's
tree_diff path convention) and are validated only lightly here
(non-empty, no leading or trailing '/') -- the individual path COMPONENTS
were already validated against tree.w's stricter tree_valid_name when
each entry was produced by index_walk (which builds every path from
tree.w-legal directory-entry names via path_join), so re-deriving that
per-component check here would be redundant, not defensive.

Persisted under <meta>/index (tools/wvc.w's ".wvc" layout convention);
written via the same write-to-temp-then-rename protocol cas.w's objects
and commit.w's refs use, reusing their fsops.w rename/unlink shim rather
than re-deriving it a third time.

Error handling follows docs/error_results.txt: wresult[T]* carrying
negative errnos unchanged, and INDEX_ERR_MALFORMED (-74, EBADMSG -- the
same code cas.w's CAS_ERR_CORRUPT and commit.w's COMMIT_ERR_MALFORMED use
for "bytes that read back fine as a file but do not parse as the format
layered on top") for a stored index whose bytes do not match the grammar
above exactly.

Nothing here enters the seed import graph (docs/projects/version_control.md).
*/
import lib.lib
import lib.path
import lib.result
import lib.time
import lib.container
import lib.stat
import structures.string
import libs.extras.vcs.cas
import libs.extras.vcs.tree
import libs.extras.vcs.__arch__.fsops


# Error code for a stored index whose bytes do not parse as this
# module's format: -74, Linux EBADMSG, matching cas.w's CAS_ERR_CORRUPT
# and commit.w's COMMIT_ERR_MALFORMED for the same class of failure.
int INDEX_ERR_MALFORMED():
	return -74


# The conventional file name under a wvc metadata directory
# (tools/wvc.w's WVC_META_DIR_NAME() -- ".wvc/index").
char* INDEX_FILE_NAME():
	return c"index"


# One cached path entry: the last (size, mtime) this module observed for
# `path` when it last actually hashed the file's content, and the blob id
# that hash produced.
struct index_entry:
	char* path      # owned; root-relative, '/'-joined (tree.w's path form)
	int size
	int mtime
	char* blob_id   # owned 64-hex cas id


# An in-memory index. entries is kept sorted ascending by path
# (index_entry_compare) after index_encode or index_parse; index_refresh
# also returns it pre-sorted. write_time is the reference point
# index_entry_trusted checks a CACHED entry's mtime against when a LATER
# refresh treats this index as `prev` (see the header comment).
struct windex:
	int write_time
	list[index_entry*] entries


windex* index_new():
	windex* idx = new windex
	idx.write_time = 0
	idx.entries = new list[index_entry*]
	return idx


void index_entry_free(index_entry* e):
	free(e.path)
	free(e.blob_id)
	free(e)


void index_free(windex* idx):
	for index_entry* e in idx.entries:
		index_entry_free(e)
	idx.entries.clear()
	list_free[index_entry*](idx.entries)
	free(idx)


int index_entry_compare(index_entry* a, index_entry* b):
	return tree_name_compare(a.path, b.path)


# A path is storable when it is non-empty and neither starts nor ends
# with '/' (see the header comment on why this is lighter than
# tree_valid_name -- each component was already validated when the entry
# was built).
int index_valid_path(char* path):
	if (path == 0):
		return 0
	int n = strlen(path)
	if (n == 0):
		return 0
	if (path[0] == '/'):
		return 0
	if (path[n - 1] == '/'):
		return 0
	return 1


/* Stat */


# Fills *size_out / *mtime_out for `path` via lib/stat.w. Returns 0 on
# success or a negative errno (e.g. -2 ENOENT).
int index_stat(char* path, int* size_out, int* mtime_out):
	file_stat st
	int err = file_stat_path(path, &st)
	if (err == 0):
		size_out[0] = st.size
		mtime_out[0] = st.mtime
	return err


/* The racy-mtime guard */


# Whether `prev`'s cached blob id may be reused for a file currently
# reporting (current_size, current_mtime), without re-reading its
# content. False whenever there is no prior entry or the stat plainly
# differs; false ALSO when prev.mtime equals prev_write_time -- git's
# racy-mtime guard (see the header comment) -- even though the stat
# matches, because a same-tick modification after the reference index
# was written could be invisible to a one-second-resolution mtime.
int index_entry_trusted(index_entry* prev, int current_size, int current_mtime, int prev_write_time):
	if (prev == 0):
		return 0
	if (prev.size != current_size):
		return 0
	if (prev.mtime != current_mtime):
		return 0
	if (prev.mtime == prev_write_time):
		return 0
	return 1


/* Serialization */


string_builder* index_encode(windex* idx):
	idx.entries.sort_by(index_entry_compare)
	string_builder* out = string_new()
	string_append(out, c"index 1\n")
	string_append(out, c"write_time ")
	string_append_int(out, idx.write_time)
	string_append_char(out, 10)
	for index_entry* e in idx.entries:
		string_append(out, c"entry ")
		string_append_int(out, e.size)
		string_append_char(out, ' ')
		string_append_int(out, e.mtime)
		string_append_char(out, ' ')
		string_append(out, e.blob_id)
		string_append_char(out, ' ')
		string_append(out, e.path)
		string_append_char(out, 10)
	return out


int index_find_char(char* data, int end, int start, int ch):
	int i = start
	while ((i < end) && (data[i] != ch)):
		i = i + 1
	return i


int index_find_newline(char* data, int length, int start):
	return index_find_char(data, length, start, 10)


int index_starts_with(char* data, int length, int offset, char* prefix):
	int n = strlen(prefix)
	if ((offset + n) > length):
		return 0
	int i = 0
	while (i < n):
		if (data[offset + i] != prefix[i]):
			return 0
		i = i + 1
	return 1


int index_valid_integer(char* data, int start, int end):
	if (start >= end):
		return 0
	int i = start
	if (data[i] == '-'):
		i = i + 1
	if (i >= end):
		return 0
	while (i < end):
		int c = data[i] & 255
		if ((c < '0') || (c > '9')):
			return 0
		i = i + 1
	return 1


int index_parse_integer(char* data, int start, int end):
	char* s = path_clone_range(data + start, end - start)
	int v = atoi(s)
	free(s)
	return v


# Parses the format documented in the header comment in one forward pass
# (mirroring tree.w's tree_get): the two fixed header lines, then zero or
# more "entry ..." lines in strictly ascending path order. Any grammar
# violation -- a missing/wrong header, a malformed integer or blob id, an
# unstorable path, or entries out of order -- is INDEX_ERR_MALFORMED.
wresult[windex*]* index_parse(char* data, int length):
	int pos = 0
	if (index_starts_with(data, length, pos, c"index 1\n") == 0):
		return result_new_error[windex*](INDEX_ERR_MALFORMED())
	pos = pos + strlen(c"index 1\n")

	if (index_starts_with(data, length, pos, c"write_time ") == 0):
		return result_new_error[windex*](INDEX_ERR_MALFORMED())
	pos = pos + strlen(c"write_time ")
	int wt_end = index_find_newline(data, length, pos)
	if ((wt_end >= length) || (index_valid_integer(data, pos, wt_end) == 0)):
		return result_new_error[windex*](INDEX_ERR_MALFORMED())
	int write_time = index_parse_integer(data, pos, wt_end)
	pos = wt_end + 1

	windex* idx = index_new()
	idx.write_time = write_time
	char* prev_path = 0
	int valid = 1
	while (valid && (pos < length)):
		if (index_starts_with(data, length, pos, c"entry ") == 0):
			valid = 0
			break
		pos = pos + strlen(c"entry ")

		int size_start = pos
		int size_end = index_find_char(data, length, pos, ' ')
		if ((size_end >= length) || (index_valid_integer(data, size_start, size_end) == 0)):
			valid = 0
			break
		pos = size_end + 1

		int mtime_start = pos
		int mtime_end = index_find_char(data, length, pos, ' ')
		if ((mtime_end >= length) || (index_valid_integer(data, mtime_start, mtime_end) == 0)):
			valid = 0
			break
		pos = mtime_end + 1

		# "<id> ": exactly 64 hex characters then a space.
		if (((pos + 65) > length) || (data[pos + 64] != ' ')):
			valid = 0
			break
		char* id = path_clone_range(data + pos, 64)
		if (cas_valid_id(id) == 0):
			free(id)
			valid = 0
			break
		pos = pos + 65

		# "<path>\n": everything up to the line terminator.
		int path_start = pos
		int path_end = index_find_newline(data, length, pos)
		if (path_end >= length):
			free(id)
			valid = 0
			break
		char* path = path_clone_range(data + path_start, path_end - path_start)
		pos = path_end + 1

		int ok = index_valid_path(path)
		if (ok && (prev_path != 0)):
			ok = tree_name_compare(prev_path, path) < 0
		if (ok == 0):
			free(id)
			free(path)
			valid = 0
			break

		index_entry* e = new index_entry
		e.path = path
		e.size = index_parse_integer(data, size_start, size_end)
		e.mtime = index_parse_integer(data, mtime_start, mtime_end)
		e.blob_id = id
		idx.entries.push(e)
		prev_path = path

	if (valid == 0):
		index_free(idx)
		return result_new_error[windex*](INDEX_ERR_MALFORMED())
	return result_new_ok[windex*](idx)


/* File IO */


# Process-wide sequence for unique temp-file names -- the same
# pid+sequence+O_EXCL scheme cas.w's cas_store_bytes and commit.w's
# ref_write_atomic use, kept as its own counter because this module
# writes into a different directory (the metadata root, not objects/ or
# refs/heads/).
int index_temp_sequence


# Writes `idx` to `path` via write-to-temp-then-rename (cas.w/commit.w's
# atomicity protocol, reusing their fsops.w vcs_rename/vcs_unlink rather
# than re-deriving it a third time). `path`'s directory must already
# exist (tools/wvc.w's ".wvc" metadata dir, created by cas_open/refs_open
# before this is ever called). Returns 0 or a negative errno.
wresult[int]* index_write(windex* idx, char* path):
	string_builder* enc = index_encode(idx)
	char* dir = path_dirname(path)

	int fd = -17
	char* temp = 0
	int attempts = 0
	while ((fd == -17) && (attempts < 100)):
		string_builder* t = string_new()
		string_append(t, dir)
		string_append(t, c"/tmp_index_")
		string_append_int(t, getpid())
		string_append_char(t, '_')
		string_append_int(t, index_temp_sequence)
		index_temp_sequence = index_temp_sequence + 1
		temp = t.data
		free(t)
		# 193 = O_WRONLY | O_CREAT | O_EXCL, 420 = rw-r--r--
		fd = open(temp, 193, 420)
		if (fd == -17):
			free(temp)
			temp = 0
		attempts = attempts + 1
	free(dir)
	if (fd < 0):
		string_free(enc)
		return result_new_error[int](fd)

	int err = 0
	int wrote = write(fd, enc.data, enc.length)
	if (wrote < 0):
		err = wrote
	else if (wrote != enc.length):
		err = -5   # EIO: a regular file should never short-write
	int closed = close(fd)
	if ((err == 0) && (closed < 0)):
		err = closed
	if (err == 0):
		err = vcs_rename(temp, path)
	if (err < 0):
		vcs_unlink(temp)
	free(temp)
	string_free(enc)
	if (err < 0):
		return result_new_error[int](err)
	return result_new_ok[int](0)


# Reads and parses the index stored at `path`. Errors: the open errno
# (e.g. -2 ENOENT -- "no index yet", the absent-index case a caller
# checks for) or INDEX_ERR_MALFORMED for a file that exists but does not
# parse.
wresult[windex*]* index_read(char* path):
	string_builder* contents = cas_read_file(path)
	if (contents == 0):
		return result_new_error[windex*](cas_read_errno)
	wresult[windex*]* r = index_parse(contents.data, contents.length)
	string_free(contents)
	return r


/* The stat-cached walk */


int index_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Recursively walks `dir` (a real filesystem path) exactly like
# tree.w's tree_snapshot, building the same kind of tree object via
# tree_new/tree_add/tree_put -- but for each regular file, stats it
# first and reuses `prev_by_path`'s cached blob id when
# index_entry_trusted allows it, appending a fresh index_entry (for
# every regular file found, cached or not) to `out_entries`. `prefix` is
# the root-relative '/'-joined path built up so far (tree.w's
# convention; the top-level call passes ""). Errors: the failing
# syscall's errno, -22 for a file name the tree format cannot store, and
# cas_put's errors -- identical to tree_snapshot's error surface.
wresult[char*]* index_walk(wcas* s, char* dir, char* prefix, list[char*] ignore, map[char*, index_entry*] prev_by_path, int prev_write_time, list[index_entry*] out_entries):
	# 65536 = O_DIRECTORY: fail up front when dir is not a directory.
	int fd = open(dir, 65536, 0)
	if (fd < 0):
		return result_new_error[char*](fd)
	wtree* t = tree_new()
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int err = 0
	int n = getdents(fd, buffer, buffer_size)
	while ((err == 0) && (n > 0)):
		int off = 0
		while ((err == 0) && (off < n)):
			char* record = buffer + off
			int reclen = index_load_uint16(record + 2 * __word_size__)
			char* entry_name = record + 2 * __word_size__ + 2
			int kind = record[reclen - 1] & 255
			off = off + reclen
			int skip = (strcmp(entry_name, c".") == 0) || (strcmp(entry_name, c"..") == 0)
			skip = skip || tree_ignored(ignore, entry_name)
			skip = skip || ((kind != 4) && (kind != 8))
			if (skip == 0):
				char* child_disk_path = path_join(dir, entry_name)
				char* child_rel_path = path_join(prefix, entry_name)
				char* child_id = 0
				if (kind == 4):
					wresult[char*]* sub = index_walk(s, child_disk_path, child_rel_path, ignore, prev_by_path, prev_write_time, out_entries)
					if (result_is_error[char*](sub)):
						err = result_code[char*](sub)
					else:
						child_id = result_value[char*](sub)
					result_free[char*](sub)
				else:
					int size = 0
					int mtime = 0
					int stat_err = index_stat(child_disk_path, &size, &mtime)
					if (stat_err < 0):
						err = stat_err
					else:
						index_entry* prev = 0
						if ((prev_by_path != 0) && (child_rel_path in prev_by_path)):
							prev = prev_by_path[child_rel_path]
						if (index_entry_trusted(prev, size, mtime, prev_write_time)):
							child_id = strclone(prev.blob_id)
						else:
							string_builder* contents = cas_read_file(child_disk_path)
							if (contents == 0):
								err = cas_read_errno
							else:
								wresult[char*]* put = cas_put(s, c"blob", contents.data, contents.length)
								if (result_is_error[char*](put)):
									err = result_code[char*](put)
								else:
									child_id = result_value[char*](put)
								result_free[char*](put)
								string_free(contents)
						if (err == 0):
							index_entry* e = new index_entry
							e.path = strclone(child_rel_path)
							e.size = size
							e.mtime = mtime
							e.blob_id = strclone(child_id)
							out_entries.push(e)
				if (err == 0):
					int mode = TREE_MODE_DIR()
					if (kind == 8):
						mode = TREE_MODE_FILE()
					err = tree_add(t, entry_name, mode, child_id)
				if (child_id != 0):
					free(child_id)
				free(child_disk_path)
				free(child_rel_path)
		if (err == 0):
			n = getdents(fd, buffer, buffer_size)
	if ((err == 0) && (n < 0)):
		err = n
	free(buffer)
	close(fd)
	if (err < 0):
		tree_free(t)
		return result_new_error[char*](err)
	wresult[char*]* root = tree_put(s, t)
	tree_free(t)
	return root


/* Refresh: the public entry point */


# Bundles index_refresh's two owned results: the fresh root tree id
# (store it in a commit, or tree_diff it against HEAD) and the fresh
# windex (persist it with index_write, or discard it). Both fields are
# the caller's to free once extracted; free the struct itself with a
# plain free() after.
struct index_refresh_result:
	char* tree_id
	windex* index


# Refreshes the dirstate for the tree rooted at `dir`: walks it with
# index_walk, using `prev` (0 for "no prior index" -- every entry is
# then rehashed, exactly like tree_snapshot) as the stat cache and `now`
# as the NEW index's write_time. Does not free or otherwise consume
# `prev` -- the caller still owns it. Errors are index_walk's (a failing
# syscall's errno, -22, or cas_put's errors).
wresult[index_refresh_result*]* index_refresh_at(wcas* s, char* dir, list[char*] ignore, windex* prev, int now):
	map[char*, index_entry*] prev_by_path = 0
	int prev_write_time = 0
	if (prev != 0):
		prev_by_path = new map[char*, index_entry*]
		for index_entry* e in prev.entries:
			prev_by_path[e.path] = e
		prev_write_time = prev.write_time

	list[index_entry*] out_entries = new list[index_entry*]
	wresult[char*]* root = index_walk(s, dir, c"", ignore, prev_by_path, prev_write_time, out_entries)
	if (prev_by_path != 0):
		map_free[char*, index_entry*](prev_by_path)

	if (result_is_error[char*](root)):
		for index_entry* e in out_entries:
			index_entry_free(e)
		out_entries.clear()
		list_free[index_entry*](out_entries)
		int code = result_code[char*](root)
		result_free[char*](root)
		return result_new_error[index_refresh_result*](code)

	char* tree_id = result_value[char*](root)
	result_free[char*](root)

	windex* new_index = new windex
	new_index.write_time = now
	new_index.entries = out_entries
	new_index.entries.sort_by(index_entry_compare)

	index_refresh_result* rr = new index_refresh_result
	rr.tree_id = tree_id
	rr.index = new_index
	return result_new_ok[index_refresh_result*](rr)


# index_refresh_at with now = time_now() -- the entry point every real
# caller (tools/wvc.w) uses. `now` only ever becomes the RETURNED
# index's write_time (relevant to whoever refreshes FROM it later); the
# racy-mtime decision for THIS call is governed entirely by `prev`'s own
# write_time (see index_entry_trusted), which is why
# vcs_index_test.w's deterministic racy-mtime coverage constructs `prev`
# directly and calls this function rather than index_refresh_at --
# nothing about the guard being tested depends on `now`.
wresult[index_refresh_result*]* index_refresh(wcas* s, char* dir, list[char*] ignore, windex* prev):
	return index_refresh_at(s, dir, ignore, prev, time_now())
