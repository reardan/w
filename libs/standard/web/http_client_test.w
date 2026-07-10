# wbuild: x64
# Offline tests for libs/standard/web/http_client.w (issue #200).
# Every network test runs against a forked pure-W HTTP fixture server
# on a loopback ephemeral port (the libs/standard/net/dns_test.w
# pattern): the parent binds the listener before forking so it knows
# the port, the child scripts one server behavior, and the parent
# drives the client and asserts. Hardening tests need no server at
# all - validation fails before any I/O.
import lib.testing
import lib.net
import lib.time
import structures.string
import libs.standard.web.http_client
import libs.standard.web.urlparse


void http_client_test_assert_ok(char* name, int result):
	if (result < 0):
		print_string(name, c" failed")
		translate_syscall_failure(result)
		exit(1)


/* Fixture server helpers (reusable server bits) */

# Listener on 127.0.0.1 with a kernel-assigned port.
int http_test_listen(int* out_port):
	int listener = socket_tcp_ipv4()
	http_client_test_assert_ok(c"tcp socket", listener)
	http_client_test_assert_ok(c"reuseaddr", socket_set_reuseaddr(listener))
	http_client_test_assert_ok(c"bind", socket_bind_ipv4(listener, ip4_from_string(c"127.0.0.1"), 0))
	http_client_test_assert_ok(c"listen", socket_listen(listener, 8))
	sockaddr_in bound
	http_client_test_assert_ok(c"getsockname", socket_getsockname_ipv4(listener, &bound))
	*out_port = net_htons(bound.port)
	return listener


char* http_test_url(int port, char* path):
	string_builder* out = string_new()
	string_append(out, c"http://127.0.0.1:")
	string_append_int(out, port)
	string_append(out, path)
	char* text = out.data
	free(out)
	return text


