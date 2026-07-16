/*
wvc: a porcelain CLI over the VCS wave 1+2 libraries (issue #252 V2c;
design: docs/projects/version_control.md "Wave 2 -- snapshots and
history", docs/projects/consolidated_plan_2026_07.md section 4). Thin
wiring only -- every real operation is libs/extras/vcs/{cas,tree,commit,
diff}.w; this file adds argument parsing, the on-disk repo layout
convention, and human-readable output.

Repo layout
-----------
A working directory is "wvc"-tracked by a metadata directory right
inside it:

	<dir>/.wvc/objects/       cas.w's content-addressed store
	<dir>/.wvc/refs/heads/    commit.w's refs (this wave: just "main")
	<dir>/.wvc/logs/          commit.w's append-only reflog

cas_open and refs_open are both called with <dir>/.wvc as their root --
they create disjoint subdirectories under it, so one root serves both
(commit.w's own header comment documents commits as "just another CAS
object", stored in the same store as trees/blobs).

Subcommands
-----------
	wvc init [dir]                    default dir: "."
	wvc snapshot <dir> -m <message> [-a <author>]
	wvc log [ref]                     default ref: "main"
	wvc diff <rev-a> <rev-b>
	wvc status <dir>

`log` and `diff` take no <dir>: unlike `init`/`snapshot`/`status`, which
name the working directory explicitly, they operate on "<cwd>/.wvc" --
this wave does not implement git's walk-up repo discovery, so run them
from the tracked directory. A rev is either a 64-hex commit id or a ref
name (currently only "main" can exist).

Exit status: 0 success, 1 an operation failed (I/O or a malformed VCS
object -- wvc_fail prints "<errno>: <ECODE>: <description>" via
lib.lib's translate_syscall_failure and exits), 2 a usage error.

Scope decisions for this wave
------------------------------
- dag.w is deliberately NOT used. Its generation-number/topological/
  merge-base machinery earns its keep once history branches -- but
  `snapshot` only ever creates a single-parent commit (there is no merge
  subcommand yet), so the commit graph this tool can produce is always a
  single chain. Walking parent_ids[0] from a ref's head IS a topological,
  oldest-parent-last iteration already; reaching for dag.w here would
  only add a hex<->32-byte-raw id conversion for the same result. Revisit
  when Wave 4's merge lands and merge-base becomes meaningful.
- `diff` renders full unified line diffs (reusing diff.w's Myers
  algorithm and unified renderer) ONLY for TREE_MODIFIED paths, where
  both sides' blob ids are cheap to resolve by walking the two trees to
  the same path. Added/removed paths print as a plain "A path"/"D path"
  line with no content dump -- version_control.md's V2c bullet calls
  this an acceptable MVP, and it keeps wvc.w from re-deriving a
  path-into-tree walk for the one-sided case too (tree_diff already
  expands one-sided subtrees itself; duplicating that here for a content
  dump did not seem worth it this wave). wvc_lookup_blob's failures are
  soft (the path-level line still prints; only the content hunk is
  skipped) so one bad lookup cannot blank out the rest of the report.
- `status` and `snapshot` both go through libs/extras/vcs/index.w's
  stat-cached dirstate now (wave 3, issue #252): a `.wvc/index` file
  records, per tracked path, the (size, mtime) last observed and the
  blob id that content hashed to, so a file whose stat is unchanged
  (and not "racy" -- see index.w's header comment) is never re-read,
  making both commands O(changed) rather than O(tree). `snapshot`
  refreshes the index unconditionally (it always writes a fresh commit,
  so it always has a fresh tree to cache); `status` uses the index when
  `.wvc/index` reads back cleanly, and otherwise falls back to exactly
  the wave-2 slow path -- a full tree_snapshot of the working tree,
  full-tree-diffed against the current commit -- so a repo with no
  index yet (or one whose index file is missing/corrupt) still works
  unchanged. Both paths still write fresh CAS objects as a side effect
  of hashing (tree_snapshot's/index_walk's design, not a bug here);
  content addressing makes repeat writes cheap (identical bytes dedup
  for free) regardless of which path ran.
*/
import lib.lib
import lib.path
import lib.result
import lib.stream
import lib.time
import structures.string
import libs.extras.vcs.cas
import libs.extras.vcs.tree
import libs.extras.vcs.commit
import libs.extras.vcs.diff
import libs.extras.vcs.index


