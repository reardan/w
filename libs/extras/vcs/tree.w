/*
Merkle tree objects over the content-addressed store (VCS wave 2, V2a;
design: docs/projects/version_control.md, "Wave 2 -- snapshots and
history"). A tree object names a directory's immediate children; because
each child is referenced by the content id of ITS bytes (a "blob"
object) or ITS tree object, a root tree id commits to the entire
directory hierarchy, and two hierarchies are identical exactly when
their root ids are equal.

Serialization is line-oriented, one entry per line, entries sorted
ascending by byte-wise (unsigned) name comparison, each name unique:

	<mode> <id> <name>\n

	mode  one of 40000 (directory), 100644 (regular file),
	      100755 (executable file) -- git's octal spellings, kept for
	      familiarity; the store itself is type-agnostic
	id    64 lowercase hex (cas.w's id form) of the child: a "tree"
	      object for 40000, a "blob" object otherwise
	name  the entry's file name bytes, verbatim

Line-oriented rather than length-framed (git's "<mode> <name>\0<raw
id>") for the same reason package.wmeta is a text format: parseable
without a general parser, and a stored tree is directly readable with
`cas_get`. The two leading fields are fixed-form (no spaces, fixed-width
id), so putting the name LAST means names may contain spaces and the
parser never needs escaping. The cost is that a name cannot contain
'\n' -- along with NUL (impossible in Linux file names), '/', "", "."
and ".." (which any VCS must reject anyway), enforced by
tree_valid_name. A newline-in-file-name is legal to POSIX but this
module declines to track it; length-framing would buy exactly that
pathological case at the price of a format that cannot be read or
hand-authored.

Canonical form is enforced on BOTH directions: tree_serialize sorts and
rejects duplicates before hashing, and tree_get rejects payloads whose
entries are malformed or not in strictly ascending name order, so a
given set of entries has exactly one id and every stored tree is in
that one form. Sorting is plain byte-wise over the name bytes -- NOT
git's variant that sorts a directory as if its name ended in '/'; git
interop is a non-goal (version_control.md, design decisions), and the
plain order keeps the diff merge-walk a simple string compare.

Divergences from git, both deliberate:
  - Empty directories are representable and preserved: an empty
    directory serializes to the empty payload ("tree 0\0" once framed
    by cas.w) and its parent keeps a normal 40000 entry pointing at
    that id, so snapshot -> restore is faithful.
  - Symbolic links (and sockets, fifos, devices) have no mode:
    tree_snapshot skips anything that is not a regular file or a
    directory. Nothing in this repository needs symlinks tracked;
    adding a mode later is a forward-compatible format extension.

tree_snapshot walks a real directory (the getdents(2) pattern
tools/wbuildgen.w and tools/wexec.w use), storing file contents as
"blob" objects and each directory as a "tree" object, bottom-up, and
returns the root tree id. An ignore list (exact entry names such as
"bin" or ".git", matched at EVERY depth; 0 = ignore nothing) prunes
whole subtrees before they are read. The walker records every regular
file as 100644: the portable syscall surface (lib/__arch__) has no
stat/access wrapper yet, so the executable bit is not observable here.
100755 is fully supported by the format, the entry API and the diff --
wave 3's index.w, which needs stat for its mtime cache anyway, is where
the walker learns the bit.

tree_diff compares two root ids by parallel descent over the sorted
entry lists and descends ONLY into subtrees whose ids differ -- an
entry pair with equal ids is skipped without reading either child (the
Merkle property; the subtree's objects are never even loaded), so the
cost is O(changed) rather than O(tree). Results are (path,
TREE_ADDED/TREE_REMOVED/TREE_MODIFIED) in deterministic depth-first
sorted order:
  - An entry present on one side only is emitted with that side's
    status; a directory entry is emitted itself (so an added empty
    directory is visible) and then expanded recursively, every child
    emitted with the same status.
  - A name present on both sides as the same kind: directories with
    differing ids recurse (the directory itself is NOT emitted --
    only its changed children are); blobs differing in id or mode
    (content change or 100644<->100755 flip) emit TREE_MODIFIED.
  - A name whose kind changed (file <-> directory) emits the removal
    of the old entry then the addition of the new one, both expanded.

Error handling follows docs/error_results.txt: wresult[T]* carrying
negative errnos unchanged, -22 (EINVAL) for invalid entries (bad name,
mode, id, or duplicate names), and cas.w's CAS_ERR_CORRUPT for a stored
object that is not a canonical tree (wrong type tag, malformed line, or
entries out of order). Nothing here enters the seed import graph.
*/
import lib.lib
import lib.path
import lib.result
import lib.stream
import structures.string
import libs.extras.vcs.cas


