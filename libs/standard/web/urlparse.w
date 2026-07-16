# URL parsing for the pure-W HTTP stack (plan 11, issue #198, part of #155).
#
# Scope is deliberately what web/http_client.w needs (plan 11 tightens
# plan 08 phase 3): absolute http:// and https:// URLs split into
# scheme, host, port, path, and query, plus strict percent
# encode/decode helpers. No userinfo, no IPv6 bracket literals, and
# fragments are dropped (they are never sent to a server).
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
#   char* url_quote(char* text)       malloc'd; %XX-encodes reserved bytes
#   char* url_unquote(char* text)     malloc'd; 0 on invalid escape
#   int url_default_port(char* scheme)  80/443, or 0 for unknown schemes
import lib.lib
import lib.str
import structures.string


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


# Default TCP port for a scheme: 80 for http, 443 for https, 0 for
# anything else (url_parse only accepts http and https).
int url_default_port(char* scheme):
	if (strcmp(scheme, c"http") == 0):
		return 80
	if (strcmp(scheme, c"https") == 0):
		return 443
	return 0


int url_lower_char(int c):
	if ((c >= 'A') & (c <= 'Z')):
		return c + 32
	return c


int url_is_hex_digit(int c):
	if ((c >= '0') & (c <= '9')):
		return 1
	if ((c >= 'a') & (c <= 'f')):
		return 1
	if ((c >= 'A') & (c <= 'F')):
		return 1
	return 0


int url_hex_digit_value(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	return c - 'A' + 10


int url_hex_digit_upper(int value):
	if (value < 10):
		return value + '0'
	return value - 10 + 'A'


# Bytes [start, end) of text as a new lowercased C string.
char* url_substring_lower(char* text, int start, int end):
	char* result = substring(text, start, end)
	int i = 0
	while (result[i] != 0):
		result[i] = url_lower_char(result[i] & 255)
		i = i + 1
	return result


# Parses an absolute http:// or https:// URL. Returns 0 when the text
# is not a well-formed absolute URL of one of those schemes: missing
# or unknown scheme, empty host, userinfo ('@'), IPv6 bracket literal,
# or a port that is empty, non-numeric, or outside 1..65535.
URL* url_parse(char* text):
	if (text == 0):
		return 0

	# Scheme runs up to the first ':' and must be followed by "//".
	int scheme_end = 0
	while ((text[scheme_end] != 0) & (text[scheme_end] != ':') & (text[scheme_end] != '/') & (text[scheme_end] != '?') & (text[scheme_end] != '#')):
		scheme_end = scheme_end + 1
	if ((text[scheme_end] != ':') | (scheme_end == 0)):
		return 0
	if (text[scheme_end + 1] != '/'):
		return 0
	if (text[scheme_end + 2] != '/'):
		return 0
	char* scheme = url_substring_lower(text, 0, scheme_end)
	if (url_default_port(scheme) == 0):
		free(scheme)
		return 0

	# Authority runs up to the first '/', '?', or '#'.
	int host_start = scheme_end + 3
	int authority_end = host_start
	while ((text[authority_end] != 0) & (text[authority_end] != '/') & (text[authority_end] != '?') & (text[authority_end] != '#')):
		authority_end = authority_end + 1

	# Reject userinfo and IPv6 literals; find the single port colon.
	int host_end = authority_end
	int i = host_start
	while (i < authority_end):
		int c = text[i] & 255
		if ((c == '@') | (c == '[') | (c == ']')):
			free(scheme)
			return 0
		if (c == ':'):
			if (host_end != authority_end):
				# Second colon in the authority.
				free(scheme)
				return 0
			host_end = i
		i = i + 1
	if (host_end == host_start):
		free(scheme)
		return 0

	int port = url_default_port(scheme)
	if (host_end != authority_end):
		int digit_start = host_end + 1
		if (digit_start == authority_end):
			# "host:" with an empty port.
			free(scheme)
			return 0
		port = 0
		int p = digit_start
		while (p < authority_end):
			int d = text[p] & 255
			if ((d < '0') | (d > '9')):
				free(scheme)
				return 0
			port = port * 10 + (d - '0')
			if (port > 65535):
				free(scheme)
				return 0
			p = p + 1
		if (port == 0):
			free(scheme)
			return 0

	# Path runs from the authority to '?', '#', or the end.
	int path_start = authority_end
	int path_end = path_start
	while ((text[path_end] != 0) & (text[path_end] != '?') & (text[path_end] != '#')):
		path_end = path_end + 1
	char* path
	if (path_end == path_start):
		path = strclone(c"/")
	else:
		path = substring(text, path_start, path_end)

	# Query runs from '?' to '#' or the end; the fragment is dropped.
	char* query
	if (text[path_end] == '?'):
		int query_start = path_end + 1
		int query_end = query_start
		while ((text[query_end] != 0) & (text[query_end] != '#')):
			query_end = query_end + 1
		query = substring(text, query_start, query_end)
	else:
		query = strclone(c"")

	URL* u = new URL()
	u.scheme = scheme
	u.host = url_substring_lower(text, host_start, host_end)
	u.port = port
	u.path = path
	u.query = query
	return u


void url_free(URL* u):
	if (u == 0):
		return;
	free(u.scheme)
	free(u.host)
	free(u.path)
	free(u.query)
	free(u)


# Rebuilds the URL text: scheme://host[:port]path[?query]. The port is
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
	if (u.query[0] != 0):
		string_append_char(out, '?')
		string_append(out, u.query)
	char* text = out.data
	free(out)
	return text


# Bytes that url_quote passes through unescaped: RFC 3986 unreserved
# characters plus '/', matching Python's urllib.parse.quote default.
int url_quote_is_safe(int c):
	if ((c >= 'a') & (c <= 'z')):
		return 1
	if ((c >= 'A') & (c <= 'Z')):
		return 1
	if ((c >= '0') & (c <= '9')):
		return 1
	if ((c == '-') | (c == '.') | (c == '_') | (c == '~') | (c == '/')):
		return 1
	return 0


# Percent-encodes every byte outside url_quote_is_safe with uppercase
# hex. Operates on raw bytes, so UTF-8 input yields %XX per byte.
# Returns a malloc'd string.
char* url_quote(char* text):
	string_builder* out = string_new()
	int i = 0
	while (text[i] != 0):
		int c = text[i] & 255
		if (url_quote_is_safe(c)):
			string_append_char(out, c)
		else:
			string_append_char(out, '%')
			string_append_char(out, url_hex_digit_upper(c >> 4))
			string_append_char(out, url_hex_digit_upper(c & 15))
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
			int hi = text[i + 1] & 255
			if (url_is_hex_digit(hi) == 0):
				string_free(out)
				return 0
			int lo = text[i + 2] & 255
			if (url_is_hex_digit(lo) == 0):
				string_free(out)
				return 0
			int decoded = url_hex_digit_value(hi) * 16 + url_hex_digit_value(lo)
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
