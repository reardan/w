# IPv4/IPv6 addresses and networks, after Python's ipaddress module
# (stdlib parity chunk P3.9; reference: CPython 3.13 Lib/ipaddress.py).
#
# Representation: every address is an ip_address value holding eight
# big-endian 16-bit groups in ints, so all arithmetic is 32-bit safe on
# x86. An IPv4 address lives in words[6] (high half) and words[7]; words
# 0..5 stay zero. Functions take pointers and write results into
# caller-owned structs, so parsing, comparison and the is_* checks never
# allocate. Only the char*-returning formatters allocate (caller frees).
#
# Python semantics kept on purpose:
#   - IPv4 parsing is strict like Python 3.9.5+: exactly four decimal
#     octets of 1-3 digits, no leading zeros ("01" is rejected), <= 255.
#   - IPv6 parsing follows _ip_int_from_string (one "::", up to 4 hex
#     digits per group, optional dotted IPv4 tail). ipv6_address_parse
#     keeps a zone id ("fe80::1%eth0", at most 31 bytes) in scope_id;
#     the *_parse_range functions and network parsing reject zones.
#   - Formatting is RFC 5952 (lowercase, first longest run of >= 2 zero
#     groups compressed); IPv4-mapped addresses print as ::ffff:1.2.3.4
#     as in Python 3.13. ipv6_format_hex never uses the dotted tail.
#   - Networks: strict=1 rejects set host bits, strict=0 masks them.
#     IPv4 networks also accept a dotted netmask or hostmask after '/'.
#   - Comparisons order IPv4 before IPv6 (Python raises TypeError);
#     equal IPv6 values order by scope_id (Python only tests equality).
#   - is_private / is_global / ... use Python 3.13's IANA tables,
#     including the IPv4-mapped delegation for IPv6 addresses.
#
# Counts that may exceed the word size (num_addresses of a /0, subnet
# counts) return the value when it fits in a positive int and set
# *fits; otherwise they return 0 and clear *fits. ip_network_host_bits
# gives the exact log2, and ip_network_num_addresses_text the decimal.
#
# Public API (all int results are 1/0 unless stated):
#   int ip_address_parse(char* text, ip_address* out)    v4, then v6
#   int ipv4_address_parse(char* text, ip_address* out)
#   int ipv6_address_parse(char* text, ip_address* out)
#   int ipv4_parse_range / ipv6_parse_range(char* text, int start, int end, ip_address* out)
#   void ip_address_from_ipv4_int(int value, ip_address* out)
#   int ip_address_to_ipv4_int(ip_address* a)            32-bit pattern
#   void ip_address_packed(ip_address* a, char* out)      4 or 16 bytes
#   int ip_address_from_packed(char* data, int length, ip_address* out)
#   char* ip_address_format / ipv6_format_hex / ip_address_exploded /
#         ip_address_reverse_pointer(ip_address* a)       malloc'd
#   int ip_address_compare(a, b)  -1/0/1;  int ip_address_equal(a, b)
#   int ip_address_add(ip_address* a, int delta, ip_address* out)  0 on overflow
#   int ip_max_prefixlen(int version)                     32 or 128
#   int ipv6_ipv4_mapped / ipv6_sixtofour(ip_address* a, ip_address* out)
#   int ipv6_teredo(ip_address* a, ip_address* server, ip_address* client)
#   void ipv4_to_ipv6_mapped(ip_address* a, ip_address* out)
#   int ip_address_is_private / is_global / is_loopback / is_link_local /
#       is_multicast / is_unspecified / is_reserved / is_site_local(a)
#   int ip_network_parse(char* text, int strict, ip_network* out)
#   int ipv4_network_parse / ipv6_network_parse(char* text, int strict, ip_network* out)
#   int ip_network_make(ip_address* a, int prefixlen, int strict, ip_network* out)
#   char* ip_network_format / ip_network_with_netmask / ip_network_with_hostmask(n)
#   void ip_network_netmask / ip_network_hostmask / ip_network_broadcast(n, ip_address* out)
#   int ip_network_contains(n, ip_address* a)
#   int ip_network_overlaps / ip_network_subnet_of / ip_network_supernet_of(a, b)
#   int ip_network_compare(a, b);  int ip_network_equal(a, b)
#   int ip_network_host_bits(n)
#   int ip_network_num_addresses(n, int* fits);  char* ip_network_num_addresses_text(n)
#   int ip_network_address_at(n, int index, ip_address* out)  negative from the end
#   int ip_network_supernet(n, int new_prefix, ip_network* out)
#   int ip_network_subnet_count(n, int new_prefix, int* fits)
#   int ip_network_subnet_at(n, int new_prefix, int index, ip_network* out)
#   void ip_network_addresses / ip_network_hosts(n, ip_address_iterator* it)
#   int ip_address_iterator_next(ip_address_iterator* it, ip_address* out)
#   int ip_network_is_private / is_global / is_loopback / is_link_local /
#       is_multicast / is_unspecified / is_reserved / is_site_local(n)
#   Plan-08 helpers on 32-bit patterns: ipv4_parse(text, int* out),
#   char* ipv4_format(int address), ipv4_in_network(address, network, prefix)
import lib.lib
import lib.hex
import structures.string


