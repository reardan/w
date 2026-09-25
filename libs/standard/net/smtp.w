# SMTP client (RFC 5321) plus a small RFC 5322 / MIME message builder
# for the pure-W network stack (issue #436, "Protocols").
#
# Transport: plaintext, STARTTLS (RFC 3207) or implicit TLS ("SMTPS",
# port 465, RFC 8314), all over libs/standard/net/tls.w, whose
# tls_connect wraps an already-connected socket. Certificate validation
# is on by default; pass a tls_config to override the trust store (or,
# in tests only, set its insecure_skip_verify).
#
# Public API -- client:
#   smtp_client* smtp_open(char* host, int port, int security,
#                          tls_config* cfg, char* ehlo_domain,
#                          int timeout_ms)       never returns 0
#   smtp_client* smtp_client_from_fd(int fd, char* server_name)
#   int  smtp_start(smtp_client* c, int security, tls_config* cfg,
#                   char* ehlo_domain)           greeting + EHLO (+TLS)
#   int  smtp_greeting(c) / smtp_ehlo(c, domain) / smtp_starttls(c, cfg)
#   int  smtp_auth(c, user, pass)                PLAIN, else LOGIN
#   int  smtp_auth_plain(c, user, pass) / smtp_auth_login(c, user, pass)
#   int  smtp_mail_from(c, addr, size) / smtp_rcpt_to(c, addr)
#   int  smtp_data(c, char* msg, int len)        dot-stuffed, CRLF'd
#   int  smtp_rset(c) / smtp_noop(c) / smtp_quit(c)
#   int  smtp_command(c, char* line)             raw verb: reply code or -1
#   int  smtp_send(c, from, list[char*] rcpts, msg, len)
#                                                accepted rcpt count or 0
#   int  smtp_send_message(c, smtp_message* m)   same, builds m first
#   void smtp_close(smtp_client* c)              closes TLS + fd, frees
#   int  smtp_error(c) / char* smtp_error_message(c)
#   int  smtp_last_code(c) / char* smtp_last_reply(c)
#   void smtp_set_allow_insecure_auth(c, int allow)
#   smtp_security_none() / smtp_security_starttls() / smtp_security_implicit()
#   smtp_error_none/io/protocol/rejected/invalid/tls/unsupported/
#     insecure/too_large()
#
# Public API -- message builder:
#   smtp_message* smtp_message_new()
#   void smtp_message_set_from(m, addr, name)    name may be 0
#   void smtp_message_add_to / add_cc(m, addr, name) / add_bcc(m, addr)
#   void smtp_message_set_subject(m, s) / set_text(m, s) / set_html(m, s)
#   void smtp_message_set_date(m, unix) / set_message_id(m, "<id@host>")
#   void smtp_message_set_boundary(m, b)         tests: fixed boundary
#   char* smtp_message_build(m, int* out_len)    0 on invalid input
#   list[char*] smtp_message_recipients(m)       envelope: to + cc + bcc
#   void smtp_message_free(m)
#   char* smtp_encode_word(char* text)           RFC 2047 encoded-word(s)
#   char* smtp_format_date(int unix)             RFC 5322 date-time
#
# Protocol behavior:
#   - Replies: multi-line "250-" continuations are joined (text lines
#     separated by LF, codes stripped); every line must carry the same
#     3-digit code with a first digit 2..5; lines are capped at
#     smtp_max_reply_line() and replies at smtp_max_reply_lines().
#   - EHLO falls back to HELO on a 5xx reply. EHLO capabilities parsed:
#     SIZE [limit], 8BITMIME, PIPELINING (recorded, not used), STARTTLS,
#     SMTPUTF8 and the AUTH mechanism list (also the legacy "AUTH=").
#   - MAIL FROM carries SIZE=<n> when SIZE is advertised, and
#     BODY=8BITMIME when the message has 8-bit bytes and the server
#     advertises 8BITMIME. A message over the advertised limit fails
#     with smtp_error_too_large() before anything is sent.
#   - DATA normalizes bare LF and bare CR to CRLF, dot-stuffs lines
#     starting with '.', and terminates with CRLF.CRLF. A text line over
#     998 octets fails with smtp_error_too_large() before DATA is sent.
#   - STARTTLS discards all capabilities, rejects plaintext bytes
#     pipelined after the 220 (CVE-2011-0411 style injection), and
#     re-issues EHLO over TLS.
#   - Credentials are only sent over TLS, to a loopback server name
#     (localhost, 127.0.0.1, ::1), or after
#     smtp_set_allow_insecure_auth(c, 1); otherwise smtp_error_insecure().
#     AUTH also requires the mechanism to have been advertised.
#
# Hardening: addresses and command arguments with CR, LF, NUL, other
# control bytes, spaces, '<' or '>' (or non-ASCII bytes) are rejected
# with smtp_error_invalid() and nothing is written, so no argument can
# smuggle a second command. Command lines are capped at 512 octets with
# CRLF (AUTH lines at 12288, RFC 4954). Builder header inputs containing
# CR or LF make smtp_message_build return 0.
#
# Errors: smtp_error_io/protocol/tls leave the connection unusable
# (every later call fails fast); rejected/invalid/unsupported/insecure/
# too_large are per-call and the session can continue (smtp_send issues
# RSET after a failed transaction). All verbs return 1 on success, 0 on
# failure; smtp_last_code / smtp_last_reply hold the server's answer.
import lib.lib
import lib.net
import lib.str
import lib.time
import structures.string
import libs.standard.crypto.base64
import libs.standard.crypto.random
import libs.standard.net.dns
import libs.standard.net.tls
import lib.mem


/* Constants */

const int smtp_security_none = 0
const int smtp_security_starttls = 1
const int smtp_security_implicit = 2


# Conventional port for a security mode: 25 (relay), 587 (submission
# with STARTTLS), 465 (submission over implicit TLS).
int smtp_default_port(int security):
	if (security == smtp_security_implicit):
		return 465
	if (security == smtp_security_starttls):
		return 587
	return 25


const int smtp_error_none = 0


# Socket or TLS read/write failed, or the peer closed. Fatal.
const int smtp_error_io = 1


# Malformed or oversized reply, or plaintext injected after STARTTLS.
const int smtp_error_protocol = 2


# The server answered with an unexpected (4xx/5xx) reply code.
const int smtp_error_rejected = 3


# A caller argument failed validation; nothing was sent.
const int smtp_error_invalid = 4


# TLS handshake failed (see smtp_error_message). Fatal.
const int smtp_error_tls = 5


# The server did not advertise what the call needs (STARTTLS, AUTH ...).
const int smtp_error_unsupported = 6


# AUTH refused locally: the channel is not encrypted (see header).
const int smtp_error_insecure = 7


# The message exceeds the server's SIZE limit or has a line over 998
# octets.
const int smtp_error_too_large = 8


# Longest accepted reply line (RFC 5321 says 512; be lenient).
const int smtp_max_reply_line = 4096


# Most lines accepted in one multi-line reply.
const int smtp_max_reply_lines = 256


# Longest command line including CRLF (RFC 5321 4.5.3.1.4).
const int smtp_max_command_line = 512