/* Entry modes (serialized tokens in tree_mode_token) */


int TREE_MODE_DIR():
	return 1


int TREE_MODE_FILE():
	return 2


int TREE_MODE_EXEC():
	return 3


/* tree_diff statuses */


int TREE_ADDED():
	return 1


int TREE_REMOVED():
	return 2


int TREE_MODIFIED():
	return 3


# One (name, mode, id) child reference. Create with tree_entry_new
# (which validates and clones), release with tree_entry_free.
struct tree_entry:
	char* name    # owned; see tree_valid_name for the allowed forms
	int mode      # TREE_MODE_DIR/FILE/EXEC
	char* id      # owned 64-hex id of the child tree or blob


# An in-memory tree object: the children of one directory. The list is
# kept in whatever order entries were added; tree_serialize (and thus
# tree_put / tree_id_hex) sorts it into canonical order in place.
# tree_get always returns entries already in canonical order.
struct wtree:
	list[tree_entry*] entries


wtree* tree_new():
	wtree* t = new wtree
	t.entries = new list[tree_entry*]
	return t


void tree_entry_free(tree_entry* e):
	free(e.name)
	free(e.id)
	free(e)


void tree_free(wtree* t):
	for tree_entry* e in t.entries:
		tree_entry_free(e)
	t.entries.clear()
	free(t)


/* Names, modes, ordering */


# A name is storable when it is non-empty, is not "." or "..", and
# contains no '/' (a tree entry names exactly one path component), no
# '\n' (the line terminator -- see the header comment for why this is
# rejected rather than escaped), and no NUL (implicit: names are C
# strings).
int tree_valid_name(char* name):
	if (name == 0):
		return 0
	if (name[0] == 0):
		return 0
	if (strcmp(name, c".") == 0):
		return 0
	if (strcmp(name, c"..") == 0):
		return 0
	int i = 0
	while (name[i] != 0):
		if ((name[i] == '/') || (name[i] == 10)):
			return 0
		i = i + 1
	return 1


# The serialized mode token, or 0 for an unknown mode value.
char* tree_mode_token(int mode):
	if (mode == TREE_MODE_DIR()):
		return c"40000"
	if (mode == TREE_MODE_FILE()):
		return c"100644"
	if (mode == TREE_MODE_EXEC()):
		return c"100755"
	return 0


int tree_mode_is_dir(int mode):
	return mode == TREE_MODE_DIR()


# Byte-wise (unsigned) name order -- the canonical sort. strcmp compares
# W's signed chars, which would order bytes >= 0x80 before 'a'; names
# are raw bytes, so the comparison must be unsigned to be truly
# byte-wise.
int tree_name_compare(char* a, char* b):
	int i = 0
	int ca = a[0] & 255
	int cb = b[0] & 255
	while ((ca == cb) && (ca != 0)):
		i = i + 1
		ca = a[i] & 255
		cb = b[i] & 255
	return ca - cb


int tree_entry_compare(tree_entry* a, tree_entry* b):
	return tree_name_compare(a.name, b.name)


# Validates and clones (name, mode, id) into an owned entry. Returns 0
# when the name is not storable, the mode is unknown, or the id is not
# a 64-lowercase-hex cas id.
tree_entry* tree_entry_new(char* name, int mode, char* id):
	if (tree_valid_name(name) == 0):
		return 0
	if (tree_mode_token(mode) == 0):
		return 0
	if (cas_valid_id(id) == 0):
		return 0
	tree_entry* e = new tree_entry
	e.name = strclone(name)
	e.mode = mode
	e.id = strclone(id)
	return e


# Convenience: validate + clone + append. Returns 0 on success, -22 for
# an invalid name/mode/id (nothing is appended).
int tree_add(wtree* t, char* name, int mode, char* id):
	tree_entry* e = tree_entry_new(name, mode, id)
	if (e == 0):
		return -22
	t.entries.push(e)
	return 0


/* Serialization */


