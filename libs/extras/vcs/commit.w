/*
Commit objects, refs-as-files, and an append-only reflog (VCS wave 2,
issue #252 V2b; design: docs/projects/version_control.md,
docs/projects/consolidated_plan_2026_07.md section 4). Built directly on
libs/extras/vcs/cas.w (wave 1's content-addressed store): a commit is
just another CAS object under object type "commit", so identity, dedup,
and integrity all come for free from cas.w's addressing scheme.

Commit object format
---------------------
Line-oriented text, deliberately in the same spirit as package.wmeta
(docs/package_metadata.txt: "parseable without a general parser") and
modeled on git's own commit header/body split:

	tree <64-hex id>
	parent <64-hex id>              # zero or more, one per line, in order
	author <free text, one line>
	timestamp <decimal seconds since epoch, may be negative>
	                                 # blank line: ends the header
	<message, verbatim to EOF>

Field order is fixed (tree, then every parent, then author, then
timestamp, then the blank separator, then the message) -- this is what
lets commit_scan validate the whole object with a single forward pass
and no backtracking, exactly the property the package.wmeta format
trades a general parser for. A message line that itself starts with
"tree ", "parent ", etc. is never misread as a header: commit_scan looks
for the header/body separator exactly once, moving strictly forward, so
anything at or after "message_start" is copied verbatim regardless of
its shape. The message is stored and returned as an exact byte range
(commit_object.message / message_length), so embedded blank lines,
trailing/missing newlines, and (should a caller ever need it) embedded
NUL bytes all round-trip exactly.

Header values that must stay on one line (author; the reflog message
below) have embedded '\n' bytes replaced with spaces at construction
time (commit_single_line) rather than being rejected, so the encoder can
never be asked to produce a line an honest forward-scanning parser could
misread as more than one.

Ids embedded in the format (tree, parent, and separately the ref/reflog
ids below) are validated with cas.w's cas_valid_id: 64 lowercase hex
characters, the same canonical form cas.w's own object ids use, so a
commit's tree/parent fields are always ready to hand straight to
cas_get.

Malformed objects (docs/error_results.txt): commit_parse and
commit_load return an error wresult with COMMIT_ERR_MALFORMED (-74,
EBADMSG -- the same errno cas.w's CAS_ERR_CORRUPT uses for the same
class of problem: bytes that read back fine as a CAS object but do not
parse as the format layered on top) for anything that does not match
the grammar above exactly: a missing or wrong-order header line, an
invalid tree/parent hex id, a missing author/timestamp line, a
non-numeric timestamp, or a missing blank-line separator. commit_load
additionally rejects an object whose CAS type tag is not "commit".
commit_new validates its own inputs up front (-22 EINVAL for a
malformed tree/parent id), so a commit built through this module's own
constructor can never fail to round-trip through commit_parse.

Refs as files
-------------
A ref is a name -> commit id mapping stored as a file:

	<root>/refs/heads/<name>   contains "<64-hex id>\n", nothing else

under a caller-given root (refs_open), mirroring cas_open's "root and
its subdirectories only, root's parent must already exist" contract.
Ref names are restricted to a flat [A-Za-z0-9._-]+ charset (no leading
or trailing '.', no '/') -- deliberately no nested namespaces
("feature/x") yet, since that needs the file/directory collision policy
git's refs.c works out on top of a plain filesystem; flat names
sidestep the question until something needs it (future work). Names
starting with "tmp_" are also rejected: ref_write_atomic's own temp
files use that prefix, so a temp file orphaned by a crash (the same
O_EXCL-retry situation cas.w's cas_store_bytes documents) is
structurally invisible to ref_list without needing to special-case it
there.

Ref updates are atomic the same way cas.w's objects are: write to a
fresh temp file in refs/heads/ (so the rename target is on the same
filesystem) and rename(2) over the final path. This reuses cas.w's
per-target rename/unlink shim (libs.extras.vcs.__arch__.fsops --
vcs_rename/vcs_unlink) directly rather than re-deriving the
arch-specific atomicity primitive; see cas.w's header comment for why
that shim exists at all (win64/wasm are unsupported by it, so they are
unsupported here too).

Append-only reflog
-------------------
Every ref_create/ref_update call appends one line to
<root>/logs/<name>:

	<old-64-hex-id> <new-64-hex-id> <decimal timestamp> <message>\n

split on the first three spaces (mirrors the commit header lines: fixed
field order, message is "rest of line"). A brand-new ref's old id is
REF_ZERO_ID() -- 64 '0' characters, git's own "this ref did not exist
before" sentinel, chosen for that familiarity; nothing about it is
treated as a real object id. The message is passed through
commit_single_line first (see above), so a caller that hands in a
multi-line commit message here still produces exactly one reflog line.
Appends use O_APPEND, not temp+rename: a single write() to an
O_APPEND-opened regular file is atomic on Linux, so concurrent appenders
and a reader mid-append never observe an interleaved line, and an
append-only log has no "previous version" that a partial rewrite could
corrupt the way a ref file's full-content replacement could.

If a ref write succeeds but the following reflog append fails (a full
disk, say), ref_create/ref_update report the append's error but do NOT
roll back the ref write -- the ref itself stays authoritative, matching
git's own best-effort posture toward its reflog.

ref_list uses the legacy Linux getdents(2) record layout (d_type is the
record's last byte), which matches x86 and x64 -- the only targets this
module's test builds for. arm64 uses getdents64, whose record layout
places d_type differently (see lib/__arch__/arm64/syscalls.w's comment
on the same difference), so ref_list on arm64 would misparse entries;
Windows directory listing is not implemented at all here (ref_list
returns -38 ENOSYS on os_windows(), rather than silently misbehaving).
Fixing this needs the same kind of per-arch directory iterator
tools/wexec.w's wexec_collect_dir already special-cases for Windows --
future work, not needed for this wave's x64 target.

HEAD (a symbolic ref pointing at a ref name, e.g. "ref: refs/heads/main")
is NOT implemented in this wave: it is a small format on its own, but
real "current branch" semantics (detecting detached HEAD, updating HEAD
on checkout, etc.) belongs with tools/wvc.w's porcelain (V2c), not this
storage-layer module. Documented here as future work rather than built
speculatively.

Nothing here enters the seed import graph (docs/projects/version_control.md).
*/
import lib.lib
import lib.path
import lib.result
import lib.time
import lib.container
import structures.string
import libs.extras.vcs.cas
import libs.extras.vcs.__arch__.fsops


