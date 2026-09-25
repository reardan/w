# wbuild: x64
# Offline FTPS tests for libs/standard/net/ftp.w (RFC 4217, issue #436).
# The session tests run against a forked pure-W FTPS fixture server on
# loopback (the ftp_test.w / smtp_test.w pattern): the parent binds the
# control listener before forking, the child serves one session with
# tls_accept and the checked-in synthetic P-256 fixture cert
# (libs/standard/net/tls_fixtures/), opening a fresh loopback data
# listener for every EPSV and handshaking TLS on each data connection
# while PROT P is in force. The child records every command (plus
# "[tls]" / "[data tls]" markers) and sends that transcript back over a
# socketpair, so the tests can assert exactly what crossed the wire and
# in which order (in particular that no credential precedes "[tls]").
import lib.testing
import lib.net
import lib.str
import structures.string
import libs.standard.net.tls
import libs.standard.net.ftp
import lib.mem
import libs.standard.net.testing


# Deterministic binary payload containing NUL, CR and LF bytes.
char* ftps_payload(int n):
	char* data = malloc(n + 1)
	for i in range(n):
		data[i] = (i * 7 + i / 251) & 255
	data[n] = 0
	return data


/* FTPS fixture server (runs in the forked child) */

struct ftps_srv:
	int ctrl
	tls_conn* tls
	char* buf
	int pos
	int len
	int data_listener
	int implicit
	int auth_ok
	int inject
	int require_prot
	int pbsz
	int prot_p
	int logged_in
	string_builder* tr
	char* stored
	int stored_len


tls_conn* ftps_srv_tls_accept(int fd):
	tls_server_config* scfg = tls_server_config_new()
	scfg.cert_chain_path = c"libs/standard/net/tls_fixtures/server_p256_cert.pem"
	scfg.key_path = c"libs/standard/net/tls_fixtures/server_p256_key.pem"
	return tls_accept(fd, scfg)


void ftps_srv_write(ftps_srv* s, char* data, int n):
	if (s.tls != 0):
		tls_write(s.tls, data, n)
		return
	net_test_send_all(s.ctrl, data, n)


void ftps_srv_reply(ftps_srv* s, char* text):
	string_builder* out = string_new()
	string_append(out, text)
	string_append(out, c"\x0d\x0a")
	ftps_srv_write(s, out.data, out.length)
	string_free(out)


# 1 = a byte is buffered. Plaintext is read one byte at a time so the
# server never swallows the start of the client's TLS handshake.
int ftps_srv_fill(ftps_srv* s):
	if (s.pos < s.len):
		return 1
	int got = 0
	if (s.tls != 0):
		got = tls_read(s.tls, s.buf, 4096)
	else:
		got = read(s.ctrl, s.buf, 1)
	if (got <= 0):
		return 0
	s.pos = 0
	s.len = got
	return 1


# One CRLF command line into line; 0 at EOF.
int ftps_srv_read_line(ftps_srv* s, string_builder* line):
	string_clear(line)
	while (ftps_srv_fill(s) != 0):
		int ch = s.buf[s.pos] & 255
		s.pos = s.pos + 1
		if (ch == 10):
			if ((line.length > 0) && ((line.data[line.length - 1] & 255) == 13)):
				line.length = line.length - 1
				line.data[line.length] = 0
			return 1
		string_append_char(line, ch)
	return 0


void ftps_srv_note(ftps_srv* s, char* text):
	string_append(s.tr, text)
	string_append_char(s.tr, 10)


# Accepts the pending data connection and, under PROT P, handshakes TLS
# on it. Returns the fd (-1 on failure, with a 425 already sent).
int ftps_srv_open_transfer(ftps_srv* s, tls_conn** out_tls):
	*out_tls = 0
	if (s.data_listener < 0):
		ftps_srv_reply(s, c"425 Use EPSV first")
		return (-1)
	ftps_srv_reply(s, c"150 Opening data connection")
	int conn = socket_accept_connection(s.data_listener)
	close(s.data_listener)
	s.data_listener = (-1)
	if (conn < 0):
		ftps_srv_reply(s, c"425 Cannot open data connection")
		return (-1)
	socket_set_recv_timeout(conn, 20000)
	if (s.prot_p != 0):
		*out_tls = ftps_srv_tls_accept(conn)
		if (*out_tls == 0):
			ftps_srv_note(s, c"[data tls failed]")
			close(conn)
			ftps_srv_reply(s, c"425 TLS negotiation failed")
			return (-1)
		ftps_srv_note(s, c"[data tls]")
	return conn