struct ip_address:
	int version
	int[8] words
	char[32] scope_id    # IPv6 zone ("eth0"), "" when absent


# Zone ids longer than this are rejected (Python has no limit).
int IP_SCOPE_ID_MAX = 31


struct ip_network:
	ip_address address
	int prefixlen


# Walks network addresses in order; filled by ip_network_addresses or
# ip_network_hosts, drained by ip_address_iterator_next.
struct ip_address_iterator:
	ip_address next
	ip_address last
	int done


int ip_max_prefixlen(int version):
	if (version == 4): return 32
	return 128


int ip__first_word(int version):
	if (version == 4): return 6
	return 0


void ip__clear(ip_address* out, int version):
	out.version = version
	out.scope_id[0] = 0
	for i in range(8): out.words[i] = 0


void ip__copy(ip_address* src, ip_address* out):
	out.version = src.version
	for i in range(8): out.words[i] = src.words[i]
	for i in range(IP_SCOPE_ID_MAX + 1): out.scope_id[i] = src.scope_id[i]


# ---- parsing ---------------------------------------------------------

int ip__is_digit(int c):
	return c >= '0' && c <= '9'


# Dotted IPv4 in text[start, end), strict like Python 3.9.5+.
int ipv4_parse_range(char* text, int start, int end, ip_address* out):
	if (text == 0 || start >= end): return 0
	int i = start
	int value = 0
	for octet in range(4):
		int first = i
		int part = 0
		while (i < end && ip__is_digit(text[i] & 255)):
			part = part * 10 + (text[i] & 255) - '0'
			i += 1
			if (i - first > 3): return 0
		if (i == first || part > 255): return 0
		if (i - first > 1 && text[first] == '0'): return 0
		if (octet == 0 || octet == 2): value = part
		else:
			value = value * 256 + part
			if (octet == 1): out.words[6] = value
			else: out.words[7] = value
		if (octet < 3):
			if (i >= end || text[i] != '.'): return 0
			i += 1
	if (i != end): return 0
	out.version = 4
	out.scope_id[0] = 0
	for k in range(6): out.words[k] = 0
	return 1


# IPv6 in text[start, end): eight 16-bit groups, one optional "::", and
# an optional dotted IPv4 tail. No zone ids or IPvFuture syntax.
int ipv6_parse_range(char* text, int start, int end, ip_address* out):
	if (text == 0 || start >= end || end - start > 45): return 0
	int[8] words
	int count = 0
	int compressed = -1
	int i = start
	if (text[i] == ':'):
		if (i + 1 >= end || text[i + 1] != ':'): return 0
		compressed = 0
		i += 2
	while (i < end):
		if (count == 8): return 0
		int segment_end = i
		int dotted = 0
		while (segment_end < end && text[segment_end] != ':'):
			if (text[segment_end] == '.'): dotted = 1
			segment_end += 1
		if (dotted):
			if (segment_end != end || count > 6): return 0
			ip_address tail
			if (ipv4_parse_range(text, i, end, &tail) == 0): return 0
			words[count] = tail.words[6]
			words[count + 1] = tail.words[7]
			count += 2
			i = end
		else:
			if (segment_end == i || segment_end - i > 4): return 0
			int value = 0
			while (i < segment_end):
				int digit = hex_decode_char(text[i] & 255)
				if (digit < 0): return 0
				value = value * 16 + digit
				i += 1
			words[count] = value
			count += 1
		if (i < end):
			i += 1
			if (i < end && text[i] == ':'):
				if (compressed >= 0): return 0
				compressed = count
				i += 1
			else if (i == end): return 0
	if (compressed < 0):
		if (count != 8): return 0
	else if (count == 8): return 0
	ip__clear(out, 6)
	if (compressed < 0): compressed = count
	for k in range(compressed): out.words[k] = words[k]
	int gap = 8 - count
	int j = compressed
	while (j < count):
		out.words[j + gap] = words[j]
		j += 1
	return 1


int ipv4_address_parse(char* text, ip_address* out):
	if (text == 0): return 0
	return ipv4_parse_range(text, 0, strlen(text), out)


# Also accepts a zone id suffix ("fe80::1%eth0"), kept in scope_id.
int ipv6_address_parse(char* text, ip_address* out):
	if (text == 0): return 0
	int n = strlen(text)
	int percent = 0
	while (percent < n && text[percent] != '%'): percent += 1
	if (percent == n): return ipv6_parse_range(text, 0, n, out)
	int scope_length = n - percent - 1
	if (scope_length == 0 || scope_length > IP_SCOPE_ID_MAX): return 0
	for i in range(percent + 1, n):
		if (text[i] == '%'): return 0
	if (ipv6_parse_range(text, 0, percent, out) == 0): return 0
	for i in range(scope_length): out.scope_id[i] = text[percent + 1 + i]
	out.scope_id[scope_length] = 0
	return 1