/* Errors, constants */


# Error code for a stored object that doesn't parse as this module's
# format: -74, Linux EBADMSG, matching cas.w's CAS_ERR_CORRUPT for the
# same class of failure one layer up (see the header comment).
int COMMIT_ERR_MALFORMED():
	return -74


# The cas.w object type tag commits are stored under.
char* COMMIT_OBJECT_TYPE():
	return c"commit"


# Lazily-built, reused-forever 64 '0' character id: the reflog's "this
# ref did not exist before" sentinel (see the header comment). Never
# free() the returned pointer.
char* commit_zero_id_cache
char* REF_ZERO_ID():
	if (commit_zero_id_cache == 0):
		char* z = malloc(65)
		int i = 0
		while (i < 64):
			z[i] = '0'
			i = i + 1
		z[64] = 0
		commit_zero_id_cache = z
	return commit_zero_id_cache


# Returns a malloc'd clone of text with every embedded '\n' replaced by a
# space, so the result is always safe to store as one header/reflog line
# (see the header comment: fields are sanitized at construction time
# rather than rejected, so the encoder can never produce a line an
# honest forward-scanning parser would misread).
char* commit_single_line(char* text):
	char* out = strclone(text)
	int i = 0
	while (out[i] != 0):
		if (out[i] == 10):
			out[i] = ' '
		i = i + 1
	return out


/* Commit objects: encode / parse */