# Longest AUTH command / response line including CRLF (RFC 4954 4).
const int smtp_max_auth_line = 12288


# Longest text line of message content, excluding CRLF (RFC 5321
# 4.5.3.1.6).
int smtp_max_text_line():
	return 998


# Longest forward/reverse path content, excluding the angle brackets.
const int smtp_max_address = 254
const int smtp_read_buf_cap = 4096


/* Client state */

struct smtp_client:
	int fd
	tls_conn* tls
	tls_config* tls_cfg
	int tls_cfg_owned
	char* server_name
	char* ehlo_domain
	char* rbuf
	int rpos
	int rlen
	int error
	int broken
	char* error_detail
	int last_code
	char* last_text
	int esmtp
	int cap_size
	int size_limit
	int cap_8bitmime
	int cap_pipelining
	int cap_starttls
	int cap_smtputf8
	int auth_plain
	int auth_login
	char* auth_mechs
	int allow_insecure_auth


void smtp_reset_caps(smtp_client* c):
	c.esmtp = 0
	c.cap_size = 0
	c.size_limit = 0
	c.cap_8bitmime = 0
	c.cap_pipelining = 0
	c.cap_starttls = 0
	c.cap_smtputf8 = 0
	c.auth_plain = 0
	c.auth_login = 0
	free(c.auth_mechs)
	c.auth_mechs = strclone(c"")


# Wraps an already-connected stream socket. The client takes ownership
# of fd (smtp_close closes it). server_name is the TLS SNI / hostname
# to verify for STARTTLS or implicit TLS (copied; 0 for none). Nothing
# is read: call smtp_start (or smtp_greeting + smtp_ehlo) next.
smtp_client* smtp_client_from_fd(int fd, char* server_name):
	smtp_client* c = new smtp_client()
	c.fd = fd
	c.tls = 0
	c.tls_cfg = 0
	c.tls_cfg_owned = 0
	c.server_name = 0
	if (server_name != 0):
		c.server_name = strclone(server_name)
	c.ehlo_domain = 0
	c.rbuf = malloc(smtp_read_buf_cap)
	c.rpos = 0
	c.rlen = 0
	c.error = 0
	c.broken = 0
	c.error_detail = 0
	c.last_code = 0
	c.last_text = strclone(c"")
	c.auth_mechs = strclone(c"")
	c.allow_insecure_auth = 0
	smtp_reset_caps(c)
	if (fd >= 0):
		socket_set_nosigpipe(fd)
	return c


# Sends nothing: closes the TLS session (close_notify) and the socket
# and frees the client. Call smtp_quit first for a polite goodbye.
void smtp_close(smtp_client* c):
	if (c == 0):
		return
	if (c.tls != 0):
		if (c.broken == 0):
			tls_close(c.tls)
		else:
			tls_conn_free(c.tls)
		c.tls = 0
	if (c.fd >= 0):
		close(c.fd)
		c.fd = (-1)
	if (c.tls_cfg_owned != 0):
		tls_config_free(c.tls_cfg)
	free(c.server_name)
	free(c.ehlo_domain)
	free(c.rbuf)
	free(c.last_text)
	free(c.auth_mechs)
	free(cast(char*, c))


int smtp_error(smtp_client* c):
	return c.error


# Static description of the last error ("" when none).
char* smtp_error_message(smtp_client* c):
	if (c.error_detail != 0):
		return c.error_detail
	return c""


int smtp_last_code(smtp_client* c):
	return c.last_code


# Text of the last reply, codes stripped, lines joined with LF. Owned by
# the client; valid until the next command.
char* smtp_last_reply(smtp_client* c):
	return c.last_text


# Permits AUTH over an unencrypted, non-loopback connection.
void smtp_set_allow_insecure_auth(smtp_client* c, int allow):
	c.allow_insecure_auth = allow


int smtp_fail(smtp_client* c, int code, char* detail):
	c.error = code
	c.error_detail = detail
	if ((code == smtp_error_io) || (code == smtp_error_protocol) || (code == smtp_error_tls)):
		c.broken = 1
	return 0


# Common prologue of every public verb: fail fast on a dead session and
# clear the previous per-call error.
int smtp_begin(smtp_client* c):
	if (c.broken != 0):
		return 0
	c.error = 0
	c.error_detail = 0
	return 1


/* Transport */

int smtp_write_all(smtp_client* c, char* data, int n):
	if (c.tls != 0):
		if (n == 0):
			return 1
		if (tls_write(c.tls, data, n) != n):
			return smtp_fail(c, smtp_error_io, c"smtp: TLS write failed")
		return 1
	int total = 0
	while (total < n):
		int got = socket_send(c.fd, data + total, n - total, msg_nosignal())
		if (got <= 0):
			return smtp_fail(c, smtp_error_io, c"smtp: socket write failed")
		total = total + got
	return 1


# Refills the read buffer when empty. 1 = bytes available, 0 = EOF/error.
int smtp_fill(smtp_client* c):
	if (c.rpos < c.rlen):
		return 1
	int got = 0
	if (c.tls != 0):
		got = tls_read(c.tls, c.rbuf, smtp_read_buf_cap)
	else:
		got = read(c.fd, c.rbuf, smtp_read_buf_cap)
	if (got <= 0):
		return smtp_fail(c, smtp_error_io, c"smtp: connection closed or read failed")
	c.rpos = 0
	c.rlen = got
	return 1


# Reads one LF-terminated line into line (cleared first), dropping the
# terminator and one CR before it. 1 on success, 0 on failure.
int smtp_read_line(smtp_client* c, string_builder* line):
	string_clear(line)
	while (1 == 1):
		if (smtp_fill(c) == 0):
			return 0
		int ch = c.rbuf[c.rpos] & 255
		c.rpos = c.rpos + 1
		if (ch == 10):
			if ((line.length > 0) && ((line.data[line.length - 1] & 255) == 13)):
				line.length = line.length - 1
				line.data[line.length] = 0
			return 1
		if (line.length >= smtp_max_reply_line):
			return smtp_fail(c, smtp_error_protocol, c"smtp: reply line too long")
		string_append_char(line, ch)
	return 0


int smtp_is_digit(int ch):
	return (ch >= '0') && (ch <= '9')


# Parses one reply line: a 3-digit code (first digit 2..5), then ' ',
# '-' or end of line. Sets *code and *more (1 for a '-' continuation).
# Returns 1, or 0 when the line is malformed.
int smtp_parse_reply_line(char* line, int len, int* code, int* more):
	if (len < 3):
		return 0
	int d0 = line[0] & 255
	int d1 = line[1] & 255
	int d2 = line[2] & 255
	if ((smtp_is_digit(d0) == 0) || (smtp_is_digit(d1) == 0) || (smtp_is_digit(d2) == 0)):
		return 0
	if ((d0 < '2') || (d0 > '5')):
		return 0
	*code = (d0 - '0') * 100 + (d1 - '0') * 10 + (d2 - '0')
	*more = 0
	if (len == 3):
		return 1
	int sep = line[3] & 255
	if (sep == '-'):
		*more = 1
		return 1
	if (sep == ' '):
		return 1
	return 0


