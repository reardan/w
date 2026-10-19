/*
HTTP cookies (docs/projects/stdlib_python_parity.md P4.3): RFC 6265
Set-Cookie and Cookie header parsing/serialization and a client cookie
jar with the RFC's domain, path and expiry rules. Python's http.cookies
and http.cookiejar are the behavioral reference where they agree with
RFC 6265; where they differ, the RFC wins (noted below).

NAMING: Cookie and CookieJar are PascalCase like the rest of the public
web/ API types (URL, ServerRequest, ...); functions are snake_case.

Public API:
  Cookie* cookie_new(char* name, char* value)
  void cookie_free(Cookie* c)
  void cookie_set_domain(Cookie* c, char* domain)    (and _path, _same_site)
  Cookie* cookie_parse_set_cookie(char* header)  RFC 6265 5.2; 0 = ignore
  char* cookie_serialize_set_cookie(Cookie* c)   malloc'd; 0 when invalid
  list[Cookie*] cookie_parse_header(char* header)  "Cookie: a=1; b=2"
  char* cookie_serialize_header(list[Cookie*] cookies)  malloc'd; 0 when invalid
  char* cookie_list_get(list[Cookie*] cookies, char* name)  borrowed value, or 0
  void cookie_list_free(list[Cookie*] cookies)   frees the cookies and list
  int cookie_name_is_valid(char* name)           RFC 6265 token
  int cookie_value_is_valid(char* value)         cookie-value (opt. quoted)
  int cookie_domain_match(char* host, char* domain)
  int cookie_path_match(char* request_path, char* cookie_path)
  char* cookie_default_path(char* request_path)  malloc'd

  CookieJar* cookie_jar_new() / void cookie_jar_free(CookieJar* jar)
  int cookie_jar_set_cookie(jar, host, path, secure_channel, header, now)
  int cookie_jar_set_cookie_url(jar, URL* url, header, now)
  int cookie_jar_add(jar, Cookie* parsed, host, path, secure_channel, now)
  list[Cookie*] cookie_jar_matching(jar, host, path, secure_channel, now)
  char* cookie_jar_header(jar, host, path, secure_channel, now)  0 if none
  char* cookie_jar_header_url(jar, URL* url, now)
  void cookie_jar_clear_expired(jar, now)
  void cookie_jar_clear_session(jar)
  void cookie_jar_clear(jar, domain, path, name)  0 = any
  int cookie_jar_count(jar)

TIME. Every time is a libs/standard/time/datetime.w datetime; the jar
works in aware UTC (a naive `now` is read as UTC). Expiry instants are
datetimes rather than Unix seconds so far-future cookies (Expires in
9999) work on x86 past 2038. Expires is parsed with
libs/standard/time/format.w's datetime_parse_http (IMF-fixdate, RFC 850,
asctime and the Netscape "Wed, 09-Jun-2021 10:18:14 GMT" form); a date
that does not parse, or a year before 1601 (RFC 6265 5.1.1), makes the
attribute be ignored. Max-Age wins over Expires; Max-Age <= 0 expires
the cookie at once (deleting a stored one). Expiry is clamped to
9999-12-31T23:59:59Z.

RULES (RFC 6265 5.3 / 5.4). A Set-Cookie without a Domain attribute is
host-only (sent only to the identical host). A Domain attribute must
domain-match the request host, and a host that is an IP address only
matches itself. There is no public-suffix list: as a stand-in, a Domain
with no embedded dot ("com", "localhost") is accepted only when it is
the request host itself (then the cookie is host-only) and otherwise
rejects the cookie. A missing Path, or one not starting with "/", takes
the request's default-path. A cookie replaces an earlier one with the
same name, domain and path, keeping its creation time. Matching
cookies are returned longest path first, then oldest first. Secure
cookies are only sent over secure channels; per RFC 6265 (unlike RFC
6265bis) a Secure cookie may be set from an insecure channel. The jar
models the HTTP API, so HttpOnly cookies are stored and sent; HttpOnly
and SameSite are recorded for the caller to enforce. No per-domain or
total cookie limits are applied (Python applies none either).

OWNERSHIP. Every char* field of a Cookie is malloc'd and owned by it.
Cookies stored in a jar are owned by the jar; cookie_jar_matching
returns a new list of borrowed pointers (free only the list, with
list_free[Cookie*]).
*/
import lib.lib
import lib.str
import lib.container
import structures.string
import libs.standard.time.datetime
import libs.standard.time.format
import libs.standard.web.urlparse