int http_test_contains(char* hay, char* needle):
	int i = 0
	while (hay[i] != 0):
		int j = 0
		while ((needle[j] != 0) & (hay[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		i = i + 1
	return 0


# One parsed request as seen by the fixture server child.
struct http_test_request:
	char* head
	char* method
	char* path
	char* body
	int body_len


void http_test_request_free(http_test_request* q):
	free(q.head)
	free(q.method)
	free(q.path)
	free(q.body)


int http_test_find_head_end(char* buf, int total):
	int i = 0
	while (i + 3 < total):
		if ((buf[i] == 13) & (buf[i + 1] == 10) & (buf[i + 2] == 13) & (buf[i + 3] == 10)):
			return i + 4
		i = i + 1
	return (-1)


int http_test_prefix_ieq(char* text, int at, char* prefix):
	int j = 0
	while (prefix[j] != 0):
		if (text[at + j] == 0):
			return 0
		if (http_lower_char(text[at + j] & 255) != http_lower_char(prefix[j] & 255)):
			return 0
		j = j + 1
	return 1


# Content-Length announced in a request head, or 0.
int http_test_content_length(char* head):
	int i = 0
	while (head[i] != 0):
		if (http_test_prefix_ieq(head, i, c"content-length:") != 0):
			int k = i + 15
			while (head[k] == ' '):
				k = k + 1
			return atoi(head + k)
		while ((head[i] != 0) & (head[i] != 10)):
			i = i + 1
		if (head[i] == 10):
			i = i + 1
	return 0


# Reads one request (head + Content-Length body) from a blocking
# connection. Returns 1, or 0 on EOF/overflow.
int http_test_read_request(int conn, http_test_request* q):
	int cap = 16384
	char* buf = malloc(cap + 1)
	int total = 0
	int head_end = (-1)
	while (head_end < 0):
		if (total >= cap):
			free(buf)
			return 0
		int got = read(conn, buf + total, cap - total)
		if (got <= 0):
			free(buf)
			return 0
		total = total + got
		head_end = http_test_find_head_end(buf, total)
	buf[total] = 0

	int sp1 = 0
	while ((buf[sp1] != ' ') & (buf[sp1] != 13) & (buf[sp1] != 0)):
		sp1 = sp1 + 1
	if (buf[sp1] != ' '):
		free(buf)
		return 0
	int sp2 = sp1 + 1
	while ((buf[sp2] != ' ') & (buf[sp2] != 13) & (buf[sp2] != 0)):
		sp2 = sp2 + 1
	if (buf[sp2] != ' '):
		free(buf)
		return 0
	q.head = substring(buf, 0, head_end)
	q.method = substring(buf, 0, sp1)
	q.path = substring(buf, sp1 + 1, sp2)

	int content_length = http_test_content_length(q.head)
	if ((content_length < 0) | (content_length > cap)):
		free(q.head)
		free(q.method)
		free(q.path)
		free(buf)
		return 0
	q.body = malloc(content_length + 1)
	int have = total - head_end
	if (have > content_length):
		have = content_length
	int i = 0
	while (i < have):
		q.body[i] = buf[head_end + i]
		i = i + 1
	free(buf)
	while (have < content_length):
		int more = read(conn, q.body + have, content_length - have)
		if (more <= 0):
			free(q.head)
			free(q.method)
			free(q.path)
			free(q.body)
			return 0
		have = have + more
	q.body[content_length] = 0
	q.body_len = content_length
	return 1


# Sends every byte, SIGPIPE-proof: an early client close (the
# fail-closed tests) must not kill the fixture child.
void http_test_send_all(int conn, char* data, int n):
	int total = 0
	while (total < n):
		int got = socket_send(conn, data + total, n - total, msg_nosignal())
		if (got <= 0):
			return
		total = total + got


void http_test_send_text(int conn, char* text):
	http_test_send_all(conn, text, strlen(text))


# Well-formed Content-Length response. extra_headers (0 for none) must
# be complete "Name: value\r\n" lines.
void http_test_respond(int conn, int status, char* extra_headers, char* body):
	string_builder* out = string_new()
	string_append(out, c"HTTP/1.1 ")
	string_append_int(out, status)
	string_append(out, c" OK\x0d\x0a")
	if (extra_headers != 0):
		string_append(out, extra_headers)
	string_append(out, c"Content-Length: ")
	string_append_int(out, strlen(body))
	string_append(out, c"\x0d\x0a\x0d\x0a")
	string_append(out, body)
	http_test_send_all(conn, out.data, out.length)
	string_free(out)


# Reads until the peer closes, so the child never exits while the
# client still expects the connection to be open.
void http_test_drain(int conn):
	char* scratch = malloc(1024)
	int got = read(conn, scratch, 1024)
	while (got > 0):
		got = read(conn, scratch, 1024)
	free(scratch)


void http_test_finish(int pid, int listener):
	# Drop the cached keep-alive connection first: children that serve
	# until EOF exit only once the client side is really closed.
	http_client_close_idle()
	int status = 0
	wait4(pid, &status, 0, 0)
	close(listener)


/* Wire-free unit coverage of the parsing helpers */

void test_http_parse_status_line():
	int status = 0
	int minor = 9
	assert_equal(1, http_parse_status_line(c"HTTP/1.1 200 OK", &status, &minor))
	assert_equal(200, status)
	assert_equal(1, minor)
	assert_equal(1, http_parse_status_line(c"HTTP/1.0 404 Not Found", &status, &minor))
	assert_equal(404, status)
	assert_equal(0, minor)
	assert_equal(1, http_parse_status_line(c"HTTP/1.1 301", &status, &minor))
	assert_equal(301, status)
	asserts(c"garbage accepted", http_parse_status_line(c"BANANA", &status, &minor) == 0)
	asserts(c"HTTP/2 accepted", http_parse_status_line(c"HTTP/2 200 OK", &status, &minor) == 0)
	asserts(c"2-digit status accepted", http_parse_status_line(c"HTTP/1.1 20 OK", &status, &minor) == 0)
	asserts(c"4-digit status accepted", http_parse_status_line(c"HTTP/1.1 2000 OK", &status, &minor) == 0)
	asserts(c"status 099 accepted", http_parse_status_line(c"HTTP/1.1 099 X", &status, &minor) == 0)
	asserts(c"glued status accepted", http_parse_status_line(c"HTTP/1.1 200OK", &status, &minor) == 0)


void test_http_parse_content_length():
	assert_equal(0, http_parse_content_length(c"0"))
	assert_equal(1234, http_parse_content_length(c"1234"))
	assert_equal((-1), http_parse_content_length(c""))
	assert_equal((-1), http_parse_content_length(c"12a"))
	assert_equal((-1), http_parse_content_length(c"-5"))
	# Joined duplicates ("10, 10") and overflows fail closed.
	assert_equal((-1), http_parse_content_length(c"10, 10"))
	assert_equal((-1), http_parse_content_length(c"99999999999"))


void test_http_parse_chunk_size():
	assert_equal(26, http_parse_chunk_size(c"1a"))
	assert_equal(26, http_parse_chunk_size(c"1A;ext=1"))
	assert_equal(0, http_parse_chunk_size(c"0"))
	assert_equal(255, http_parse_chunk_size(c"ff "))
	assert_equal((-1), http_parse_chunk_size(c""))
	assert_equal((-1), http_parse_chunk_size(c"zz"))
	assert_equal((-1), http_parse_chunk_size(c"1a1a1a1a1a"))
	# One over the 8 MB chunk cap.
	assert_equal(8388608, http_parse_chunk_size(c"800000"))
	assert_equal((-1), http_parse_chunk_size(c"800001"))


void test_http_value_has_token():
	assert_equal(1, http_value_has_token(c"close", c"close"))
	assert_equal(1, http_value_has_token(c"keep-alive, Upgrade", c"upgrade"))
	assert_equal(1, http_value_has_token(c"Keep-Alive", c"keep-alive"))
	assert_equal(0, http_value_has_token(c"keep-alive", c"close"))
	assert_equal(0, http_value_has_token(c"closed", c"close"))
	assert_equal(0, http_value_has_token(c"", c"close"))


void test_http_error_strings():
	assert_strings_equal(c"", http_error_string(http_error_none()))
	assert_strings_equal(c"timed out", http_error_string(http_error_timeout()))
	assert_strings_equal(c"too many redirects", http_error_string(http_error_too_many_redirects()))
	assert_strings_equal(c"TLS handshake failed", http_error_string(http_error_tls()))
	assert_strings_equal(c"unknown error", http_error_string(999))


/* Request hardening: rejected before any socket is opened */

void http_test_expect_error(http_response* resp, int code):
	assert_equal(code, resp.error)
	assert_equal(0, resp.status)
	http_response_free(resp)


void test_http_request_hardening():
	# CR/LF in a header value (header injection).
	http_req* req = http_req_new(c"GET", c"http://127.0.0.1:9/x")
	http_req_add_header(req, c"X-A", c"a\x0d\x0aEvil: 1")
	http_response* resp = http_request(req)
	assert_strings_equal(c"invalid request header", resp.error_message)
	http_test_expect_error(resp, http_error_bad_header())
	http_req_free(req)

	# Non-token header name.
	req = http_req_new(c"GET", c"http://127.0.0.1:9/x")
	http_req_add_header(req, c"X A", c"v")
	http_test_expect_error(http_request(req), http_error_bad_header())
	http_req_free(req)

	# Caller-supplied framing/routing headers are the client's alone.
	req = http_req_new(c"GET", c"http://127.0.0.1:9/x")
	http_req_add_header(req, c"Host", c"evil.example")
	http_test_expect_error(http_request(req), http_error_bad_header())
	http_req_free(req)
	req = http_req_new(c"GET", c"http://127.0.0.1:9/x")
	http_req_add_header(req, c"Content-Length", c"999")
	http_test_expect_error(http_request(req), http_error_bad_header())
	http_req_free(req)
	req = http_req_new(c"GET", c"http://127.0.0.1:9/x")
	http_req_add_header(req, c"Transfer-Encoding", c"chunked")
	http_test_expect_error(http_request(req), http_error_bad_header())
	http_req_free(req)

	# Method with a space.
	req = http_req_new(c"GE T", c"http://127.0.0.1:9/x")
	http_test_expect_error(http_request(req), http_error_bad_header())
	http_req_free(req)

	# CR or space smuggled into the URL path.
	http_test_expect_error(http_get(c"http://127.0.0.1:9/a\x0db"), http_error_bad_url())
	http_test_expect_error(http_get(c"http://127.0.0.1:9/a\x0ab"), http_error_bad_url())
	http_test_expect_error(http_get(c"http://127.0.0.1:9/a b"), http_error_bad_url())

	# https:// is now a supported transport (wired through net/tls.w, #204);
	# it validates offline here (the loopback TLS handshake is exercised
	# end to end in web/https_e2e_test.w). Assert the validation layer
	# accepts it rather than reaching the network.
	url* https_url = url_parse(c"https://example.com/")
	asserts(c"https url parses", https_url != 0)
	assert_equal(0, http_validate_url(https_url))
	url_free(https_url)

	# Not an absolute http URL at all.
	http_test_expect_error(http_get(c"nope"), http_error_bad_url())
	http_test_expect_error(http_get(0), http_error_bad_url())


/* End-to-end fixture tests */

void test_http_get_round_trip():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		http_test_request q
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		int ok = 1
		if (strcmp(q.method, c"GET") != 0):
			ok = 0
		if (strcmp(q.path, c"/hello?x=1") != 0):
			ok = 0
		char* want_host = strjoin(c"Host: 127.0.0.1:", itoa(port))
		if (http_test_contains(q.head, want_host) == 0):
			ok = 0
		if (http_test_contains(q.head, c"Accept-Encoding: identity") == 0):
			ok = 0
		if (http_test_contains(q.head, c"Connection: keep-alive") == 0):
			ok = 0
		# A GET without a body must not announce one.
		if (http_test_contains(q.head, c"Content-Length") != 0):
			ok = 0
		if (ok != 0):
			http_test_respond(conn, 200, c"X-Custom: hello\x0d\x0aX-Dup: a\x0d\x0aX-Dup: b\x0d\x0a", c"hello world")
		else:
			http_test_respond(conn, 500, 0, c"bad request seen by fixture")
		http_test_drain(conn)
		exit(0)

	char* target = http_test_url(port, c"/hello?x=1")
	http_response* resp = http_get(target)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"hello world", resp.body)
	assert_equal(11, resp.body_len)
	# Case-insensitive lookup and duplicate joining.
	assert_strings_equal(c"hello", http_response_header(resp, c"x-CUSTOM"))
	assert_strings_equal(c"a, b", http_response_header(resp, c"X-Dup"))
	asserts(c"missing header not 0", http_response_header(resp, c"x-missing") == 0)
	http_response_free(resp)
	free(target)
	http_test_finish(pid, listener)


void test_http_post_round_trip():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		http_test_request q
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		int ok = 1
		if (strcmp(q.method, c"POST") != 0):
			ok = 0
		if (strcmp(q.body, c"ping-pong") != 0):
			ok = 0
		if (q.body_len != 9):
			ok = 0
		if (http_test_contains(q.head, c"Content-Length: 9") == 0):
			ok = 0
		if (http_test_contains(q.head, c"X-Token: t1") == 0):
			ok = 0
		if (ok != 0):
			# Echo the request body back.
			http_test_respond(conn, 200, 0, q.body)
		else:
			http_test_respond(conn, 500, 0, c"bad request seen by fixture")
		http_test_drain(conn)
		exit(0)

	char* target = http_test_url(port, c"/echo")
	http_req* req = http_req_new(c"POST", target)
	req.body = c"ping-pong"
	req.body_len = 9
	http_req_add_header(req, c"X-Token", c"t1")
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"ping-pong", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	http_test_finish(pid, listener)


void test_http_chunked_body():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		http_test_request q
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		http_test_request_free(&q)
		# Multi-chunk body with a chunk extension, a 0-size terminator,
		# and trailers.
		http_test_send_text(conn, c"HTTP/1.1 200 OK\x0d\x0aTransfer-Encoding: chunked\x0d\x0a\x0d\x0a")
		http_test_send_text(conn, c"4\x0d\x0aWiki\x0d\x0a")
		http_test_send_text(conn, c"5;ext=1\x0d\x0apedia\x0d\x0a")
		http_test_send_text(conn, c"e\x0d\x0a in\x0d\x0a\x0d\x0achunks.\x0d\x0a")
		http_test_send_text(conn, c"0\x0d\x0aX-Trailer: done\x0d\x0a\x0d\x0a")
		# The trailers must have been consumed exactly: a second
		# request on the same connection still frames correctly.
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		int second_ok = 0
		if (strcmp(q.path, c"/after") == 0):
			second_ok = 1
		http_test_request_free(&q)
		if (second_ok != 0):
			http_test_respond(conn, 200, 0, c"second")
		else:
			http_test_respond(conn, 500, 0, c"unexpected second request")
		http_test_drain(conn)
		exit(0)

	char* target = http_test_url(port, c"/chunked")
	http_response* resp = http_get(target)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"Wikipedia in\x0d\x0a\x0d\x0achunks.", resp.body)
	assert_equal(23, resp.body_len)
	http_response_free(resp)
	free(target)

	# Keep-alive reuse across the chunked response.
	target = http_test_url(port, c"/after")
	resp = http_get(target)
	assert_equal(0, resp.error)
	assert_strings_equal(c"second", resp.body)
	http_response_free(resp)
	free(target)
	http_test_finish(pid, listener)


void test_http_chunked_rejects():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int k = 0
		while (k < 3):
			int conn = socket_accept_connection(listener)
			if (conn < 0):
				exit(1)
			http_test_request q
			if (http_test_read_request(conn, &q) == 0):
				exit(1)
			http_test_request_free(&q)
			if (k == 0):
				# 0xFFFFF0 = 16 MB chunk, over the 8 MB cap.
				http_test_send_text(conn, c"HTTP/1.1 200 OK\x0d\x0aTransfer-Encoding: chunked\x0d\x0a\x0d\x0aFFFFF0\x0d\x0a")
			else if (k == 1):
				http_test_send_text(conn, c"HTTP/1.1 200 OK\x0d\x0aTransfer-Encoding: chunked\x0d\x0a\x0d\x0azz\x0d\x0a")
			else:
				# Undecodable transfer coding fails closed.
				http_test_send_text(conn, c"HTTP/1.1 200 OK\x0d\x0aTransfer-Encoding: gzip\x0d\x0a\x0d\x0a")
			http_test_drain(conn)
			close(conn)
			k = k + 1
		exit(0)

	char* target = http_test_url(port, c"/chunk-abuse")
	http_response* resp = http_get(target)
	assert_equal(http_error_bad_chunk(), resp.error)
	assert_equal(200, resp.status)
	http_response_free(resp)

	resp = http_get(target)
	assert_equal(http_error_bad_chunk(), resp.error)
	http_response_free(resp)

	resp = http_get(target)
	assert_equal(http_error_bad_response(), resp.error)
	http_response_free(resp)
	free(target)
	http_test_finish(pid, listener)


void test_http_malformed_status_line():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int k = 0
		while (k < 2):
			int conn = socket_accept_connection(listener)
			if (conn < 0):
				exit(1)
			http_test_request q
			if (http_test_read_request(conn, &q) == 0):
				exit(1)
			http_test_request_free(&q)
			if (k == 0):
				http_test_send_text(conn, c"BANANA\x0d\x0a\x0d\x0abody")
			else:
				http_test_send_text(conn, c"HTTP/1.1 20 OK\x0d\x0a\x0d\x0a")
			http_test_drain(conn)
			close(conn)
			k = k + 1
		exit(0)

	char* target = http_test_url(port, c"/nonsense")
	http_response* resp = http_get(target)
	assert_equal(http_error_bad_response(), resp.error)
	assert_equal(0, resp.status)
	http_response_free(resp)

	resp = http_get(target)
	assert_equal(http_error_bad_response(), resp.error)
	http_response_free(resp)
	free(target)
	http_test_finish(pid, listener)


void test_http_oversized_headers():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int k = 0
		while (k < 2):
			int conn = socket_accept_connection(listener)
			if (conn < 0):
				exit(1)
			http_test_request q
			if (http_test_read_request(conn, &q) == 0):
				exit(1)
			http_test_request_free(&q)
			string_builder* out = string_new()
			string_append(out, c"HTTP/1.1 200 OK\x0d\x0a")
			if (k == 0):
				# One 9000-byte header line, over the 8192 line cap.
				string_append(out, c"X-Big: ")
				int i = 0
				while (i < 9000):
					string_append_char(out, 'a')
					i = i + 1
				string_append(out, c"\x0d\x0a")
			else:
				# Twelve 6 KB header lines: each under the line cap,
				# together over the 64 KB block cap.
				int h = 0
				while (h < 12):
					string_append(out, c"X-Fill: ")
					int i = 0
					while (i < 6000):
						string_append_char(out, 'b')
						i = i + 1
					string_append(out, c"\x0d\x0a")
					h = h + 1
			string_append(out, c"\x0d\x0aContent-Length: 0\x0d\x0a\x0d\x0a")
			http_test_send_all(conn, out.data, out.length)
			string_free(out)
			http_test_drain(conn)
			close(conn)
			k = k + 1
		exit(0)

	char* target = http_test_url(port, c"/big-headers")
	http_response* resp = http_get(target)
	assert_equal(http_error_headers_too_large(), resp.error)
	http_response_free(resp)

	resp = http_get(target)
	assert_equal(http_error_headers_too_large(), resp.error)
	http_response_free(resp)
	free(target)
	http_test_finish(pid, listener)


# Serves the redirect fixture paths on one keep-alive connection.
void http_test_redirect_child(int listener, int port):
	int conn = socket_accept_connection(listener)
	if (conn < 0):
		exit(1)
	char* absolute_head = strjoin(c"Location: http://127.0.0.1:", itoa(port))
	char* absolute = strjoin(absolute_head, c"/final\x0d\x0a")
	http_test_request q
	while (http_test_read_request(conn, &q) != 0):
		if (strcmp(q.path, c"/start") == 0):
			# Relative path: resolves against the /start directory.
			http_test_respond(conn, 302, c"Location: next\x0d\x0a", c"")
		else if (strcmp(q.path, c"/next") == 0):
			http_test_respond(conn, 301, c"Location: /abs\x0d\x0a", c"")
		else if (strcmp(q.path, c"/abs") == 0):
			http_test_respond(conn, 307, absolute, c"")
		else if (strcmp(q.path, c"/final") == 0):
			http_test_respond(conn, 200, 0, c"arrived")
		else:
			http_test_respond(conn, 404, 0, c"lost")
		http_test_request_free(&q)
	exit(0)


void test_http_redirect_chain():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		http_test_redirect_child(listener, port)

	char* target = http_test_url(port, c"/start")
	http_response* resp = http_get(target)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"arrived", resp.body)
	http_response_free(resp)
	free(target)
	http_test_finish(pid, listener)