# Reads one complete (possibly multi-line) reply. Returns its code, or
# -1 on failure (the connection is then broken).
int smtp_read_reply(smtp_client* c):
	string_builder* line = string_new()
	string_builder* text = string_new()
	int code = 0
	int lines = 0
	int more = 1
	while (more != 0):
		if (smtp_read_line(c, line) == 0):
			string_free(line)
			string_free(text)
			return (-1)
		int this_code = 0
		if (smtp_parse_reply_line(line.data, line.length, &this_code, &more) == 0):
			string_free(line)
			string_free(text)
			smtp_fail(c, smtp_error_protocol, c"smtp: malformed reply line")
			return (-1)
		if ((lines > 0) && (this_code != code)):
			string_free(line)
			string_free(text)
			smtp_fail(c, smtp_error_protocol, c"smtp: inconsistent codes in multi-line reply")
			return (-1)
		code = this_code
		lines = lines + 1
		if (lines > smtp_max_reply_lines):
			string_free(line)
			string_free(text)
			smtp_fail(c, smtp_error_protocol, c"smtp: too many reply lines")
			return (-1)
		if (lines > 1):
			string_append_char(text, 10)
		if (line.length > 4):
			string_append_bytes(text, line.data + 4, line.length - 4)
	string_free(line)
	free(c.last_text)
	c.last_text = text.data
	free(cast(char*, text))
	c.last_code = code
	return code


/* Argument validation */

# 1 when text is a safe single command argument: 1..max_len bytes of
# printable ASCII without space, '<' or '>'. Rules out CR/LF injection.
int smtp_valid_token(char* text, int max_len, int allow_empty):
	if (text == 0):
		return 0
	int n = 0
	while (text[n] != 0):
		int ch = text[n] & 255
		if ((ch <= 32) || (ch >= 127) || (ch == '<') || (ch == '>')):
			return 0
		n = n + 1
		if (n > max_len):
			return 0
	if ((n == 0) && (allow_empty == 0)):
		return 0
	return 1


# 1 when addr is a valid (non-empty) forward-path / mailbox address.
int smtp_valid_address(char* addr):
	return smtp_valid_token(addr, smtp_max_address, 0)


# 1 when line may be sent as one command: no CR, LF or NUL-truncation
# issues and short enough with CRLF appended.
int smtp_valid_line(char* line, int max_with_crlf):
	if (line == 0):
		return 0
	int n = 0
	while (line[n] != 0):
		int ch = line[n] & 255
		if ((ch == 13) || (ch == 10)):
			return 0
		n = n + 1
	if ((n == 0) || (n + 2 > max_with_crlf)):
		return 0
	return 1


/* Commands */

int smtp_send_line(smtp_client* c, char* line, int max_with_crlf):
	if (smtp_valid_line(line, max_with_crlf) == 0):
		return smtp_fail(c, smtp_error_invalid, c"smtp: command line contains CR/LF or is too long")
	int n = strlen(line)
	char* buf = malloc(n + 3)
	mem_copy(buf, line, n)
	buf[n] = 13
	buf[n + 1] = 10
	buf[n + 2] = 0
	int ok = smtp_write_all(c, buf, n + 2)
	free(buf)
	return ok


int smtp_command_limit(smtp_client* c, char* line, int max_with_crlf):
	if (smtp_send_line(c, line, max_with_crlf) == 0):
		return (-1)
	return smtp_read_reply(c)


# Sends one raw command line (CRLF appended) and returns the reply code,
# or -1 when the line is invalid (CR/LF, too long) or I/O failed.
int smtp_command(smtp_client* c, char* line):
	if (smtp_begin(c) == 0):
		return (-1)
	return smtp_command_limit(c, line, smtp_max_command_line)


# Maps a reply code to the verb result: 1 when it is one of the wanted
# codes (want2 may be 0), else records a rejection.
int smtp_expect(smtp_client* c, int code, int want1, int want2):
	if (code < 0):
		return 0
	if ((code == want1) || ((want2 != 0) && (code == want2))):
		return 1
	return smtp_fail(c, smtp_error_rejected, c"smtp: server rejected the command")


int smtp_simple(smtp_client* c, char* line, int want1, int want2):
	if (smtp_begin(c) == 0):
		return 0
	return smtp_expect(c, smtp_command_limit(c, line, smtp_max_command_line), want1, want2)


# Reads the 220 service greeting.
int smtp_greeting(smtp_client* c):
	if (smtp_begin(c) == 0):
		return 0
	return smtp_expect(c, smtp_read_reply(c), 220, 0)


int smtp_upper(int ch):
	if ((ch >= 'a') && (ch <= 'z')):
		return ch - 32
	return ch


# Case-insensitive compare of text[start, end) with an upper-case word.
int smtp_word_is(char* text, int start, int end, char* word):
	int n = strlen(word)
	if (end - start != n):
		return 0
	for i in range(n):
		if (smtp_upper(text[start + i] & 255) != (word[i] & 255)):
			return 0
	return 1


int smtp_parse_decimal(char* text, int start, int end):
	int v = 0
	for i in range(start, end):
		int ch = text[i] & 255
		if (smtp_is_digit(ch) == 0):
			return 0
		if (v > 200000000):
			return 2000000000
		v = v * 10 + (ch - '0')
	return v


void smtp_note_auth_mechs(smtp_client* c, char* text, int start, int end):
	string_builder* mechs = string_from(c.auth_mechs)
	int i = start
	while (i < end):
		while ((i < end) && ((text[i] & 255) == ' ')):
			i = i + 1
		int ws = i
		while ((i < end) && ((text[i] & 255) != ' ')):
			i = i + 1
		if (i > ws):
			if (smtp_word_is(text, ws, i, c"PLAIN") != 0):
				c.auth_plain = 1
			else if (smtp_word_is(text, ws, i, c"LOGIN") != 0):
				c.auth_login = 1
			if (mechs.length > 0):
				string_append_char(mechs, ' ')
			for k in range(ws, i):
				string_append_char(mechs, smtp_upper(text[k] & 255))
	free(c.auth_mechs)
	c.auth_mechs = mechs.data
	free(cast(char*, mechs))


# Parses EHLO reply text (as stored in last_text: first line is the
# greeting, each further line one extension) into the capability flags.
void smtp_parse_ehlo_caps(smtp_client* c, char* text):
	smtp_reset_caps(c)
	c.esmtp = 1
	int i = 0
	# Skip the first line (domain + greeting).
	while ((text[i] != 0) && (text[i] != 10)):
		i = i + 1
	while (text[i] != 0):
		i = i + 1
		int ls = i
		while ((text[i] != 0) && (text[i] != 10)):
			i = i + 1
		int le = i
		int ke = ls
		while ((ke < le) && ((text[ke] & 255) != ' ') && ((text[ke] & 255) != '=')):
			ke = ke + 1
		int ps = ke
		if (ps < le):
			ps = ps + 1
		if (smtp_word_is(text, ls, ke, c"SIZE") != 0):
			c.cap_size = 1
			c.size_limit = smtp_parse_decimal(text, ps, le)
		else if (smtp_word_is(text, ls, ke, c"8BITMIME") != 0):
			c.cap_8bitmime = 1
		else if (smtp_word_is(text, ls, ke, c"PIPELINING") != 0):
			c.cap_pipelining = 1
		else if (smtp_word_is(text, ls, ke, c"STARTTLS") != 0):
			c.cap_starttls = 1
		else if (smtp_word_is(text, ls, ke, c"SMTPUTF8") != 0):
			c.cap_smtputf8 = 1
		else if (smtp_word_is(text, ls, ke, c"AUTH") != 0):
			smtp_note_auth_mechs(c, text, ps, le)


