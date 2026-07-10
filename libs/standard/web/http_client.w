# HTTP/1.1 client (plaintext + TLS) for the pure-W HTTPS stack (plan 11
# phases 2 + 9, issues #200 and #204, part of #155). Built on lib/stream.w
# buffered reads, libs/standard/web/urlparse.w, and libs/standard/net/dns.w.
# For https:// URLs the socket is wrapped with libs/standard/net/tls.w
# (#204) underneath this same API and every request write / response read /
# streaming byte goes through tls_read/tls_write; the plaintext path is
# unchanged. SSE (#202) consumes the streaming reader; neither changes callers.
#
# Transport-mode note: the plaintext path uses a nonblocking socket with
# poll() timeouts; net/tls.w does blocking socket_recv/socket_send. The
# https:// path therefore switches the socket to blocking after connect and
# arms SO_RCVTIMEO/SO_SNDTIMEO so the TLS handshake and every later
# read/write stays bounded -- a stalled peer can never wedge a request. The
# connect step keeps the nonblocking + poll timeout; the handshake uses
# req.tls_handshake_timeout_ms (else req.timeout_ms); after the handshake
# the socket is re-armed to req.timeout_ms for the header/body/idle reads.
#
# Public API:
#   http_req* http_req_new(char* method, char* url)
#   void http_req_add_header(http_req* req, char* name, char* value)
#   void http_req_free(http_req* req)
#   http_response* http_request(http_req* req)     never returns 0
#   http_response* http_get(char* url)             never returns 0
#   char* http_response_header(http_response* resp, char* name)
#   void http_response_free(http_response* resp)
#   http_stream* http_open(http_req* req)          never returns 0
#   http_response* http_stream_headers(http_stream* s)
#   int http_stream_read(http_stream* s, char* buf, int cap)
#   void http_stream_close(http_stream* s)
#   void http_client_close_idle()
#   int http_error_*()  /  char* http_error_string(int code)
#
# Behavior notes:
# - Requests always send Host (with the port when it is not the scheme
#   default), Accept-Encoding: identity and Connection: keep-alive
#   unless the caller supplied their own, and Content-Length when the
#   request has a body. Caller-supplied Host, Content-Length, and
#   Transfer-Encoding headers are rejected, as is any header name,
#   header value, or URL part containing CR, LF, or other control
#   bytes (header injection hardening).
# - Responses may be Content-Length delimited, chunked (extensions
#   ignored, trailers consumed, chunk sizes capped), or read-to-close
#   (HTTP/1.0 style). Header lines and the total header block are
#   size-capped and fail closed.
# - Redirects: 301/302/303/307/308 with a Location header are followed
#   up to req.max_redirects (303 switches to GET and drops the body);
#   exceeding the cap fails with http_error_too_many_redirects, which
#   also bounds redirect loops. max_redirects <= 0 returns the 3xx
#   response unfollowed.
# - Keep-alive: one idle connection is cached per process and reused
#   when the next request targets the same host:port and the previous
#   response body was fully read under a length-delimited framing. A
#   reused connection that turns out to be dead before yielding a
#   single response byte is retried once on a fresh connection.
# - Timeouts: req.timeout_ms (default 30s) bounds the connect and each
#   blocking read/write wait (an inactivity timeout, not a whole
#   request deadline).
import lib.lib
import lib.str
import lib.net
import lib.poll
import lib.stream
import lib.container
import structures.string
import libs.standard.web.urlparse
import libs.standard.net.dns
import libs.standard.net.tls


struct http_header:
	char* name
	char* value


# One request. method, url, and body are borrowed (the caller keeps
# them alive until the request returns); headers added through
# http_req_add_header are owned by the request.
struct http_req:
	char* method
	char* url
	list[http_header*] headers
	char* body
	int body_len
	int timeout_ms
	int max_redirects
	# TLS knobs (https:// only; ignored for http://). Borrowed like
	# method/url. tls_trust_store_path overrides the system CA bundle
	# (0 = default). tls_insecure_skip_verify (loud by name, tests only)
	# skips chain + hostname checks but never the handshake signature or
	# Finished MAC. tls_has_now_unix/tls_now_unix inject a fixed
	# validation clock for deterministic certificate-validity tests.
	# tls_handshake_timeout_ms bounds the TLS handshake separately from
	# timeout_ms (0 = use timeout_ms): a handshake can legitimately need
	# more inactivity headroom than a per-read wait -- notably against a
	# pure-W loopback server whose ECDSA/X25519 take real CPU time.
	char* tls_trust_store_path
	int tls_insecure_skip_verify
	int tls_has_now_unix
	int tls_now_unix
	int tls_handshake_timeout_ms


# One response. headers maps lowercased header names to values
# (duplicates joined with ", "); body is malloc'd and NUL-terminated
# (body_len excludes the terminator). error is an http_error_* code, 0
# on success; error_message is static text, never freed. status stays
# 0 when the request failed before a status line arrived.
struct http_response:
	int status
	map[char*, char*] headers
	char* body
	int body_len
	int error
	char* error_message


# Buffered reader over one socket. For plaintext the socket is
# nonblocking (poll timeouts); for https tls is non-null, the socket is
# blocking with SO_RCVTIMEO/SO_SNDTIMEO, and all I/O routes through
# tls_read/tls_write. tls_cfg owns the config the tls_conn borrows (freed
# with it); tls_insecure records the verify posture for the idle cache key.
struct http_conn:
	int fd
	wstream* reader
	int timeout_ms
	int error
	int received_any
	tls_conn* tls
	tls_config* tls_cfg
	int tls_insecure


# Streaming response: status and headers are parsed eagerly by
# http_open, the body is pulled incrementally with http_stream_read.
struct http_stream:
	http_conn* conn
	http_response* resp
	int body_mode
	int body_remaining
	int chunk_first
	int body_complete
	int reuse_ok
	int error
	char* cache_host
	int cache_port


/* Limits (fail closed when exceeded) and defaults */

int http_default_timeout_ms():
	return 30000


int http_default_max_redirects():
	return 5


# Cap on one status/header/chunk-size line.
int http_max_header_line():
	return 8192


# Cap on a whole header (or trailer) block.
int http_max_header_bytes():
	return 65536


# Cap on a single chunk in a chunked body.
int http_max_chunk_size():
	return 8388608


# Cap on Content-Length values and on bodies buffered by http_request
# (streaming reads are unbounded in total, bounded per chunk).
int http_max_body_bytes():
	return 1073741824


