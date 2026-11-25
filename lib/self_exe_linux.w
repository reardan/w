# lib/self_exe.w for Linux and Android: the /proc/self/exe link.
char* self_exe_path():
	char* buffer = cast(char*, malloc(4096))
	int length = readlink(c"/proc/self/exe", buffer, 4095)
	if (length <= 0):
		free(buffer)
		return 0
	buffer[length] = 0
	return buffer
