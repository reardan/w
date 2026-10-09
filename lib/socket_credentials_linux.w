# Linux SO_PEERCRED carries three C ints, never three W words.
import lib.linux
import lib.memory


int socket_identity_credentials(int fd, int* pid, int* uid, int* gid):
	char[12] cred
	int32 length = 12
	int rc = sys_getsockopt(fd, 1, 17, cast(int, &cred[0]), cast(int, &length))
	if (rc < 0): return rc
	if (length != 12): return -95
	char* raw = cast(char*, &cred[0])
	*pid = load_int32(raw)
	*uid = cast(int, *cast(uint32*, raw + 4))
	*gid = cast(int, *cast(uint32*, raw + 8))
	return 0