# Redirect bodies are drained up to this many bytes so the connection
# can be reused; larger ones just close the connection.
int http_max_redirect_drain():
	return 65536


/* Error codes */

int http_error_none():
	return 0


int http_error_bad_url():
	return 1


int http_error_unsupported_scheme():
	return 2


int http_error_dns():
	return 3


int http_error_connect():
	return 4


int http_error_timeout():
	return 5


int http_error_send():
	return 6


int http_error_recv():
	return 7


int http_error_bad_response():
	return 8


int http_error_headers_too_large():
	return 9


int http_error_body_too_large():
	return 10


int http_error_bad_chunk():
	return 11


int http_error_truncated_body():
	return 12


int http_error_too_many_redirects():
	return 13


int http_error_bad_header():
	return 14


# TLS handshake (or transport wrap) failed on an https:// request.
int http_error_tls():
	return 15


# Static description of an http_error_* code. Never freed.
char* http_error_string(int code):
	if (code == http_error_none()):
		return c""
	if (code == http_error_bad_url()):
		return c"invalid URL"
	if (code == http_error_unsupported_scheme()):
		return c"unsupported URL scheme"
	if (code == http_error_dns()):
		return c"DNS resolution failed"
	if (code == http_error_connect()):
		return c"connect failed"
	if (code == http_error_timeout()):
		return c"timed out"
	if (code == http_error_send()):
		return c"send failed"
	if (code == http_error_recv()):
		return c"receive failed"
	if (code == http_error_bad_response()):
		return c"malformed response"
	if (code == http_error_headers_too_large()):
		return c"response headers too large"
	if (code == http_error_body_too_large()):
		return c"response body too large"
	if (code == http_error_bad_chunk()):
		return c"malformed chunked body"
	if (code == http_error_truncated_body()):
		return c"connection closed mid-body"
	if (code == http_error_too_many_redirects()):
		return c"too many redirects"
	if (code == http_error_bad_header()):
		return c"invalid request header"
	if (code == http_error_tls()):
		return c"TLS handshake failed"
	return c"unknown error"


/* Body framing modes */

int http_body_none():
	return 0


int http_body_length():
	return 1


int http_body_chunked():
	return 2


int http_body_close():
	return 3


/* Small text helpers */

int http_lower_char(int c):
	if ((c >= 'A') & (c <= 'Z')):
		return c + 32
	return c


int http_str_ieq(char* a, char* b):
	int i = 0
	while ((a[i] != 0) & (b[i] != 0)):
		if (http_lower_char(a[i] & 255) != http_lower_char(b[i] & 255)):
			return 0
		i = i + 1
	return (a[i] == 0) & (b[i] == 0)


# RFC 9110 token characters, legal in methods and header names.
int http_is_token_char(int c):
	if ((c >= 'a') & (c <= 'z')):
		return 1
	if ((c >= 'A') & (c <= 'Z')):
		return 1
	if ((c >= '0') & (c <= '9')):
		return 1
	if ((c == '!') | (c == '#') | (c == '$') | (c == '%') | (c == '&')):
		return 1
	if ((c == 39) | (c == '*') | (c == '+') | (c == '-') | (c == '.')):
		return 1
	if ((c == '^') | (c == '_') | (c == 96) | (c == '|') | (c == '~')):
		return 1
	return 0


int http_is_token(char* text):
	if (text == 0):
		return 0
	if (text[0] == 0):
		return 0
	int i = 0
	while (text[i] != 0):
		if (http_is_token_char(text[i] & 255) == 0):
			return 0
		i = i + 1
	return 1


# Header values: visible bytes, spaces, and tabs only. CR, LF, NUL,
# and other control bytes are rejected (header injection hardening).
int http_valid_header_value(char* value):
	if (value == 0):
		return 0
	int i = 0
	while (value[i] != 0):
		int c = value[i] & 255
		if ((c < 32) & (c != 9)):
			return 0
		if (c == 127):
			return 0
		i = i + 1
	return 1


# URL parts placed on the request line or in Host: no control bytes,
# no spaces (either would break request framing).
int http_url_part_clean(char* text):
	int i = 0
	while (text[i] != 0):
		int c = text[i] & 255
		if (c < 33):
			return 0
		if (c == 127):
			return 0
		i = i + 1
	return 1


# Case-insensitive search for token as a comma/space-delimited element
# of a header value like "keep-alive, Upgrade".
int http_value_has_token(char* value, char* token):
	int token_length = strlen(token)
	int i = 0
	while (value[i] != 0):
		int c = value[i] & 255
		if ((c == ',') | (c == ' ') | (c == 9) | (c == ';')):
			i = i + 1
		else:
			int start = i
			int elem_done = 0
			while ((value[i] != 0) & (elem_done == 0)):
				c = value[i] & 255
				if ((c == ',') | (c == ' ') | (c == 9) | (c == ';')):
					elem_done = 1
				else:
					i = i + 1
			if (i - start == token_length):
				int j = 0
				int match = 1
				while (j < token_length):
					if (http_lower_char(value[start + j] & 255) != http_lower_char(token[j] & 255)):
						match = 0
						j = token_length
					else:
						j = j + 1
				if (match != 0):
					return 1
	return 0


/* Requests */

# New request with default timeout and redirect cap. method, url, and
# any body assigned to req.body are borrowed, not copied.
http_req* http_req_new(char* method, char* url):
	http_req* req = new http_req()
	req.method = method
	req.url = url
	req.headers = new list[http_header*]
	req.body = 0
	req.body_len = 0
	req.timeout_ms = http_default_timeout_ms()
	req.max_redirects = http_default_max_redirects()
	req.tls_trust_store_path = 0
	req.tls_insecure_skip_verify = 0
	req.tls_has_now_unix = 0
	req.tls_now_unix = 0
	req.tls_handshake_timeout_ms = 0
	return req


# Appends a request header; name and value are copied. Validation
# happens when the request is sent (http_error_bad_header).
void http_req_add_header(http_req* req, char* name, char* value):
	http_header* h = new http_header()
	h.name = strclone(name)
	h.value = strclone(value)
	req.headers.push(h)


void http_req_free(http_req* req):
	if (req == 0):
		return
	for http_header* h in req.headers:
		free(h.name)
		free(h.value)
		free(h)
	list_free[http_header*](req.headers)
	free(req)


/* Responses */

http_response* http_response_new():
	http_response* resp = new http_response()
	resp.status = 0
	resp.headers = new map[char*, char*]
	resp.body = 0
	resp.body_len = 0
	resp.error = 0
	resp.error_message = c""
	return resp