# EHLO, falling back to HELO when the server answers EHLO with 5xx.
# Records the capabilities (all cleared after a HELO fallback).
int smtp_ehlo(smtp_client* c, char* domain):
	if (smtp_begin(c) == 0):
		return 0
	if (domain == 0):
		domain = c"localhost"
	if (smtp_valid_token(domain, 255, 0) == 0):
		return smtp_fail(c, smtp_error_invalid, c"smtp: invalid EHLO domain")
	if (c.ehlo_domain != domain):
		free(c.ehlo_domain)
		c.ehlo_domain = strclone(domain)
	char* line = strjoin(c"EHLO ", domain)
	int code = smtp_command_limit(c, line, smtp_max_command_line)
	free(line)
	if (code == 250):
		smtp_parse_ehlo_caps(c, c.last_text)
		return 1
	if ((code < 500) || (code > 599)):
		return smtp_expect(c, code, 250, 0)
	smtp_reset_caps(c)
	line = strjoin(c"HELO ", domain)
	code = smtp_command_limit(c, line, smtp_max_command_line)
	free(line)
	return smtp_expect(c, code, 250, 0)


int smtp_tls_wrap(smtp_client* c, tls_config* cfg):
	if (cfg == 0):
		if (c.tls_cfg_owned == 0):
			c.tls_cfg = tls_config_new()
			c.tls_cfg_owned = 1
		cfg = c.tls_cfg
	else:
		if (c.tls_cfg_owned != 0):
			tls_config_free(c.tls_cfg)
			c.tls_cfg_owned = 0
		c.tls_cfg = cfg
	char* name = c.server_name
	if (name == 0):
		name = c""
	c.tls = tls_connect(c.fd, name, cfg)
	if (c.tls == 0):
		char* why = tls_last_error(cfg)
		if (why == 0):
			why = c"smtp: TLS handshake failed"
		return smtp_fail(c, smtp_error_tls, why)
	return 1


# STARTTLS (RFC 3207): requires the capability, rejects plaintext
# pipelined behind the 220, handshakes TLS (cfg 0 = default config with
# certificate validation) and re-issues EHLO.
int smtp_starttls(smtp_client* c, tls_config* cfg):
	if (smtp_begin(c) == 0):
		return 0
	if (c.tls != 0):
		return smtp_fail(c, smtp_error_unsupported, c"smtp: TLS already active")
	if (c.cap_starttls == 0):
		return smtp_fail(c, smtp_error_unsupported, c"smtp: server does not offer STARTTLS")
	int code = smtp_command_limit(c, c"STARTTLS", smtp_max_command_line)
	if (smtp_expect(c, code, 220, 0) == 0):
		return 0
	if (c.rpos < c.rlen):
		return smtp_fail(c, smtp_error_protocol, c"smtp: plaintext data after STARTTLS reply")
	smtp_reset_caps(c)
	if (smtp_tls_wrap(c, cfg) == 0):
		return 0
	char* domain = strclone(c.ehlo_domain)
	int ok = smtp_ehlo(c, domain)
	free(domain)
	return ok


# Session setup on a fresh connection: implicit TLS handshake (security
# implicit), 220 greeting, EHLO/HELO, and STARTTLS + EHLO (security
# starttls; fails with smtp_error_unsupported when not offered, never
# silently downgrading). ehlo_domain 0 means "localhost".
int smtp_start(smtp_client* c, int security, tls_config* cfg, char* ehlo_domain):
	if (smtp_begin(c) == 0):
		return 0
	if (security == smtp_security_implicit):
		if (smtp_tls_wrap(c, cfg) == 0):
			return 0
	if (smtp_greeting(c) == 0):
		return 0
	if (smtp_ehlo(c, ehlo_domain) == 0):
		return 0
	if (security == smtp_security_starttls):
		return smtp_starttls(c, cfg)
	return 1


# Resolves host (dotted quad, /etc/hosts or DNS), connects, applies
# timeout_ms (0 = none) to every socket read/write, and runs smtp_start.
# Never returns 0: check smtp_error(c) (non-zero = failed; the client
# must still be released with smtp_close).
smtp_client* smtp_open(char* host, int port, int security, tls_config* cfg, char* ehlo_domain, int timeout_ms):
	smtp_client* c = smtp_client_from_fd((-1), host)
	int ip = 0
	if ((host == 0) || (dns_resolve_ipv4(host, &ip) == 0)):
		smtp_fail(c, smtp_error_io, c"smtp: cannot resolve host")
		return c
	int fd = socket_tcp_ipv4()
	if (fd < 0):
		smtp_fail(c, smtp_error_io, c"smtp: socket failed")
		return c
	c.fd = fd
	socket_set_nosigpipe(fd)
	if (timeout_ms > 0):
		socket_set_recv_timeout(fd, timeout_ms)
		socket_set_send_timeout(fd, timeout_ms)
	if (socket_connect_ipv4(fd, ip, port) < 0):
		smtp_fail(c, smtp_error_io, c"smtp: connect failed")
		return c
	smtp_start(c, security, cfg, ehlo_domain)
	return c


int smtp_is_loopback_name(char* name):
	if (name == 0):
		return 0
	if ((strcmp(name, c"localhost") == 0) || (strcmp(name, c"127.0.0.1") == 0) || (strcmp(name, c"::1") == 0)):
		return 1
	return 0


int smtp_auth_allowed(smtp_client* c, int advertised):
	if ((c.tls == 0) && (c.allow_insecure_auth == 0) && (smtp_is_loopback_name(c.server_name) == 0)):
		return smtp_fail(c, smtp_error_insecure, c"smtp: refusing to send credentials without TLS")
	if (advertised == 0):
		return smtp_fail(c, smtp_error_unsupported, c"smtp: AUTH mechanism not advertised")
	return 1


int smtp_valid_credential(char* text):
	return (text != 0) && (strlen(text) <= 4096)


# Sends base64(data[0, len)) as a SASL response line, prefixed with
# prefix (0 for none). Returns the reply code or -1.
int smtp_sasl_send(smtp_client* c, char* prefix, char* data, int len):
	char* b64 = base64_encode(data, len)
	char* line = b64
	if (prefix != 0):
		line = strjoin(prefix, b64)
		free(b64)
	int code = smtp_command_limit(c, line, smtp_max_auth_line)
	int n = strlen(line)
	mem_fill(line, 0, n)
	free(line)
	return code


# If the server is still mid-exchange (334), cancel it with "*".
void smtp_sasl_cancel(smtp_client* c, int code):
	if (code == 334):
		smtp_command_limit(c, c"*", smtp_max_command_line)