# A parsed or freshly built commit. tree_id/parent_ids entries are
# 64-hex ids (cas.w's id form). message is an exact byte range
# (NUL-terminated for convenience, message_length is authoritative --
# the same convention wcas_object uses in cas.w).
struct commit_object:
	char* tree_id
	list[char*] parent_ids
	char* author
	int timestamp
	char* message
	int message_length


# Renders `co` as the format documented above. The blank line after
# 'timestamp' always separates header from message, even for an empty
# message.
string_builder* commit_encode(commit_object* co):
	string_builder* s = string_new()
	string_append(s, c"tree ")
	string_append(s, co.tree_id)
	string_append_char(s, 10)
	for char* parent_id in co.parent_ids:
		string_append(s, c"parent ")
		string_append(s, parent_id)
		string_append_char(s, 10)
	string_append(s, c"author ")
	string_append(s, co.author)
	string_append_char(s, 10)
	string_append(s, c"timestamp ")
	string_append_int(s, co.timestamp)
	string_append_char(s, 10)
	string_append_char(s, 10)
	string_append_bytes(s, co.message, co.message_length)
	return s


# True when data[offset .. offset+strlen(prefix)) equals prefix, without
# reading past `length` (a header keyword straddling EOF is rejected
# rather than read out of bounds).
int commit_starts_with(char* data, int length, int offset, char* prefix):
	int n = strlen(prefix)
	if ((offset + n) > length):
		return 0
	int i = 0
	while (i < n):
		if (data[offset + i] != prefix[i]):
			return 0
		i = i + 1
	return 1


# Index of the first `ch` byte at or after `start`, within [0, end); or
# `end` itself when `ch` does not occur (the caller's "not found, and
# nothing past `end` was read" signal).
int commit_find_char(char* data, int end, int start, int ch):
	int i = start
	while ((i < end) && (data[i] != ch)):
		i = i + 1
	return i


int commit_find_newline(char* data, int length, int start):
	return commit_find_char(data, length, start, 10)


# True when data[start,end) is one or more decimal digits, optionally
# preceded by '-' (a timestamp).
int commit_valid_integer(char* data, int start, int end):
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


# True when data[start,end) is a valid cas.w object id (cas_valid_id),
# without requiring the slice to already be its own NUL-terminated
# string.
int commit_valid_hex_slice(char* data, int start, int end):
	if ((end - start) != 64):
		return 0
	char* slice = path_clone_range(data + start, end - start)
	int ok = cas_valid_id(slice)
	free(slice)
	return ok


# The result of a single forward pass over a candidate commit object's
# bytes: byte offsets of every field once `valid` is 1, and nothing else
# meaningful when it is 0 (commit_scan returns as soon as it finds a
# grammar violation, so later fields are left at their zero value).
struct commit_layout:
	int valid
	int tree_start
	int tree_end
	list[int] parent_starts
	list[int] parent_ends
	int author_start
	int author_end
	int timestamp_start
	int timestamp_end
	int message_start


# Validates and locates every field of the format documented above in
# one forward pass with no backtracking. Splitting validation
# (commit_scan) from extraction (commit_parse) this way means
# commit_parse never allocates anything until the whole object is
# already known to be well-formed, so there is no partial-allocation
# state to clean up on an error path.
commit_layout* commit_scan(char* data, int length):
	commit_layout* lay = new commit_layout
	lay.valid = 0
	lay.parent_starts = new list[int]
	lay.parent_ends = new list[int]

	int pos = 0
	if (commit_starts_with(data, length, pos, c"tree ") == 0):
		return lay
	pos = pos + strlen(c"tree ")
	int tree_end = commit_find_newline(data, length, pos)
	if (tree_end >= length):
		return lay
	if (commit_valid_hex_slice(data, pos, tree_end) == 0):
		return lay
	lay.tree_start = pos
	lay.tree_end = tree_end
	pos = tree_end + 1

	while (commit_starts_with(data, length, pos, c"parent ")):
		int pstart = pos + strlen(c"parent ")
		int pend = commit_find_newline(data, length, pstart)
		if (pend >= length):
			return lay
		if (commit_valid_hex_slice(data, pstart, pend) == 0):
			return lay
		lay.parent_starts.push(pstart)
		lay.parent_ends.push(pend)
		pos = pend + 1

	if (commit_starts_with(data, length, pos, c"author ") == 0):
		return lay
	int astart = pos + strlen(c"author ")
	int aend = commit_find_newline(data, length, astart)
	if (aend >= length):
		return lay
	lay.author_start = astart
	lay.author_end = aend
	pos = aend + 1

	if (commit_starts_with(data, length, pos, c"timestamp ") == 0):
		return lay
	int tstart = pos + strlen(c"timestamp ")
	int tend = commit_find_newline(data, length, tstart)
	if (tend >= length):
		return lay
	if (commit_valid_integer(data, tstart, tend) == 0):
		return lay
	lay.timestamp_start = tstart
	lay.timestamp_end = tend
	pos = tend + 1

	if ((pos >= length) || (data[pos] != 10)):
		return lay
	pos = pos + 1

	lay.message_start = pos
	lay.valid = 1
	return lay