# Python's ip_address(): IPv4 first, then IPv6.
int ip_address_parse(char* text, ip_address* out):
	if (ipv4_address_parse(text, out)): return 1
	return ipv6_address_parse(text, out)


void ip_address_from_ipv4_int(int value, ip_address* out):
	ip__clear(out, 4)
	out.words[6] = (value >> 16) & 65535
	out.words[7] = value & 65535


# The 32-bit pattern of words 6..7 (negative on x86 for >= 128.0.0.0).
int ip_address_to_ipv4_int(ip_address* a):
	return (a.words[6] << 16) | a.words[7]


# Network-order bytes: 4 for IPv4, 16 for IPv6.
void ip_address_packed(ip_address* a, char* out):
	int first = ip__first_word(a.version)
	int n = 0
	for i in range(first, 8):
		out[n] = (a.words[i] >> 8) & 255
		out[n + 1] = a.words[i] & 255
		n += 2


int ip_address_from_packed(char* data, int length, ip_address* out):
	if (length != 4 && length != 16): return 0
	if (length == 4): ip__clear(out, 4)
	else: ip__clear(out, 6)
	int first = 8 - length / 2
	for i in range(length / 2):
		out.words[first + i] = ((data[2 * i] & 255) << 8) | (data[2 * i + 1] & 255)
	return 1


# ---- formatting ------------------------------------------------------

void ip__append_hex_group(string_builder* out, int word):
	int shift = 12
	while (shift > 0 && ((word >> shift) & 15) == 0): shift -= 4
	while (shift >= 0):
		string_append_char(out, hex_digit((word >> shift) & 15))
		shift -= 4


void ip__append_ipv4(string_builder* out, int high, int low):
	string_append_int(out, high >> 8)
	string_append_char(out, '.')
	string_append_int(out, high & 255)
	string_append_char(out, '.')
	string_append_int(out, low >> 8)
	string_append_char(out, '.')
	string_append_int(out, low & 255)


# RFC 5952 compression of words[0, count): the first longest run of at
# least two zero groups becomes "::".
void ip__append_compressed(string_builder* out, ip_address* a, int count):
	int best_start = -1
	int best_length = 1
	int i = 0
	while (i < count):
		if (a.words[i] != 0): i += 1
		else:
			int first = i
			while (i < count && a.words[i] == 0): i += 1
			if (i - first > best_length):
				best_start = first
				best_length = i - first
	i = 0
	while (i < count):
		if (i == best_start):
			string_append(out, c"::")
			i += best_length
		else:
			if (i > 0 && i != best_start + best_length): string_append_char(out, ':')
			ip__append_hex_group(out, a.words[i])
			i += 1


char* ip__finish(string_builder* out):
	char* result = out.data
	free(out)
	return result


# IPv6 RFC 5952 text without the dotted IPv4-mapped form (URL hosts use
# this so every spelling of an address has one serialization).
char* ipv6_format_hex(ip_address* a):
	string_builder* out = string_new()
	ip__append_compressed(out, a, 8)
	return ip__finish(out)


int ip__is_mapped(ip_address* a):
	if (a.version != 6 || a.words[5] != 65535): return 0
	for i in range(5):
		if (a.words[i] != 0): return 0
	return 1


void ip__append_scope(string_builder* out, ip_address* a):
	if (a.version == 6 && a.scope_id[0] != 0):
		string_append_char(out, '%')
		string_append(out, a.scope_id)


# Python's str(): dotted IPv4, compressed IPv6, ::ffff:d.d.d.d for mapped.
char* ip_address_format(ip_address* a):
	string_builder* out = string_new()
	if (a.version == 4): ip__append_ipv4(out, a.words[6], a.words[7])
	else if (ip__is_mapped(a)):
		string_append(out, c"::ffff:")
		ip__append_ipv4(out, a.words[6], a.words[7])
	else: ip__append_compressed(out, a, 8)
	ip__append_scope(out, a)
	return ip__finish(out)


# Python's .exploded: every IPv6 group as four hex digits (IPv4 is
# unchanged; mapped addresses keep their dotted tail).
char* ip_address_exploded(ip_address* a):
	if (a.version == 4): return ip_address_format(a)
	string_builder* out = string_new()
	int groups = 8
	if (ip__is_mapped(a)): groups = 6
	for i in range(groups):
		if (i > 0): string_append_char(out, ':')
		for k in range(4): string_append_char(out, hex_digit((a.words[i] >> (12 - 4 * k)) & 15))
	if (groups == 6):
		string_append_char(out, ':')
		ip__append_ipv4(out, a.words[6], a.words[7])
	else: ip__append_scope(out, a)
	return ip__finish(out)