# Canonicalizes (sorts entries in place by tree_name_compare) and
# serializes to the documented line format, returned as a malloc'd
# string (the format contains no NUL bytes, so its strlen is the
# payload length). Returns 0 when any entry is invalid or two entries
# share a name -- the canonical form must be unique, so duplicates are
# an error rather than a silent overwrite.
char* tree_serialize(wtree* t):
	t.entries.sort_by(tree_entry_compare)
	string_builder* out = string_new()
	char* prev = 0
	for tree_entry* e in t.entries:
		char* token = tree_mode_token(e.mode)
		int valid = (token != 0) && tree_valid_name(e.name) && cas_valid_id(e.id)
		if (valid && (prev != 0)):
			# Strictly ascending: equality is a duplicate name.
			valid = tree_name_compare(prev, e.name) < 0
		if (valid == 0):
			string_free(out)
			return 0
		string_append(out, token)
		string_append_char(out, ' ')
		string_append(out, e.id)
		string_append_char(out, ' ')
		string_append(out, e.name)
		string_append_char(out, 10)
		prev = e.name
	char* payload = out.data
	free(out)
	return payload


# The id tree_put would store this tree under, without touching any
# store (pure, mirroring cas_id_hex). Returns 0 for a tree that does
# not serialize. The empty tree has a well-defined id: the hash of the
# empty "tree" payload.
char* tree_id_hex(wtree* t):
	char* payload = tree_serialize(t)
	if (payload == 0):
		return 0
	char* id = cas_id_hex(c"tree", payload, strlen(payload))
	free(payload)
	return id


# Canonicalizes, serializes and stores the tree as a "tree" object.
# Returns the malloc'd 64-hex id; -22 for a tree that does not
# serialize, otherwise cas_put's errors.
wresult[char*]* tree_put(wcas* s, wtree* t):
	char* payload = tree_serialize(t)
	if (payload == 0):
		return result_new_error[char*](-22)
	wresult[char*]* r = cas_put(s, c"tree", payload, strlen(payload))
	free(payload)
	return r


/* Parsing */


# Loads and parses a tree object. Errors: cas_get's (-22 malformed id,
# -2 missing object), and CAS_ERR_CORRUPT when the object is not a
# canonical tree -- wrong type tag, a line that does not parse as
# "<mode> <id> <name>", an invalid mode/id/name, or entries not in
# strictly ascending name order. The result owns its entries; release
# with tree_free.
wresult[wtree*]* tree_get(wcas* s, char* id):
	wcas_object* o = cas_get(s, id)?
	if (strcmp(o.object_type, c"tree") != 0):
		cas_object_free(o)
		return result_new_error[wtree*](CAS_ERR_CORRUPT())
	wtree* t = tree_new()
	char* bytes = o.data
	int total = o.length
	int i = 0
	int valid = 1
	char* prev = 0
	while (valid && (i < total)):
		# "<mode> ": scan to the separating space.
		int mode_start = i
		while ((i < total) && (bytes[i] != ' ') && (bytes[i] != 10) && (bytes[i] != 0)):
			i = i + 1
		valid = (i < total) && (bytes[i] == ' ')
		int mode = 0
		if (valid):
			char* token = path_clone_range(bytes + mode_start, i - mode_start)
			if (strcmp(token, c"40000") == 0):
				mode = TREE_MODE_DIR()
			else if (strcmp(token, c"100644") == 0):
				mode = TREE_MODE_FILE()
			else if (strcmp(token, c"100755") == 0):
				mode = TREE_MODE_EXEC()
			else:
				valid = 0
			free(token)
			i = i + 1
		# "<id> ": exactly 64 hex characters then a space.
		char* entry_id = 0
		if (valid):
			valid = (i + 65) <= total
		if (valid):
			valid = bytes[i + 64] == ' '
		if (valid):
			entry_id = path_clone_range(bytes + i, 64)
			valid = cas_valid_id(entry_id)
			i = i + 65
		# "<name>\n": everything up to the line terminator.
		if (valid):
			int name_start = i
			while ((i < total) && (bytes[i] != 10) && (bytes[i] != 0)):
				i = i + 1
			valid = (i < total) && (bytes[i] == 10)
			if (valid):
				char* name = path_clone_range(bytes + name_start, i - name_start)
				i = i + 1
				valid = tree_valid_name(name)
				if (valid && (prev != 0)):
					valid = tree_name_compare(prev, name) < 0
				if (valid):
					tree_entry* e = new tree_entry
					e.name = name
					e.mode = mode
					e.id = entry_id
					entry_id = 0
					t.entries.push(e)
					prev = name
				else:
					free(name)
		if (entry_id != 0):
			free(entry_id)
	cas_object_free(o)
	if (valid == 0):
		tree_free(t)
		return result_new_error[wtree*](CAS_ERR_CORRUPT())
	return result_new_ok[wtree*](t)


/* Directory snapshot */


# 1 when `name` appears verbatim in the ignore list (0 = empty list).
int tree_ignored(list[char*] ignore, char* name):
	if (ignore == 0):
		return 0
	for char* skip in ignore:
		if (strcmp(skip, name) == 0):
			return 1
	return 0