# Parses `length` bytes of a commit object's payload (as returned by
# cas_get). See the header comment for the exact grammar and error
# convention.
wresult[commit_object*]* commit_parse(char* data, int length):
	commit_layout* lay = commit_scan(data, length)
	if (lay.valid == 0):
		list_free[int](lay.parent_starts)
		list_free[int](lay.parent_ends)
		free(lay)
		return result_new_error[commit_object*](COMMIT_ERR_MALFORMED())

	commit_object* co = new commit_object
	co.tree_id = path_clone_range(data + lay.tree_start, lay.tree_end - lay.tree_start)
	co.parent_ids = new list[char*]
	int i = 0
	while (i < lay.parent_starts.length):
		int ps = lay.parent_starts[i]
		int pe = lay.parent_ends[i]
		co.parent_ids.push(path_clone_range(data + ps, pe - ps))
		i = i + 1
	co.author = path_clone_range(data + lay.author_start, lay.author_end - lay.author_start)
	char* ts_str = path_clone_range(data + lay.timestamp_start, lay.timestamp_end - lay.timestamp_start)
	co.timestamp = atoi(ts_str)
	free(ts_str)
	co.message_length = length - lay.message_start
	co.message = malloc(co.message_length + 1)
	int j = 0
	while (j < co.message_length):
		co.message[j] = data[lay.message_start + j]
		j = j + 1
	co.message[co.message_length] = 0

	list_free[int](lay.parent_starts)
	list_free[int](lay.parent_ends)
	free(lay)
	return result_new_ok[commit_object*](co)


# Builds a new commit_object, validating tree_id and every parent id
# (-22 EINVAL on the first invalid one) so anything constructed here
# always round-trips through commit_encode -> commit_parse. author has
# embedded '\n' bytes replaced with spaces (commit_single_line); message
# is copied verbatim for message_length bytes (may embed '\n', and --
# should a caller ever need it -- NUL).
wresult[commit_object*]* commit_new(char* tree_id, list[char*] parent_ids, char* author, int timestamp, char* message, int message_length):
	if (cas_valid_id(tree_id) == 0):
		return result_new_error[commit_object*](-22)
	for char* parent_id in parent_ids:
		if (cas_valid_id(parent_id) == 0):
			return result_new_error[commit_object*](-22)
	if (message_length < 0):
		return result_new_error[commit_object*](-22)
	if ((message == 0) && (message_length != 0)):
		return result_new_error[commit_object*](-22)

	commit_object* co = new commit_object
	co.tree_id = strclone(tree_id)
	co.parent_ids = new list[char*]
	for char* pid in parent_ids:
		co.parent_ids.push(strclone(pid))
	char* raw_author = author
	if (raw_author == 0):
		raw_author = c""
	co.author = commit_single_line(raw_author)
	co.timestamp = timestamp
	co.message = malloc(message_length + 1)
	int i = 0
	while (i < message_length):
		co.message[i] = message[i]
		i = i + 1
	co.message[message_length] = 0
	co.message_length = message_length
	return result_new_ok[commit_object*](co)