void http_response_set_error(http_response* resp, int code):
	resp.error = code
	resp.error_message = http_error_string(code)


# Case-insensitive header lookup. Returns the stored value (owned by
# the response; do not free) or 0 when absent.
char* http_response_header(http_response* resp, char* name):
	if (resp == 0):
		return 0
	if (name == 0):
		return 0
	char* lower = strclone(name)
	int i = 0
	while (lower[i] != 0):
		lower[i] = http_lower_char(lower[i] & 255)
		i = i + 1
	char* value = resp.headers.get(lower, 0)
	free(lower)
	return value


void http_response_free(http_response* resp):
	if (resp == 0):
		return
	list[char*] keys = resp.headers.keys()
	for char* key in keys:
		char* value = resp.headers[key]
		free(value)
	list_free[char*](keys)
	map_free[char*, char*](resp.headers)
	if (resp.body != 0):
		free(resp.body)
	free(resp)


/* Idle connection cache: at most one keep-alive connection. Keyed on
   (transport, host, port): is_tls distinguishes an https connection from a
   plaintext one so a TLS conn is never handed to a plaintext target or vice
   versa, and for TLS the verify posture (insecure) must also match so an
   insecure connection is never reused for a verifying request. A cached TLS
   connection keeps its tls_conn (keys live) and owning tls_config. */

char* http_idle_host
int http_idle_port
int http_idle_fd
int http_idle_is_tls
int http_idle_insecure
tls_conn* http_idle_tls
tls_config* http_idle_tls_cfg

# Transient outputs of the most recent successful http_cache_take: the
# cached TLS connection and its owning config (both 0 for a plaintext hit).
tls_conn* http_cache_last_tls
tls_config* http_cache_last_tls_cfg


# Closes the cached idle keep-alive connection, if any. A TLS connection
# gets a close_notify and its key material wiped, and its config is freed.
void http_client_close_idle():
	if (http_idle_host != 0):
		if (http_idle_tls != 0):
			tls_close(http_idle_tls)
			http_idle_tls = 0
		if (http_idle_tls_cfg != 0):
			tls_config_free(http_idle_tls_cfg)
			http_idle_tls_cfg = 0
		close(http_idle_fd)
		free(http_idle_host)
		http_idle_host = 0


# Takes the cached connection when it targets the same transport + host:port
# (and, for TLS, the same verify posture). Returns the fd (with any TLS state
# in http_cache_last_tls / http_cache_last_tls_cfg) or -1.
int http_cache_take(char* host, int port, int is_tls, int insecure):
	http_cache_last_tls = 0
	http_cache_last_tls_cfg = 0
	if (http_idle_host == 0):
		return (-1)
	if (strcmp(http_idle_host, host) != 0):
		return (-1)
	if (http_idle_port != port):
		return (-1)
	if (http_idle_is_tls != is_tls):
		return (-1)
	if (is_tls != 0):
		if (http_idle_insecure != insecure):
			return (-1)
	int fd = http_idle_fd
	http_cache_last_tls = http_idle_tls
	http_cache_last_tls_cfg = http_idle_tls_cfg
	http_idle_tls = 0
	http_idle_tls_cfg = 0
	free(http_idle_host)
	http_idle_host = 0
	return fd


void http_cache_put(char* host, int port, int is_tls, int insecure, int fd, tls_conn* tls, tls_config* cfg):
	http_client_close_idle()
	http_idle_host = strclone(host)
	http_idle_port = port
	http_idle_is_tls = is_tls
	http_idle_insecure = insecure
	http_idle_fd = fd
	http_idle_tls = tls
	http_idle_tls_cfg = cfg


/* Connection: nonblocking socket + buffered reader + poll timeouts */

http_conn* http_conn_new(int fd, int timeout_ms):
	http_conn* c = new http_conn()
	c.fd = fd
	c.reader = stream_reader(fd)
	c.timeout_ms = timeout_ms
	c.error = 0
	c.received_any = 0
	c.tls = 0
	c.tls_cfg = 0
	c.tls_insecure = 0
	return c


void http_conn_destroy(http_conn* c):
	# tls_close sends close_notify over the fd and wipes/frees the keys,
	# so it must run before the fd is closed. The owning config outlives
	# the tls_conn (which only borrows it), so free it here too.
	if (c.tls != 0):
		tls_close(c.tls)
	if (c.tls_cfg != 0):
		tls_config_free(c.tls_cfg)
	close(c.fd)
	stream_free(c.reader)
	free(c)


# Builds a per-connection tls_config from a request's TLS knobs. The
# trust-store path is borrowed from the request (never freed by the
# config). The config must outlive the tls_conn that borrows it.
tls_config* http_build_tls_config(http_req* req):
	tls_config* cfg = tls_config_new()
	cfg.trust_store_path = req.tls_trust_store_path
	cfg.insecure_skip_verify = req.tls_insecure_skip_verify
	if (req.tls_has_now_unix != 0):
		cfg.has_now_unix = 1
		cfg.now_unix = req.tls_now_unix
	return cfg


# Refills the reader buffer from the socket, waiting up to timeout_ms.
# Returns 1 when bytes are buffered, 0 on EOF, -1 on error or timeout
# (c.error set).
int http_conn_fill(http_conn* c):
	wstream* r = c.reader
	if (r.position < r.limit):
		return 1
	if (r.eof != 0):
		return 0
	r.position = 0
	r.limit = 0
	if (c.tls != 0):
		# Blocking read bounded by SO_RCVTIMEO (armed at connect time).
		# tls_read drains its own buffered plaintext first, so no read
		# waits on a record that already arrived. 0 = clean close_notify
		# EOF, <0 = error: a broken connection is a protocol failure,
		# otherwise a timed-out (SO_RCVTIMEO) or reset read.
		int tcount = tls_read(c.tls, r.buffer, r.capacity)
		if (tcount > 0):
			r.limit = tcount
			c.received_any = 1
			return 1
		if (tcount == 0):
			r.eof = 1
			return 0
		if (c.tls.broken != 0):
			c.error = http_error_recv()
		else:
			c.error = http_error_timeout()
		return (-1)
	while (1):
		int count = socket_recv(c.fd, r.buffer, r.capacity, 0)
		if (count > 0):
			r.limit = count
			c.received_any = 1
			return 1
		if (count == 0):
			r.eof = 1
			return 0
		if ((count != (0 - net_eagain())) & (count != (0 - 4))):
			# Hard receive error (EINTR, -4, retries instead).
			c.error = http_error_recv()
			return (-1)
		int ready = poll_single(c.fd, poll_in(), c.timeout_ms)
		if (ready == 0):
			c.error = http_error_timeout()
			return (-1)
		if (ready < 0):
			if (ready != (0 - 4)):
				c.error = http_error_recv()
				return (-1)


