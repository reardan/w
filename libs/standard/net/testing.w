# Loopback fixture-server helpers shared by the network tests: the
# parent binds an ephemeral 127.0.0.1 listener before forking (so it
# knows the port), the child scripts one server behavior, and the parent
# drives the client, then reaps the child with net_test_finish.
import lib.lib
import lib.assert
import lib.net
import lib.str
import structures.string


# Exits with the translated syscall error when result < 0.
void net_test_assert_ok(char* name, int result):
	if (result < 0):
		print_string(name, c" failed")
		translate_syscall_failure(result)
		exit(1)


# Listener on 127.0.0.1 with a kernel-assigned port (stored in out_port).
int net_test_listen(int* out_port):
	int listener = socket_tcp_ipv4()
	net_test_assert_ok(c"tcp socket", listener)
	net_test_assert_ok(c"reuseaddr", socket_set_reuseaddr(listener))
	net_test_assert_ok(c"bind", socket_bind_ipv4(listener, ip4_from_string(c"127.0.0.1"), 0))
	net_test_assert_ok(c"listen", socket_listen(listener, 8))
	sockaddr_in bound
	net_test_assert_ok(c"getsockname", socket_getsockname_ipv4(listener, &bound))
	*out_port = net_htons(bound.port)
	return listener


# "scheme://127.0.0.1:port/path" (malloc'd).
char* net_test_url(char* scheme, int port, char* path):
	string s = f"{scheme}://127.0.0.1:{port}{path}"
	return s.data


# "host:port" (malloc'd).
char* net_test_authority(char* host, int port):
	string s = f"{host}:{port}"
	return s.data


# 1 when needle occurs in hay.
int net_test_contains(char* hay, char* needle):
	return index_of(hay, needle) >= 0


# Sends every byte, SIGPIPE-proof: an early peer close (the fail-closed
# tests) must not kill the fixture child. Gives up on the first error.
void net_test_send_all(int fd, char* data, int n):
	int total = 0
	while (total < n):
		int got = socket_send(fd, data + total, n - total, msg_nosignal())
		if (got <= 0):
			return
		total = total + got


void net_test_send_text(int fd, char* text):
	net_test_send_all(fd, text, strlen(text))


# Reads until the peer closes (or a recv timeout fires), so a child never
# exits while the client still expects the connection to be open.
void net_test_drain(int fd):
	char* scratch = malloc(1024)
	int got = read(fd, scratch, 1024)
	while (got > 0):
		got = read(fd, scratch, 1024)
	free(scratch)


# Reads until EOF into a malloc'd NUL-terminated string.
char* net_test_read_all(int fd):
	string_builder* out = string_new()
	char* buf = malloc(4096)
	int got = read(fd, buf, 4096)
	while (got > 0):
		string_append_bytes(out, buf, got)
		got = read(fd, buf, 4096)
	free(buf)
	char* text = out.data
	free(out)
	return text


# Sends one raw request to 127.0.0.1:port and returns everything the
# server says before closing (malloc'd).
char* net_test_exchange(int port, char* request):
	int fd = socket_tcp_ipv4()
	asserts(c"socket", fd >= 0)
	socket_set_recv_timeout(fd, 10000)
	asserts(c"connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) >= 0)
	net_test_send_text(fd, request)
	char* text = net_test_read_all(fd)
	close(fd)
	return text


# Offset just past the CRLFCRLF that ends a request head, or -1.
int net_test_head_end(char* buf, int total):
	int i = 0
	while (i + 3 < total):
		if ((buf[i] == 13) && (buf[i + 1] == 10) && (buf[i + 2] == 13) && (buf[i + 3] == 10)):
			return i + 4
		i = i + 1
	return (-1)


# Consumes one request head (through CRLFCRLF, EOF, the recv timeout or
# 8 KiB) so a child can start responding.
void net_test_read_head(int fd):
	char* buf = malloc(8192)
	int total = 0
	while (total < 8192):
		int got = read(fd, buf + total, 8192 - total)
		if (got <= 0):
			break
		total = total + got
		if (net_test_head_end(buf, total) >= 0):
			break
	free(buf)


# Reaps the fixture child, closes the listener (when >= 0) and asserts
# the child exited cleanly.
void net_test_finish(int pid, int listener):
	int status = 0
	wait4(pid, &status, 0, 0)
	if (listener >= 0):
		close(listener)
	if (status != 0):
		print2(c"fixture child status: ")
		println2(itoa(status))
	assert_equal(0, status)
