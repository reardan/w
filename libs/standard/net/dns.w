# DNS resolver for the pure-W HTTP stack (plan 11, issue #198, part of
# #155): A records over UDP port 53 with a TCP retry when the server
# sets the TC (truncation) bit. IPv4 only for now (lib/net.w sockets
# are IPv4-only), but nothing here designs AAAA out.
#
# Resolution order in dns_resolve_ipv4: dotted-quad literals
# short-circuit, then /etc/hosts, then the /etc/resolv.conf
# nameservers in order with a 2 second timeout per server.
#
# All addresses cross this API in host byte order, matching
# ip4_from_string and the lib/net.w connect/send helpers.
#
# Wire parsing is strict and bounded: response id/flags/counts are
# validated, CNAME chains are followed only within the same response
# and only to dns_max_cname_depth(), compression pointers must point
# strictly backwards and are capped at dns_max_pointer_hops(), and
# oversized or truncated messages are rejected.
#
# Public API (everything an HTTP client needs):
#   int dns_resolve_ipv4(char* hostname, int* out_ip)     1/0
#   int dns_query_server(int server_ip, int server_port, char* hostname,
#                        int timeout_ms, int* out_ip)     1/0
#   int dns_parse_ipv4_literal(char* text, int* out_ip)   1/0
#   int dns_hosts_lookup_text/file(...)                   1/0
#   int dns_resolv_conf_nameservers_text/file(...)        count
#   int dns_build_query(char* hostname, int query_id, char* out,
#                       int out_cap)                      length or 0
#   int dns_parse_response(char* msg, int msg_len, int query_id,
#                          char* hostname, int* out_ip)   dns_result_*
import lib.lib
import lib.net
import lib.poll
import lib.file
import lib.time


int dns_port():
	return 53


int dns_default_timeout_ms():
	return 2000


int dns_max_nameservers():
	return 3


int dns_udp_message_max():
	return 512


int dns_tcp_message_max():
	return 4096


# Longest decoded (presentation-form) name we accept, plus one for the
# terminating NUL: decode buffers are dns_name_buffer_size() bytes.
int dns_name_buffer_size():
	return 256


int dns_max_cname_depth():
	return 8


int dns_max_pointer_hops():
	return 32


int dns_max_answers():
	return 64


int dns_type_a():
	return 1


int dns_type_cname():
	return 5


int dns_class_in():
	return 1


# dns_parse_response result codes.
int dns_result_error():
	return 0


int dns_result_ok():
	return 1


int dns_result_truncated():
	return 2


int dns_lower_char(int c):
	if ((c >= 'A') & (c <= 'Z')):
		return c + 32
	return c


# Case-insensitive DNS name comparison. A single trailing dot on
# either side is ignored, so "example.com." equals "example.com".
int dns_names_equal_ci(char* a, char* b):
	int a_length = strlen(a)
	int b_length = strlen(b)
	if (a_length > 0):
		if (a[a_length - 1] == '.'):
			a_length = a_length - 1
	if (b_length > 0):
		if (b[b_length - 1] == '.'):
			b_length = b_length - 1
	if (a_length != b_length):
		return 0
	int i = 0
	while (i < a_length):
		if (dns_lower_char(a[i] & 255) != dns_lower_char(b[i] & 255)):
			return 0
		i = i + 1
	return 1


# Strict dotted-quad parser: exactly four decimal octets 0..255
# separated by dots, no leading zeros (avoids octal ambiguity), and
# nothing else. Returns 1 with the host-order address in *out_ip, or 0.
int dns_parse_ipv4_literal(char* text, int* out_ip):
	if (text == 0):
		return 0
	int value = 0
	int parts = 0
	int i = 0
	while (1):
		int digit_start = i
		int part_value = 0
		while ((text[i] >= '0') & (text[i] <= '9')):
			part_value = part_value * 10 + (text[i] - '0')
			i = i + 1
			if (i - digit_start > 3):
				return 0
		if (i == digit_start):
			return 0
		if ((i - digit_start > 1) & (text[digit_start] == '0')):
			return 0
		if (part_value > 255):
			return 0
		value = (value << 8) | part_value
		parts = parts + 1
		if (parts == 4):
			if (text[i] != 0):
				return 0
			*out_ip = value
			return 1
		if (text[i] != '.'):
			return 0
		i = i + 1
	return 0


