# wbuild: x64
# Offline tests for libs/standard/net/dns.w (issue #198). Wire-format
# coverage runs against hand-built byte fixtures; /etc/hosts and
# resolv.conf parsing runs against fixture strings and files under
# bin/ (never the real system files); the resolver network path runs
# against a forked mock DNS server on a loopback ephemeral port.
import lib.testing
import lib.file
import lib.net
import libs.standard.net.dns
import libs.standard.net.testing
import lib.hex


void dns_test_assert_bytes_equal(char* want, char* got, int length):
	for i in range(length): assert_equal(want[i] & 255, got[i] & 255)


int dns_test_put_u16(char* msg, int pos, int value):
	msg[pos] = (value >> 8) & 255
	msg[pos + 1] = value & 255
	return pos + 2


# Response fixture builder: question "a" A/IN, then cname_count CNAME
# records chaining single-letter names a -> b -> ..., then one A
# record 1.2.3.4 for the final name. id 0x1234, flags 0x8180.
char* dns_test_build_cname_chain(int cname_count, int* out_len):
	char* msg = cast(char*, malloc(1024))
	int pos = dns_test_put_u16(msg, 0, 0x1234)
	pos = dns_test_put_u16(msg, pos, 0x8180)
	pos = dns_test_put_u16(msg, pos, 1)
	pos = dns_test_put_u16(msg, pos, cname_count + 1)
	pos = dns_test_put_u16(msg, pos, 0)
	pos = dns_test_put_u16(msg, pos, 0)
	msg[pos] = 1
	msg[pos + 1] = 'a'
	msg[pos + 2] = 0
	pos = pos + 3
	pos = dns_test_put_u16(msg, pos, 1)
	pos = dns_test_put_u16(msg, pos, 1)
	for k in range(cname_count):
		msg[pos] = 1
		msg[pos + 1] = 'a' + k
		msg[pos + 2] = 0
		pos = pos + 3
		pos = dns_test_put_u16(msg, pos, 5)
		pos = dns_test_put_u16(msg, pos, 1)
		pos = dns_test_put_u16(msg, pos, 0)
		pos = dns_test_put_u16(msg, pos, 60)
		pos = dns_test_put_u16(msg, pos, 3)
		msg[pos] = 1
		msg[pos + 1] = 'a' + k + 1
		msg[pos + 2] = 0
		pos = pos + 3
	msg[pos] = 1
	msg[pos + 1] = 'a' + cname_count
	msg[pos + 2] = 0
	pos = pos + 3
	pos = dns_test_put_u16(msg, pos, 1)
	pos = dns_test_put_u16(msg, pos, 1)
	pos = dns_test_put_u16(msg, pos, 0)
	pos = dns_test_put_u16(msg, pos, 60)
	pos = dns_test_put_u16(msg, pos, 4)
	msg[pos] = 1
	msg[pos + 1] = 2
	msg[pos + 2] = 3
	msg[pos + 3] = 4
	pos = pos + 4
	*out_len = pos
	return msg


# A well-formed response to the example.com A query, id 0x1234, with
# one compressed A answer 93.184.216.34.
char* dns_test_response_a(int* out_len):
	return hex_decode_loose(c"12 34 81 80 00 01 00 01 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01 c0 0c 00 01 00 01 00 00 00 3c 00 04 5d b8 d8 22", out_len)


void test_dns_build_query_encoding():
	char* out = cast(char*, malloc(512))
	int length = dns_build_query(c"example.com", 0x1234, out, 512)
	int want_len = 0
	char* want = hex_decode_loose(c"12 34 01 00 00 01 00 00 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01", &want_len)
	assert_equal(want_len, length)
	dns_test_assert_bytes_equal(want, out, want_len)

	# A single trailing dot encodes identically.
	int dotted_len = dns_build_query(c"example.com.", 0x1234, out, 512)
	assert_equal(want_len, dotted_len)
	dns_test_assert_bytes_equal(want, out, want_len)
	free(want)
	free(out)