# Python's .reverse_pointer ("4.3.2.1.in-addr.arpa" / nibbles.ip6.arpa).
char* ip_address_reverse_pointer(ip_address* a):
	string_builder* out = string_new()
	if (a.version == 4):
		string_append_int(out, a.words[7] & 255)
		string_append_char(out, '.')
		string_append_int(out, a.words[7] >> 8)
		string_append_char(out, '.')
		string_append_int(out, a.words[6] & 255)
		string_append_char(out, '.')
		string_append_int(out, a.words[6] >> 8)
		string_append(out, c".in-addr.arpa")
	else:
		int i = 7
		while (i >= 0):
			for k in range(4):
				string_append_char(out, hex_digit((a.words[i] >> (4 * k)) & 15))
				string_append_char(out, '.')
			i -= 1
		string_append(out, c"ip6.arpa")
	return ip__finish(out)


# ---- comparison and arithmetic ---------------------------------------

int ip_address_compare(ip_address* a, ip_address* b):
	if (a.version != b.version):
		if (a.version < b.version): return -1
		return 1
	for i in range(8):
		if (a.words[i] != b.words[i]):
			if (a.words[i] < b.words[i]): return -1
			return 1
	int c = strcmp(a.scope_id, b.scope_id)
	if (c < 0): return -1
	if (c > 0): return 1
	return 0


int ip_address_equal(ip_address* a, ip_address* b):
	return ip_address_compare(a, b) == 0


# out = a + delta (delta may be negative). Returns 0, leaving out
# untouched, when the result leaves the address family's range.
int ip_address_add(ip_address* a, int delta, ip_address* out):
	int[9] sum
	sum[0] = 0
	for i in range(8): sum[i + 1] = a.words[i]
	int carry = 0
	int rest = delta
	int i = 8
	while (i >= 0):
		int value = sum[i] + (rest & 65535) + carry
		sum[i] = value & 65535
		carry = value >> 16
		rest = rest >> 16
		i -= 1
	if (sum[0] != 0): return 0
	int first = ip__first_word(a.version)
	for k in range(first):
		if (sum[k + 1] != 0): return 0
	ip__clear(out, a.version)
	for k in range(8): out.words[k] = sum[k + 1]
	return 1


# ---- embedded IPv4 ---------------------------------------------------

# ::ffff:a.b.c.d -> a.b.c.d
int ipv6_ipv4_mapped(ip_address* a, ip_address* out):
	if (ip__is_mapped(a) == 0): return 0
	ip__clear(out, 4)
	out.words[6] = a.words[6]
	out.words[7] = a.words[7]
	return 1


# 2002:aabb:ccdd::/16 -> aa.bb.cc.dd
int ipv6_sixtofour(ip_address* a, ip_address* out):
	if (a.version != 6 || a.words[0] != 8194): return 0
	ip__clear(out, 4)
	out.words[6] = a.words[1]
	out.words[7] = a.words[2]
	return 1


# 2001:0:server:server:x:x:~client:~client -> (server, client)
int ipv6_teredo(ip_address* a, ip_address* server, ip_address* client):
	if (a.version != 6 || a.words[0] != 8193 || a.words[1] != 0): return 0
	ip__clear(server, 4)
	server.words[6] = a.words[2]
	server.words[7] = a.words[3]
	ip__clear(client, 4)
	client.words[6] = a.words[6] ^ 65535
	client.words[7] = a.words[7] ^ 65535
	return 1


void ipv4_to_ipv6_mapped(ip_address* a, ip_address* out):
	int high = a.words[6]
	int low = a.words[7]
	ip__clear(out, 6)
	out.words[5] = 65535
	out.words[6] = high
	out.words[7] = low


# ---- networks --------------------------------------------------------

# The mask for word i of a prefixlen-bit network of this version.
int ip__mask_word(int version, int prefixlen, int i):
	int bits = 128 - ip_max_prefixlen(version) + prefixlen - 16 * i
	if (bits <= 0): return 0
	if (bits >= 16): return 65535
	return (65535 << (16 - bits)) & 65535


void ip__mask(ip_address* a, int prefixlen, ip_address* out):
	ip__clear(out, a.version)
	for i in range(8): out.words[i] = a.words[i] & ip__mask_word(a.version, prefixlen, i)


int ip__has_host_bits(ip_address* a, int prefixlen):
	for i in range(8):
		if ((a.words[i] & ip__mask_word(a.version, prefixlen, i)) != a.words[i]): return 1
	return 0


int ip_network_make(ip_address* a, int prefixlen, int strict, ip_network* out):
	if (prefixlen < 0 || prefixlen > ip_max_prefixlen(a.version)): return 0
	if (strict && ip__has_host_bits(a, prefixlen)): return 0
	ip__mask(a, prefixlen, &out.address)
	out.prefixlen = prefixlen
	return 1


