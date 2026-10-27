# lib/dir.w's directory read for this target, over
# FindFirstFileW/FindNextFileW (UTF-16 names, converted to UTF-8).
# WIN32_FIND_DATAW is 592 bytes: dwFileAttributes at 0, cFileName at 44;
# FILE_ATTRIBUTE_DIRECTORY = 16. A directory reads as kind 4, anything
# else as 8 (a regular file).
import lib.lib


int dir_platform_read(char* path, list[char*] names, list[int] kinds):
	char* pattern = strjoin(path, c"/*")
	char* wide = win_wide_path(pattern)
	free(pattern)
	if (wide == 0): return -1
	char* find_data = cast(char*, malloc(592))
	int handle = FindFirstFileW(wide, find_data)
	win_wide_free(wide)
	if (handle == -1):
		free(find_data)
		return -1
	while (1):
		char* name = win_utf8(find_data + 44)
		if (name != 0):
			names.push(strclone(name))
			win_wide_free(name)
			if (load_int32(find_data) & 16): kinds.push(4)
			else: kinds.push(8)
		if (cast(int32, FindNextFileW(handle, find_data)) == 0): break
	FindClose(handle)
	free(find_data)
	return 0