# Next byte, or -1 on EOF/error (EOF leaves c.error at 0).
int http_conn_read_byte(http_conn* c):
	int state = http_conn_fill(c)
	if (state <= 0):
		return (-1)
	wstream* r = c.reader
	int b = r.buffer[r.position] & 255
	r.position = r.position + 1
	return b


# Reads up to want bytes (at least 1 unless the stream ends). Returns
# the count, 0 on EOF, -1 on error (c.error set).
int http_conn_read(http_conn* c, char* out, int want):
	int state = http_conn_fill(c)
	if (state <= 0):
		return state
	wstream* r = c.reader
	int n = r.limit - r.position
	if (n > want):
		n = want
	int i = 0
	while (i < n):
		out[i] = r.buffer[r.position + i]
		i = i + 1
	r.position = r.position + n
	return n


# Reads one line, accepting CRLF or bare LF and stripping both.
# Returns 1 on a line, 0 on EOF before any byte, -1 on error: c.error
# is oversize_error when the line exceeds http_max_header_line(),
# stays 0 for EOF mid-line (caller picks the code), or is already set
# by the transport.
int http_conn_read_line(http_conn* c, string_builder* line, int oversize_error):
	string_clear(line)
	while (1):
		int b = http_conn_read_byte(c)
		if (b < 0):
			if (c.error != 0):
				return (-1)
			if (line.length == 0):
				return 0
			return (-1)
		if (b == 10):
			if (line.length > 0):
				if (line.data[line.length - 1] == 13):
					line.length = line.length - 1
					line.data[line.length] = 0
			return 1
		if (line.length >= http_max_header_line()):
			c.error = oversize_error
			return (-1)
		string_append_char(line, b)


# Sends all n bytes, polling for writability as needed. Returns 1, or
# 0 with c.error set.
int http_conn_write_all(http_conn* c, char* data, int n):
	if (c.tls != 0):
		# tls_write sends every byte (fragmenting to the record cap) or
		# returns -1. The send is bounded by SO_SNDTIMEO on the socket.
		if (n <= 0):
			return 1
		int wrote = tls_write(c.tls, data, n)
		if (wrote == n):
			return 1
		c.error = http_error_send()
		return 0
	int total = 0
	while (total < n):
		int count = socket_send(c.fd, data + total, n - total, msg_nosignal())
		if (count > 0):
			total = total + count
		else if (count == 0):
			c.error = http_error_send()
			return 0
		else if ((count == (0 - net_eagain())) | (count == (0 - 4))):
			int ready = poll_single(c.fd, poll_out(), c.timeout_ms)
			if (ready == 0):
				c.error = http_error_timeout()
				return 0
			if (ready < 0):
				if (ready != (0 - 4)):
					c.error = http_error_send()
					return 0
		else:
			c.error = http_error_send()
			return 0
	return 1


# Nonblocking connect with a poll timeout. Returns the socket, or the
# negated http_error_* code.
int http_connect_fd(int ip, int port, int timeout_ms):
	int fd = socket_tcp_ipv4()
	if (fd < 0):
		return 0 - http_error_connect()
	if (socket_set_nonblocking(fd) < 0):
		close(fd)
		return 0 - http_error_connect()
	# SIGPIPE suppression on targets without MSG_NOSIGNAL (Darwin).
	socket_set_nosigpipe(fd)
	int rc = socket_connect_ipv4(fd, ip, port)
	if (rc < 0):
		if (rc != (0 - net_einprogress())):
			close(fd)
			return 0 - http_error_connect()
		int ready = poll_single(fd, poll_out(), timeout_ms)
		if (ready == 0):
			close(fd)
			return 0 - http_error_timeout()
		if (ready < 0):
			close(fd)
			return 0 - http_error_connect()
		if ((ready & (poll_err() | poll_hup())) != 0):
			close(fd)
			return 0 - http_error_connect()
		if ((ready & poll_out()) == 0):
			close(fd)
			return 0 - http_error_connect()
	return fd


/* Request validation and writing */

# Returns 0 or the http_error_* code describing the first problem.
int http_validate_req(http_req* req):
	if (http_is_token(req.method) == 0):
		return http_error_bad_header()
	if ((req.body != 0) & (req.body_len < 0)):
		return http_error_bad_header()
	for http_header* h in req.headers:
		if (http_is_token(h.name) == 0):
			return http_error_bad_header()
		if (http_valid_header_value(h.value) == 0):
			return http_error_bad_header()
		# The client owns these; caller-supplied copies could desync
		# framing (request smuggling) or the Host the server routes on.
		if (http_str_ieq(h.name, c"host") != 0):
			return http_error_bad_header()
		if (http_str_ieq(h.name, c"content-length") != 0):
			return http_error_bad_header()
		if (http_str_ieq(h.name, c"transfer-encoding") != 0):
			return http_error_bad_header()
	return 0


# Whether a URL's transport is TLS (https). url_parse only yields http or
# https, so this is the single scheme discriminator the client keys on.
int http_url_is_tls(url* u):
	return strcmp(u.scheme, c"https") == 0


# Returns 0 or an http_error_* code. Both http:// (plaintext) and https://
# (TLS, wired through net/tls.w) are dialable; any other scheme is
# unsupported (url_parse already rejects non-http(s) schemes upstream).
int http_validate_url(url* u):
	int ok_scheme = 0
	if (strcmp(u.scheme, c"http") == 0):
		ok_scheme = 1
	if (strcmp(u.scheme, c"https") == 0):
		ok_scheme = 1
	if (ok_scheme == 0):
		return http_error_unsupported_scheme()
	if (http_url_part_clean(u.host) == 0):
		return http_error_bad_url()
	if (http_url_part_clean(u.path) == 0):
		return http_error_bad_url()
	if (http_url_part_clean(u.query) == 0):
		return http_error_bad_url()
	return 0


# Whether the request headers permit reusing the connection afterwards
# (no caller-supplied "Connection: close").
int http_req_allows_reuse(http_req* req):
	for http_header* h in req.headers:
		if (http_str_ieq(h.name, c"connection") != 0):
			if (http_value_has_token(h.value, c"close") != 0):
				return 0
	return 1