int dns_is_space(int c):
	return (c == ' ') | (c == 9) | (c == 13)


# Scans the next whitespace-separated token in text[*pos, line_end).
# '#' and ';' start a comment running to the line end (hosts(5) uses
# '#', resolv.conf(5) allows both; neither appears in valid tokens).
# Returns 1 with [*tok_start, *tok_end) set, or 0 when no token is
# left on the line. *pos advances past the token either way.
int dns_next_token(char* text, int* pos, int line_end, int* tok_start, int* tok_end):
	int p = *pos
	while ((p < line_end) & (dns_is_space(text[p] & 255) != 0)):
		p = p + 1
	if (p >= line_end):
		*pos = line_end
		return 0
	if ((text[p] == '#') | (text[p] == ';')):
		*pos = line_end
		return 0
	*tok_start = p
	int done = 0
	while ((p < line_end) & (done == 0)):
		int c = text[p] & 255
		if ((dns_is_space(c) != 0) | (c == '#') | (c == ';')):
			done = 1
		else:
			p = p + 1
	*tok_end = p
	*pos = p
	return 1


# Parses text[start, end) as a dotted-quad address. Returns 1/0.
int dns_token_ipv4(char* text, int start, int end, int* out_ip):
	int length = end - start
	if ((length <= 0) | (length > 15)):
		return 0
	char* token = malloc(16)
	int i = 0
	while (i < length):
		token[i] = text[start + i]
		i = i + 1
	token[length] = 0
	int ok = dns_parse_ipv4_literal(token, out_ip)
	free(token)
	return ok


# Case-insensitive comparison of text[start, end) against name.
int dns_token_equals_ci(char* text, int start, int end, char* name):
	int length = end - start
	if (strlen(name) != length):
		return 0
	int i = 0
	while (i < length):
		if (dns_lower_char(text[start + i] & 255) != dns_lower_char(name[i] & 255)):
			return 0
		i = i + 1
	return 1


# Looks hostname up in hosts(5)-format text (the format of /etc/hosts):
# per line an address token followed by one or more names, '#' comments.
# Only IPv4 entries participate; the name match is case-insensitive.
# Returns 1 with the host-order address in *out_ip, or 0.
int dns_hosts_lookup_text(char* text, char* hostname, int* out_ip):
	if ((text == 0) | (hostname == 0)):
		return 0
	int i = 0
	while (text[i] != 0):
		int line_end = i
		while ((text[line_end] != 0) & (text[line_end] != 10)):
			line_end = line_end + 1
		int pos = i
		int tok_start = 0
		int tok_end = 0
		if (dns_next_token(text, &pos, line_end, &tok_start, &tok_end) != 0):
			int address = 0
			if (dns_token_ipv4(text, tok_start, tok_end, &address) != 0):
				while (dns_next_token(text, &pos, line_end, &tok_start, &tok_end) != 0):
					if (dns_token_equals_ci(text, tok_start, tok_end, hostname) != 0):
						*out_ip = address
						return 1
		i = line_end
		if (text[i] == 10):
			i = i + 1
	return 0


# dns_hosts_lookup_text over a file (normally /etc/hosts). Returns 0
# when the file cannot be read.
int dns_hosts_lookup_file(char* path, char* hostname, int* out_ip):
	char* text = file_read_text(path)
	if (text == 0):
		return 0
	int found = dns_hosts_lookup_text(text, hostname, out_ip)
	free(text)
	return found