# Sends a download; truncate = drop the TCP connection without the TLS
# close_notify (a truncation attack the client must detect).
void ftps_srv_download(ftps_srv* s, char* data, int n, int truncate):
	tls_conn* dt = 0
	int conn = ftps_srv_open_transfer(s, &dt)
	if (conn < 0):
		return
	if (dt != 0):
		tls_write(dt, data, n)
		if (truncate != 0):
			tls_conn_free(dt)
		else:
			tls_close(dt)
	else:
		net_test_send_all(conn, data, n)
	close(conn)
	ftps_srv_reply(s, c"226 Transfer complete")


void ftps_srv_upload(ftps_srv* s):
	tls_conn* dt = 0
	int conn = ftps_srv_open_transfer(s, &dt)
	if (conn < 0):
		return
	string_builder* got = string_new()
	char* chunk = malloc(4096)
	int k = 0
	int clean = 1
	while (1):
		if (dt != 0):
			k = tls_read(dt, chunk, 4096)
		else:
			k = read(conn, chunk, 4096)
		if (k <= 0):
			if (k < 0):
				clean = 0
			break
		string_append_bytes(got, chunk, k)
	free(chunk)
	if (dt != 0):
		tls_conn_free(dt)
	close(conn)
	s.stored = got.data
	s.stored_len = got.length
	free(got)
	if (clean != 0):
		ftps_srv_reply(s, c"226 Transfer complete")
	else:
		ftps_srv_reply(s, c"426 Upload truncated")


# 1 when a transfer may proceed under the server's protection policy.
int ftps_srv_prot_ok(ftps_srv* s):
	if ((s.require_prot != 0) && (s.prot_p == 0)):
		if (s.data_listener >= 0):
			close(s.data_listener)
			s.data_listener = (-1)
		ftps_srv_reply(s, c"521 Data connections must be encrypted")
		return 0
	return 1