void commit_free(commit_object* co):
	free(co.tree_id)
	for char* parent_id in co.parent_ids:
		free(parent_id)
	list_free[char*](co.parent_ids)
	free(co.author)
	free(co.message)
	free(co)


# Encodes and stores `co` in `store` under object type "commit".
# Returns the malloc'd 64-hex id (cas_put's usual content-addressed
# dedup applies unchanged).
wresult[char*]* commit_store(wcas* store, commit_object* co):
	string_builder* encoded = commit_encode(co)
	wresult[char*]* result = cas_put(store, COMMIT_OBJECT_TYPE(), encoded.data, encoded.length)
	string_free(encoded)
	return result


# Loads and parses the commit stored under `id`. Errors: whatever
# cas_get reports (-22 malformed id, the open errno for a missing
# object, CAS_ERR_CORRUPT for broken CAS framing) pass through
# unchanged; COMMIT_ERR_MALFORMED additionally covers an object whose
# CAS type tag is not "commit" or whose payload does not parse per
# commit_parse.
wresult[commit_object*]* commit_load(wcas* store, char* id):
	wresult[wcas_object*]* got = cas_get(store, id)
	if (result_is_error[wcas_object*](got)):
		int code = result_code[wcas_object*](got)
		result_free[wcas_object*](got)
		return result_new_error[commit_object*](code)
	wcas_object* obj = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	if (strcmp(obj.object_type, COMMIT_OBJECT_TYPE()) != 0):
		cas_object_free(obj)
		return result_new_error[commit_object*](COMMIT_ERR_MALFORMED())
	wresult[commit_object*]* parsed = commit_parse(obj.data, obj.length)
	cas_object_free(obj)
	return parsed


/* Refs as files */


# An open refs root: refs/heads/<name> holds ids, logs/<name> holds
# reflogs. Create with refs_open, release with refs_close.
struct wrefs:
	char* root
	char* heads_dir
	char* logs_dir


int ref_valid_name_char(int c):
	int is_digit = (c >= '0') && (c <= '9')
	int is_lower = (c >= 'a') && (c <= 'z')
	int is_upper = (c >= 'A') && (c <= 'Z')
	return is_digit || is_lower || is_upper || (c == '-') || (c == '_') || (c == '.')


# A safe, flat ref name: 1..255 [A-Za-z0-9._-] characters, no leading or
# trailing '.', and never the "tmp_" prefix ref_write_atomic reserves
# for its own temp files (see the header comment). Rejects nested names
# ("feature/x") for now -- '/' is not in the accepted charset.
int ref_valid_name(char* name):
	if (name == 0):
		return 0
	int len = strlen(name)
	if ((len < 1) || (len > 255)):
		return 0
	if ((name[0] == '.') || (name[len - 1] == '.')):
		return 0
	if (commit_starts_with(name, len, 0, c"tmp_")):
		return 0
	int i = 0
	while (i < len):
		if (ref_valid_name_char(name[i] & 255) == 0):
			return 0
		i = i + 1
	return 1


# Opens (creating if needed) refs/heads/ and logs/ under `root`; only
# these directories are created, mirroring cas_open's "root's parent
# must already exist" contract. Errors carry the failing mkdir's errno.
wresult[wrefs*]* refs_open(char* root):
	int err = mkdir(root, 493)
	if ((err < 0) && (err != -17)):
		return result_new_error[wrefs*](err)
	char* refs_dir = path_join(root, c"refs")
	err = mkdir(refs_dir, 493)
	if ((err < 0) && (err != -17)):
		free(refs_dir)
		return result_new_error[wrefs*](err)
	char* heads_dir = path_join(refs_dir, c"heads")
	free(refs_dir)
	err = mkdir(heads_dir, 493)
	if ((err < 0) && (err != -17)):
		free(heads_dir)
		return result_new_error[wrefs*](err)
	char* logs_dir = path_join(root, c"logs")
	err = mkdir(logs_dir, 493)
	if ((err < 0) && (err != -17)):
		free(heads_dir)
		free(logs_dir)
		return result_new_error[wrefs*](err)

	wrefs* r = new wrefs
	r.root = strclone(root)
	r.heads_dir = heads_dir
	r.logs_dir = logs_dir
	return result_new_ok[wrefs*](r)