# Extracts up to max_servers IPv4 nameserver addresses from
# resolv.conf(5)-format text ("nameserver <address>" lines; '#'/';'
# comments). IPv6 and malformed entries are skipped. Returns the
# count stored into out_ips (host byte order).
int dns_resolv_conf_nameservers_text(char* text, int* out_ips, int max_servers):
	if ((text == 0) | (max_servers <= 0)):
		return 0
	int count = 0
	int i = 0
	while ((text[i] != 0) & (count < max_servers)):
		int line_end = i
		while ((text[line_end] != 0) & (text[line_end] != 10)):
			line_end = line_end + 1
		int pos = i
		int tok_start = 0
		int tok_end = 0
		if (dns_next_token(text, &pos, line_end, &tok_start, &tok_end) != 0):
			if (dns_token_equals_ci(text, tok_start, tok_end, c"nameserver") != 0):
				if (dns_next_token(text, &pos, line_end, &tok_start, &tok_end) != 0):
					int address = 0
					if (dns_token_ipv4(text, tok_start, tok_end, &address) != 0):
						out_ips[count] = address
						count = count + 1
		i = line_end
		if (text[i] == 10):
			i = i + 1
	return count


# dns_resolv_conf_nameservers_text over a file (normally
# /etc/resolv.conf). Returns 0 when the file cannot be read.
int dns_resolv_conf_nameservers_file(char* path, int* out_ips, int max_servers):
	char* text = file_read_text(path)
	if (text == 0):
		return 0
	int count = dns_resolv_conf_nameservers_text(text, out_ips, max_servers)
	free(text)
	return count


# 16-bit query id from /dev/urandom so answers are hard to spoof.
# TODO(#193): switch to libs.standard.crypto.random once it lands.
int dns_random_id():
	int file = open(c"/dev/urandom", 0, 0)
	if (file >= 0):
		char* buf = malloc(2)
		int count = read(file, buf, 2)
		close(file)
		int id = ((buf[0] & 255) << 8) | (buf[1] & 255)
		free(buf)
		if (count == 2):
			return id
	# Last-resort fallback; should be unreachable on Linux and macOS.
	return time_monotonic_ms() & 65535


# Encodes a recursion-desired A/IN query for hostname with the given
# 16-bit id into out. A single trailing dot is accepted. Returns the
# encoded length, or 0 when the hostname is invalid (empty label,
# label over 63 bytes, encoded name over 255 bytes) or out_cap is too
# small.
int dns_build_query(char* hostname, int query_id, char* out, int out_cap):
	if (hostname == 0):
		return 0
	if ((hostname[0] == 0) | (out_cap < 17)):
		return 0
	out[0] = (query_id >> 8) & 255
	out[1] = query_id & 255
	out[2] = 1
	out[3] = 0
	out[4] = 0
	out[5] = 1
	out[6] = 0
	out[7] = 0
	out[8] = 0
	out[9] = 0
	out[10] = 0
	out[11] = 0
	int pos = 12
	int i = 0
	while (hostname[i] != 0):
		int label_length = 0
		while ((hostname[i + label_length] != 0) & (hostname[i + label_length] != '.')):
			label_length = label_length + 1
		if ((label_length == 0) | (label_length > 63)):
			return 0
		# Room for this label plus the name terminator and qtype/qclass.
		if (pos + 1 + label_length + 5 > out_cap):
			return 0
		# Encoded name cap: length bytes + labels + terminator <= 255.
		if (pos + 1 + label_length + 1 - 12 > 255):
			return 0
		out[pos] = label_length
		pos = pos + 1
		int j = 0
		while (j < label_length):
			out[pos] = hostname[i + j]
			pos = pos + 1
			j = j + 1
		i = i + label_length
		if (hostname[i] == '.'):
			# Skip the separator; a single trailing dot ends the loop.
			i = i + 1
	out[pos] = 0
	out[pos + 1] = 0
	out[pos + 2] = dns_type_a()
	out[pos + 3] = 0
	out[pos + 4] = dns_class_in()
	return pos + 5


int dns_read_u16(char* msg, int offset):
	return ((msg[offset] & 255) << 8) | (msg[offset + 1] & 255)