# Returns 0 to end the session.
int ftps_srv_handle(ftps_srv* s, char* verb, char* arg):
	if (strcmp(verb, c"AUTH") == 0):
		if ((s.auth_ok == 0) || (s.tls != 0) || (strcmp(arg, c"TLS") != 0)):
			ftps_srv_reply(s, c"534 AUTH TLS not available")
			return 1
		if (s.inject != 0):
			# One write: the forged 230 lands in the client's plaintext
			# buffer together with the 234.
			char* both = c"234 Proceed with negotiation\x0d\x0a230 injected: logged in\x0d\x0a"
			net_test_send_all(s.ctrl, both, strlen(both))
		else:
			ftps_srv_reply(s, c"234 Proceed with negotiation")
		s.tls = ftps_srv_tls_accept(s.ctrl)
		if (s.tls == 0):
			ftps_srv_note(s, c"[tls failed]")
			return 0
		ftps_srv_note(s, c"[tls]")
		s.pos = 0
		s.len = 0
		return 1
	if (strcmp(verb, c"USER") == 0):
		ftps_srv_reply(s, c"331 Password required")
		return 1
	if (strcmp(verb, c"PASS") == 0):
		if (strcmp(arg, c"secret") == 0):
			s.logged_in = 1
			ftps_srv_reply(s, c"230 Logged in")
		else:
			ftps_srv_reply(s, c"530 Login incorrect")
		return 1
	if (strcmp(verb, c"QUIT") == 0):
		ftps_srv_reply(s, c"221 Goodbye")
		return 0
	if (strcmp(verb, c"NOOP") == 0):
		ftps_srv_reply(s, c"200 NOOP ok")
		return 1
	if (strcmp(verb, c"PBSZ") == 0):
		if (s.tls == 0):
			ftps_srv_reply(s, c"503 PBSZ requires AUTH")
		else:
			s.pbsz = 1
			ftps_srv_reply(s, c"200 PBSZ=0")
		return 1
	if (strcmp(verb, c"PROT") == 0):
		if ((s.tls == 0) || (s.pbsz == 0)):
			ftps_srv_reply(s, c"503 PROT requires PBSZ")
		else if (strcmp(arg, c"P") == 0):
			s.prot_p = 1
			ftps_srv_reply(s, c"200 Protection set to Private")
		else if (strcmp(arg, c"C") == 0):
			s.prot_p = 0
			ftps_srv_reply(s, c"200 Protection set to Clear")
		else:
			ftps_srv_reply(s, c"504 Unsupported protection level")
		return 1
	if (s.logged_in == 0):
		ftps_srv_reply(s, c"530 Please login with USER and PASS")
		return 1
	if (strcmp(verb, c"EPSV") == 0):
		if (s.data_listener >= 0):
			close(s.data_listener)
		int port = 0
		s.data_listener = net_test_listen(&port)
		char* text = strjoin(strjoin(c"229 Entering Extended Passive Mode (|||", itoa(port)), c"|)")
		ftps_srv_reply(s, text)
		return 1
	if (strcmp(verb, c"LIST") == 0):
		if (ftps_srv_prot_ok(s) != 0):
			char* listing = c"-rw-r--r-- 1 ftp ftp 13 Sep 25 12:00 hello.txt\x0d\x0a"
			ftps_srv_download(s, listing, strlen(listing), 0)
		return 1
	if (strcmp(verb, c"RETR") == 0):
		if (ftps_srv_prot_ok(s) == 0):
			return 1
		if (strcmp(arg, c"hello.txt") == 0):
			ftps_srv_download(s, c"Hello, FTPS!\x0d\x0a", 14, 0)
		else if (strcmp(arg, c"trunc.bin") == 0):
			ftps_srv_download(s, c"partial", 7, 1)
		else if ((strcmp(arg, c"upload.bin") == 0) && (s.stored != 0)):
			ftps_srv_download(s, s.stored, s.stored_len, 0)
		else:
			if (s.data_listener >= 0):
				close(s.data_listener)
				s.data_listener = (-1)
			ftps_srv_reply(s, c"550 Failed to open file")
		return 1
	if (strcmp(verb, c"STOR") == 0):
		if (ftps_srv_prot_ok(s) != 0):
			ftps_srv_upload(s)
		return 1
	ftps_srv_reply(s, c"502 Command not implemented")
	return 1


void ftps_srv_run(int listener, int pipe_fd, int implicit, int auth_ok, int inject, int require_prot):
	ftps_srv* s = new ftps_srv()
	s.tls = 0
	s.buf = malloc(4096)
	s.pos = 0
	s.len = 0
	s.data_listener = (-1)
	s.implicit = implicit
	s.auth_ok = auth_ok
	s.inject = inject
	s.require_prot = require_prot
	s.pbsz = 0
	s.prot_p = 0
	s.logged_in = 0
	s.tr = string_new()
	s.stored = 0
	s.stored_len = 0
	s.ctrl = socket_accept_connection(listener)
	close(listener)
	if (s.ctrl < 0):
		exit(1)
	socket_set_recv_timeout(s.ctrl, 20000)
	int alive = 1
	if (implicit != 0):
		s.tls = ftps_srv_tls_accept(s.ctrl)
		if (s.tls == 0):
			ftps_srv_note(s, c"[tls failed]")
			alive = 0
		else:
			ftps_srv_note(s, c"[tls]")
	if (alive != 0):
		ftps_srv_reply(s, c"220-W test FTPS server\x0d\x0a220 Ready")
	string_builder* line = string_new()
	while ((alive != 0) && (ftps_srv_read_line(s, line) != 0)):
		ftps_srv_note(s, line.data)
		int sp = 0
		while ((line.data[sp] != 0) && (line.data[sp] != ' ')):
			sp = sp + 1
		char* verb = substring(line.data, 0, sp)
		char* arg = c""
		if (line.data[sp] == ' '):
			arg = line.data + sp + 1
		alive = ftps_srv_handle(s, verb, arg)
		free(verb)
	if (s.tls != 0):
		tls_close(s.tls)
	close(s.ctrl)
	net_test_send_all(pipe_fd, s.tr.data, s.tr.length)
	close(pipe_fd)
	exit(0)


struct ftps_fx:
	int port
	int pid
	int pipe_fd


