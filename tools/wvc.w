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
	wvc merge <rev> [-m <message>] [-a <author>]
	wvc serve --port N [--root dir]   default root: "."
	wvc pull <url> [ref]              default ref: "main"
	wvc push <url> [ref]              default ref: "main"

`log`, `diff`, `merge`, `pull` and `push` take no <dir>: unlike
`init`/`snapshot`/`status`/`serve`, which name the working directory
explicitly (`serve` via `--root`), they operate on "<cwd>/.wvc" (and,
for `merge`, cwd itself as the working tree it writes into) -- this
wave does not implement git's walk-up repo discovery, so run them from
the tracked directory. A rev is either a 64-hex commit id or a ref name
(currently only "main" can exist).

`serve`/`pull`/`push` (VCS wave 4, issue #252 "sync") are thin CLI
wiring over libs/extras/vcs/sync.w -- see that file's header comment
for the wire protocol, the have/want negotiation algorithm, and the
ancestry-cap/error-handling design decisions. `serve` runs the HTTP
object server forever (until killed) and prints "Listening on
<ip>:<port>" on its first stdout line once bound, so a test or script
launching it with `--port 0` can read the kernel-assigned port back.

Exit status: 0 success, 1 an operation failed (I/O or a malformed VCS
object -- wvc_fail prints "<errno>: <ECODE>: <description>" via
lib.lib's translate_syscall_failure and exits), 2 a usage error.

Scope decisions for this wave
------------------------------
- `log` still walks parent_ids[0] only (oldest-parent-last, single-chain
  iteration) rather than reaching for dag.w's topological order -- a
  merge commit's OTHER parents are real (`merge` below gives every
  commit graph produced here actual branching for the first time), but
  `log`'s first-parent walk is still a well-defined, useful "mainline
  history" view (the same one `git log --first-parent` gives), and nothing
  in this wave's scope asks for a full-DAG log. `merge` is the one
  command that builds a real libs/extras/vcs/dag.w graph (see below).
- `merge <rev>` (VCS wave 4, issue #252) does the merge-base lookup and
  per-file three-way merge docs/projects/version_control.md's "Wave 4 --
  merge and sync" section calls for:
    - Builds an in-memory dag.w graph over the FULL ancestry of HEAD and
      <rev> (wvc_dag_insert_ancestors, a recursive parents-first walk --
      recursion depth is the length of the deepest chain visited, an
      accepted tradeoff for an MVP porcelain over histories this repo's
      own test suite produces; revisit with an explicit stack if a real
      history ever makes that a problem). Commit ids (64-hex) are
      converted to dag.w's 32-byte raw id form with
      libs.standard.crypto.base64's hex_decode/hex_encode (the very
      conversion the old note above deferred "until Wave 4's merge
      lands" -- it has).
    - Merge-base selection is dag_merge_base(d, head_raw, other_raw)[0]:
      the lowest-insertion-sequence-number best common ancestor.
      Criss-cross histories can legitimately produce more than one best
      common ancestor (dag.w's own header comment); this wave picks the
      first deterministically rather than synthesizing a recursive
      virtual base (git's merge-recursive/merge-ort) -- out of scope,
      called out explicitly here per the wave plan rather than silently
      approximated.
    - Per changed path (union of tree_diff(base,HEAD) and
      tree_diff(base,<rev>), content-compared rather than trusted from
      tree_diff's ADDED/REMOVED/MODIFIED status alone, so a directory-
      level tree_diff entry or a mode-only difference cannot be
      mistaken for a content change): only one side differs from base ->
      take that side (an unchanged "ours" needs no write -- the working
      tree is assumed to already hold HEAD's content); both differ
      identically -> coalesce; both differ and one side has no content
      at all (a modify/delete conflict) -> keep whichever side still has
      content, report, and flag conflicted, since there is no third
      text to run a line merge against; both differ with real content on
      both sides -> libs/extras/vcs/merge3.w's three-way text merge,
      UNLESS either side (or base) is binary-ish (a NUL in the first
      8000 bytes -- git's own sniff heuristic), which conflicts wholesale
      with no attempt to interleave bytes with text markers.
    - No fast-forward shortcut: even when the merge-base equals HEAD (a
      pure fast-forward) or equals <rev> (already up to date, handled as
      a no-op instead), a clean merge always writes a real two-parent
      commit rather than just moving the ref -- simpler and uniform, at
      the cost of the ref-move optimization git's fast-forward performs.
    - No rename detection (version_control.md's Wave 4 bullet defers it
      explicitly): a file renamed on one side and edited on the other is
      seen as an unrelated add + delete, not a content conflict.
    - A conflict is counted per FILE (this porcelain's own tally,
      printed one "CONFLICT (...): path" line per file on stdout) even
      though merge3.w's own conflict count is per conflicting REGION
      within one file -- wvc reports "N files need resolving", not "N
      hunks need resolving".
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
import lib.file
import lib.container
import structures.string
import libs.standard.crypto.base64
import libs.extras.vcs.cas
import libs.extras.vcs.tree
import libs.extras.vcs.commit
import libs.extras.vcs.diff
import libs.extras.vcs.index
import libs.extras.vcs.dag
import libs.extras.vcs.merge3
import libs.extras.vcs.sync
import libs.standard.web.http_server


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
	stream_write_line(err, c"       wvc merge <rev> [-m <message>] [-a <author>]")
	stream_write_line(err, c"       wvc serve --port N [--root dir]")
	stream_write_line(err, c"       wvc pull <url> [ref]")
	stream_write_line(err, c"       wvc push <url> [ref]")
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


/* Merge helpers (wave 4, issue #252 -- see the header comment) */


# Recursively inserts commit_hex and every one of its ancestors into `d`
# in parents-before-children order (dag_add_node's own requirement),
# converting each 64-hex commit id to dag.w's 32-byte raw id form via
# hex_decode. `visited` (a map[char*, int] the caller owns and frees)
# guards against revisiting shared history twice when this is called
# once per merge side -- everything reachable from the first call short-
# circuits instantly on the second.
void wvc_dag_insert_ancestors(dag* d, wcas* store, map[char*, int] visited, char* commit_hex):
	if (commit_hex in visited):
		return
	visited[commit_hex] = 1
	commit_object* co = wvc_unwrap[commit_object*](commit_load(store, commit_hex), c"cannot load commit history for merge-base")
	for char* parent_hex in co.parent_ids:
		wvc_dag_insert_ancestors(d, store, visited, parent_hex)

	int raw_len = 0
	char* raw = hex_decode(commit_hex, 64, &raw_len)
	list[char*] parent_raws = new list[char*]
	for char* parent_hex in co.parent_ids:
		int plen = 0
		parent_raws.push(hex_decode(parent_hex, 64, &plen))
	dag_add_node(d, raw, parent_raws)
	free(raw)
	for char* p in parent_raws:
		free(p)
	list_free[char*](parent_raws)
	commit_free(co)


# Resolves the blob id at `path` under `tree_id`, or 0 for "not present"
# -- 0 for a 0 tree_id (no tree at all), and 0 (rather than propagating
# the error) for any lookup failure, since a merge's per-path plan needs
# a soft "maybe present" query on each of three sides independently, not
# wvc_lookup_blob's fail-fast error surface.
char* wvc_maybe_blob_id(wcas* store, char* tree_id, char* path):
	if (tree_id == 0):
		return 0
	wresult[char*]* r = wvc_lookup_blob(store, tree_id, path)
	if (result_is_error[char*](r)):
		result_free[char*](r)
		return 0
	char* id = result_value[char*](r)
	result_free[char*](r)
	return id


# Resolves the blob at `path` under `tree_id` AND confirms it is really
# a "blob" object (not a "tree" -- a tree_diff entry naming a whole
# added/removed directory resolves its OWN path to a tree id, which
# this rejects rather than misreading as file content; the directory's
# individual files already appear as their own separate tree_diff
# entries, so skipping the directory-level entry here loses nothing).
# Returns 0 for "not present or not a file"; the caller owns the result
# and releases it with cas_object_free.
wcas_object* wvc_maybe_blob(wcas* store, char* tree_id, char* path):
	char* id = wvc_maybe_blob_id(store, tree_id, path)
	if (id == 0):
		return 0
	wresult[wcas_object*]* r = cas_get(store, id)
	free(id)
	if (result_is_error[wcas_object*](r)):
		result_free[wcas_object*](r)
		return 0
	wcas_object* o = result_value[wcas_object*](r)
	result_free[wcas_object*](r)
	if (strcmp(o.object_type, c"blob") != 0):
		cas_object_free(o)
		return 0
	return o


# Byte-for-byte content equality, treating "both absent" (0, 0) as equal
# and "one absent" as never equal.
int wvc_blob_content_equal(wcas_object* a, wcas_object* b):
	if ((a == 0) && (b == 0)):
		return 1
	if ((a == 0) || (b == 0)):
		return 0
	if (a.length != b.length):
		return 0
	int i = 0
	while (i < a.length):
		if (a.data[i] != b.data[i]):
			return 0
		i = i + 1
	return 1


int WVC_BINARY_SNIFF_LEN():
	return 8000


# Git's own binary-detection heuristic: a NUL byte anywhere in the first
# WVC_BINARY_SNIFF_LEN() bytes. 0 (absent) is never binary-ish -- there
# is no content to sniff.
int wvc_is_binaryish(wcas_object* o):
	if (o == 0):
		return 0
	int n = o.length
	if (n > WVC_BINARY_SNIFF_LEN()):
		n = WVC_BINARY_SNIFF_LEN()
	int i = 0
	while (i < n):
		if (o.data[i] == 0):
			return 1
		i = i + 1
	return 0


# Union of the two change lists' paths, deduplicated and sorted
# (tree_name_compare -- tree.w's canonical byte-wise order, the same one
# index.w and tree.w themselves sort by). Returned pointers are borrowed
# from the tree_change entries themselves; the caller must keep
# `ours_changes`/`theirs_changes` alive for as long as the result is in
# use, and only needs to list_free the returned list itself.
list[char*] wvc_merge_collect_paths(list[tree_change*] ours_changes, list[tree_change*] theirs_changes):
	map[char*, int] seen = new map[char*, int]
	list[char*] paths = new list[char*]
	for tree_change* c in ours_changes:
		if ((c.path in seen) == 0):
			seen[c.path] = 1
			paths.push(c.path)
	for tree_change* c in theirs_changes:
		if ((c.path in seen) == 0):
			seen[c.path] = 1
			paths.push(c.path)
	map_free[char*, int](seen)
	paths.sort_by(tree_name_compare)
	return paths


# Creates every missing ancestor directory of `dir`/`rel_path` (all but
# the final path component -- the file itself), the same '/'-split-and-
# join approach wvc_split_path already gives every other path-walking
# helper in this file. Ignores EEXIST; a real mkdir failure surfaces
# later as the write that actually needs the directory failing instead.
void wvc_ensure_parent_dirs(char* dir, char* rel_path):
	list[char*] parts = wvc_split_path(rel_path)
	char* current = strclone(dir)
	int i = 0
	while (i < (parts.length - 1)):
		char* next = path_join(current, parts[i])
		free(current)
		current = next
		mkdir(current, 493)
		i = i + 1
	free(current)
	for char* p in parts:
		free(p)
	list_free[char*](parts)


# Writes `obj`'s raw bytes (length-framed, so embedded NUL bytes in
# binary content survive -- unlike file_write_text's strlen-based write)
# to <dir>/rel_path, creating any missing parent directories first.
void wvc_write_file_bytes(char* dir, char* rel_path, wcas_object* obj):
	wvc_ensure_parent_dirs(dir, rel_path)
	char* full_path = path_join(dir, rel_path)
	wstream* out = stream_open_write(full_path)
	free(full_path)
	if (out == 0):
		return
	stream_write(out, obj.data, obj.length)
	stream_close(out)


# Removes <dir>/rel_path if present; a missing file is not an error (the
# caller may be reconciling a delete against a working tree that's
# already in the target state).
void wvc_remove_file(char* dir, char* rel_path):
	char* full_path = path_join(dir, rel_path)
	unlink(full_path)
	free(full_path)


void wvc_report_conflict(wstream* out, char* kind, char* path):
	stream_write_cstr(out, c"CONFLICT (")
	stream_write_cstr(out, kind)
	stream_write_cstr(out, c"): ")
	stream_write_line(out, path)


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


# wvc merge <rev> [-m <message>] [-a <author>]: three-way merges <rev>
# into the current branch's HEAD (wave 4, issue #252 -- see the header
# comment's "Scope decisions" section for the full design). Runs against
# cwd, like `log`/`diff`: "<cwd>/.wvc" is the metadata root and cwd
# itself is the working tree files are written into.
int wvc_cmd_merge(int argc, int argv):
	char* other_arg = 0
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
		else if (other_arg == 0):
			other_arg = a
		else:
			wvc_usage()
			return 2
		i = i + 1
	if (other_arg == 0):
		wvc_usage()
		return 2

	char* dir = c"."
	char* meta = wvc_meta_dir(dir)
	wcas* store = wvc_open_store(meta)
	wrefs* refs = wvc_open_refs(meta)
	wstream* out = stdout_writer()

	wresult[char*]* head_r = ref_read(refs, WVC_DEFAULT_REF())
	if (result_is_error[char*](head_r)):
		int code = result_code[char*](head_r)
		result_free[char*](head_r)
		wvc_fail(c"cannot merge: no commits yet", code)
	char* head_id = result_value[char*](head_r)
	result_free[char*](head_r)

	char* other_id = wvc_resolve_rev(store, refs, other_arg)

	if (strcmp(head_id, other_id) == 0):
		stream_write_line(out, c"Already up to date.")
		stream_flush(out)
		free(head_id)
		free(other_id)
		free(meta)
		cas_close(store)
		refs_close(refs)
		return 0

	# Build the commit DAG over the full ancestry of both sides so
	# dag.w's generation-bounded merge-base walk has a graph to run on
	# (deferred here explicitly by the pre-wave-4 header comment; see
	# "Scope decisions" above).
	dag* d = dag_new()
	map[char*, int] visited = new map[char*, int]
	wvc_dag_insert_ancestors(d, store, visited, head_id)
	wvc_dag_insert_ancestors(d, store, visited, other_id)
	map_free[char*, int](visited)

	int head_raw_len = 0
	char* head_raw = hex_decode(head_id, 64, &head_raw_len)
	int other_raw_len = 0
	char* other_raw = hex_decode(other_id, 64, &other_raw_len)
	list[char*] base_raws = dag_merge_base(d, head_raw, other_raw)
	if (base_raws.length == 0):
		wvc_fail(c"HEAD and the given commit share no common ancestor", -22)
	# dag_merge_base sorts results by ascending insertion sequence number
	# already (dag.w's own header comment); base_raws[0] is therefore the
	# deterministic "first" best common ancestor -- see the header
	# comment's criss-cross note.
	char* base_id = hex_encode(base_raws[0], DAG_ID_SIZE())
	free(head_raw)
	free(other_raw)
	list_free[char*](base_raws)

	if (strcmp(base_id, other_id) == 0):
		# <rev> is already an ancestor of HEAD: nothing to bring in.
		stream_write_line(out, c"Already up to date.")
		stream_flush(out)
		free(base_id)
		free(head_id)
		free(other_id)
		free(meta)
		cas_close(store)
		refs_close(refs)
		return 0

	commit_object* base_co = wvc_unwrap[commit_object*](commit_load(store, base_id), c"cannot load merge-base commit")
	commit_object* head_co = wvc_unwrap[commit_object*](commit_load(store, head_id), c"cannot load HEAD commit")
	commit_object* other_co = wvc_unwrap[commit_object*](commit_load(store, other_id), c"cannot load merged commit")

	list[tree_change*] ours_changes = new list[tree_change*]
	wvc_unwrap[int](tree_diff(store, base_co.tree_id, head_co.tree_id, ours_changes), c"merge: diff against merge-base (ours) failed")
	list[tree_change*] theirs_changes = new list[tree_change*]
	wvc_unwrap[int](tree_diff(store, base_co.tree_id, other_co.tree_id, theirs_changes), c"merge: diff against merge-base (theirs) failed")

	list[char*] paths = wvc_merge_collect_paths(ours_changes, theirs_changes)
	int conflicts = 0
	for char* path in paths:
		wcas_object* base_obj = wvc_maybe_blob(store, base_co.tree_id, path)
		wcas_object* ours_obj = wvc_maybe_blob(store, head_co.tree_id, path)
		wcas_object* theirs_obj = wvc_maybe_blob(store, other_co.tree_id, path)

		int ours_changed = wvc_blob_content_equal(base_obj, ours_obj) == 0
		int theirs_changed = wvc_blob_content_equal(base_obj, theirs_obj) == 0

		if ((ours_changed == 0) && (theirs_changed == 0)):
			# Neither side names a real content change at this path (a
			# directory-level tree_diff entry, most likely) -- nothing
			# to reconcile.
			int noop = 1
		else if (ours_changed == 0):
			# Only theirs changed: apply cleanly.
			if (theirs_obj == 0):
				wvc_remove_file(dir, path)
			else:
				wvc_write_file_bytes(dir, path, theirs_obj)
		else if (theirs_changed == 0):
			# Only ours changed: keep -- already on disk, no write.
			int noop = 1
		else if (wvc_blob_content_equal(ours_obj, theirs_obj)):
			# Both changed identically (including both deleting):
			# coalesce.
			if (ours_obj == 0):
				wvc_remove_file(dir, path)
		else if ((ours_obj == 0) || (theirs_obj == 0)):
			# Modify/delete conflict: no third text to line-merge
			# against. Keep whichever side still has content (git's own
			# posture); materialize theirs' content when ours has none
			# to fall back on.
			conflicts = conflicts + 1
			wvc_report_conflict(out, c"modify/delete", path)
			if (ours_obj == 0):
				wvc_write_file_bytes(dir, path, theirs_obj)
		else if (wvc_is_binaryish(base_obj) || wvc_is_binaryish(ours_obj) || wvc_is_binaryish(theirs_obj)):
			# Binary-ish: conflict wholesale, leave ours' content in
			# place untouched -- never interleave binary bytes with
			# text markers.
			conflicts = conflicts + 1
			wvc_report_conflict(out, c"binary", path)
		else:
			char* base_text = c""
			if (base_obj != 0):
				base_text = base_obj.data
			merge3_text_result* mr = merge3_merge_text(base_text, ours_obj.data, theirs_obj.data, 0, 0)
			wvc_ensure_parent_dirs(dir, path)
			char* full_path = path_join(dir, path)
			file_write_text(full_path, mr.text)
			free(full_path)
			if (mr.conflicts > 0):
				conflicts = conflicts + 1
				wvc_report_conflict(out, c"content", path)
			free(mr.text)
			free(mr)

		if (base_obj != 0):
			cas_object_free(base_obj)
		if (ours_obj != 0):
			cas_object_free(ours_obj)
		if (theirs_obj != 0):
			cas_object_free(theirs_obj)

	int result = 0
	if (conflicts > 0):
		stream_flush(out)
		result = 1
	else:
		list[char*] ignore = wvc_ignore_list()
		char* index_path = wvc_index_path(meta)
		wresult[windex*]* prev_index_r = index_read(index_path)
		windex* prev_index = 0
		if (result_is_ok[windex*](prev_index_r)):
			prev_index = result_value[windex*](prev_index_r)
		result_free[windex*](prev_index_r)
		index_refresh_result* refreshed = wvc_unwrap[index_refresh_result*](index_refresh(store, dir, ignore, prev_index), c"merge failed while refreshing the dirstate")
		list_free[char*](ignore)
		if (prev_index != 0):
			index_free(prev_index)
		char* new_tree_id = refreshed.tree_id
		windex* new_index = refreshed.index
		free(refreshed)

		list[char*] parent_ids = new list[char*]
		parent_ids.push(head_id)
		parent_ids.push(other_id)

		char* final_message = message
		int free_message = 0
		if (final_message == 0):
			string_builder* mb = string_new()
			string_append(mb, c"Merge ")
			string_append(mb, other_arg)
			final_message = mb.data
			free(mb)
			free_message = 1

		commit_object* mco = wvc_unwrap[commit_object*](commit_new(new_tree_id, parent_ids, author, time_now(), final_message, strlen(final_message)), c"invalid merge commit")
		char* commit_id = wvc_unwrap[char*](commit_store(store, mco), c"cannot store merge commit")
		wvc_unwrap[int](ref_update(refs, WVC_DEFAULT_REF(), commit_id, final_message), c"cannot update ref")

		wresult[int]* index_written = index_write(new_index, index_path)
		result_free[int](index_written)

		stream_write_line(out, commit_id)
		stream_flush(out)

		if (free_message):
			free(final_message)
		commit_free(mco)
		list_free[char*](parent_ids)
		free(new_tree_id)
		index_free(new_index)
		free(index_path)
		free(commit_id)

	list_free[char*](paths)
	tree_changes_free(ours_changes)
	list_free[tree_change*](ours_changes)
	tree_changes_free(theirs_changes)
	list_free[tree_change*](theirs_changes)
	commit_free(base_co)
	commit_free(head_co)
	commit_free(other_co)
	free(base_id)
	free(head_id)
	free(other_id)
	free(meta)
	cas_close(store)
	refs_close(refs)
	return result


/* wvc serve / pull / push (wave 4, issue #252 "sync" -- see the header
   comment and libs/extras/vcs/sync.w's own header comment for the wire
   protocol and algorithm). Thin wiring only: every real operation is
   libs/extras/vcs/sync.w. */


# The server_handler_fn ServerContext requires even though every request
# here is dispatched through the RequestContext/routing path instead
# (vcs_sync_register_routes always registers at least one route) -- see
# http_server.w's own module doc: this is never actually called.
ServerResponse* wvc_serve_unused_handler(ServerRequest* req, void* context):
	return server_response_new(404)


int wvc_cmd_serve(int argc, int argv):
	int port = -1
	char* root = c"."
	int i = 2
	while (i < argc):
		char** arg = argv + i * __word_size__
		char* a = *arg
		if (strcmp(a, c"--port") == 0):
			i = i + 1
			if (i >= argc):
				wvc_usage()
				return 2
			char** v = argv + i * __word_size__
			port = atoi(*v)
		else if (strcmp(a, c"--root") == 0):
			i = i + 1
			if (i >= argc):
				wvc_usage()
				return 2
			char** v = argv + i * __word_size__
			root = *v
		else:
			wvc_usage()
			return 2
		i = i + 1
	if (port < 0):
		wvc_usage()
		return 2

	char* meta = wvc_meta_dir(root)
	wcas* store = wvc_open_store(meta)
	wrefs* refs = wvc_open_refs(meta)
	free(meta)

	wvc_serve_ctx* ctx = new wvc_serve_ctx()
	ctx.store = store
	ctx.refs = refs

	ServerContext* s = server_context_new(c"127.0.0.1", port, wvc_serve_unused_handler, 0)
	vcs_sync_register_routes(s, ctx)
	if (server_context_bind(s) == 0):
		wstream* err = stderr_writer()
		stream_write_line(err, c"wvc: cannot bind server")
		stream_flush(err)
		return 1
	int bound_port = server_context_port(s)

	wstream* out = stdout_writer()
	stream_write_cstr(out, c"Listening on 127.0.0.1:")
	char* port_text = itoa(bound_port)
	stream_write_line(out, port_text)
	free(port_text)
	stream_flush(out)

	# Serves forever (max_connections <= 0) -- a `wvc serve` process is
	# killed by whatever launched it (a script, or this project's own
	# tests/wvc_sync_e2e_test.w), never told to stop gracefully; see
	# sync.w's header comment on the concurrency/robustness posture.
	server_context_accept_loop(s, 0)

	server_context_free(s)
	cas_close(store)
	refs_close(refs)
	free(ctx)
	return 0


int wvc_cmd_pull(int argc, int argv):
	char* url = 0
	char* ref_name = WVC_DEFAULT_REF()
	if (argc >= 3):
		char** arg = argv + 2 * __word_size__
		url = *arg
	if (argc >= 4):
		char** arg2 = argv + 3 * __word_size__
		ref_name = *arg2
	if (url == 0):
		wvc_usage()
		return 2

	char* meta = wvc_meta_dir(c".")
	wcas* store = wvc_open_store(meta)
	wrefs* refs = wvc_open_refs(meta)
	free(meta)

	wstream* out = stdout_writer()
	int result = vcs_sync_pull(store, refs, url, ref_name, out)

	cas_close(store)
	refs_close(refs)
	return result


int wvc_cmd_push(int argc, int argv):
	char* url = 0
	char* ref_name = WVC_DEFAULT_REF()
	if (argc >= 3):
		char** arg = argv + 2 * __word_size__
		url = *arg
	if (argc >= 4):
		char** arg2 = argv + 3 * __word_size__
		ref_name = *arg2
	if (url == 0):
		wvc_usage()
		return 2

	char* meta = wvc_meta_dir(c".")
	wcas* store = wvc_open_store(meta)
	wrefs* refs = wvc_open_refs(meta)
	free(meta)

	wstream* out = stdout_writer()
	int result = vcs_sync_push(store, refs, url, ref_name, out)

	cas_close(store)
	refs_close(refs)
	return result


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
	if (strcmp(cmd, c"merge") == 0):
		return wvc_cmd_merge(argc, argv)
	if (strcmp(cmd, c"serve") == 0):
		return wvc_cmd_serve(argc, argv)
	if (strcmp(cmd, c"pull") == 0):
		return wvc_cmd_pull(argc, argv)
	if (strcmp(cmd, c"push") == 0):
		return wvc_cmd_push(argc, argv)
	wvc_usage()
	return 2