# AUTH PLAIN (RFC 4616) with an initial response: base64 of
# NUL user NUL pass (empty authorization identity).
int smtp_auth_plain(smtp_client* c, char* user, char* pass):
	if (smtp_begin(c) == 0):
		return 0
	if ((smtp_valid_credential(user) == 0) || (smtp_valid_credential(pass) == 0) || (strlen(user) == 0)):
		return smtp_fail(c, smtp_error_invalid, c"smtp: invalid credentials")
	if (smtp_auth_allowed(c, c.auth_plain) == 0):
		return 0
	int ul = strlen(user)
	int pl = strlen(pass)
	int n = ul + pl + 2
	char* raw = malloc(n + 1)
	raw[0] = 0
	int i = 0
	while (i < ul):
		raw[1 + i] = user[i]
		i = i + 1
	raw[1 + ul] = 0
	i = 0
	while (i < pl):
		raw[2 + ul + i] = pass[i]
		i = i + 1
	int code = smtp_sasl_send(c, c"AUTH PLAIN ", raw, n)
	mem_fill(raw, 0, n)
	free(raw)
	if (code == 235):
		return 1
	smtp_sasl_cancel(c, code)
	return smtp_expect(c, code, 235, 0)


# AUTH LOGIN: "AUTH LOGIN", then base64 user and base64 password, each
# after a 334 challenge.
int smtp_auth_login(smtp_client* c, char* user, char* pass):
	if (smtp_begin(c) == 0):
		return 0
	if ((smtp_valid_credential(user) == 0) || (smtp_valid_credential(pass) == 0) || (strlen(user) == 0)):
		return smtp_fail(c, smtp_error_invalid, c"smtp: invalid credentials")
	if (smtp_auth_allowed(c, c.auth_login) == 0):
		return 0
	int code = smtp_command_limit(c, c"AUTH LOGIN", smtp_max_command_line)
	if (code != 334):
		return smtp_expect(c, code, 334, 0)
	code = smtp_sasl_send(c, 0, user, strlen(user))
	if (code != 334):
		smtp_sasl_cancel(c, code)
		return smtp_expect(c, code, 334, 0)
	code = smtp_sasl_send(c, 0, pass, strlen(pass))
	if (code == 235):
		return 1
	smtp_sasl_cancel(c, code)
	return smtp_expect(c, code, 235, 0)


# Picks AUTH PLAIN when advertised, else AUTH LOGIN.
int smtp_auth(smtp_client* c, char* user, char* pass):
	if ((c.auth_plain == 0) && (c.auth_login != 0)):
		return smtp_auth_login(c, user, pass)
	return smtp_auth_plain(c, user, pass)


int smtp_mail_from_ex(smtp_client* c, char* addr, int size, int eightbit):
	if (smtp_begin(c) == 0):
		return 0
	if (addr == 0):
		addr = c""
	if (smtp_valid_token(addr, smtp_max_address, 1) == 0):
		return smtp_fail(c, smtp_error_invalid, c"smtp: invalid MAIL FROM address")
	if ((c.cap_size != 0) && (c.size_limit > 0) && (size > c.size_limit)):
		return smtp_fail(c, smtp_error_too_large, c"smtp: message exceeds the server SIZE limit")
	string_builder* line = string_new()
	string_append(line, c"MAIL FROM:<")
	string_append(line, addr)
	string_append(line, c">")
	if ((c.cap_size != 0) && (size > 0)):
		string_append(line, c" SIZE=")
		string_append_int(line, size)
	if ((eightbit != 0) && (c.cap_8bitmime != 0)):
		string_append(line, c" BODY=8BITMIME")
	int code = smtp_command_limit(c, line.data, smtp_max_command_line)
	string_free(line)
	return smtp_expect(c, code, 250, 0)


# MAIL FROM:<addr> (addr "" or 0 = null reverse-path), with SIZE=size
# when the server advertises SIZE and size > 0.
int smtp_mail_from(smtp_client* c, char* addr, int size):
	return smtp_mail_from_ex(c, addr, size, 0)


# RCPT TO:<addr>; accepts 250 and 251.
int smtp_rcpt_to(smtp_client* c, char* addr):
	if (smtp_begin(c) == 0):
		return 0
	if (smtp_valid_address(addr) == 0):
		return smtp_fail(c, smtp_error_invalid, c"smtp: invalid RCPT TO address")
	string_builder* line = string_new()
	string_append(line, c"RCPT TO:<")
	string_append(line, addr)
	string_append(line, c">")
	int code = smtp_command_limit(c, line.data, smtp_max_command_line)
	string_free(line)
	return smtp_expect(c, code, 250, 251)


int smtp_has_8bit(char* data, int len):
	for i in range(len):
		if ((data[i] & 255) >= 128):
			return 1
	return 0


# Transforms message content for DATA: bare LF and bare CR become CRLF,
# lines starting with '.' get an extra '.', and the result ends with
# CRLF (the ".\r\n" terminator is NOT included). Returns a malloc'd
# buffer and its length, or 0 when a line exceeds smtp_max_text_line().
char* smtp_dot_stuff(char* data, int len, int* out_len):
	*out_len = 0
	string_builder* out = string_new_sized(len + len / 32 + 8)
	int i = 0
	int col = 0
	while (i < len):
		int ch = data[i] & 255
		if ((ch == 13) || (ch == 10)):
			if ((ch == 13) && (i + 1 < len) && ((data[i + 1] & 255) == 10)):
				i = i + 1
			string_append_char(out, 13)
			string_append_char(out, 10)
			col = 0
		else:
			if ((col == 0) && (ch == '.')):
				string_append_char(out, '.')
			string_append_char(out, ch)
			col = col + 1
			if (col > smtp_max_text_line()):
				string_free(out)
				return 0
		i = i + 1
	if (col > 0):
		string_append_char(out, 13)
		string_append_char(out, 10)
	*out_len = out.length
	char* result = out.data
	free(cast(char*, out))
	return result


# DATA: validates and dot-stuffs msg first (a too-long line fails before
# anything is sent), expects 354, sends the content + CRLF.CRLF, and
# expects 250.
int smtp_data(smtp_client* c, char* msg, int len):
	if (smtp_begin(c) == 0):
		return 0
	int n = 0
	char* stuffed = smtp_dot_stuff(msg, len, &n)
	if (stuffed == 0):
		return smtp_fail(c, smtp_error_too_large, c"smtp: message line longer than 998 octets")
	int code = smtp_command_limit(c, c"DATA", smtp_max_command_line)
	if (code != 354):
		free(stuffed)
		return smtp_expect(c, code, 354, 0)
	int ok = smtp_write_all(c, stuffed, n)
	free(stuffed)
	if (ok == 0):
		return 0
	if (smtp_write_all(c, c".\x0d\x0a", 3) == 0):
		return 0
	return smtp_expect(c, smtp_read_reply(c), 250, 0)


int smtp_rset(smtp_client* c):
	return smtp_simple(c, c"RSET", 250, 0)


int smtp_noop(smtp_client* c):
	return smtp_simple(c, c"NOOP", 250, 0)


