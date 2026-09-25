# lib/dir.w's directory read for this target: WASI preview1 exposes no
# directory listing here (getdents returns -1), so every directory
# reads as unopenable.


int dir_platform_read(char* path, list[char*] names, list[int] kinds):
	return -1
