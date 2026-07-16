# Base HTTP/1.1 server (issue #235, phase 2 of the http_server framework
# plan 08 phase 3 mentions). Layers a ServerContext (bind/listen/accept
# loop, request parsing, a minimal response writer) over
# libs/standard/web/connection.w's ConnectionContext, composing
# libs/standard/net/tls.w's tls_accept for https:// exactly the way
# examples/web/https_server.w's raw-socket demo did by hand -- one
# accept loop, one request-parsing/response-writing code path, serving
# both http and https depending only on whether ServerContext was given
# a cert/key.
#
# Concurrency: v1 is single-threaded sequential accept -- one connection
# is fully served (including every keep-alive request on it) before the
# next is accepted. lib/thread.w's kernel threads exist but forbid
# allocation in worker functions (MVP constraint, see its module doc),
# which rules out a plain thread-per-connection model without a bigger
# redesign; lib/event_loop.w's poll(2) loop could drive a concurrent,
# non-blocking version of this accept loop, but that needs the request
# parser and handler contract to become resumable (callback/coroutine
# style) instead of the straight-line blocking code below. Neither is
# in scope here -- see docs/projects/ for a future concurrency phase.
#
# Request parsing mirrors http_client.w's response parser (issue #200)
# wherever the shapes line up: header lines share http_store_header_into,
# Content-Length parsing reuses http_parse_content_length, chunked
# bodies reuse http_parse_chunk_size, and the http_header struct backs
# ServerResponse's header list. Requests are read here as one already-
# parsed value (method, target, path, query, headers, a fully buffered
# body) -- there is no streaming request body reader in this phase.
#
# Phase 3 seam (NOT built here -- see issue #235's remaining phases):
# a RequestContext wrapping ServerRequest with set_status/set_header/
# write_body/streaming methods, handler registration/routing, and
# migrating examples/web/https_server.w onto this framework. The seam
# this phase leaves is: ServerContext.handler is a plain
# server_handler_fn* that takes a ServerRequest* and returns a
# ServerResponse*; RequestContext can wrap that same pair (or replace
# server_write_response with incremental ConnectionContext writes for
# streaming) without changing ConnectionContext, the accept loop, or
# request parsing.
#
# NAMING: ServerContext, ServerRequest, and ServerResponse are
# PascalCase, matching ConnectionContext (libs/standard/web/connection.w)
# and URL (libs/standard/web/urlparse.w) -- see connection.w's module
# doc for the full rationale. server_handler_fn, like the codebase's
# other function-pointer typedefs (lib/event_loop.w's event_fd_cb,
# lib/json_rpc.w's jsonrpc_handler, lib/thread.w's thread_fn), stays
# snake_case: the PascalCase convention marks struct *types* in this
# framework's public surface, not callback aliases. All function names
# stay snake_case throughout, as everywhere else in the codebase.
#
# Public API:
#   type server_handler_fn = fn(ServerRequest*, void*) -> ServerResponse*
#
#   ServerContext* server_context_new(char* bind_ip, int port, server_handler_fn* handler, void* handler_context)
#   void server_context_set_tls(ServerContext* s, char* cert_path, char* key_path)
#   int server_context_bind(ServerContext* s)          0 on failure (s.error set)
#   int server_context_port(ServerContext* s)           the bound port (for port 0 binds)
#   int server_context_accept_loop(ServerContext* s, int max_connections)  connections served
#   void server_context_close(ServerContext* s)
#   void server_context_free(ServerContext* s)
#
#   char* server_request_header(ServerRequest* req, char* name)
#   int server_request_wants_keep_alive(ServerRequest* req)
#
#   ServerResponse* server_response_new(int status)
#   void server_response_add_header(ServerResponse* resp, char* name, char* value)
#   void server_response_set_body(ServerResponse* resp, char* body, int body_len)
#   void server_response_set_text(ServerResponse* resp, char* text)
#   void server_response_free(ServerResponse* resp)
#
#   int server_error_*()  /  char* server_error_string(int code)  /  int server_error_to_status(int code)
import lib.lib
import lib.str
import lib.net
import lib.container
import structures.string
import libs.standard.web.connection
import libs.standard.web.http_client
import libs.standard.net.tls


