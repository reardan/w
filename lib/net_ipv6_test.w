# wbuild: x64
# wbuild: step="bin/net_ipv6_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# IPv6 sockets in lib/net.w (stdlib parity P3.10). Hosts without IPv6
# (containers and sandboxes such as gVisor report EAFNOSUPPORT, others
# lack a ::1 address) skip the live loopback checks with a note on
# stderr; the layout, ordering and IPv4-fallback checks always run.
import lib.testing
import lib.net
import lib.http


int net_ipv6_test_skip_noted = 0


void net_ipv6_test_stderr(char* text):
	write(2, text, strlen(text))


# Returns 1 (after a one-time stderr note) when rc says this host has
# no IPv6; asserts on any other failure.
int net_ipv6_test_unavailable(char* what, int rc):
	if (rc >= 0): return 0
	if (net_ipv6_unavailable_error(rc)):
		if (net_ipv6_test_skip_noted == 0):
			# write(2) directly: print_error's string conversion allocates.
			net_ipv6_test_stderr(c"net_ipv6_test: no IPv6 loopback on this host (")
			net_ipv6_test_stderr(what)
			net_ipv6_test_stderr(c" errno ")
			char* code = itoa(0 - rc)
			net_ipv6_test_stderr(code)
			free(code)
			net_ipv6_test_stderr(c"); skipping live ::1 checks\n")
			net_ipv6_test_skip_noted = 1
		return 1
	print_string(what, c" failed")
	translate_syscall_failure(rc)
	asserts(what, 0)
	return 0


void test_ipv6_abi_values():
	assert_equal(10, net_af_inet6())
	assert_equal(41, socket_abi_ipproto_ipv6())
	assert_equal(26, socket_abi_ipv6_v6only())
	assert_equal(97, net_eafnosupport())
	assert_equal(28, sockaddr_in6_size)
	asserts(c"sockaddr_in6 holds 28 bytes", sizeof(sockaddr_in6) >= 28)


void test_sockaddr_in6_layout():
	char* ip = cast(char*, malloc(16))
	for i in range(16): ip[i] = 0x20 + i
	sockaddr_in6 addr
	sockaddr_in6_init(&addr, ip, 8080, 3)
	char* raw = sockaddr_in6_bytes(&addr)
	# Linux: 16-bit family, big-endian port, zero flowinfo.
	assert_equal(10, raw[0] & 255)
	assert_equal(0, raw[1] & 255)
	assert_equal(0x1f, raw[2] & 255)
	assert_equal(0x90, raw[3] & 255)
	for i in range(4): assert_equal(0, raw[4 + i])
	for i in range(16): assert_equal(0x20 + i, raw[8 + i] & 255)
	assert_equal(3, raw[24] & 255)
	assert_equal(0, raw[25] | raw[26] | raw[27])
	assert_equal(net_af_inet6(), sockaddr_in6_family(&addr))
	assert_equal(8080, sockaddr_in6_port(&addr))
	assert_equal(3, sockaddr_in6_scope_id(&addr))
	char* back = cast(char*, malloc(16))
	sockaddr_in6_address(&addr, back)
	for i in range(16): assert_equal(ip[i], back[i])
	# A null address is the unspecified address ::, port 65535 edge.
	sockaddr_in6_init(&addr, 0, 65535, 0)
	assert_equal(65535, sockaddr_in6_port(&addr))
	for i in range(16): assert_equal(0, raw[8 + i])
	net_ipv6_loopback(back)
	for i in range(15): assert_equal(0, back[i])
	assert_equal(1, back[15])
	free(back)
	free(ip)


void net_ipv6_test_v6(net_address* a, int last):
	char* ip = cast(char*, malloc(16))
	for i in range(16): ip[i] = 0
	ip[0] = 0x20
	ip[15] = last
	net_address_set_ipv6(a, ip, 0)
	free(ip)


# Encodes a list as "61 42 ..." (family and last octet) for asserts.
char* net_ipv6_test_order(net_address* addrs, int count):
	char* out = cast(char*, malloc(count * 4 + 1))
	int pos = 0
	for i in range(count):
		if (net_address_is_ipv6(&addrs[i])):
			out[pos] = '6'
			out[pos + 1] = '0' + (addrs[i].ipv6_3 & 255)
		else:
			out[pos] = '4'
			out[pos + 1] = '0' + (addrs[i].ipv4 & 255)
		out[pos + 2] = ' '
		pos += 3
	if (pos > 0): pos -= 1
	out[pos] = 0
	return out


