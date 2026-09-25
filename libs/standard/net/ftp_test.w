# wbuild: x64
# Offline tests for libs/standard/net/ftp.w (issue #436). The session
# tests run against a forked pure-W scripted FTP server on loopback
# (the libs/standard/web/http_client_test.w pattern): the parent binds
# the control listener before forking so it knows the port, the child
# serves one session (opening a fresh loopback data listener for every
# EPSV/PASV), and the parent drives the client and asserts. The child
# exits nonzero when it sees something a correct client never sends
# (an injected command, a second EPSV after a rejection), and the
# parent checks that exit status. Reply-parser tests need no server:
# they feed canned bytes through a socketpair.
import lib.testing
import lib.net
import lib.str
import structures.string
import libs.standard.net.ftp
import lib.mem
import libs.standard.net.testing


# Deterministic binary payload containing NUL, CR and LF bytes.
char* ftp_test_big_payload(int n):
	char* data = malloc(n + 1)
	int i = 0
	while (i < n):
		data[i] = (i * 7 + i / 251) & 255
		i = i + 1
	data[n] = 0
	return data


int ftp_test_big_size():
	return 200000


/* Scripted fixture server (runs in the forked child) */

struct ftp_srv:
	int ctrl
	int data_listener
	int epsv_ok
	int epsv_count
	int pasv_count
	int bad
	int logged_in
	char* user
	char* rename_from
	char* stored
	int stored_len


void ftp_srv_reply(ftp_srv* s, char* text):
	net_test_send_all(s.ctrl, text, strlen(text))
	net_test_send_all(s.ctrl, c"\x0d\x0a", 2)


# Reads one CRLF command line into a fresh string; 0 on EOF.
char* ftp_srv_read_line(int fd):
	string_builder* line = string_new()
	char* one = malloc(1)
	while (1):
		int got = read(fd, one, 1)
		if (got <= 0):
			string_free(line)
			free(one)
			return 0
		if (one[0] == 10):
			break
		string_append_char(line, one[0] & 255)
	free(one)
	if ((line.length > 0) && (line.data[line.length - 1] == 13)):
		line.length = line.length - 1
		line.data[line.length] = 0
	char* text = line.data
	free(line)
	return text


# Opens a loopback data listener for the next transfer; returns its port.
int ftp_srv_open_data(ftp_srv* s):
	if (s.data_listener >= 0):
		close(s.data_listener)
	int port = 0
	s.data_listener = net_test_listen(&port)
	return port


# Accepts the pending passive data connection (-1 when none was set up).
int ftp_srv_accept_data(ftp_srv* s):
	if (s.data_listener < 0):
		return (-1)
	int conn = socket_accept_connection(s.data_listener)
	close(s.data_listener)
	s.data_listener = (-1)
	return conn


void ftp_srv_drop_data(ftp_srv* s):
	if (s.data_listener >= 0):
		close(s.data_listener)
		s.data_listener = (-1)


# Sends a download over a fresh data connection with 150/226 framing.
void ftp_srv_send_download(ftp_srv* s, char* data, int n):
	if (s.data_listener < 0):
		ftp_srv_reply(s, c"425 Use PASV or EPSV first")
		return
	ftp_srv_reply(s, c"150 Opening BINARY mode data connection")
	int conn = ftp_srv_accept_data(s)
	if (conn < 0):
		ftp_srv_reply(s, c"425 Cannot open data connection")
		return
	int sent = 0
	int ok = 1
	while (sent < n):
		int got = socket_send(conn, data + sent, n - sent, msg_nosignal())
		if (got <= 0):
			ok = 0
			break
		sent = sent + got
	close(conn)
	if (ok != 0):
		ftp_srv_reply(s, c"226 Transfer complete")
	else:
		ftp_srv_reply(s, c"426 Connection closed; transfer aborted")


char* ftp_srv_file(ftp_srv* s, char* name, int* out_len):
	if (strcmp(name, c"hello.txt") == 0):
		*out_len = 13
		return c"Hello, FTP!\x0d\x0a"
	if (strcmp(name, c"big.bin") == 0):
		*out_len = ftp_test_big_size()
		return ftp_test_big_payload(ftp_test_big_size())
	if ((s.stored != 0) && (strcmp(name, c"upload.bin") == 0)):
		*out_len = s.stored_len
		return s.stored
	return 0


