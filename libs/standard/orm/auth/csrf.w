# CSRF protection for cookie-authenticated requests (issue #754, unit
# U3.2; docs/projects/orm/u3_2.md): Django's CsrfViewMiddleware with
# CSRF_USE_SESSIONS, i.e. the secret lives in the session rather than in
# its own cookie.
#
#   char* tok = csrf_token(s)              # masked, for a form field / header
#   ...on the unsafe request:
#   csrf_request* r = csrf_request_new(c"POST", c"example.com", 1)
#   r.origin = origin_header               # or 0
#   r.referer = referer_header             # or 0
#   r.token = form_or_header_token         # or 0
#   char* why = csrf_check_session(s, r, trusted_origins)   # 0 = accepted
#
# The algorithms are Django's (django/middleware/csrf.py), so tokens are
# interchangeable with a Django app that keeps the secret in the same
# place: a 32-character [A-Za-z0-9] secret, masked per response as
# mask + cipher (64 characters, cipher[i] = secret[i] + mask[i] mod 62),
# and checked with a constant-time compare after unmasking. Unmasked
# 32-character secrets are accepted too, as Django does.
import libs.standard.orm.auth.session


const int CSRF_SECRET_LENGTH = 32
const int CSRF_TOKEN_LENGTH = 64


char* CSRF_ALLOWED_CHARS():
	return c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"


# Rejection reasons (Django's, without the interpolated URL).
char* CSRF_REASON_BAD_ORIGIN(): return c"Origin checking failed - does not match any trusted origins."
char* CSRF_REASON_NO_REFERER(): return c"Referer checking failed - no Referer."
char* CSRF_REASON_BAD_REFERER(): return c"Referer checking failed - does not match any trusted origins."
char* CSRF_REASON_MALFORMED_REFERER(): return c"Referer checking failed - Referer is malformed."
char* CSRF_REASON_INSECURE_REFERER(): return c"Referer checking failed - Referer is insecure while host is secure."
char* CSRF_REASON_NO_SECRET(): return c"CSRF cookie not set."
char* CSRF_REASON_TOKEN_MISSING(): return c"CSRF token missing."
char* CSRF_REASON_TOKEN_LENGTH(): return c"CSRF token has incorrect length."
char* CSRF_REASON_TOKEN_CHARS(): return c"CSRF token has invalid characters."
char* CSRF_REASON_TOKEN_INCORRECT(): return c"CSRF token incorrect."


# Index of c in CSRF_ALLOWED_CHARS, or -1.
int csrf_char_index(int c):
	if (c >= 'a' && c <= 'z'): return c - 'a'
	if (c >= 'A' && c <= 'Z'): return c - 'A' + 26
	if (c >= '0' && c <= '9'): return c - '0' + 52
	return -1


# Owned string of n random allowed characters, or 0 when the CSPRNG failed.
char* csrf_random_string(int n):
	char* out = cast(char*, malloc(n + 1))
	char* chars = CSRF_ALLOWED_CHARS()
	for i in range(n):
		int k = secrets_randbelow(62)
		if (k < 0):
			free(out)
			return 0
		out[i] = chars[k]
	out[n] = 0
	return out


# Owned masked token (64 characters) for a 32-character secret, or 0.
char* csrf_mask(char* secret):
	if (secret == 0 || strlen(secret) != CSRF_SECRET_LENGTH): return 0
	char* mask = csrf_random_string(CSRF_SECRET_LENGTH)
	if (mask == 0): return 0
	char* chars = CSRF_ALLOWED_CHARS()
	char* out = cast(char*, malloc(CSRF_TOKEN_LENGTH + 1))
	for i in range(CSRF_SECRET_LENGTH):
		out[i] = mask[i]
		int x = csrf_char_index(secret[i])
		int y = csrf_char_index(mask[i])
		out[CSRF_SECRET_LENGTH + i] = chars[(x + y) % 62]
	out[CSRF_TOKEN_LENGTH] = 0
	free(mask)
	return out


# Owned secret of a 64-character masked token (Django's
# _unmask_cipher_token). The token's characters must already be valid.
char* csrf_unmask(char* token):
	char* chars = CSRF_ALLOWED_CHARS()
	char* out = cast(char*, malloc(CSRF_SECRET_LENGTH + 1))
	for i in range(CSRF_SECRET_LENGTH):
		int x = csrf_char_index(token[CSRF_SECRET_LENGTH + i])
		int y = csrf_char_index(token[i])
		out[i] = chars[(x - y + 62) % 62]
	out[CSRF_SECRET_LENGTH] = 0
	return out