void refs_close(wrefs* r):
	free(r.root)
	free(r.heads_dir)
	free(r.logs_dir)
	free(r)


char* ref_path(wrefs* r, char* name):
	return path_join(r.heads_dir, name)


char* reflog_path(wrefs* r, char* name):
	return path_join(r.logs_dir, name)


# Process-wide sequence for unique ref temp-file names -- the same
# pid+sequence+O_EXCL scheme cas.w's cas_store_bytes uses, kept as its
# own counter because this module writes into a different directory
# (refs/heads/, not objects/).
int commit_temp_sequence


# Writes `contents` (length bytes) to a fresh temp file inside
# r.heads_dir and renames it onto `final_path` -- reusing vcs_rename /
# vcs_unlink (libs.extras.vcs.__arch__.fsops) rather than re-deriving
# the arch-specific atomicity primitive cas.w already has. A single
# write() is enough here (unlike cas_store_bytes's loop): every caller
# passes a small, fixed-shape line (a ref file is exactly 65 bytes), far
# under any short-write boundary, and a short write is still detected
# and reported rather than assumed away. Returns 0 or a negative errno;
# the temp file is always cleaned up on failure.
int ref_write_atomic(wrefs* r, char* final_path, char* contents, int length):
	int fd = -17
	char* temp = 0
	int attempts = 0
	while ((fd == -17) && (attempts < 100)):
		string_builder* t = string_new()
		string_append(t, r.heads_dir)
		string_append(t, c"/tmp_")
		string_append_int(t, getpid())
		string_append_char(t, '_')
		string_append_int(t, commit_temp_sequence)
		commit_temp_sequence = commit_temp_sequence + 1
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

	int err = write(fd, contents, length)
	if (err >= 0):
		if (err != length):
			err = -5   # EIO: a regular file should never short-write
		else:
			err = 0
	int closed = close(fd)
	if ((err == 0) && (closed < 0)):
		err = closed
	if (err == 0):
		err = vcs_rename(temp, final_path)
	if (err < 0):
		vcs_unlink(temp)
	free(temp)
	return err


# Reads the current id a ref points at. Errors: -22 for a malformed
# name, the open errno for a ref that does not exist (-2 ENOENT, the
# "no such branch" case a caller checks for), COMMIT_ERR_MALFORMED when
# the file exists but is not exactly "<64-hex>\n".
wresult[char*]* ref_read(wrefs* r, char* name):
	if (ref_valid_name(name) == 0):
		return result_new_error[char*](-22)
	char* path = ref_path(r, name)
	string_builder* contents = cas_read_file(path)
	free(path)
	if (contents == 0):
		return result_new_error[char*](cas_read_errno)
	int ok = (contents.length == 65) && (contents.data[64] == 10)
	char* id = 0
	if (ok):
		id = path_clone_range(contents.data, 64)
		if (cas_valid_id(id) == 0):
			free(id)
			id = 0
			ok = 0
	string_free(contents)
	if (ok == 0):
		return result_new_error[char*](COMMIT_ERR_MALFORMED())
	return result_new_ok[char*](id)


int ref_exists(wrefs* r, char* name):
	if (ref_valid_name(name) == 0):
		return 0
	char* path = ref_path(r, name)
	int present = path_exists(path)
	free(path)
	return present


