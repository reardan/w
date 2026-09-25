# wbuild: x64
# Offline tests for libs/standard/net/smtp.w (issue #436).
#
# Protocol tests run against a forked pure-W scripted SMTP server on a
# loopback ephemeral port (the http_client_test.w pattern): the parent
# binds the listener before forking, the child answers each client line
# with the next scripted reply and records every line it receives, and
# after the client disconnects it hands the transcript back over a
# socketpair so the parent can assert the exact command sequence.
# STARTTLS and implicit TLS use tls_accept with the checked-in
# synthetic P-256 fixture cert (libs/standard/net/tls_fixtures/).
# Builder, dot-stuffing and reply-parsing tests need no server.
import lib.testing
import lib.net
import structures.string
import libs.standard.net.tls
import libs.standard.net.smtp
import libs.standard.net.testing
import lib.mem


/* Helpers */

# Replaces each LF in text with CRLF (fixtures read better with LF).
char* fx_crlf(char* text):
	string_builder* out = string_new()
	int i = 0
	while (text[i] != 0):
		if (text[i] == 10):
			string_append_char(out, 13)
		string_append_char(out, text[i] & 255)
		i = i + 1
	char* result = out.data
	free(cast(char*, out))
	return result


/* Scripted SMTP fixture server */

struct smtp_fx:
	int listener
	int port
	int pid
	int pipe_fd


struct smtp_fx_io:
	int fd
	tls_conn* tls
	char* buf
	int pos
	int len


int fx_fill(smtp_fx_io* io):
	if (io.pos < io.len):
		return 1
	int got = 0
	if (io.tls != 0):
		got = tls_read(io.tls, io.buf, 4096)
	else:
		got = read(io.fd, io.buf, 4096)
	if (got <= 0):
		return 0
	io.pos = 0
	io.len = got
	return 1


# Reads one LF-terminated line (terminator and CR stripped). *crlf is 1
# when the line ended in CRLF. Returns 0 at EOF.
int fx_read_line(smtp_fx_io* io, string_builder* line, int* crlf):
	string_clear(line)
	*crlf = 0
	while (fx_fill(io) != 0):
		int ch = io.buf[io.pos] & 255
		io.pos = io.pos + 1
		if (ch == 10):
			if ((line.length > 0) && ((line.data[line.length - 1] & 255) == 13)):
				line.length = line.length - 1
				line.data[line.length] = 0
				*crlf = 1
			return 1
		string_append_char(line, ch)
	return 0


void fx_write(smtp_fx_io* io, char* data, int n):
	if (io.tls != 0):
		tls_write(io.tls, data, n)
		return
	net_test_send_all(io.fd, data, n)


# Copies the next '|'-separated reply from script into resp (LF turned
# into CRLF, final CRLF added). Returns 0 when the script is exhausted.
int fx_next_reply(char* script, int* pos, string_builder* resp):
	string_clear(resp)
	int i = *pos
	if (script[i] == 0):
		return 0
	while ((script[i] != 0) && (script[i] != '|')):
		if (script[i] == 10):
			string_append_char(resp, 13)
		string_append_char(resp, script[i] & 255)
		i = i + 1
	string_append(resp, c"\x0d\x0a")
	if (script[i] == '|'):
		i = i + 1
	*pos = i
	return 1


tls_conn* fx_tls_accept(int fd):
	tls_server_config* scfg = tls_server_config_new()
	scfg.cert_chain_path = c"libs/standard/net/tls_fixtures/server_p256_cert.pem"
	scfg.key_path = c"libs/standard/net/tls_fixtures/server_p256_key.pem"
	return tls_accept(fd, scfg)