# One parsed request. target is the raw request-target off the request
# line ("/path?query", "*", or an absolute-form URL for a proxy request
# -- this server does not resolve absolute-form specially, it is kept
# verbatim in target/path); path/query are only meaningful when target
# begins with '/' (origin-form), which is what every test and the
# examples use. headers maps lowercased names to values (duplicates
# joined with ", ", exactly like http_response.headers). body is
# malloc'd and NUL-terminated (body_len excludes the terminator), "" /
# 0 when the request has no body. error is a server_error_* code, 0 on
# a cleanly parsed request.
struct ServerRequest:
	char* method
	char* target
	char* path
	char* query
	int http_minor
	map[char*, char*] headers
	char* body
	int body_len
	int error


# A handler's response: status, headers (name/value pairs, appended in
# order), and a fully buffered body. server_write_response adds
# Content-Length and Connection headers when the handler did not supply
# its own.
struct ServerResponse:
	int status
	list[http_header*] headers
	char* body
	int body_len


# request, handler_context -> response (never 0; a handler that cannot
# produce a real response should still return e.g. server_response_new(500)).
type server_handler_fn = fn(ServerRequest*, void*) -> ServerResponse*


# Server-wide config and listener state. bind_ip/port/backlog/timeout_ms
# and handler/handler_context are set by server_context_new; cert_path/
# key_path (set via server_context_set_tls) switch server_context_bind
# to also build a tls_server_config, and every accepted connection then
# completes tls_accept before requests are parsed -- one accept loop,
# one request-parsing/response-writing path serves both transports.
struct ServerContext:
	char* bind_ip
	int port
	int backlog
	int timeout_ms
	char* cert_path
	char* key_path
	int is_tls
	server_handler_fn* handler
	void* handler_context
	int listener_fd
	tls_server_config* tls_cfg
	int error


int server_default_timeout_ms():
	return 30000


int server_default_backlog():
	return 16


/* Error codes. Deliberately disjoint from connection.w's
   connection_error_* range (0-3): server_read_request/server_read_headers
   translate a ConnectionContext failure into one of these, and also pass
   headers_too_large/bad_chunk straight through to
   connection_context_read_line's oversize_error parameter, so the two
   small enums must never collide on a shared value. */

int server_error_none():
	return 0


int server_error_bind():
	return 100


int server_error_timeout():
	return 101


int server_error_bad_request():
	return 102


int server_error_headers_too_large():
	return 103


int server_error_body_too_large():
	return 104


int server_error_bad_chunk():
	return 105


int server_error_not_implemented():
	return 106


int server_error_tls():
	return 107


char* server_error_string(int code):
	if (code == server_error_none()):
		return c""
	if (code == server_error_bind()):
		return c"bind/listen failed"
	if (code == server_error_timeout()):
		return c"timed out"
	if (code == server_error_bad_request()):
		return c"malformed request"
	if (code == server_error_headers_too_large()):
		return c"request headers too large"
	if (code == server_error_body_too_large()):
		return c"request body too large"
	if (code == server_error_bad_chunk()):
		return c"malformed chunked body"
	if (code == server_error_not_implemented()):
		return c"unsupported transfer-encoding"
	if (code == server_error_tls()):
		return c"TLS handshake failed"
	return c"unknown error"


# HTTP status this server writes back for a request-level failure.
int server_error_to_status(int code):
	if (code == server_error_timeout()):
		return 408
	if (code == server_error_headers_too_large()):
		return 431
	if (code == server_error_body_too_large()):
		return 413
	if (code == server_error_not_implemented()):
		return 501
	return 400


/* Status reason phrases (advisory only -- http_client.w's
   http_parse_status_line does not inspect them beyond the space that
   follows the 3-digit code). Covers the codes this framework and its
   handlers are likely to use; anything else falls back to its class. */

