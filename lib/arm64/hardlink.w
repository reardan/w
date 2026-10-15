# linkat(2), flags=0.
import lib.lib

int shell_hardlink(char* source, char* dest):
	return syscall7(37, -100, source, -100, cast(int, dest), 0, 0)