# QUIT, expecting 221. Does not close: call smtp_close afterwards.
int smtp_quit(smtp_client* c):
	return smtp_simple(c, c"QUIT", 221, 0)


# After a failed transaction step, reset the server's transaction state
# without clobbering the error that caused the failure.
void smtp_abort_transaction(smtp_client* c):
	if (c.broken != 0):
		return
	int err = c.error
	char* detail = c.error_detail
	int code = c.last_code
	char* text = strclone(c.last_text)
	smtp_rset(c)
	if (c.broken == 0):
		c.error = err
		c.error_detail = detail
		c.last_code = code
		free(c.last_text)
		c.last_text = text
	else:
		free(text)


# One mail transaction: MAIL FROM, RCPT TO for each recipient, DATA.
# Rejected recipients are skipped; the message goes to the accepted
# ones. Returns the number of accepted recipients, or 0 when MAIL, all
# recipients, or DATA failed (after an accepted MAIL, RSET is issued on
# a live session; the failing reply stays in smtp_last_code/_reply).
int smtp_send(smtp_client* c, char* from, list[char*] rcpts, char* msg, int len):
	if (smtp_begin(c) == 0):
		return 0
	if (rcpts.length == 0):
		return smtp_fail(c, smtp_error_invalid, c"smtp: no recipients")
	int i = 0
	while (i < rcpts.length):
		if (smtp_valid_address(rcpts[i]) == 0):
			return smtp_fail(c, smtp_error_invalid, c"smtp: invalid RCPT TO address")
		i = i + 1
	if (smtp_mail_from_ex(c, from, len, smtp_has_8bit(msg, len)) == 0):
		return 0
	int accepted = 0
	i = 0
	while (i < rcpts.length):
		if (smtp_rcpt_to(c, rcpts[i]) != 0):
			accepted = accepted + 1
		else if (c.broken != 0):
			return 0
		i = i + 1
	if (accepted == 0):
		smtp_abort_transaction(c)
		return 0
	if (smtp_data(c, msg, len) == 0):
		smtp_abort_transaction(c)
		return 0
	return accepted


/* Message builder (RFC 5322 + MIME) */

struct smtp_message:
	char* from_addr
	char* from_name
	list[char*] to_addrs
	list[char*] to_names
	list[char*] cc_addrs
	list[char*] cc_names
	list[char*] bcc_addrs
	char* subject
	char* text
	char* html
	int has_date
	int date_unix
	char* message_id
	char* boundary


char* smtp_clone_or_zero(char* s):
	if (s == 0):
		return 0
	return strclone(s)


smtp_message* smtp_message_new():
	smtp_message* m = new smtp_message()
	m.from_addr = 0
	m.from_name = 0
	m.to_addrs = new list[char*]
	m.to_names = new list[char*]
	m.cc_addrs = new list[char*]
	m.cc_names = new list[char*]
	m.bcc_addrs = new list[char*]
	m.subject = 0
	m.text = 0
	m.html = 0
	m.has_date = 0
	m.date_unix = 0
	m.message_id = 0
	m.boundary = 0
	return m


void smtp_free_strings(list[char*] l):
	int i = 0
	while (i < l.length):
		free(l[i])
		i = i + 1
	l.free()


void smtp_message_free(smtp_message* m):
	if (m == 0):
		return
	free(m.from_addr)
	free(m.from_name)
	smtp_free_strings(m.to_addrs)
	smtp_free_strings(m.to_names)
	smtp_free_strings(m.cc_addrs)
	smtp_free_strings(m.cc_names)
	smtp_free_strings(m.bcc_addrs)
	free(m.subject)
	free(m.text)
	free(m.html)
	free(m.message_id)
	free(m.boundary)
	free(cast(char*, m))


void smtp_message_set_from(smtp_message* m, char* addr, char* name):
	free(m.from_addr)
	free(m.from_name)
	m.from_addr = smtp_clone_or_zero(addr)
	m.from_name = smtp_clone_or_zero(name)


void smtp_message_add_to(smtp_message* m, char* addr, char* name):
	m.to_addrs.push(smtp_clone_or_zero(addr))
	m.to_names.push(smtp_clone_or_zero(name))


void smtp_message_add_cc(smtp_message* m, char* addr, char* name):
	m.cc_addrs.push(smtp_clone_or_zero(addr))
	m.cc_names.push(smtp_clone_or_zero(name))


# Bcc recipients get the message but appear in no header.
void smtp_message_add_bcc(smtp_message* m, char* addr):
	m.bcc_addrs.push(smtp_clone_or_zero(addr))


void smtp_message_set_subject(smtp_message* m, char* subject):
	free(m.subject)
	m.subject = smtp_clone_or_zero(subject)


# Plain-text body (UTF-8).
void smtp_message_set_text(smtp_message* m, char* text):
	free(m.text)
	m.text = smtp_clone_or_zero(text)


# HTML alternative; when set the message is multipart/alternative.
void smtp_message_set_html(smtp_message* m, char* html):
	free(m.html)
	m.html = smtp_clone_or_zero(html)


# Fixed Date (Unix seconds); default is the current time.
void smtp_message_set_date(smtp_message* m, int unix_time):
	m.has_date = 1
	m.date_unix = unix_time


# Fixed Message-ID including the angle brackets; default is random.
void smtp_message_set_message_id(smtp_message* m, char* id):
	free(m.message_id)
	m.message_id = smtp_clone_or_zero(id)


# Fixed multipart boundary; default is random.
void smtp_message_set_boundary(smtp_message* m, char* boundary):
	free(m.boundary)
	m.boundary = smtp_clone_or_zero(boundary)


# Envelope recipients: every To, Cc and Bcc address (strings borrowed
# from m; free only the list).
list[char*] smtp_message_recipients(smtp_message* m):
	list[char*] out = new list[char*]
	int i = 0
	while (i < m.to_addrs.length):
		out.push(m.to_addrs[i])
		i = i + 1
	i = 0
	while (i < m.cc_addrs.length):
		out.push(m.cc_addrs[i])
		i = i + 1
	i = 0
	while (i < m.bcc_addrs.length):
		out.push(m.bcc_addrs[i])
		i = i + 1
	return out


int smtp_has_crlf(char* s):
	if (s == 0):
		return 0
	int i = 0
	while (s[i] != 0):
		if ((s[i] == 13) || (s[i] == 10)):
			return 1
		i = i + 1
	return 0


# 1 when s needs RFC 2047 encoding in a header: non-ASCII or control
# bytes, an "=?" sequence, or a word too long to fold.
int smtp_needs_encoding(char* s):
	int i = 0
	int word = 0
	while (s[i] != 0):
		int ch = s[i] & 255
		if ((ch < 32) || (ch >= 127)):
			return 1
		if ((ch == '=') && (s[i + 1] == '?')):
			return 1
		if (ch == ' '):
			word = 0
		else:
			word = word + 1
			if (word > 70):
				return 1
		i = i + 1
	return 0