ftps_fx* ftps_start(int implicit, int auth_ok, int inject, int require_prot):
	ftps_fx* fx = new ftps_fx()
	int port = 0
	int listener = net_test_listen(&port)
	int* fds = malloc(__word_size__ * 2)
	net_test_assert_ok(c"socketpair", socket_pair(fds))
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		close(fds[0])
		ftps_srv_run(listener, fds[1], implicit, auth_ok, inject, require_prot)
	close(fds[1])
	close(listener)
	fx.port = port
	fx.pid = pid
	fx.pipe_fd = fds[0]
	free(cast(char*, fds))
	return fx


# Waits for the child and returns its transcript.
char* ftps_finish(ftps_fx* fx):
	char* result = net_test_read_all(fx.pipe_fd)
	close(fx.pipe_fd)
	int status = 0
	wait4(fx.pid, &status, 0, 0)
	free(cast(char*, fx))
	asserts(c"fixture child failed", status == 0)
	return result


# The fixture cert is self-signed for test.w.example; most tests skip
# chain + hostname checks (the handshake signature and Finished MAC are
# still verified). test_ftps_trust_store covers real validation.
tls_config* ftps_client_config():
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	return cfg


/* Tests */

void test_ftps_explicit_session():
	ftps_fx* fx = ftps_start(0, 1, 0, 1)
	tls_config* cfg = ftps_client_config()
	ftp_client* c = ftp_connect_tls(c"127.0.0.1", fx.port, ftp_security_explicit, cfg, 20000)
	assert_equal(0, c.error)
	asserts(c"control not encrypted", c.tls != 0)
	assert_equal(1, ftp_login(c, c"alice", c"secret"))
	int n = 0
	char* listing = ftp_list(c, 0, &n)
	assert_equal(0, c.error)
	assert_strings_equal(c"-rw-r--r-- 1 ftp ftp 13 Sep 25 12:00 hello.txt\x0d\x0a", listing)
	free(listing)
	char* body = ftp_retr(c, c"hello.txt", &n)
	assert_equal(14, n)
	assert_strings_equal(c"Hello, FTPS!\x0d\x0a", body)
	free(body)
	# A protected upload larger than one TLS record, read back.
	char* want = ftps_payload(40000)
	assert_equal(1, ftp_stor(c, c"upload.bin", want, 40000))
	assert_equal(226, c.reply_code)
	body = ftp_retr(c, c"upload.bin", &n)
	assert_equal(40000, n)
	assert_equal(1, mem_eq(want, body, n))
	free(body)
	free(want)
	assert_equal(1, ftp_quit(c))
	ftp_close(c)
	tls_config_free(cfg)
	assert_strings_equal(c"AUTH TLS\n[tls]\nUSER alice\nPASS secret\nPBSZ 0\nPROT P\nEPSV\nLIST\n[data tls]\nEPSV\nRETR hello.txt\n[data tls]\nEPSV\nSTOR upload.bin\n[data tls]\nEPSV\nRETR upload.bin\n[data tls]\nQUIT\n", ftps_finish(fx))


void test_ftps_implicit_session():
	ftps_fx* fx = ftps_start(1, 0, 0, 0)
	tls_config* cfg = ftps_client_config()
	ftp_client* c = ftp_connect_tls(c"127.0.0.1", fx.port, ftp_security_implicit, cfg, 20000)
	assert_equal(0, c.error)
	assert_equal(220, c.reply_code)
	asserts(c"control not encrypted", c.tls != 0)
	assert_equal(1, ftp_login(c, c"alice", c"secret"))
	# Explicit ftp_prot before the first transfer.
	assert_equal(1, ftp_prot(c, 1))
	int n = 0
	char* body = ftp_retr(c, c"hello.txt", &n)
	assert_strings_equal(c"Hello, FTPS!\x0d\x0a", body)
	free(body)
	assert_equal(1, ftp_stor(c, c"upload.bin", c"implicit upload", 15))
	# PROT C: protected control, clear data (no "[data tls]" after it).
	assert_equal(1, ftp_prot(c, 0))
	body = ftp_retr(c, c"upload.bin", &n)
	assert_strings_equal(c"implicit upload", body)
	free(body)
	# Back to Private: only PROT is re-sent (PBSZ once per session).
	assert_equal(1, ftp_prot(c, 1))
	char* listing = ftp_list(c, 0, &n)
	asserts(c"LIST", listing != 0)
	free(listing)
	# An AUTH TLS on an already protected session is refused locally.
	assert_equal(0, ftp_auth_tls(c, cfg))
	assert_equal(ftp_error_bad_argument(), c.error)
	assert_equal(1, ftp_quit(c))
	ftp_close(c)
	tls_config_free(cfg)
	assert_strings_equal(c"[tls]\nUSER alice\nPASS secret\nPBSZ 0\nPROT P\nEPSV\nRETR hello.txt\n[data tls]\nEPSV\nSTOR upload.bin\n[data tls]\nPROT C\nEPSV\nRETR upload.bin\nPROT P\nEPSV\nLIST\n[data tls]\nQUIT\n", ftps_finish(fx))