# Django's _check_token_format: 0 when token is well formed, else the
# reason.
char* csrf_token_format_error(char* token):
	if (token == 0 || token[0] == 0): return CSRF_REASON_TOKEN_MISSING()
	int n = strlen(token)
	if (n != CSRF_SECRET_LENGTH && n != CSRF_TOKEN_LENGTH): return CSRF_REASON_TOKEN_LENGTH()
	for i in range(n):
		if (csrf_char_index(token[i]) < 0): return CSRF_REASON_TOKEN_CHARS()
	return 0


# 1 when token (masked or bare, well formed) carries secret; the final
# compare is constant-time.
int csrf_token_matches(char* secret, char* token):
	if (secret == 0 || csrf_token_format_error(token) != 0): return 0
	if (strlen(token) == CSRF_TOKEN_LENGTH):
		char* plain = csrf_unmask(token)
		int ok = secrets_compare_digest_str(secret, plain)
		free(plain)
		return ok
	return secrets_compare_digest_str(secret, token)


# The session's secret (borrowed), or 0 when it has none.
char* csrf_session_secret(auth_session* s):
	if (s == 0): return 0
	return session_get(s, AUTH_SESSION_CSRF_KEY())


# The session's secret, created when missing (the session is then
# modified: save it). Borrowed; 0 when the CSPRNG failed.
char* csrf_get_secret(auth_session* s):
	char* secret = csrf_session_secret(s)
	if (secret != 0 && strlen(secret) == CSRF_SECRET_LENGTH): return secret
	char* fresh = csrf_random_string(CSRF_SECRET_LENGTH)
	if (fresh == 0): return 0
	session_set(s, AUTH_SESSION_CSRF_KEY(), fresh)
	free(fresh)
	return csrf_session_secret(s)


# Django's rotate_token: a new secret (old tokens stop matching).
void csrf_rotate(auth_session* s):
	session_remove(s, AUTH_SESSION_CSRF_KEY())
	csrf_get_secret(s)


# Django's get_token: a fresh masked token for the session's secret
# (owned), creating the secret when needed. 0 when the CSPRNG failed.
char* csrf_token(auth_session* s):
	return csrf_mask(csrf_get_secret(s))


# RFC 9110 safe methods (GET, HEAD, OPTIONS, TRACE) are exempt.
int csrf_method_is_safe(char* method):
	if (method == 0): return 0
	return strcmp(method, c"GET") == 0 || strcmp(method, c"HEAD") == 0 || strcmp(method, c"OPTIONS") == 0 || strcmp(method, c"TRACE") == 0


int csrf_method_needs_check(char* method):
	return csrf_method_is_safe(method) == 0


# ---------------------------------------------------------------------------
# Origin / Referer

# Splits "scheme://netloc/..." into owned lower-case scheme and netloc.
# Returns 0 when either part is empty.
int csrf_split_url(char* url, char** scheme, char** netloc):
	scheme[0] = 0
	netloc[0] = 0
	if (url == 0): return 0
	int colon = index_of(url, c"://")
	if (colon <= 0): return 0
	int start = colon + 3
	int end = start
	while (url[end] != 0 && url[end] != '/' && url[end] != '?' && url[end] != '#'): end = end + 1
	if (end == start): return 0
	char* s = str_copy_range(url, 0, colon)
	char* n = str_copy_range(url, start, end)
	for i in range(strlen(s)): s[i] = tolower(s[i])
	for i in range(strlen(n)): n[i] = tolower(n[i])
	scheme[0] = s
	netloc[0] = n
	return 1


# Django's is_same_domain: pattern ".example.com" matches example.com and
# every subdomain; anything else must equal host. Both lower-case.
int csrf_same_domain(char* host, char* pattern):
	if (pattern == 0 || pattern[0] == 0): return 0
	if (pattern[0] == '.'):
		return ends_with(host, pattern) || strcmp(host, &pattern[1]) == 0
	return strcmp(host, pattern) == 0