char* server_status_text(int status):
	if (status == 200):
		return c"OK"
	if (status == 201):
		return c"Created"
	if (status == 204):
		return c"No Content"
	if (status == 301):
		return c"Moved Permanently"
	if (status == 302):
		return c"Found"
	if (status == 304):
		return c"Not Modified"
	if (status == 400):
		return c"Bad Request"
	if (status == 404):
		return c"Not Found"
	if (status == 405):
		return c"Method Not Allowed"
	if (status == 408):
		return c"Request Timeout"
	if (status == 411):
		return c"Length Required"
	if (status == 413):
		return c"Payload Too Large"
	if (status == 431):
		return c"Request Header Fields Too Large"
	if (status == 500):
		return c"Internal Server Error"
	if (status == 501):
		return c"Not Implemented"
	if (status == 503):
		return c"Service Unavailable"
	if (status < 300):
		return c"OK"
	if (status < 400):
		return c"Redirect"
	if (status < 500):
		return c"Error"
	return c"Server Error"


/* ServerRequest */

ServerRequest* server_request_new():
	ServerRequest* req = new ServerRequest()
	req.method = 0
	req.target = 0
	req.path = 0
	req.query = 0
	req.http_minor = 1
	req.headers = new map[char*, char*]
	req.body = strclone(c"")
	req.body_len = 0
	req.error = 0
	return req


void server_request_free(ServerRequest* req):
	if (req == 0):
		return
	if (req.method != 0):
		free(req.method)
	if (req.target != 0):
		free(req.target)
	if (req.path != 0):
		free(req.path)
	if (req.query != 0):
		free(req.query)
	list[char*] keys = req.headers.keys()
	for char* key in keys:
		char* value = req.headers[key]
		free(value)
	list_free[char*](keys)
	map_free[char*, char*](req.headers)
	if (req.body != 0):
		free(req.body)
	free(req)


# Case-insensitive header lookup. Returns the stored value (owned by
# the request; do not free) or 0 when absent.
char* server_request_header(ServerRequest* req, char* name):
	if (req == 0):
		return 0
	char* lower = strclone(name)
	int i = 0
	while (lower[i] != 0):
		lower[i] = http_lower_char(lower[i] & 255)
		i = i + 1
	char* value = req.headers.get(lower, 0)
	free(lower)
	return value


# Whether the client's request allows the connection to stay open after
# the response (RFC 9112 9.3, mirroring http_client.w's
# http_response_keep_alive on the request side): HTTP/1.1 defaults to
# keep-alive unless "Connection: close" is present; HTTP/1.0 defaults to
# close unless "Connection: keep-alive" is present.
int server_request_wants_keep_alive(ServerRequest* req):
	char* connection = server_request_header(req, c"connection")
	if (req.http_minor >= 1):
		if (connection == 0):
			return 1
		if (http_value_has_token(connection, c"close") != 0):
			return 0
		return 1
	if (connection == 0):
		return 0
	return http_value_has_token(connection, c"keep-alive")


/* ServerResponse */

ServerResponse* server_response_new(int status):
	ServerResponse* resp = new ServerResponse()
	resp.status = status
	resp.headers = new list[http_header*]
	resp.body = 0
	resp.body_len = 0
	return resp


# Appends a response header; name and value are copied.
void server_response_add_header(ServerResponse* resp, char* name, char* value):
	http_header* h = new http_header()
	h.name = strclone(name)
	h.value = strclone(value)
	resp.headers.push(h)


char* server_response_get_header(ServerResponse* resp, char* name):
	for http_header* h in resp.headers:
		if (http_str_ieq(h.name, name) != 0):
			return h.value
	return 0


# Copies body_len bytes from body (which the caller keeps ownership of
# and may free or reuse immediately afterwards).
void server_response_set_body(ServerResponse* resp, char* body, int body_len):
	if (resp.body != 0):
		free(resp.body)
	if (body_len <= 0):
		resp.body = strclone(c"")
		resp.body_len = 0
		return
	char* copy = malloc(body_len + 1)
	int i = 0
	while (i < body_len):
		copy[i] = body[i]
		i = i + 1
	copy[body_len] = 0
	resp.body = copy
	resp.body_len = body_len


