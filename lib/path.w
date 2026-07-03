/*
Filesystem path helpers.

These helpers stay within the current raw Linux syscall surface. path_exists()
checks whether a path can be opened read-only; without stat/access wrappers it
does not distinguish missing paths from permission-denied paths.
*/
import lib.lib


char* path_clone_range(char* start, int length):
	char* result = malloc(length + 1)
	int i = 0
	while (i < length):
		result[i] = start[i]
		i = i + 1
	result[length] = 0
	return result


char* path_join(char* left, char* right):
	int left_length = strlen(left)
	int right_length = strlen(right)
	if (right_length == 0):
		return strclone(left)
	if (right[0] == '/'):
		return strclone(right)
	if (left_length == 0):
		return strclone(right)

	int needs_slash = left[left_length - 1] != '/'
	char* result = malloc(left_length + right_length + needs_slash + 1)
	char* cur = result
	cur = strcpy(cur, left)
	if (needs_slash):
		cur[0] = '/'
		cur = cur + 1
	strcpy(cur, right)
	return result


char* path_basename(char* path):
	int length = strlen(path)
	if (length == 0):
		return strclone(".")

	while ((length > 1) & (path[length - 1] == '/')):
		length = length - 1

	if ((length == 1) & (path[0] == '/')):
		return strclone("/")

	int end = length
	int start = end - 1
	while ((start >= 0) & (path[start] != '/')):
		start = start - 1
	start = start + 1
	return path_clone_range(path + start, end - start)


char* path_dirname(char* path):
	int length = strlen(path)
	if (length == 0):
		return strclone(".")

	while ((length > 1) & (path[length - 1] == '/')):
		length = length - 1

	if ((length == 1) & (path[0] == '/')):
		return strclone("/")

	int slash = length - 1
	while ((slash >= 0) & (path[slash] != '/')):
		slash = slash - 1

	if (slash < 0):
		return strclone(".")

	while ((slash > 0) & (path[slash - 1] == '/')):
		slash = slash - 1

	if (slash == 0):
		return strclone("/")

	return path_clone_range(path, slash)


int path_exists(char* path):
	int file = open(path, 0, 0)
	if (file < 0):
		return 0
	close(file)
	return 1