void fx_child(int listener, int pipe_fd, char* script, int implicit_tls):
	int conn = socket_accept_connection(listener)
	close(listener)
	string_builder* tr = string_new()
	smtp_fx_io* io = new smtp_fx_io(conn, 0, malloc(4096), 0, 0)
	int alive = 1
	if (implicit_tls != 0):
		io.tls = fx_tls_accept(conn)
		if (io.tls == 0):
			string_append(tr, c"[tls failed]\n")
			alive = 0
	int sp = 0
	string_builder* resp = string_new()
	string_builder* line = string_new()
	if ((alive != 0) && (fx_next_reply(script, &sp, resp) != 0)):
		fx_write(io, resp.data, resp.length)
	int in_data = 0
	int crlf = 0
	while ((alive != 0) && (fx_read_line(io, line, &crlf) != 0)):
		string_append(tr, line.data)
		if (crlf == 0):
			string_append(tr, c"<bare LF>")
		string_append_char(tr, 10)
		int reply = 1
		if (in_data != 0):
			if (strcmp(line.data, c".") == 0):
				in_data = 0
			else:
				reply = 0
		if ((reply != 0) && (fx_next_reply(script, &sp, resp) != 0)):
			fx_write(io, resp.data, resp.length)
			if (starts_with(resp.data, c"354") != 0):
				in_data = 1
			if ((strcmp(line.data, c"STARTTLS") == 0) && (starts_with(resp.data, c"220") != 0)):
				string_append(tr, c"[tls]\n")
				io.tls = fx_tls_accept(conn)
				if (io.tls == 0):
					string_append(tr, c"[tls failed]\n")
					alive = 0
	if (io.tls != 0):
		tls_close(io.tls)
	close(conn)
	int total = 0
	while (total < tr.length):
		int got = socket_send(pipe_fd, tr.data + total, tr.length - total, msg_nosignal())
		if (got <= 0):
			exit(3)
		total = total + got
	close(pipe_fd)
	exit(0)


smtp_fx* fx_start_mode(char* script, int implicit_tls):
	smtp_fx* fx = new smtp_fx()
	int listener = net_test_listen(&fx.port)
	fx.listener = listener
	int* fds = malloc(__word_size__ * 2)
	net_test_assert_ok(c"socketpair", socket_pair(fds))
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		close(fds[0])
		fx_child(listener, fds[1], script, implicit_tls)
	close(fds[1])
	fx.pipe_fd = fds[0]
	fx.pid = pid
	free(cast(char*, fds))
	return fx


smtp_fx* fx_start(char* script):
	return fx_start_mode(script, 0)