void ftp_srv_handle(ftp_srv* s, char* verb, char* arg):
	# Anything that smells of the CRLF-injection payload is fatal.
	if ((net_test_contains(verb, c"EVIL") != 0) || (net_test_contains(arg, c"EVIL") != 0)):
		s.bad = 3
	if (strcmp(verb, c"USER") == 0):
		if (s.user != 0):
			free(s.user)
		s.user = strclone(arg)
		if (strcmp(arg, c"root") == 0):
			ftp_srv_reply(s, c"530 Not allowed")
		else:
			ftp_srv_reply(s, c"331 Password required")
		return
	if (strcmp(verb, c"PASS") == 0):
		if (s.user == 0):
			ftp_srv_reply(s, c"503 Login with USER first")
		else if (strcmp(s.user, c"anonymous") == 0):
			s.logged_in = 1
			ftp_srv_reply(s, c"230-Welcome, anonymous.\x0d\x0a230-Be nice.\x0d\x0a230 Logged in.")
		else if ((strcmp(s.user, c"alice") == 0) && (strcmp(arg, c"secret") == 0)):
			s.logged_in = 1
			ftp_srv_reply(s, c"230 User alice logged in")
		else:
			ftp_srv_reply(s, c"530 Login incorrect")
		return
	if (strcmp(verb, c"QUIT") == 0):
		ftp_srv_reply(s, c"221 Goodbye")
		return
	if (s.logged_in == 0):
		ftp_srv_reply(s, c"530 Please login with USER and PASS")
		return
	if (strcmp(verb, c"TYPE") == 0):
		if ((strcmp(arg, c"I") == 0) || (strcmp(arg, c"A") == 0)):
			ftp_srv_reply(s, c"200 Type set")
		else:
			ftp_srv_reply(s, c"504 Type not supported")
	else if (strcmp(verb, c"PWD") == 0):
		ftp_srv_reply(s, c"257 \"/home/a \"\"quoted\"\" dir\" is the current directory")
	else if (strcmp(verb, c"CWD") == 0):
		if (strcmp(arg, c"pub") == 0):
			ftp_srv_reply(s, c"250 Directory changed")
		else:
			ftp_srv_reply(s, c"550 No such directory")
	else if (strcmp(verb, c"CDUP") == 0):
		ftp_srv_reply(s, c"200 OK")
	else if (strcmp(verb, c"MKD") == 0):
		ftp_srv_reply(s, c"257 \"/newdir\" created")
	else if (strcmp(verb, c"RMD") == 0):
		ftp_srv_reply(s, c"250 Directory removed")
	else if (strcmp(verb, c"DELE") == 0):
		if (strcmp(arg, c"hello.txt") == 0):
			ftp_srv_reply(s, c"250 Deleted")
		else:
			ftp_srv_reply(s, c"550 No such file")
	else if (strcmp(verb, c"RNFR") == 0):
		if (s.rename_from != 0):
			free(s.rename_from)
		s.rename_from = strclone(arg)
		ftp_srv_reply(s, c"350 Ready for RNTO")
	else if (strcmp(verb, c"RNTO") == 0):
		if ((s.rename_from != 0) && (strcmp(s.rename_from, c"old.txt") == 0) && (strcmp(arg, c"new.txt") == 0)):
			ftp_srv_reply(s, c"250 Renamed")
		else:
			ftp_srv_reply(s, c"503 Bad sequence")
		if (s.rename_from != 0):
			free(s.rename_from)
		s.rename_from = 0
	else if (strcmp(verb, c"SIZE") == 0):
		int n = 0
		char* body = ftp_srv_file(s, arg, &n)
		if (body == 0):
			ftp_srv_reply(s, c"550 No such file")
		else:
			char* text = strjoin(c"213 ", itoa(n))
			ftp_srv_reply(s, text)
	else if (strcmp(verb, c"MDTM") == 0):
		ftp_srv_reply(s, c"213 20260925120304")
	else if (strcmp(verb, c"NOOP") == 0):
		ftp_srv_reply(s, c"200 NOOP ok")
	else if (strcmp(verb, c"EPSV") == 0):
		s.epsv_count = s.epsv_count + 1
		if (s.epsv_ok == 0):
			ftp_srv_reply(s, c"500 EPSV not understood")
		else:
			int port = ftp_srv_open_data(s)
			char* text = strjoin(strjoin(c"229 Entering Extended Passive Mode (|||", itoa(port)), c"|)")
			ftp_srv_reply(s, text)
	else if (strcmp(verb, c"PASV") == 0):
		s.pasv_count = s.pasv_count + 1
		int pport = ftp_srv_open_data(s)
		# Advertise an unroutable TEST-NET host: a client that honoured
		# it (instead of the control peer) could never connect.
		string_builder* out = string_new()
		string_append(out, c"227 Entering Passive Mode (192,0,2,99,")
		string_append_int(out, pport / 256)
		string_append_char(out, ',')
		string_append_int(out, pport % 256)
		string_append(out, c").")
		ftp_srv_reply(s, out.data)
		string_free(out)
	else if ((strcmp(verb, c"LIST") == 0) || (strcmp(verb, c"NLST") == 0) || (strcmp(verb, c"MLSD") == 0)):
		char* listing = c"hello.txt\x0d\x0abig.bin\x0d\x0a"
		if (strcmp(verb, c"LIST") == 0):
			listing = c"-rw-r--r-- 1 ftp ftp 13 Sep 25 12:00 hello.txt\x0d\x0a-rw-r--r-- 1 ftp ftp 200000 Sep 25 12:00 big.bin\x0d\x0a"
		if (strcmp(verb, c"MLSD") == 0):
			listing = c"type=file;size=13; hello.txt\x0d\x0atype=file;size=200000; big.bin\x0d\x0a"
		if ((arg != 0) && (arg[0] != 0) && (strcmp(arg, c"pub") != 0)):
			ftp_srv_drop_data(s)
			ftp_srv_reply(s, c"550 No such directory")
		else:
			ftp_srv_send_download(s, listing, strlen(listing))
	else if (strcmp(verb, c"RETR") == 0):
		int rn = 0
		char* rbody = ftp_srv_file(s, arg, &rn)
		if (rbody == 0):
			ftp_srv_drop_data(s)
			ftp_srv_reply(s, c"550 Failed to open file")
		else:
			ftp_srv_send_download(s, rbody, rn)
	else if ((strcmp(verb, c"STOR") == 0) || (strcmp(verb, c"APPE") == 0)):
		if (strcmp(arg, c"upload.bin") != 0):
			ftp_srv_drop_data(s)
			ftp_srv_reply(s, c"553 Permission denied")
			return
		ftp_srv_reply(s, c"150 Ok to send data")
		int conn = ftp_srv_accept_data(s)
		if (conn < 0):
			ftp_srv_reply(s, c"425 Cannot open data connection")
			return
		string_builder* got = string_new()
		if ((strcmp(verb, c"APPE") == 0) && (s.stored != 0)):
			string_append_bytes(got, s.stored, s.stored_len)
		char* chunk = malloc(4096)
		int k = read(conn, chunk, 4096)
		while (k > 0):
			string_append_bytes(got, chunk, k)
			k = read(conn, chunk, 4096)
		free(chunk)
		close(conn)
		s.stored = got.data
		s.stored_len = got.length
		free(got)
		ftp_srv_reply(s, c"226 Transfer complete")
	else:
		ftp_srv_reply(s, c"502 Command not implemented")


