# link(2): no replacement and no symlink dereference. Returns -errno.
import lib.lib

int shell_hardlink(char* source, char* dest):
	return syscall(9, source, dest, 0)