void server_response_set_text(ServerResponse* resp, char* text):
	server_response_set_body(resp, text, strlen(text))


void server_response_free(ServerResponse* resp):
	if (resp == 0):
		return
	for http_header* h in resp.headers:
		free(h.name)
		free(h.value)
		free(h)
	list_free[http_header*](resp.headers)
	if (resp.body != 0):
		free(resp.body)
	free(resp)


/* Request-line + header + body parsing */

# "METHOD SP target SP HTTP/1.<0|1>", one space exactly between each
# part (RFC 9112 3). Fills req.method/target/http_minor. Returns 1/0.
int server_parse_request_line(char* line, ServerRequest* req):
	int i = 0
	while ((line[i] != 0) & (line[i] != ' ')):
		i = i + 1
	if ((line[i] != ' ') | (i == 0)):
		return 0
	char* method = substring(line, 0, i)
	int target_start = i + 1
	i = target_start
	while ((line[i] != 0) & (line[i] != ' ')):
		i = i + 1
	if ((line[i] != ' ') | (i == target_start)):
		free(method)
		return 0
	char* target = substring(line, target_start, i)
	char* version = line + i + 1
	if (http_is_token(method) == 0):
		free(method)
		free(target)
		return 0
	if (http_url_part_clean(target) == 0):
		free(method)
		free(target)
		return 0
	int minor = 0
	if (strcmp(version, c"HTTP/1.1") == 0):
		minor = 1
	else if (strcmp(version, c"HTTP/1.0") == 0):
		minor = 0
	else:
		free(method)
		free(target)
		return 0
	req.method = method
	req.target = target
	req.http_minor = minor
	return 1


# Splits req.target into req.path/req.query at the first '?', for
# origin-form targets ("/path?query"); a target that does not start
# with '/' (asterisk-form "*", or an absolute-form proxy target) is
# kept whole as path with an empty query.
void server_split_target(ServerRequest* req):
	char* target = req.target
	if (target[0] != '/'):
		req.path = strclone(target)
		req.query = strclone(c"")
		return
	int i = 0
	while ((target[i] != 0) & (target[i] != '?')):
		i = i + 1
	req.path = substring(target, 0, i)
	if (target[i] == '?'):
		req.query = strclone(target + i + 1)
	else:
		req.query = strclone(c"")


# Translates a ConnectionContext-level read failure (from
# connection_context_read_line/read/read_exact) into a server_error_*
# code and stores it on req. Handles the three connection_error_* values
# read/fill can set, plus a server_error_* value already passed straight
# through via read_line's oversize_error parameter (headers_too_large,
# bad_chunk), and a clean mid-line EOF (c.error == 0).
void server_note_read_failure(ConnectionContext* c, ServerRequest* req):
	if (c.error == connection_error_timeout()):
		req.error = server_error_timeout()
	else if (c.error == server_error_headers_too_large()):
		req.error = server_error_headers_too_large()
	else if (c.error == server_error_bad_chunk()):
		req.error = server_error_bad_chunk()
	else:
		req.error = server_error_bad_request()


# Reads header lines up to the blank terminator line into req.headers,
# bounded by http_max_header_bytes() total (mirrors http_client.w's
# http_read_head inner loop). Returns 1, or 0 with req.error set.
int server_read_headers(ConnectionContext* c, ServerRequest* req):
	string_builder* line = string_new()
	int total = 0
	int in_block = 1
	int ok = 1
	while (in_block != 0):
		int got = connection_context_read_line(c, line, server_error_headers_too_large())
		if (got <= 0):
			server_note_read_failure(c, req)
			ok = 0
			in_block = 0
		else if (line.length == 0):
			in_block = 0
		else:
			total = total + line.length + 2
			if (total > http_max_header_bytes()):
				req.error = server_error_headers_too_large()
				ok = 0
				in_block = 0
			else if (http_store_header_into(req.headers, line.data, line.length) == 0):
				req.error = server_error_bad_request()
				ok = 0
				in_block = 0
	string_free(line)
	return ok