# Appends one line to logs/<name>: "<old_id> <new_id> <timestamp>
# <message>\n". `message` is passed through commit_single_line first, so
# a multi-line caller message still produces exactly one line. Returns 0
# or a negative errno.
int reflog_append(wrefs* r, char* name, char* old_id, char* new_id, char* message):
	char* path = reflog_path(r, name)
	char* raw_message = message
	if (raw_message == 0):
		raw_message = c""
	char* safe_message = commit_single_line(raw_message)

	string_builder* line = string_new()
	string_append(line, old_id)
	string_append_char(line, ' ')
	string_append(line, new_id)
	string_append_char(line, ' ')
	string_append_int(line, time_now())
	string_append_char(line, ' ')
	string_append(line, safe_message)
	string_append_char(line, 10)
	free(safe_message)

	# 1089 = O_WRONLY | O_CREAT | O_APPEND (lib/line_edit.w uses the same
	# numeric flags for its history file), 420 = rw-r--r--. A single
	# write() to an O_APPEND-opened regular file is atomic on Linux, so
	# concurrent appenders never interleave -- no temp+rename is needed
	# for an append-only log.
	int fd = open(path, 1089, 420)
	free(path)
	if (fd < 0):
		string_free(line)
		return fd
	int err = write(fd, line.data, line.length)
	if (err >= 0):
		if (err != line.length):
			err = -5
		else:
			err = 0
	int closed = close(fd)
	if ((err == 0) && (closed < 0)):
		err = closed
	string_free(line)
	return err


# Shared body of ref_create/ref_update: writes the ref file atomically,
# then appends the reflog line. If the write succeeds but the append
# fails, the error is reported but the ref write is NOT rolled back (see
# the header comment).
wresult[int]* ref_write_and_log(wrefs* r, char* name, char* old_id, char* new_id, char* message):
	char* path = ref_path(r, name)
	string_builder* body = string_new()
	string_append(body, new_id)
	string_append_char(body, 10)
	int err = ref_write_atomic(r, path, body.data, body.length)
	string_free(body)
	free(path)
	if (err < 0):
		return result_new_error[int](err)
	int log_err = reflog_append(r, name, old_id, new_id, message)
	if (log_err < 0):
		return result_new_error[int](log_err)
	return result_new_ok[int](0)


# Creates a brand-new ref pointing at `id`. Fails with -17 (EEXIST) if
# `name` already exists -- use ref_update to move an existing ref. Logs
# REF_ZERO_ID() as the reflog's old id.
wresult[int]* ref_create(wrefs* r, char* name, char* id, char* message):
	if ((ref_valid_name(name) == 0) || (cas_valid_id(id) == 0)):
		return result_new_error[int](-22)
	if (ref_exists(r, name)):
		return result_new_error[int](-17)
	return ref_write_and_log(r, name, REF_ZERO_ID(), id, message)


# Moves an existing ref to `id`. Fails with -2 (ENOENT) if `name` does
# not exist -- use ref_create for a brand-new ref. Logs the ref's
# current id as the reflog's old id.
wresult[int]* ref_update(wrefs* r, char* name, char* id, char* message):
	if ((ref_valid_name(name) == 0) || (cas_valid_id(id) == 0)):
		return result_new_error[int](-22)
	wresult[char*]* current = ref_read(r, name)
	if (result_is_error[char*](current)):
		int code = result_code[char*](current)
		result_free[char*](current)
		return result_new_error[int](code)
	char* old_id = result_value[char*](current)
	result_free[char*](current)
	wresult[int]* out = ref_write_and_log(r, name, old_id, id, message)
	free(old_id)
	return out


# Reads a little-endian 16-bit field out of a getdents record (the
# d_reclen field -- see ref_list).
int commit_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Insertion sort: getdents order depends on filesystem state, and
# ref_list's result must not (tools/wexec.w's wexec_sort_strings does
# the same, for the same reason).
void commit_sort_strings(list[char*] items):
	int i = 1
	while (i < items.length):
		char* value = items[i]
		int j = i - 1
		while ((j >= 0) && (strcmp(items[j], value) > 0)):
			items[j + 1] = items[j]
			j = j - 1
		items[j + 1] = value
		i = i + 1


