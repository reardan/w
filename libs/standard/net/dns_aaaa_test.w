# wbuild: x64
# wbuild: step="bin/dns_aaaa_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# AAAA queries/answers and dual-stack address lists in
# libs/standard/net/dns.w (stdlib parity P3.10). Wire fixtures are
# embedded as hex: the NXDOMAIN one was captured from this sandbox's
# resolver (8.8.8.8 answered by the sandbox for example.com AAAA); the
# sandbox blocks real lookups, so the positive/NODATA/CNAME fixtures
# are assembled byte for byte in the layout real servers send (name
# compression at 0xc00c, SOA in the authority section for NODATA).
# The resolver paths run against hosts files under bin/ and a forked
# mock DNS server on a loopback ephemeral port, never the system files.
import lib.testing
import lib.file
import lib.net
import lib.hex
import libs.standard.net.dns
import libs.standard.net.ipaddress
import libs.standard.net.testing


char* dns_aaaa_test_msg(char* hex, int* out_len):
	return hex_decode(hex, strlen(hex), out_len)


# Formats 16 network-order bytes the ipaddress.w way.
char* dns_aaaa_test_format(char* ip16):
	ip_address a
	asserts(c"from_packed", ip_address_from_packed(ip16, 16, &a))
	return ip_address_format(&a)


void dns_aaaa_test_expect_address(char* want, char* ip16):
	char* got = dns_aaaa_test_format(ip16)
	assert_strings_equal(want, got)
	free(got)


void test_dns_build_query_aaaa():
	char* out = cast(char*, malloc(64))
	int length = dns_build_query_type(c"example.com", dns_type_aaaa, 0x1234, out, 64)
	int want_len = 0
	char* want = dns_aaaa_test_msg(c"123401000001000000000000076578616d706c6503636f6d00001c0001", &want_len)
	assert_equal(want_len, length)
	for i in range(length): assert_equal(want[i] & 255, out[i] & 255)
	# The A builder is the qtype 1 form of the same encoder.
	assert_equal(length, dns_build_query(c"example.com", 0x1234, out, 64))
	assert_equal(1, out[length - 3])
	assert_equal(0, dns_build_query_type(c"bad..name", dns_type_aaaa, 1, out, 64))
	free(want)
	free(out)


void test_dns_parse_aaaa_answer():
	int length = 0
	char* msg = dns_aaaa_test_msg(c"123481800001000100000000076578616d706c6503636f6d00001c0001c00c001c000100000e10001026062800022000010248189325c81946", &length)
	char* ip6 = cast(char*, malloc(16))
	int ttl = 0
	assert_equal(dns_result_ok, dns_parse_response_aaaa(msg, length, 0x1234, c"example.com", ip6, &ttl))
	dns_aaaa_test_expect_address(c"2606:2800:220:1:248:1893:25c8:1946", ip6)
	# 3600s on the wire, capped like A answers.
	assert_equal(dns_cache_ttl_max, ttl)
	# Name match is case-insensitive and ignores one trailing dot.
	assert_equal(dns_result_ok, dns_parse_response_aaaa(msg, length, 0x1234, c"EXAMPLE.com.", ip6, &ttl))
	# Wrong id or name.
	assert_equal(dns_result_error, dns_parse_response_aaaa(msg, length, 0x1235, c"example.com", ip6, &ttl))
	assert_equal(dns_result_error, dns_parse_response_aaaa(msg, length, 0x1234, c"example.org", ip6, &ttl))
	# An AAAA response is not an answer to an A question.
	int ip = 0
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"example.com", &ip))
	# Truncated rdata.
	assert_equal(dns_result_error, dns_parse_response_aaaa(msg, length - 1, 0x1234, c"example.com", ip6, &ttl))
	# rdlength 4 on an AAAA record is malformed.
	msg[length - 17] = 4
	assert_equal(dns_result_error, dns_parse_response_aaaa(msg, length - 12, 0x1234, c"example.com", ip6, &ttl))
	free(ip6)
	free(msg)


void test_dns_parse_aaaa_cname_chain():
	int length = 0
	char* msg = dns_aaaa_test_msg(c"beef8180000100020000000003777777076578616d706c6503636f6d00001c0001c00c00050001000000780002c010c010001c00010000003c001020010db8000000000000000000000001", &length)
	char* ip6 = cast(char*, malloc(16))
	int ttl = 0
	assert_equal(dns_result_ok, dns_parse_response_aaaa(msg, length, 0xbeef, c"www.example.com", ip6, &ttl))
	dns_aaaa_test_expect_address(c"2001:db8::1", ip6)
	# Minimum of the CNAME (120) and AAAA (60) TTLs.
	assert_equal(60, ttl)
	free(ip6)
	free(msg)


