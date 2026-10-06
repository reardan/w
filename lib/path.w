/*
Filesystem path helpers.

These helpers stay within the current raw Linux syscall surface. path_exists()
checks whether a path can be opened read-only; without stat/access wrappers it
does not distinguish missing paths from permission-denied paths.
*/
import lib.lib


# Returns a malloc'd string the caller may free.
char* path_clone_range(char* start, int length):
	char* result = malloc(length + 1)
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
	char* out = malloc(length + 2)
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
	char* joined = malloc(left_length + right_length + needs_slash + 1)
	char* cur = joined
	cur = strcpy(cur, left)
	if (needs_slash):
		cur[0] = '/'
		cur = cur + 1
	strcpy(cur, right)
	char* result = path_normalize(joined)
	free(joined)
	return result


# Whether path, after normalising both, is root itself or lies under it
# (lexically; symlinks are not followed). A relative path is never
# within an absolute root or vice versa.
int path_is_within(char* root, char* path):
	char* r = path_normalize(root)
	char* p = path_normalize(path)
	int r_len = strlen(r)
	if ((r_len > 1) && (r[r_len - 1] == '/')):
		r_len = r_len - 1
		r[r_len] = 0
	int p_len = strlen(p)
	if ((p_len > 1) && (p[p_len - 1] == '/')):
		p_len = p_len - 1
		p[p_len] = 0
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