# Writes the request head and body. Returns 1, or 0 with c.error set.
int http_send_request(http_conn* c, http_req* req, url* u, char* method, int include_body):
	string_builder* out = string_new()
	string_append(out, method)
	string_append_char(out, ' ')
	string_append(out, u.path)
	if (u.query[0] != 0):
		string_append_char(out, '?')
		string_append(out, u.query)
	string_append(out, c" HTTP/1.1\x0d\x0a")
	string_append(out, c"Host: ")
	string_append(out, u.host)
	if (u.port != url_default_port(u.scheme)):
		string_append_char(out, ':')
		char* port_text = itoa(u.port)
		string_append(out, port_text)
		free(port_text)
	string_append(out, c"\x0d\x0a")
	int user_accept_encoding = 0
	int user_connection = 0
	for http_header* h in req.headers:
		string_append(out, h.name)
		string_append(out, c": ")
		string_append(out, h.value)
		string_append(out, c"\x0d\x0a")
		if (http_str_ieq(h.name, c"accept-encoding") != 0):
			user_accept_encoding = 1
		if (http_str_ieq(h.name, c"connection") != 0):
			user_connection = 1
	int with_body = 0
	if ((include_body != 0) & (req.body != 0)):
		with_body = 1
		string_append(out, c"Content-Length: ")
		char* length_text = itoa(req.body_len)
		string_append(out, length_text)
		free(length_text)
		string_append(out, c"\x0d\x0a")
	if (user_accept_encoding == 0):
		string_append(out, c"Accept-Encoding: identity\x0d\x0a")
	if (user_connection == 0):
		string_append(out, c"Connection: keep-alive\x0d\x0a")
	string_append(out, c"\x0d\x0a")
	if (with_body != 0):
		string_append_bytes(out, req.body, req.body_len)
	int ok = http_conn_write_all(c, out.data, out.length)
	string_free(out)
	return ok


/* Response head parsing */

# "HTTP/1.<d> <3 digits>[ reason]". Returns 1/0.
int http_parse_status_line(char* line, int* out_status, int* out_minor):
	if (starts_with(line, c"HTTP/1.") == 0):
		return 0
	int d = line[7] & 255
	if ((d < '0') | (d > '9')):
		return 0
	if (line[8] != ' '):
		return 0
	int status = 0
	int digits = 0
	int i = 9
	while ((line[i] >= '0') & (line[i] <= '9')):
		status = status * 10 + (line[i] - '0')
		digits = digits + 1
		i = i + 1
	if (digits != 3):
		return 0
	if ((line[i] != 0) & (line[i] != ' ')):
		return 0
	if (status < 100):
		return 0
	*out_status = status
	*out_minor = d - '0'
	return 1


# Value bytes of a header line with surrounding spaces/tabs trimmed,
# as a fresh allocation.
char* http_trimmed_value(char* line, int start, int end):
	while ((start < end) & ((line[start] == ' ') | (line[start] == 9))):
		start = start + 1
	while ((end > start) & ((line[end - 1] == ' ') | (line[end - 1] == 9))):
		end = end - 1
	return substring(line, start, end)


# Parses "Name: value" into resp.headers (name lowercased, duplicates
# joined with ", "). Returns 1, or 0 on a malformed line (obs-fold,
# empty or non-token name).
int http_store_header(http_response* resp, char* line, int length):
	int first = line[0] & 255
	if ((first == ' ') | (first == 9)):
		# Obsolete line folding: fail closed.
		return 0
	int colon = 0
	while ((line[colon] != 0) & (line[colon] != ':')):
		colon = colon + 1
	if ((line[colon] != ':') | (colon == 0)):
		return 0
	int i = 0
	while (i < colon):
		if (http_is_token_char(line[i] & 255) == 0):
			return 0
		i = i + 1
	char* name = substring(line, 0, colon)
	i = 0
	while (name[i] != 0):
		name[i] = http_lower_char(name[i] & 255)
		i = i + 1
	char* value = http_trimmed_value(line, colon + 1, length)
	if (name in resp.headers):
		char* old = resp.headers[name]
		char* joined_head = strjoin(old, c", ")
		char* joined = strjoin(joined_head, value)
		free(joined_head)
		free(old)
		free(value)
		resp.headers[name] = joined
	else:
		resp.headers[name] = value
	free(name)
	return 1


# Reads the status line and header block into resp, skipping interim
# 1xx responses. Returns 1 on success, 0 on error (resp.error set),
# -1 when the connection yielded no bytes at all (stale keep-alive
# candidate; resp.error left for the caller).
int http_read_head(http_conn* c, http_response* resp, int* out_minor):
	string_builder* line = string_new()
	int rounds = 0
	while (1):
		int got = http_conn_read_line(c, line, http_error_headers_too_large())
		if (got <= 0):
			int no_bytes = 0
			if (c.received_any == 0):
				if (got == 0):
					no_bytes = 1
				else if (c.error == http_error_recv()):
					no_bytes = 1
			string_free(line)
			if (no_bytes != 0):
				return (-1)
			if (c.error != 0):
				http_response_set_error(resp, c.error)
			else:
				http_response_set_error(resp, http_error_bad_response())
			return 0
		int status = 0
		int minor = 1
		if (http_parse_status_line(line.data, &status, &minor) == 0):
			string_free(line)
			http_response_set_error(resp, http_error_bad_response())
			return 0
		int interim = 0
		if ((status >= 100) & (status <= 199)):
			interim = 1
		int total = 0
		int in_block = 1
		while (in_block != 0):
			got = http_conn_read_line(c, line, http_error_headers_too_large())
			if (got <= 0):
				if (c.error != 0):
					http_response_set_error(resp, c.error)
				else:
					http_response_set_error(resp, http_error_bad_response())
				string_free(line)
				return 0
			if (line.length == 0):
				in_block = 0
			else:
				total = total + line.length + 2
				if (total > http_max_header_bytes()):
					http_response_set_error(resp, http_error_headers_too_large())
					string_free(line)
					return 0
				if (interim == 0):
					if (http_store_header(resp, line.data, line.length) == 0):
						http_response_set_error(resp, http_error_bad_response())
						string_free(line)
						return 0
		if (interim == 0):
			resp.status = status
			*out_minor = minor
			string_free(line)
			return 1
		rounds = rounds + 1
		if (rounds > 4):
			http_response_set_error(resp, http_error_bad_response())
			string_free(line)
			return 0
	return 0