# Decodes a (possibly compressed) name starting at offset into out as
# dotted labels without a trailing dot (the root name decodes to "").
# Strict and bounded: compression pointers must point strictly
# backwards from their own position and are capped at
# dns_max_pointer_hops(); the decoded name is capped at 254 bytes;
# 0x40/0x80 label tags are rejected. Stores the offset just past the
# name at the top compression level into *out_end. Returns 1/0.
int dns_read_name(char* msg, int msg_len, int offset, char* out, int out_cap, int* out_end):
	int pos = offset
	int out_length = 0
	int hops = 0
	int end = 0 - 1
	while (1):
		if ((pos < 0) | (pos >= msg_len)):
			return 0
		int tag = msg[pos] & 255
		if (tag == 0):
			if (end < 0):
				end = pos + 1
			if (out_length >= out_cap):
				return 0
			out[out_length] = 0
			*out_end = end
			return 1
		if ((tag & 192) == 192):
			if (pos + 2 > msg_len):
				return 0
			int target = ((tag & 63) << 8) | (msg[pos + 1] & 255)
			if (target >= pos):
				return 0
			hops = hops + 1
			if (hops > dns_max_pointer_hops()):
				return 0
			if (end < 0):
				end = pos + 2
			pos = target
		else if ((tag & 192) != 0):
			return 0
		else:
			if (pos + 1 + tag > msg_len):
				return 0
			if (out_length > 0):
				if (out_length + 1 >= out_cap):
					return 0
				out[out_length] = '.'
				out_length = out_length + 1
			if (out_length + tag >= out_cap):
				return 0
			int j = 0
			while (j < tag):
				out[out_length] = msg[pos + 1 + j]
				out_length = out_length + 1
				j = j + 1
			if (out_length > 254):
				return 0
			pos = pos + 1 + tag
	return 0


int dns_parse_fail(char* name, char* target):
	free(name)
	free(target)
	return dns_result_error()


# Validates and parses a response to an A/IN query for hostname with
# id query_id. The echoed question must match; CNAME chains are
# followed in answer order within this message only, up to
# dns_max_cname_depth(). Returns dns_result_ok() with the host-order
# address in *out_ip, dns_result_truncated() when the TC bit demands a
# TCP retry, or dns_result_error() for anything malformed.
int dns_parse_response(char* msg, int msg_len, int query_id, char* hostname, int* out_ip):
	if ((msg == 0) | (hostname == 0)):
		return dns_result_error()
	if ((msg_len < 12) | (msg_len > 65535)):
		return dns_result_error()
	if (dns_read_u16(msg, 0) != (query_id & 65535)):
		return dns_result_error()
	int flags = dns_read_u16(msg, 2)
	if ((flags & 0x8000) == 0):
		# Not a response.
		return dns_result_error()
	if ((flags & 0x7800) != 0):
		# Opcode must be QUERY.
		return dns_result_error()
	if ((flags & 0x0200) != 0):
		return dns_result_truncated()
	if ((flags & 15) != 0):
		# Non-zero RCODE (NXDOMAIN, SERVFAIL, ...).
		return dns_result_error()
	if (dns_read_u16(msg, 4) != 1):
		return dns_result_error()
	int ancount = dns_read_u16(msg, 6)
	if (ancount > dns_max_answers()):
		return dns_result_error()

	# Echoed question must be our A/IN question for hostname.
	char* name = malloc(dns_name_buffer_size())
	char* target = strclone(hostname)
	int pos = 0
	if (dns_read_name(msg, msg_len, 12, name, dns_name_buffer_size(), &pos) == 0):
		return dns_parse_fail(name, target)
	if (dns_names_equal_ci(name, target) == 0):
		return dns_parse_fail(name, target)
	if (pos + 4 > msg_len):
		return dns_parse_fail(name, target)
	if (dns_read_u16(msg, pos) != dns_type_a()):
		return dns_parse_fail(name, target)
	if (dns_read_u16(msg, pos + 2) != dns_class_in()):
		return dns_parse_fail(name, target)
	pos = pos + 4

	int depth = 0
	int i = 0
	while (i < ancount):
		if (dns_read_name(msg, msg_len, pos, name, dns_name_buffer_size(), &pos) == 0):
			return dns_parse_fail(name, target)
		if (pos + 10 > msg_len):
			return dns_parse_fail(name, target)
		int rtype = dns_read_u16(msg, pos)
		int rclass = dns_read_u16(msg, pos + 2)
		int rdlength = dns_read_u16(msg, pos + 8)
		int rdata = pos + 10
		if (rdata + rdlength > msg_len):
			return dns_parse_fail(name, target)
		if (rclass != dns_class_in()):
			return dns_parse_fail(name, target)
		if (dns_names_equal_ci(name, target) != 0):
			if (rtype == dns_type_a()):
				if (rdlength != 4):
					return dns_parse_fail(name, target)
				*out_ip = ((msg[rdata] & 255) << 24) | ((msg[rdata + 1] & 255) << 16) | ((msg[rdata + 2] & 255) << 8) | (msg[rdata + 3] & 255)
				free(name)
				free(target)
				return dns_result_ok()
			if (rtype == dns_type_cname()):
				int cname_end = 0
				if (dns_read_name(msg, msg_len, rdata, name, dns_name_buffer_size(), &cname_end) == 0):
					return dns_parse_fail(name, target)
				if (cname_end > rdata + rdlength):
					return dns_parse_fail(name, target)
				depth = depth + 1
				if (depth > dns_max_cname_depth()):
					return dns_parse_fail(name, target)
				free(target)
				target = strclone(name)
		pos = rdata + rdlength
		i = i + 1
	free(name)
	free(target)
	return dns_result_error()