void test_http_redirect_loop():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		http_test_request q
		while (http_test_read_request(conn, &q) != 0):
			http_test_request_free(&q)
			http_test_respond(conn, 302, c"Location: /loop\x0d\x0a", c"")
		exit(0)

	char* target = http_test_url(port, c"/loop")
	http_response* resp = http_get(target)
	assert_equal(http_error_too_many_redirects(), resp.error)
	http_response_free(resp)
	free(target)
	http_test_finish(pid, listener)


void test_http_redirects_not_followed_when_disabled():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		http_test_request q
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		http_test_request_free(&q)
		http_test_respond(conn, 302, c"Location: /elsewhere\x0d\x0a", c"redir")
		http_test_drain(conn)
		exit(0)

	char* target = http_test_url(port, c"/moved")
	http_req* req = http_req_new(c"GET", target)
	req.max_redirects = 0
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(302, resp.status)
	assert_strings_equal(c"redir", resp.body)
	assert_strings_equal(c"/elsewhere", http_response_header(resp, c"Location"))
	http_response_free(resp)
	http_req_free(req)
	free(target)
	http_test_finish(pid, listener)


void test_http_303_post_becomes_get():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		http_test_request q
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		int first_ok = 0
		if (strcmp(q.method, c"POST") == 0):
			if (strcmp(q.body, c"data=1") == 0):
				first_ok = 1
		http_test_request_free(&q)
		if (first_ok == 0):
			http_test_respond(conn, 500, 0, c"bad first request")
			http_test_drain(conn)
			exit(1)
		http_test_respond(conn, 303, c"Location: /done\x0d\x0a", c"")
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		int second_ok = 1
		if (strcmp(q.path, c"/done") != 0):
			second_ok = 0
		# The 303 follow-up must be a GET and must drop the body.
		if (http_test_contains(q.head, c"Content-Length") != 0):
			second_ok = 0
		if (q.body_len != 0):
			second_ok = 0
		char* seen_method = strclone(q.method)
		http_test_request_free(&q)
		if (second_ok != 0):
			http_test_respond(conn, 200, 0, seen_method)
		else:
			http_test_respond(conn, 500, 0, c"bad second request")
		http_test_drain(conn)
		exit(0)

	char* target = http_test_url(port, c"/submit")
	http_req* req = http_req_new(c"POST", target)
	req.body = c"data=1"
	req.body_len = 6
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"GET", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	http_test_finish(pid, listener)


