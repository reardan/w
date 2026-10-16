# DNS resolver for the pure-W HTTP stack (plan 11, issue #198, part of
# #155): A and AAAA records over UDP port 53 with a TCP retry when the
# server sets the TC (truncation) bit. Nameservers are reached over
# IPv4; AAAA answers and IPv6 /etc/hosts lines feed lib/net.w's
# AF_INET6 connects (stdlib parity P3.10).
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
#   void dns_cache_clear()                    flush answers and files
#   void dns_cache_set_enabled(int enabled)    opt out/in, flushing both
#   int dns_hosts_lookup_text/file(...)                   1/0
#   int dns_resolv_conf_nameservers_text/file(...)        count
#   int dns_build_query(char* hostname, int query_id, char* out,
#                       int out_cap)                      length or 0
#   int dns_parse_response(char* msg, int msg_len, int query_id,
#                          char* hostname, int* out_ip)   dns_result_*
# IPv6 / dual stack (16-byte network-order addresses):
#   int dns_resolve_addresses(char* hostname, net_address* out, int max)
#       count; IPv6-first interleaved (also _until, _config_until)
#   int dns_resolve_ipv6(char* hostname, char* out16)     1/0 (also _until)
#   int dns_query_server_aaaa(int server_ip, int server_port,
#       char* hostname, int timeout_ms, char* out16)      1/0
#   int dns_parse_ipv6_literal(char* text, char* out16)   "::1" or "[::1]"
#   int dns_hosts_lookup_ipv6_text(char* text, char* hostname, char* out16)
#   int dns_build_query_type(hostname, qtype, query_id, out, out_cap)
#   int dns_parse_response_aaaa(msg, msg_len, query_id, hostname,
#       char* out16, int* out_ttl)    dns_result_* incl. dns_result_nodata
import lib.lib
import lib.bytes
import lib.net
import lib.poll
import lib.io_wait
import lib.file
import lib.time
import lib.mem
import lib.stat
import lib.__arch__.budget_lock
import libs.standard.net.ipaddress


const int dns_port = 53
const int dns_default_timeout_ms = 2000
const int dns_max_nameservers = 3
const int dns_udp_message_max = 512
const int dns_tcp_message_max = 4096


# Longest decoded (presentation-form) name we accept, plus one for the
# terminating NUL: decode buffers are dns_name_buffer_size() bytes.
const int dns_name_buffer_size = 256
const int dns_max_cname_depth = 8
const int dns_max_pointer_hops = 32
const int dns_max_answers = 64
const int dns_type_a = 1
const int dns_type_cname = 5
const int dns_type_aaaa = 28
const int dns_class_in = 1


# dns_parse_response result codes.
const int dns_result_error = 0
const int dns_result_ok = 1
const int dns_result_truncated = 2
const int dns_result_nxdomain = 3
# The name exists but has no record of the queried type (NOERROR with
# no matching answer). Only the typed parsers return it; the A-only
# compatibility parsers report it as dns_result_error as before.
const int dns_result_nodata = 4
const int dns_cache_capacity = 64
const int dns_cache_ttl_max = 300
const int dns_cache_negative_ttl = 5


int dns_build_query_type(char* hostname, int qtype, int query_id, char* out, int out_cap);
int dns_parse_response_rdata(char* msg, int msg_len, int query_id, char* hostname, int qtype, char* out_rdata, int* out_ttl);
void dns_cache_store_typed(char* hostname, int qtype, int ip, char* ip6, int result, int ttl, int generation);