void test_dns_parse_aaaa_nodata_and_nxdomain():
	int length = 0
	char* msg = dns_aaaa_test_msg(c"0101818000010000000100000676346f6e6c79076578616d706c6500001c0001c00c000600010000012c0037026e73076578616d706c6503636f6d000561646d696e076578616d706c6503636f6d00000007e800001c2000000e10001275000000012c", &length)
	char* ip6 = cast(char*, malloc(16))
	int ttl = 0
	assert_equal(dns_result_nodata, dns_parse_response_aaaa(msg, length, 0x0101, c"v4only.example", ip6, &ttl))
	assert_equal(dns_cache_negative_ttl, ttl)
	free(msg)

	# Captured: the sandbox resolver's NXDOMAIN for example.com AAAA.
	msg = dns_aaaa_test_msg(c"123481830001000000000000076578616d706c6503636f6d00001c0001", &length)
	assert_equal(dns_result_nxdomain, dns_parse_response_aaaa(msg, length, 0x1234, c"example.com", ip6, &ttl))
	assert_equal(dns_cache_negative_ttl, ttl)
	# TC bit wins over everything else.
	msg[2] = msg[2] | 2
	assert_equal(dns_result_truncated, dns_parse_response_aaaa(msg, length, 0x1234, c"example.com", ip6, &ttl))
	free(msg)

	# An A record for the name in an AAAA response is not an answer:
	# NODATA for the typed parser.
	msg = dns_aaaa_test_msg(c"123481800001000100000000016100001c0001c00c000100010000003c00040a000001", &length)
	assert_equal(dns_result_nodata, dns_parse_response_aaaa(msg, length, 0x1234, c"a", ip6, &ttl))
	free(msg)

	# The compatibility A parser still reports NODATA as an error.
	msg = dns_aaaa_test_msg(c"12348180000100000000000001610000010001", &length)
	int ip = 0
	assert_equal(dns_result_error, dns_parse_response(msg, length, 0x1234, c"a", &ip))
	assert_equal(dns_result_error, dns_parse_response_ttl(msg, length, 0x1234, c"a", &ip, &ttl))
	assert_equal(0, ttl)
	free(msg)
	free(ip6)


void test_dns_parse_ipv6_literal():
	char* ip6 = cast(char*, malloc(16))
	asserts(c"::1", dns_parse_ipv6_literal(c"::1", ip6))
	dns_aaaa_test_expect_address(c"::1", ip6)
	asserts(c"[2001:db8::2]", dns_parse_ipv6_literal(c"[2001:DB8::2]", ip6))
	dns_aaaa_test_expect_address(c"2001:db8::2", ip6)
	asserts(c"mapped", dns_parse_ipv6_literal(c"::ffff:192.0.2.1", ip6))
	dns_aaaa_test_expect_address(c"::ffff:192.0.2.1", ip6)
	assert_equal(0, dns_parse_ipv6_literal(c"[::1", ip6))
	assert_equal(0, dns_parse_ipv6_literal(c"fe80::1%eth0", ip6))
	assert_equal(0, dns_parse_ipv6_literal(c"1.2.3.4", ip6))
	assert_equal(0, dns_parse_ipv6_literal(c"example.com", ip6))
	assert_equal(0, dns_parse_ipv6_literal(c"", ip6))
	assert_equal(0, dns_parse_ipv6_literal(0, ip6))
	free(ip6)


void test_dns_hosts_lookup_ipv6_text():
	char* text = c"127.0.0.1 localhost\x0a::1 localhost ip6-localhost # loopback\x0afe80::1%lo0 zoned\x0a2001:db8::7\tSix.Example\x0a"
	char* ip6 = cast(char*, malloc(16))
	asserts(c"ip6-localhost", dns_hosts_lookup_ipv6_text(text, c"ip6-localhost", ip6))
	dns_aaaa_test_expect_address(c"::1", ip6)
	asserts(c"localhost v6", dns_hosts_lookup_ipv6_text(text, c"LOCALHOST", ip6))
	asserts(c"tab separated", dns_hosts_lookup_ipv6_text(text, c"six.example", ip6))
	dns_aaaa_test_expect_address(c"2001:db8::7", ip6)
	assert_equal(0, dns_hosts_lookup_ipv6_text(text, c"zoned", ip6))
	assert_equal(0, dns_hosts_lookup_ipv6_text(text, c"missing", ip6))
	# IPv4 lookups are unchanged by IPv6 lines.
	int ip = 0
	asserts(c"v4", dns_hosts_lookup_text(text, c"localhost", &ip))
	assert_equal_hex(0x7f000001, ip)
	assert_equal(0, dns_hosts_lookup_text(text, c"ip6-localhost", &ip))
	free(ip6)