struct Cookie:
	char* name
	char* value
	char* domain          # lowercase, no leading dot; "" = no Domain attribute
	char* path            # "" = no (usable) Path attribute
	int has_expires
	datetime expires      # aware UTC, when has_expires
	int has_max_age
	int max_age           # delta seconds (<= 0 means expire now)
	int secure
	int http_only
	char* same_site       # "Strict", "Lax", "None" or "" (absent)
	# Jar state (RFC 6265 5.3), filled in by cookie_jar_add.
	int host_only
	int persistent        # 0 = session cookie (no expiry)
	datetime expiry       # aware UTC, when persistent
	datetime creation
	datetime last_access
	int seq               # creation order inside the jar


struct CookieJar:
	list[Cookie*] cookies
	int next_seq


# ---- small helpers -----------------------------------------------------------------

int cookie_lower(int c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c


int cookie_is_wsp(int c):
	return (c == ' ') || (c == 9)


# Case-insensitive equality of text[start..end) and the lowercase name.
int cookie_range_is(char* text, int start, int end, char* name):
	int n = strlen(name)
	if (end - start != n): return 0
	for i in range(n):
		if (cookie_lower(text[start + i] & 255) != (name[i] & 255)): return 0
	return 1


# text[start..end) with SP/HTAB trimmed from both ends, malloc'd.
char* cookie_trimmed(char* text, int start, int end):
	while ((start < end) && cookie_is_wsp(text[start] & 255)): start = start + 1
	while ((end > start) && cookie_is_wsp(text[end - 1] & 255)): end = end - 1
	return substring(text, start, end)


char* cookie_lower_copy(char* s):
	char* r = strclone(s)
	int i = 0
	while (r[i] != 0):
		r[i] = cookie_lower(r[i] & 255)
		i = i + 1
	return r


datetime cookie_epoch_min():
	return datetime_with_offset(datetime_new(1, 1, 1, 0, 0, 0, 0), 0)


datetime cookie_epoch_max():
	return datetime_with_offset(datetime_new(9999, 12, 31, 23, 59, 59, 0), 0)


# now as an aware UTC datetime (a naive one is taken as UTC).
datetime cookie_utc(datetime now):
	if (now.has_offset): return datetime_to_utc(now)
	return datetime_with_offset(now, 0)


# now + seconds, clamped to years 1..9999.
datetime cookie_add_seconds(datetime now, int seconds):
	if (seconds <= 0): return cookie_epoch_min()
	duration at = duration_add(datetime_instant(now), duration_from_seconds(seconds))
	if (at.days > DATE_MAX_ORDINAL): return cookie_epoch_max()
	return datetime_from_parts(at.days, at.seconds, at.nanoseconds, 1, 0)


# ---- Cookie objects ----------------------------------------------------------------

Cookie* cookie_new(char* name, char* value):
	Cookie* c = new Cookie()
	c.name = strclone(name)
	c.value = strclone(value)
	c.domain = strclone(c"")
	c.path = strclone(c"")
	c.same_site = strclone(c"")
	c.expires = cookie_epoch_min()
	c.expiry = cookie_epoch_max()
	c.creation = cookie_epoch_min()
	c.last_access = cookie_epoch_min()
	return c


void cookie_free(Cookie* c):
	if (c == 0): return
	free(c.name)
	free(c.value)
	free(c.domain)
	free(c.path)
	free(c.same_site)
	free(cast(char*, c))


# Domain attribute value: a leading dot is dropped and the rest lowercased.
void cookie_set_domain(Cookie* c, char* domain):
	free(c.domain)
	if (domain[0] == '.'): domain = &domain[1]
	c.domain = cookie_lower_copy(domain)


void cookie_set_path(Cookie* c, char* path):
	free(c.path)
	c.path = strclone(path)


void cookie_set_same_site(Cookie* c, char* same_site):
	free(c.same_site)
	c.same_site = strclone(same_site)


void cookie_set_expires(Cookie* c, datetime expires):
	c.has_expires = 1
	c.expires = cookie_utc(expires)


void cookie_set_max_age(Cookie* c, int max_age):
	c.has_max_age = 1
	c.max_age = max_age


void cookie_list_free(list[Cookie*] cookies):
	if (cookies == 0): return
	for i in range(cookies.length):
		cookie_free(cookies[i])
	list_free[Cookie*](cookies)


# The value of the first cookie called name (borrowed), or 0.
char* cookie_list_get(list[Cookie*] cookies, char* name):
	if (cookies == 0): return 0
	for i in range(cookies.length):
		Cookie* c = cookies[i]
		if (strcmp(c.name, name) == 0): return c.value
	return 0


# ---- validation (RFC 6265 4.1.1) -----------------------------------------------

# RFC 2616 token: visible ASCII except separators.
int cookie_is_token_char(int c):
	if ((c <= 32) || (c >= 127)): return 0
	char* separators = c"()<>@,;:\\\"/[]?={}"
	int i = 0
	while (separators[i] != 0):
		if ((separators[i] & 255) == c): return 0
		i = i + 1
	return 1


# cookie-octet: %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E
int cookie_is_octet(int c):
	if ((c < 0x21) || (c > 0x7e)): return 0
	return (c != '"') && (c != ',') && (c != ';') && (c != '\\')


int cookie_name_is_valid(char* name):
	if (name == 0 || name[0] == 0): return 0
	int i = 0
	while (name[i] != 0):
		if (!cookie_is_token_char(name[i] & 255)): return 0
		i = i + 1
	return 1


# *cookie-octet or DQUOTE *cookie-octet DQUOTE (the empty value is valid).
int cookie_value_is_valid(char* value):
	if (value == 0): return 0
	int n = strlen(value)
	int start = 0
	int end = n
	if ((n > 0) && (value[0] == '"')):
		if ((n < 2) || (value[n - 1] != '"')): return 0
		start = 1
		end = n - 1
	for i in range(start, end):
		if (!cookie_is_octet(value[i] & 255)): return 0
	return 1


# An attribute value may hold any CHAR except CTLs and ';'.
int cookie_av_is_valid(char* value):
	int i = 0
	while (value[i] != 0):
		int c = value[i] & 255
		if ((c < 32) || (c == 127) || (c == ';')): return 0
		i = i + 1
	return 1


# ---- Set-Cookie (RFC 6265 5.2) -----------------------------------------------------

int cookie_index_of_char(char* s, int start, int end, int ch):
	for i in range(start, end):
		if ((s[i] & 255) == ch): return i
	return 0 - 1


# Max-Age: an optional '-' then one or more digits; 1 and *out (saturated
# at 999999999 seconds, ~31 years) when well formed.
int cookie_parse_max_age(char* s, int* out):
	int i = 0
	int neg = 0
	if (s[0] == '-'):
		neg = 1
		i = 1
	if ((s[i] < '0') || (s[i] > '9')): return 0
	int v = 0
	while (s[i] != 0):
		if ((s[i] < '0') || (s[i] > '9')): return 0
		if (v < 100000000): v = v * 10 + (s[i] - '0')
		else: v = 999999999
		i = i + 1
	if (neg): v = 0 - v
	*out = v
	return 1


# Applies one cookie-av (name text[ns..ne), value av) to c.
void cookie_apply_av(Cookie* c, char* text, int ns, int ne, char* av):
	if (cookie_range_is(text, ns, ne, c"expires")):
		datetime dt = cookie_epoch_min()
		if (datetime_parse_http(av, &dt) && (dt.d.year >= 1601)):
			c.has_expires = 1
			c.expires = dt
	else if (cookie_range_is(text, ns, ne, c"max-age")):
		int v = 0
		if (cookie_parse_max_age(av, &v)):
			c.has_max_age = 1
			c.max_age = v
	else if (cookie_range_is(text, ns, ne, c"domain")):
		if (av[0] != 0): cookie_set_domain(c, av)
	else if (cookie_range_is(text, ns, ne, c"path")):
		if (av[0] == '/'): cookie_set_path(c, av)
		else: cookie_set_path(c, c"")
	else if (cookie_range_is(text, ns, ne, c"secure")):
		c.secure = 1
	else if (cookie_range_is(text, ns, ne, c"httponly")):
		c.http_only = 1
	else if (cookie_range_is(text, ns, ne, c"samesite")):
		int n = strlen(av)
		if (cookie_range_is(av, 0, n, c"strict")): cookie_set_same_site(c, c"Strict")
		else if (cookie_range_is(av, 0, n, c"lax")): cookie_set_same_site(c, c"Lax")
		else if (cookie_range_is(av, 0, n, c"none")): cookie_set_same_site(c, c"None")
		else: cookie_set_same_site(c, c"")


# Parses a Set-Cookie header value. Returns 0 when RFC 6265 says to
# ignore the whole header: no '=' in the name-value pair or an empty
# name. Unknown or malformed attributes are skipped; for a repeated
# attribute the last one wins.
Cookie* cookie_parse_set_cookie(char* header):
	if (header == 0): return 0
	int n = strlen(header)
	int pair_end = cookie_index_of_char(header, 0, n, ';')
	if (pair_end < 0): pair_end = n
	int eq = cookie_index_of_char(header, 0, pair_end, '=')
	if (eq < 0): return 0
	char* name = cookie_trimmed(header, 0, eq)
	if (name[0] == 0):
		free(name)
		return 0
	char* value = cookie_trimmed(header, eq + 1, pair_end)
	Cookie* c = cookie_new(name, value)
	free(name)
	free(value)
	int pos = pair_end
	while (pos < n):
		int start = pos + 1
		int end = cookie_index_of_char(header, start, n, ';')
		if (end < 0): end = n
		int aeq = cookie_index_of_char(header, start, end, '=')
		int name_end = end
		if (aeq >= 0): name_end = aeq
		while ((start < name_end) && cookie_is_wsp(header[start] & 255)): start = start + 1
		while ((name_end > start) && cookie_is_wsp(header[name_end - 1] & 255)): name_end = name_end - 1
		char* av = 0
		if (aeq >= 0): av = cookie_trimmed(header, aeq + 1, end)
		else: av = strclone(c"")
		cookie_apply_av(c, header, start, name_end, av)
		free(av)
		pos = end
	return c


# "name=value" plus the set attributes, in Python's Morsel order:
# Expires, Path, Domain, Max-Age, Secure, HttpOnly, SameSite. Returns 0
# when the name is not a token, the value is not a cookie-value, or an
# attribute value holds a control character or ';'.
char* cookie_serialize_set_cookie(Cookie* c):
	if (!cookie_name_is_valid(c.name) || !cookie_value_is_valid(c.value)): return 0
	if (!cookie_av_is_valid(c.domain) || !cookie_av_is_valid(c.path) || !cookie_av_is_valid(c.same_site)): return 0
	string_builder* sb = string_new()
	string_append(sb, c.name)
	string_append_char(sb, '=')
	string_append(sb, c.value)
	if (c.has_expires):
		char* date = datetime_format_http(c.expires)
		string_append(sb, c"; Expires=")
		string_append(sb, date)
		free(date)
	if (c.path[0] != 0):
		string_append(sb, c"; Path=")
		string_append(sb, c.path)
	if (c.domain[0] != 0):
		string_append(sb, c"; Domain=")
		string_append(sb, c.domain)
	if (c.has_max_age):
		string_append(sb, c"; Max-Age=")
		string_append_int(sb, c.max_age)
	if (c.secure): string_append(sb, c"; Secure")
	if (c.http_only): string_append(sb, c"; HttpOnly")
	if (c.same_site[0] != 0):
		string_append(sb, c"; SameSite=")
		string_append(sb, c.same_site)
	char* result = sb.data
	free(cast(char*, sb))
	return result


# ---- Cookie request header (RFC 6265 4.2 / 5.4) -------------------------------

# Parses a Cookie header value into name/value cookies, in order.
# Pieces are separated by ';' and trimmed; a piece without '=' or with
# an empty name is skipped. Values are kept verbatim (quotes included,
# as RFC 6265 does; Python's SimpleCookie would unquote them).
list[Cookie*] cookie_parse_header(char* header):
	list[Cookie*] out = new list[Cookie*]
	if (header == 0): return out
	int n = strlen(header)
	int pos = 0
	while (pos <= n):
		int end = cookie_index_of_char(header, pos, n, ';')
		if (end < 0): end = n
		int eq = cookie_index_of_char(header, pos, end, '=')
		if (eq >= 0):
			char* name = cookie_trimmed(header, pos, eq)
			if (name[0] != 0):
				char* value = cookie_trimmed(header, eq + 1, end)
				out.push(cookie_new(name, value))
				free(value)
			free(name)
		pos = end + 1
	return out


# "a=1; b=2" for a Cookie request header (names and values only).
# Returns 0 when a name or value is invalid; "" for an empty list.
char* cookie_serialize_header(list[Cookie*] cookies):
	string_builder* sb = string_new()
	for i in range(cookies.length):
		Cookie* c = cookies[i]
		if (!cookie_name_is_valid(c.name) || !cookie_value_is_valid(c.value)):
			string_free(sb)
			return 0
		if (i > 0): string_append(sb, c"; ")
		string_append(sb, c.name)
		string_append_char(sb, '=')
		string_append(sb, c.value)
	char* result = sb.data
	free(cast(char*, sb))
	return result


# ---- matching rules (RFC 6265 5.1.3, 5.1.4) -----------------------------------

# A host that is an IP literal: bracketed or containing ':' (IPv6), or
# all digits and dots (IPv4).
int cookie_host_is_ip(char* host):
	if ((host[0] == '[') || (index_of(host, c":") >= 0)): return 1
	if (host[0] == 0): return 0
	int i = 0
	while (host[i] != 0):
		int c = host[i] & 255
		if ((c != '.') && ((c < '0') || (c > '9'))): return 0
		i = i + 1
	return 1


# RFC 6265 5.1.3: host and domain are canonical (lowercase). Identical,
# or domain is a suffix of a non-IP host preceded by '.'.
int cookie_domain_match(char* host, char* domain):
	if (strcmp(host, domain) == 0): return 1
	int hn = strlen(host)
	int dn = strlen(domain)
	if ((dn == 0) || (dn >= hn)): return 0
	if (host[hn - dn - 1] != '.'): return 0
	if (strcmp(&host[hn - dn], domain) != 0): return 0
	return !cookie_host_is_ip(host)


# RFC 6265 5.1.4 path-match.
int cookie_path_match(char* request_path, char* cookie_path):
	int cn = strlen(cookie_path)
	for i in range(cn):
		if (request_path[i] != cookie_path[i]): return 0
	if (request_path[cn] == 0): return 1
	if ((cn > 0) && (cookie_path[cn - 1] == '/')): return 1
	return request_path[cn] == '/'


# RFC 6265 5.1.4 default-path of a request path (any '?query' ignored).
char* cookie_default_path(char* request_path):
	int n = strlen(request_path)
	int q = cookie_index_of_char(request_path, 0, n, '?')
	if (q >= 0): n = q
	if ((n == 0) || (request_path[0] != '/')): return strclone(c"/")
	int last = 0
	for i in range(n):
		if (request_path[i] == '/'): last = i
	if (last == 0): return strclone(c"/")
	return substring(request_path, 0, last)


# The request path without a query, "/" when empty, malloc'd.
char* cookie_request_path(char* path):
	if (path == 0 || path[0] == 0): return strclone(c"/")
	int n = strlen(path)
	int q = cookie_index_of_char(path, 0, n, '?')
	if (q >= 0): n = q
	if (n == 0): return strclone(c"/")
	return substring(path, 0, n)


# ---- the jar (RFC 6265 5.3 / 5.4) -------------------------------------------

CookieJar* cookie_jar_new():
	CookieJar* jar = new CookieJar()
	jar.cookies = new list[Cookie*]
	jar.next_seq = 1
	return jar


void cookie_jar_free(CookieJar* jar):
	if (jar == 0): return
	cookie_list_free(jar.cookies)
	free(cast(char*, jar))


int cookie_jar_count(CookieJar* jar):
	return jar.cookies.length


int cookie_is_expired(Cookie* c, datetime now):
	if (!c.persistent): return 0
	return datetime_compare(c.expiry, now) <= 0


# Removes (and frees) every persistent cookie whose expiry is not after now.
void cookie_jar_clear_expired(CookieJar* jar, datetime now):
	now = cookie_utc(now)
	int i = 0
	while (i < jar.cookies.length):
		Cookie* c = jar.cookies[i]
		if (cookie_is_expired(c, now)):
			jar.cookies.remove(i)
			cookie_free(c)
		else:
			i = i + 1


# Removes every session (non-persistent) cookie, as at the end of a session.
void cookie_jar_clear_session(CookieJar* jar):
	int i = 0
	while (i < jar.cookies.length):
		Cookie* c = jar.cookies[i]
		if (!c.persistent):
			jar.cookies.remove(i)
			cookie_free(c)
		else:
			i = i + 1


# Removes the cookies whose domain, path and name equal the given ones;
# a 0 argument matches anything (cookie_jar_clear(jar, 0, 0, 0) empties
# the jar). Python's CookieJar.clear(domain, path, name).
void cookie_jar_clear(CookieJar* jar, char* domain, char* path, char* name):
	int i = 0
	while (i < jar.cookies.length):
		Cookie* c = jar.cookies[i]
		int hit = 1
		if ((domain != 0) && (strcmp(c.domain, domain) != 0)): hit = 0
		if ((path != 0) && (strcmp(c.path, path) != 0)): hit = 0
		if ((name != 0) && (strcmp(c.name, name) != 0)): hit = 0
		if (hit):
			jar.cookies.remove(i)
			cookie_free(c)
		else:
			i = i + 1


# Stores a parsed Set-Cookie (RFC 6265 5.3) received for a request to
# host / path over a secure or insecure channel at time now. Takes
# ownership of c: it is kept in the jar, or freed. Returns 1 when the
# cookie was accepted (stored, or applied as an immediate expiry that
# deleted any matching stored cookie) and 0 when it was rejected.
int cookie_jar_add(CookieJar* jar, Cookie* c, char* host, char* path, int secure_channel, datetime now):
	if (c == 0): return 0
	now = cookie_utc(now)
	char* canon_host = cookie_lower_copy(host)
	# Expiry: Max-Age wins over Expires; neither makes a session cookie.
	if (c.has_max_age):
		c.persistent = 1
		c.expiry = cookie_add_seconds(now, c.max_age)
	else if (c.has_expires):
		c.persistent = 1
		c.expiry = c.expires
	else:
		c.persistent = 0
		c.expiry = cookie_epoch_max()
	# Domain.
	int ok = 1
	if (c.domain[0] != 0):
		if (index_of(c.domain, c".") < 0):
			# No public-suffix list: a dotless domain only works as the host itself.
			if (strcmp(c.domain, canon_host) == 0): c.host_only = 1
			else: ok = 0
		else if (cookie_domain_match(canon_host, c.domain)):
			c.host_only = 0
		else:
			ok = 0
	else:
		c.host_only = 1
	if (!ok):
		free(canon_host)
		cookie_free(c)
		return 0
	if (c.host_only):
		free(c.domain)
		c.domain = canon_host
	else:
		free(canon_host)
	# Path.
	if (c.path[0] != '/'):
		free(c.path)
		c.path = cookie_default_path(path)
	c.creation = now
	c.last_access = now
	c.seq = jar.next_seq
	jar.next_seq = jar.next_seq + 1
	# Replace an existing cookie with the same name, domain and path.
	for i in range(jar.cookies.length):
		Cookie* old = jar.cookies[i]
		if ((strcmp(old.name, c.name) == 0) && (strcmp(old.domain, c.domain) == 0) && (strcmp(old.path, c.path) == 0)):
			c.creation = old.creation
			c.seq = old.seq
			jar.cookies.remove(i)
			cookie_free(old)
			break
	if (cookie_is_expired(c, now)):
		cookie_free(c)
		return 1
	jar.cookies.push(c)
	return 1


# Parses a Set-Cookie header and stores it (see cookie_jar_add).
int cookie_jar_set_cookie(CookieJar* jar, char* host, char* path, int secure_channel, char* header, datetime now):
	return cookie_jar_add(jar, cookie_parse_set_cookie(header), host, path, secure_channel, now)


int cookie_url_is_secure(URL* url):
	return strcmp(url.scheme, c"https") == 0


# cookie_jar_set_cookie for a response to url (https is the secure channel).
int cookie_jar_set_cookie_url(CookieJar* jar, URL* url, char* header, datetime now):
	return cookie_jar_set_cookie(jar, url.host, url.path, cookie_url_is_secure(url), header, now)


# Does cookie a sort before b (longer path first, then created earlier)?
int cookie_sorts_before(Cookie* a, Cookie* b):
	int la = strlen(a.path)
	int lb = strlen(b.path)
	if (la != lb): return la > lb
	return a.seq < b.seq


# The cookies to send with a request to host / path (RFC 6265 5.4),
# after evicting expired ones: host-only cookies need the identical
# host, domain cookies a domain-match; the path must path-match; Secure
# cookies need a secure channel. Sorted longest path first, then oldest
# first; each one's last_access becomes now. Returns a new list of
# borrowed pointers: free it with list_free[Cookie*].
list[Cookie*] cookie_jar_matching(CookieJar* jar, char* host, char* path, int secure_channel, datetime now):
	now = cookie_utc(now)
	cookie_jar_clear_expired(jar, now)
	char* canon_host = cookie_lower_copy(host)
	char* req_path = cookie_request_path(path)
	list[Cookie*] out = new list[Cookie*]
	for i in range(jar.cookies.length):
		Cookie* c = jar.cookies[i]
		int hit = 1
		if (c.host_only):
			if (strcmp(canon_host, c.domain) != 0): hit = 0
		else if (!cookie_domain_match(canon_host, c.domain)):
			hit = 0
		if (hit && !cookie_path_match(req_path, c.path)): hit = 0
		if (hit && c.secure && !secure_channel): hit = 0
		if (hit):
			c.last_access = now
			# Stable insertion sort.
			int at = out.length
			while ((at > 0) && cookie_sorts_before(c, out[at - 1])): at = at - 1
			out.insert(at, c)
	free(canon_host)
	free(req_path)
	return out


# The Cookie request-header value for a request to host / path ("a=1;
# b=2"), malloc'd, or 0 when no cookie matches.
char* cookie_jar_header(CookieJar* jar, char* host, char* path, int secure_channel, datetime now):
	list[Cookie*] hits = cookie_jar_matching(jar, host, path, secure_channel, now)
	if (hits.length == 0):
		list_free[Cookie*](hits)
		return 0
	string_builder* sb = string_new()
	for i in range(hits.length):
		Cookie* c = hits[i]
		if (i > 0): string_append(sb, c"; ")
		string_append(sb, c.name)
		string_append_char(sb, '=')
		string_append(sb, c.value)
	list_free[Cookie*](hits)
	char* result = sb.data
	free(cast(char*, sb))
	return result


char* cookie_jar_header_url(CookieJar* jar, URL* url, datetime now):
	return cookie_jar_header(jar, url.host, url.path, cookie_url_is_secure(url), now)