# Content-Length value: digits only, capped. Returns the length or -1.
int http_parse_content_length(char* value):
	if (value[0] == 0):
		return (-1)
	int result = 0
	int i = 0
	while (value[i] != 0):
		int d = value[i] & 255
		if ((d < '0') | (d > '9')):
			return (-1)
		if (result > 107374182):
			return (-1)
		result = result * 10 + (d - '0')
		i = i + 1
	if (result > http_max_body_bytes()):
		return (-1)
	return result


# Whether the response allows keeping the connection open afterwards.
int http_response_keep_alive(http_response* resp, int minor):
	char* connection = http_response_header(resp, c"connection")
	if (minor >= 1):
		if (connection == 0):
			return 1
		if (http_value_has_token(connection, c"close") != 0):
			return 0
		return 1
	if (connection == 0):
		return 0
	return http_value_has_token(connection, c"keep-alive")


/* Streaming */

http_stream* http_stream_new():
	http_stream* s = new http_stream()
	s.conn = 0
	s.resp = http_response_new()
	s.body_mode = http_body_none()
	s.body_remaining = 0
	s.chunk_first = 1
	s.body_complete = 0
	s.reuse_ok = 0
	s.error = 0
	s.cache_host = 0
	s.cache_port = 0
	return s


void http_stream_fail(http_stream* s, int code):
	s.error = code
	if (s.resp != 0):
		http_response_set_error(s.resp, code)


# Status and headers of the opened response. Owned by the stream and
# released by http_stream_close.
http_response* http_stream_headers(http_stream* s):
	return s.resp


# Hands the connection back: to the idle cache when the response was
# fully consumed under keep-alive with no buffered leftovers, closed
# otherwise.
void http_stream_release_conn(http_stream* s):
	http_conn* c = s.conn
	if (c == 0):
		return
	s.conn = 0
	int can_cache = 0
	if ((s.reuse_ok != 0) & (s.body_complete != 0)):
		if ((s.error == 0) & (c.error == 0) & (s.cache_host != 0)):
			wstream* r = c.reader
			if ((r.position >= r.limit) & (r.eof == 0)):
				can_cache = 1
				# A TLS conn may still hold decrypted plaintext buffered
				# inside tls_read; caching then would strand those bytes.
				if (c.tls != 0):
					if (c.tls.app_pos < c.tls.app_len):
						can_cache = 0
	if (can_cache != 0):
		int is_tls = 0
		if (c.tls != 0):
			is_tls = 1
		# Ownership of the tls_conn + its config transfers to the cache,
		# so do NOT tls_close / tls_config_free here (only free the wrapper).
		http_cache_put(s.cache_host, s.cache_port, is_tls, c.tls_insecure, c.fd, c.tls, c.tls_cfg)
		stream_free(c.reader)
		free(c)
	else:
		http_conn_destroy(c)


# Decides body framing from the response (RFC 9112 6.3). Returns 1, or
# 0 with the error set.
int http_stream_set_framing(http_stream* s, char* method):
	http_response* resp = s.resp
	int status = resp.status
	int no_body = 0
	if (strcmp(method, c"HEAD") == 0):
		no_body = 1
	if ((status == 204) | (status == 304)):
		no_body = 1
	if (no_body != 0):
		s.body_mode = http_body_none()
		s.body_remaining = 0
		return 1
	char* te = http_response_header(resp, c"transfer-encoding")
	if (te != 0):
		# Only plain chunked is decodable; anything else fails closed.
		char* trimmed = http_trimmed_value(te, 0, strlen(te))
		int is_chunked = http_str_ieq(trimmed, c"chunked")
		free(trimmed)
		if (is_chunked == 0):
			http_stream_fail(s, http_error_bad_response())
			return 0
		s.body_mode = http_body_chunked()
		s.body_remaining = 0
		s.chunk_first = 1
		return 1
	char* cl = http_response_header(resp, c"content-length")
	if (cl != 0):
		int length = http_parse_content_length(cl)
		if (length < 0):
			http_stream_fail(s, http_error_bad_response())
			return 0
		s.body_mode = http_body_length()
		s.body_remaining = length
		return 1
	s.body_mode = http_body_close()
	s.body_remaining = 0
	return 1


int http_stream_read_length(http_stream* s, char* out, int cap):
	int want = cap
	if (want > s.body_remaining):
		want = s.body_remaining
	int got = http_conn_read(s.conn, out, want)
	if (got < 0):
		http_stream_fail(s, s.conn.error)
		return (-1)
	if (got == 0):
		http_stream_fail(s, http_error_truncated_body())
		return (-1)
	s.body_remaining = s.body_remaining - got
	if (s.body_remaining == 0):
		s.body_complete = 1
		http_stream_release_conn(s)
	return got


int http_stream_read_close(http_stream* s, char* out, int cap):
	int got = http_conn_read(s.conn, out, cap)
	if (got < 0):
		http_stream_fail(s, s.conn.error)
		return (-1)
	if (got == 0):
		s.body_complete = 1
		http_stream_release_conn(s)
		return 0
	return got


# The CRLF that terminates each chunk's data (bare LF tolerated).
int http_conn_expect_crlf(http_conn* c):
	int b = http_conn_read_byte(c)
	if (b == 13):
		b = http_conn_read_byte(c)
	if (b != 10):
		return 0
	return 1


# Chunk-size line: hex digits, then optional spaces and an optional
# ";extensions" tail which is ignored. Returns the size, or -1 when
# malformed or over http_max_chunk_size().
int http_parse_chunk_size(char* line):
	int value = 0
	int digits = 0
	int i = 0
	while (url_is_hex_digit(line[i] & 255) != 0):
		value = value * 16 + url_hex_digit_value(line[i] & 255)
		digits = digits + 1
		if (value > http_max_chunk_size()):
			return (-1)
		i = i + 1
	if (digits == 0):
		return (-1)
	while ((line[i] == ' ') | (line[i] == 9)):
		i = i + 1
	if ((line[i] != 0) & (line[i] != ';')):
		return (-1)
	return value


# Consumes trailer lines after the terminal 0-size chunk. Contents
# are discarded but stay bounded. Returns 1, or 0 with the error set.
int http_stream_consume_trailers(http_stream* s):
	string_builder* line = string_new()
	int total = 0
	while (1):
		int got = http_conn_read_line(s.conn, line, http_error_headers_too_large())
		if (got <= 0):
			if (s.conn.error != 0):
				http_stream_fail(s, s.conn.error)
			else:
				http_stream_fail(s, http_error_truncated_body())
			string_free(line)
			return 0
		if (line.length == 0):
			string_free(line)
			return 1
		total = total + line.length + 2
		if (total > http_max_header_bytes()):
			http_stream_fail(s, http_error_headers_too_large())
			string_free(line)
			return 0
	return 0