char* WVC_META_DIR_NAME():
	return c".wvc"


char* WVC_DEFAULT_REF():
	return c"main"


char* WVC_DEFAULT_AUTHOR():
	return c"wvc"


char* wvc_meta_dir(char* dir):
	return path_join(dir, WVC_META_DIR_NAME())


# "<meta>/index" -- libs/extras/vcs/index.w's persisted dirstate
# (INDEX_FILE_NAME()).
char* wvc_index_path(char* meta):
	return path_join(meta, INDEX_FILE_NAME())


# Exact-name-at-every-depth ignore list tree_snapshot expects: our own
# metadata directory, and build output (the same "bin" example
# tree.w's own header comment uses).
list[char*] wvc_ignore_list():
	list[char*] ignore = new list[char*]
	ignore.push(WVC_META_DIR_NAME())
	ignore.push(c"bin")
	return ignore


void wvc_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wvc init [dir]")
	stream_write_line(err, c"       wvc snapshot <dir> -m <message> [-a <author>]")
	stream_write_line(err, c"       wvc log [ref]")
	stream_write_line(err, c"       wvc diff <rev-a> <rev-b>")
	stream_write_line(err, c"       wvc status <dir>")
	stream_flush(err)


# A porcelain command has no local recovery for an I/O or malformed-
# object error (docs/error_results.txt: "Use ... translate_syscall_
# failure when continuing would be a bug or when the program has no
# useful local recovery path"): print a short context line, then the
# errno description, and exit(1) -- never returns.
void wvc_fail(char* context, int code):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wvc: ")
	stream_write_line(err, context)
	stream_flush(err)
	translate_syscall_failure(code)


# Unwraps an ok wresult[T]* or dies via wvc_fail; the common case for
# every VCS library call this CLI treats as fatal. (Generic function
# calls are resolved after the whole file is seen -- tests/generics_test.w
# -- so ordering wvc_fail before this in the file, though not required
# for the generic call itself, keeps every OTHER (non-generic) call in
# this file in the single-pass define-before-use order the rest of the
# codebase relies on.)
T wvc_unwrap[T](wresult[T]* r, char* context):
	if (result_is_error[T](r)):
		int code = result_code[T](r)
		result_free[T](r)
		wvc_fail(context, code)
	T value = result_value[T](r)
	result_free[T](r)
	return value


wcas* wvc_open_store(char* meta):
	return wvc_unwrap[wcas*](cas_open(meta), c"cannot open object store (did you run 'wvc init'?)")


wrefs* wvc_open_refs(char* meta):
	return wvc_unwrap[wrefs*](refs_open(meta), c"cannot open refs (did you run 'wvc init'?)")


int wvc_status_char(int status):
	if (status == TREE_ADDED()):
		return 'A'
	if (status == TREE_REMOVED()):
		return 'D'
	return 'M'


# Splits a tree_diff path ("a/b/c.txt", tree.w's '/'-joined form) into
# its components. No leading/trailing separators occur in practice (see
# tree_diff's header comment: prefixes are built by path_join from "",
# which never adds a leading slash), but empty segments are skipped
# defensively rather than trusted.
list[char*] wvc_split_path(char* path):
	list[char*] parts = new list[char*]
	int n = strlen(path)
	int start = 0
	int i = 0
	while (i <= n):
		int at_sep = (i == n) || (path[i] == '/')
		if (at_sep):
			if (i > start):
				parts.push(path_clone_range(path + start, i - start))
			start = i + 1
		i = i + 1
	return parts


