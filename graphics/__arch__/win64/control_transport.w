# graphics.control socket on Windows: an AF_UNIX stream client through
# Winsock (Windows 10 1803+ ships AF_UNIX in ws2_32). Compile-checked
# only: wdrive itself is a Linux tool today (docs/projects/wdrive.md,
# "Limitations"). Readiness is a zero-timeout select(), so the frame
# loop never blocks; writes loop until the whole response is out.
import lib.lib
import lib.memory

c_lib "ws2_32.dll"
extern int WSAStartup(int version, char* data)
extern int socket(int family, int kind, int protocol)
extern int connect(int s, char* addr, int length)
extern int recv(int s, char* buf, int length, int flags)
extern int send(int s, char* buf, int length, int flags)
extern int select(int nfds, char* readfds, char* writefds, char* exceptfds, char* timeout)
extern int closesocket(int s)


int gfx_control_wsa_started


int gfx_control_transport_connect(char* path):
	if (gfx_control_wsa_started == 0):
		# WSADATA is 408 bytes on win64; 2.2 = 0x0202.
		char* data = cast(char*, malloc(512))
		if (WSAStartup(514, data) != 0):
			free(data)
			return 0 - 1
		free(data)
		gfx_control_wsa_started = 1
	int n = strlen(path)
	if (n > 107): return 0 - 1
	# SOCKADDR_UN: u16 sun_family (AF_UNIX = 1), char sun_path[108].
	char* addr = cast(char*, malloc(110))
	for i in range(110): addr[i] = 0
	addr[0] = 1
	for i in range(n): addr[2 + i] = path[i]
	int s = socket(1, 1, 0)
	if ((s == 0) || (s == 0 - 1)):
		free(addr)
		return 0 - 1
	if (connect(s, addr, 2 + n + 1) != 0):
		closesocket(s)
		free(addr)
		return 0 - 1
	free(addr)
	return s


int gfx_control_transport_readable(int fd):
	# fd_set: u32 fd_count (padded to 8) then SOCKET fd_array[64];
	# timeval: two 32-bit longs, zero = poll.
	char* set = cast(char*, malloc(8 + 8 * 64))
	char* timeout = cast(char*, malloc(8))
	for i in range(8): timeout[i] = 0
	save_int32(set, 1)
	save_int32(set + 4, 0)
	save_int(set + 8, fd)
	int ready = select(0, set, cast(char*, 0), cast(char*, 0), timeout)
	free(set)
	free(timeout)
	return ready != 0


int gfx_control_transport_recv(int fd, char* buf, int n):
	int k = (recv(fd, buf, n, 0) << 32) >> 32
	# recv returns a 32-bit int: sign-extend SOCKET_ERROR (-1).
	if (k < 0): return 0 - 1
	return k


int gfx_control_transport_send(int fd, char* buf, int n):
	int sent = 0
	while (sent < n):
		int k = (send(fd, buf + sent, n - sent, 0) << 32) >> 32
		if (k <= 0): return 0 - 1
		sent = sent + k
	return n


void gfx_control_transport_close(int fd):
	closesocket(fd)
