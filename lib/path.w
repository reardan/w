/*
Filesystem path helpers.

These helpers stay within the current raw Linux syscall surface. path_exists()
checks whether a path can be opened read-only; without stat/access wrappers it
does not distinguish missing paths from permission-denied paths.
*/
import lib.lib
import lib.env


# Returns a malloc'd string the caller may free.
char* path_clone_range(char* start, int length):
	char* result = cast(char*, malloc(length + 1))
	for i in range(length): result[i] = start[i]
	result[length] = 0
	return result


# Lexically normalises path: collapses repeated '/', drops "."
# components and resolves each ".." against the component before it.
# A relative path keeps the ".." components it cannot resolve
# ("../x"); ".." at the root of an absolute path stays at the root
# ("/../x" -> "/x"). A trailing '/' is kept when the result names a
# component; an empty result is ".". This is purely textual: a ".."
# after a symlinked directory resolves differently on disk.
# Returns a malloc'd string the caller may free.
char* path_normalize(char* path):
	int length = strlen(path)
	int absolute = (length > 0) && (path[0] == '/')
	int trailing = (length > 0) && (path[length - 1] == '/')
	# Output never grows: each kept component is copied left.
	char* out = cast(char*, malloc(length + 2))
	int out_len = 0
	if (absolute):
		out[0] = '/'
		out_len = 1
	int base = out_len
	# Leading ".." components kept in a relative result end here.
	int fixed = out_len
	int i = 0
	while (i < length):
		while ((i < length) && (path[i] == '/')): i = i + 1
		int start = i
		while ((i < length) && (path[i] != '/')): i = i + 1
		int part = i - start
		if (part == 0): continue
		if ((part == 1) && (path[start] == '.')): continue
		if ((part == 2) && (path[start] == '.') && (path[start + 1] == '.')):
			if (out_len > fixed):
				# Drop the last kept component (and its separator).
				while ((out_len > fixed) && (out[out_len - 1] != '/')): out_len = out_len - 1
				if (out_len > base): out_len = out_len - 1
				continue
			if (absolute): continue
			if (out_len > base):
				out[out_len] = '/'
				out_len = out_len + 1
			out[out_len] = '.'
			out[out_len + 1] = '.'
			out_len = out_len + 2
			fixed = out_len
			continue
		if (out_len > base):
			out[out_len] = '/'
			out_len = out_len + 1
		for j in range(part): out[out_len + j] = path[start + j]
		out_len = out_len + part
	if (out_len == 0):
		out[0] = '.'
		out_len = 1
	else if (trailing && (out_len > base)):
		out[out_len] = '/'
		out_len = out_len + 1
	out[out_len] = 0
	return out


# Joins right onto left and normalises the result (path_normalize), so
# "." and ".." components in either part are resolved: path_join(
# "/srv/static", "../../etc/passwd") is "/etc/passwd". An absolute
# right replaces left, and an empty part yields the other one. To keep
# an untrusted relative path inside a root, use path_join_within.
# Returns a malloc'd string the caller may free.
char* path_join(char* left, char* right):
	int left_length = strlen(left)
	int right_length = strlen(right)
	if (right_length == 0):
		if (left_length == 0): return strclone(left)
		return path_normalize(left)
	if (right[0] == '/'): return path_normalize(right)
	if (left_length == 0): return path_normalize(right)

	int needs_slash = left[left_length - 1] != '/'
	char* joined = cast(char*, malloc(left_length + right_length + needs_slash + 1))
	char* cur = joined
	cur = strcpy(cur, left)
	if (needs_slash):
		cur[0] = '/'
		cur = cur + 1
	strcpy(cur, right)
	char* result = path_normalize(joined)
	free(joined)
	return result


# path_normalize without the trailing '/' it keeps for a directory-like
# path ("a/b/" -> "a/b"); "/" stays "/".
# Returns a malloc'd string the caller may free.
char* path_normalize_bare(char* path):
	char* p = path_normalize(path)
	int length = strlen(p)
	if ((length > 1) && (p[length - 1] == '/')): p[length - 1] = 0
	return p