# Walks from a root tree id down to `path`'s blob id. Returns -2 (ENOENT)
# when any component is missing along the way, -22 for an empty path;
# otherwise tree_get's own errors. Callers that only want a nice-to-have
# (wvc_diff_modified) treat any error here as "skip the content diff",
# not fatal.
wresult[char*]* wvc_lookup_blob(wcas* store, char* root_id, char* path):
	list[char*] parts = wvc_split_path(path)
	char* current_id = strclone(root_id)
	int err = 0
	if (parts.length == 0):
		err = -22
	int i = 0
	while ((i < parts.length) && (err == 0)):
		wresult[wtree*]* t_r = tree_get(store, current_id)
		if (result_is_error[wtree*](t_r)):
			err = result_code[wtree*](t_r)
			result_free[wtree*](t_r)
		else:
			wtree* t = result_value[wtree*](t_r)
			result_free[wtree*](t_r)
			char* want = parts[i]
			tree_entry* found = 0
			for tree_entry* e in t.entries:
				if (strcmp(e.name, want) == 0):
					found = e
			if (found == 0):
				err = -2
			else:
				free(current_id)
				current_id = strclone(found.id)
			tree_free(t)
		i = i + 1
	for char* p in parts:
		free(p)
	list_free[char*](parts)
	if (err != 0):
		free(current_id)
		return result_new_error[char*](err)
	return result_new_ok[char*](current_id)


# A rev is either a 64-hex commit id already, or a ref name to resolve.
char* wvc_resolve_rev(wcas* store, wrefs* refs, char* rev):
	if (cas_valid_id(rev)):
		return strclone(rev)
	if (ref_valid_name(rev)):
		return wvc_unwrap[char*](ref_read(refs, rev), c"cannot resolve rev")
	wvc_fail(c"rev is neither a commit id nor a valid ref name", -22)
	return 0


# Nice-to-have content diff for one TREE_MODIFIED path (see the header
# comment): resolves both sides' blob ids by walking the two trees, and
# renders a unified diff if the content actually differs. Any failure
# along the way (path not found the way tree_diff itself found it -- it
# can't happen without the object store changing under us, but this
# reuses cas_get's own error surface rather than asserting) just skips
# the content hunk; the path-level "M <path>" line the caller already
# printed still stands.
void wvc_diff_modified(wcas* store, char* tree_a, char* tree_b, char* path, wstream* out):
	wresult[char*]* old_id_r = wvc_lookup_blob(store, tree_a, path)
	wresult[char*]* new_id_r = wvc_lookup_blob(store, tree_b, path)
	# Extract each side independently (not gated on the OTHER side also
	# being ok): if only one lookup fails, the other's owned payload
	# still needs freeing below rather than leaking.
	char* old_blob_id = 0
	char* new_blob_id = 0
	if (result_is_ok[char*](old_id_r)):
		old_blob_id = result_value[char*](old_id_r)
	if (result_is_ok[char*](new_id_r)):
		new_blob_id = result_value[char*](new_id_r)
	result_free[char*](old_id_r)
	result_free[char*](new_id_r)
	if ((old_blob_id == 0) || (new_blob_id == 0)):
		if (old_blob_id != 0):
			free(old_blob_id)
		if (new_blob_id != 0):
			free(new_blob_id)
		return

	wresult[wcas_object*]* old_obj_r = cas_get(store, old_blob_id)
	wresult[wcas_object*]* new_obj_r = cas_get(store, new_blob_id)
	wcas_object* old_obj = 0
	wcas_object* new_obj = 0
	if (result_is_ok[wcas_object*](old_obj_r)):
		old_obj = result_value[wcas_object*](old_obj_r)
	if (result_is_ok[wcas_object*](new_obj_r)):
		new_obj = result_value[wcas_object*](new_obj_r)
	result_free[wcas_object*](old_obj_r)
	result_free[wcas_object*](new_obj_r)
	free(old_blob_id)
	free(new_blob_id)
	if ((old_obj != 0) && (new_obj != 0)):
		diff_result* d = diff_text(old_obj.data, new_obj.data, diff_default_context())
		if (diff_is_identical(d) == 0):
			string_builder* a_label = string_new()
			string_append(a_label, c"a/")
			string_append(a_label, path)
			string_builder* b_label = string_new()
			string_append(b_label, c"b/")
			string_append(b_label, path)
			diff_render_unified(out, a_label.data, b_label.data, d)
			string_free(a_label)
			string_free(b_label)
	if (old_obj != 0):
		cas_object_free(old_obj)
	if (new_obj != 0):
		cas_object_free(new_obj)


/* Subcommands */