void test_ftps_auth_refused_is_fatal():
	ftps_fx* fx = ftps_start(0, 0, 0, 0)
	tls_config* cfg = ftps_client_config()
	ftp_client* c = ftp_connect_tls(c"127.0.0.1", fx.port, ftp_security_explicit, cfg, 20000)
	assert_equal(ftp_error_tls_refused, c.error)
	assert_equal(534, c.reply_code)
	asserts(c"tls set", c.tls == 0)
	# TLS was requested: the session cannot continue in plaintext.
	assert_equal(0, ftp_login(c, c"alice", c"secret"))
	assert_equal(ftp_error_io(), c.error)
	ftp_close(c)
	tls_config_free(cfg)
	assert_strings_equal(c"AUTH TLS\n", ftps_finish(fx))


void test_ftps_auth_refused_plain_session():
	# A caller driving ftp_auth_tls by hand keeps a usable plain session.
	ftps_fx* fx = ftps_start(0, 0, 0, 0)
	ftp_client* c = ftp_connect(c"127.0.0.1", fx.port, 20000)
	assert_equal(0, c.error)
	assert_equal(0, ftp_auth_tls(c, 0))
	assert_equal(ftp_error_tls_refused, c.error)
	# PROT P without TLS fails locally; nothing is sent.
	assert_equal(0, ftp_prot(c, 1))
	assert_equal(ftp_error_tls(), c.error)
	int n = 0
	asserts(c"transfer after failed PROT", ftp_retr(c, c"hello.txt", &n) == 0)
	assert_equal(ftp_error_tls(), c.error)
	assert_equal(1, ftp_prot(c, 0))
	assert_equal(1, ftp_noop(c))
	assert_equal(1, ftp_quit(c))
	ftp_close(c)
	assert_strings_equal(c"AUTH TLS\nNOOP\nQUIT\n", ftps_finish(fx))


void test_ftps_plaintext_injection_rejected():
	ftps_fx* fx = ftps_start(0, 1, 1, 0)
	tls_config* cfg = ftps_client_config()
	ftp_client* c = ftp_connect_tls(c"127.0.0.1", fx.port, ftp_security_explicit, cfg, 20000)
	assert_equal(ftp_error_protocol(), c.error)
	asserts(c"tls set", c.tls == 0)
	assert_equal(0, ftp_login(c, c"alice", c"secret"))
	assert_equal(ftp_error_io(), c.error)
	ftp_close(c)
	tls_config_free(cfg)
	# The client never started a handshake, let alone sent USER/PASS.
	assert_strings_equal(c"AUTH TLS\n[tls failed]\n", ftps_finish(fx))


void test_ftps_default_config_validates():
	# cfg 0: system trust store + hostname check. The self-signed
	# fixture cert (for test.w.example, not 127.0.0.1) must be refused.
	ftps_fx* fx = ftps_start(0, 1, 0, 0)
	ftp_client* c = ftp_connect_tls(c"127.0.0.1", fx.port, ftp_security_explicit, 0, 20000)
	assert_equal(ftp_error_tls(), c.error)
	asserts(c"no TLS reason", strlen(ftp_tls_error(c)) > 0)
	assert_equal(0, ftp_login(c, c"alice", c"secret"))
	assert_equal(ftp_error_io(), c.error)
	ftp_close(c)
	assert_strings_equal(c"AUTH TLS\n[tls failed]\n", ftps_finish(fx))