# 1 when trusted origin entry t ("https://app.example.com" or
# "https://*.example.com") admits scheme://netloc.
int csrf_trusted_admits(char* t, char* scheme, char* netloc, int need_scheme):
	char* ts = 0
	char* tn = 0
	if (csrf_split_url(t, &ts, &tn) == 0): return 0
	int ok = 0
	if (need_scheme == 0 || strcmp(ts, scheme) == 0):
		if (tn[0] == '*'): ok = csrf_same_domain(netloc, &tn[1])
		else: ok = strcmp(netloc, tn) == 0
	free(ts)
	free(tn)
	return ok


# Django's _origin_verified: origin equals this host's own origin
# (scheme by is_secure) or a trusted origin (exact, or a "*." wildcard
# for subdomains with the same scheme).
int csrf_origin_ok(char* origin, char* host, int is_secure, list[char*] trusted):
	char* scheme = 0
	char* netloc = 0
	if (csrf_split_url(origin, &scheme, &netloc) == 0): return 0
	int ok = 0
	char* want = c"http"
	if (is_secure): want = c"https"
	if (host != 0 && strcmp(scheme, want) == 0):
		char* h = strclone(host)
		for i in range(strlen(h)): h[i] = tolower(h[i])
		ok = strcmp(netloc, h) == 0
		free(h)
	if (ok == 0 && trusted != 0):
		for char* t in trusted:
			if (ok == 0 && csrf_trusted_admits(t, scheme, netloc, 1)): ok = 1
	free(scheme)
	free(netloc)
	return ok


# Django's _check_referer (HTTPS requests without an Origin header): 0
# when the Referer is an https URL on this host or a trusted origin's
# host, else the reason.
char* csrf_referer_error(char* referer, char* host, list[char*] trusted):
	if (referer == 0 || referer[0] == 0): return CSRF_REASON_NO_REFERER()
	char* scheme = 0
	char* netloc = 0
	if (csrf_split_url(referer, &scheme, &netloc) == 0): return CSRF_REASON_MALFORMED_REFERER()
	char* why = 0
	if (strcmp(scheme, c"https") != 0): why = CSRF_REASON_INSECURE_REFERER()
	else:
		int ok = 0
		if (trusted != 0):
			for char* t in trusted:
				if (ok == 0 && csrf_trusted_admits(t, scheme, netloc, 0)): ok = 1
		if (ok == 0 && host != 0):
			char* h = strclone(host)
			for i in range(strlen(h)): h[i] = tolower(h[i])
			ok = csrf_same_domain(netloc, h)
			free(h)
		if (ok == 0): why = CSRF_REASON_BAD_REFERER()
	free(scheme)
	free(netloc)
	return why


struct csrf_request:
	char* method     # "POST", ...
	char* host       # Host header, with a non-default port ("example.com:8443")
	int is_secure    # the request came over HTTPS
	char* origin     # Origin header or 0
	char* referer    # Referer header or 0
	char* token      # X-CSRFToken header or csrfmiddlewaretoken form field, or 0


# Borrows every string; free with free().
csrf_request* csrf_request_new(char* method, char* host, int is_secure):
	csrf_request* r = new csrf_request()
	r.method = method
	r.host = host
	r.is_secure = is_secure
	return r


# Django's CsrfViewMiddleware.process_view for a request whose session
# secret is `secret` (0 = none): 0 when accepted, else the reason
# (static text). Safe methods pass. Otherwise an Origin header must be
# verified; without one, an HTTPS request needs a good Referer; then the
# token must match the secret.
char* csrf_check(char* secret, csrf_request* r, list[char*] trusted):
	if (csrf_method_is_safe(r.method)): return 0
	if (r.origin != 0):
		if (csrf_origin_ok(r.origin, r.host, r.is_secure, trusted) == 0): return CSRF_REASON_BAD_ORIGIN()
	else if (r.is_secure):
		char* why = csrf_referer_error(r.referer, r.host, trusted)
		if (why != 0): return why
	if (secret == 0): return CSRF_REASON_NO_SECRET()
	char* bad = csrf_token_format_error(r.token)
	if (bad != 0): return bad
	if (csrf_token_matches(secret, r.token) == 0): return CSRF_REASON_TOKEN_INCORRECT()
	return 0


# csrf_check with the secret of session s (0 = no session).
char* csrf_check_session(auth_session* s, csrf_request* r, list[char*] trusted):
	return csrf_check(csrf_session_secret(s), r, trusted)