# RFC 2047 "B" encoded-words for text (UTF-8): chunks of at most 39
# bytes, split only at UTF-8 character boundaries, so each word is at
# most 64 characters and fits a folded 78-column line even after
# "Subject: "; words are separated by single spaces (foldable
# whitespace that decoders drop between adjacent encoded-words).
char* smtp_encode_word(char* text):
	string_builder* out = string_new()
	int n = strlen(text)
	int start = 0
	while (start < n):
		int end = start + 39
		if (end >= n):
			end = n
		else:
			while ((end > start) && (((text[end] & 255) & 192) == 128)):
				end = end - 1
			if (end == start):
				end = start + 39
		char* b64 = base64_encode(text + start, end - start)
		if (out.length > 0):
			string_append_char(out, ' ')
		string_append(out, c"=?UTF-8?B?")
		string_append(out, b64)
		string_append(out, c"?=")
		free(b64)
		start = end
	char* result = out.data
	free(cast(char*, out))
	return result


void smtp_append_2(string_builder* out, int v):
	string_append_char(out, '0' + (v / 10) % 10)
	string_append_char(out, '0' + v % 10)


# RFC 5322 date-time in UTC, e.g. "Fri, 25 Sep 2026 12:34:56 +0000".
char* smtp_format_date(int unix_time):
	if (unix_time < 0):
		unix_time = 0
	date_time dt
	time_utc_from_unix(unix_time, &dt)
	string_builder* out = string_new()
	string_append_bytes(out, time_weekday_name(dt.weekday), 3)
	string_append(out, c", ")
	string_append_int(out, dt.day)
	string_append_char(out, ' ')
	string_append_bytes(out, time_month_name(dt.month), 3)
	string_append_char(out, ' ')
	string_append_int(out, dt.year)
	string_append_char(out, ' ')
	smtp_append_2(out, dt.hour)
	string_append_char(out, ':')
	smtp_append_2(out, dt.minute)
	string_append_char(out, ':')
	smtp_append_2(out, dt.second)
	string_append(out, c" +0000")
	char* result = out.data
	free(cast(char*, out))
	return result


# Random lowercase hex of nbytes random bytes (falls back to a clock +
# counter mix when the entropy source is unavailable).
int smtp_random_counter = 0


char* smtp_random_hex(int nbytes):
	char* raw = malloc(nbytes)
	if (random_bytes(raw, nbytes) == 0):
		smtp_random_counter = smtp_random_counter + 1
		int seed = time_now() * 31 + time_monotonic_ms() + smtp_random_counter * 7919
		for i in range(nbytes):
			seed = seed * 1103515245 + 12345
			raw[i] = (seed >> 16) & 255
	char* out = hex_encode(raw, nbytes)
	free(raw)
	return out


# Appends "Name: value" CRLF, folding at spaces so lines stay within 78
# characters where possible (RFC 5322 2.2.3). Each space in value is
# kept; a fold turns one of them into CRLF + space. Returns 0 when a
# line would still exceed 998 characters.
int smtp_append_header(string_builder* out, char* name, char* value):
	string_append(out, name)
	string_append_char(out, ':')
	int line_len = strlen(name) + 1
	int n = strlen(value)
	int i = 0
	int first = 1
	while (1 == 1):
		int j = i
		while ((j < n) && (value[j] != ' ')):
			j = j + 1
		int tok = j - i
		if ((first == 0) && (tok > 0) && (line_len + 1 + tok > 78)):
			string_append(out, c"\x0d\x0a")
			line_len = 0
		string_append_char(out, ' ')
		string_append_bytes(out, value + i, tok)
		line_len = line_len + 1 + tok
		if (line_len > 998):
			return 0
		first = 0
		if (j >= n):
			string_append(out, c"\x0d\x0a")
			return 1
		i = j + 1
	return 0


int smtp_is_atext_or_space(int ch):
	if ((ch >= 'a') && (ch <= 'z')):
		return 1
	if ((ch >= 'A') && (ch <= 'Z')):
		return 1
	if (smtp_is_digit(ch) != 0):
		return 1
	char* extra = c" !#$%&'*+-/=?^_`{|}~"
	int i = 0
	while (extra[i] != 0):
		if (extra[i] == ch):
			return 1
		i = i + 1
	return 0


# "Display Name <addr>" (name quoted or RFC 2047-encoded as needed), or
# just "addr". Returns 0 when addr or name is invalid.
char* smtp_format_mailbox(char* addr, char* name):
	if (smtp_valid_address(addr) == 0):
		return 0
	if ((name == 0) || (name[0] == 0)):
		return strclone(addr)
	if (smtp_has_crlf(name) != 0):
		return 0
	string_builder* out = string_new()
	if (smtp_needs_encoding(name) != 0):
		char* enc = smtp_encode_word(name)
		string_append(out, enc)
		free(enc)
	else:
		int plain = 1
		int i = 0
		while (name[i] != 0):
			if (smtp_is_atext_or_space(name[i] & 255) == 0):
				plain = 0
			i = i + 1
		if (plain != 0):
			string_append(out, name)
		else:
			string_append_char(out, '"')
			i = 0
			while (name[i] != 0):
				if ((name[i] == '"') || (name[i] == 92)):
					string_append_char(out, 92)
				string_append_char(out, name[i] & 255)
				i = i + 1
			string_append_char(out, '"')
	string_append(out, c" <")
	string_append(out, addr)
	string_append_char(out, '>')
	char* result = out.data
	free(cast(char*, out))
	return result


# Comma-separated mailbox list, or 0 when an entry is invalid.
char* smtp_format_mailbox_list(list[char*] addrs, list[char*] names):
	string_builder* out = string_new()
	int i = 0
	while (i < addrs.length):
		char* mb = smtp_format_mailbox(addrs[i], names[i])
		if (mb == 0):
			string_free(out)
			return 0
		if (i > 0):
			string_append(out, c", ")
		string_append(out, mb)
		free(mb)
		i = i + 1
	char* result = out.data
	free(cast(char*, out))
	return result