# Reads exactly want bytes from a (nonblocking) TCP socket, polling
# until deadline_ms (a time_monotonic_ms() timestamp). Returns 1/0.
int dns_tcp_recv_exact(int sock, char* buf, int want, int deadline_ms):
	int got = 0
	while (got < want):
		int remaining = deadline_ms - time_monotonic_ms()
		if (remaining <= 0):
			return 0
		int ready = poll_single(sock, poll_in(), remaining)
		if (ready <= 0):
			return 0
		int count = socket_recv(sock, buf + got, want - got, 0)
		if (count == 0 - net_eagain()):
			# EAGAIN: spurious wakeup, poll again.
			count = 0
		else if (count <= 0):
			# Error or EOF before the full message arrived.
			return 0
		got = got + count
	return 1


# TCP retry after a truncated UDP response: RFC 1035 4.2.2 two-byte
# length-prefixed messages over a connection to the same server. The
# whole exchange (connect, send, receive) shares one timeout budget.
# Returns 1 with the host-order address in *out_ip, else 0.
int dns_query_server_tcp(int server_ip, int server_port, char* hostname, int timeout_ms, int* out_ip):
	char* query = malloc(2 + dns_udp_message_max())
	int query_id = dns_random_id()
	int query_len = dns_build_query(hostname, query_id, query + 2, dns_udp_message_max())
	if (query_len == 0):
		free(query)
		return 0
	query[0] = (query_len >> 8) & 255
	query[1] = query_len & 255

	int sock = socket_tcp_ipv4()
	if (sock < 0):
		free(query)
		return 0
	int deadline = time_monotonic_ms() + timeout_ms
	if (socket_set_nonblocking(sock) < 0):
		close(sock)
		free(query)
		return 0
	int rc = socket_connect_ipv4(sock, server_ip, server_port)
	if (rc < 0):
		if (rc != (0 - net_einprogress())):
			# Anything but EINPROGRESS is a hard connect failure.
			close(sock)
			free(query)
			return 0
		int ready = poll_single(sock, poll_out(), timeout_ms)
		if (ready <= 0):
			close(sock)
			free(query)
			return 0
		if ((ready & poll_out()) == 0):
			close(sock)
			free(query)
			return 0
	int sent = write(sock, query, query_len + 2)
	free(query)
	if (sent != query_len + 2):
		close(sock)
		return 0

	char* header = malloc(2)
	if (dns_tcp_recv_exact(sock, header, 2, deadline) == 0):
		free(header)
		close(sock)
		return 0
	int response_len = dns_read_u16(header, 0)
	free(header)
	if ((response_len < 12) | (response_len > dns_tcp_message_max())):
		close(sock)
		return 0
	char* response = malloc(response_len)
	if (dns_tcp_recv_exact(sock, response, response_len, deadline) == 0):
		free(response)
		close(sock)
		return 0
	close(sock)
	int parsed = dns_parse_response(response, response_len, query_id, hostname, out_ip)
	free(response)
	if (parsed == dns_result_ok()):
		return 1
	return 0