void test_http_close_mid_body():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int k = 0
		while (k < 2):
			int conn = socket_accept_connection(listener)
			if (conn < 0):
				exit(1)
			http_test_request q
			if (http_test_read_request(conn, &q) == 0):
				exit(1)
			http_test_request_free(&q)
			# Promise 100 bytes, deliver 10, hang up.
			http_test_send_text(conn, c"HTTP/1.1 200 OK\x0d\x0aContent-Length: 100\x0d\x0a\x0d\x0apartial-10")
			close(conn)
			k = k + 1
		exit(0)

	# Buffered read: error plus the bytes that did arrive.
	char* target = http_test_url(port, c"/truncated")
	http_response* resp = http_get(target)
	assert_equal(http_error_truncated_body(), resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"partial-10", resp.body)
	assert_equal(10, resp.body_len)
	http_response_free(resp)

	# Streaming read: the truncation surfaces as -1.
	http_req* req = http_req_new(c"GET", target)
	http_stream* s = http_open(req)
	assert_equal(0, s.error)
	assert_equal(200, http_stream_headers(s).status)
	char* buf = malloc(64)
	int total = 0
	int got = http_stream_read(s, buf, 64)
	while (got > 0):
		total = total + got
		got = http_stream_read(s, buf, 64)
	assert_equal((-1), got)
	assert_equal(10, total)
	assert_equal(http_error_truncated_body(), s.error)
	free(buf)
	http_stream_close(s)
	http_req_free(req)
	free(target)
	http_test_finish(pid, listener)


