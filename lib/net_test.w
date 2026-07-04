import lib.testing
import lib.net
import lib.http


void assert_syscall_ok(char* name, int result):
	if (result < 0):
		print_string(name, c" failed")
		translate_syscall_failure(result)
		exit(1)


void test_net_byte_order():
	assert_equal_hex(24862, net_htons(7777))
	assert_equal_hex(16777343, net_htonl(ip4_from_string(c"127.0.0.1")))


void test_sockaddr_in_init():
	sockaddr_in addr
	sockaddr_in_init(&addr, ip4_from_string(c"127.0.0.1"), 7777)
	assert_equal(af_inet(), addr.family)
	assert_equal_hex(24862, addr.port)
	assert_equal_hex(16777343, addr.ip_address)
	assert_equal(0, addr.zero1)
	assert_equal(0, addr.zero2)


void test_socketpair_round_trip():
	int* fds = malloc(__word_size__ * 2)
	assert_syscall_ok(c"socket_pair", socket_pair(fds))

	char* want = c"ping"
	assert_equal(strlen(want), write_string(fds[0], want))

	char* got = malloc(16)
	int read_count = read(fds[1], got, 16)
	assert_equal(strlen(want), read_count)
	got[read_count] = 0
	assert_strings_equal(want, got)

	close(fds[0])
	close(fds[1])
	free(got)
	free(fds)


void test_tcp_bind_listen_ephemeral_loopback():
	int server = socket_tcp_ipv4()
	asserts(c"tcp socket failed", server >= 0)
	assert_syscall_ok(c"socket_set_reuseaddr", socket_set_reuseaddr(server))
	assert_syscall_ok(c"socket_bind_ipv4", socket_bind_ipv4(server, ip4_from_string(c"127.0.0.1"), 0))
	assert_syscall_ok(c"socket_listen", socket_listen(server, 1))
	close(server)


void test_tcp_connect_accept_loopback():
	int server = socket_tcp_ipv4()
	asserts(c"server tcp socket failed", server >= 0)
	assert_syscall_ok(c"socket_set_reuseaddr", socket_set_reuseaddr(server))
	assert_syscall_ok(c"socket_bind_ipv4", socket_bind_ipv4(server, ip4_from_string(c"127.0.0.1"), 0))
	assert_syscall_ok(c"socket_listen", socket_listen(server, 1))

	sockaddr_in bound_addr
	assert_syscall_ok(c"socket_getsockname_ipv4", socket_getsockname_ipv4(server, &bound_addr))
	int port = net_htons(bound_addr.port)
	asserts(c"ephemeral port not assigned", port > 0)

	int client = socket_tcp_ipv4()
	asserts(c"client tcp socket failed", client >= 0)
	assert_syscall_ok(c"socket_connect_ipv4", socket_connect_ipv4(client, ip4_from_string(c"127.0.0.1"), port))

	int accepted = socket_accept_connection(server)
	asserts(c"socket_accept_connection failed", accepted >= 0)

	char* client_message = c"c"
	assert_equal(strlen(client_message), write_string(client, client_message))
	char* server_buf = malloc(2)
	int server_read_count = read(accepted, server_buf, 1)
	assert_equal(strlen(client_message), server_read_count)
	server_buf[server_read_count] = 0
	assert_strings_equal(client_message, server_buf)

	char* server_message = c"s"
	assert_equal(strlen(server_message), write_string(accepted, server_message))
	char* client_buf = malloc(2)
	int client_read_count = read(client, client_buf, 1)
	assert_equal(strlen(server_message), client_read_count)
	client_buf[client_read_count] = 0
	assert_strings_equal(server_message, client_buf)

	close(accepted)
	close(client)
	close(server)
	free(server_buf)
	free(client_buf)


void test_udp_send_loopback():
	int sockfd = socket_udp_ipv4()
	asserts(c"udp socket failed", sockfd >= 0)
	char* message = c"ping"
	int sent = socket_send_to_ipv4(sockfd, message, strlen(message), 0, ip4_from_string(c"127.0.0.1"), 9)
	assert_equal(strlen(message), sent)
	close(sockfd)


void test_http_response_headers():
	int* fds = malloc(__word_size__ * 2)
	assert_syscall_ok(c"socket_pair", socket_pair(fds))

	char* expected = c"HTTP/1.1 200 OK\x0d\x0aServer: whttp\x0d\x0aContent-Type: text/plain\x0d\x0aContent-Length: 5\x0d\x0aConnection: close\x0d\x0a\x0d\x0a"
	http_write_ok_headers(fds[0], c"text/plain", 5)

	int expected_length = strlen(expected)
	char* got = malloc(expected_length + 17)
	int read_count = read(fds[1], got, expected_length + 16)
	assert_equal(expected_length, read_count)
	got[read_count] = 0
	assert_strings_equal(expected, got)

	close(fds[0])
	close(fds[1])
	free(got)
	free(fds)