# Serves one control connection until QUIT or EOF, then exits the
# child: 0 when the client behaved, else the recorded failure code.
void ftp_srv_run(int listener, int epsv_ok):
	ftp_srv* s = new ftp_srv()
	s.data_listener = (-1)
	s.epsv_count = 0
	s.pasv_count = 0
	s.bad = 0
	s.logged_in = 0
	s.user = 0
	s.rename_from = 0
	s.stored = 0
	s.stored_len = 0
	s.epsv_ok = epsv_ok
	s.ctrl = socket_accept_connection(listener)
	if (s.ctrl < 0):
		exit(1)
	# Multi-line greeting whose middle lines look like replies.
	ftp_srv_reply(s, c"220-W test FTP server\x0d\x0a220-still greeting\x0d\x0a 220 indented, not the end\x0d\x0a123 other code, not the end\x0d\x0a220 Ready")
	while (1):
		char* line = ftp_srv_read_line(s.ctrl)
		if (line == 0):
			break
		int sp = 0
		while ((line[sp] != 0) && (line[sp] != ' ')):
			sp = sp + 1
		char* verb = substring(line, 0, sp)
		char* arg = c""
		if (line[sp] == ' '):
			arg = line + sp + 1
		ftp_srv_handle(s, verb, arg)
		int quit = strcmp(verb, c"QUIT") == 0
		free(verb)
		free(line)
		if (quit != 0):
			break
	if ((s.epsv_ok == 0) && (s.epsv_count > 1)):
		# The client must stop trying EPSV after the first rejection.
		s.bad = 4
	close(s.ctrl)
	exit(s.bad)