void net_ipv6_test_expect_order(net_address* addrs, int count, char* want):
	net_addresses_interleave(addrs, count)
	char* got = net_ipv6_test_order(addrs, count)
	assert_strings_equal(want, got)
	free(got)


void test_addresses_interleave():
	net_address* a = cast(net_address*, malloc(sizeof(net_address) * 6))
	# A records first from the resolver: IPv6 still leads.
	net_address_set_ipv4(&a[0], 1)
	net_address_set_ipv4(&a[1], 2)
	net_ipv6_test_v6(&a[2], 3)
	net_ipv6_test_v6(&a[3], 4)
	net_ipv6_test_expect_order(a, 4, c"63 41 64 42")
	# Longer family's leftovers go last, in resolver order.
	net_address_set_ipv4(&a[0], 1)
	net_ipv6_test_v6(&a[1], 2)
	net_ipv6_test_v6(&a[2], 3)
	net_ipv6_test_v6(&a[3], 4)
	net_address_set_ipv4(&a[4], 5)
	net_ipv6_test_v6(&a[5], 6)
	net_ipv6_test_expect_order(a, 6, c"62 41 63 45 64 66")
	# Single family lists and singletons are unchanged.
	net_address_set_ipv4(&a[0], 3)
	net_address_set_ipv4(&a[1], 1)
	net_address_set_ipv4(&a[2], 2)
	net_ipv6_test_expect_order(a, 3, c"43 41 42")
	net_ipv6_test_v6(&a[0], 9)
	net_ipv6_test_expect_order(a, 1, c"69")
	net_ipv6_test_expect_order(a, 0, c"")
	free(a)


void test_address_equal_and_copy():
	net_address a
	net_address b
	net_ipv6_test_v6(&a, 7)
	net_address_copy(&a, &b)
	asserts(c"copy equal", net_address_equal(&a, &b))
	char* bytes = cast(char*, malloc(16))
	net_address_ipv6_bytes(&b, bytes)
	assert_equal(0x20, bytes[0] & 255)
	for i in range(1, 15): assert_equal(0, bytes[i])
	assert_equal(7, bytes[15] & 255)
	# High-bit bytes survive the big-endian packing on 32-bit ints.
	for i in range(16): bytes[i] = 0xf0 + i
	net_address_set_ipv6(&b, bytes, 0)
	char* back = cast(char*, malloc(16))
	net_address_ipv6_bytes(&b, back)
	for i in range(16): assert_equal(bytes[i] & 255, back[i] & 255)
	free(back)
	free(bytes)
	b.scope_id = 2
	asserts(c"scope differs", net_address_equal(&a, &b) == 0)
	net_address_set_ipv4(&b, 7)
	asserts(c"family differs", net_address_equal(&a, &b) == 0)
	net_address_set_ipv4(&a, 7)
	asserts(c"ipv4 equal", net_address_equal(&a, &b))


void test_tcp_echo_ipv6_loopback():
	char* loopback = cast(char*, malloc(16))
	net_ipv6_loopback(loopback)
	int server = socket_tcp_ipv6()
	if (net_ipv6_test_unavailable(c"socket(AF_INET6)", server)):
		free(loopback)
		return
	socket_set_reuseaddr(server)
	asserts(c"IPV6_V6ONLY", socket_set_ipv6_only(server, 1) >= 0)
	int rc = socket_bind_ipv6(server, loopback, 0)
	if (net_ipv6_test_unavailable(c"bind([::1]:0)", rc)):
		close(server)
		free(loopback)
		return
	asserts(c"listen", socket_listen(server, 1) >= 0)
	sockaddr_in6 bound
	asserts(c"getsockname", socket_getsockname_ipv6(server, &bound) >= 0)
	assert_equal(net_af_inet6(), sockaddr_in6_family(&bound))
	int port = sockaddr_in6_port(&bound)
	asserts(c"ephemeral port", port > 0)

	io_result r
	int client = net_connect6_timeout_checked(loopback, port, 0, 2000, &r)
	asserts(c"connect [::1]", client >= 0)
	socket_set_blocking(client)
	sockaddr_in6 peer
	int conn = socket_accept_connection_from_ipv6(server, &peer)
	asserts(c"accept", conn >= 0)
	assert_equal(net_af_inet6(), sockaddr_in6_family(&peer))
	char* peer_ip = cast(char*, malloc(16))
	sockaddr_in6_address(&peer, peer_ip)
	for i in range(16): assert_equal(loopback[i], peer_ip[i])

	char* buf = cast(char*, malloc(16))
	assert_equal(4, socket_send(client, c"ping", 4, msg_nosignal()))
	int got = socket_recv(conn, buf, 16, 0)
	assert_equal(4, got)
	# Echo it back.
	assert_equal(4, socket_send(conn, buf, got, msg_nosignal()))
	got = socket_recv(client, buf, 16, 0)
	assert_equal(4, got)
	buf[got] = 0
	assert_strings_equal(c"ping", buf)

	# Plain blocking connect helper agrees.
	int second = socket_tcp_ipv6()
	asserts(c"connect plain", socket_connect_ipv6(second, loopback, port) >= 0)
	int conn2 = socket_accept_connection(server)
	asserts(c"accept 2", conn2 >= 0)
	close(conn2)
	close(second)

	close(conn)
	close(client)
	close(server)
	free(buf)
	free(peer_ip)
	free(loopback)