char* dns_aaaa_test_hosts_path():
	if (__word_size__ == 8): return c"bin/dns_aaaa_hosts64.txt"
	return c"bin/dns_aaaa_hosts32.txt"


char* dns_aaaa_test_resolv_path():
	if (__word_size__ == 8): return c"bin/dns_aaaa_resolv64.txt"
	return c"bin/dns_aaaa_resolv32.txt"


void dns_aaaa_test_files(char* hosts):
	dns_cache_clear()
	assert_equal(1, file_write_text(dns_aaaa_test_hosts_path(), hosts))
	assert_equal(1, file_write_text(dns_aaaa_test_resolv_path(), c"nameserver 127.0.0.1\x0a"))


# Order as "6:<last byte> 4:<last byte>" for compact asserts.
char* dns_aaaa_test_order(net_address* addrs, int count):
	char* out = cast(char*, malloc(count * 8 + 1))
	char* ip6 = cast(char*, malloc(16))
	int pos = 0
	for i in range(count):
		int last = addrs[i].ipv4 & 255
		out[pos] = '4'
		if (net_address_is_ipv6(&addrs[i])):
			net_address_ipv6_bytes(&addrs[i], ip6)
			last = ip6[15] & 255
			out[pos] = '6'
		out[pos + 1] = ':'
		char* digits = itoa(last)
		int n = strlen(digits)
		for j in range(n): out[pos + 2 + j] = digits[j]
		free(digits)
		pos += 2 + n
		out[pos] = ' '
		pos += 1
	if (pos > 0): pos -= 1
	out[pos] = 0
	free(ip6)
	return out


void dns_aaaa_test_expect_resolve(char* name, int port, char* want):
	net_address* addrs = cast(net_address*, malloc(sizeof(net_address) * 4))
	int count = dns_resolve_addresses_config_until(name, addrs, 4, time_monotonic_ms() + 2000, dns_aaaa_test_hosts_path(), dns_aaaa_test_resolv_path(), port)
	char* got = dns_aaaa_test_order(addrs, count)
	assert_strings_equal(want, got)
	free(got)
	free(addrs)


void test_dns_resolve_addresses_literals_and_hosts():
	dns_aaaa_test_files(c"127.0.0.1 localhost\x0a::1 localhost\x0a127.0.0.2 v4.test\x0a::2 v6.test\x0a10.0.0.3 multi.test\x0a10.0.0.4 multi.test\x0a::5 multi.test\x0a")
	# Port 9 on loopback: nothing answers, so any DNS fallback would fail.
	dns_aaaa_test_expect_resolve(c"10.1.2.3", 9, c"4:3")
	dns_aaaa_test_expect_resolve(c"[2001:db8::9]", 9, c"6:9")
	dns_aaaa_test_expect_resolve(c"2001:db8::8", 9, c"6:8")
	dns_aaaa_test_expect_resolve(c"localhost", 9, c"6:1 4:1")
	dns_aaaa_test_expect_resolve(c"v4.test", 9, c"4:2")
	dns_aaaa_test_expect_resolve(c"V6.TEST", 9, c"6:2")
	dns_aaaa_test_expect_resolve(c"multi.test", 9, c"6:5 4:3 4:4")
	# max bounds the list (hosts order before interleaving).
	net_address* one = cast(net_address*, malloc(sizeof(net_address)))
	assert_equal(1, dns_resolve_addresses_config_until(c"multi.test", one, 1, time_monotonic_ms() + 2000, dns_aaaa_test_hosts_path(), dns_aaaa_test_resolv_path(), 9))
	assert_equal(0, net_address_is_ipv6(one))
	assert_equal(0, dns_resolve_addresses_config_until(c"", one, 1, time_monotonic_ms() + 2000, dns_aaaa_test_hosts_path(), dns_aaaa_test_resolv_path(), 9))
	assert_equal(0, dns_resolve_addresses_config_until(c"x.test", one, 0, time_monotonic_ms() + 2000, dns_aaaa_test_hosts_path(), dns_aaaa_test_resolv_path(), 9))
	free(one)
	# The AAAA resolver alone sees hosts IPv6 lines and literals.
	char* ip6 = cast(char*, malloc(16))
	asserts(c"v6 hosts", dns_resolve_ipv6_config_until(c"localhost", ip6, time_monotonic_ms() + 2000, dns_aaaa_test_hosts_path(), dns_aaaa_test_resolv_path(), 9))
	dns_aaaa_test_expect_address(c"::1", ip6)
	assert_equal(0, dns_resolve_ipv6_config_until(c"127.0.0.1", ip6, time_monotonic_ms() + 2000, dns_aaaa_test_hosts_path(), dns_aaaa_test_resolv_path(), 9))
	free(ip6)
	dns_cache_clear()


