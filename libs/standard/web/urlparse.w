# URL parsing for the pure-W HTTP stack (plan 11, issue #198, part of #155).
#
# HTTP/HTTPS references use RFC 3986 component and dot-segment rules.
# Fragments and empty query/fragment delimiters survive round trips.
# Bracketed IPv6 is supported; userinfo and file URLs are deliberately
# rejected. See docs/projects/browser_network.md for the normalization contract.
#
# NAMING: the URL type is PascalCase -- the codebase otherwise uses
# lowercase_snake_case for everything, but the http_server.w /
# connection.w server framework (issue #235) marks its public
# high-level API types this way (ConnectionContext, ServerContext,
# ServerRequest, ServerResponse, ...) to set them apart from the
# lowercase_snake_case primitives they are built from. URL predates that
# framework but was renamed (issue #235 phase 1) to join the same
# convention, since it is equally part of the public web/ API surface.
# Function names are unaffected and stay snake_case throughout.
#
# Public API:
#   URL* url_parse(char* text)        parsed URL, or 0 on any error
#   void url_free(URL* u)
#   char* url_unparse(URL* u)         malloc'd; omits default ports
#   URL* url_resolve(URL* base, char* reference)  new owned absolute URL
#   int url_same_origin(URL* a, URL* b)  normalized tuple comparison
#   char* url_quote(char* text)       malloc'd; %XX-encodes reserved bytes
#   char* url_unquote(char* text)     malloc'd; 0 on invalid escape
#   char* url_query_param(char* query, char* name)  malloc'd value, or 0
#   int url_default_port(char* scheme)  80/443, or 0 for unknown schemes
import lib.lib
import lib.str
import structures.string
import lib.hex


# Parsed absolute URL. Every char* field is malloc'd, owned by the URL,
# and released by url_free. scheme and host are lowercased; path always
# begins with '/' (an absent path becomes "/"); query never includes
# the leading '?' and is "" when absent.
struct URL:
	char* scheme
	char* host
	int port
	char* path
	char* query
	char* fragment
	int has_query
	int has_fragment


# Default TCP port for a scheme: 80 for http, 443 for https, 0 for
# anything else (url_parse only accepts http and https).
int url_default_port(char* scheme):
	if (strcmp(scheme, c"http") == 0): return 80
	if (strcmp(scheme, c"https") == 0): return 443
	return 0


