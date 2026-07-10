# wbuild: x64
# Offline tests for libs/standard/web/sse.w (issue #202). Every event
# stream is served by a forked pure-W fixture server on a loopback
# ephemeral port (the http_client_test.w pattern), and the parent drives
# a real http_stream through sse_next. That means the parser is always
# exercised over the genuine http_stream_read contract; the
# split-across-reads test additionally dribbles bytes with tiny sleeps so
# lines and events are guaranteed to straddle read boundaries.
import lib.testing
import lib.net
import lib.time
import structures.string
import libs.standard.web.http_client
import libs.standard.web.sse


void sse_test_assert_ok(char* name, int result):
	if (result < 0):
		print_string(name, c" failed")
		translate_syscall_failure(result)
		exit(1)


/* Fixture server helpers */

# Listener on 127.0.0.1 with a kernel-assigned port.
int sse_test_listen(int* out_port):
	int listener = socket_tcp_ipv4()
	sse_test_assert_ok(c"tcp socket", listener)
	sse_test_assert_ok(c"reuseaddr", socket_set_reuseaddr(listener))
	sse_test_assert_ok(c"bind", socket_bind_ipv4(listener, ip4_from_string(c"127.0.0.1"), 0))
	sse_test_assert_ok(c"listen", socket_listen(listener, 8))
	sockaddr_in bound
	sse_test_assert_ok(c"getsockname", socket_getsockname_ipv4(listener, &bound))
	*out_port = net_htons(bound.port)
	return listener


char* sse_test_url(int port, char* path):
	string_builder* out = string_new()
	string_append(out, c"http://127.0.0.1:")
	string_append_int(out, port)
	string_append(out, path)
	char* text = out.data
	free(out)
	return text


# SIGPIPE-proof send: an early client close must not kill the child.
void sse_test_send_all(int conn, char* data, int n):
	int total = 0
	while (total < n):
		int got = socket_send(conn, data + total, n - total, msg_nosignal())
		if (got <= 0):
			return
		total = total + got


void sse_test_send_text(int conn, char* text):
	sse_test_send_all(conn, text, strlen(text))


void sse_test_send_builder(int conn, string_builder* b):
	sse_test_send_all(conn, b.data, b.length)


# Consumes the request head (up to the terminating CRLFCRLF) so the child
# can start responding.
void sse_child_read_request(int conn):
	char* buf = malloc(8192)
	int total = 0
	int done = 0
	while (done == 0):
		int got = read(conn, buf + total, 8191 - total)
		if (got <= 0):
			done = 1
		else:
			total = total + got
			int i = 0
			while (i + 3 < total):
				if ((buf[i] == 13) & (buf[i + 1] == 10)):
					if ((buf[i + 2] == 13) & (buf[i + 3] == 10)):
						done = 1
						i = total
					else:
						i = i + 1
				else:
					i = i + 1
			if (total >= 8191):
				done = 1
	free(buf)


# Standard SSE response head: no Content-Length, so the client frames the
# body by connection close.
void sse_child_send_head(int conn):
	sse_test_send_text(conn, c"HTTP/1.1 200 OK\x0d\x0aContent-Type: text/event-stream\x0d\x0aConnection: close\x0d\x0a\x0d\x0a")


/* Parent-side driver */

struct sse_test_conn:
	http_req* req
	http_stream* s
	sse_reader* r


sse_test_conn* sse_test_open(char* target):
	sse_test_conn* c = new sse_test_conn()
	c.req = http_req_new(c"GET", target)
	c.req.timeout_ms = 5000
	c.s = http_open(c.req)
	asserts(c"stream open error", c.s.error == 0)
	assert_equal(200, http_stream_headers(c.s).status)
	c.r = sse_open(c.s)
	return c


void sse_test_close(sse_test_conn* c, int pid, int listener):
	sse_reader_free(c.r)
	http_stream_close(c.s)
	http_req_free(c.req)
	free(c)
	http_client_close_idle()
	int status = 0
	wait4(pid, &status, 0, 0)
	close(listener)


# Asserts the next event's type and data, then frees it. Tests that also
# need to inspect the id or retry_ms call sse_next directly instead.
void sse_expect(sse_reader* r, char* want_event, char* want_data):
	sse_event* ev = sse_next(r)
	asserts(c"expected an event, got end-of-stream", ev != 0)
	assert_strings_equal(want_event, ev.event)
	assert_strings_equal(want_data, ev.data)
	sse_event_free(ev)