# Whether path, after normalising both, is root itself or lies under it
# (lexically; symlinks are not followed). A relative path is never
# within an absolute root or vice versa.
int path_is_within(char* root, char* path):
	char* r = path_normalize_bare(root)
	char* p = path_normalize_bare(path)
	int r_len = strlen(r)
	int inside = 0
	if (strcmp(r, c".") == 0):
		# Relative root ".": anything relative that does not climb out.
		inside = (p[0] != '/') && (strcmp(p, c"..") != 0) && (starts_with(p, c"../") == 0)
	else if (strcmp(r, c"/") == 0): inside = p[0] == '/'
	else if (starts_with(p, r) && ((p[r_len] == 0) || (p[r_len] == '/'))): inside = 1
	free(r)
	free(p)
	return inside


# Resolves an untrusted path (for example a URL path) beneath root:
# leading '/' characters are stripped so rel is always taken relative
# to root, the joined path is normalised, and the result is returned
# only when it stays inside root (path_is_within). Returns a malloc'd
# path the caller may free, or 0 when rel escapes root.
char* path_join_within(char* root, char* rel):
	while (rel[0] == '/'): rel = rel + 1
	char* joined = path_join(root, rel)
	if (path_is_within(root, joined) == 0):
		free(joined)
		return 0
	return joined


# Returns a malloc'd string the caller may free.
char* path_basename(char* path):
	int length = strlen(path)
	if (length == 0): return strclone(c".")

	while ((length > 1) && (path[length - 1] == '/')): length = length - 1

	if ((length == 1) && (path[0] == '/')): return strclone(c"/")

	int end = length
	int start = end - 1
	while ((start >= 0) && (path[start] != '/')): start = start - 1
	start = start + 1
	return path_clone_range(path + start, end - start)


# Returns a malloc'd string the caller may free.
char* path_dirname(char* path):
	int length = strlen(path)
	if (length == 0): return strclone(c".")

	while ((length > 1) && (path[length - 1] == '/')): length = length - 1

	if ((length == 1) && (path[0] == '/')): return strclone(c"/")

	int slash = length - 1
	while ((slash >= 0) && (path[slash] != '/')): slash = slash - 1

	if (slash < 0): return strclone(c".")

	while ((slash > 0) && (path[slash - 1] == '/')): slash = slash - 1

	if (slash == 0): return strclone(c"/")

	return path_clone_range(path, slash)


int path_exists(char* path):
	int file = open(path, 2048, 0)
	if (file < 0): return 0
	close(file)
	return 1


# Return 1 if the path is absolute: starts with '/' (Unix) or with a
# Windows drive letter and colon (e.g. 'C:\', 'C:/', 'c:'). The drive
# form is accepted on every host because the compiler resolves paths
# for its win64 target with it; otherwise this is os.path.isabs.
int path_is_absolute(char* p):
	if (p[0] == 47): return 1
	# Windows drive letter: an ASCII letter at [0], colon at [1]. The
	# letter check keeps ':' in ordinary Unix filenames from matching
	# (and never reads p[1] when the string is empty).
	int first = p[0] | 32
	if ((first >= 'a') && (first <= 'z') && (p[1] == 58)): return 1
	return 0


# Offset where the extension of the first length bytes of s starts, as
# os.path.splitext splits it: the last '.' of the final component,
# unless everything before it in that component is dots (".bashrc",
# "..", "...x" have no extension). Returns length when there is none.
int path_ext_offset(char* s, int length):
	int sep = length - 1
	while ((sep >= 0) && (s[sep] != '/')): sep = sep - 1
	int dot = length - 1
	while ((dot > sep) && (s[dot] != '.')): dot = dot - 1
	if (dot <= sep): return length
	int name = sep + 1
	while ((name < dot) && (s[name] == '.')): name = name + 1
	if (name == dot): return length
	return dot


# os.path.splitext: stores malloc'd root and ext (each for the caller to
# free) with root + ext == path. "a.tar.gz" -> ("a.tar", ".gz"),
# ".bashrc" -> (".bashrc", ""), "a.b/c" -> ("a.b/c", ""), "x." -> ("x", ".").
void path_splitext(char* path, char** root, char** ext):
	int length = strlen(path)
	int dot = path_ext_offset(path, length)
	root[0] = path_clone_range(path, dot)
	ext[0] = path_clone_range(path + dot, length - dot)