# Consumes trailer lines after a chunked body's terminal 0-size chunk.
# Contents are discarded but stay bounded. Returns 1, or 0 on failure.
int server_consume_trailers(ConnectionContext* c, ServerRequest* req):
	string_builder* line = string_new()
	int total = 0
	while (1):
		int got = connection_context_read_line(c, line, server_error_headers_too_large())
		if (got <= 0):
			server_note_read_failure(c, req)
			string_free(line)
			return 0
		if (line.length == 0):
			string_free(line)
			return 1
		total = total + line.length + 2
		if (total > http_max_header_bytes()):
			req.error = server_error_headers_too_large()
			string_free(line)
			return 0
	return 0


# Reads a chunked request body (RFC 9112 7.1) into out, bounded by
# http_max_body_bytes() total. Chunk-size parsing reuses http_client.w's
# http_parse_chunk_size. Returns 1, or 0 with req.error set.
int server_read_chunked_body(ConnectionContext* c, ServerRequest* req, string_builder* out):
	int chunk_first = 1
	int total = 0
	while (1):
		if (chunk_first == 0):
			if (connection_context_expect_crlf(c) == 0):
				if (c.error != 0):
					server_note_read_failure(c, req)
				else:
					req.error = server_error_bad_chunk()
				return 0
		chunk_first = 0
		string_builder* line = string_new()
		int got = connection_context_read_line(c, line, server_error_bad_chunk())
		if (got <= 0):
			server_note_read_failure(c, req)
			string_free(line)
			return 0
		int size = http_parse_chunk_size(line.data)
		string_free(line)
		if (size < 0):
			req.error = server_error_bad_chunk()
			return 0
		if (size == 0):
			return server_consume_trailers(c, req)
		total = total + size
		if (total > http_max_body_bytes()):
			req.error = server_error_body_too_large()
			return 0
		char* buf = malloc(size)
		int ok = connection_context_read_exact(c, buf, size)
		if (ok != 0):
			string_append_bytes(out, buf, size)
		free(buf)
		if (ok == 0):
			server_note_read_failure(c, req)
			return 0
	return 0


# Reads exactly length bytes of a Content-Length-delimited body into out.
# Returns 1, or 0 with req.error set.
int server_read_length_body(ConnectionContext* c, ServerRequest* req, string_builder* out, int length):
	char* buf = malloc(length)
	int ok = connection_context_read_exact(c, buf, length)
	if (ok != 0):
		string_append_bytes(out, buf, length)
	free(buf)
	if (ok == 0):
		server_note_read_failure(c, req)
	return ok


# Reads one full request off c: the request-line, headers, and (per
# Content-Length or "Transfer-Encoding: chunked") a fully buffered body.
# Returns 0 only for a clean idle close between requests (no bytes at
# all for a new request-line -- the normal end of a keep-alive
# connection); otherwise always returns a ServerRequest, with .error set
# to a server_error_* code on any parse/transport failure.
ServerRequest* server_read_request(ConnectionContext* c):
	string_builder* line = string_new()
	int got = connection_context_read_line(c, line, server_error_headers_too_large())
	if (got == 0):
		string_free(line)
		return 0
	ServerRequest* req = server_request_new()
	if (got < 0):
		server_note_read_failure(c, req)
		string_free(line)
		return req
	if (server_parse_request_line(line.data, req) == 0):
		string_free(line)
		req.error = server_error_bad_request()
		return req
	string_free(line)
	server_split_target(req)
	if (server_read_headers(c, req) == 0):
		return req
	if (req.http_minor >= 1):
		# RFC 9112 3.2: an HTTP/1.1 request must carry exactly one Host
		# header; http_store_header_into already joins duplicates with
		# ", " so a duplicate Host still fails downstream (as an invalid
		# authority) rather than silently picking one.
		if (server_request_header(req, c"host") == 0):
			req.error = server_error_bad_request()
			return req
	char* te = server_request_header(req, c"transfer-encoding")
	char* cl = server_request_header(req, c"content-length")
	if ((te != 0) & (cl != 0)):
		# Ambiguous framing (RFC 9112 6.3 request smuggling hardening):
		# fail closed rather than guess which header the peer meant.
		req.error = server_error_bad_request()
		return req
	if (te != 0):
		char* trimmed = http_trimmed_value(te, 0, strlen(te))
		int is_chunked = http_str_ieq(trimmed, c"chunked")
		free(trimmed)
		if (is_chunked == 0):
			req.error = server_error_not_implemented()
			return req
		string_builder* body = string_new()
		if (server_read_chunked_body(c, req, body) == 0):
			string_free(body)
			return req
		req.body = body.data
		req.body_len = body.length
		free(body)
	else if (cl != 0):
		int length = http_parse_content_length(cl)
		if (length < 0):
			req.error = server_error_bad_request()
			return req
		if (length > 0):
			string_builder* body = string_new()
			if (server_read_length_body(c, req, body, length) == 0):
				string_free(body)
				return req
			req.body = body.data
			req.body_len = body.length
			free(body)
	c.keep_alive = server_request_wants_keep_alive(req)
	return req