int url_lower_char(int c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c


# Bytes [start, end) of text as a new lowercased C string.
char* url_substring_lower(char* text, int start, int end):
	char* result = substring(text, start, end)
	int i = 0
	while (result[i] != 0):
		result[i] = url_lower_char(result[i] & 255)
		i = i + 1
	return result


# IPv6 syntax validation (no zone identifiers or embedded IPv4 yet).
int url_ipv6_valid(char* text, int start, int end):
	int groups = 0
	int compressed = 0
	int i = start
	if (i == end): return 0
	if (text[i] == ':'):
		if (i + 1 >= end || text[i + 1] != ':'): return 0
		compressed = 1
		i += 2
	while (i < end):
		int digits = 0
		while (i < end && hex_decode_char(text[i] & 255) >= 0):
			digits += 1
			i += 1
		if (digits == 0 || digits > 4): return 0
		groups += 1
		if (groups > 8): return 0
		if (i < end):
			if (text[i] != ':'): return 0
			i += 1
			if (i < end && text[i] == ':'):
				if (compressed): return 0
				compressed = 1
				i += 1
			else if (i == end): return 0
	if (compressed): return groups < 8
	return groups == 8


# Reject controls, spaces, backslashes and invalid percent escapes before
# components can become an HTTP request target. Escaped delimiters stay escaped.
int url_text_valid(char* text):
	int i = 0
	while (text[i] != 0):
		int c = text[i] & 255
		if (c <= 32 || c == 127 || c == 92): return 0
		if (c == '%'):
			if (hex_decode_char(text[i + 1] & 255) < 0): return 0
			if (hex_decode_char(text[i + 2] & 255) < 0): return 0
			i += 2
		i += 1
	return 1


# Absolute HTTP(S) URL. host retains brackets for IPv6 serialization.
URL* url_parse(char* text):
	if (text == 0): return 0
	if (url_text_valid(text) == 0): return 0
	int scheme_end = 0
	while (text[scheme_end] != 0 && text[scheme_end] != ':' && text[scheme_end] != '/' && text[scheme_end] != '?' && text[scheme_end] != '#'):
		scheme_end += 1
	if (text[scheme_end] != ':' || scheme_end == 0): return 0
	if (text[scheme_end + 1] != '/'): return 0
	if (text[scheme_end + 2] != '/'): return 0
	char* scheme = url_substring_lower(text, 0, scheme_end)
	if (url_default_port(scheme) == 0):
		free(scheme)
		return 0
	int host_start = scheme_end + 3
	int authority_end = host_start
	while (text[authority_end] != 0 && text[authority_end] != '/' && text[authority_end] != '?' && text[authority_end] != '#'):
		authority_end += 1
	int host_end = host_start
	int valid = 1
	if (text[host_start] == '['):
		host_end += 1
		while (host_end < authority_end && text[host_end] != ']'): host_end += 1
		if (host_end == authority_end): valid = 0
		else:
			valid = url_ipv6_valid(text, host_start + 1, host_end)
			host_end += 1
	else:
		while (host_end < authority_end && text[host_end] != ':'):
			int c = text[host_end] & 255
			if (c == '@' || c == '[' || c == ']'): valid = 0
			host_end += 1
	if (host_end == host_start): valid = 0
	int port = url_default_port(scheme)
	if (host_end < authority_end):
		if (text[host_end] != ':' || host_end + 1 == authority_end): valid = 0
		port = 0
		int i = host_end + 1
		while (i < authority_end && valid):
			int d = text[i] & 255
			if (d < '0' || d > '9'): valid = 0
			else:
				port = port * 10 + d - '0'
				if (port > 65535): valid = 0
			i += 1
		if (port == 0): valid = 0
	if (valid == 0):
		free(scheme)
		return 0
	int path_end = authority_end
	while (text[path_end] != 0 && text[path_end] != '?' && text[path_end] != '#'): path_end += 1
	URL* u = new URL()
	u.scheme = scheme
	u.host = url_substring_lower(text, host_start, host_end)
	u.port = port
	if (path_end == authority_end): u.path = strclone(c"/")
	else: u.path = substring(text, authority_end, path_end)
	u.has_query = text[path_end] == '?'
	int query_start = path_end
	if (u.has_query): query_start += 1
	int query_end = query_start
	if (u.has_query):
		while (text[query_end] != 0 && text[query_end] != '#'): query_end += 1
	u.query = substring(text, query_start, query_end)
	u.has_fragment = text[query_end] == '#'
	if (u.has_fragment): u.fragment = strclone(text + query_end + 1)
	else: u.fragment = strclone(c"")
	return u


void url_free(URL* u):
	if (u == 0): return;
	free(u.scheme)
	free(u.host)
	free(u.path)
	free(u.query)
	free(u.fragment)
	free(u)


# Rebuilds scheme://host[:port]path[?query][#fragment]. The port is
# omitted when it equals the scheme default. Returns a malloc'd string.
char* url_unparse(URL* u):
	string_builder* out = string_new()
	string_append(out, u.scheme)
	string_append(out, c"://")
	string_append(out, u.host)
	if (u.port != url_default_port(u.scheme)):
		string_append_char(out, ':')
		char* port_text = itoa(u.port)
		string_append(out, port_text)
		free(port_text)
	string_append(out, u.path)
	if (u.has_query || u.query[0] != 0):
		string_append_char(out, '?')
		string_append(out, u.query)
	if (u.has_fragment):
		string_append_char(out, '#')
		string_append(out, u.fragment)
	char* text = out.data
	free(out)
	return text


# Bytes that url_quote passes through unescaped: RFC 3986 unreserved
# characters plus '/', matching Python's urllib.parse.quote default.
int url_quote_is_safe(int c):
	if ((c >= 'a') && (c <= 'z')): return 1
	if ((c >= 'A') && (c <= 'Z')): return 1
	if ((c >= '0') && (c <= '9')): return 1
	if ((c == '-') || (c == '.') || (c == '_') || (c == '~') || (c == '/')): return 1
	return 0


# Percent-encodes every byte outside url_quote_is_safe with uppercase
# hex. Operates on raw bytes, so UTF-8 input yields %XX per byte.
# Returns a malloc'd string.
char* url_quote(char* text):
	string_builder* out = string_new()
	int i = 0
	while (text[i] != 0):
		int c = text[i] & 255
		if (url_quote_is_safe(c)): string_append_char(out, c)
		else:
			string_append_char(out, '%')
			string_append_char(out, hex_digit_upper(c >> 4))
			string_append_char(out, hex_digit_upper(c & 15))
		i = i + 1
	char* result = out.data
	free(out)
	return result


# Percent-decodes text. Strict: every '%' must be followed by exactly
# two hex digits, and "%00" is rejected (a NUL cannot live in a C
# string). '+' is left as-is (this is unquote, not unquote_plus).
# Returns a malloc'd string, or 0 on any invalid escape.
char* url_unquote(char* text):
	string_builder* out = string_new()
	int i = 0
	while (text[i] != 0):
		int c = text[i] & 255
		if (c == '%'):
			int hi = hex_decode_char(text[i + 1] & 255)
			int lo = 0 - 1
			if (hi >= 0): lo = hex_decode_char(text[i + 2] & 255)
			if (lo < 0):
				string_free(out)
				return 0
			int decoded = hi * 16 + lo
			if (decoded == 0):
				string_free(out)
				return 0
			string_append_char(out, decoded)
			i = i + 3
		else:
			string_append_char(out, c)
			i = i + 1
	char* result = out.data
	free(out)
	return result


# Looks up name in a "&"-separated, percent-encoded query string
# ("a=1&b=2"); a pair with no '=' is treated as an empty value. Both
# keys and values are percent-decoded via url_unquote before comparing
# (so an encoded key like "a%20b" matches name "a b"). Returns a
# malloc'd, percent-decoded value the caller frees, or 0 when name is
# absent or every occurrence of it has an invalid percent-escape in its
# key or value.
char* url_query_param(char* query, char* name):
	int i = 0
	while (query[i] != 0):
		int pair_start = i
		int eq = 0 - 1
		while ((query[i] != 0) && (query[i] != '&')):
			if ((query[i] == '=') && (eq < 0)): eq = i
			i = i + 1
		int pair_end = i
		char* key_raw
		char* value_raw
		if (eq >= 0):
			key_raw = substring(query, pair_start, eq)
			value_raw = substring(query, eq + 1, pair_end)
		else:
			key_raw = substring(query, pair_start, pair_end)
			value_raw = strclone(c"")
		char* key = url_unquote(key_raw)
		free(key_raw)
		int matched = 0
		if (key != 0):
			if (strcmp(key, name) == 0): matched = 1
			free(key)
		if (matched != 0):
			char* value = url_unquote(value_raw)
			free(value_raw)
			return value
		free(value_raw)
		if (query[i] == '&'): i = i + 1
	return 0


int url_has_prefix(char* text, char* prefix):
	int i = 0
	while (prefix[i] != 0):
		if (text[i] != prefix[i]): return 0
		i += 1
	return 1


# RFC 3986 section 5.2.4, preserving repeated slashes and encoded dots.
char* url_remove_dot_segments(char* path):
	string_builder* out = string_new()
	int i = 0
	int n = strlen(path)
	while (i < n):
		if (url_has_prefix(path + i, c"../")): i += 3
		else if (url_has_prefix(path + i, c"./")): i += 2
		else if (url_has_prefix(path + i, c"/./")): i += 2
		else if (strcmp(path + i, c"/.") == 0):
			i = n
			string_append_char(out, '/')
		else if (url_has_prefix(path + i, c"/../") || strcmp(path + i, c"/..") == 0):
			int final_segment = strcmp(path + i, c"/..") == 0
			i += 3
			while (out.length > 0 && out.data[out.length - 1] != '/'): out.length -= 1
			if (out.length > 0): out.length -= 1
			out.data[out.length] = 0
			if (final_segment): string_append_char(out, '/')
		else if (strcmp(path + i, c".") == 0 || strcmp(path + i, c"..") == 0): i = n
		else:
			string_append_char(out, path[i])
			i += 1
			while (i < n && path[i] != '/'):
				string_append_char(out, path[i])
				i += 1
	char* result = out.data
	free(out)
	return result


# A new owned absolute URL; base is borrowed. Empty references inherit
# path/query but clear the fragment. Unknown explicit schemes fail closed.
URL* url_resolve(URL* base, char* reference):
	if (base == 0 || reference == 0): return 0
	if (url_text_valid(reference) == 0): return 0
	int i = 0
	while (reference[i] != 0 && reference[i] != ':' && reference[i] != '/' && reference[i] != '?' && reference[i] != '#'): i += 1
	URL* result = 0
	if (reference[i] == ':'): result = url_parse(reference)
	else:
		string_builder* out = string_new()
		string_append(out, base.scheme)
		string_append_char(out, ':')
		if (reference[0] == '/' && reference[1] == '/'): string_append(out, reference)
		else:
			string_append(out, c"//")
			string_append(out, base.host)
			if (base.port != url_default_port(base.scheme)):
				char* port = itoa(base.port)
				string_append_char(out, ':')
				string_append(out, port)
				free(port)
			if (reference[0] == 0 || reference[0] == '?' || reference[0] == '#'):
				string_append(out, base.path)
				if (reference[0] != '?' && (base.has_query || base.query[0] != 0)):
					string_append_char(out, '?')
					string_append(out, base.query)
			else if (reference[0] != '/'):
				int last = 0
				for j in range(strlen(base.path)):
					if (base.path[j] == '/'): last = j
				string_append_bytes(out, base.path, last + 1)
			string_append(out, reference)
		result = url_parse(out.data)
		string_free(out)
	if (result != 0):
		char* normalized = url_remove_dot_segments(result.path)
		free(result.path)
		result.path = normalized
	return result


# Origin tuple comparison for normalized DNS names / identical IPv6 text.
# Does not equate different textual spellings of the same IPv6 address.
int url_same_origin(URL* a, URL* b):
	if (a == 0 || b == 0): return 0
	return a.port == b.port && strcmp(a.scheme, b.scheme) == 0 && strcmp(a.host, b.host) == 0