void test_dns_build_query_rejects_bad_names():
	char* out = cast(char*, malloc(512))
	asserts(c"empty name accepted", dns_build_query(c"", 1, out, 512) == 0)
	asserts(c"lone dot accepted", dns_build_query(c".", 1, out, 512) == 0)
	asserts(c"empty label accepted", dns_build_query(c"a..b", 1, out, 512) == 0)
	asserts(c"leading dot accepted", dns_build_query(c".a", 1, out, 512) == 0)
	asserts(c"double trailing dot accepted", dns_build_query(c"a..", 1, out, 512) == 0)

	# A 64-byte label is one over the limit.
	char* long_label = cast(char*, malloc(80))
	int i = 0
	while (i < 64):
		long_label[i] = 'a'
		i = i + 1
	long_label[64] = 0
	asserts(c"64-byte label accepted", dns_build_query(long_label, 1, out, 512) == 0)
	free(long_label)

	# Four 63-byte labels encode to 257 bytes, over the 255 cap.
	char* long_name = cast(char*, malloc(260))
	int pos = 0
	for part in range(4):
		if (part > 0):
			long_name[pos] = '.'
			pos = pos + 1
		i = 0
		while (i < 63):
			long_name[pos] = 'b'
			pos = pos + 1
			i = i + 1
	long_name[pos] = 0
	asserts(c"oversized name accepted", dns_build_query(long_name, 1, out, 512) == 0)
	free(long_name)

	# Output buffer too small for the encoded query.
	asserts(c"tiny buffer accepted", dns_build_query(c"example.com", 1, out, 20) == 0)
	free(out)