void test_http_keep_alive_reuse():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		# Accept exactly one connection and serve both requests on it:
		# a client that opened a second socket would never be served.
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		http_test_request q
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		http_test_request_free(&q)
		http_test_respond(conn, 200, 0, c"one")
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		http_test_request_free(&q)
		http_test_respond(conn, 200, 0, c"two")
		http_test_drain(conn)
		exit(0)

	char* target = http_test_url(port, c"/counted")
	http_req* req = http_req_new(c"GET", target)
	req.timeout_ms = 3000
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_strings_equal(c"one", resp.body)
	http_response_free(resp)

	resp = http_request(req)
	assert_equal(0, resp.error)
	assert_strings_equal(c"two", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	http_test_finish(pid, listener)


void test_http_read_timeout():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		http_test_request q
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		http_test_request_free(&q)
		# Never respond; wait for the client to give up and close.
		http_test_drain(conn)
		exit(0)

	char* target = http_test_url(port, c"/slow")
	http_req* req = http_req_new(c"GET", target)
	req.timeout_ms = 150
	int started = time_monotonic_ms()
	http_response* resp = http_request(req)
	int elapsed = time_monotonic_ms() - started
	assert_equal(http_error_timeout(), resp.error)
	assert_equal(0, resp.status)
	asserts(c"timed out too early", elapsed >= 100)
	asserts(c"timeout took too long", elapsed < 5000)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	http_test_finish(pid, listener)


void test_http_read_to_close_body():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		http_test_request q
		if (http_test_read_request(conn, &q) == 0):
			exit(1)
		http_test_request_free(&q)
		# HTTP/1.0 style: no Content-Length, body delimited by close.
		http_test_send_text(conn, c"HTTP/1.0 200 OK\x0d\x0a\x0d\x0aold-school body")
		close(conn)
		exit(0)

	char* target = http_test_url(port, c"/http10")
	http_response* resp = http_get(target)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"old-school body", resp.body)
	http_response_free(resp)
	free(target)
	http_test_finish(pid, listener)


