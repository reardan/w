/*
POSIX path helpers for libs.standard.fs.

These functions are lexical except fs_path_abspath(), which reads the current
working directory and then normalizes the result. Returned strings are malloc'd.
*/
import lib.lib
import structures.string


char* fs_path_clone_range(char* start, int length):
	char* result = malloc(length + 1)
	int i = 0
	while (i < length):
		result[i] = start[i]
		i = i + 1
	result[length] = 0
	return result


void fs_path_append_range(string_builder* out, char* start, int length):
	if (length == 0):
		return
	if ((out.length > 0) && !((out.length == 1) && (out.data[0] == '/'))):
		string_append_char(out, '/')
	int i = 0
	while (i < length):
		string_append_char(out, start[i])
		i = i + 1


int fs_path_segment_equals(char* start, int length, char* value):
	if (strlen(value) != length):
		return 0
	int i = 0
	while (i < length):
		if (start[i] != value[i]):
			return 0
		i = i + 1
	return 1


int fs_path_last_is_parent(string_builder* out):
	int start = out.length - 1
	while ((start >= 0) && (out.data[start] != '/')):
		start = start - 1
	start = start + 1
	return ((out.length - start) == 2) && (out.data[start] == '.') && (out.data[start + 1] == '.')


void fs_path_remove_last(string_builder* out):
	if (out.length == 0):
		return
	if ((out.length == 1) && (out.data[0] == '/')):
		return
	int i = out.length - 1
	while ((i >= 0) && (out.data[i] != '/')):
		i = i - 1
	if (i <= 0):
		if ((i == 0) && (out.data[0] == '/')):
			out.length = 1
		else:
			out.length = 0
	else:
		out.length = i
	out.data[out.length] = 0


int fs_path_isabs(char* path):
	return path[0] == '/'


# Joins two POSIX path fragments. An absolute right side replaces the left.
char* fs_path_join(char* left, char* right):
	int left_length = strlen(left)
	int right_length = strlen(right)
	if ((right_length > 0) && (right[0] == '/')):
		return strclone(right)
	if (left_length == 0):
		return strclone(right)
	int needs_slash = left[left_length - 1] != '/'
	char* result = malloc(left_length + needs_slash + right_length + 1)
	char* cur = result
	cur = strcpy(cur, left)
	if (needs_slash):
		cur[0] = '/'
		cur = cur + 1
	strcpy(cur, right)
	return result


# Normalizes a POSIX path without touching the filesystem.
char* fs_path_normpath(char* path):
	int length = strlen(path)
	if (length == 0):
		return strclone(c".")
	int absolute = fs_path_isabs(path)
	string_builder* out = string_new()
	if (absolute):
		string_append_char(out, '/')
	int i = 0
	while (i < length):
		while ((i < length) && (path[i] == '/')):
			i = i + 1
		int start = i
		while ((i < length) && (path[i] != '/')):
			i = i + 1
		int segment_length = i - start
		if ((segment_length > 0) && !fs_path_segment_equals(path + start, segment_length, c".")):
			if (fs_path_segment_equals(path + start, segment_length, c"..")):
				if (absolute):
					if (out.length > 1):
						fs_path_remove_last(out)
				else if ((out.length == 0) || fs_path_last_is_parent(out)):
					fs_path_append_range(out, path + start, segment_length)
				else:
					fs_path_remove_last(out)
			else:
				fs_path_append_range(out, path + start, segment_length)
	if (out.length == 0):
		string_append_char(out, '.')
	char* result = out.data
	free(out)
	return result


char* fs_path_abspath(char* path):
	if (fs_path_isabs(path)):
		return fs_path_normpath(path)
	int buffer_size = 4096
	char* cwd = malloc(buffer_size)
	int rc = getcwd(cwd, buffer_size)
	if (rc < 0):
		free(cwd)
		return 0
	char* joined = fs_path_join(cwd, path)
	free(cwd)
	char* normalized = fs_path_normpath(joined)
	free(joined)
	return normalized


# Returns the final path component. Like Python posixpath.basename(),
# trailing slashes produce an empty basename.
char* fs_path_basename(char* path):
	int length = strlen(path)
	int start = length - 1
	while ((start >= 0) && (path[start] != '/')):
		start = start - 1
	start = start + 1
	return fs_path_clone_range(path + start, length - start)


# Returns the leading directory portion, or an empty string when there is none.
char* fs_path_dirname(char* path):
	int length = strlen(path)
	int end = length - 1
	while ((end >= 0) && (path[end] != '/')):
		end = end - 1
	if (end < 0):
		return strclone(c"")
	while ((end > 0) && (path[end] == '/')):
		end = end - 1
	if ((end == 0) && (path[0] == '/')):
		return strclone(c"/")
	return fs_path_clone_range(path, end + 1)