void test_udp_ipv6_loopback():
	char* loopback = cast(char*, malloc(16))
	net_ipv6_loopback(loopback)
	int receiver = socket_udp_ipv6()
	if (net_ipv6_test_unavailable(c"socket(AF_INET6, SOCK_DGRAM)", receiver)):
		free(loopback)
		return
	int rc = socket_bind_ipv6(receiver, loopback, 0)
	if (net_ipv6_test_unavailable(c"bind udp [::1]:0", rc)):
		close(receiver)
		free(loopback)
		return
	sockaddr_in6 bound
	asserts(c"getsockname", socket_getsockname_ipv6(receiver, &bound) >= 0)
	int port = sockaddr_in6_port(&bound)
	int sender = socket_udp_ipv6()
	asserts(c"sender bind", socket_bind_ipv6(sender, loopback, 0) >= 0)
	sockaddr_in6 sender_addr
	socket_getsockname_ipv6(sender, &sender_addr)
	assert_equal(5, socket_send_to_ipv6(sender, c"hello", 5, 0, loopback, port))
	char* buf = cast(char*, malloc(16))
	sockaddr_in6 from
	assert_equal(5, socket_recv_from_ipv6(receiver, buf, 16, 0, &from))
	assert_equal(sockaddr_in6_port(&sender_addr), sockaddr_in6_port(&from))
	assert_equal(net_af_inet6(), sockaddr_in6_family(&from))
	close(sender)
	close(receiver)
	free(buf)
	free(loopback)


# Happy-Eyeballs-lite fallback: ::1 first (refused, or no IPv6 at all
# here), then 127.0.0.1 where the server actually listens.
void test_connect_addresses_falls_back_to_ipv4():
	int server = socket_tcp_ipv4()
	asserts(c"ipv4 socket", server >= 0)
	socket_set_reuseaddr(server)
	asserts(c"bind", socket_bind_ipv4(server, ip4_from_string(c"127.0.0.1"), 0) >= 0)
	asserts(c"listen", socket_listen(server, 1) >= 0)
	sockaddr_in bound
	socket_getsockname_ipv4(server, &bound)
	int port = net_htons(bound.port)

	net_address* addrs = cast(net_address*, malloc(sizeof(net_address) * 2))
	net_address_set_ipv4(&addrs[0], ip4_from_string(c"127.0.0.1"))
	char* loopback = cast(char*, malloc(16))
	net_ipv6_loopback(loopback)
	net_address_set_ipv6(&addrs[1], loopback, 0)
	net_addresses_interleave(addrs, 2)
	asserts(c"ipv6 first", net_address_is_ipv6(&addrs[0]))

	io_result r
	int fd = net_connect_addresses_timeout_checked(addrs, 2, port, 2000, &r)
	asserts(c"fallback connect", fd >= 0)
	assert_equal(IO_OK, r.status)
	int conn = socket_accept_connection(server)
	asserts(c"accept", conn >= 0)
	close(conn)
	close(fd)

	# Only the unreachable/refused IPv6 address: fails, r explains why.
	fd = net_connect_addresses_timeout_checked(addrs, 1, port, 2000, &r)
	assert_equal(-1, fd)
	asserts(c"error status", r.status != IO_OK)
	# Empty list fails without touching the network.
	assert_equal(-1, net_connect_addresses_timeout_checked(addrs, 0, port, 2000, &r))
	close(server)
	free(loopback)
	free(addrs)