int ftp_test_spawn(int* out_port, int epsv_ok, int* out_listener):
	int listener = net_test_listen(out_port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		ftp_srv_run(listener, epsv_ok)
		exit(0)
	*out_listener = listener
	return pid


/* Wire-free parser coverage */

void test_ftp_parse_epsv():
	assert_equal(6446, ftp_parse_epsv_reply(c"229 Entering Extended Passive Mode (|||6446|)"))
	assert_equal(21, ftp_parse_epsv_reply(c"229 ok (!!!21!)"))
	assert_equal((-1), ftp_parse_epsv_reply(c"229 no parens |||6446|"))
	assert_equal((-1), ftp_parse_epsv_reply(c"229 (|||0|)"))
	assert_equal((-1), ftp_parse_epsv_reply(c"229 (|||65536|)"))
	assert_equal((-1), ftp_parse_epsv_reply(c"229 (|||123456|)"))
	assert_equal((-1), ftp_parse_epsv_reply(c"229 (||||)"))
	assert_equal((-1), ftp_parse_epsv_reply(c"229 (|||80!)"))
	assert_equal((-1), ftp_parse_epsv_reply(c"229 (|1|2|80|)"))
	assert_equal((-1), ftp_parse_epsv_reply(c"229 (|||80|"))


void test_ftp_parse_pasv():
	int host = 0
	assert_equal(1025, ftp_parse_pasv_reply(c"227 Entering Passive Mode (192,168,1,2,4,1).", &host))
	assert_equal(ip4_from_string(c"192.168.1.2"), host)
	# Parentheses are optional in practice.
	assert_equal(65535, ftp_parse_pasv_reply(c"227 =10,0,0,1,255,255", &host))
	assert_equal(ip4_from_string(c"10.0.0.1"), host)
	assert_equal((-1), ftp_parse_pasv_reply(c"227 (1,2,3,4,5)", &host))
	assert_equal((-1), ftp_parse_pasv_reply(c"227 (1,2,3,256,5,6)", &host))
	assert_equal((-1), ftp_parse_pasv_reply(c"227 (1,2,3,4,0,0)", &host))
	assert_equal((-1), ftp_parse_pasv_reply(c"227 (1,2,3,4,1000,1)", &host))
	assert_equal((-1), ftp_parse_pasv_reply(c"227 nothing here", &host))
	assert_equal((-1), ftp_parse_pasv_reply(c"22", &host))


void test_ftp_parse_pwd():
	char* dir = ftp_parse_pwd_reply(c"257 \"/home/a \"\"quoted\"\" dir\" is current")
	assert_strings_equal(c"/home/a \"quoted\" dir", dir)
	free(dir)
	dir = ftp_parse_pwd_reply(c"257 \"/\"")
	assert_strings_equal(c"/", dir)
	free(dir)
	asserts(c"unterminated accepted", ftp_parse_pwd_reply(c"257 \"/abc") == 0)
	asserts(c"unquoted accepted", ftp_parse_pwd_reply(c"257 /abc") == 0)


void test_ftp_argument_validation():
	assert_equal(1, ftp_valid_argument(c"file name.txt"))
	assert_equal(0, ftp_valid_argument(c"a\x0d\x0aDELE b"))
	assert_equal(0, ftp_valid_argument(c"a\x0ab"))
	assert_equal(0, ftp_valid_argument(c"a\x0db"))
	assert_equal(0, ftp_valid_argument(c""))
	assert_equal(0, ftp_valid_argument(0))
	char* longarg = malloc(ftp_max_argument() + 2)
	int i = 0
	while (i < ftp_max_argument() + 1):
		longarg[i] = 'a'
		i = i + 1
	longarg[i] = 0
	assert_equal(0, ftp_valid_argument(longarg))
	longarg[ftp_max_argument()] = 0
	assert_equal(1, ftp_valid_argument(longarg))
	free(longarg)
	assert_equal(1, ftp_valid_verb(c"NOOP"))
	assert_equal(0, ftp_valid_verb(c"NO OP"))
	assert_equal(0, ftp_valid_verb(c"LIST\x0d\x0aDELE"))
	assert_equal(0, ftp_valid_verb(c""))
	assert_equal(0, ftp_valid_verb(c"TOOLONGVERB"))


void test_ftp_error_strings():
	assert_strings_equal(c"", ftp_error_string(ftp_error_none()))
	assert_strings_equal(c"timed out", ftp_error_string(ftp_error_timeout()))
	assert_strings_equal(c"invalid argument", ftp_error_string(ftp_error_bad_argument()))
	assert_strings_equal(c"unknown error", ftp_error_string(999))


/* Reply parsing over a socketpair */

# Client attached to one end of a socketpair; fds[1] is the "server".
ftp_client* ftp_test_pair_client(int* fds, int timeout_ms):
	net_test_assert_ok(c"socketpair", socket_pair(fds))
	socket_set_recv_timeout(fds[0], timeout_ms)
	return ftp_attach(fds[0], ip4_from_string(c"127.0.0.1"), timeout_ms)


void ftp_test_feed(int fd, char* text):
	net_test_send_all(fd, text, strlen(text))


void test_ftp_reply_multiline():
	int* fds = malloc(2 * __word_size__)
	ftp_client* c = ftp_test_pair_client(fds, 2000)
	ftp_test_feed(fds[1], c"211-Features:\x0d\x0a EPSV\x0d\x0a211-not the end\x0d\x0a212 other code\x0d\x0a211 End\x0d\x0a200 single\x0d\x0a226 bare-LF line\x0a")
	assert_equal(211, ftp_read_reply(c))
	assert_strings_equal(c"211-Features:\x0a EPSV\x0a211-not the end\x0a212 other code\x0a211 End", c.reply_text.data)
	assert_equal(200, ftp_read_reply(c))
	assert_strings_equal(c"200 single", c.reply_text.data)
	assert_equal(226, ftp_read_reply(c))
	assert_strings_equal(c"226 bare-LF line", c.reply_text.data)
	assert_equal(0, c.error)
	# A malformed code breaks the session for good.
	ftp_test_feed(fds[1], c"hello\x0d\x0a")
	assert_equal((-1), ftp_read_reply(c))
	assert_equal(ftp_error_protocol(), c.error)
	assert_equal(0, ftp_noop(c))
	assert_equal(ftp_error_io(), c.error)
	ftp_close(c)
	close(fds[1])
	free(fds)


void test_ftp_reply_bad_codes():
	int* fds = malloc(2 * __word_size__)
	ftp_client* c = ftp_test_pair_client(fds, 2000)
	ftp_test_feed(fds[1], c"600 out of range\x0d\x0a")
	assert_equal((-1), ftp_read_reply(c))
	assert_equal(ftp_error_protocol(), c.error)
	ftp_close(c)
	close(fds[1])
	c = ftp_test_pair_client(fds, 2000)
	ftp_test_feed(fds[1], c"200x glued\x0d\x0a")
	assert_equal((-1), ftp_read_reply(c))
	assert_equal(ftp_error_protocol(), c.error)
	ftp_close(c)
	close(fds[1])
	free(fds)


void test_ftp_reply_line_cap():
	int* fds = malloc(2 * __word_size__)
	ftp_client* c = ftp_test_pair_client(fds, 2000)
	int n = ftp_max_line() + 100
	char* big = malloc(n + 1)
	mem_fill(big, 'x', n)
	big[0] = '2'
	big[1] = '0'
	big[2] = '0'
	big[3] = ' '
	big[n] = 0
	ftp_test_feed(fds[1], big)
	ftp_test_feed(fds[1], c"\x0d\x0a")
	assert_equal((-1), ftp_read_reply(c))
	assert_equal(ftp_error_overflow(), c.error)
	free(big)
	ftp_close(c)
	close(fds[1])
	free(fds)


void test_ftp_reply_timeout():
	int* fds = malloc(2 * __word_size__)
	ftp_client* c = ftp_test_pair_client(fds, 200)
	ftp_test_feed(fds[1], c"220-partial multi-line reply\x0d\x0a")
	assert_equal((-1), ftp_read_reply(c))
	assert_equal(ftp_error_timeout(), c.error)
	ftp_close(c)
	close(fds[1])
	free(fds)


void test_ftp_reply_eof():
	int* fds = malloc(2 * __word_size__)
	ftp_client* c = ftp_test_pair_client(fds, 2000)
	ftp_test_feed(fds[1], c"421 closing")
	close(fds[1])
	assert_equal((-1), ftp_read_reply(c))
	assert_equal(ftp_error_io(), c.error)
	ftp_close(c)
	free(fds)


/* End-to-end sessions against the forked fixture server */

void test_ftp_session_epsv():
	int port = 0
	int listener = 0
	int pid = ftp_test_spawn(&port, 1, &listener)
	ftp_client* c = ftp_connect(c"127.0.0.1", port, 5000)
	assert_equal(0, c.error)
	assert_equal(220, c.reply_code)
	asserts(c"greeting text", net_test_contains(c.reply_text.data, c"123 other code, not the end") != 0)

	# Wrong password: a 530 reply leaves the session usable.
	assert_equal(0, ftp_login(c, c"alice", c"wrong"))
	assert_equal(ftp_error_reply(), c.error)
	assert_equal(530, c.reply_code)
	assert_equal(1, ftp_login(c, c"alice", c"secret"))
	assert_equal(230, c.reply_code)

	char* dir = ftp_pwd(c)
	assert_strings_equal(c"/home/a \"quoted\" dir", dir)
	free(dir)
	assert_equal(1, ftp_cwd(c, c"pub"))
	assert_equal(0, ftp_cwd(c, c"missing"))
	assert_equal(550, c.reply_code)
	assert_equal(1, ftp_cdup(c))
	assert_equal(1, ftp_type_ascii(c))
	assert_equal(1, ftp_type_binary(c))
	assert_equal(1, ftp_mkd(c, c"newdir"))
	assert_equal(257, c.reply_code)
	assert_equal(1, ftp_rmd(c, c"newdir"))
	assert_equal(1, ftp_delete(c, c"hello.txt"))
	assert_equal(0, ftp_delete(c, c"nope.txt"))
	assert_equal(550, c.reply_code)
	assert_equal(1, ftp_rename(c, c"old.txt", c"new.txt"))
	assert_equal(13, ftp_size(c, c"hello.txt"))
	assert_equal((-1), ftp_size(c, c"nope.txt"))
	assert_equal(ftp_error_reply(), c.error)
	char* stamp = ftp_mdtm(c, c"hello.txt")
	assert_strings_equal(c"20260925120304", stamp)
	free(stamp)
	assert_equal(1, ftp_noop(c))
	assert_equal(502, ftp_command(c, c"SITE", c"CHMOD 644 x"))

	int n = 0
	char* listing = ftp_list(c, 0, &n)
	assert_equal(0, c.error)
	asserts(c"LIST content", net_test_contains(listing, c"-rw-r--r-- 1 ftp ftp 13 Sep 25 12:00 hello.txt\x0d\x0a") != 0)
	assert_equal(strlen(listing), n)
	assert_equal(226, c.reply_code)
	free(listing)
	listing = ftp_nlst(c, c"pub", &n)
	assert_strings_equal(c"hello.txt\x0d\x0abig.bin\x0d\x0a", listing)
	free(listing)
	listing = ftp_mlsd(c, 0, &n)
	asserts(c"MLSD content", net_test_contains(listing, c"type=file;size=13; hello.txt") != 0)
	free(listing)
	# A 550 in place of the 150 preliminary reply.
	asserts(c"LIST of missing dir", ftp_list(c, c"missing", &n) == 0)
	assert_equal(ftp_error_reply(), c.error)
	assert_equal(550, c.reply_code)

	char* body = ftp_retr(c, c"hello.txt", &n)
	assert_strings_equal(c"Hello, FTP!\x0d\x0a", body)
	assert_equal(13, n)
	free(body)
	body = ftp_retr(c, c"big.bin", &n)
	assert_equal(ftp_test_big_size(), n)
	char* want = ftp_test_big_payload(ftp_test_big_size())
	assert_equal(1, mem_eq(want, body, n))
	free(body)
	asserts(c"RETR missing", ftp_retr(c, c"nope.txt", &n) == 0)
	assert_equal(550, c.reply_code)
	assert_equal(0, n)

	# Upload, append, then read the result back.
	assert_equal(1, ftp_stor(c, c"upload.bin", want, 70000))
	assert_equal(226, c.reply_code)
	assert_equal(1, ftp_appe(c, c"upload.bin", want + 70000, 130000))
	assert_equal(ftp_test_big_size(), ftp_size(c, c"upload.bin"))
	body = ftp_retr(c, c"upload.bin", &n)
	assert_equal(ftp_test_big_size(), n)
	assert_equal(1, mem_eq(want, body, n))
	free(body)
	assert_equal(0, ftp_stor(c, c"denied.bin", c"x", 1))
	assert_equal(553, c.reply_code)
	# An empty upload is legal.
	assert_equal(1, ftp_stor(c, c"upload.bin", 0, 0))
	assert_equal(0, ftp_size(c, c"upload.bin"))

	# RETR streamed into a descriptor.
	int* pair = malloc(2 * __word_size__)
	net_test_assert_ok(c"socketpair", socket_pair(pair))
	assert_equal(13, ftp_retr_fd(c, c"hello.txt", pair[1]))
	char* got = malloc(32)
	assert_equal(13, read(pair[0], got, 32))
	assert_equal(1, mem_eq(c"Hello, FTP!\x0d\x0a", got, 13))
	free(got)
	close(pair[0])
	close(pair[1])
	free(pair)

	# Buffered transfer over the cap: fails, consumes the reply, and the
	# session keeps working.
	ftp_set_max_transfer(c, 1000)
	asserts(c"capped RETR", ftp_retr(c, c"big.bin", &n) == 0)
	assert_equal(ftp_error_overflow(), c.error)
	ftp_set_max_transfer(c, ftp_default_max_transfer())
	assert_equal(1, ftp_noop(c))
	free(want)

	assert_equal(1, ftp_quit(c))
	assert_equal(221, c.reply_code)
	assert_equal(0, ftp_noop(c))
	ftp_close(c)
	net_test_finish(pid, listener)


void test_ftp_session_pasv_fallback():
	int port = 0
	int listener = 0
	int pid = ftp_test_spawn(&port, 0, &listener)
	ftp_client* c = ftp_connect(c"127.0.0.1", port, 5000)
	assert_equal(0, c.error)
	assert_equal(1, ftp_login_anonymous(c))
	# The multi-line 230 reply arrives whole.
	assert_strings_equal(c"230-Welcome, anonymous.\x0a230-Be nice.\x0a230 Logged in.", c.reply_text.data)
	int n = 0
	# The PASV reply advertises 192.0.2.99; the client must still dial
	# the control peer (127.0.0.1) or these transfers would fail.
	char* body = ftp_retr(c, c"hello.txt", &n)
	assert_strings_equal(c"Hello, FTP!\x0d\x0a", body)
	free(body)
	assert_equal(0, c.use_epsv)
	char* listing = ftp_nlst(c, 0, &n)
	assert_strings_equal(c"hello.txt\x0d\x0abig.bin\x0d\x0a", listing)
	free(listing)
	assert_equal(1, ftp_stor(c, c"upload.bin", c"pasv upload", 11))
	body = ftp_retr(c, c"upload.bin", &n)
	assert_strings_equal(c"pasv upload", body)
	free(body)
	assert_equal(1, ftp_quit(c))
	ftp_close(c)
	# The child exits 4 if EPSV was retried after the first 500.
	net_test_finish(pid, listener)


void test_ftp_pasv_only_mode():
	int port = 0
	int listener = 0
	int pid = ftp_test_spawn(&port, 0, &listener)
	ftp_client* c = ftp_connect(c"127.0.0.1", port, 5000)
	ftp_set_epsv(c, 0)
	assert_equal(1, ftp_login(c, c"alice", c"secret"))
	int n = 0
	char* body = ftp_retr(c, c"hello.txt", &n)
	assert_equal(13, n)
	free(body)
	assert_equal(1, ftp_quit(c))
	ftp_close(c)
	net_test_finish(pid, listener)


void test_ftp_crlf_injection_rejected():
	int port = 0
	int listener = 0
	int pid = ftp_test_spawn(&port, 1, &listener)
	ftp_client* c = ftp_connect(c"127.0.0.1", port, 5000)
	# Injection through the user name, password, and every path taker.
	assert_equal(0, ftp_login(c, c"alice\x0d\x0aDELE EVIL", c"secret"))
	assert_equal(ftp_error_bad_argument(), c.error)
	assert_equal(0, ftp_login(c, c"alice", c"secret\x0aDELE EVIL"))
	assert_equal(ftp_error_bad_argument(), c.error)
	# The failed PASS left the server waiting for a password; log in.
	assert_equal(1, ftp_login(c, c"alice", c"secret"))
	assert_equal(0, ftp_cwd(c, c"pub\x0d\x0aDELE EVIL"))
	assert_equal(ftp_error_bad_argument(), c.error)
	assert_equal(0, ftp_delete(c, c"x\x0dDELE EVIL"))
	assert_equal(0, ftp_mkd(c, c"d\x0aRMD EVIL"))
	assert_equal(0, ftp_rename(c, c"old.txt", c"new.txt\x0d\x0aDELE EVIL"))
	assert_equal(ftp_error_bad_argument(), c.error)
	assert_equal((-1), ftp_size(c, c"a\x0d\x0aDELE EVIL"))
	int n = 0
	asserts(c"RETR injected", ftp_retr(c, c"hello.txt\x0d\x0aDELE EVIL", &n) == 0)
	assert_equal(ftp_error_bad_argument(), c.error)
	asserts(c"LIST injected", ftp_list(c, c"pub\x0aDELE EVIL", &n) == 0)
	assert_equal(0, ftp_stor(c, c"upload.bin\x0d\x0aDELE EVIL", c"x", 1))
	assert_equal(ftp_error_bad_argument(), c.error)
	assert_equal((-1), ftp_command(c, c"NOOP\x0d\x0aDELE", c"EVIL"))
	assert_equal((-1), ftp_command(c, c"SITE", c"x\x0d\x0aDELE EVIL"))
	assert_equal(ftp_error_bad_argument(), c.error)
	# Nothing reached the wire: the control connection is still in step.
	assert_equal(1, ftp_noop(c))
	assert_equal(200, c.reply_code)
	assert_equal(1, ftp_quit(c))
	ftp_close(c)
	# The child exits 3 if any EVIL command arrived.
	net_test_finish(pid, listener)


void test_ftp_connect_failures():
	# Nothing listens on a just-closed ephemeral port.
	int port = 0
	int listener = net_test_listen(&port)
	close(listener)
	ftp_client* c = ftp_connect(c"127.0.0.1", port, 2000)
	assert_equal(ftp_error_connect(), c.error)
	assert_equal(0, ftp_noop(c))
	assert_equal(ftp_error_io(), c.error)
	ftp_close(c)
	c = ftp_connect(0, 21, 2000)
	assert_equal(ftp_error_resolve(), c.error)
	ftp_close(c)