int wvc_cmd_init(int argc, int argv):
	char* dir = c"."
	if (argc >= 3):
		char** arg = argv + 2 * __word_size__
		dir = *arg

	# cas_open/refs_open both require their root's PARENT to already
	# exist (the same contract cas.w's header comment states); `dir`
	# itself is that parent for <dir>/.wvc, so create it first (like
	# git init making its target directory).
	int mkdir_err = mkdir(dir, 493)
	if ((mkdir_err < 0) && (mkdir_err != -17)):
		wvc_fail(c"cannot create directory", mkdir_err)

	char* meta = wvc_meta_dir(dir)
	wcas* store = wvc_open_store(meta)
	wrefs* refs = wvc_open_refs(meta)

	wstream* out = stdout_writer()
	stream_write_cstr(out, c"Initialized empty wvc repository in ")
	stream_write_cstr(out, meta)
	stream_write_line(out, c"/")
	stream_flush(out)

	cas_close(store)
	refs_close(refs)
	free(meta)
	return 0


int wvc_cmd_snapshot(int argc, int argv):
	char* dir = 0
	char* message = 0
	char* author = WVC_DEFAULT_AUTHOR()
	int i = 2
	while (i < argc):
		char** arg = argv + i * __word_size__
		char* a = *arg
		if (strcmp(a, c"-m") == 0):
			i = i + 1
			if (i >= argc):
				wvc_usage()
				return 2
			char** v = argv + i * __word_size__
			message = *v
		else if (strcmp(a, c"-a") == 0):
			i = i + 1
			if (i >= argc):
				wvc_usage()
				return 2
			char** v = argv + i * __word_size__
			author = *v
		else if (dir == 0):
			dir = a
		else:
			wvc_usage()
			return 2
		i = i + 1
	if ((dir == 0) || (message == 0)):
		wvc_usage()
		return 2

	char* meta = wvc_meta_dir(dir)
	wcas* store = wvc_open_store(meta)
	wrefs* refs = wvc_open_refs(meta)

	# Refresh the dirstate: reuse the previous index's cached blob ids
	# for anything whose stat still matches (index.w's racy-mtime guard
	# governs "still matches"), full-rehash anything else -- including
	# every file, the first time a repo has no index yet (prev = 0
	# degrades index_refresh to tree_snapshot's own behavior exactly,
	# see index.w's header comment).
	char* index_path = wvc_index_path(meta)
	wresult[windex*]* prev_index_r = index_read(index_path)
	windex* prev_index = 0
	if (result_is_ok[windex*](prev_index_r)):
		prev_index = result_value[windex*](prev_index_r)
	result_free[windex*](prev_index_r)

	list[char*] ignore = wvc_ignore_list()
	index_refresh_result* refreshed = wvc_unwrap[index_refresh_result*](index_refresh(store, dir, ignore, prev_index), c"snapshot failed")
	list_free[char*](ignore)
	if (prev_index != 0):
		index_free(prev_index)
	char* tree_id = refreshed.tree_id
	windex* new_index = refreshed.index
	free(refreshed)

	list[char*] parent_ids = new list[char*]
	int have_parent = ref_exists(refs, WVC_DEFAULT_REF())
	char* parent_id = 0
	if (have_parent):
		parent_id = wvc_unwrap[char*](ref_read(refs, WVC_DEFAULT_REF()), c"cannot read current ref")
		parent_ids.push(parent_id)

	commit_object* co = wvc_unwrap[commit_object*](commit_new(tree_id, parent_ids, author, time_now(), message, strlen(message)), c"invalid commit")
	char* commit_id = wvc_unwrap[char*](commit_store(store, co), c"cannot store commit")

	if (have_parent):
		wvc_unwrap[int](ref_update(refs, WVC_DEFAULT_REF(), commit_id, message), c"cannot update ref")
	else:
		wvc_unwrap[int](ref_create(refs, WVC_DEFAULT_REF(), commit_id, message), c"cannot create ref")

	# Persist the refreshed dirstate. Best-effort: the commit above is
	# already durable, so a write failure here (e.g. a full disk) must
	# not turn a successful snapshot into a failing command -- it only
	# costs the NEXT status/snapshot its fast path, and both already
	# fall back cleanly to a missing/corrupt index.
	wresult[int]* index_written = index_write(new_index, index_path)
	result_free[int](index_written)

	wstream* out = stdout_writer()
	stream_write_line(out, commit_id)
	stream_flush(out)

	commit_free(co)
	list_free[char*](parent_ids)
	if (have_parent):
		free(parent_id)
	free(tree_id)
	index_free(new_index)
	free(index_path)
	free(commit_id)
	free(meta)
	cas_close(store)
	refs_close(refs)
	return 0