void test_ftps_manual_auth_tls():
	# ftp_connect + ftp_auth_tls by hand, with a caller-owned config
	# and an explicit certificate name; data connections reuse both.
	# (The fixture leaf is not a CA, so it cannot serve as a trust
	# anchor; test_ftps_default_config_validates covers validation.)
	ftps_fx* fx = ftps_start(0, 1, 0, 1)
	tls_config* cfg = ftps_client_config()
	ftp_client* c = ftp_connect(c"127.0.0.1", fx.port, 20000)
	ftp_set_server_name(c, c"test.w.example")
	assert_equal(1, ftp_auth_tls(c, cfg))
	assert_strings_equal(c"", ftp_tls_error(c))
	assert_equal(1, ftp_login(c, c"alice", c"secret"))
	int n = 0
	char* body = ftp_retr(c, c"hello.txt", &n)
	assert_strings_equal(c"Hello, FTPS!\x0d\x0a", body)
	free(body)
	assert_equal(1, ftp_quit(c))
	ftp_close(c)
	tls_config_free(cfg)
	assert_strings_equal(c"AUTH TLS\n[tls]\nUSER alice\nPASS secret\nPBSZ 0\nPROT P\nEPSV\nRETR hello.txt\n[data tls]\nQUIT\n", ftps_finish(fx))


void test_ftps_truncated_download():
	ftps_fx* fx = ftps_start(1, 0, 0, 1)
	tls_config* cfg = ftps_client_config()
	ftp_client* c = ftp_connect_tls(c"127.0.0.1", fx.port, ftp_security_implicit, cfg, 20000)
	assert_equal(1, ftp_login(c, c"alice", c"secret"))
	int n = 0
	# The data connection closes without close_notify: not a clean EOF.
	asserts(c"truncated RETR accepted", ftp_retr(c, c"trunc.bin", &n) == 0)
	assert_equal(ftp_error_io(), c.error)
	assert_equal(0, n)
	# The completion reply was consumed; the session is still in step.
	assert_equal(1, ftp_noop(c))
	assert_equal(1, ftp_quit(c))
	ftp_close(c)
	tls_config_free(cfg)
	assert_strings_equal(c"[tls]\nUSER alice\nPASS secret\nPBSZ 0\nPROT P\nEPSV\nRETR trunc.bin\n[data tls]\nNOOP\nQUIT\n", ftps_finish(fx))


# Reads what the client wrote on the socketpair's far end.
char* ftps_drain(int fd):
	char* buf = malloc(256)
	int got = read(fd, buf, 255)
	if (got < 0):
		got = 0
	buf[got] = 0
	return buf


void test_ftps_insecure_login_policy():
	int* fds = malloc(2 * __word_size__)
	net_test_assert_ok(c"socketpair", socket_pair(fds))
	socket_set_recv_timeout(fds[0], 2000)
	# A non-loopback peer over plaintext: credentials are withheld.
	ftp_client* c = ftp_attach(fds[0], ip4_from_string(c"192.0.2.1"), 2000)
	assert_equal(0, ftp_login(c, c"alice", c"secret"))
	assert_equal(ftp_error_insecure, c.error)
	# The anonymous convention is not a secret and is allowed.
	net_test_send_all(fds[1], c"230 ok\x0d\x0a", 8)
	assert_equal(1, ftp_login(c, c"Anonymous", c"guest@"))
	char* sent = ftps_drain(fds[1])
	assert_strings_equal(c"USER Anonymous\x0d\x0a", sent)
	free(sent)
	assert_equal(1, ftp_is_anonymous_user(c"ftp"))
	assert_equal(0, ftp_is_anonymous_user(c"ftpuser"))
	assert_equal(0, ftp_is_anonymous_user(c"anon"))
	# Explicit opt-in sends them.
	ftp_set_allow_insecure_login(c, 1)
	net_test_send_all(fds[1], c"230 ok\x0d\x0a", 8)
	assert_equal(1, ftp_login(c, c"alice", c"secret"))
	sent = ftps_drain(fds[1])
	assert_strings_equal(c"USER alice\x0d\x0a", sent)
	free(sent)
	ftp_close(c)
	close(fds[1])
	free(fds)