void test_http_streaming_matches_buffered():
	int port = 0
	int listener = http_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		int k = 0
		while (k < 2):
			http_test_request q
			if (http_test_read_request(conn, &q) == 0):
				exit(1)
			http_test_request_free(&q)
			http_test_send_text(conn, c"HTTP/1.1 200 OK\x0d\x0aContent-Type: text/plain\x0d\x0aTransfer-Encoding: chunked\x0d\x0a\x0d\x0a")
			http_test_send_text(conn, c"6\x0d\x0astream\x0d\x0a")
			http_test_send_text(conn, c"4\x0d\x0a me \x0d\x0a")
			http_test_send_text(conn, c"7\x0d\x0aplease.\x0d\x0a")
			http_test_send_text(conn, c"0\x0d\x0a\x0d\x0a")
			k = k + 1
		http_test_drain(conn)
		exit(0)

	char* target = http_test_url(port, c"/stream")
	http_response* buffered = http_get(target)
	assert_equal(0, buffered.error)
	assert_strings_equal(c"stream me please.", buffered.body)

	# Same resource through the streaming reader, 7 bytes at a time,
	# over the cached keep-alive connection.
	http_req* req = http_req_new(c"GET", target)
	http_stream* s = http_open(req)
	assert_equal(0, s.error)
	http_response* head = http_stream_headers(s)
	assert_equal(200, head.status)
	assert_strings_equal(c"text/plain", http_response_header(head, c"content-type"))
	string_builder* collected = string_new()
	char* buf = malloc(8)
	int got = http_stream_read(s, buf, 7)
	while (got > 0):
		asserts(c"stream chunk over cap", got <= 7)
		string_append_bytes(collected, buf, got)
		got = http_stream_read(s, buf, 7)
	assert_equal(0, got)
	assert_equal(0, s.error)
	assert_strings_equal(buffered.body, collected.data)
	assert_equal(buffered.body_len, collected.length)
	free(buf)
	string_free(collected)
	http_stream_close(s)
	http_req_free(req)
	http_response_free(buffered)
	free(target)
	http_test_finish(pid, listener)