int wvc_cmd_log(int argc, int argv):
	char* ref_name = WVC_DEFAULT_REF()
	if (argc >= 3):
		char** arg = argv + 2 * __word_size__
		ref_name = *arg

	char* meta = wvc_meta_dir(c".")
	wcas* store = wvc_open_store(meta)
	wrefs* refs = wvc_open_refs(meta)

	wresult[char*]* head_r = ref_read(refs, ref_name)
	if (result_is_error[char*](head_r)):
		int code = result_code[char*](head_r)
		result_free[char*](head_r)
		if (code == -2):
			wstream* err = stderr_writer()
			stream_write_cstr(err, c"wvc: ref '")
			stream_write_cstr(err, ref_name)
			stream_write_line(err, c"' has no commits yet")
			stream_flush(err)
			cas_close(store)
			refs_close(refs)
			free(meta)
			return 1
		wvc_fail(c"cannot read ref", code)
	char* current_id = result_value[char*](head_r)
	result_free[char*](head_r)

	# Collect the whole chain before printing anything, so a load
	# failure partway through never leaves a half-printed report on
	# stdout (wstream buffers are not flushed by exit()).
	list[commit_object*] history = new list[commit_object*]
	list[char*] history_ids = new list[char*]
	while (current_id != 0):
		commit_object* co = wvc_unwrap[commit_object*](commit_load(store, current_id), c"cannot load commit")
		history.push(co)
		history_ids.push(current_id)
		if (co.parent_ids.length > 0):
			current_id = strclone(co.parent_ids[0])
		else:
			current_id = 0

	wstream* out = stdout_writer()
	int i = 0
	while (i < history.length):
		commit_object* co = history[i]
		char* id = history_ids[i]
		if (i > 0):
			stream_write_line(out, c"")
		stream_write_cstr(out, c"commit ")
		stream_write_line(out, id)
		stream_write_cstr(out, c"Author: ")
		stream_write_line(out, co.author)
		char* date = time_format_unix_utc(co.timestamp)
		stream_write_cstr(out, c"Date:   ")
		stream_write_line(out, date)
		free(date)
		stream_write_line(out, c"")
		list[char*] lines = diff_split_lines(co.message)
		for char* l in lines:
			stream_write_cstr(out, c"    ")
			stream_write_line(out, l)
		for char* l in lines:
			free(l)
		list_free[char*](lines)
		i = i + 1
	stream_flush(out)

	for commit_object* co in history:
		commit_free(co)
	list_free[commit_object*](history)
	for char* id in history_ids:
		free(id)
	list_free[char*](history_ids)
	cas_close(store)
	refs_close(refs)
	free(meta)
	return 0


int wvc_cmd_diff(int argc, int argv):
	if (argc < 4):
		wvc_usage()
		return 2
	char** a_arg = argv + 2 * __word_size__
	char** b_arg = argv + 3 * __word_size__
	char* rev_a = *a_arg
	char* rev_b = *b_arg

	char* meta = wvc_meta_dir(c".")
	wcas* store = wvc_open_store(meta)
	wrefs* refs = wvc_open_refs(meta)

	char* commit_a = wvc_resolve_rev(store, refs, rev_a)
	char* commit_b = wvc_resolve_rev(store, refs, rev_b)
	commit_object* ca = wvc_unwrap[commit_object*](commit_load(store, commit_a), c"cannot load rev-a")
	commit_object* cb = wvc_unwrap[commit_object*](commit_load(store, commit_b), c"cannot load rev-b")

	list[tree_change*] changes = new list[tree_change*]
	wvc_unwrap[int](tree_diff(store, ca.tree_id, cb.tree_id, changes), c"diff failed")

	wstream* out = stdout_writer()
	for tree_change* c in changes:
		stream_write_byte(out, wvc_status_char(c.status))
		stream_write_byte(out, ' ')
		stream_write_line(out, c.path)
		if (c.status == TREE_MODIFIED()):
			wvc_diff_modified(store, ca.tree_id, cb.tree_id, c.path, out)
	stream_flush(out)

	tree_changes_free(changes)
	list_free[tree_change*](changes)
	commit_free(ca)
	commit_free(cb)
	free(commit_a)
	free(commit_b)
	free(meta)
	cas_close(store)
	refs_close(refs)
	return 0