void test_dns_parse_response_a_record():
	int length = 0
	char* msg = dns_test_response_a(&length)
	int ip = 0
	assert_equal(dns_result_ok, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	assert_equal_hex(0x5db8d822, ip)

	# Name matching is case-insensitive and ignores a trailing dot.
	ip = 0
	assert_equal(dns_result_ok, dns_parse_response(msg, length, 0x1234, c"EXAMPLE.COM", &ip))
	assert_equal_hex(0x5db8d822, ip)
	ip = 0
	assert_equal(dns_result_ok, dns_parse_response(msg, length, 0x1234, c"example.com.", &ip))
	assert_equal_hex(0x5db8d822, ip)
	free(msg)


void test_dns_parse_response_cname_chain():
	# example.com CNAME cdn.example.com (compressed against the
	# question), then an A record for the CNAME target via a pointer
	# into the first answer's rdata.
	int length = 0
	char* msg = hex_decode_loose(c"12 34 81 80 00 01 00 02 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01 c0 0c 00 05 00 01 00 00 00 3c 00 06 03 63 64 6e c0 0c c0 29 00 01 00 01 00 00 00 3c 00 04 05 06 07 08", &length)
	int ip = 0
	assert_equal(dns_result_ok, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	assert_equal_hex(0x05060708, ip)
	free(msg)


void test_dns_parse_response_cname_depth_limit():
	int length = 0
	char* msg = dns_test_build_cname_chain(8, &length)
	int ip = 0
	assert_equal(dns_result_ok, dns_parse_response(msg, length, 0x1234, c"a", &ip))
	assert_equal_hex(0x01020304, ip)
	free(msg)

	# A ninth CNAME hop exceeds dns_max_cname_depth().
	msg = dns_test_build_cname_chain(9, &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"a", &ip))
	free(msg)


void test_dns_parse_response_truncation_bit():
	int length = 0
	char* msg = hex_decode_loose(c"12 34 83 80 00 00 00 00 00 00 00 00", &length)
	int ip = 0
	assert_equal(dns_result_truncated, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)


void test_dns_parse_response_header_negatives():
	int ip = 0
	int length = 0

	# Shorter than a header.
	char* msg = hex_decode_loose(c"12 34 81 80", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# Mismatched query id.
	msg = dns_test_response_a(&length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x9999, c"example.com", &ip))
	# Question name mismatch.
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"other.com", &ip))
	free(msg)

	# QR clear: a query, not a response.
	msg = hex_decode_loose(c"12 34 01 00 00 01 00 00 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# Non-zero opcode.
	msg = hex_decode_loose(c"12 34 89 80 00 01 00 00 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# RCODE 3 (NXDOMAIN).
	msg = hex_decode_loose(c"12 34 81 83 00 01 00 00 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# QDCOUNT != 1.
	msg = hex_decode_loose(c"12 34 81 80 00 02 00 00 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)


void test_dns_parse_response_malformed_names():
	int ip = 0
	int length = 0

	# Question name is a compression pointer to itself.
	char* msg = hex_decode_loose(c"12 34 81 80 00 01 00 00 00 00 00 00 c0 0c 00 01 00 01", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# Answer name is a label/pointer cycle: "a" then a pointer back to
	# the same label, looping forever without the hop cap.
	msg = hex_decode_loose(c"12 34 81 80 00 01 00 01 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01 01 61 c0 1d 00 01 00 01 00 00 00 3c 00 04 01 02 03 04", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# Label length runs past the end of the message.
	msg = hex_decode_loose(c"12 34 81 80 00 01 00 00 00 00 00 00 3f 61 61", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# Reserved label tag 0x40.
	msg = hex_decode_loose(c"12 34 81 80 00 01 00 00 00 00 00 00 40 61 00 00 01 00 01", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)


void test_dns_parse_response_malformed_records():
	int ip = 0
	int length = 0

	# RDLENGTH runs past the end of the message.
	char* msg = hex_decode_loose(c"12 34 81 80 00 01 00 01 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01 c0 0c 00 01 00 01 00 00 00 3c 00 20 5d b8 d8 22", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# An A record whose RDLENGTH is not 4.
	msg = hex_decode_loose(c"12 34 81 80 00 01 00 01 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01 c0 0c 00 01 00 01 00 00 00 3c 00 05 5d b8 d8 22 00", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# An answer for an unrelated name is skipped, leaving no result.
	msg = hex_decode_loose(c"12 34 81 80 00 01 00 01 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01 03 77 77 77 c0 0c 00 01 00 01 00 00 00 3c 00 04 05 06 07 08", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)

	# NOERROR with no answers resolves nothing.
	msg = hex_decode_loose(c"12 34 81 80 00 01 00 00 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01", &length)
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	free(msg)


void test_dns_parse_ipv4_literal():
	int ip = 0
	assert_equal(1, dns_parse_ipv4_literal(c"127.0.0.1", &ip))
	assert_equal_hex(0x7f000001, ip)
	assert_equal(1, dns_parse_ipv4_literal(c"0.0.0.0", &ip))
	assert_equal_hex(0, ip)
	assert_equal(1, dns_parse_ipv4_literal(c"1.2.3.4", &ip))
	assert_equal_hex(0x01020304, ip)
	assert_equal(1, dns_parse_ipv4_literal(c"255.255.255.255", &ip))

	asserts(c"octet 256 accepted", dns_parse_ipv4_literal(c"256.1.1.1", &ip) == 0)
	asserts(c"three parts accepted", dns_parse_ipv4_literal(c"1.2.3", &ip) == 0)
	asserts(c"five parts accepted", dns_parse_ipv4_literal(c"1.2.3.4.5", &ip) == 0)
	asserts(c"trailing dot accepted", dns_parse_ipv4_literal(c"1.2.3.4.", &ip) == 0)
	asserts(c"leading zero accepted", dns_parse_ipv4_literal(c"01.2.3.4", &ip) == 0)
	asserts(c"leading zero octet accepted", dns_parse_ipv4_literal(c"1.2.3.04", &ip) == 0)
	asserts(c"letters accepted", dns_parse_ipv4_literal(c"a.b.c.d", &ip) == 0)
	asserts(c"hostname accepted", dns_parse_ipv4_literal(c"example.com", &ip) == 0)
	asserts(c"empty accepted", dns_parse_ipv4_literal(c"", &ip) == 0)
	asserts(c"empty octet accepted", dns_parse_ipv4_literal(c"1..3.4", &ip) == 0)
	asserts(c"trailing space accepted", dns_parse_ipv4_literal(c"1.2.3.4 ", &ip) == 0)
	asserts(c"four digit octet accepted", dns_parse_ipv4_literal(c"1234.1.1.1", &ip) == 0)


void test_dns_hosts_lookup_text():
	char* hosts = c"# fixture hosts file\x0a127.0.0.1\x09localhost\x0a::1 ip6-localhost\x0a93.184.216.34 example.com www.example.com # comment\x0a10.0.0.7 short\x0a"
	int ip = 0
	assert_equal(1, dns_hosts_lookup_text(hosts, c"localhost", &ip))
	assert_equal_hex(0x7f000001, ip)
	assert_equal(1, dns_hosts_lookup_text(hosts, c"example.com", &ip))
	assert_equal_hex(0x5db8d822, ip)
	# Aliases and case-insensitive matching.
	assert_equal(1, dns_hosts_lookup_text(hosts, c"WWW.Example.COM", &ip))
	assert_equal_hex(0x5db8d822, ip)
	assert_equal(1, dns_hosts_lookup_text(hosts, c"short", &ip))
	assert_equal_hex(0x0a000007, ip)
	# IPv6-only entries never match an IPv4 lookup.
	assert_equal(0, dns_hosts_lookup_text(hosts, c"ip6-localhost", &ip))
	assert_equal(0, dns_hosts_lookup_text(hosts, c"missing.example", &ip))
	# A name inside a comment is not an entry.
	assert_equal(0, dns_hosts_lookup_text(hosts, c"comment", &ip))
	assert_equal(0, dns_hosts_lookup_text(c"", c"localhost", &ip))


void test_dns_hosts_lookup_file():
	char* path = c"bin/dns_test_hosts.txt"
	asserts(c"fixture write failed", file_write_text(path, c"198.51.100.9 fixture.example alias.example\x0a") != 0)
	int ip = 0
	assert_equal(1, dns_hosts_lookup_file(path, c"fixture.example", &ip))
	# String compare: high-bit 0x literals sign-extend on x64.
	assert_strings_equal(c"0xc6336409", hex(ip))
	assert_equal(1, dns_hosts_lookup_file(path, c"alias.example", &ip))
	assert_equal(0, dns_hosts_lookup_file(path, c"missing.example", &ip))
	assert_equal(0, dns_hosts_lookup_file(c"bin/dns_test_missing_11aa.txt", c"fixture.example", &ip))


void test_dns_resolv_conf_nameservers_text():
	char* conf = c"# fixture resolv.conf\x0a; another comment\x0adomain example.com\x0anameserver 10.0.0.1\x0anameserver fe80::1\x0a\x09nameserver\x0910.0.0.2\x0anameserver 10.0.0.3 # trailing comment\x0anameserver 10.0.0.4\x0a"
	int* servers = cast(int*, malloc(4 * __word_size__))
	int count = dns_resolv_conf_nameservers_text(conf, servers, 3)
	# The IPv6 server is skipped; the cap stops before 10.0.0.4.
	assert_equal(3, count)
	assert_equal_hex(0x0a000001, servers[0])
	assert_equal_hex(0x0a000002, servers[1])
	assert_equal_hex(0x0a000003, servers[2])
	assert_equal(0, dns_resolv_conf_nameservers_text(c"", servers, 3))
	assert_equal(0, dns_resolv_conf_nameservers_text(c"nameserver\x0a", servers, 3))
	assert_equal(0, dns_resolv_conf_nameservers_text(c"nameserver notanip\x0a", servers, 3))
	free(servers)


void test_dns_resolv_conf_nameservers_file():
	char* path = c"bin/dns_test_resolv.txt"
	asserts(c"fixture write failed", file_write_text(path, c"nameserver 192.0.2.53\x0a") != 0)
	int* servers = cast(int*, malloc(2 * __word_size__))
	assert_equal(1, dns_resolv_conf_nameservers_file(path, servers, 2))
	# String compare: high-bit 0x literals sign-extend on x64.
	assert_strings_equal(c"0xc0000235", hex(servers[0]))
	assert_equal(0, dns_resolv_conf_nameservers_file(c"bin/dns_test_missing_11aa.txt", servers, 2))
	free(servers)


void test_dns_random_id_range():
	for i in range(8):
		int id = dns_random_id()
		asserts(c"id out of range", (id >= 0) & (id <= 65535))


# Blocking exact read helper for the mock server child.
int dns_test_read_exact(int file, char* buf, int want):
	int got = 0
	while (got < want):
		int count = read(file, buf + got, want - got)
		if (count <= 0): return 0
		got = got + count
	return 1


# Appends a compressed A answer (name pointer to the question at
# offset 12, ttl 60, address 127.0.0.42) to a query in buf of
# query_len bytes and flips it into a NOERROR response. Returns the
# response length.
int dns_test_mock_answer(char* buf, int query_len):
	buf[2] = 0x81
	buf[3] = 0x80
	buf[6] = 0
	buf[7] = 1
	int pos = query_len
	buf[pos] = 0xc0
	buf[pos + 1] = 12
	pos = dns_test_put_u16(buf, pos + 2, 1)
	pos = dns_test_put_u16(buf, pos, 1)
	pos = dns_test_put_u16(buf, pos, 0)
	pos = dns_test_put_u16(buf, pos, 60)
	pos = dns_test_put_u16(buf, pos, 4)
	buf[pos] = 127
	buf[pos + 1] = 0
	buf[pos + 2] = 0
	buf[pos + 3] = 42
	return pos + 4


# End-to-end resolver check against a mock loopback DNS server: the
# forked child answers exactly one UDP query, the parent resolves
# through dns_query_server.
void test_dns_query_server_mock_udp():
	int loopback = ip4_from_string(c"127.0.0.1")
	int server = socket_udp_ipv4()
	net_test_assert_ok(c"udp socket", server)
	net_test_assert_ok(c"udp bind", socket_bind_ipv4(server, loopback, 0))
	sockaddr_in bound
	net_test_assert_ok(c"getsockname", socket_getsockname_ipv4(server, &bound))
	int port = net_htons(bound.port)

	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		char* buf = cast(char*, malloc(512))
		sockaddr_in from
		int received = socket_recv_from_ipv4(server, buf, 512 - 16, 0, &from)
		if (received < 12): exit(1)
		int response_len = dns_test_mock_answer(buf, received)
		socket_send_to_ipv4(server, buf, response_len, 0, net_htonl(from.ip_address), net_htons(from.port))
		exit(0)

	int ip = 0
	int ok = dns_query_server(loopback, port, c"mock.example", 2000, &ip)
	int status = 0
	wait4(pid, &status, 0, 0)
	close(server)
	assert_equal(1, ok)
	assert_equal_hex(0x7f00002a, ip)


# TC-bit path: the child answers the UDP query with a truncated
# response, then serves the full answer over TCP on the same port.
void test_dns_query_server_mock_tcp_fallback():
	int loopback = ip4_from_string(c"127.0.0.1")
	int udp_server = socket_udp_ipv4()
	net_test_assert_ok(c"udp socket", udp_server)
	net_test_assert_ok(c"udp bind", socket_bind_ipv4(udp_server, loopback, 0))
	sockaddr_in bound
	net_test_assert_ok(c"getsockname", socket_getsockname_ipv4(udp_server, &bound))
	int port = net_htons(bound.port)

	int tcp_server = socket_tcp_ipv4()
	net_test_assert_ok(c"tcp socket", tcp_server)
	net_test_assert_ok(c"tcp reuseaddr", socket_set_reuseaddr(tcp_server))
	net_test_assert_ok(c"tcp bind", socket_bind_ipv4(tcp_server, loopback, port))
	net_test_assert_ok(c"tcp listen", socket_listen(tcp_server, 1))

	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		char* buf = cast(char*, malloc(512))
		sockaddr_in from
		int received = socket_recv_from_ipv4(udp_server, buf, 512 - 16, 0, &from)
		if (received < 12): exit(1)
		# Truncated UDP reply: echo the id, set QR|TC|RD|RA.
		char* truncated = cast(char*, malloc(12))
		truncated[0] = buf[0]
		truncated[1] = buf[1]
		truncated[2] = 0x83
		truncated[3] = 0x80
		for z in range(4, 12): truncated[z] = 0
		socket_send_to_ipv4(udp_server, truncated, 12, 0, net_htonl(from.ip_address), net_htons(from.port))

		# Full answer over TCP, RFC 1035 4.2.2 length-prefixed.
		int conn = socket_accept_connection(tcp_server)
		if (conn < 0): exit(1)
		char* prefix = cast(char*, malloc(2))
		if (dns_test_read_exact(conn, prefix, 2) == 0): exit(1)
		int query_len = ((prefix[0] & 255) << 8) | (prefix[1] & 255)
		if ((query_len < 12) || (query_len > 512 - 16)): exit(1)
		if (dns_test_read_exact(conn, buf, query_len) == 0): exit(1)
		int response_len = dns_test_mock_answer(buf, query_len)
		prefix[0] = (response_len >> 8) & 255
		prefix[1] = response_len & 255
		write(conn, prefix, 2)
		write(conn, buf, response_len)
		close(conn)
		exit(0)

	int ip = 0
	int ok = dns_query_server(loopback, port, c"mock.example", 2000, &ip)
	int status = 0
	wait4(pid, &status, 0, 0)
	close(udp_server)
	close(tcp_server)
	assert_equal(1, ok)
	assert_equal_hex(0x7f00002a, ip)


void test_dns_query_server_timeout():
	int loopback = ip4_from_string(c"127.0.0.1")
	# A bound socket that never answers: the query must time out.
	int silent = socket_udp_ipv4()
	net_test_assert_ok(c"udp socket", silent)
	net_test_assert_ok(c"udp bind", socket_bind_ipv4(silent, loopback, 0))
	sockaddr_in bound
	net_test_assert_ok(c"getsockname", socket_getsockname_ipv4(silent, &bound))
	int port = net_htons(bound.port)

	int ip = 0
	assert_equal(0, dns_query_server(loopback, port, c"mock.example", 100, &ip))
	close(silent)


void test_dns_resolve_ipv4_literal_short_circuit():
	# Literals resolve without touching hosts, resolv.conf, or the
	# network.
	int ip = 0
	assert_equal(1, dns_resolve_ipv4(c"192.0.2.1", &ip))
	# String compare: high-bit 0x literals sign-extend on x64.
	assert_strings_equal(c"0xc0000201", hex(ip))
	assert_equal(0, dns_resolve_ipv4(c"", &ip))
	assert_equal(0, dns_resolve_ipv4(0, &ip))


# Separate x86/x64 fixtures because wbuild runs the twins concurrently.
char* dns_cache_test_hosts_path():
	if (__word_size__ == 8): return c"bin/dns_cache_hosts64.txt"
	return c"bin/dns_cache_hosts32.txt"


char* dns_cache_test_resolv_path():
	if (__word_size__ == 8): return c"bin/dns_cache_resolv64.txt"
	return c"bin/dns_cache_resolv32.txt"


void dns_cache_test_files():
	dns_cache_clear()
	assert_equal(1, file_write_text(dns_cache_test_hosts_path(), c"# empty hosts\x0a"))
	assert_equal(1, file_write_text(dns_cache_test_resolv_path(), c"nameserver 127.0.0.1\x0a"))


int dns_cache_test_resolve(char* name, int port, int* ip):
	return dns_resolve_ipv4_config_until(name, ip, time_monotonic_ms() + 1000, dns_cache_test_hosts_path(), dns_cache_test_resolv_path(), port)


# Bounded child: later positive answers carry different addresses, so an
# accidental extra query cannot masquerade as a cache hit. first_rcode
# applies only to the first response, exposing negative-cache mistakes.
int dns_cache_test_server(int ttl, int first_rcode, int queries, int* out_fd, int* out_port):
	int server = socket_udp_ipv4()
	net_test_assert_ok(c"cache UDP socket", server)
	net_test_assert_ok(c"cache UDP bind", socket_bind_ipv4(server, 0x7f000001, 0))
	sockaddr_in bound
	net_test_assert_ok(c"cache getsockname", socket_getsockname_ipv4(server, &bound))
	*out_fd = server
	*out_port = net_htons(bound.port)
	int pid = fork()
	asserts(c"cache fork failed", pid >= 0)
	if (pid != 0): return pid
	char* buf = cast(char*, malloc(512))
	for i in range(queries):
		if (io_poll(server, poll_in, 3000) <= 0): exit(1)
		sockaddr_in from
		int received = socket_recv_from_ipv4(server, buf, 496, 0, &from)
		if (received < 12): exit(2)
		int length = dns_test_mock_answer(buf, received)
		store_be32(buf + received + 6, ttl)
		buf[length - 1] = 42 + i
		if (i == 0 && first_rcode != 0):
			buf[3] = 128 | first_rcode
			store_be16(buf + 6, 0)
			length = received
		if (socket_send_to_ipv4(server, buf, length, 0, net_htonl(from.ip_address), net_htons(from.port)) != length): exit(3)
	free(buf)
	close(server)
	exit(0)
	return 0


void dns_cache_test_join(int pid, int server):
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)
	close(server)
	dns_cache_clear()


void test_dns_cache_hit_and_ttl_expiry():
	dns_cache_test_files()
	int server = 0
	int port = 0
	int pid = dns_cache_test_server(1, 0, 2, &server, &port)
	int ip = 0
	assert_equal(1, dns_cache_test_resolve(c"cache.example", port, &ip))
	assert_equal_hex(0x7f00002a, ip)
	assert_equal(1, dns_cache_test_resolve(c"CACHE.EXAMPLE.", port, &ip))
	assert_equal_hex(0x7f00002a, ip)
	# An expired deadline must fail even though an answer is cached.
	assert_equal(0, dns_resolve_ipv4_config_until(c"cache.example", &ip, time_monotonic_ms() - 1, dns_cache_test_hosts_path(), dns_cache_test_resolv_path(), port))
	sleep_ms(1100)
	assert_equal(1, dns_cache_test_resolve(c"cache.example", port, &ip))
	assert_equal_hex(0x7f00002b, ip)
	dns_cache_test_join(pid, server)


void test_dns_cache_zero_ttl_and_transient_errors():
	for mode in range(2):
		dns_cache_test_files()
		int server = 0
		int port = 0
		int rcode = mode * 2
		int pid = dns_cache_test_server(0, rcode, 2, &server, &port)
		int ip = 0
		assert_equal(1 - mode, dns_cache_test_resolve(c"zero.example", port, &ip))
		asserts(c"zero TTL or SERVFAIL cached", dns_cache_answers == 0)
		assert_equal(1, dns_cache_test_resolve(c"zero.example", port, &ip))
		assert_equal_hex(0x7f00002b, ip)
		dns_cache_test_join(pid, server)


void test_dns_cache_nxdomain_and_expiry():
	dns_cache_test_files()
	int server = 0
	int port = 0
	int pid = dns_cache_test_server(60, 3, 2, &server, &port)
	int ip = 123
	assert_equal(0, dns_cache_test_resolve(c"absent.example", port, &ip))
	assert_equal(123, ip)
	asserts(c"NXDOMAIN not cached", dns_cache_answers != 0)
	assert_equal(dns_result_nxdomain, dns_cache_answers.result)
	asserts(c"negative lifetime too long", dns_cache_answers.expires - time_monotonic_ms() <= dns_cache_negative_ttl * 1000)
	assert_equal(0, dns_cache_test_resolve(c"ABSENT.EXAMPLE.", port, &ip))
	# Advance only this entry past expiry, without a five-second sleep.
	dns_cache_answers.expires = time_monotonic_ms() - 1
	assert_equal(1, dns_cache_test_resolve(c"absent.example", port, &ip))
	assert_equal_hex(0x7f00002b, ip)
	dns_cache_test_join(pid, server)


void test_dns_cache_flush_and_opt_out():
	for mode in range(2):
		dns_cache_test_files()
		int server = 0
		int port = 0
		int pid = dns_cache_test_server(60, 0, 2, &server, &port)
		int ip = 0
		if (mode == 1): dns_cache_set_enabled(0)
		assert_equal(1, dns_cache_test_resolve(c"flush.example", port, &ip))
		assert_equal_hex(0x7f00002a, ip)
		if (mode == 0): dns_cache_clear()
		assert_equal(1, dns_cache_test_resolve(c"flush.example", port, &ip))
		assert_equal_hex(0x7f00002b, ip)
		if (mode == 1):
			asserts(c"disabled answer cache populated", dns_cache_answers == 0)
			dns_cache_set_enabled(1)
		dns_cache_test_join(pid, server)


void test_dns_cache_config_reload():
	dns_cache_test_files()
	int server = 0
	int port = 0
	int pid = dns_cache_test_server(60, 0, 2, &server, &port)
	int ip = 0
	assert_equal(1, dns_cache_test_resolve(c"reload.example", port, &ip))
	assert_equal_hex(0x7f00002a, ip)
	# Hosts take priority over a positive DNS entry after a rewrite.
	assert_equal(1, file_write_text(dns_cache_test_hosts_path(), c"10.0.0.1 reload.example alias.example\x0a"))
	assert_equal(1, dns_cache_test_resolve(c"reload.example", port, &ip))
	assert_equal_hex(0x0a000001, ip)
	# Same-size same-second rewrite: nanosecond mtime must invalidate.
	sleep_ms(2)
	assert_equal(1, file_write_text(dns_cache_test_hosts_path(), c"10.0.0.2 reload.example alias.example\x0a"))
	assert_equal(1, dns_cache_test_resolve(c"ALIAS.EXAMPLE.", port, &ip))
	assert_equal_hex(0x0a000002, ip)
	assert_equal(0, unlink(dns_cache_test_hosts_path()))
	# DNS must query again after removing the hosts override.
	assert_equal(1, dns_cache_test_resolve(c"reload.example", port, &ip))
	assert_equal_hex(0x7f00002b, ip)
	# Config changes clear the positive cache even if hosts resolves first.
	assert_equal(1, file_write_text(dns_cache_test_hosts_path(), c"10.0.0.3 hosts.example\x0a"))
	assert_equal(1, file_write_text(dns_cache_test_resolv_path(), c"nameserver 127.0.0.2\x0a"))
	assert_equal(1, dns_cache_test_resolve(c"hosts.example", port, &ip))
	assert_equal_hex(0x7f000002, dns_cache_resolv.servers[0])
	asserts(c"config reload retained answers", dns_cache_answers == 0)
	dns_cache_test_join(pid, server)


void test_dns_cache_ttl_parser_and_negative_validation():
	int length = 0
	char* msg = dns_test_response_a(&length)
	int ip = 0
	int ttl = 0
	assert_equal(dns_result_ok, dns_parse_response_ttl(msg, length, 0x1234, c"example.com", &ip, &ttl))
	assert_equal(60, ttl)
	store_be32(msg + length - 10, -1)
	assert_equal(dns_result_ok, dns_parse_response_ttl(msg, length, 0x1234, c"example.com", &ip, &ttl))
	assert_equal(300, ttl)
	free(msg)
	msg = dns_test_build_cname_chain(1, &length)
	# First CNAME has a shorter lifetime than the final A record.
	store_be32(msg + 26, 2)
	assert_equal(dns_result_ok, dns_parse_response_ttl(msg, length, 0x1234, c"a", &ip, &ttl))
	assert_equal(2, ttl)
	store_be32(msg + 26, 0)
	assert_equal(dns_result_ok, dns_parse_response_ttl(msg, length, 0x1234, c"a", &ip, &ttl))
	assert_equal(0, ttl)
	free(msg)
	msg = hex_decode_loose(c"12 34 81 83 00 01 00 00 00 00 00 00 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01", &length)
	assert_equal(dns_result_nxdomain, dns_parse_response_ttl(msg, length, 0x1234, c"example.com", &ip, &ttl))
	assert_equal(dns_result_error, dns_parse_response_ttl(msg, length, 0x1234, c"other.example", &ip, &ttl))
	assert_equal(dns_result_error, dns_parse_response_ttl(msg, 12, 0x1234, c"example.com", &ip, &ttl))
	free(msg)


void test_dns_cache_capacity_and_flush_generation():
	dns_cache_clear()
	int generation = dns_cache_generation
	for i in range(dns_cache_capacity + 10):
		dns_cache_store(c"bounded.example", i, dns_result_ok, 60, generation)
	int count = 0
	dns_cache_entry* entry = dns_cache_answers
	while (entry != 0):
		count += 1
		entry = entry.next
	assert_equal(dns_cache_capacity, count)
	dns_cache_clear()
	dns_cache_store(c"stale.example", 1, dns_result_ok, 60, generation)
	asserts(c"in-flight lookup survived flush", dns_cache_answers == 0)



void test_dns_cache_monotonic_signed_wrap():
	dns_cache_clear()
	dns_cache_store(c"wrap.example", 42, dns_result_ok, 60, dns_cache_generation)
	int before = 2147483600
	# Runtime addition wraps on x86; x64 also proves ordinary deadlines.
	dns_cache_answers.expires = before + 1000
	int ip = 0
	assert_equal(dns_result_ok, dns_cache_find_at(c"wrap.example", &ip, before + 500))
	assert_equal(42, ip)
	assert_equal(0, dns_cache_find_at(c"wrap.example", &ip, before + 1000))
	assert_equal(0, dns_cache_find_at(c"wrap.example", &ip, before + 1100))
	dns_cache_clear()



void test_dns_cache_hosts_reload_overrides_negative():
	dns_cache_test_files()
	int server = 0
	int port = 0
	int pid = dns_cache_test_server(60, 3, 1, &server, &port)
	int ip = 0
	assert_equal(0, dns_cache_test_resolve(c"new.example", port, &ip))
	assert_equal(1, file_write_text(dns_cache_test_hosts_path(), c"10.1.2.3 new.example\x0a"))
	assert_equal(1, dns_cache_test_resolve(c"new.example", port, &ip))
	assert_equal_hex(0x0a010203, ip)
	asserts(c"hosts reload retained NXDOMAIN", dns_cache_answers == 0)
	dns_cache_test_join(pid, server)



void test_dns_cache_long_idle_does_not_revive_expired_entries():
	dns_cache_clear()
	dns_cache_store(c"idle.example", 42, dns_result_ok, 60, dns_cache_generation)
	dns_cache_answers.created_seconds = 100
	dns_cache_answers.expires = 160000
	int ip = 0
	assert_equal(dns_result_ok, dns_cache_find_at_time(c"idle.example", &ip, 159999, 159))
	assert_equal(0, dns_cache_find_at_time(c"idle.example", &ip, 160000, 160))
	for mode in range(2):
		int elapsed = 25 * 24 * 60 * 60
		# Also cover one complete 32-bit millisecond wrap, about 49.7 days.
		if (mode == 1): elapsed = 4294968
		int now_seconds = 100 + elapsed
		int now_ms = now_seconds * 1000
		if (__word_size__ == 4):
			asserts(c"fixture did not expose millisecond expiry revival", dns_cache_answers.expires - now_ms > 0)
		assert_equal(0, dns_cache_find_at_time(c"idle.example", &ip, now_ms, now_seconds))
	dns_cache_clear()