# One A/IN query against a single server (host-order address,
# normally port 53): UDP first, TCP retry when the response is
# truncated. The response must come from the queried server and
# arrive within timeout_ms. Returns 1 with the host-order address in
# *out_ip, else 0.
int dns_query_server(int server_ip, int server_port, char* hostname, int timeout_ms, int* out_ip):
	char* query = malloc(dns_udp_message_max())
	int query_id = dns_random_id()
	int query_len = dns_build_query(hostname, query_id, query, dns_udp_message_max())
	if (query_len == 0):
		free(query)
		return 0
	int sock = socket_udp_ipv4()
	if (sock < 0):
		free(query)
		return 0
	int sent = socket_send_to_ipv4(sock, query, query_len, 0, server_ip, server_port)
	free(query)
	if (sent != query_len):
		close(sock)
		return 0
	int ready = poll_single(sock, poll_in(), timeout_ms)
	if (ready <= 0):
		close(sock)
		return 0
	if ((ready & poll_in()) == 0):
		close(sock)
		return 0
	char* response = malloc(dns_udp_message_max())
	sockaddr_in from
	int received = socket_recv_from_ipv4(sock, response, dns_udp_message_max(), 0, &from)
	close(sock)
	if (received <= 0):
		free(response)
		return 0
	# Only accept a datagram from the server we queried.
	if (net_htonl(from.ip_address) != server_ip):
		free(response)
		return 0
	if (net_htons(from.port) != server_port):
		free(response)
		return 0
	int parsed = dns_parse_response(response, received, query_id, hostname, out_ip)
	free(response)
	if (parsed == dns_result_ok()):
		return 1
	if (parsed == dns_result_truncated()):
		return dns_query_server_tcp(server_ip, server_port, hostname, timeout_ms, out_ip)
	return 0


char* dns_hosts_path():
	return c"/etc/hosts"


char* dns_resolv_conf_path():
	return c"/etc/resolv.conf"


# Resolves hostname to a host-order IPv4 address. Order: dotted-quad
# literals short-circuit, then /etc/hosts, then each resolv.conf
# nameserver over DNS with dns_default_timeout_ms() per server (TCP
# retry on truncation). With no usable nameserver entries the
# resolver falls back to 127.0.0.1, like libc resolvers. Returns 1
# with the address in *out_ip, else 0.
int dns_resolve_ipv4(char* hostname, int* out_ip):
	if (hostname == 0):
		return 0
	if (hostname[0] == 0):
		return 0
	if (dns_parse_ipv4_literal(hostname, out_ip) != 0):
		return 1
	if (dns_hosts_lookup_file(dns_hosts_path(), hostname, out_ip) != 0):
		return 1
	int* servers = malloc(dns_max_nameservers() * __word_size__)
	int count = dns_resolv_conf_nameservers_file(dns_resolv_conf_path(), servers, dns_max_nameservers())
	if (count == 0):
		servers[0] = ip4_from_string(c"127.0.0.1")
		count = 1
	int i = 0
	while (i < count):
		if (dns_query_server(servers[i], dns_port(), hostname, dns_default_timeout_ms(), out_ip) != 0):
			free(servers)
			return 1
		i = i + 1
	free(servers)
	return 0