int tree_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Snapshots the directory at `path` into the store: file contents
# become "blob" objects, directories become "tree" objects (bottom-up),
# and the returned malloc'd id names the root tree. `ignore` prunes
# entries by exact name at every depth, before their contents are read
# (0 = ignore nothing). Entries that are neither regular files nor
# directories (symlinks etc.) are skipped -- see the header comment.
# Errors: the failing syscall's errno (e.g. -2 for a missing path,
# -20 for a non-directory), -22 for a file name the format cannot
# store, and cas_put's errors.
wresult[char*]* tree_snapshot(wcas* s, char* path, list[char*] ignore):
	# 65536 = O_DIRECTORY: fail up front when path is not a directory.
	int fd = open(path, 65536, 0)
	if (fd < 0):
		return result_new_error[char*](fd)
	wtree* t = tree_new()
	# getdents record layout, as in tools/wbuildgen.w: d_reclen 2 bytes
	# after the two word-sized ino/off fields, name after d_reclen,
	# d_type in the record's last byte (4 = directory, 8 = regular).
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int err = 0
	int n = getdents(fd, buffer, buffer_size)
	while ((err == 0) && (n > 0)):
		int off = 0
		while ((err == 0) && (off < n)):
			char* record = buffer + off
			int reclen = tree_load_uint16(record + 2 * __word_size__)
			char* entry_name = record + 2 * __word_size__ + 2
			int kind = record[reclen - 1] & 255
			off = off + reclen
			int skip = (strcmp(entry_name, c".") == 0) || (strcmp(entry_name, c"..") == 0)
			skip = skip || tree_ignored(ignore, entry_name)
			skip = skip || ((kind != 4) && (kind != 8))
			if (skip == 0):
				char* child_path = path_join(path, entry_name)
				char* child_id = 0
				if (kind == 4):
					wresult[char*]* sub = tree_snapshot(s, child_path, ignore)
					if (result_is_error[char*](sub)):
						err = result_code[char*](sub)
					else:
						child_id = result_value[char*](sub)
					result_free[char*](sub)
				else:
					string_builder* contents = cas_read_file(child_path)
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
					int mode = TREE_MODE_DIR()
					if (kind == 8):
						mode = TREE_MODE_FILE()
					err = tree_add(t, entry_name, mode, child_id)
				if (child_id != 0):
					free(child_id)
				free(child_path)
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


/* Tree diff */


# One tree_diff result: an owned '/'-joined path (relative to the
# compared roots) and its status. Release a result list's contents with
# tree_changes_free.
struct tree_change:
	char* path
	int status


void tree_changes_free(list[tree_change*] changes):
	for tree_change* c in changes:
		free(c.path)
		free(c)
	changes.clear()


void tree_change_push(list[tree_change*] out, char* path, int status):
	tree_change* c = new tree_change
	c.path = path
	c.status = status
	out.push(c)


# Folds a sub-walk's result into a running count: adds the ok value to
# *count and returns 0, or returns the error code. Frees the result
# either way.
int tree_diff_take(wresult[int]* r, int* count):
	if (result_is_error[int](r)):
		int code = result_code[int](r)
		result_free[int](r)
		return code
	count[0] = count[0] + result_value[int](r)
	result_free[int](r)
	return 0


# tree_diff_emit and tree_diff_expand are mutually recursive (a
# single-sided directory expands through its entries, each of which may
# itself be a directory).
wresult[int]* tree_diff_expand(wcas* s, char* id, char* prefix, int status, list[tree_change*] out);


# Emits (prefix/name, status) for one single-sided entry and, for a
# directory, every entry below it (all with the same status). Returns
# the number of changes appended.
wresult[int]* tree_diff_emit(wcas* s, tree_entry* e, char* prefix, int status, list[tree_change*] out):
	char* path = path_join(prefix, e.name)
	tree_change_push(out, path, status)
	int count = 1
	if (tree_mode_is_dir(e.mode)):
		# `path` stays valid for the recursion: the pushed change owns it
		# and the caller frees changes only after the walk finishes.
		wresult[int]* sub = tree_diff_expand(s, e.id, path, status, out)
		if (result_is_error[int](sub)):
			return sub
		count = count + result_value[int](sub)
		result_free[int](sub)
	return result_new_ok[int](count)