# All ref names currently under refs/heads/, sorted. Uses the legacy
# getdents(2) record layout (see the header comment): correct on x86/x64
# (this module's tested targets), not yet correct on arm64, and not
# implemented at all on Windows (-38 ENOSYS from os_windows()).
wresult[list[char*]]* ref_list(wrefs* r):
	if (os_windows()):
		return result_new_error[list[char*]](-38)
	# 65536 = O_DIRECTORY
	int fd = open(r.heads_dir, 65536, 0)
	if (fd < 0):
		return result_new_error[list[char*]](fd)
	list[char*] names = new list[char*]
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = commit_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			int kind = entry[reclen - 1] & 255
			int is_dot = strcmp(entry_name, c".") == 0
			int is_dotdot = strcmp(entry_name, c"..") == 0
			if ((is_dot == 0) && (is_dotdot == 0)):
				if ((kind == 8) && ref_valid_name(entry_name)):
					names.push(strclone(entry_name))
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	commit_sort_strings(names)
	return result_new_ok[list[char*]](names)


/* Reflog */


# One parsed reflog line.
struct reflog_entry:
	char* old_id
	char* new_id
	int timestamp
	char* message


void reflog_entry_free(reflog_entry* e):
	free(e.old_id)
	free(e.new_id)
	free(e.message)
	free(e)


# Parses one reflog line (data[start,end), no trailing '\n'):
# "<old_id> <new_id> <timestamp> <message>". Returns 0 for anything that
# does not match (message may be empty, but the three leading fields and
# their separating spaces are mandatory).
reflog_entry* reflog_parse_line(char* data, int start, int end):
	int p1 = commit_find_char(data, end, start, ' ')
	if (p1 >= end):
		return 0
	if (commit_valid_hex_slice(data, start, p1) == 0):
		return 0
	int p2 = commit_find_char(data, end, p1 + 1, ' ')
	if (p2 >= end):
		return 0
	if (commit_valid_hex_slice(data, p1 + 1, p2) == 0):
		return 0
	int p3 = commit_find_char(data, end, p2 + 1, ' ')
	if (p3 >= end):
		return 0
	if (commit_valid_integer(data, p2 + 1, p3) == 0):
		return 0

	reflog_entry* e = new reflog_entry
	e.old_id = path_clone_range(data + start, p1 - start)
	e.new_id = path_clone_range(data + (p1 + 1), p2 - (p1 + 1))
	char* ts_str = path_clone_range(data + (p2 + 1), p3 - (p2 + 1))
	e.timestamp = atoi(ts_str)
	free(ts_str)
	e.message = path_clone_range(data + (p3 + 1), end - (p3 + 1))
	return e


# All reflog entries for `name`, oldest first (append order == file
# order, so no sorting is needed -- unlike ref_list, which reads a
# directory with no inherent order). A ref with no reflog file yet (it
# was never created/updated) returns an empty list, not an error: an
# empty history is a valid state, exactly like git's reflog for a ref
# with none yet.
wresult[list[reflog_entry*]]* reflog_read(wrefs* r, char* name):
	if (ref_valid_name(name) == 0):
		return result_new_error[list[reflog_entry*]](-22)
	char* path = reflog_path(r, name)
	string_builder* contents = cas_read_file(path)
	free(path)
	if (contents == 0):
		if (cas_read_errno == -2):
			return result_new_ok[list[reflog_entry*]](new list[reflog_entry*])
		return result_new_error[list[reflog_entry*]](cas_read_errno)

	list[reflog_entry*] entries = new list[reflog_entry*]
	int pos = 0
	int length = contents.length
	int ok = 1
	while ((pos < length) && ok):
		int line_end = commit_find_newline(contents.data, length, pos)
		if (line_end >= length):
			ok = 0
		else:
			reflog_entry* e = reflog_parse_line(contents.data, pos, line_end)
			if (e == 0):
				ok = 0
			else:
				entries.push(e)
				pos = line_end + 1
	string_free(contents)

	if (ok == 0):
		for reflog_entry* stale in entries:
			reflog_entry_free(stale)
		list_free[reflog_entry*](entries)
		return result_new_error[list[reflog_entry*]](COMMIT_ERR_MALFORMED())
	return result_new_ok[list[reflog_entry*]](entries)
