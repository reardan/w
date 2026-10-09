# No socket backend on this target. Generic checked operations report
# IO_UNSUPPORTED with native_error 0 before invoking these placeholders.
int socket_identity_supported():
	return 0


int socket_identity_getpeername(int fd, char* addr, int32* length):
	return -38


int socket_identity_shutdown(int fd, int direction):
	return -38


int socket_identity_credentials(int fd, int* pid, int* uid, int* gid):
	return -38
