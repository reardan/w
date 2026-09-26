# lib/dir.w's directory read for this target, over
# FindFirstFileA/FindNextFileA. WIN32_FIND_DATAA is 320 bytes:
# dwFileAttributes at 0, cFileName at 44; FILE_ATTRIBUTE_DIRECTORY =
# 16. A directory reads as kind 4, anything else as 8 (a regular file).
import lib.lib


int dir_platform_read(char* path, list[char*] names, list[int] kinds):
	char* pattern = strjoin(path, c"/*")
	char* find_data = malloc(320)
	int handle = FindFirstFileA(pattern, find_data)
	free(pattern)
	if (handle == -1):
		free(find_data)
		return -1
	while (1):
		names.push(strclone(find_data + 44))
		if (load_int32(find_data) & 16): kinds.push(4)
		else: kinds.push(8)
		if (FindNextFileA(handle, find_data) == 0): break
	FindClose(handle)
	free(find_data)
	return 0