# Prefix length of a contiguous netmask (ones then zeros), or -1.
int ip__prefix_from_mask(ip_address* m):
	int first = ip__first_word(m.version)
	int prefixlen = 0
	int ended = 0
	for i in range(first, 8):
		for bit in range(16):
			int set = (m.words[i] >> (15 - bit)) & 1
			if (set):
				if (ended): return -1
				prefixlen += 1
			else: ended = 1
	return prefixlen


# A '/' suffix: ASCII digits (leading zeros allowed, as Python's int()),
# or for IPv4 a dotted netmask or hostmask. Returns -1 when invalid.
int ip__parse_prefix(char* text, int start, int end, int version):
	int max = ip_max_prefixlen(version)
	if (start >= end): return -1
	int all_digits = 1
	int value = 0
	for i in range(start, end):
		if (ip__is_digit(text[i] & 255) == 0): all_digits = 0
		else if (value <= max): value = value * 10 + (text[i] & 255) - '0'
	if (all_digits):
		if (value > max): return -1
		return value
	if (version != 4): return -1
	ip_address mask
	if (ipv4_parse_range(text, start, end, &mask) == 0): return -1
	int prefixlen = ip__prefix_from_mask(&mask)
	if (prefixlen >= 0): return prefixlen
	mask.words[6] = mask.words[6] ^ 65535
	mask.words[7] = mask.words[7] ^ 65535
	return ip__prefix_from_mask(&mask)


int ip__network_parse(char* text, int strict, int version, ip_network* out):
	if (text == 0): return 0
	int n = strlen(text)
	int slash = -1
	for i in range(n):
		if (text[i] == '/'):
			if (slash >= 0): return 0
			slash = i
	int address_end = n
	if (slash >= 0): address_end = slash
	ip_address a
	if (version == 4):
		if (ipv4_parse_range(text, 0, address_end, &a) == 0): return 0
	else if (ipv6_parse_range(text, 0, address_end, &a) == 0): return 0
	int prefixlen = ip_max_prefixlen(version)
	if (slash >= 0):
		prefixlen = ip__parse_prefix(text, slash + 1, n, version)
		if (prefixlen < 0): return 0
	return ip_network_make(&a, prefixlen, strict, out)


int ipv4_network_parse(char* text, int strict, ip_network* out):
	return ip__network_parse(text, strict, 4, out)


int ipv6_network_parse(char* text, int strict, ip_network* out):
	return ip__network_parse(text, strict, 6, out)


# Python's ip_network(text, strict): IPv4 first, then IPv6. A bare
# address is a single-address network.
int ip_network_parse(char* text, int strict, ip_network* out):
	if (ipv4_network_parse(text, strict, out)): return 1
	return ipv6_network_parse(text, strict, out)


void ip_network_netmask(ip_network* n, ip_address* out):
	ip__clear(out, n.address.version)
	int first = ip__first_word(n.address.version)
	for i in range(first, 8): out.words[i] = ip__mask_word(n.address.version, n.prefixlen, i)


void ip_network_hostmask(ip_network* n, ip_address* out):
	ip_network_netmask(n, out)
	int first = ip__first_word(n.address.version)
	for i in range(first, 8): out.words[i] = out.words[i] ^ 65535


void ip_network_broadcast(ip_network* n, ip_address* out):
	ip_address host
	ip_network_hostmask(n, &host)
	ip__clear(out, n.address.version)
	for i in range(8): out.words[i] = n.address.words[i] | host.words[i]


char* ip__network_text(ip_network* n, int kind):
	string_builder* out = string_new()
	char* text = ip_address_format(&n.address)
	string_append(out, text)
	free(text)
	string_append_char(out, '/')
	if (kind == 0): string_append_int(out, n.prefixlen)
	else:
		ip_address mask
		if (kind == 1): ip_network_netmask(n, &mask)
		else: ip_network_hostmask(n, &mask)
		text = ip_address_format(&mask)
		string_append(out, text)
		free(text)
	return ip__finish(out)


# "10.0.0.0/8" (Python's str() / with_prefixlen).
char* ip_network_format(ip_network* n):
	return ip__network_text(n, 0)


char* ip_network_with_netmask(ip_network* n):
	return ip__network_text(n, 1)


char* ip_network_with_hostmask(ip_network* n):
	return ip__network_text(n, 2)


int ip_network_contains(ip_network* n, ip_address* a):
	if (n.address.version != a.version): return 0
	for i in range(8):
		if ((a.words[i] & ip__mask_word(a.version, n.prefixlen, i)) != n.address.words[i]): return 0
	return 1


