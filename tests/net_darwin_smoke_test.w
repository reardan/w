# Darwin socket smoke test (plan 11 phase 2 darwin socket audit,
# issue #200): exercises the per-arch socket ABI from
# lib/__arch__/arm64_darwin/socket_abi.w end to end - sockaddr_in
# writes (connect/bind), kernel-filled sockaddr_in reads (getsockname,
# recvfrom), O_NONBLOCK via fcntl, and a full plaintext HTTP GET over
# loopback through libs/standard/web/http_client.w (nonblocking
# connect, EINPROGRESS, poll timeouts, SO_NOSIGPIPE).
#
# TO RUN ON A MAC: compile with `./wbuild net_darwin` (Linux CI only
# cross-compiles it as a build guard), then execute the binary
# natively with:
#     tools/mac/run_darwin_tests.sh bin/net_darwin_smoke_test
# It is part of that script's default set. The same source also runs
# on Linux targets, so the logic itself stays CI-covered.
import lib.testing
import lib.net
import structures.string
import libs.standard.web.http_client


void net_smoke_assert_ok(char* name, int result):
	if (result < 0):
		print_string(name, c" failed")
		translate_syscall_failure(result)
		exit(1)


int net_smoke_listen(int* out_port):
	int listener = socket_tcp_ipv4()
	net_smoke_assert_ok(c"tcp socket", listener)
	net_smoke_assert_ok(c"reuseaddr", socket_set_reuseaddr(listener))
	net_smoke_assert_ok(c"bind", socket_bind_ipv4(listener, ip4_from_string(c"127.0.0.1"), 0))
	net_smoke_assert_ok(c"listen", socket_listen(listener, 4))
	sockaddr_in bound
	net_smoke_assert_ok(c"getsockname", socket_getsockname_ipv4(listener, &bound))
	# The kernel filled this sockaddr_in: the portable family accessor
	# must see AF_INET on every target layout.
	assert_equal(af_inet(), sockaddr_in_family(&bound))
	*out_port = net_htons(bound.port)
	return listener


void test_tcp_sockaddr_round_trip():
	int port = 0
	int listener = net_smoke_listen(&port)
	asserts(c"ephemeral port not assigned", port > 0)

	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		char* buf = malloc(16)
		int got = read(conn, buf, 4)
		if (got != 4):
			exit(1)
		if (socket_send(conn, buf, got, msg_nosignal()) != got):
			exit(1)
		close(conn)
		exit(0)

	# Blocking connect writes a sockaddr_in the kernel must accept.
	int client = socket_tcp_ipv4()
	net_smoke_assert_ok(c"client socket", client)
	net_smoke_assert_ok(c"connect", socket_connect_ipv4(client, ip4_from_string(c"127.0.0.1"), port))
	assert_equal(4, write(client, c"ping", 4))
	char* echo = malloc(16)
	int got = read(client, echo, 16)
	assert_equal(4, got)
	echo[got] = 0
	assert_strings_equal(c"ping", echo)
	free(echo)
	close(client)
	int status = 0
	wait4(pid, &status, 0, 0)
	close(listener)


void test_udp_recvfrom_sockaddr():
	int loopback = ip4_from_string(c"127.0.0.1")
	int receiver = socket_udp_ipv4()
	net_smoke_assert_ok(c"udp socket", receiver)
	net_smoke_assert_ok(c"udp bind", socket_bind_ipv4(receiver, loopback, 0))
	sockaddr_in bound
	net_smoke_assert_ok(c"getsockname", socket_getsockname_ipv4(receiver, &bound))
	int port = net_htons(bound.port)

	int sender = socket_udp_ipv4()
	net_smoke_assert_ok(c"udp sender", sender)
	assert_equal(4, socket_send_to_ipv4(sender, c"ping", 4, 0, loopback, port))

	char* got = malloc(16)
	sockaddr_in from
	int received = socket_recv_from_ipv4(receiver, got, 16, 0, &from)
	assert_equal(4, received)
	# Kernel-filled sender address parses on this target's layout.
	assert_equal(af_inet(), sockaddr_in_family(&from))
	assert_equal_hex(loopback, net_htonl(from.ip_address))
	free(got)
	close(sender)
	close(receiver)


void test_nonblocking_recv_eagain():
	int* fds = malloc(__word_size__ * 2)
	net_smoke_assert_ok(c"socketpair", socket_pair(fds))
	net_smoke_assert_ok(c"set nonblocking", socket_set_nonblocking(fds[1]))
	char* buf = malloc(8)
	# The per-target O_NONBLOCK really took effect: an empty read
	# reports this target's EAGAIN instead of blocking.
	assert_equal(0 - net_eagain(), socket_recv(fds[1], buf, 8, 0))
	close(fds[0])
	close(fds[1])
	free(buf)
	free(fds)


void test_http_get_loopback():
	int port = 0
	int listener = net_smoke_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		char* buf = malloc(4096)
		if (read(conn, buf, 4095) <= 0):
			exit(1)
		char* response = c"HTTP/1.1 200 OK\x0d\x0aContent-Length: 12\x0d\x0a\x0d\x0asmoke passed"
		socket_send(conn, response, strlen(response), msg_nosignal())
		char* scratch = malloc(64)
		while (read(conn, scratch, 64) > 0):
			scratch[0] = 0
		exit(0)

	string_builder* target = string_new()
	string_append(target, c"http://127.0.0.1:")
	string_append_int(target, port)
	string_append(target, c"/smoke")
	http_req* req = http_req_new(c"GET", target.data)
	req.timeout_ms = 5000
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"smoke passed", resp.body)
	http_response_free(resp)
	http_req_free(req)
	string_free(target)
	http_client_close_idle()
	int status = 0
	wait4(pid, &status, 0, 0)
	close(listener)