int dns_lower_char(int c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c


# Case-insensitive DNS name comparison. A single trailing dot on
# either side is ignored, so "example.com." equals "example.com".
int dns_names_equal_ci(char* a, char* b):
	int a_length = strlen(a)
	int b_length = strlen(b)
	if (a_length > 0):
		if (a[a_length - 1] == '.'): a_length = a_length - 1
	if (b_length > 0):
		if (b[b_length - 1] == '.'): b_length = b_length - 1
	if (a_length != b_length): return 0
	for i in range(a_length):
		if (dns_lower_char(a[i] & 255) != dns_lower_char(b[i] & 255)): return 0
	return 1


# Strict dotted-quad parser: exactly four decimal octets 0..255
# separated by dots, no leading zeros (avoids octal ambiguity), and
# nothing else. Returns 1 with the host-order address in *out_ip, or 0.
int dns_parse_ipv4_literal(char* text, int* out_ip):
	if (text == 0): return 0
	int value = 0
	int parts = 0
	int i = 0
	while (1):
		int digit_start = i
		int part_value = 0
		while ((text[i] >= '0') && (text[i] <= '9')):
			part_value = part_value * 10 + (text[i] - '0')
			i = i + 1
			if (i - digit_start > 3): return 0
		if (i == digit_start): return 0
		if ((i - digit_start > 1) && (text[digit_start] == '0')): return 0
		if (part_value > 255): return 0
		value = (value << 8) | part_value
		parts = parts + 1
		if (parts == 4):
			if (text[i] != 0): return 0
			*out_ip = value
			return 1
		if (text[i] != '.'): return 0
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
	while ((p < line_end) & (dns_is_space(text[p] & 255) != 0)): p = p + 1
	if (p >= line_end):
		*pos = line_end
		return 0
	if ((text[p] == '#') || (text[p] == ';')):
		*pos = line_end
		return 0
	*tok_start = p
	int done = 0
	while ((p < line_end) && (done == 0)):
		int c = text[p] & 255
		if ((dns_is_space(c) != 0) | (c == '#') || (c == ';')): done = 1
		else: p = p + 1
	*tok_end = p
	*pos = p
	return 1


# Parses text[start, end) as a dotted-quad address. Returns 1/0.
int dns_token_ipv4(char* text, int start, int end, int* out_ip):
	int length = end - start
	if ((length <= 0) || (length > 15)): return 0
	char* token = cast(char*, malloc(16))
	mem_copy(token, text + start, length)
	token[length] = 0
	int ok = dns_parse_ipv4_literal(token, out_ip)
	free(token)
	return ok


# Case-insensitive comparison of text[start, end) against name.
int dns_token_equals_ci(char* text, int start, int end, char* name):
	int length = end - start
	if (strlen(name) != length): return 0
	for i in range(length):
		if (dns_lower_char(text[start + i] & 255) != dns_lower_char(name[i] & 255)): return 0
	return 1


# Looks hostname up in hosts(5)-format text (the format of /etc/hosts):
# per line an address token followed by one or more names, '#' comments.
# Only IPv4 entries participate; the name match is case-insensitive.
# Returns 1 with the host-order address in *out_ip, or 0.
int dns_hosts_lookup_text(char* text, char* hostname, int* out_ip):
	if ((text == 0) || (hostname == 0)): return 0
	int i = 0
	while (text[i] != 0):
		int line_end = i
		while ((text[line_end] != 0) && (text[line_end] != 10)): line_end = line_end + 1
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
		if (text[i] == 10): i = i + 1
	return 0


# dns_hosts_lookup_text over a file (normally /etc/hosts). Returns 0
# when the file cannot be read.
int dns_hosts_lookup_file(char* path, char* hostname, int* out_ip):
	char* text = file_read_text(path)
	if (text == 0): return 0
	int found = dns_hosts_lookup_text(text, hostname, out_ip)
	free(text)
	return found


# Extracts up to max_servers IPv4 nameserver addresses from
# resolv.conf(5)-format text ("nameserver <address>" lines; '#'/';'
# comments). IPv6 and malformed entries are skipped. Returns the
# count stored into out_ips (host byte order).
int dns_resolv_conf_nameservers_text(char* text, int* out_ips, int max_servers):
	if ((text == 0) || (max_servers <= 0)): return 0
	int count = 0
	int i = 0
	while ((text[i] != 0) && (count < max_servers)):
		int line_end = i
		while ((text[line_end] != 0) && (text[line_end] != 10)): line_end = line_end + 1
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
		if (text[i] == 10): i = i + 1
	return count


# dns_resolv_conf_nameservers_text over a file (normally
# /etc/resolv.conf). Returns 0 when the file cannot be read.
int dns_resolv_conf_nameservers_file(char* path, int* out_ips, int max_servers):
	char* text = file_read_text(path)
	if (text == 0): return 0
	int count = dns_resolv_conf_nameservers_text(text, out_ips, max_servers)
	free(text)
	return count


# 16-bit query id from /dev/urandom so answers are hard to spoof.
# TODO(#193): switch to libs.standard.crypto.random once it lands.
int dns_random_id():
	int file = open(c"/dev/urandom", 0, 0)
	if (file >= 0):
		char* buf = cast(char*, malloc(2))
		int count = read(file, buf, 2)
		close(file)
		int id = load_be16(buf)
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
	return dns_build_query_type(hostname, dns_type_a, query_id, out, out_cap)


# dns_build_query for any qtype (dns_type_a, dns_type_aaaa, ...).
int dns_build_query_type(char* hostname, int qtype, int query_id, char* out, int out_cap):
	if (hostname == 0): return 0
	if ((hostname[0] == 0) || (out_cap < 17)): return 0
	store_be16(out, query_id)
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
		while ((hostname[i + label_length] != 0) && (hostname[i + label_length] != '.')):
			label_length = label_length + 1
		if ((label_length == 0) || (label_length > 63)): return 0
		# Room for this label plus the name terminator and qtype/qclass.
		if (pos + 1 + label_length + 5 > out_cap): return 0
		# Encoded name cap: length bytes + labels + terminator <= 255.
		if (pos + 1 + label_length + 1 - 12 > 255): return 0
		out[pos] = label_length
		pos = pos + 1
		for j in range(label_length):
			out[pos] = hostname[i + j]
			pos = pos + 1
		i = i + label_length
		if (hostname[i] == '.'):
			# Skip the separator; a single trailing dot ends the loop.
			i = i + 1
	out[pos] = 0
	out[pos + 1] = (qtype >> 8) & 255
	out[pos + 2] = qtype & 255
	out[pos + 3] = 0
	out[pos + 4] = dns_class_in
	return pos + 5


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
		if ((pos < 0) || (pos >= msg_len)): return 0
		int tag = msg[pos] & 255
		if (tag == 0):
			if (end < 0): end = pos + 1
			if (out_length >= out_cap): return 0
			out[out_length] = 0
			*out_end = end
			return 1
		if ((tag & 192) == 192):
			if (pos + 2 > msg_len): return 0
			int target = ((tag & 63) << 8) | (msg[pos + 1] & 255)
			if (target >= pos): return 0
			hops = hops + 1
			if (hops > dns_max_pointer_hops): return 0
			if (end < 0): end = pos + 2
			pos = target
		else if ((tag & 192) != 0): return 0
		else:
			if (pos + 1 + tag > msg_len): return 0
			if (out_length > 0):
				if (out_length + 1 >= out_cap): return 0
				out[out_length] = '.'
				out_length = out_length + 1
			if (out_length + tag >= out_cap): return 0
			for j in range(tag):
				out[out_length] = msg[pos + 1 + j]
				out_length = out_length + 1
			if (out_length > 254): return 0
			pos = pos + 1 + tag
	return 0


int dns_parse_fail(char* name, char* target):
	free(name)
	free(target)
	return dns_result_error


# Validates and parses a response to an A/IN query for hostname with
# id query_id. The echoed question must match; CNAME chains are
# followed in answer order within this message only, up to
# dns_max_cname_depth(). Returns dns_result_ok() with the host-order
# address in *out_ip, dns_result_truncated() when the TC bit demands a
# TCP retry, dns_result_nxdomain for a matching NXDOMAIN question, or
# dns_result_error for anything malformed. out_ttl is capped and includes
# every followed CNAME as well as the final A record.
int dns_parse_response_ttl(char* msg, int msg_len, int query_id, char* hostname, int* out_ip, int* out_ttl):
	char* rdata = cast(char*, malloc(4))
	int result = dns_parse_response_rdata(msg, msg_len, query_id, hostname, dns_type_a, rdata, out_ttl)
	if (result == dns_result_ok): *out_ip = load_be32(rdata)
	free(rdata)
	if (result == dns_result_nodata):
		*out_ttl = 0
		return dns_result_error
	return result


# Record data length for the address types this resolver answers.
int dns_rdata_length(int qtype):
	if (qtype == dns_type_aaaa): return 16
	return 4


# Typed core of dns_parse_response_ttl: validates a response to a
# qtype/IN query and copies the first matching record's rdata
# (dns_rdata_length(qtype) bytes, network order) into out_rdata.
# Additionally returns dns_result_nodata (with the negative TTL) when a
# NOERROR response holds no record of that type for the name.
int dns_parse_response_rdata(char* msg, int msg_len, int query_id, char* hostname, int qtype, char* out_rdata, int* out_ttl):
	*out_ttl = 0
	if ((msg == 0) || (hostname == 0)):
		return dns_result_error
	if ((msg_len < 12) || (msg_len > 65535)):
		return dns_result_error
	if (load_be16(msg) != (query_id & 65535)):
		return dns_result_error
	int flags = load_be16(msg + 2)
	if ((flags & 0x8000) == 0):
		# Not a response.
		return dns_result_error
	if ((flags & 0x7800) != 0):
		# Opcode must be QUERY.
		return dns_result_error
	if ((flags & 0x0200) != 0):
		return dns_result_truncated
	if (((flags & 15) != 0) && ((flags & 15) != 3)):
		# Transient errors are never negatively cached.
		return dns_result_error
	if (load_be16(msg + 4) != 1):
		return dns_result_error
	int ancount = load_be16(msg + 6)
	if (ancount > dns_max_answers):
		return dns_result_error

	# Echoed question must be our qtype/IN question for hostname.
	char* name = cast(char*, malloc(dns_name_buffer_size))
	char* target = strclone(hostname)
	int pos = 0
	if (dns_read_name(msg, msg_len, 12, name, dns_name_buffer_size, &pos) == 0):
		return dns_parse_fail(name, target)
	if (dns_names_equal_ci(name, target) == 0): return dns_parse_fail(name, target)
	if (pos + 4 > msg_len): return dns_parse_fail(name, target)
	if (load_be16(msg + pos) != qtype): return dns_parse_fail(name, target)
	if (load_be16(msg + pos + 2) != dns_class_in): return dns_parse_fail(name, target)
	pos = pos + 4

	if ((flags & 15) == 3):
		free(name)
		free(target)
		*out_ttl = dns_cache_negative_ttl
		return dns_result_nxdomain

	int depth = 0
	int ttl = dns_cache_ttl_max
	for i in range(ancount):
		if (dns_read_name(msg, msg_len, pos, name, dns_name_buffer_size, &pos) == 0):
			return dns_parse_fail(name, target)
		if (pos + 10 > msg_len): return dns_parse_fail(name, target)
		int rtype = load_be16(msg + pos)
		int rclass = load_be16(msg + pos + 2)
		int rdlength = load_be16(msg + pos + 8)
		int rdata = pos + 10
		if (rdata + rdlength > msg_len): return dns_parse_fail(name, target)
		if (rclass != dns_class_in): return dns_parse_fail(name, target)
		if (dns_names_equal_ci(name, target) != 0):
			# Clamp before arithmetic: wire TTL is unsigned even on x86.
			int record_ttl = load_be16(msg + pos + 6)
			if (load_be16(msg + pos + 4) != 0): record_ttl = dns_cache_ttl_max
			if ((rtype == qtype) || (rtype == dns_type_cname)):
				if (record_ttl < ttl): ttl = record_ttl
			if (rtype == qtype):
				if (rdlength != dns_rdata_length(qtype)): return dns_parse_fail(name, target)
				for j in range(rdlength): out_rdata[j] = msg[rdata + j]
				*out_ttl = ttl
				free(name)
				free(target)
				return dns_result_ok
			if (rtype == dns_type_cname):
				int cname_end = 0
				if (dns_read_name(msg, msg_len, rdata, name, dns_name_buffer_size, &cname_end) == 0):
					return dns_parse_fail(name, target)
				if (cname_end > rdata + rdlength): return dns_parse_fail(name, target)
				depth = depth + 1
				if (depth > dns_max_cname_depth): return dns_parse_fail(name, target)
				free(target)
				target = strclone(name)
		pos = rdata + rdlength
	free(name)
	free(target)
	# Every answer parsed, none for the name and type: NODATA (any
	# authority/additional sections, such as the SOA, are not read).
	*out_ttl = dns_cache_negative_ttl
	return dns_result_nodata


# AAAA form of dns_parse_response_ttl: out16 gets the 16 network-order
# address bytes. Returns dns_result_ok, _nodata, _nxdomain, _truncated
# or _error.
int dns_parse_response_aaaa(char* msg, int msg_len, int query_id, char* hostname, char* out16, int* out_ttl):
	return dns_parse_response_rdata(msg, msg_len, query_id, hostname, dns_type_aaaa, out16, out_ttl)


# Compatibility parser: callers that only need an address keep the original
# result codes. The TTL variant additionally distinguishes validated NXDOMAIN.
int dns_parse_response(char* msg, int msg_len, int query_id, char* hostname, int* out_ip):
	int ttl = 0
	int result = dns_parse_response_ttl(msg, msg_len, query_id, hostname, out_ip, &ttl)
	if (result == dns_result_nxdomain): return dns_result_error
	return result


# Reads exactly want bytes from a (nonblocking) TCP socket, polling
# until deadline_ms (a time_monotonic_ms() timestamp). Returns 1/0.
int dns_tcp_recv_exact(int sock, char* buf, int want, int deadline_ms):
	int got = 0
	while (got < want):
		int remaining = deadline_ms - time_monotonic_ms()
		if (remaining <= 0): return 0
		int ready = io_poll(sock, poll_in, remaining)
		if (ready <= 0): return 0
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
# Returns dns_result_ok with the address/TTL, dns_result_nxdomain, or 0.
# Typed core: qtype's rdata lands in out_rdata; also returns
# dns_result_nodata.
int dns_query_server_tcp_rdata(int server_ip, int server_port, char* hostname, int qtype, int timeout_ms, char* out_rdata, int* out_ttl):
	char* query = cast(char*, malloc(2 + dns_udp_message_max))
	int query_id = dns_random_id()
	int query_len = dns_build_query_type(hostname, qtype, query_id, query + 2, dns_udp_message_max)
	if (query_len == 0):
		free(query)
		return 0
	store_be16(query, query_len)

	int deadline = time_monotonic_ms() + timeout_ms
	int sock = net_connect_timeout(server_ip, server_port, timeout_ms)
	if (sock < 0):
		free(query)
		return 0
	int sent = write(sock, query, query_len + 2)
	free(query)
	if (sent != query_len + 2):
		close(sock)
		return 0

	char* header = cast(char*, malloc(2))
	if (dns_tcp_recv_exact(sock, header, 2, deadline) == 0):
		free(header)
		close(sock)
		return 0
	int response_len = load_be16(header)
	free(header)
	if ((response_len < 12) || (response_len > dns_tcp_message_max)):
		close(sock)
		return 0
	char* response = cast(char*, malloc(response_len))
	if (dns_tcp_recv_exact(sock, response, response_len, deadline) == 0):
		free(response)
		close(sock)
		return 0
	close(sock)
	int parsed = dns_parse_response_rdata(response, response_len, query_id, hostname, qtype, out_rdata, out_ttl)
	free(response)
	if (parsed == dns_result_ok || parsed == dns_result_nxdomain || parsed == dns_result_nodata): return parsed
	return 0


# Maps a typed A result back to the int-address API (NODATA was never
# reported there; it stays a plain failure).
int dns_result_ipv4(int result, char* rdata, int* out_ip, int* out_ttl):
	if (result == dns_result_ok): *out_ip = load_be32(rdata)
	free(rdata)
	if (result == dns_result_nodata):
		*out_ttl = 0
		return 0
	return result


int dns_query_server_tcp_ttl(int server_ip, int server_port, char* hostname, int timeout_ms, int* out_ip, int* out_ttl):
	char* rdata = cast(char*, malloc(4))
	int result = dns_query_server_tcp_rdata(server_ip, server_port, hostname, dns_type_a, timeout_ms, rdata, out_ttl)
	return dns_result_ipv4(result, rdata, out_ip, out_ttl)


# One qtype/IN query against a single server (host-order address,
# normally port 53): UDP first, TCP retry when the response is
# truncated. The response must come from the queried server and
# arrive within timeout_ms. Returns dns_result_ok with address/TTL,
# dns_result_nxdomain with the negative TTL, or 0.
int dns_query_server_rdata(int server_ip, int server_port, char* hostname, int qtype, int timeout_ms, char* out_rdata, int* out_ttl):
	*out_ttl = 0
	int deadline = time_monotonic_ms() + timeout_ms
	if (timeout_ms <= 0 || io_check() < 0): return 0
	char* query = cast(char*, malloc(dns_udp_message_max))
	int query_id = dns_random_id()
	int query_len = dns_build_query_type(hostname, qtype, query_id, query, dns_udp_message_max)
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
	int ready = io_poll(sock, poll_in, timeout_ms)
	if (ready <= 0):
		close(sock)
		return 0
	if ((ready & poll_in) == 0):
		close(sock)
		return 0
	char* response = cast(char*, malloc(dns_udp_message_max))
	sockaddr_in from
	int received = socket_recv_from_ipv4(sock, response, dns_udp_message_max, 0, &from)
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
	int parsed = dns_parse_response_rdata(response, received, query_id, hostname, qtype, out_rdata, out_ttl)
	free(response)
	if (parsed == dns_result_ok || parsed == dns_result_nxdomain || parsed == dns_result_nodata): return parsed
	if (parsed == dns_result_truncated):
		int remaining = deadline - time_monotonic_ms()
		if (remaining <= 0): return 0
		return dns_query_server_tcp_rdata(server_ip, server_port, hostname, qtype, remaining, out_rdata, out_ttl)
	return 0


# One A/IN query (see dns_query_server_rdata).
int dns_query_server_ttl(int server_ip, int server_port, char* hostname, int timeout_ms, int* out_ip, int* out_ttl):
	char* rdata = cast(char*, malloc(4))
	int result = dns_query_server_rdata(server_ip, server_port, hostname, dns_type_a, timeout_ms, rdata, out_ttl)
	return dns_result_ipv4(result, rdata, out_ip, out_ttl)


# Explicit-server queries intentionally bypass the process cache.
int dns_query_server(int server_ip, int server_port, char* hostname, int timeout_ms, int* out_ip):
	int ttl = 0
	return dns_query_server_ttl(server_ip, server_port, hostname, timeout_ms, out_ip, &ttl) == dns_result_ok


int dns_query_server_tcp(int server_ip, int server_port, char* hostname, int timeout_ms, int* out_ip):
	int ttl = 0
	return dns_query_server_tcp_ttl(server_ip, server_port, hostname, timeout_ms, out_ip, &ttl) == dns_result_ok


# One AAAA/IN query (UDP, TCP on truncation); out16 gets the address in
# network order. Bypasses the cache. Returns 1/0.
int dns_query_server_aaaa(int server_ip, int server_port, char* hostname, int timeout_ms, char* out16):
	int ttl = 0
	return dns_query_server_rdata(server_ip, server_port, hostname, dns_type_aaaa, timeout_ms, out16, &ttl) == dns_result_ok


char* dns_hosts_path():
	return c"/etc/hosts"


char* dns_resolv_conf_path():
	return c"/etc/resolv.conf"


# Process-wide cache. The lock serializes ownership and config refresh;
# it is never held across DNS network I/O. Like shared budgets, concurrent
# callers are qualified on Linux x86/x64. Other hosts use the same serial API.
struct dns_cache_entry:
	char* name
	int ip
	int qtype           # dns_type_a or dns_type_aaaa
	char* ip6           # 16 network-order bytes for AAAA entries, else 0
	int result
	int expires
	int created_seconds
	int ttl_seconds
	dns_cache_entry* next


struct dns_config_cache:
	char* path
	char* text
	int mtime
	int mtime_ns
	int size
	int ino
	int stamped
	dns_cache_entry* hosts
	int* servers
	int count


int dns_cache_lock = 0
int dns_cache_enabled = 1
int dns_cache_generation = 0
int dns_cache_server_port = 0
dns_cache_entry* dns_cache_answers = 0
dns_config_cache* dns_cache_hosts = 0
dns_config_cache* dns_cache_resolv = 0


void dns_cache_entries_free(dns_cache_entry* entry):
	while (entry != 0):
		dns_cache_entry* next = entry.next
		free(entry.name)
		if (entry.ip6 != 0): free(entry.ip6)
		free(entry)
		entry = next


void dns_cache_answers_clear():
	dns_cache_entries_free(dns_cache_answers)
	dns_cache_answers = 0
	dns_cache_generation += 1


void dns_cache_config_free(dns_config_cache* config):
	if (config == 0): return
	free(config.path)
	free(config.text)
	free(config.servers)
	dns_cache_entries_free(config.hosts)
	free(config)


# Flush both answer and parsed-file caches. In-flight lookups cannot
# repopulate a cache flushed while their network exchange was running.
void dns_cache_clear():
	budget_lock_enter(&dns_cache_lock)
	dns_cache_answers_clear()
	dns_cache_config_free(dns_cache_hosts)
	dns_cache_config_free(dns_cache_resolv)
	dns_cache_hosts = 0
	dns_cache_resolv = 0
	budget_lock_leave(&dns_cache_lock)


# Set to zero to opt out of both answer and parsed-file reuse. Flushes
# on every transition, including re-enabling, so old answers never revive.
void dns_cache_set_enabled(int enabled):
	budget_lock_enter(&dns_cache_lock)
	dns_cache_enabled = enabled != 0
	dns_cache_answers_clear()
	dns_cache_config_free(dns_cache_hosts)
	dns_cache_config_free(dns_cache_resolv)
	dns_cache_hosts = 0
	dns_cache_resolv = 0
	budget_lock_leave(&dns_cache_lock)


# Parses text[start, end) as an IPv6 address without a zone into 16
# network-order bytes at out16. Returns 1/0.
int dns_token_ipv6(char* text, int start, int end, char* out16):
	ip_address address
	if (ipv6_parse_range(text, start, end, &address) == 0): return 0
	ip_address_packed(&address, out16)
	return 1


# Parse all IPv4 and IPv6 aliases once, preserving hosts-file order.
dns_cache_entry* dns_cache_parse_hosts(char* text):
	dns_cache_entry* head = 0
	dns_cache_entry* tail = 0
	int i = 0
	while (text[i] != 0):
		int end = i
		while (text[end] != 0 && text[end] != 10): end += 1
		int pos = i
		int start = 0
		int stop = 0
		int ip = 0
		char* ip6 = cast(char*, malloc(16))
		if (dns_next_token(text, &pos, end, &start, &stop)):
			int qtype = 0
			if (dns_token_ipv4(text, start, stop, &ip)): qtype = dns_type_a
			else if (dns_token_ipv6(text, start, stop, ip6)): qtype = dns_type_aaaa
			if (qtype != 0):
				while (dns_next_token(text, &pos, end, &start, &stop)):
					dns_cache_entry* entry = new dns_cache_entry()
					entry.name = cast(char*, malloc(stop - start + 1))
					mem_copy(entry.name, text + start, stop - start)
					entry.name[stop - start] = 0
					entry.ip = ip
					entry.qtype = qtype
					if (qtype == dns_type_aaaa):
						entry.ip6 = cast(char*, malloc(16))
						mem_copy(entry.ip6, ip6, 16)
					if (tail == 0): head = entry
					else: tail.next = entry
					tail = entry
		free(ip6)
		i = end
		if (text[i] == 10): i += 1
	return head


# Called with the cache lock held. statx gives nanosecond mtime plus
# inode/size, catching same-second rewrites and atomic file replacement.
# On hosts whose statx wrapper is unavailable (currently Darwin), compare
# freshly read text instead; answers still cache, and file edits stay visible.
dns_config_cache* dns_cache_config_load(dns_config_cache* old, char* path, int hosts):
	char* stamp = cast(char*, malloc(FILE_STATX_BUF_SIZE))
	int stamped = statx(path, 0, FILE_STATX_BASIC_STATS, stamp) == 0
	int mtime = 0
	int mtime_ns = 0
	int size = 0
	int ino = 0
	if (stamped):
		mtime = load_word(stamp + FILE_STATX_MTIME_OFFSET)
		mtime_ns = load_int(stamp + FILE_STATX_MTIME_OFFSET + 8)
		size = load_word(stamp + FILE_STATX_SIZE_OFFSET)
		ino = load_word(stamp + FILE_STATX_INO_OFFSET)
	free(stamp)
	int same_path = 0
	if (old != 0): same_path = strcmp(old.path, path) == 0
	if (dns_cache_enabled && same_path && stamped && old.stamped):
		if (mtime == old.mtime && mtime_ns == old.mtime_ns && size == old.size && ino == old.ino): return old
	char* text = file_read_text(path)
	if (text == 0):
		text = strclone(c"")
		stamped = 0
	if (dns_cache_enabled && same_path && strcmp(old.text, text) == 0):
		free(text)
	else:
		dns_cache_answers_clear()
		dns_cache_config_free(old)
		old = new dns_config_cache()
		old.path = strclone(path)
		old.text = text
		if (hosts): old.hosts = dns_cache_parse_hosts(text)
		else:
			old.servers = cast(int*, malloc(dns_max_nameservers * __word_size__))
			old.count = dns_resolv_conf_nameservers_text(text, old.servers, dns_max_nameservers)
			if (old.count == 0):
				old.servers[0] = ip4_from_string(c"127.0.0.1")
				old.count = 1
	old.stamped = stamped
	old.mtime = mtime
	old.mtime_ns = mtime_ns
	old.size = size
	old.ino = ino
	return old


# Keep a seconds timestamp alongside precise millisecond expiry. The
# millisecond counter wraps on x86: subtraction alone can make an entry
# retained for over 24.8 days appear live again. The seconds age guard
# rejects that entry, including after a complete millisecond wrap.
int dns_cache_read_seconds(int* out_seconds):
	timespec ts
	if (sys_clock_gettime(clock_monotonic, cast(int, &ts)) < 0): return 0
	*out_seconds = ts.seconds
	return 1


# Caller holds the cache lock. Clock reversal/seconds-counter wrap
# conservatively invalidates entries; a clock failure bypasses caching.
int dns_cache_find_typed_at_time(char* hostname, int qtype, int* out_ip, char* out_ip6, int now_ms, int now_seconds):
	if (dns_cache_enabled == 0): return 0
	dns_cache_entry* entry = dns_cache_answers
	while (entry != 0):
		if (now_seconds >= entry.created_seconds && now_seconds - entry.created_seconds <= entry.ttl_seconds):
			if (entry.qtype == qtype && dns_names_equal_ci(entry.name, hostname) && entry.expires - now_ms > 0):
				if (entry.result == dns_result_ok):
					if (qtype == dns_type_aaaa): mem_copy(out_ip6, entry.ip6, 16)
					else: *out_ip = entry.ip
				return entry.result
		entry = entry.next
	return 0


int dns_cache_find_at_time(char* hostname, int* out_ip, int now_ms, int now_seconds):
	return dns_cache_find_typed_at_time(hostname, dns_type_a, out_ip, 0, now_ms, now_seconds)


int dns_cache_find_at(char* hostname, int* out_ip, int now_ms):
	int now_seconds = 0
	if (dns_cache_read_seconds(&now_seconds) == 0): return 0
	return dns_cache_find_at_time(hostname, out_ip, now_ms, now_seconds)


void dns_cache_store(char* hostname, int ip, int result, int ttl, int generation):
	dns_cache_store_typed(hostname, dns_type_a, ip, 0, result, ttl, generation)


# ip6: 16 network-order bytes for an ok AAAA answer, else 0.
void dns_cache_store_typed(char* hostname, int qtype, int ip, char* ip6, int result, int ttl, int generation):
	budget_lock_enter(&dns_cache_lock)
	int now_seconds = 0
	if (dns_cache_enabled && generation == dns_cache_generation && ttl > 0 && dns_cache_read_seconds(&now_seconds)):
		if (ttl > dns_cache_ttl_max): ttl = dns_cache_ttl_max
		dns_cache_entry* entry = new dns_cache_entry()
		entry.name = strclone(hostname)
		entry.ip = ip
		entry.qtype = qtype
		if (ip6 != 0):
			entry.ip6 = cast(char*, malloc(16))
			mem_copy(entry.ip6, ip6, 16)
		entry.result = result
		entry.created_seconds = now_seconds
		entry.ttl_seconds = ttl
		entry.expires = time_monotonic_ms() + ttl * 1000
		entry.next = dns_cache_answers
		dns_cache_answers = entry
		# Bound memory independently of expired/duplicate keys.
		for i in range(1, dns_cache_capacity):
			if (entry.next == 0): break
			entry = entry.next
		dns_cache_entries_free(entry.next)
		entry.next = 0
	budget_lock_leave(&dns_cache_lock)


# Resolver with explicit configuration files and DNS port, for embedders
# and offline tests. Changing the configuration invalidates cached answers.
# The ordinary entry points below use system files and port 53.
int dns_resolve_ipv4_config_until(char* hostname, int* out_ip, int deadline_ms, char* hosts_path, char* resolv_path, int server_port):
	if (hostname == 0): return 0
	if (hostname[0] == 0 || io_check() < 0): return 0
	if (deadline_ms - time_monotonic_ms() <= 0): return 0
	if (dns_parse_ipv4_literal(hostname, out_ip)): return 1
	int* servers = cast(int*, malloc(dns_max_nameservers * __word_size__))
	budget_lock_enter(&dns_cache_lock)
	dns_cache_hosts = dns_cache_config_load(dns_cache_hosts, hosts_path, 1)
	dns_cache_resolv = dns_cache_config_load(dns_cache_resolv, resolv_path, 0)
	if (server_port != dns_cache_server_port):
		dns_cache_answers_clear()
		dns_cache_server_port = server_port
	int result = 0
	dns_cache_entry* host = dns_cache_hosts.hosts
	while (host != 0 && result == 0):
		if (host.qtype == dns_type_a && dns_names_equal_ci(host.name, hostname)):
			*out_ip = host.ip
			result = dns_result_ok
		host = host.next
	if (result == 0): result = dns_cache_find_at(hostname, out_ip, time_monotonic_ms())
	int count = dns_cache_resolv.count
	for i in range(count): servers[i] = dns_cache_resolv.servers[i]
	int generation = dns_cache_generation
	budget_lock_leave(&dns_cache_lock)
	int ttl = 0
	int ip = 0
	int i = 0
	while (i < count && result == 0):
		int remaining = deadline_ms - time_monotonic_ms()
		if (remaining <= 0 || io_check() < 0): break
		if (remaining > dns_default_timeout_ms): remaining = dns_default_timeout_ms
		result = dns_query_server_ttl(servers[i], server_port, hostname, remaining, &ip, &ttl)
		if (result == dns_result_ok): *out_ip = ip
		if (result != 0): dns_cache_store(hostname, ip, result, ttl, generation)
		i += 1
	free(servers)
	if (deadline_ms - time_monotonic_ms() <= 0 || io_check() < 0): return 0
	return result == dns_result_ok


# Literals, parsed /etc/hosts, cached DNS answers, then nameservers in
# /etc/resolv.conf. Positive answers use the minimum CNAME/A TTL capped
# to 300s; validated NXDOMAIN uses 5s. Errors and TTL zero never cache.
int dns_resolve_ipv4(char* hostname, int* out_ip):
	return dns_resolve_ipv4_config_until(hostname, out_ip, time_monotonic_ms() + dns_max_nameservers * dns_default_timeout_ms, dns_hosts_path(), dns_resolv_conf_path(), dns_port)


# Resolution bounded across configured servers, UDP and TCP fallback.
# Cancellation/deadline are checked even when an answer is already cached.
int dns_resolve_ipv4_until(char* hostname, int* out_ip, int deadline_ms):
	return dns_resolve_ipv4_config_until(hostname, out_ip, deadline_ms, dns_hosts_path(), dns_resolv_conf_path(), dns_port)


/* AAAA resolution and dual-stack address lists (stdlib parity P3.10).
IPv6 addresses cross this API as 16 network-order bytes (the packed
form of ipaddress.w), ready for lib/net.w's sockaddr_in6 helpers. */

# How long the AAAA lookup may still run once the A lookup has already
# produced an address: a resolver that drops AAAA queries must not make
# IPv4-only names noticeably slower than before IPv6 support.
const int dns_aaaa_after_a_ms = 1000
const int dns_max_addresses = 16


# IPv6 literal, bare ("::1") or bracketed as in URLs ("[::1]"); zone ids
# are rejected. Returns 1 with the network-order bytes in out16, or 0.
int dns_parse_ipv6_literal(char* text, char* out16):
	if (text == 0): return 0
	int length = strlen(text)
	int start = 0
	int end = length
	if (length > 0 && text[0] == '['):
		if (text[length - 1] != ']'): return 0
		start = 1
		end = length - 1
	ip_address address
	if (ipv6_parse_range(text, start, end, &address) == 0): return 0
	ip_address_packed(&address, out16)
	return 1


# hosts(5) lookup of the first IPv6 entry for hostname (case-insensitive).
int dns_hosts_lookup_ipv6_text(char* text, char* hostname, char* out16):
	if ((text == 0) || (hostname == 0)): return 0
	dns_cache_entry* entries = dns_cache_parse_hosts(text)
	int found = 0
	dns_cache_entry* entry = entries
	while (entry != 0 && found == 0):
		if (entry.qtype == dns_type_aaaa && dns_names_equal_ci(entry.name, hostname)):
			mem_copy(out16, entry.ip6, 16)
			found = 1
		entry = entry.next
	dns_cache_entries_free(entries)
	return found


# AAAA counterpart of dns_resolve_ipv4_config_until: IPv6 literal,
# /etc/hosts IPv6 entries, cached answers (NODATA/NXDOMAIN cache for
# dns_cache_negative_ttl), then the nameservers. Returns 1/0.
int dns_resolve_ipv6_config_until(char* hostname, char* out16, int deadline_ms, char* hosts_path, char* resolv_path, int server_port):
	if (hostname == 0): return 0
	if (hostname[0] == 0 || io_check() < 0): return 0
	if (deadline_ms - time_monotonic_ms() <= 0): return 0
	if (dns_parse_ipv6_literal(hostname, out16)): return 1
	int unused_ip = 0
	if (dns_parse_ipv4_literal(hostname, &unused_ip)): return 0
	int* servers = cast(int*, malloc(dns_max_nameservers * __word_size__))
	budget_lock_enter(&dns_cache_lock)
	dns_cache_hosts = dns_cache_config_load(dns_cache_hosts, hosts_path, 1)
	dns_cache_resolv = dns_cache_config_load(dns_cache_resolv, resolv_path, 0)
	if (server_port != dns_cache_server_port):
		dns_cache_answers_clear()
		dns_cache_server_port = server_port
	int result = 0
	dns_cache_entry* host = dns_cache_hosts.hosts
	while (host != 0 && result == 0):
		if (host.qtype == dns_type_aaaa && dns_names_equal_ci(host.name, hostname)):
			mem_copy(out16, host.ip6, 16)
			result = dns_result_ok
		host = host.next
	if (result == 0):
		int now_seconds = 0
		if (dns_cache_read_seconds(&now_seconds)):
			result = dns_cache_find_typed_at_time(hostname, dns_type_aaaa, &unused_ip, out16, time_monotonic_ms(), now_seconds)
	int count = dns_cache_resolv.count
	for i in range(count): servers[i] = dns_cache_resolv.servers[i]
	int generation = dns_cache_generation
	budget_lock_leave(&dns_cache_lock)
	char* answer = cast(char*, malloc(16))
	int ttl = 0
	int i = 0
	while (i < count && result == 0):
		int remaining = deadline_ms - time_monotonic_ms()
		if (remaining <= 0 || io_check() < 0): break
		if (remaining > dns_default_timeout_ms): remaining = dns_default_timeout_ms
		result = dns_query_server_rdata(servers[i], server_port, hostname, dns_type_aaaa, remaining, answer, &ttl)
		if (result == dns_result_ok):
			mem_copy(out16, answer, 16)
			dns_cache_store_typed(hostname, dns_type_aaaa, 0, answer, result, ttl, generation)
		else if (result != 0): dns_cache_store_typed(hostname, dns_type_aaaa, 0, 0, result, ttl, generation)
		i += 1
	free(answer)
	free(servers)
	if (deadline_ms - time_monotonic_ms() <= 0 || io_check() < 0): return 0
	return result == dns_result_ok


int dns_resolve_ipv6(char* hostname, char* out16):
	return dns_resolve_ipv6_config_until(hostname, out16, time_monotonic_ms() + dns_max_nameservers * dns_default_timeout_ms, dns_hosts_path(), dns_resolv_conf_path(), dns_port)


int dns_resolve_ipv6_until(char* hostname, char* out16, int deadline_ms):
	return dns_resolve_ipv6_config_until(hostname, out16, deadline_ms, dns_hosts_path(), dns_resolv_conf_path(), dns_port)


# Dual-stack resolution for connecting clients. Fills out[0..max) and
# returns the count (0 on failure), in Happy-Eyeballs-lite order
# (net_addresses_interleave: IPv6 first, then alternating):
#   - an IPv4 or IPv6 literal (bare or "[...]") gives that one address;
#   - /etc/hosts entries of either family, when any match, are the
#     whole answer (as with glibc's files-before-dns);
#   - otherwise the A lookup runs first, then AAAA; once A has an
#     answer, AAAA gets at most dns_aaaa_after_a_ms more, so IPv4-only
#     names keep their old latency. One address per family from DNS.
int dns_resolve_addresses_config_until(char* hostname, net_address* out, int max, int deadline_ms, char* hosts_path, char* resolv_path, int server_port):
	if (hostname == 0 || max <= 0): return 0
	if (hostname[0] == 0 || io_check() < 0): return 0
	if (deadline_ms - time_monotonic_ms() <= 0): return 0
	int ip = 0
	char* ip6 = cast(char*, malloc(16))
	int count = 0
	if (dns_parse_ipv4_literal(hostname, &ip)):
		net_address_set_ipv4(&out[0], ip)
		count = 1
	else if (dns_parse_ipv6_literal(hostname, ip6)):
		net_address_set_ipv6(&out[0], ip6, 0)
		count = 1
	if (count > 0):
		free(ip6)
		return count
	budget_lock_enter(&dns_cache_lock)
	dns_cache_hosts = dns_cache_config_load(dns_cache_hosts, hosts_path, 1)
	dns_cache_entry* host = dns_cache_hosts.hosts
	while (host != 0 && count < max):
		if (dns_names_equal_ci(host.name, hostname)):
			if (host.qtype == dns_type_aaaa): net_address_set_ipv6(&out[count], host.ip6, 0)
			else: net_address_set_ipv4(&out[count], host.ip)
			count += 1
		host = host.next
	budget_lock_leave(&dns_cache_lock)
	if (count == 0):
		int have4 = dns_resolve_ipv4_config_until(hostname, &ip, deadline_ms, hosts_path, resolv_path, server_port)
		int deadline6 = deadline_ms
		if (have4):
			int capped = time_monotonic_ms() + dns_aaaa_after_a_ms
			if (capped - deadline6 < 0): deadline6 = capped
		int have6 = 0
		if (io_check() >= 0): have6 = dns_resolve_ipv6_config_until(hostname, ip6, deadline6, hosts_path, resolv_path, server_port)
		if (have6):
			net_address_set_ipv6(&out[count], ip6, 0)
			count += 1
		if (have4 && count < max):
			net_address_set_ipv4(&out[count], ip)
			count += 1
	free(ip6)
	if (io_check() < 0): return 0
	net_addresses_interleave(out, count)
	return count


int dns_resolve_addresses(char* hostname, net_address* out, int max):
	return dns_resolve_addresses_config_until(hostname, out, max, time_monotonic_ms() + dns_max_nameservers * dns_default_timeout_ms, dns_hosts_path(), dns_resolv_conf_path(), dns_port)


int dns_resolve_addresses_until(char* hostname, net_address* out, int max, int deadline_ms):
	return dns_resolve_addresses_config_until(hostname, out, max, deadline_ms, dns_hosts_path(), dns_resolv_conf_path(), dns_port)