/* Response writing */

# Writes the status line, headers (adding Content-Length and Connection
# when the handler did not supply its own), and body. Mirrors
# http_client.w's http_send_request. Returns 1, or 0 with c.error set.
int server_write_response(ConnectionContext* c, ServerResponse* resp, int keep_alive):
	string_builder* out = string_new()
	string_append(out, c"HTTP/1.1 ")
	char* status_text = itoa(resp.status)
	string_append(out, status_text)
	free(status_text)
	string_append_char(out, ' ')
	string_append(out, server_status_text(resp.status))
	string_append(out, c"\x0d\x0a")
	int user_connection = 0
	int user_content_length = 0
	for http_header* h in resp.headers:
		string_append(out, h.name)
		string_append(out, c": ")
		string_append(out, h.value)
		string_append(out, c"\x0d\x0a")
		if (http_str_ieq(h.name, c"connection") != 0):
			user_connection = 1
		if (http_str_ieq(h.name, c"content-length") != 0):
			user_content_length = 1
	int body_len = 0
	if (resp.body != 0):
		body_len = resp.body_len
	if (user_content_length == 0):
		string_append(out, c"Content-Length: ")
		char* len_text = itoa(body_len)
		string_append(out, len_text)
		free(len_text)
		string_append(out, c"\x0d\x0a")
	if (user_connection == 0):
		if (keep_alive != 0):
			string_append(out, c"Connection: keep-alive\x0d\x0a")
		else:
			string_append(out, c"Connection: close\x0d\x0a")
	string_append(out, c"\x0d\x0a")
	if (body_len > 0):
		string_append_bytes(out, resp.body, body_len)
	int ok = connection_context_write_all(c, out.data, out.length)
	string_free(out)
	return ok


# Best-effort error response for a request that failed to parse (the
# connection is always closed afterwards -- a peer that sent a
# malformed request cannot be trusted to still be framing correctly).
void server_write_error(ConnectionContext* c, int error_code):
	int status = server_error_to_status(error_code)
	ServerResponse* resp = server_response_new(status)
	server_response_set_text(resp, server_status_text(status))
	server_response_add_header(resp, c"Content-Type", c"text/plain")
	server_write_response(c, resp, 0)
	server_response_free(resp)


/* ServerContext */

ServerContext* server_context_new(char* bind_ip, int port, server_handler_fn* handler, void* handler_context):
	ServerContext* s = new ServerContext()
	s.bind_ip = bind_ip
	s.port = port
	s.backlog = server_default_backlog()
	s.timeout_ms = server_default_timeout_ms()
	s.cert_path = 0
	s.key_path = 0
	s.is_tls = 0
	s.handler = handler
	s.handler_context = handler_context
	s.listener_fd = (-1)
	s.tls_cfg = 0
	s.error = 0
	return s


