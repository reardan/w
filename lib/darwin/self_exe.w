# lib/self_exe.w for Darwin: proc_info (336) with PROC_INFO_CALL_PIDINFO
# (2) and PROC_PIDPATHINFO (11) fills a buffer of
# PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) bytes with a NUL-terminated
# absolute path (xnu bsd/sys/proc_info.h).
char* self_exe_path():
	char* buffer = cast(char*, malloc(4096))
	for i in range(4096): buffer[i] = 0
	int status = syscall7(336, 2, getpid(), 11, 0, buffer, 4096)
	if ((status < 0) || (buffer[0] != '/')):
		free(buffer)
		return 0
	return buffer