int ip_network_overlaps(ip_network* a, ip_network* b):
	if (a.address.version != b.address.version): return 0
	ip_address last
	if (ip_network_contains(b, &a.address)): return 1
	ip_network_broadcast(a, &last)
	if (ip_network_contains(b, &last)): return 1
	if (ip_network_contains(a, &b.address)): return 1
	ip_network_broadcast(b, &last)
	return ip_network_contains(a, &last)


# a lies entirely inside b (false across versions).
int ip_network_subnet_of(ip_network* a, ip_network* b):
	if (a.address.version != b.address.version): return 0
	return a.prefixlen >= b.prefixlen && ip_network_contains(b, &a.address)


int ip_network_supernet_of(ip_network* a, ip_network* b):
	return ip_network_subnet_of(b, a)


# Version, then network address, then netmask (shorter prefix first).
int ip_network_compare(ip_network* a, ip_network* b):
	int c = ip_address_compare(&a.address, &b.address)
	if (c != 0): return c
	if (a.prefixlen < b.prefixlen): return -1
	if (a.prefixlen > b.prefixlen): return 1
	return 0


int ip_network_equal(ip_network* a, ip_network* b):
	return ip_network_compare(a, b) == 0


# log2 of num_addresses.
int ip_network_host_bits(ip_network* n):
	return ip_max_prefixlen(n.address.version) - n.prefixlen


# 2**bits when that fits in a positive int.
int ip__power(int bits, int* fits):
	if (bits > sizeof(int) * 8 - 2):
		*fits = 0
		return 0
	*fits = 1
	return 1 << bits


int ip_network_num_addresses(ip_network* n, int* fits):
	return ip__power(ip_network_host_bits(n), fits)


# Exact decimal num_addresses (up to 2**128). malloc'd.
char* ip_network_num_addresses_text(ip_network* n):
	char[40] digits
	int length = 1
	digits[0] = 1
	for step in range(ip_network_host_bits(n)):
		int carry = 0
		for i in range(length):
			int value = digits[i] * 2 + carry
			digits[i] = value % 10
			carry = value / 10
		if (carry):
			digits[length] = carry
			length += 1
	char* text = cast(char*, malloc(length + 1))
	for i in range(length): text[i] = '0' + digits[length - 1 - i]
	text[length] = 0
	return text


# Python's network[index]; negative indexes count from the broadcast end.
int ip_network_address_at(ip_network* n, int index, ip_address* out):
	ip_address base
	int offset = index
	if (index >= 0): ip__copy(&n.address, &base)
	else:
		ip_network_broadcast(n, &base)
		offset = index + 1
	ip_address result
	if (ip_address_add(&base, offset, &result) == 0): return 0
	if (ip_network_contains(n, &result) == 0): return 0
	ip__copy(&result, out)
	return 1


# Python's supernet(new_prefix=...): new_prefix <= prefixlen.
int ip_network_supernet(ip_network* n, int new_prefix, ip_network* out):
	if (new_prefix < 0 || new_prefix > n.prefixlen): return 0
	return ip_network_make(&n.address, new_prefix, 0, out)


int ip__subnet_prefix_ok(ip_network* n, int new_prefix):
	return new_prefix >= n.prefixlen && new_prefix <= ip_max_prefixlen(n.address.version)


# Number of subnets(new_prefix=...).
int ip_network_subnet_count(ip_network* n, int new_prefix, int* fits):
	if (ip__subnet_prefix_ok(n, new_prefix) == 0):
		*fits = 1
		return 0
	return ip__power(new_prefix - n.prefixlen, fits)


# The index-th subnet of length new_prefix, in address order.
int ip_network_subnet_at(ip_network* n, int new_prefix, int index, ip_network* out):
	if (ip__subnet_prefix_ok(n, new_prefix) == 0 || index < 0): return 0
	int diff = new_prefix - n.prefixlen
	if (diff < sizeof(int) * 8 - 1 && index >= (1 << diff)): return 0
	# Shift index left by the subnet's host bits, word-wise.
	int shift = ip_max_prefixlen(n.address.version) - new_prefix
	int[8] offset
	for i in range(8): offset[i] = 0
	int rest = index
	int bit = shift
	while (rest != 0):
		int position = 127 - bit
		offset[position / 16] = offset[position / 16] | ((rest & 1) << (15 - position % 16))
		rest = rest >> 1
		bit += 1
	ip__clear(&out.address, n.address.version)
	for i in range(8): out.address.words[i] = n.address.words[i] | offset[i]
	out.prefixlen = new_prefix
	return 1


void ip_network_addresses(ip_network* n, ip_address_iterator* it):
	ip__copy(&n.address, &it.next)
	ip_network_broadcast(n, &it.last)
	it.done = 0


# Python's hosts(): skips the network and IPv4 broadcast addresses
# except on /31 and /32 (IPv6: skips the Subnet-Router anycast address
# except on /127 and /128).
void ip_network_hosts(ip_network* n, ip_address_iterator* it):
	ip_network_addresses(n, it)
	int host_bits = ip_network_host_bits(n)
	if (host_bits < 2): return;
	ip_address_add(&it.next, 1, &it.next)
	if (n.address.version == 4): ip_address_add(&it.last, -1, &it.last)


