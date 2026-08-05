# wbuild: x64
# End-to-end test for lib/net.w's AF_UNIX surface (issue #231 wbuildd
# stage-1 prerequisite, docs/projects/wbuildd.md par. 2.3): a real
# fork()ed echo client against an in-process server over a pid-scoped
# socket path under bin/ (the fixture pattern of
# libs/standard/web/https_e2e_test.w and tests/vcs_cas_test.w), plus
# the sockaddr_un layout, the crashed-predecessor stale-socket-file
# takeover, and the live-server-is-not-stolen guarantee of
# socket_bind_unix_replacing_stale.
import lib.testing
import lib.net
import structures.string


# The pid-and-word-size-scoped socket path prefix, so the 32- and
# 64-bit twins can run in parallel without colliding.
char* us_root_cache
char* us_root():
	if (us_root_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/unix_socket_test_")
		string_append_int(p, getpid())
		string_append_char(p, '_')
		string_append_int(p, __word_size__ * 8)
		us_root_cache = p.data
		free(p)
	return us_root_cache


# "<us_root()>_<suffix>.sock": one socket path per test function.
char* us_sock(char* suffix):
	string_builder* p = string_new()
	string_append(p, us_root())
	string_append_char(p, '_')
	string_append(p, suffix)
	string_append(p, c".sock")
	char* result = p.data
	free(p)
	return result


void us_assert_ok(char* what, int result):
	if (result < 0):
		print_string(what, c" failed")
		translate_syscall_failure(result)
		exit(1)


char* us_too_long_path():
	string_builder* p = string_new()
	int i = 0
	while (i <= SOCKADDR_UN_PATH_MAX()):
		string_append_char(p, 'x')
		i = i + 1
	char* result = p.data
	free(p)
	return result


void test_sockaddr_un_layout():
	char* path = c"bin/some.sock"
	char* addr = malloc(SOCKADDR_UN_SIZE())
	int addrlen = sockaddr_un_init(addr, path)
	# family word + path + NUL.
	assert_equal(2 + strlen(path) + 1, addrlen)
	assert_equal(socket_abi_family_word(af_unix()), load_int16(addr))
	assert_strings_equal(path, &addr[2])
	# NUL-padded through the last byte.
	assert_equal(0, addr[2 + strlen(path)])
	assert_equal(0, addr[SOCKADDR_UN_SIZE() - 1])
	free(addr)


void test_sockaddr_un_rejects_too_long_path():
	char* long_path = us_too_long_path()
	char* addr = malloc(SOCKADDR_UN_SIZE())
	assert_equal(0 - 22, sockaddr_un_init(addr, long_path))
	# The bind/connect wrappers surface the same failure.
	int sockfd = socket_unix_stream()
	us_assert_ok(c"socket_unix_stream", sockfd)
	assert_equal(0 - 22, socket_bind_unix(sockfd, long_path))
	assert_equal(0 - 22, socket_connect_unix(sockfd, long_path))
	close(sockfd)
	free(addr)
	free(long_path)


# A real echo roundtrip: fork()ed client, in-process server.
void test_unix_echo_roundtrip():
	char* path = us_sock(c"echo")
	int server = socket_listen_unix_path(path, 4)
	us_assert_ok(c"socket_listen_unix_path", server)

	int child = fork()
	if (child == 0):
		# Client: connect, send "ping", expect "pong" back. Failures
		# surface as distinct nonzero exit codes through wait4.
		int client = socket_connect_unix_path(path)
		if (client < 0):
			exit(2)
		if (write(client, c"ping", 4) != 4):
			exit(3)
		char* reply = malloc(8)
		int got = read(client, reply, 8)
		if (got != 4):
			exit(4)
		reply[got] = 0
		if (strcmp(reply, c"pong") != 0):
			exit(5)
		close(client)
		exit(0)
	asserts(c"fork failed", child > 0)

	int accepted = socket_accept_connection(server)
	us_assert_ok(c"socket_accept_connection", accepted)
	char* request = malloc(8)
	int got = read(accepted, request, 8)
	assert_equal(4, got)
	request[got] = 0
	assert_strings_equal(c"ping", request)
	assert_equal(4, write(accepted, c"pong", 4))

	# Pre-zero: the kernel writes a 32-bit status, W ints are
	# word-sized (the lib/process.w convention).
	int child_status = 0
	assert_equal(child, wait4(child, &child_status, 0, 0))
	assert_equal(0, child_status)

	close(accepted)
	close(server)
	us_assert_ok(c"unlink", unlink(path))
	free(request)
	free(path)


# A crashed server's leftover socket file blocks a plain bind but is
# unlinked and claimed by socket_bind_unix_replacing_stale.
void test_unix_stale_socket_file_replaced():
	char* path = us_sock(c"stale")
	int first = socket_unix_stream()
	us_assert_ok(c"socket_unix_stream", first)
	us_assert_ok(c"socket_bind_unix", socket_bind_unix(first, path))
	# close() does not unlink a bound socket path: this is the crashed
	# predecessor, and its socket file is now stale.
	close(first)

	int second = socket_unix_stream()
	us_assert_ok(c"socket_unix_stream", second)
	asserts(c"plain bind on a stale path should fail", socket_bind_unix(second, path) < 0)
	us_assert_ok(c"socket_bind_unix_replacing_stale", socket_bind_unix_replacing_stale(second, path))
	us_assert_ok(c"socket_listen", socket_listen(second, 1))

	close(second)
	us_assert_ok(c"unlink", unlink(path))
	free(path)


# A live server's path must NOT be stolen: the probe connect answers,
# so the would-be thief keeps the original bind error and the listener
# keeps working.
void test_unix_live_server_not_stolen():
	char* path = us_sock(c"live")
	int server = socket_listen_unix_path(path, 4)
	us_assert_ok(c"socket_listen_unix_path", server)

	int thief = socket_unix_stream()
	us_assert_ok(c"socket_unix_stream", thief)
	asserts(c"live path should not be stolen", socket_bind_unix_replacing_stale(thief, path) < 0)
	close(thief)

	# The thief's probe connection is first in the accept queue; it is
	# already closed, so it reads as immediate EOF.
	int probe = socket_accept_connection(server)
	us_assert_ok(c"accept of probe connection", probe)
	char* buf = malloc(8)
	assert_equal(0, read(probe, buf, 8))
	close(probe)

	# The listener still serves a real client after the failed theft.
	int client = socket_connect_unix_path(path)
	us_assert_ok(c"socket_connect_unix_path", client)
	int accepted = socket_accept_connection(server)
	us_assert_ok(c"socket_accept_connection", accepted)
	assert_equal(2, write(client, c"hi", 2))
	int got = read(accepted, buf, 8)
	assert_equal(2, got)
	buf[got] = 0
	assert_strings_equal(c"hi", buf)

	close(client)
	close(accepted)
	close(server)
	us_assert_ok(c"unlink", unlink(path))
	free(buf)
	free(path)