int smtp_contains(char* hay, char* needle):
	if (hay == 0):
		return 0
	int i = 0
	while (hay[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (hay[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		i = i + 1
	return 0


# 1 when body can go as 7bit: ASCII only, lines at most 998 octets.
int smtp_body_is_7bit(char* body):
	int i = 0
	int col = 0
	while (body[i] != 0):
		int ch = body[i] & 255
		if (ch >= 128):
			return 0
		if ((ch == 10) || (ch == 13)):
			col = 0
		else:
			col = col + 1
			if (col > smtp_max_text_line()):
				return 0
		i = i + 1
	return 1


# Line-ending normalization only (bare LF/CR -> CRLF, trailing CRLF
# ensured); no dot-stuffing, which belongs to the DATA transport.
char* smtp_normalize_crlf(char* body, int* out_len):
	string_builder* out = string_new()
	int n = strlen(body)
	int i = 0
	int col = 0
	while (i < n):
		int ch = body[i] & 255
		if ((ch == 13) || (ch == 10)):
			if ((ch == 13) && (i + 1 < n) && ((body[i + 1] & 255) == 10)):
				i = i + 1
			string_append(out, c"\x0d\x0a")
			col = 0
		else:
			string_append_char(out, ch)
			col = col + 1
		i = i + 1
	if (col > 0):
		string_append(out, c"\x0d\x0a")
	*out_len = out.length
	char* result = out.data
	free(cast(char*, out))
	return result


# Appends the Content-Type / Content-Transfer-Encoding headers, a blank
# line, and the encoded body (7bit with CRLF line ends, else base64 in
# 76-character lines), ending with CRLF.
void smtp_append_body_part(string_builder* out, char* subtype, char* body):
	string_append(out, c"Content-Type: text/")
	string_append(out, subtype)
	string_append(out, c"; charset=utf-8\x0d\x0a")
	if (smtp_body_is_7bit(body) != 0):
		string_append(out, c"Content-Transfer-Encoding: 7bit\x0d\x0a\x0d\x0a")
		int n = 0
		char* norm = smtp_normalize_crlf(body, &n)
		string_append_bytes(out, norm, n)
		free(norm)
		return
	string_append(out, c"Content-Transfer-Encoding: base64\x0d\x0a\x0d\x0a")
	char* b64 = base64_encode(body, strlen(body))
	int total = strlen(b64)
	int pos = 0
	while (pos < total):
		int take = total - pos
		if (take > 76):
			take = 76
		string_append_bytes(out, b64 + pos, take)
		string_append(out, c"\x0d\x0a")
		pos = pos + take
	free(b64)


char* smtp_address_domain(char* addr):
	int at = (-1)
	int i = 0
	while (addr[i] != 0):
		if (addr[i] == '@'):
			at = i
		i = i + 1
	if ((at < 0) || (addr[at + 1] == 0)):
		return strclone(c"localhost")
	return strclone(addr + at + 1)


int smtp_valid_boundary(char* b):
	int n = strlen(b)
	if ((n == 0) || (n > 70)):
		return 0
	for i in range(n):
		int ch = b[i] & 255
		if ((ch <= 32) || (ch >= 127) || (ch == '"')):
			return 0
	return 1


# 1 for "<printable-ascii-without-spaces>" of at most 250 characters.
int smtp_valid_msgid(char* id):
	int n = strlen(id)
	if ((n < 3) || (n > 250) || (id[0] != '<') || (id[n - 1] != '>')):
		return 0
	for i in range(1, n - 1):
		int ch = id[i] & 255
		if ((ch <= 32) || (ch >= 127) || (ch == '<') || (ch == '>')):
			return 0
	return 1


# Serializes the message: Date, From, To, Cc, Subject, Message-ID,
# MIME-Version and the body (text/plain, or multipart/alternative with
# the HTML part). Returns a malloc'd buffer (length in *out_len), or 0
# when From is missing, there is no To/Cc/Bcc, an address or name is
# invalid, or a header input contains CR/LF.
char* smtp_message_build(smtp_message* m, int* out_len):
	*out_len = 0
	if (m.from_addr == 0):
		return 0
	if ((m.to_addrs.length + m.cc_addrs.length + m.bcc_addrs.length) == 0):
		return 0
	int i = 0
	while (i < m.bcc_addrs.length):
		if (smtp_valid_address(m.bcc_addrs[i]) == 0):
			return 0
		i = i + 1
	if ((smtp_has_crlf(m.subject) != 0) || (smtp_has_crlf(m.message_id) != 0)):
		return 0
	if ((m.message_id != 0) && (smtp_valid_msgid(m.message_id) == 0)):
		return 0

	string_builder* out = string_new()
	int ok = 1

	int when = m.date_unix
	if (m.has_date == 0):
		when = time_now()
	char* date = smtp_format_date(when)
	ok = ok & smtp_append_header(out, c"Date", date)
	free(date)

	char* from = smtp_format_mailbox(m.from_addr, m.from_name)
	if (from == 0):
		string_free(out)
		return 0
	ok = ok & smtp_append_header(out, c"From", from)
	free(from)

	if (m.to_addrs.length > 0):
		char* to = smtp_format_mailbox_list(m.to_addrs, m.to_names)
		if (to == 0):
			string_free(out)
			return 0
		ok = ok & smtp_append_header(out, c"To", to)
		free(to)
	if (m.cc_addrs.length > 0):
		char* cc = smtp_format_mailbox_list(m.cc_addrs, m.cc_names)
		if (cc == 0):
			string_free(out)
			return 0
		ok = ok & smtp_append_header(out, c"Cc", cc)
		free(cc)

	if (m.subject != 0):
		if (smtp_needs_encoding(m.subject) != 0):
			char* enc = smtp_encode_word(m.subject)
			ok = ok & smtp_append_header(out, c"Subject", enc)
			free(enc)
		else:
			ok = ok & smtp_append_header(out, c"Subject", m.subject)

	if (m.message_id != 0):
		ok = ok & smtp_append_header(out, c"Message-ID", m.message_id)
	else:
		char* hexid = smtp_random_hex(16)
		char* domain = smtp_address_domain(m.from_addr)
		string_builder* id = string_new()
		string_append_char(id, '<')
		string_append(id, hexid)
		string_append_char(id, '@')
		string_append(id, domain)
		string_append_char(id, '>')
		ok = ok & smtp_append_header(out, c"Message-ID", id.data)
		string_free(id)
		free(hexid)
		free(domain)

	string_append(out, c"MIME-Version: 1.0\x0d\x0a")
	char* text = m.text
	if (text == 0):
		text = c""
	if (m.html == 0):
		smtp_append_body_part(out, c"plain", text)
	else:
		char* boundary = 0
		if (m.boundary != 0):
			boundary = strclone(m.boundary)
		else:
			char* hexb = smtp_random_hex(12)
			boundary = strjoin(c"=_w_", hexb)
			free(hexb)
		if ((smtp_valid_boundary(boundary) == 0) || (smtp_contains(text, boundary) != 0) || (smtp_contains(m.html, boundary) != 0)):
			free(boundary)
			string_free(out)
			return 0
		string_append(out, c"Content-Type: multipart/alternative; boundary=\"")
		string_append(out, boundary)
		string_append(out, c"\"\x0d\x0a\x0d\x0a")
		string_append(out, c"--")
		string_append(out, boundary)
		string_append(out, c"\x0d\x0a")
		smtp_append_body_part(out, c"plain", text)
		string_append(out, c"--")
		string_append(out, boundary)
		string_append(out, c"\x0d\x0a")
		smtp_append_body_part(out, c"html", m.html)
		string_append(out, c"--")
		string_append(out, boundary)
		string_append(out, c"--\x0d\x0a")
		free(boundary)
	if (ok == 0):
		string_free(out)
		return 0
	*out_len = out.length
	char* result = out.data
	free(cast(char*, out))
	return result


# Builds m and sends it in one transaction from m's From address to all
# its To/Cc/Bcc recipients. Returns the accepted recipient count or 0
# (smtp_error_invalid when the message does not build).
int smtp_send_message(smtp_client* c, smtp_message* m):
	if (smtp_begin(c) == 0):
		return 0
	int len = 0
	char* msg = smtp_message_build(m, &len)
	if (msg == 0):
		return smtp_fail(c, smtp_error_invalid, c"smtp: message failed to build")
	list[char*] rcpts = smtp_message_recipients(m)
	int accepted = smtp_send(c, m.from_addr, rcpts, msg, len)
	rcpts.free()
	free(msg)
	return accepted