# Recursively emits every entry of the tree stored under `id`.
wresult[int]* tree_diff_expand(wcas* s, char* id, char* prefix, int status, list[tree_change*] out):
	wtree* t = tree_get(s, id)?
	int count = 0
	for tree_entry* e in t.entries:
		wresult[int]* emitted = tree_diff_emit(s, e, prefix, status, out)
		if (result_is_error[int](emitted)):
			tree_free(t)
			return emitted
		count = count + result_value[int](emitted)
		result_free[int](emitted)
	tree_free(t)
	return result_new_ok[int](count)


# The parallel descent over two tree ids already known to differ: a
# merge walk of the two canonically sorted entry lists. Equal-id
# same-kind entries are skipped WITHOUT loading either child object --
# only the two trees named by old_id/new_id themselves are read here.
wresult[int]* tree_diff_walk(wcas* s, char* old_id, char* new_id, char* prefix, list[tree_change*] out):
	wtree* old_tree = tree_get(s, old_id)?
	wresult[wtree*]* new_loaded = tree_get(s, new_id)
	if (result_is_error[wtree*](new_loaded)):
		tree_free(old_tree)
		int code = result_code[wtree*](new_loaded)
		result_free[wtree*](new_loaded)
		return result_new_error[int](code)
	wtree* new_tree = result_value[wtree*](new_loaded)
	result_free[wtree*](new_loaded)

	int count = 0
	int err = 0
	int i = 0
	int j = 0
	while ((err == 0) && ((i < old_tree.entries.length) || (j < new_tree.entries.length))):
		int cmp = 0
		if (i >= old_tree.entries.length):
			cmp = 1
		else if (j >= new_tree.entries.length):
			cmp = -1
		else:
			cmp = tree_name_compare(old_tree.entries[i].name, new_tree.entries[j].name)
		if (cmp < 0):
			# Only in old: removed.
			wresult[int]* r = tree_diff_emit(s, old_tree.entries[i], prefix, TREE_REMOVED(), out)
			err = tree_diff_take(r, &count)
			i = i + 1
		else if (cmp > 0):
			# Only in new: added.
			wresult[int]* a = tree_diff_emit(s, new_tree.entries[j], prefix, TREE_ADDED(), out)
			err = tree_diff_take(a, &count)
			j = j + 1
		else:
			tree_entry* oe = old_tree.entries[i]
			tree_entry* ne = new_tree.entries[j]
			if (tree_mode_is_dir(oe.mode) != tree_mode_is_dir(ne.mode)):
				# Kind change: the old entry goes away, the new appears.
				wresult[int]* gone = tree_diff_emit(s, oe, prefix, TREE_REMOVED(), out)
				err = tree_diff_take(gone, &count)
				if (err == 0):
					wresult[int]* born = tree_diff_emit(s, ne, prefix, TREE_ADDED(), out)
					err = tree_diff_take(born, &count)
			else if (tree_mode_is_dir(oe.mode)):
				# Both directories: equal ids are skipped unread (the
				# Merkle property); differing ids recurse.
				if (strcmp(oe.id, ne.id) != 0):
					char* child_prefix = path_join(prefix, oe.name)
					wresult[int]* sub = tree_diff_walk(s, oe.id, ne.id, child_prefix, out)
					err = tree_diff_take(sub, &count)
					free(child_prefix)
			else:
				# Both blobs: a content or mode change is one MODIFIED.
				if ((strcmp(oe.id, ne.id) != 0) || (oe.mode != ne.mode)):
					tree_change_push(out, path_join(prefix, oe.name), TREE_MODIFIED())
					count = count + 1
			i = i + 1
			j = j + 1
	tree_free(old_tree)
	tree_free(new_tree)
	if (err < 0):
		return result_new_error[int](err)
	return result_new_ok[int](count)


# Diffs two root tree ids, appending owned tree_change records to `out`
# (created by the caller; release contents with tree_changes_free --
# also after an error, which may leave a partial result in the list).
# Either id may be 0 meaning "no tree": everything in the other root is
# then added/removed -- the shape an initial or deleting snapshot needs.
# Equal ids (including both 0) return ok(0) without reading anything.
# The ok value is the number of changes appended; errors are tree_get's.
wresult[int]* tree_diff(wcas* s, char* old_id, char* new_id, list[tree_change*] out):
	if ((old_id == 0) && (new_id == 0)):
		return result_new_ok[int](0)
	if (old_id == 0):
		return tree_diff_expand(s, new_id, c"", TREE_ADDED(), out)
	if (new_id == 0):
		return tree_diff_expand(s, old_id, c"", TREE_REMOVED(), out)
	if (strcmp(old_id, new_id) == 0):
		return result_new_ok[int](0)
	return tree_diff_walk(s, old_id, new_id, c"", out)