int http_stream_read_chunked(http_stream* s, char* out, int cap):
	while (1):
		if (s.body_remaining > 0):
			int want = cap
			if (want > s.body_remaining):
				want = s.body_remaining
			int got = http_conn_read(s.conn, out, want)
			if (got < 0):
				http_stream_fail(s, s.conn.error)
				return (-1)
			if (got == 0):
				http_stream_fail(s, http_error_truncated_body())
				return (-1)
			s.body_remaining = s.body_remaining - got
			return got
		# At a chunk boundary: read the next chunk-size line.
		if (s.chunk_first == 0):
			if (http_conn_expect_crlf(s.conn) == 0):
				if (s.conn.error != 0):
					http_stream_fail(s, s.conn.error)
				else:
					http_stream_fail(s, http_error_bad_chunk())
				return (-1)
		string_builder* line = string_new()
		int got_line = http_conn_read_line(s.conn, line, http_error_bad_chunk())
		if (got_line <= 0):
			if (s.conn.error != 0):
				http_stream_fail(s, s.conn.error)
			else:
				http_stream_fail(s, http_error_truncated_body())
			string_free(line)
			return (-1)
		int size = http_parse_chunk_size(line.data)
		string_free(line)
		if (size < 0):
			http_stream_fail(s, http_error_bad_chunk())
			return (-1)
		s.chunk_first = 0
		if (size == 0):
			if (http_stream_consume_trailers(s) == 0):
				return (-1)
			s.body_complete = 1
			http_stream_release_conn(s)
			return 0
		s.body_remaining = size
	return 0


# Next body bytes into buf. Returns the count (>= 1), 0 at the end of
# the body, or -1 on error (s.error and the response error are set).
int http_stream_read(http_stream* s, char* buf, int cap):
	if (s == 0):
		return (-1)
	if (s.error != 0):
		return (-1)
	if (s.body_complete != 0):
		return 0
	if (s.conn == 0):
		return 0
	if (cap <= 0):
		return 0
	if (s.body_mode == http_body_length()):
		return http_stream_read_length(s, buf, cap)
	if (s.body_mode == http_body_chunked()):
		return http_stream_read_chunked(s, buf, cap)
	if (s.body_mode == http_body_close()):
		return http_stream_read_close(s, buf, cap)
	return 0


void http_stream_close(http_stream* s):
	if (s == 0):
		return
	http_stream_release_conn(s)
	if (s.resp != 0):
		http_response_free(s.resp)
	if (s.cache_host != 0):
		free(s.cache_host)
	free(s)


/* Opening a stream: connect, send, parse head, follow redirects */

# One request/response exchange on one connection. Returns 1 on a
# parsed head, 0 on failure; *out_stale reports a reused connection
# that died before yielding any bytes (retryable).
int http_open_attempt(http_stream* s, http_req* req, url* u, char* method, int include_body, int use_cache, int* out_stale):
	*out_stale = 0
	int timeout = req.timeout_ms
	if (timeout <= 0):
		timeout = http_default_timeout_ms()
	int is_tls = http_url_is_tls(u)
	int insecure = 0
	if (is_tls != 0):
		insecure = req.tls_insecure_skip_verify
	int from_cache = 0
	int fd = (-1)
	tls_conn* tls = 0
	tls_config* tls_cfg = 0
	if (use_cache != 0):
		fd = http_cache_take(u.host, u.port, is_tls, insecure)
		if (fd >= 0):
			from_cache = 1
			tls = http_cache_last_tls
			tls_cfg = http_cache_last_tls_cfg
	if (fd < 0):
		int ip = 0
		if (dns_resolve_ipv4(u.host, &ip) == 0):
			http_stream_fail(s, http_error_dns())
			return 0
		fd = http_connect_fd(ip, u.port, timeout)
		if (fd < 0):
			http_stream_fail(s, 0 - fd)
			return 0
		if (is_tls != 0):
			# net/tls.w uses blocking socket I/O: switch off O_NONBLOCK and
			# arm SO_RCVTIMEO/SO_SNDTIMEO so the handshake and every later
			# read/write is bounded. The handshake gets its own budget
			# (tls_handshake_timeout_ms, else timeout_ms); the socket is then
			# re-armed to timeout_ms for the header/body/idle reads.
			if (socket_set_blocking(fd) < 0):
				close(fd)
				http_stream_fail(s, http_error_connect())
				return 0
			int hs_timeout = timeout
			if (req.tls_handshake_timeout_ms > 0):
				hs_timeout = req.tls_handshake_timeout_ms
			socket_set_recv_timeout(fd, hs_timeout)
			socket_set_send_timeout(fd, hs_timeout)
			tls_cfg = http_build_tls_config(req)
			tls = tls_connect(fd, u.host, tls_cfg)
			if (tls == 0):
				tls_config_free(tls_cfg)
				close(fd)
				http_stream_fail(s, http_error_tls())
				return 0
			socket_set_recv_timeout(fd, timeout)
			socket_set_send_timeout(fd, timeout)
	http_conn* c = http_conn_new(fd, timeout)
	c.tls = tls
	c.tls_cfg = tls_cfg
	c.tls_insecure = insecure
	if (http_send_request(c, req, u, method, include_body) == 0):
		int send_error = c.error
		int send_received = c.received_any
		http_conn_destroy(c)
		if ((from_cache != 0) & (send_received == 0) & (send_error == http_error_send())):
			*out_stale = 1
			return 0
		http_stream_fail(s, send_error)
		return 0
	int minor = 1
	int head = http_read_head(c, s.resp, &minor)
	if (head < 0):
		int head_error = c.error
		http_conn_destroy(c)
		if (from_cache != 0):
			*out_stale = 1
			return 0
		if (head_error != 0):
			http_stream_fail(s, head_error)
		else:
			http_stream_fail(s, http_error_bad_response())
		return 0
	if (head == 0):
		s.error = s.resp.error
		http_conn_destroy(c)
		return 0
	s.conn = c
	s.cache_host = strclone(u.host)
	s.cache_port = u.port
	if (http_stream_set_framing(s, method) == 0):
		return 0
	s.reuse_ok = 0
	if (s.body_mode != http_body_close()):
		if (http_response_keep_alive(s.resp, minor) != 0):
			if (http_req_allows_reuse(req) != 0):
				s.reuse_ok = 1
	if (s.body_mode == http_body_none()):
		s.body_complete = 1
		http_stream_release_conn(s)
	else if ((s.body_mode == http_body_length()) & (s.body_remaining == 0)):
		s.body_complete = 1
		http_stream_release_conn(s)
	return 1