# Locates pathlib's name: the final component, ignoring trailing '/' and
# trailing "." components ("a/b/./" -> "b"). It is empty for "", "." and
# "/". Stores the start offset and returns the length.
int path_name_range(char* path, int* start_out):
	int end = strlen(path)
	int start = end
	int again = 1
	while (again):
		while ((end > 0) && (path[end - 1] == '/')): end = end - 1
		start = end
		while ((start > 0) && (path[start - 1] != '/')): start = start - 1
		again = ((end - start) == 1) && (path[start] == '.')
		if (again): end = start
	start_out[0] = start
	return end - start


# pathlib's suffix: the extension of the final component, splitext-style
# ("a/b.tar.gz" -> ".gz", ".bashrc" -> "", "x." -> "." as in Python
# 3.14). Returns a malloc'd string the caller may free.
char* path_suffix(char* path):
	int start = 0
	int length = path_name_range(path, &start)
	int dot = path_ext_offset(path + start, length)
	return path_clone_range(path + start + dot, length - dot)


# pathlib's stem: the final component without its suffix ("a/b.tar.gz"
# -> "b.tar", ".bashrc" -> ".bashrc", "/" -> "").
# Returns a malloc'd string the caller may free.
char* path_stem(char* path):
	int start = 0
	int length = path_name_range(path, &start)
	int dot = path_ext_offset(path + start, length)
	return path_clone_range(path + start, dot)


# pathlib's relative_to (without walk_up): path relative to base, after
# normalising both lexically (path_normalize_bare). Returns "." when they
# are the same path, or 0 when path is not within base (path_is_within;
# a relative path is never within an absolute base or vice versa).
# Returns a malloc'd string the caller may free.
char* path_relative_to(char* path, char* base):
	if (path_is_within(base, path) == 0): return 0
	char* r = path_normalize_bare(base)
	char* p = path_normalize_bare(path)
	char* result = 0
	if (strcmp(r, c".") == 0): result = strclone(p)
	else if (strcmp(p, r) == 0): result = strclone(c".")
	else if (strcmp(r, c"/") == 0): result = strclone(p + 1)
	else: result = strclone(p + strlen(r) + 1)
	free(r)
	free(p)
	return result


# os.path.expanduser for "~" and "~/...": replaces the leading "~" with
# $HOME (trailing '/' stripped; an empty result is "/"). The path is
# returned unchanged when it does not start with "~", when HOME is unset
# (Python would consult the password database), and for the "~user"
# form, which needs a password-database lookup this module does not do.
# Returns a malloc'd string the caller may free.
char* path_expand_user(char* path):
	if (path[0] != '~'): return strclone(path)
	if ((path[1] != 0) && (path[1] != '/')): return strclone(path)
	char* home = env_get(c"HOME")
	if (home == 0): return strclone(path)
	int home_length = strlen(home)
	while ((home_length > 0) && (home[home_length - 1] == '/')): home_length = home_length - 1
	int rest = strlen(path) - 1
	if ((home_length + rest) == 0): return strclone(c"/")
	char* out = cast(char*, malloc(home_length + rest + 1))
	for i in range(home_length): out[i] = home[i]
	for j in range(rest): out[home_length + j] = path[1 + j]
	out[home_length + rest] = 0
	return out


# pathlib's parts: "/" first for an absolute path, then each component;
# empty and "." components are dropped and ".." is kept ("/a//./b/../c"
# -> ["/", "a", "b", "..", "c"]; "" and "." -> []). Unlike pathlib, a
# leading "//" is "/". Free the result with path_parts_free.
list[char*] path_split_parts(char* path):
	list[char*] parts = new list[char*]
	int length = strlen(path)
	if ((length > 0) && (path[0] == '/')): parts.push(strclone(c"/"))
	int i = 0
	while (i < length):
		while ((i < length) && (path[i] == '/')): i = i + 1
		int start = i
		while ((i < length) && (path[i] != '/')): i = i + 1
		int part = i - start
		if (part == 0): continue
		if ((part == 1) && (path[start] == '.')): continue
		parts.push(path_clone_range(path + start, part))
	return parts


# Frees a path_split_parts result and its strings.
void path_parts_free(list[char*] parts):
	for char* part in parts: free(part)
	__w_list_free(cast(__w_list*, parts))