/* Tests */

void test_sse_basic_fields():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		sse_test_send_text(conn, c"event: greeting\ndata: hello world\n\n")
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	sse_event* ev = sse_next(c.r)
	asserts(c"no event", ev != 0)
	assert_strings_equal(c"greeting", ev.event)
	assert_strings_equal(c"hello world", ev.data)
	asserts(c"id should be 0", ev.id == 0)
	assert_equal(0, ev.retry_ms)
	sse_event_free(ev)
	# Clean end-of-stream: a null event with no error.
	asserts(c"expected EOF", sse_next(c.r) == 0)
	assert_equal(sse_error_none(), sse_reader_error(c.r))
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_leading_space_stripping():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		# One optional space is stripped; a second space is data.
		sse_test_send_text(conn, c"data: withspace\n\n")
		sse_test_send_text(conn, c"data:nospace\n\n")
		sse_test_send_text(conn, c"data:  twospaces\n\n")
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	sse_expect(c.r, c"message", c"withspace")
	sse_expect(c.r, c"message", c"nospace")
	sse_expect(c.r, c"message", c" twospaces")
	asserts(c"expected EOF", sse_next(c.r) == 0)
	assert_equal(sse_error_none(), sse_reader_error(c.r))
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_multiline_data():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		sse_test_send_text(conn, c"data: line1\ndata: line2\ndata: line3\n\n")
		# An empty data line contributes just a newline.
		sse_test_send_text(conn, c"data\ndata: tail\n\n")
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	sse_expect(c.r, c"message", c"line1\nline2\nline3")
	# "data" with no colon -> empty value; joined "\ntail".
	sse_expect(c.r, c"message", c"\ntail")
	asserts(c"expected EOF", sse_next(c.r) == 0)
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_comment_keepalive():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		# A bare-colon keep-alive, a comment, then the real event.
		sse_test_send_text(conn, c":\n: keep-alive ping\ndata: after-comment\n\n")
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	sse_expect(c.r, c"message", c"after-comment")
	asserts(c"expected EOF", sse_next(c.r) == 0)
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_retry_field():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		sse_test_send_text(conn, c"retry: 7000\ndata: a\n\n")
		# A non-numeric retry is ignored; the delay stays 7000.
		sse_test_send_text(conn, c"retry: notanumber\ndata: b\n\n")
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	sse_event* ev = sse_next(c.r)
	asserts(c"no event", ev != 0)
	assert_strings_equal(c"a", ev.data)
	assert_equal(7000, ev.retry_ms)
	assert_equal(7000, sse_reader_retry_ms(c.r))
	sse_event_free(ev)
	ev = sse_next(c.r)
	asserts(c"no event 2", ev != 0)
	assert_strings_equal(c"b", ev.data)
	assert_equal(7000, ev.retry_ms)
	sse_event_free(ev)
	asserts(c"expected EOF", sse_next(c.r) == 0)
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_id_and_nul():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		string_builder* body = string_new()
		string_append(body, c"id: 42\ndata: a\n\n")
		# An id containing a NUL is ignored; last id stays "42".
		string_append(body, c"id: x")
		string_append_char(body, 0)
		string_append(body, c"y\ndata: b\n\n")
		# No id field: the last id persists.
		string_append(body, c"data: c\n\n")
		sse_test_send_builder(conn, body)
		string_free(body)
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	sse_event* ev = sse_next(c.r)
	asserts(c"no event", ev != 0)
	assert_strings_equal(c"a", ev.data)
	asserts(c"id missing", ev.id != 0)
	assert_strings_equal(c"42", ev.id)
	sse_event_free(ev)
	# NUL id rejected -> still "42".
	ev = sse_next(c.r)
	asserts(c"no event 2", ev != 0)
	assert_strings_equal(c"b", ev.data)
	assert_strings_equal(c"42", ev.id)
	sse_event_free(ev)
	# id persists across events.
	ev = sse_next(c.r)
	asserts(c"no event 3", ev != 0)
	assert_strings_equal(c"c", ev.data)
	assert_strings_equal(c"42", ev.id)
	sse_event_free(ev)
	asserts(c"expected EOF", sse_next(c.r) == 0)
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_cr_lf_crlf_endings():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		# CR-only, LF-only, and CRLF line/terminator styles.
		sse_test_send_text(conn, c"data: cr\x0d\x0d")
		sse_test_send_text(conn, c"data: lf\x0a\x0a")
		sse_test_send_text(conn, c"data: crlf\x0d\x0a\x0d\x0a")
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	sse_expect(c.r, c"message", c"cr")
	sse_expect(c.r, c"message", c"lf")
	sse_expect(c.r, c"message", c"crlf")
	asserts(c"expected EOF", sse_next(c.r) == 0)
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_bom_stripping():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		string_builder* body = string_new()
		# A single leading UTF-8 BOM (EF BB BF) before the first field.
		string_append_char(body, 239)
		string_append_char(body, 187)
		string_append_char(body, 191)
		string_append(body, c"event: boms\ndata: ok\n\n")
		sse_test_send_builder(conn, body)
		string_free(body)
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	# If the BOM were not stripped, "event" would not parse.
	sse_expect(c.r, c"boms", c"ok")
	asserts(c"expected EOF", sse_next(c.r) == 0)
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_blank_line_dispatch():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		# An event with only "event:" and no data must NOT dispatch, and
		# must reset the event type. Only the second block fires.
		sse_test_send_text(conn, c"event: ping\n\ndata: real\n\n")
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	# The event-only block was skipped and its type discarded, so this
	# fires as the default "message" type.
	sse_expect(c.r, c"message", c"real")
	asserts(c"expected EOF", sse_next(c.r) == 0)
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_split_across_reads():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		# Dribble with sleeps so each piece surfaces as its own read: a
		# line split mid-token, an event split at the blank line, and a
		# CRLF split across the read boundary.
		sse_test_send_text(conn, c"data: hel")
		sleep_ms(20)
		sse_test_send_text(conn, c"lo\nda")
		sleep_ms(20)
		sse_test_send_text(conn, c"ta: world\n")
		sleep_ms(20)
		sse_test_send_text(conn, c"\n")
		sleep_ms(20)
		sse_test_send_text(conn, c"data: second\n\n")
		sleep_ms(20)
		sse_test_send_text(conn, c"data: split\x0d")
		sleep_ms(20)
		sse_test_send_text(conn, c"\x0a\x0d\x0a")
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	sse_expect(c.r, c"message", c"hello\nworld")
	sse_expect(c.r, c"message", c"second")
	sse_expect(c.r, c"message", c"split")
	asserts(c"expected EOF", sse_next(c.r) == 0)
	assert_equal(sse_error_none(), sse_reader_error(c.r))
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_buffer_overflow_fails_closed():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		sse_child_send_head(conn)
		# One line larger than the 1 MiB line cap, with no terminator.
		char* chunk = malloc(65536)
		int i = 0
		while (i < 65536):
			chunk[i] = 'x'
			i = i + 1
		int sent = 0
		while (sent < 1245184):
			sse_test_send_all(conn, chunk, 65536)
			sent = sent + 65536
		free(chunk)
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	# The oversized line trips the cap: no event, overflow error.
	asserts(c"overflow should yield no event", sse_next(c.r) == 0)
	assert_equal(sse_error_overflow(), sse_reader_error(c.r))
	sse_test_close(c, pid, listener)
	free(target)


void test_sse_stream_error_distinct_from_eof():
	int port = 0
	int listener = sse_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		sse_child_read_request(conn)
		# Promise 100 body bytes but deliver 14 then hang up: the stream
		# read fails mid-body.
		sse_test_send_text(conn, c"HTTP/1.1 200 OK\x0d\x0aContent-Type: text/event-stream\x0d\x0aContent-Length: 100\x0d\x0a\x0d\x0a")
		sse_test_send_text(conn, c"data: partial\n")
		close(conn)
		exit(0)

	char* target = sse_test_url(port, c"/events")
	sse_test_conn* c = sse_test_open(target)
	# No complete event arrives; the truncation surfaces as a stream
	# error, distinct from a clean EOF.
	asserts(c"expected no event", sse_next(c.r) == 0)
	assert_equal(sse_error_stream(), sse_reader_error(c.r))
	sse_test_close(c, pid, listener)
	free(target)
