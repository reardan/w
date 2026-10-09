# Native socket identity/control ABI. All failures are negative native errno.
import lib.linux


int socket_identity_supported():
	return 1


int socket_identity_getpeername(int fd, char* addr, int32* length):
	return syscall(368, fd, addr, length)


int socket_identity_shutdown(int fd, int direction):
	return syscall(373, fd, direction, 0)


import lib.socket_credentials_linux