# Enables https: cert_path/key_path are borrowed (like http_req's TLS
# knobs), and server_context_bind builds a tls_server_config from them.
void server_context_set_tls(ServerContext* s, char* cert_path, char* key_path):
	s.cert_path = cert_path
	s.key_path = key_path
	s.is_tls = 1


int server_context_bind(ServerContext* s):
	int listener = socket_tcp_ipv4()
	if (listener < 0):
		s.error = server_error_bind()
		return 0
	socket_set_reuseaddr(listener)
	if (socket_bind_ipv4(listener, ip4_from_string(s.bind_ip), s.port) < 0):
		close(listener)
		s.error = server_error_bind()
		return 0
	if (socket_listen(listener, s.backlog) < 0):
		close(listener)
		s.error = server_error_bind()
		return 0
	s.listener_fd = listener
	if (s.is_tls != 0):
		tls_server_config* cfg = tls_server_config_new()
		cfg.cert_chain_path = s.cert_path
		cfg.key_path = s.key_path
		s.tls_cfg = cfg
	return 1


# The bound port -- useful after binding to port 0 for a kernel-assigned
# ephemeral port, the loopback-test idiom (libs/standard/web/https_e2e_test.w's
# hs_listen).
int server_context_port(ServerContext* s):
	sockaddr_in bound
	if (socket_getsockname_ipv4(s.listener_fd, &bound) < 0):
		return 0
	return net_htons(bound.port)


void server_context_close(ServerContext* s):
	if (s.listener_fd >= 0):
		close(s.listener_fd)
		s.listener_fd = (-1)
	if (s.tls_cfg != 0):
		tls_server_config_free(s.tls_cfg)
		s.tls_cfg = 0


void server_context_free(ServerContext* s):
	server_context_close(s)
	free(s)


# Serves every request on one accepted connection sequentially,
# looping while both the request and the response agree the connection
# stays open, until a request fails to parse, a response fails to
# write, or the peer closes (server_read_request returns 0).
void server_serve_connection(ServerContext* s, ConnectionContext* c):
	int done = 0
	while (done == 0):
		ServerRequest* req = server_read_request(c)
		if (req == 0):
			done = 1
		else if (req.error != 0):
			server_write_error(c, req.error)
			server_request_free(req)
			done = 1
		else:
			ServerResponse* resp = s.handler(req, s.handler_context)
			int keep = c.keep_alive
			if (resp == 0):
				resp = server_response_new(500)
				keep = 0
			else if (server_response_get_header(resp, c"connection") != 0):
				if (http_value_has_token(server_response_get_header(resp, c"connection"), c"close") != 0):
					keep = 0
			if (server_write_response(c, resp, keep) == 0):
				done = 1
			server_response_free(resp)
			server_request_free(req)
			if (keep == 0):
				done = 1
	connection_context_destroy(c)


# Accepts and serves connections sequentially (see the module doc's
# concurrency note). max_connections <= 0 runs forever; a positive count
# stops after that many ACCEPTED connections (each may carry more than
# one request under keep-alive) -- how the loopback tests bound the
# server child without a second control channel. Returns the number of
# connections accepted.
int server_context_accept_loop(ServerContext* s, int max_connections):
	int served = 0
	while ((max_connections <= 0) | (served < max_connections)):
		sockaddr_in peer
		int conn = socket_accept_connection_from(s.listener_fd, &peer)
		if (conn < 0):
			return served
		socket_set_recv_timeout(conn, s.timeout_ms)
		socket_set_send_timeout(conn, s.timeout_ms)
		tls_conn* tls = 0
		if (s.is_tls != 0):
			tls = tls_accept(conn, s.tls_cfg)
			if (tls == 0):
				close(conn)
				served = served + 1
				continue
		ConnectionContext* c = connection_context_new(conn, s.timeout_ms, tls)
		connection_context_set_peer(c, net_htonl(peer.ip_address), net_htons(peer.port))
		server_serve_connection(s, c)
		served = served + 1
	return served
