# Native socket identity/control ABI. All failures are negative native errno.
import lib.linux


int socket_identity_supported():
	return 1


int socket_identity_getpeername(int fd, char* addr, int32* length):
	return syscall(31, fd, addr, length)


int socket_identity_shutdown(int fd, int direction):
	return syscall(134, fd, direction, 0)


# XNU LOCAL_PEERCRED (SOL_LOCAL = 0), struct xucred from sys/ucred.h.
# Darwin exposes uid and primary group here; pid is explicitly unavailable.
int socket_identity_credentials(int fd, int* pid, int* uid, int* gid):
	char[76] cred
	int32 length = 76
	int rc = sys_getsockopt(fd, 0, 1, cast(int, &cred[0]), cast(int, &length))
	if (rc < 0): return rc
	char* raw = cast(char*, &cred[0])
	if ((length != 76) || (load_int32(raw) != 0)): return -45
	if (load_int16(raw + 8) < 1): return -45
	*pid = -1
	*uid = cast(int, *cast(uint32*, raw + 4))
	*gid = cast(int, *cast(uint32*, raw + 12))
	return 0