# Mock DNS server: answers `queries` UDP queries; A gets 127.0.0.42,
# AAAA gets 2001:db8::42 (or NODATA when aaaa_nodata). TTL 60.
int dns_aaaa_test_server(int aaaa_nodata, int queries, int* out_fd, int* out_port):
	int server = socket_udp_ipv4()
	net_test_assert_ok(c"udp socket", server)
	net_test_assert_ok(c"udp bind", socket_bind_ipv4(server, 0x7f000001, 0))
	sockaddr_in bound
	net_test_assert_ok(c"getsockname", socket_getsockname_ipv4(server, &bound))
	*out_fd = server
	*out_port = net_htons(bound.port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid != 0): return pid
	char* buf = cast(char*, malloc(512))
	for i in range(queries):
		if (io_poll(server, poll_in, 3000) <= 0): exit(1)
		sockaddr_in from
		int received = socket_recv_from_ipv4(server, buf, 400, 0, &from)
		if (received < 17): exit(2)
		int qtype = load_be16(buf + received - 4)
		buf[2] = 0x81
		buf[3] = 0x80
		int length = received
		if (qtype == dns_type_a || aaaa_nodata == 0):
			store_be16(buf + 6, 1)
			buf[length] = 0xc0
			buf[length + 1] = 12
			store_be16(buf + length + 2, qtype)
			store_be16(buf + length + 4, 1)
			store_be32(buf + length + 6, 60)
			length += 10
			if (qtype == dns_type_a):
				store_be16(buf + length, 4)
				store_be32(buf + length + 2, 0x7f00002a)
				length += 6
			else:
				store_be16(buf + length, 16)
				for j in range(16): buf[length + 2 + j] = 0
				buf[length + 2] = 0x20
				buf[length + 3] = 0x01
				buf[length + 4] = 0x0d
				buf[length + 5] = 0xb8
				buf[length + 17] = 0x42
				length += 18
		if (socket_send_to_ipv4(server, buf, length, 0, net_htonl(from.ip_address), net_htons(from.port)) != length): exit(3)
	exit(0)
	return 0


void dns_aaaa_test_join(int pid, int server):
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)
	close(server)


void test_dns_query_server_aaaa_mock():
	int server = 0
	int port = 0
	int pid = dns_aaaa_test_server(0, 1, &server, &port)
	char* ip6 = cast(char*, malloc(16))
	int ok = dns_query_server_aaaa(0x7f000001, port, c"mock.example", 2000, ip6)
	dns_aaaa_test_join(pid, server)
	assert_equal(1, ok)
	dns_aaaa_test_expect_address(c"2001:db8::42", ip6)
	free(ip6)


void test_dns_resolve_addresses_dual_stack_mock():
	dns_aaaa_test_files(c"# empty\x0a")
	int server = 0
	int port = 0
	# Exactly two queries (A, AAAA): the repeat below must hit the cache.
	int pid = dns_aaaa_test_server(0, 2, &server, &port)
	dns_aaaa_test_expect_resolve(c"mock.example", port, c"6:66 4:42")
	dns_aaaa_test_expect_resolve(c"MOCK.example", port, c"6:66 4:42")
	dns_aaaa_test_join(pid, server)
	dns_cache_clear()


void test_dns_resolve_addresses_nodata_mock():
	dns_aaaa_test_files(c"# empty\x0a")
	int server = 0
	int port = 0
	int pid = dns_aaaa_test_server(1, 2, &server, &port)
	dns_aaaa_test_expect_resolve(c"v4only.example", port, c"4:42")
	# NODATA is negatively cached: no third query.
	dns_aaaa_test_expect_resolve(c"v4only.example", port, c"4:42")
	char* ip6 = cast(char*, malloc(16))
	assert_equal(0, dns_resolve_ipv6_config_until(c"v4only.example", ip6, time_monotonic_ms() + 2000, dns_aaaa_test_hosts_path(), dns_aaaa_test_resolv_path(), port))
	free(ip6)
	dns_aaaa_test_join(pid, server)
	dns_cache_clear()