# Connected client for the fixture (read timeout keeps a broken test
# from hanging).
smtp_client* fx_client(smtp_fx* fx, char* server_name):
	int fd = socket_tcp_ipv4()
	net_test_assert_ok(c"client socket", fd)
	socket_set_recv_timeout(fd, 20000)
	net_test_assert_ok(c"connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), fx.port))
	return smtp_client_from_fd(fd, server_name)


# Waits for the child and returns everything it recorded.
char* fx_finish(smtp_fx* fx):
	char* result = net_test_read_all(fx.pipe_fd)
	close(fx.pipe_fd)
	int status = 0
	wait4(fx.pid, &status, 0, 0)
	close(fx.listener)
	free(cast(char*, fx))
	asserts(c"fixture child failed", status == 0)
	return result


tls_config* fx_tls_client_config():
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	return cfg


/* Pure unit tests */

void test_smtp_parse_reply_line():
	int code = 0
	int more = 0
	assert_equal(1, smtp_parse_reply_line(c"250 ok", 6, &code, &more))
	assert_equal(250, code)
	assert_equal(0, more)
	assert_equal(1, smtp_parse_reply_line(c"250-SIZE 100", 12, &code, &more))
	assert_equal(1, more)
	assert_equal(1, smtp_parse_reply_line(c"354", 3, &code, &more))
	assert_equal(354, code)
	asserts(c"short line accepted", smtp_parse_reply_line(c"25", 2, &code, &more) == 0)
	asserts(c"1xx accepted", smtp_parse_reply_line(c"199 x", 5, &code, &more) == 0)
	asserts(c"6xx accepted", smtp_parse_reply_line(c"600 x", 5, &code, &more) == 0)
	asserts(c"letters accepted", smtp_parse_reply_line(c"2x0 x", 5, &code, &more) == 0)
	asserts(c"glued text accepted", smtp_parse_reply_line(c"250ok", 5, &code, &more) == 0)


void test_smtp_parse_ehlo_caps():
	smtp_client* c = smtp_client_from_fd((-1), 0)
	smtp_parse_ehlo_caps(c, c"mx hello\nsize 5000\n8bitmime\nPIPELINING\nSTARTTLS\nSMTPUTF8\nAUTH=login cram-md5")
	assert_equal(1, c.esmtp)
	assert_equal(1, c.cap_size)
	assert_equal(5000, c.size_limit)
	assert_equal(1, c.cap_8bitmime)
	assert_equal(1, c.cap_pipelining)
	assert_equal(1, c.cap_starttls)
	assert_equal(1, c.cap_smtputf8)
	assert_equal(0, c.auth_plain)
	assert_equal(1, c.auth_login)
	assert_strings_equal(c"LOGIN CRAM-MD5", c.auth_mechs)
	smtp_parse_ehlo_caps(c, c"mx\nSIZE\nAUTH PLAIN")
	assert_equal(1, c.cap_size)
	assert_equal(0, c.size_limit)
	assert_equal(0, c.cap_starttls)
	assert_equal(1, c.auth_plain)
	assert_equal(0, c.auth_login)
	smtp_close(c)


void test_smtp_dot_stuff():
	int n = 0
	char* input = c".hidden\nline2\x0d\x0a..two\x0dbare\n."
	char* out = smtp_dot_stuff(input, strlen(input), &n)
	assert_strings_equal(fx_crlf(c"..hidden\nline2\n...two\nbare\n..\n"), out)
	assert_equal(strlen(out), n)
	free(out)
	out = smtp_dot_stuff(c"", 0, &n)
	assert_equal(0, n)
	free(out)
	# 998 octets is the limit; 999 fails closed.
	char* longline = malloc(1001)
	mem_fill(longline, 'a', 999)
	longline[999] = 0
	asserts(c"999-octet line accepted", smtp_dot_stuff(longline, 999, &n) == 0)
	out = smtp_dot_stuff(longline, 998, &n)
	asserts(c"998-octet line rejected", out != 0)
	assert_equal(1000, n)
	free(out)
	free(longline)


void test_smtp_validation():
	asserts(c"plain address", smtp_valid_address(c"a.b+tag@example.com") != 0)
	asserts(c"CRLF address", smtp_valid_address(c"a@x\x0d\x0aRCPT TO:<b@y>") == 0)
	asserts(c"LF address", smtp_valid_address(c"a@x\nDATA") == 0)
	asserts(c"space address", smtp_valid_address(c"a b@x") == 0)
	asserts(c"bracket address", smtp_valid_address(c"a@x>") == 0)
	asserts(c"empty address", smtp_valid_address(c"") == 0)
	asserts(c"non-ascii address", smtp_valid_address(c"\xc3\xa9@x") == 0)
	asserts(c"CR line", smtp_valid_line(c"NOOP\x0dRSET", 512) == 0)
	asserts(c"ok line", smtp_valid_line(c"NOOP", 512) != 0)


void test_smtp_format_date():
	char* d = smtp_format_date(1790340000)
	assert_strings_equal(c"Fri, 25 Sep 2026 12:40:00 +0000", d)
	free(d)
	d = smtp_format_date(0)
	assert_strings_equal(c"Thu, 1 Jan 1970 00:00:00 +0000", d)
	free(d)


void test_smtp_encode_word():
	char* w = smtp_encode_word(c"h\xc3\xa9llo")
	assert_strings_equal(c"=?UTF-8?B?aMOpbGxv?=", w)
	free(w)
	# 30 two-byte characters = 60 bytes: split at a character boundary
	# (38 bytes, not 39) into two words of at most 64 characters.
	string_builder* s = string_new()
	int i = 0
	while (i < 30):
		string_append(s, c"\xc3\xa9")
		i = i + 1
	w = smtp_encode_word(s.data)
	int sp = 0
	while (w[sp] != ' '):
		sp = sp + 1
	asserts(c"first word too long", sp <= 64)
	asserts(c"second word too long", strlen(w) - sp - 1 <= 64)
	char* first = substring(w, 0, sp)
	# 38 bytes = 19 characters, so the first chunk is whole characters.
	string_builder* expect = string_new()
	string_append(expect, c"=?UTF-8?B?")
	char* b = base64_encode(s.data, 38)
	string_append(expect, b)
	string_append(expect, c"?=")
	assert_strings_equal(expect.data, first)
	free(b)
	free(first)
	free(w)
	string_free(expect)
	string_free(s)


smtp_message* fx_simple_message():
	smtp_message* m = smtp_message_new()
	smtp_message_set_from(m, c"a@x.test", c"Alice")
	smtp_message_add_to(m, c"b@y.test", 0)
	smtp_message_set_subject(m, c"Hello")
	smtp_message_set_text(m, c"hi\nthere")
	smtp_message_set_date(m, 1790340000)
	smtp_message_set_message_id(m, c"<id1@x.test>")
	return m


void test_smtp_message_build_plain():
	smtp_message* m = fx_simple_message()
	int n = 0
	char* msg = smtp_message_build(m, &n)
	char* want = fx_crlf(c"Date: Fri, 25 Sep 2026 12:40:00 +0000\nFrom: Alice <a@x.test>\nTo: b@y.test\nSubject: Hello\nMessage-ID: <id1@x.test>\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 7bit\n\nhi\nthere\n")
	assert_strings_equal(want, msg)
	assert_equal(strlen(want), n)
	free(msg)
	free(want)
	smtp_message_free(m)


void test_smtp_message_build_multipart():
	smtp_message* m = smtp_message_new()
	smtp_message_set_from(m, c"j@x.test", c"J\xc3\xb6rg")
	smtp_message_add_to(m, c"b@y.test", c"Doe, John")
	smtp_message_add_cc(m, c"c@y.test", c"Carol")
	smtp_message_add_bcc(m, c"hidden@y.test")
	smtp_message_set_subject(m, c"Gr\xc3\xbc\xc3\x9f\x65 aus K\xc3\xb6ln")
	smtp_message_set_text(m, c"plain")
	smtp_message_set_html(m, c"<p>caf\xc3\xa9</p>")
	smtp_message_set_date(m, 0)
	smtp_message_set_message_id(m, c"<m@x.test>")
	smtp_message_set_boundary(m, c"BOUND")
	int n = 0
	char* msg = smtp_message_build(m, &n)
	char* want = fx_crlf(c"Date: Thu, 1 Jan 1970 00:00:00 +0000\nFrom: =?UTF-8?B?SsO2cmc=?= <j@x.test>\nTo: \"Doe, John\" <b@y.test>\nCc: Carol <c@y.test>\nSubject: =?UTF-8?B?R3LDvMOfZSBhdXMgS8O2bG4=?=\nMessage-ID: <m@x.test>\nMIME-Version: 1.0\nContent-Type: multipart/alternative; boundary=\"BOUND\"\n\n--BOUND\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 7bit\n\nplain\n--BOUND\nContent-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: base64\n\nPHA+Y2Fmw6k8L3A+\n--BOUND--\n")
	assert_strings_equal(want, msg)
	free(msg)
	free(want)
	# Bcc is in the envelope but in no header.
	list[char*] rcpts = smtp_message_recipients(m)
	assert_equal(3, rcpts.length)
	assert_strings_equal(c"b@y.test", rcpts[0])
	assert_strings_equal(c"c@y.test", rcpts[1])
	assert_strings_equal(c"hidden@y.test", rcpts[2])
	rcpts.free()
	smtp_message_free(m)


# Every line of a header block is at most max characters and
# continuation lines start with a space.
void fx_assert_folded(char* msg, int max):
	int i = 0
	int col = 0
	int line_start = 1
	while ((msg[i] != 0) && ((msg[i] != 13) || (line_start == 0))):
		if (msg[i] == 13):
			assert_equal(10, msg[i + 1])
			i = i + 2
			col = 0
			line_start = 1
		else:
			line_start = 0
			col = col + 1
			asserts(c"header line too long", col <= max)
			i = i + 1


void test_smtp_message_header_folding():
	smtp_message* m = fx_simple_message()
	int i = 0
	while (i < 8):
		string_builder* addr = string_new()
		string_append(addr, c"recipient")
		string_append_int(addr, i)
		string_append(addr, c"@example.org")
		smtp_message_add_to(m, addr.data, c"Some Person")
		string_free(addr)
		i = i + 1
	smtp_message_set_subject(m, c"A rather long subject line that certainly needs folding because it goes on and on past the limit")
	int n = 0
	char* msg = smtp_message_build(m, &n)
	asserts(c"build failed", msg != 0)
	fx_assert_folded(msg, 78)
	asserts(c"subject not folded", smtp_contains(msg, fx_crlf(c"Subject: A rather long subject line that certainly needs folding because it\n goes on and on past the limit\n")) != 0)
	asserts(c"To not folded after comma", smtp_contains(msg, fx_crlf(c"To: b@y.test, Some Person <recipient0@example.org>, Some Person\n <recipient1@example.org>")) != 0)
	free(msg)
	# A long non-ASCII subject becomes several folded encoded-words.
	string_builder* s = string_new()
	i = 0
	while (i < 60):
		string_append(s, c"\xc3\xa9")
		i = i + 1
	smtp_message_set_subject(m, s.data)
	msg = smtp_message_build(m, &n)
	fx_assert_folded(msg, 78)
	asserts(c"subject words not folded", smtp_contains(msg, c"?=\x0d\x0a =?UTF-8?B?") != 0)
	free(msg)
	string_free(s)
	smtp_message_free(m)


void test_smtp_message_build_rejects():
	int n = 0
	smtp_message* m = fx_simple_message()
	smtp_message_set_subject(m, c"hi\x0d\x0a\x42\x63\x63: victim@x.test")
	asserts(c"CRLF subject built", smtp_message_build(m, &n) == 0)
	smtp_message_set_subject(m, c"ok")
	smtp_message_add_to(m, c"x@y.test", c"Eve\nBcc: v@x")
	asserts(c"LF name built", smtp_message_build(m, &n) == 0)
	smtp_message_free(m)

	m = fx_simple_message()
	smtp_message_add_cc(m, c"bad address@x", 0)
	asserts(c"bad cc built", smtp_message_build(m, &n) == 0)
	smtp_message_free(m)

	m = smtp_message_new()
	smtp_message_set_from(m, c"a@x.test", 0)
	asserts(c"no recipients built", smtp_message_build(m, &n) == 0)
	smtp_message_free(m)

	m = fx_simple_message()
	smtp_message_set_html(m, c"<p>BOUND</p>")
	smtp_message_set_boundary(m, c"BOUND")
	asserts(c"boundary collision built", smtp_message_build(m, &n) == 0)
	smtp_message_set_boundary(m, 0)
	char* msg = smtp_message_build(m, &n)
	asserts(c"random boundary failed", smtp_contains(msg, c"boundary=\"=_w_") != 0)
	free(msg)
	smtp_message_set_message_id(m, c"<a b@x>")
	asserts(c"bad message id built", smtp_message_build(m, &n) == 0)
	smtp_message_set_message_id(m, 0)
	msg = smtp_message_build(m, &n)
	asserts(c"generated message id missing", smtp_contains(msg, c"@x.test>\x0d\x0aMIME-Version") != 0)
	free(msg)
	smtp_message_free(m)


void test_smtp_message_body_base64():
	smtp_message* m = fx_simple_message()
	smtp_message_set_text(m, c"caf\xc3\xa9")
	int n = 0
	char* msg = smtp_message_build(m, &n)
	asserts(c"base64 body missing", smtp_contains(msg, fx_crlf(c"Content-Transfer-Encoding: base64\n\nY2Fmw6k=\n")) != 0)
	free(msg)
	smtp_message_free(m)


/* Protocol tests against the scripted server */

void test_smtp_send_auth_plain():
	smtp_fx* fx = fx_start(c"220 mx.test ESMTP|250-mx.test hi\n250-SIZE 10000\n250-8BITMIME\n250-PIPELINING\n250 AUTH PLAIN LOGIN|235 ok|250 sender ok|250 rcpt ok|354 go|250 queued|221 bye")
	smtp_client* c = smtp_open(c"127.0.0.1", fx.port, smtp_security_none(), 0, c"client.example", 20000)
	assert_equal(0, smtp_error(c))
	assert_equal(1, c.esmtp)
	assert_equal(10000, c.size_limit)
	assert_equal(1, c.cap_8bitmime)
	assert_equal(1, c.cap_pipelining)
	assert_equal(1, c.auth_plain)
	assert_equal(1, c.auth_login)
	assert_strings_equal(c"mx.test hi\nSIZE 10000\n8BITMIME\nPIPELINING\nAUTH PLAIN LOGIN", smtp_last_reply(c))
	assert_equal(1, smtp_auth(c, c"user", c"pass"))
	char* msg = fx_crlf(c"Subject: hi\n\nhello\n")
	list[char*] rcpts = list[char*]{c"b@y.test"}
	assert_equal(1, smtp_send(c, c"a@x.test", rcpts, msg, strlen(msg)))
	assert_equal(250, smtp_last_code(c))
	assert_strings_equal(c"queued", smtp_last_reply(c))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	char* tr = fx_finish(fx)
	assert_strings_equal(c"EHLO client.example\nAUTH PLAIN AHVzZXIAcGFzcw==\nMAIL FROM:<a@x.test> SIZE=22\nRCPT TO:<b@y.test>\nDATA\nSubject: hi\n\nhello\n.\nQUIT\n", tr)
	rcpts.free()


void test_smtp_auth_login():
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n250 AUTH LOGIN|334 VXNlcm5hbWU6|334 UGFzc3dvcmQ6|235 welcome|221 bye")
	smtp_client* c = fx_client(fx, c"localhost")
	assert_equal(1, smtp_start(c, smtp_security_none(), 0, c"client.example"))
	assert_equal(0, c.auth_plain)
	assert_equal(1, smtp_auth(c, c"user", c"pass"))
	assert_equal(235, smtp_last_code(c))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	assert_strings_equal(c"EHLO client.example\nAUTH LOGIN\ndXNlcg==\ncGFzcw==\nQUIT\n", fx_finish(fx))


void test_smtp_auth_failure_cancels():
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n250 AUTH LOGIN|334 VXNlcm5hbWU6|535 bad user|221 bye")
	smtp_client* c = fx_client(fx, c"127.0.0.1")
	assert_equal(1, smtp_start(c, smtp_security_none(), 0, 0))
	assert_equal(0, smtp_auth_login(c, c"nobody", c"x"))
	assert_equal(smtp_error_rejected(), smtp_error(c))
	assert_equal(535, smtp_last_code(c))
	assert_equal(0, smtp_auth_plain(c, c"user", c"pass"))
	assert_equal(smtp_error_unsupported(), smtp_error(c))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	assert_strings_equal(c"EHLO localhost\nAUTH LOGIN\nbm9ib2R5\nQUIT\n", fx_finish(fx))


void test_smtp_multi_recipient_message():
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n250 8BITMIME|250 ok|250 ok|550 no such user|251 forwarding|354 go|250 queued|221 bye")
	smtp_client* c = fx_client(fx, c"127.0.0.1")
	assert_equal(1, smtp_start(c, smtp_security_none(), 0, c"client.example"))
	smtp_message* m = fx_simple_message()
	smtp_message_add_cc(m, c"gone@y.test", 0)
	smtp_message_add_bcc(m, c"c@z.test")
	assert_equal(2, smtp_send_message(c, m))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	smtp_message_free(m)
	assert_strings_equal(c"EHLO client.example\nMAIL FROM:<a@x.test>\nRCPT TO:<b@y.test>\nRCPT TO:<gone@y.test>\nRCPT TO:<c@z.test>\nDATA\nDate: Fri, 25 Sep 2026 12:40:00 +0000\nFrom: Alice <a@x.test>\nTo: b@y.test\nCc: gone@y.test\nSubject: Hello\nMessage-ID: <id1@x.test>\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 7bit\n\nhi\nthere\n.\nQUIT\n", fx_finish(fx))


void test_smtp_dot_stuffing_on_wire():
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n250-8BITMIME\n250 SIZE|250 ok|250 ok|354 go|250 queued|250 ok|221 bye")
	smtp_client* c = fx_client(fx, c"127.0.0.1")
	assert_equal(1, smtp_start(c, smtp_security_none(), 0, c"client.example"))
	char* body = c".hidden\nline2\x0d\x0a..two\x0dbare\n.\ncaf\xc3\xa9"
	list[char*] rcpts = list[char*]{c"b@y.test"}
	assert_equal(1, smtp_send(c, c"", rcpts, body, strlen(body)))
	assert_equal(1, smtp_noop(c))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	assert_strings_equal(c"EHLO client.example\nMAIL FROM:<> SIZE=33 BODY=8BITMIME\nRCPT TO:<b@y.test>\nDATA\n..hidden\nline2\n...two\nbare\n..\ncaf\xc3\xa9\n.\nNOOP\nQUIT\n", fx_finish(fx))
	rcpts.free()


void test_smtp_helo_fallback():
	smtp_fx* fx = fx_start(c"220 old.test|502 command not recognized|250 old.test|250 ok|250 ok|354 go|250 queued|221 bye")
	smtp_client* c = fx_client(fx, c"127.0.0.1")
	assert_equal(1, smtp_start(c, smtp_security_none(), 0, c"client.example"))
	assert_equal(0, c.esmtp)
	assert_equal(0, c.cap_size)
	# No AUTH on a HELO server: refused locally, nothing sent.
	assert_equal(0, smtp_auth(c, c"user", c"pass"))
	assert_equal(smtp_error_unsupported(), smtp_error(c))
	char* msg = fx_crlf(c"x\n")
	list[char*] rcpts = list[char*]{c"b@y.test"}
	assert_equal(1, smtp_send(c, c"a@x.test", rcpts, msg, strlen(msg)))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	assert_strings_equal(c"EHLO client.example\nHELO client.example\nMAIL FROM:<a@x.test>\nRCPT TO:<b@y.test>\nDATA\nx\n.\nQUIT\n", fx_finish(fx))
	rcpts.free()


void test_smtp_rejections():
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n250 SIZE 100|550 sender denied|250 ok|550 no|550 no|250 reset|250 ok|250 ok|354 go|554-5.7.1 spam\n554 5.7.1 rejected|250 reset|221 bye")
	smtp_client* c = fx_client(fx, c"127.0.0.1")
	assert_equal(1, smtp_start(c, smtp_security_none(), 0, c"client.example"))
	char* msg = fx_crlf(c"x\n")
	list[char*] one = list[char*]{c"b@y.test"}
	list[char*] two = list[char*]{c"b@y.test", c"c@y.test"}
	# MAIL rejected: no transaction is open, so no RSET.
	assert_equal(0, smtp_send(c, c"a@x.test", one, msg, strlen(msg)))
	assert_equal(smtp_error_rejected(), smtp_error(c))
	assert_equal(550, smtp_last_code(c))
	assert_strings_equal(c"sender denied", smtp_last_reply(c))
	# Every recipient rejected -> RSET, no DATA.
	assert_equal(0, smtp_send(c, c"a@x.test", two, msg, strlen(msg)))
	assert_equal(550, smtp_last_code(c))
	# Final DATA reply rejected (multi-line 554) -> RSET.
	assert_equal(0, smtp_send(c, c"a@x.test", one, msg, strlen(msg)))
	assert_equal(554, smtp_last_code(c))
	assert_strings_equal(c"5.7.1 spam\n5.7.1 rejected", smtp_last_reply(c))
	# Over the advertised SIZE: refused locally, nothing sent.
	char* big = malloc(201)
	mem_fill(big, 'a', 200)
	big[200] = 0
	assert_equal(0, smtp_send(c, c"a@x.test", one, big, 200))
	assert_equal(smtp_error_too_large(), smtp_error(c))
	free(big)
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	assert_strings_equal(c"EHLO client.example\nMAIL FROM:<a@x.test> SIZE=3\nMAIL FROM:<a@x.test> SIZE=3\nRCPT TO:<b@y.test>\nRCPT TO:<c@y.test>\nRSET\nMAIL FROM:<a@x.test> SIZE=3\nRCPT TO:<b@y.test>\nDATA\nx\n.\nRSET\nQUIT\n", fx_finish(fx))
	one.free()
	two.free()


void test_smtp_injection_rejected():
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n250 AUTH PLAIN|235 ok|221 bye")
	smtp_client* c = fx_client(fx, c"mx.test")
	assert_equal(1, smtp_start(c, smtp_security_none(), 0, c"client.example"))
	assert_equal(0, smtp_mail_from(c, c"a@x\x0d\x0aRCPT TO:<evil@x>", 0))
	assert_equal(smtp_error_invalid(), smtp_error(c))
	assert_equal(0, smtp_rcpt_to(c, c"b@y>\x0d\x0a\x44\x41TA"))
	assert_equal(smtp_error_invalid(), smtp_error(c))
	assert_equal(0, smtp_rcpt_to(c, c"b@y\nQUIT"))
	assert_equal(0, smtp_rcpt_to(c, c"b @y"))
	assert_equal(0, smtp_ehlo(c, c"x\x0d\x0aQUIT"))
	assert_equal(smtp_error_invalid(), smtp_error(c))
	assert_equal((-1), smtp_command(c, c"NOOP\x0d\x0aRSET"))
	assert_equal(smtp_error_invalid(), smtp_error(c))
	list[char*] evil = list[char*]{c"ok@y.test", c"x@y\x0d\x0aRSET"}
	char* msg = fx_crlf(c"x\n")
	assert_equal(0, smtp_send(c, c"a@x.test", evil, msg, strlen(msg)))
	assert_equal(smtp_error_invalid(), smtp_error(c))
	evil.free()
	# Length limits: a 300-character address and a 600-character line.
	string_builder* s = string_new()
	int i = 0
	while (i < 300):
		string_append_char(s, 'a')
		i = i + 1
	assert_equal(0, smtp_rcpt_to(c, s.data))
	assert_equal(smtp_error_invalid(), smtp_error(c))
	while (i < 600):
		string_append_char(s, 'a')
		i = i + 1
	assert_equal((-1), smtp_command(c, s.data))
	string_free(s)
	# A 1000-octet text line fails before DATA is sent.
	char* longline = malloc(1001)
	mem_fill(longline, 'a', 1000)
	longline[1000] = 0
	assert_equal(0, smtp_data(c, longline, 1000))
	assert_equal(smtp_error_too_large(), smtp_error(c))
	free(longline)
	# Credentials never go out in plaintext to a non-loopback name...
	assert_equal(0, smtp_auth_plain(c, c"user", c"pass"))
	assert_equal(smtp_error_insecure(), smtp_error(c))
	# ...unless explicitly allowed.
	smtp_set_allow_insecure_auth(c, 1)
	assert_equal(1, smtp_auth_plain(c, c"user", c"pass"))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	assert_strings_equal(c"EHLO client.example\nAUTH PLAIN AHVzZXIAcGFzcw==\nQUIT\n", fx_finish(fx))


void test_smtp_malformed_replies():
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n251 mixed codes")
	smtp_client* c = fx_client(fx, c"127.0.0.1")
	assert_equal(0, smtp_start(c, smtp_security_none(), 0, c"client.example"))
	assert_equal(smtp_error_protocol(), smtp_error(c))
	# The session is dead: later calls fail fast without I/O.
	assert_equal(0, smtp_noop(c))
	smtp_close(c)
	assert_strings_equal(c"EHLO client.example\n", fx_finish(fx))

	fx = fx_start(c"hello there")
	c = fx_client(fx, c"127.0.0.1")
	assert_equal(0, smtp_greeting(c))
	assert_equal(smtp_error_protocol(), smtp_error(c))
	smtp_close(c)
	assert_strings_equal(c"", fx_finish(fx))

	fx = fx_start(c"554 go away|221 bye")
	c = fx_client(fx, c"127.0.0.1")
	assert_equal(0, smtp_greeting(c))
	assert_equal(smtp_error_rejected(), smtp_error(c))
	assert_equal(554, smtp_last_code(c))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	assert_strings_equal(c"QUIT\n", fx_finish(fx))


void test_smtp_starttls():
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n250-STARTTLS\n250 SIZE 1000|220 go ahead|250-mx over tls\n250 AUTH PLAIN|235 ok|250 ok|221 bye")
	smtp_client* c = fx_client(fx, c"mx.test")
	tls_config* cfg = fx_tls_client_config()
	int ok = smtp_start(c, smtp_security_starttls(), cfg, c"client.example")
	if (ok == 0):
		println(smtp_error_message(c))
	assert_equal(1, ok)
	asserts(c"not encrypted", c.tls != 0)
	# Capabilities come from the post-TLS EHLO only.
	assert_equal(0, c.cap_starttls)
	assert_equal(0, c.cap_size)
	assert_equal(1, c.auth_plain)
	assert_equal(1, smtp_auth(c, c"user", c"pass"))
	assert_equal(1, smtp_noop(c))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	tls_config_free(cfg)
	assert_strings_equal(c"EHLO client.example\nSTARTTLS\n[tls]\nEHLO client.example\nAUTH PLAIN AHVzZXIAcGFzcw==\nNOOP\nQUIT\n", fx_finish(fx))


void test_smtp_starttls_required_but_missing():
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n250 AUTH PLAIN|221 bye")
	smtp_client* c = fx_client(fx, c"mx.test")
	assert_equal(0, smtp_start(c, smtp_security_starttls(), 0, c"client.example"))
	assert_equal(smtp_error_unsupported(), smtp_error(c))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	assert_strings_equal(c"EHLO client.example\nQUIT\n", fx_finish(fx))


void test_smtp_starttls_injection():
	# Plaintext pipelined behind the 220 must not survive into TLS.
	smtp_fx* fx = fx_start(c"220 mx|250-mx\n250 STARTTLS|220 go ahead\n250 injected")
	smtp_client* c = fx_client(fx, c"mx.test")
	assert_equal(0, smtp_start(c, smtp_security_starttls(), 0, c"client.example"))
	assert_equal(smtp_error_protocol(), smtp_error(c))
	smtp_close(c)
	assert_strings_equal(c"EHLO client.example\nSTARTTLS\n[tls]\n[tls failed]\n", fx_finish(fx))


void test_smtp_implicit_tls():
	smtp_fx* fx = fx_start_mode(c"220 mx smtps|250-mx\n250 AUTH LOGIN|334 VXNlcm5hbWU6|334 UGFzc3dvcmQ6|235 ok|221 bye", 1)
	smtp_client* c = fx_client(fx, c"mx.test")
	tls_config* cfg = fx_tls_client_config()
	assert_equal(1, smtp_start(c, smtp_security_implicit(), cfg, c"client.example"))
	assert_equal(1, smtp_auth(c, c"user", c"pass"))
	assert_equal(1, smtp_quit(c))
	smtp_close(c)
	tls_config_free(cfg)
	assert_strings_equal(c"EHLO client.example\nAUTH LOGIN\ndXNlcg==\ncGFzcw==\nQUIT\n", fx_finish(fx))