int wvc_cmd_status(int argc, int argv):
	if (argc < 3):
		wvc_usage()
		return 2
	char** arg = argv + 2 * __word_size__
	char* dir = *arg

	char* meta = wvc_meta_dir(dir)
	wcas* store = wvc_open_store(meta)
	wrefs* refs = wvc_open_refs(meta)

	char* old_tree_id = 0
	if (ref_exists(refs, WVC_DEFAULT_REF())):
		char* head_id = wvc_unwrap[char*](ref_read(refs, WVC_DEFAULT_REF()), c"cannot read current ref")
		commit_object* co = wvc_unwrap[commit_object*](commit_load(store, head_id), c"cannot load current commit")
		old_tree_id = strclone(co.tree_id)
		commit_free(co)
		free(head_id)

	list[char*] ignore = wvc_ignore_list()
	char* index_path = wvc_index_path(meta)
	wresult[windex*]* prev_index_r = index_read(index_path)
	char* new_tree_id = 0
	windex* fresh_index = 0
	if (result_is_ok[windex*](prev_index_r)):
		# Fast path: a readable dirstate exists, so index_refresh only
		# re-hashes paths whose stat changed (or is racy) -- see
		# index.w's header comment.
		windex* prev_index = result_value[windex*](prev_index_r)
		result_free[windex*](prev_index_r)
		index_refresh_result* refreshed = wvc_unwrap[index_refresh_result*](index_refresh(store, dir, ignore, prev_index), c"status refresh failed")
		index_free(prev_index)
		new_tree_id = refreshed.tree_id
		fresh_index = refreshed.index
		free(refreshed)
	else:
		# Slow path: no usable index (absent, or unreadable/corrupt) --
		# exactly wave 2's original behavior, a full tree_snapshot that
		# rehashes every file. Nothing is written back here: an index
		# only ever gets created by `snapshot` (see index.w's header
		# comment on why status's own dirstate refresh below only fires
		# once a dirstate already exists to refresh).
		result_free[windex*](prev_index_r)
		new_tree_id = wvc_unwrap[char*](tree_snapshot(store, dir, ignore), c"status snapshot failed")
	list_free[char*](ignore)

	list[tree_change*] changes = new list[tree_change*]
	wvc_unwrap[int](tree_diff(store, old_tree_id, new_tree_id, changes), c"status diff failed")

	wstream* out = stdout_writer()
	if (changes.length == 0):
		stream_write_line(out, c"nothing to snapshot, working tree clean")
	else:
		for tree_change* c in changes:
			stream_write_byte(out, wvc_status_char(c.status))
			stream_write_byte(out, ' ')
			stream_write_line(out, c.path)
	stream_flush(out)

	# Keep the dirstate warm for the next status/snapshot call (git's own
	# `status` similarly rewrites the index after refreshing it).
	# Best-effort, same posture as snapshot's own index_write: a status
	# report that already succeeded must not turn into a failing command
	# over a stale-cache write.
	if (fresh_index != 0):
		wresult[int]* index_written = index_write(fresh_index, index_path)
		result_free[int](index_written)
		index_free(fresh_index)

	tree_changes_free(changes)
	list_free[tree_change*](changes)
	if (old_tree_id != 0):
		free(old_tree_id)
	free(new_tree_id)
	free(index_path)
	free(meta)
	cas_close(store)
	refs_close(refs)
	return 0


int main(int argc, int argv):
	if (argc < 2):
		wvc_usage()
		return 2
	char** cmd_arg = argv + __word_size__
	char* cmd = *cmd_arg
	if (strcmp(cmd, c"init") == 0):
		return wvc_cmd_init(argc, argv)
	if (strcmp(cmd, c"snapshot") == 0):
		return wvc_cmd_snapshot(argc, argv)
	if (strcmp(cmd, c"log") == 0):
		return wvc_cmd_log(argc, argv)
	if (strcmp(cmd, c"diff") == 0):
		return wvc_cmd_diff(argc, argv)
	if (strcmp(cmd, c"status") == 0):
		return wvc_cmd_status(argc, argv)
	wvc_usage()
	return 2
