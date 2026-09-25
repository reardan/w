/*
Working-tree and repository-layout helpers shared by VCS porcelains
(issue #338: split out of tools/wvc.w so the CLI is argument parsing,
error policy and output only; see that file's header comment for the
merge and diff semantics these helpers implement).

Repo layout convention: a working directory is tracked by a metadata
directory right inside it (REPO_META_DIR_NAME(), ".wvc"), which serves as
the root for both cas_open and refs_open, plus index.w's dirstate file.

Nothing here exits the process: lookups return wresult errors or 0 for
"not present", and file writes fail soft, so a caller picks its own
error policy.
*/
import lib.lib
import lib.path
import lib.result
import lib.stream
import structures.string
import libs.extras.vcs.cas
import libs.extras.vcs.tree
import libs.extras.vcs.diff
import libs.extras.vcs.index


char* REPO_META_DIR_NAME():
	return c".wvc"


char* REPO_DEFAULT_REF():
	return c"main"


char* repo_meta_dir(char* dir):
	return path_join(dir, REPO_META_DIR_NAME())


# "<meta>/index" -- libs/extras/vcs/index.w's persisted dirstate
# (INDEX_FILE_NAME()).
char* repo_index_path(char* meta):
	return path_join(meta, INDEX_FILE_NAME())


# Exact-name-at-every-depth ignore list tree_snapshot expects: our own
# metadata directory, and build output (the same "bin" example
# tree.w's own header comment uses).
list[char*] repo_ignore_list():
	list[char*] ignore = new list[char*]
	ignore.push(REPO_META_DIR_NAME())
	ignore.push(c"bin")
	return ignore


int repo_status_char(int status):
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
list[char*] repo_split_path(char* path):
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
# (repo_diff_modified) treat any error here as "skip the content diff",
# not fatal.
wresult[char*]* repo_lookup_blob(wcas* store, char* root_id, char* path):
	list[char*] parts = repo_split_path(path)
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


# Resolves the blob id at `path` under `tree_id`, or 0 for "not present"
# -- 0 for a 0 tree_id (no tree at all), and 0 (rather than propagating
# the error) for any lookup failure, since a merge's per-path plan needs
# a soft "maybe present" query on each of three sides independently, not
# repo_lookup_blob's fail-fast error surface.
char* repo_maybe_blob_id(wcas* store, char* tree_id, char* path):
	if (tree_id == 0):
		return 0
	wresult[char*]* r = repo_lookup_blob(store, tree_id, path)
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
wcas_object* repo_maybe_blob(wcas* store, char* tree_id, char* path):
	char* id = repo_maybe_blob_id(store, tree_id, path)
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
int repo_blob_content_equal(wcas_object* a, wcas_object* b):
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


int REPO_BINARY_SNIFF_LEN():
	return 8000


# Git's own binary-detection heuristic: a NUL byte anywhere in the first
# REPO_BINARY_SNIFF_LEN() bytes. 0 (absent) is never binary-ish -- there
# is no content to sniff.
int repo_is_binaryish(wcas_object* o):
	if (o == 0):
		return 0
	int n = o.length
	if (n > REPO_BINARY_SNIFF_LEN()):
		n = REPO_BINARY_SNIFF_LEN()
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
list[char*] repo_merge_collect_paths(list[tree_change*] ours_changes, list[tree_change*] theirs_changes):
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
# join approach repo_split_path already gives every other path-walking
# helper in this file. Ignores EEXIST; a real mkdir failure surfaces
# later as the write that actually needs the directory failing instead.
void repo_ensure_parent_dirs(char* dir, char* rel_path):
	list[char*] parts = repo_split_path(rel_path)
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
void repo_write_file_bytes(char* dir, char* rel_path, wcas_object* obj):
	repo_ensure_parent_dirs(dir, rel_path)
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
void repo_remove_file(char* dir, char* rel_path):
	char* full_path = path_join(dir, rel_path)
	unlink(full_path)
	free(full_path)


# Nice-to-have content diff for one TREE_MODIFIED path (see the header
# comment): resolves both sides' blob ids by walking the two trees, and
# renders a unified diff if the content actually differs. Any failure
# along the way (path not found the way tree_diff itself found it -- it
# can't happen without the object store changing under us, but this
# reuses cas_get's own error surface rather than asserting) just skips
# the content hunk; the path-level "M <path>" line the caller already
# printed still stands.
void repo_diff_modified(wcas* store, char* tree_a, char* tree_b, char* path, wstream* out):
	wresult[char*]* old_id_r = repo_lookup_blob(store, tree_a, path)
	wresult[char*]* new_id_r = repo_lookup_blob(store, tree_b, path)
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