# One exchange, retrying once on a fresh connection when a reused
# keep-alive connection turns out to be dead.
int http_open_single(http_stream* s, http_req* req, url* u, char* method, int include_body):
	int stale = 0
	if (http_open_attempt(s, req, u, method, include_body, 1, &stale) != 0):
		return 1
	if (stale == 0):
		return 0
	http_response_free(s.resp)
	s.resp = http_response_new()
	s.error = 0
	return http_open_attempt(s, req, u, method, include_body, 0, &stale)


# Resolves a Location header against the current URL: absolute URLs,
# scheme-relative "//host/...", absolute paths "/...", and relative
# paths. Returns a parsed url or 0.
url* http_redirect_target(url* base, char* location):
	if (location == 0):
		return 0
	if (location[0] == 0):
		return 0
	url* direct = url_parse(location)
	if (direct != 0):
		return direct
	string_builder* text = string_new()
	if ((location[0] == '/') & (location[1] == '/')):
		string_append(text, base.scheme)
		string_append_char(text, ':')
		string_append(text, location)
	else:
		string_append(text, base.scheme)
		string_append(text, c"://")
		string_append(text, base.host)
		if (base.port != url_default_port(base.scheme)):
			string_append_char(text, ':')
			char* port_text = itoa(base.port)
			string_append(text, port_text)
			free(port_text)
		if (location[0] == '/'):
			string_append(text, location)
		else:
			# Merge with the directory of the current path.
			int last_slash = 0
			int i = 0
			while (base.path[i] != 0):
				if (base.path[i] == '/'):
					last_slash = i
				i = i + 1
			string_append_bytes(text, base.path, last_slash + 1)
			string_append(text, location)
	url* u = url_parse(text.data)
	string_free(text)
	return u


# Prepares the stream for the next hop: drains a bounded amount of the
# current body so the connection can be reused, releases it, and
# resets the parse state.
void http_stream_redirect_reset(http_stream* s):
	if ((s.conn != 0) & (s.body_complete == 0) & (s.error == 0)):
		char* scratch = malloc(4096)
		int drained = 0
		int more = 1
		while (more != 0):
			int got = http_stream_read(s, scratch, 4096)
			if (got <= 0):
				more = 0
			else:
				drained = drained + got
				if (drained > http_max_redirect_drain()):
					s.reuse_ok = 0
					more = 0
		free(scratch)
	http_stream_release_conn(s)
	http_response_free(s.resp)
	s.resp = http_response_new()
	s.error = 0
	s.body_mode = http_body_none()
	s.body_remaining = 0
	s.chunk_first = 1
	s.body_complete = 0
	s.reuse_ok = 0
	if (s.cache_host != 0):
		free(s.cache_host)
		s.cache_host = 0


int http_status_is_redirect(int status):
	if ((status == 301) | (status == 302) | (status == 303)):
		return 1
	if ((status == 307) | (status == 308)):
		return 1
	return 0


# Opens a streaming request: validates, connects, sends, parses the
# status line and headers, and follows redirects. Never returns 0;
# check http_stream_headers(s).error (mirrored in s.error) before
# reading. SSE (#202) consumes the body via http_stream_read.
http_stream* http_open(http_req* req):
	http_stream* s = http_stream_new()
	if (req == 0):
		http_stream_fail(s, http_error_bad_url())
		return s
	int req_error = http_validate_req(req)
	if (req_error != 0):
		http_stream_fail(s, req_error)
		return s
	url* u = url_parse(req.url)
	if (u == 0):
		http_stream_fail(s, http_error_bad_url())
		return s
	int url_error = http_validate_url(u)
	if (url_error != 0):
		url_free(u)
		http_stream_fail(s, url_error)
		return s
	char* method = req.method
	int include_body = 1
	int redirects = 0
	int done = 0
	while (done == 0):
		if (http_open_single(s, req, u, method, include_body) == 0):
			done = 1
		else if (http_status_is_redirect(s.resp.status) == 0):
			done = 1
		else if (req.max_redirects <= 0):
			done = 1
		else:
			char* location = http_response_header(s.resp, c"location")
			if (location == 0):
				done = 1
			else:
				redirects = redirects + 1
				if (redirects > req.max_redirects):
					http_stream_fail(s, http_error_too_many_redirects())
					done = 1
				else:
					url* next = http_redirect_target(u, location)
					if (next == 0):
						http_stream_fail(s, http_error_bad_url())
						done = 1
					else:
						int next_error = http_validate_url(next)
						if (next_error != 0):
							url_free(next)
							http_stream_fail(s, next_error)
							done = 1
						else:
							if (s.resp.status == 303):
								# 303 See Other: switch to GET, drop the body.
								method = c"GET"
								include_body = 0
							http_stream_redirect_reset(s)
							url_free(u)
							u = next
	url_free(u)
	return s


/* Buffered convenience API */

# Performs the request and buffers the whole body. Never returns 0;
# check resp.error. On a mid-body failure resp.error is set and
# resp.body holds the bytes received so far. resp.body is always
# non-null and NUL-terminated.
http_response* http_request(http_req* req):
	http_stream* s = http_open(req)
	http_response* resp = s.resp
	if (s.error == 0):
		string_builder* body = string_new()
		char* scratch = malloc(8192)
		int more = 1
		while (more != 0):
			int got = http_stream_read(s, scratch, 8192)
			if (got <= 0):
				more = 0
			else if (body.length + got > http_max_body_bytes()):
				http_stream_fail(s, http_error_body_too_large())
				more = 0
			else:
				string_append_bytes(body, scratch, got)
		free(scratch)
		resp.body = body.data
		resp.body_len = body.length
		free(body)
	if (resp.body == 0):
		resp.body = strclone(c"")
		resp.body_len = 0
	s.resp = 0
	http_stream_close(s)
	return resp


# GET with default timeout and redirect handling. Never returns 0.
http_response* http_get(char* target):
	http_req* req = http_req_new(c"GET", target)
	http_response* resp = http_request(req)
	http_req_free(req)
	return resp