int ip_address_iterator_next(ip_address_iterator* it, ip_address* out):
	if (it.done): return 0
	ip__copy(&it.next, out)
	if (ip_address_equal(&it.next, &it.last)): it.done = 1
	else: ip_address_add(&it.next, 1, &it.next)
	return 1


# ---- special-purpose ranges (Python 3.13 tables) ---------------------

# a inside the literal CIDR (an always-valid table entry).
int ip__in(ip_address* a, char* cidr):
	ip_network n
	if (ip_network_parse(cidr, 1, &n) == 0): return 0
	return ip_network_contains(&n, a)


int ip__in_private_table(ip_address* a):
	if (a.version == 4):
		return ip__in(a, c"0.0.0.0/8") || ip__in(a, c"10.0.0.0/8") || ip__in(a, c"127.0.0.0/8") || ip__in(a, c"169.254.0.0/16") || ip__in(a, c"172.16.0.0/12") || ip__in(a, c"192.0.0.0/24") || ip__in(a, c"192.0.0.170/31") || ip__in(a, c"192.0.2.0/24") || ip__in(a, c"192.168.0.0/16") || ip__in(a, c"198.18.0.0/15") || ip__in(a, c"198.51.100.0/24") || ip__in(a, c"203.0.113.0/24") || ip__in(a, c"240.0.0.0/4") || ip__in(a, c"255.255.255.255/32")
	return ip__in(a, c"::1/128") || ip__in(a, c"::/128") || ip__in(a, c"::ffff:0:0/96") || ip__in(a, c"64:ff9b:1::/48") || ip__in(a, c"100::/64") || ip__in(a, c"2001::/23") || ip__in(a, c"2001:db8::/32") || ip__in(a, c"2002::/16") || ip__in(a, c"3fff::/20") || ip__in(a, c"fc00::/7") || ip__in(a, c"fe80::/10")


int ip__in_private_exceptions(ip_address* a):
	if (a.version == 4): return ip__in(a, c"192.0.0.9/32") || ip__in(a, c"192.0.0.10/32")
	return ip__in(a, c"2001:1::1/128") || ip__in(a, c"2001:1::2/128") || ip__in(a, c"2001:3::/32") || ip__in(a, c"2001:4:112::/48") || ip__in(a, c"2001:20::/28") || ip__in(a, c"2001:30::/28")


int ip_address_is_private(ip_address* a):
	ip_address v4
	if (ipv6_ipv4_mapped(a, &v4)): return ip_address_is_private(&v4)
	return ip__in_private_table(a) && ip__in_private_exceptions(a) == 0


int ip_address_is_global(ip_address* a):
	ip_address v4
	if (ipv6_ipv4_mapped(a, &v4)): return ip_address_is_global(&v4)
	if (a.version == 4 && ip__in(a, c"100.64.0.0/10")): return 0
	return ip_address_is_private(a) == 0


int ip_address_is_multicast(ip_address* a):
	ip_address v4
	if (ipv6_ipv4_mapped(a, &v4)): return ip_address_is_multicast(&v4)
	if (a.version == 4): return ip__in(a, c"224.0.0.0/4")
	return ip__in(a, c"ff00::/8")


int ip_address_is_reserved(ip_address* a):
	ip_address v4
	if (ipv6_ipv4_mapped(a, &v4)): return ip_address_is_reserved(&v4)
	if (a.version == 4): return ip__in(a, c"240.0.0.0/4")
	return ip__in(a, c"::/8") || ip__in(a, c"100::/8") || ip__in(a, c"200::/7") || ip__in(a, c"400::/6") || ip__in(a, c"800::/5") || ip__in(a, c"1000::/4") || ip__in(a, c"4000::/3") || ip__in(a, c"6000::/3") || ip__in(a, c"8000::/3") || ip__in(a, c"a000::/3") || ip__in(a, c"c000::/3") || ip__in(a, c"e000::/4") || ip__in(a, c"f000::/5") || ip__in(a, c"f800::/6") || ip__in(a, c"fe00::/9")


int ip_address_is_link_local(ip_address* a):
	ip_address v4
	if (ipv6_ipv4_mapped(a, &v4)): return ip_address_is_link_local(&v4)
	if (a.version == 4): return ip__in(a, c"169.254.0.0/16")
	return ip__in(a, c"fe80::/10")


int ip_address_is_loopback(ip_address* a):
	ip_address v4
	if (ipv6_ipv4_mapped(a, &v4)): return ip_address_is_loopback(&v4)
	if (a.version == 4): return ip__in(a, c"127.0.0.0/8")
	return ip__in(a, c"::1/128")


int ip_address_is_unspecified(ip_address* a):
	ip_address v4
	if (ipv6_ipv4_mapped(a, &v4)): return ip_address_is_unspecified(&v4)
	for i in range(8):
		if (a.words[i] != 0): return 0
	return 1


# IPv6 only (deprecated fec0::/10); always 0 for IPv4.
int ip_address_is_site_local(ip_address* a):
	if (a.version == 4): return 0
	return ip__in(a, c"fec0::/10")


int ip__both_in(ip_address* a, ip_address* b, char* cidr):
	return ip__in(a, cidr) && ip__in(b, cidr)


int ip__private_v4_network(ip_address* a, ip_address* b):
	return ip__both_in(a, b, c"0.0.0.0/8") || ip__both_in(a, b, c"10.0.0.0/8") || ip__both_in(a, b, c"127.0.0.0/8") || ip__both_in(a, b, c"169.254.0.0/16") || ip__both_in(a, b, c"172.16.0.0/12") || ip__both_in(a, b, c"192.0.0.0/24") || ip__both_in(a, b, c"192.0.0.170/31") || ip__both_in(a, b, c"192.0.2.0/24") || ip__both_in(a, b, c"192.168.0.0/16") || ip__both_in(a, b, c"198.18.0.0/15") || ip__both_in(a, b, c"198.51.100.0/24") || ip__both_in(a, b, c"203.0.113.0/24") || ip__both_in(a, b, c"240.0.0.0/4") || ip__both_in(a, b, c"255.255.255.255/32")


int ip__private_v6_network(ip_address* a, ip_address* b):
	return ip__both_in(a, b, c"::1/128") || ip__both_in(a, b, c"::/128") || ip__both_in(a, b, c"::ffff:0:0/96") || ip__both_in(a, b, c"64:ff9b:1::/48") || ip__both_in(a, b, c"100::/64") || ip__both_in(a, b, c"2001::/23") || ip__both_in(a, b, c"2001:db8::/32") || ip__both_in(a, b, c"2002::/16") || ip__both_in(a, b, c"3fff::/20") || ip__both_in(a, b, c"fc00::/7") || ip__both_in(a, b, c"fe80::/10")


# Network checks hold when both the network and broadcast addresses
# pass; is_private tests both endpoints against the raw tables.
int ip_network_is_private(ip_network* n):
	ip_address last
	ip_network_broadcast(n, &last)
	if (ip__in_private_exceptions(&n.address) || ip__in_private_exceptions(&last)): return 0
	if (n.address.version == 4):
		return ip__private_v4_network(&n.address, &last)
	return ip__private_v6_network(&n.address, &last)


int ip_network_is_global(ip_network* n):
	if (n.address.version == 4):
		ip_address last
		ip_network_broadcast(n, &last)
		if (ip__both_in(&n.address, &last, c"100.64.0.0/10")): return 0
	return ip_network_is_private(n) == 0


int ip_network_is_multicast(ip_network* n):
	ip_address last
	ip_network_broadcast(n, &last)
	return ip_address_is_multicast(&n.address) && ip_address_is_multicast(&last)


int ip_network_is_reserved(ip_network* n):
	ip_address last
	ip_network_broadcast(n, &last)
	return ip_address_is_reserved(&n.address) && ip_address_is_reserved(&last)


int ip_network_is_link_local(ip_network* n):
	ip_address last
	ip_network_broadcast(n, &last)
	return ip_address_is_link_local(&n.address) && ip_address_is_link_local(&last)


int ip_network_is_loopback(ip_network* n):
	ip_address last
	ip_network_broadcast(n, &last)
	return ip_address_is_loopback(&n.address) && ip_address_is_loopback(&last)


int ip_network_is_unspecified(ip_network* n):
	ip_address last
	ip_network_broadcast(n, &last)
	return ip_address_is_unspecified(&n.address) && ip_address_is_unspecified(&last)


int ip_network_is_site_local(ip_network* n):
	ip_address last
	ip_network_broadcast(n, &last)
	return ip_address_is_site_local(&n.address) && ip_address_is_site_local(&last)


# ---- plan-08 helpers on raw 32-bit IPv4 patterns ---------------------

int ipv4_parse(char* text, int* out):
	ip_address a
	if (ipv4_address_parse(text, &a) == 0): return 0
	*out = ip_address_to_ipv4_int(&a)
	return 1


char* ipv4_format(int address):
	ip_address a
	ip_address_from_ipv4_int(address, &a)
	return ip_address_format(&a)


int ipv4_in_network(int address, int network, int prefix):
	if (prefix < 0 || prefix > 32): return 0
	ip_address a
	ip_address b
	ip_address_from_ipv4_int(address, &a)
	ip_address_from_ipv4_int(network, &b)
	for i in range(6, 8):
		int mask = ip__mask_word(4, prefix, i)
		if ((a.words[i] & mask) != (b.words[i] & mask)): return 0
	return 1
