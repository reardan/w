# FTP client (RFC 959) for the pure-W network stack, with RFC 2428
# EPSV, the cheap RFC 3659 extensions (SIZE, MDTM, MLSD) and FTPS
# (RFC 4217 explicit AUTH TLS, and implicit TLS on port 990) over
# libs/standard/net/tls.w. Part of issue #436 (Protocols). IPv4 only:
# no active mode (PORT/EPRT), no REST/resume, no CCC.
#
#   ftp_client* ftp_connect(char* host, int port, int timeout_ms)
#   ftp_client* ftp_attach(int fd, int peer_ip, int timeout_ms)
#   int   ftp_ok(ftp_client* c)             1 while c.error == 0
#   int   ftp_login(c, char* user, char* password)
#   int   ftp_login_anonymous(c)
#   int   ftp_type_binary(c) / ftp_type_ascii(c)
#   char* ftp_pwd(c)                        caller frees; 0 on failure
#   int   ftp_cwd(c, char* path) / ftp_cdup(c)
#   int   ftp_mkd(c, path) / ftp_rmd(c, path) / ftp_delete(c, path)
#   int   ftp_rename(c, char* from, char* to)      RNFR + RNTO
#   int   ftp_size(c, path)                  bytes, or -1
#   char* ftp_mdtm(c, path)                  "YYYYMMDDHHMMSS[.sss]" or 0
#   int   ftp_noop(c) / ftp_quit(c)
#   int   ftp_command(c, char* verb, char* arg)    raw: reply code or -1
#   char* ftp_list(c, path, int* out_len)    LIST (path may be 0)
#   char* ftp_nlst(c, path, int* out_len)    NLST (path may be 0)
#   char* ftp_mlsd(c, path, int* out_len)    MLSD (path may be 0)
#   char* ftp_retr(c, path, int* out_len)    whole file into a buffer
#   int   ftp_retr_fd(c, path, int fd)       streams to fd; bytes or -1
#   int   ftp_stor(c, path, char* data, int len)
#   int   ftp_appe(c, path, char* data, int len)
#   void  ftp_set_max_transfer(c, int bytes)  cap for buffered reads
#   void  ftp_set_epsv(c, int enabled)        0 = PASV only
#   void  ftp_close(ftp_client* c)            closes TLS + sockets, frees c
#   char* ftp_error_string(int code)
# FTPS (see "TLS" below):
#   ftp_client* ftp_connect_tls(char* host, int port, int security,
#                               tls_config* cfg, int timeout_ms)
#   int   ftp_auth_tls(c, tls_config* cfg)   AUTH TLS on a plain session
#   int   ftp_prot(c, int private)           PBSZ 0 + PROT P (1) / C (0)
#   void  ftp_set_server_name(c, char* name) TLS SNI / name to verify
#   void  ftp_set_allow_insecure_login(c, int allow)
#   char* ftp_tls_error(c)                   tls.w's reason, or ""
#   ftp_security_none() / ftp_security_explicit() / ftp_security_implicit()
#   ftp_default_implicit_port()              990
# Buffers returned by ftp_list/nlst/mlsd/retr are NUL-terminated (the
# NUL is not counted in *out_len) and owned by the caller.
#
# Errors: c.error describes the most recent operation only. Each call
# starts by clearing it, so a 4xx/5xx reply (ftp_error_reply), a
# rejected argument, or an over-cap buffered transfer (its completion
# reply is consumed) leaves the session usable. A control-connection
# failure (I/O error, timeout, malformed or over-long reply, or QUIT)
# marks the client broken: every later call fails with ftp_error_io.
#
# Control connection: replies are "ddd text" lines; a multi-line reply
# opens with "ddd-" and ends at the first later line that starts with
# the same three digits followed by a space (lines in between may start
# with anything, including other digits). Lines end in CRLF (a bare LF
# is tolerated). Each line is capped at ftp_max_line() bytes and each
# reply at ftp_max_reply_lines() lines; exceeding either fails with
# ftp_error_overflow. Every socket wait (connect, control and data
# reads/writes) is bounded by the client's timeout_ms via poll(2) and
# SO_RCVTIMEO/SO_SNDTIMEO.
#
# Data connections are always passive. EPSV is tried first; the first
# time a server rejects it with a 5xx reply the client falls back to
# PASV and keeps using PASV for the rest of the session. SECURITY: the
# host part of a 227 PASV reply (h1,h2,h3,h4) is parsed but IGNORED -
# the data connection always goes to the control connection's peer
# address, exactly as EPSV mandates. Honouring the advertised address
# would let a hostile or compromised server point the client at an
# arbitrary third host (FTP bounce / SSRF into internal networks), so
# servers behind NAT that advertise a different address are only
# reachable when that address equals the control peer.
#
# Transfer ordering: the data connection is opened (EPSV/PASV +
# connect) before the transfer command is sent. The command must then
# answer with a 1xx preliminary reply (125/150); a 4xx/5xx instead
# aborts before any data moves. After the data connection reaches EOF
# (downloads) or is closed by the client (uploads), the completion reply
# must be 2xx (226/250). TYPE A transfers are delivered raw: CRLF line
# ends are not rewritten.
#
# Command injection: every user-supplied argument (user names,
# passwords, paths, raw ftp_command verbs/args) is rejected with
# ftp_error_bad_argument before anything is sent when it contains CR or
# LF (or exceeds ftp_max_argument() bytes), so one call can never
# smuggle a second command onto the control connection.
#
# TLS (RFC 4217). ftp_connect_tls with ftp_security_explicit() reads
# the plaintext 220 greeting and sends AUTH TLS; ftp_security_implicit()
# (port 990) handshakes before the greeting is read. Certificate
# validation is on by default: cfg 0 means a fresh tls_config (system
# trust store, hostname = the host argument); pass a tls_config to
# override the trust store. The caller keeps ownership of a passed cfg
# and must keep it alive until ftp_close (data connections reuse it).
#   - Never a silent downgrade: when TLS was requested and AUTH TLS is
#     refused (ftp_error_tls_refused) or the handshake fails
#     (ftp_error_tls) the client is marked broken, so no later call can
#     continue the session in plaintext. ftp_auth_tls called directly
#     on a plain session leaves it usable (plaintext) when the server
#     refuses, with c.error = ftp_error_tls_refused.
#   - Plaintext injection: bytes the server pipelined behind the 234
#     reply (already buffered before the handshake starts) break the
#     session with ftp_error_protocol instead of being read later as if
#     they had arrived over TLS.
#   - Data connections: once the control connection is protected, data
#     protection defaults to Private. Before the first transfer (or on
#     ftp_prot) the client sends "PBSZ 0" once and then "PROT P", and
#     every data connection is then a TLS client connection verified
#     against the same name and tls_config. ftp_prot(c, 0) selects
#     PROT C (clear data, protected control) explicitly. A rejected
#     PROT fails the transfer (ftp_error_reply); it never falls back.
#     ftp_prot(c, 1) on a session without TLS fails with ftp_error_tls.
#     A protected download must end with the server's TLS close_notify:
#     a data connection that closes without one is reported as a
#     truncated transfer (ftp_error_io). Uploads end with the client's
#     close_notify followed by the TCP close.
#   - LIMITATION: tls.w has no session resumption (no PSK / tickets),
#     so every data connection does a full handshake. Servers that
#     insist on TLS session reuse between control and data channels
#     (vsftpd require_ssl_reuse=YES, ProFTPD without
#     NoSessionReuseRequired, FileZilla Server by default) will refuse
#     the protected data connection (the transfer fails with
#     ftp_error_tls or ftp_error_reply, never plaintext).
#   - Credentials: ftp_login refuses (ftp_error_insecure, nothing sent)
#     to send a non-anonymous USER/PASS over an unencrypted control
#     connection unless the peer is loopback (127.0.0.0/8) or
#     ftp_set_allow_insecure_login(c, 1) was called. The anonymous
#     users "anonymous" and "ftp" are always allowed.
import lib.lib
import lib.net
import structures.string
import libs.standard.net.dns
import libs.standard.net.tls


struct ftp_client:
	int ctrl_fd
	int peer_ip
	int timeout_ms
	int error
	int reply_code
	string_builder* reply_text
	char* rbuf
	int rpos
	int rlen
	int use_epsv
	int max_transfer
	int broken
	tls_conn* tls
	tls_config* tls_cfg
	int tls_cfg_owned
	char* server_name
	int prot_want
	int prot_have
	int pbsz_done
	int allow_insecure_login
	tls_conn* data_tls


/* Limits and error codes */

const int ftp_default_port = 21
const int ftp_default_timeout_ms = 30000


# Longest control-connection line accepted (excluding CRLF).
const int ftp_max_line = 8192


# Most lines accepted in one (multi-line) reply.
const int ftp_max_reply_lines = 1024


# Longest user-supplied command argument.
const int ftp_max_argument = 4096


# Default cap on a buffered data transfer (LIST/NLST/MLSD/RETR).
const int ftp_default_max_transfer = 67108864
const int ftp_error_none = 0
const int ftp_error_connect = 1
const int ftp_error_timeout = 2


# Control or data connection failed or closed unexpectedly.
int ftp_error_io():
	return 3


# Malformed reply (bad code, bad EPSV/PASV/PWD text).
int ftp_error_protocol():
	return 4


# Line, reply, or buffered transfer larger than its cap.
int ftp_error_overflow():
	return 5


# CR/LF (or an over-long / empty) user-supplied argument.
int ftp_error_bad_argument():
	return 6


# The server answered with an unexpected (usually 4xx/5xx) reply; the
# code and text are in c.reply_code / c.reply_text.
int ftp_error_reply():
	return 7


const int ftp_error_resolve = 8


# TLS handshake (control or data connection) failed; ftp_tls_error(c)
# has tls.w's reason.
int ftp_error_tls():
	return 9


# The server refused AUTH TLS (reply in c.reply_code / c.reply_text).
const int ftp_error_tls_refused = 10


# ftp_login refused to send credentials over an unencrypted connection.
const int ftp_error_insecure = 11
const int ftp_security_none = 0


# RFC 4217: plaintext greeting, then AUTH TLS.
const int ftp_security_explicit = 1


# TLS from the first byte ("ftps", port 990).
const int ftp_security_implicit = 2
const int ftp_default_implicit_port = 990


char* ftp_error_string(int code):
	if (code == ftp_error_none): return c""
	if (code == ftp_error_connect): return c"connect failed"
	if (code == ftp_error_timeout): return c"timed out"
	if (code == ftp_error_io()): return c"connection error"
	if (code == ftp_error_protocol()): return c"malformed server reply"
	if (code == ftp_error_overflow()): return c"reply or transfer too large"
	if (code == ftp_error_bad_argument()): return c"invalid argument"
	if (code == ftp_error_reply()): return c"unexpected server reply"
	if (code == ftp_error_resolve): return c"host lookup failed"
	if (code == ftp_error_tls()): return c"TLS handshake failed"
	if (code == ftp_error_tls_refused): return c"server refused AUTH TLS"
	if (code == ftp_error_insecure): return c"refusing to send credentials without TLS"
	return c"unknown error"


int ftp_ok(ftp_client* c):
	return c.error == 0


# Records the first error only, so the root cause survives cleanup.
int ftp_fail(ftp_client* c, int code):
	if (c.error == 0): c.error = code
	return 0


# ftp_fail for functions whose failure value is -1.
int ftp_fail_neg(ftp_client* c, int code):
	ftp_fail(c, code)
	return (-1)


# A control-connection failure: the connection is out of step (or gone)
# and every later command fails fast with ftp_error_io.
int ftp_break(ftp_client* c, int code):
	c.broken = 1
	return ftp_fail(c, code)


int ftp_break_neg(ftp_client* c, int code):
	ftp_break(c, code)
	return (-1)


# Starts a public operation: clears the previous operation's error
# (a 4xx/5xx reply or a rejected argument leaves the session usable)
# unless the control connection is broken. Returns 1 to proceed.
int ftp_begin_op(ftp_client* c):
	if (c.broken != 0):
		c.error = 0
		return ftp_fail(c, ftp_error_io())
	c.error = 0
	return 1


void ftp_set_max_transfer(ftp_client* c, int bytes):
	c.max_transfer = bytes


void ftp_set_epsv(ftp_client* c, int enabled):
	c.use_epsv = enabled


/* Argument validation */

# 1 when text is a safe single command argument: non-empty, at most
# ftp_max_argument() bytes, and free of CR and LF.
int ftp_valid_argument(char* text):
	if (text == 0): return 0
	int i = 0
	while (text[i] != 0):
		int ch = text[i] & 255
		if ((ch == 13) || (ch == 10)): return 0
		i = i + 1
		if (i > ftp_max_argument): return 0
	return i > 0


# Verbs are 1-8 ASCII letters.
int ftp_valid_verb(char* verb):
	if (verb == 0): return 0
	int i = 0
	while (verb[i] != 0):
		int ch = verb[i] & 255
		int upper = (ch >= 'A') && (ch <= 'Z')
		int lower = (ch >= 'a') && (ch <= 'z')
		if ((upper == 0) && (lower == 0)): return 0
		i = i + 1
		if (i > 8): return 0
	return i > 0


/* Socket plumbing */

# lib/net.w's net_connect_timeout, then back to blocking with
# SO_RCVTIMEO/SO_SNDTIMEO armed. Returns the fd, or the negated
# ftp_error_* code.
int ftp_connect_fd(int ip, int port, int timeout_ms):
	int fd = net_connect_timeout(ip, port, timeout_ms)
	if (fd == -2): return 0 - ftp_error_timeout
	if (fd < 0): return 0 - ftp_error_connect
	if (socket_set_blocking(fd) < 0):
		close(fd)
		return 0 - ftp_error_connect
	socket_set_recv_timeout(fd, timeout_ms)
	socket_set_send_timeout(fd, timeout_ms)
	return fd


# Maps a negative recv/send result to an error code.
int ftp_io_error_code(int rc):
	if (rc == (0 - net_eagain())):
		return ftp_error_timeout
	return ftp_error_io()


# Sends all n bytes on a blocking socket. Returns 1, or 0 with *err set.
int ftp_send_all(int fd, char* data, int n, int* err):
	int total = 0
	while (total < n):
		int got = socket_send(fd, data + total, n - total, msg_nosignal())
		if (got > 0): total = total + got
		else if (got == (0 - 4)): got = 0
		else if (got == 0):
			*err = ftp_error_io()
			return 0
		else:
			*err = ftp_io_error_code(got)
			return 0
	return 1


/* Control connection */

# Wraps an already-connected control socket. peer_ip (host order) is
# where passive data connections go. The greeting is NOT read.
ftp_client* ftp_attach(int fd, int peer_ip, int timeout_ms):
	ftp_client* c = new ftp_client()
	c.ctrl_fd = fd
	c.peer_ip = peer_ip
	c.timeout_ms = timeout_ms
	c.error = 0
	c.reply_code = 0
	c.reply_text = string_new()
	c.rbuf = malloc(4096)
	c.rpos = 0
	c.rlen = 0
	c.use_epsv = 1
	c.max_transfer = ftp_default_max_transfer
	c.broken = 0
	c.tls = 0
	c.tls_cfg = 0
	c.tls_cfg_owned = 0
	c.server_name = 0
	c.prot_want = 0
	c.prot_have = 0
	c.pbsz_done = 0
	c.allow_insecure_login = 0
	c.data_tls = 0
	if (fd < 0): c.broken = 1
	return c


# Next control byte, or -1 with c.error set.
int ftp_read_byte(ftp_client* c):
	if (c.rpos >= c.rlen):
		if (c.ctrl_fd < 0): return ftp_break_neg(c, ftp_error_io())
		int got = 0
		if (c.tls != 0):
			# tls_read: 0 = close_notify, -1 = error (including a
			# SO_RCVTIMEO expiry, which tls.w cannot tell apart).
			got = tls_read(c.tls, c.rbuf, 4096)
			if (got < 0): return ftp_break_neg(c, ftp_error_io())
		else:
			got = socket_recv(c.ctrl_fd, c.rbuf, 4096, 0)
			while (got == (0 - 4)): got = socket_recv(c.ctrl_fd, c.rbuf, 4096, 0)
		if (got == 0): return ftp_break_neg(c, ftp_error_io())
		if (got < 0): return ftp_break_neg(c, ftp_io_error_code(got))
		c.rpos = 0
		c.rlen = got
	int b = c.rbuf[c.rpos] & 255
	c.rpos = c.rpos + 1
	return b


# Reads one line (CRLF or LF, both stripped) into line. Returns 1, or 0
# with c.error set.
int ftp_read_line(ftp_client* c, string_builder* line):
	string_clear(line)
	while (1):
		int b = ftp_read_byte(c)
		if (b < 0): return 0
		if (b == 10):
			if ((line.length > 0) && (line.data[line.length - 1] == 13)):
				line.length = line.length - 1
				line.data[line.length] = 0
			return 1
		if (line.length >= ftp_max_line): return ftp_break(c, ftp_error_overflow())
		string_append_char(line, b)


# Reply code of a line that starts with three digits (first 1-5), else
# -1. *sep receives the fourth byte (' ', '-', or 0 at end of line).
int ftp_line_code(char* line, int* sep):
	for i in range(3):
		int ch = line[i] & 255
		if ((ch < '0') || (ch > '9')): return (-1)
	int first = (line[0] & 255) - '0'
	if ((first < 1) || (first > 5)): return (-1)
	*sep = line[3] & 255
	return ((line[0] & 255) - '0') * 100 + ((line[1] & 255) - '0') * 10 + (line[2] & 255) - '0'


# Reads one complete (possibly multi-line) reply into c.reply_code and
# c.reply_text (lines joined with LF). Returns the code, or -1 with
# c.error set.
int ftp_read_reply(ftp_client* c):
	c.reply_code = 0
	string_clear(c.reply_text)
	if (c.broken != 0): return ftp_fail_neg(c, ftp_error_io())
	string_builder* line = string_new()
	if (ftp_read_line(c, line) == 0):
		string_free(line)
		return (-1)
	int sep = 0
	int code = ftp_line_code(line.data, &sep)
	if ((code < 0) || ((sep != ' ') && (sep != '-') && (sep != 0))):
		string_free(line)
		return ftp_break_neg(c, ftp_error_protocol())
	string_append(c.reply_text, line.data)
	if (sep == '-'):
		int lines = 1
		int done = 0
		while (done == 0):
			if (lines >= ftp_max_reply_lines):
				string_free(line)
				return ftp_break_neg(c, ftp_error_overflow())
			if (ftp_read_line(c, line) == 0):
				string_free(line)
				return (-1)
			lines = lines + 1
			string_append_char(c.reply_text, 10)
			string_append(c.reply_text, line.data)
			int end_sep = 0
			if ((ftp_line_code(line.data, &end_sep) == code) && ((end_sep == ' ') || (end_sep == 0))):
				done = 1
	string_free(line)
	c.reply_code = code
	return code


# Sends "VERB[ arg]\r\n" after validating both. Returns 1, or 0 with
# c.error set (nothing is sent on a validation failure).
int ftp_send_command(ftp_client* c, char* verb, char* arg):
	if (ftp_begin_op(c) == 0): return 0
	if (ftp_valid_verb(verb) == 0): return ftp_fail(c, ftp_error_bad_argument())
	if ((arg != 0) && (ftp_valid_argument(arg) == 0)): return ftp_fail(c, ftp_error_bad_argument())
	string_builder* out = string_new()
	string_append(out, verb)
	if (arg != 0):
		string_append_char(out, ' ')
		string_append(out, arg)
	string_append(out, c"\x0d\x0a")
	int err = 0
	int ok = 1
	if (c.tls != 0):
		if (tls_write(c.tls, out.data, out.length) != out.length):
			ok = 0
			err = ftp_error_io()
	else: ok = ftp_send_all(c.ctrl_fd, out.data, out.length, &err)
	string_free(out)
	if (ok == 0): return ftp_break(c, err)
	return 1


# Raw command: sends it and returns the reply code, or -1 on a
# transport/validation failure. A 4xx/5xx reply is NOT an error here.
int ftp_command(ftp_client* c, char* verb, char* arg):
	if (ftp_send_command(c, verb, arg) == 0): return (-1)
	return ftp_read_reply(c)


# Sends a command and expects a reply in the given class (2 = 2xx,
# 3 = 3xx). Returns 1, or 0 with c.error set.
int ftp_expect(ftp_client* c, char* verb, char* arg, int want_class):
	int code = ftp_command(c, verb, arg)
	if (code < 0): return 0
	if (code / 100 != want_class): return ftp_fail(c, ftp_error_reply())
	return 1


# TLS SNI / certificate name for AUTH TLS and protected data
# connections (copied). ftp_connect/ftp_connect_tls set it to the host
# argument; ftp_attach leaves it unset (no SNI, and a trust-store
# config then fails hostname verification unless it skips it).
void ftp_set_server_name(ftp_client* c, char* name):
	if (c.server_name != 0): free(c.server_name)
	c.server_name = 0
	if (name != 0): c.server_name = strclone(name)


# Permits a non-anonymous ftp_login over an unencrypted, non-loopback
# control connection.
void ftp_set_allow_insecure_login(ftp_client* c, int allow):
	c.allow_insecure_login = allow


# tls.w's description of the last TLS failure, or "".
char* ftp_tls_error(ftp_client* c):
	char* why = tls_last_error(c.tls_cfg)
	if (why == 0): return c""
	return why


# Adopts cfg (0 = a fresh default config owned by the client) as the
# config for the control and every data connection.
void ftp_use_tls_config(ftp_client* c, tls_config* cfg):
	if (cfg == 0):
		if (c.tls_cfg != 0): return
		c.tls_cfg = tls_config_new()
		c.tls_cfg_owned = 1
		return
	if (c.tls_cfg_owned != 0):
		tls_config_free(c.tls_cfg)
		c.tls_cfg_owned = 0
	c.tls_cfg = cfg


char* ftp_tls_name(ftp_client* c):
	if (c.server_name == 0): return c""
	return c.server_name


# Handshakes TLS over the control socket. Returns 1, or 0 with the
# session broken (ftp_error_tls).
int ftp_wrap_control(ftp_client* c, tls_config* cfg):
	ftp_use_tls_config(c, cfg)
	c.tls = tls_connect(c.ctrl_fd, ftp_tls_name(c), c.tls_cfg)
	if (c.tls == 0): return ftp_break(c, ftp_error_tls())
	# RFC 4217 section 9: data protection defaults to Private once the
	# control connection is protected (sent lazily, see ftp_prot).
	c.prot_want = 1
	c.prot_have = 0
	c.pbsz_done = 0
	return 1


# AUTH TLS (RFC 4217 section 4) on a plaintext control connection:
# expects 234, rejects plaintext the server pipelined behind it, then
# handshakes (cfg 0 = default config with certificate validation).
# Returns 1, or 0 with c.error set: ftp_error_tls_refused (session
# still usable in plaintext; the caller decides), ftp_error_protocol
# (injected plaintext; broken) or ftp_error_tls (broken).
int ftp_auth_tls(ftp_client* c, tls_config* cfg):
	if (ftp_begin_op(c) == 0): return 0
	if (c.tls != 0): return ftp_fail(c, ftp_error_bad_argument())
	int code = ftp_command(c, c"AUTH", c"TLS")
	if (code < 0): return 0
	if (code != 234): return ftp_fail(c, ftp_error_tls_refused)
	if (c.rpos < c.rlen):
		# Anything already buffered was sent in the clear after the 234
		# and must not be read as if it came over TLS.
		c.rpos = c.rlen
		return ftp_break(c, ftp_error_protocol())
	return ftp_wrap_control(c, cfg)


# Reads the greeting; RFC 959: it may be preceded by "120 ready in nnn
# minutes". Returns 1, or 0 with the session broken.
int ftp_read_greeting(ftp_client* c):
	int code = ftp_read_reply(c)
	while ((code >= 100) && (code < 200)): code = ftp_read_reply(c)
	if (code < 0): return 0
	if (code != 220): return ftp_break(c, ftp_error_reply())
	return 1


# Resolves host, connects (bounded by timeout_ms) and sets up security:
# ftp_security_none() (plain FTP), ftp_security_explicit() (greeting,
# then AUTH TLS) or ftp_security_implicit() (TLS, then greeting). Never
# returns 0: check c.error (non-zero = failed; a TLS failure or refusal
# breaks the session so it cannot continue in plaintext). The client
# must still be released with ftp_close.
ftp_client* ftp_connect_tls(char* host, int port, int security, tls_config* cfg, int timeout_ms):
	ftp_client* c = ftp_attach(-1, 0, timeout_ms)
	int ip = 0
	if ((host == 0) || (dns_resolve_ipv4(host, &ip) == 0)):
		ftp_fail(c, ftp_error_resolve)
		return c
	ftp_set_server_name(c, host)
	c.peer_ip = ip
	if ((security != ftp_security_none) && (security != ftp_security_explicit) && (security != ftp_security_implicit)):
		ftp_fail(c, ftp_error_bad_argument())
		return c
	int fd = ftp_connect_fd(ip, port, timeout_ms)
	if (fd < 0):
		ftp_fail(c, 0 - fd)
		return c
	c.ctrl_fd = fd
	c.broken = 0
	if (security == ftp_security_implicit):
		if (ftp_wrap_control(c, cfg) == 0):
			return c
	if (ftp_read_greeting(c) == 0):
		return c
	if (security == ftp_security_explicit):
		if (ftp_auth_tls(c, cfg) == 0):
			# TLS was requested: never continue in plaintext.
			c.broken = 1
	return c


ftp_client* ftp_connect(char* host, int port, int timeout_ms):
	return ftp_connect_tls(host, port, ftp_security_none, 0, timeout_ms)


void ftp_close(ftp_client* c):
	if (c == 0): return
	if (c.data_tls != 0): tls_conn_free(c.data_tls)
	if (c.tls != 0):
		# tls_close sends close_notify unless the TLS layer is broken.
		tls_close(c.tls)
	if (c.ctrl_fd >= 0): close(c.ctrl_fd)
	if (c.tls_cfg_owned != 0): tls_config_free(c.tls_cfg)
	if (c.server_name != 0): free(c.server_name)
	string_free(c.reply_text)
	free(c.rbuf)
	free(c)


/* Simple commands */

# 1 for the conventional anonymous user names (case-insensitive).
int ftp_is_anonymous_user(char* user):
	if (user == 0): return 0
	char* want = c"anonymous"
	if (((user[0] & 255) | 32) == 'f'): want = c"ftp"
	int i = 0
	while ((want[i] != 0) && (((user[i] & 255) | 32) == (want[i] & 255))): i = i + 1
	return (want[i] == 0) && (user[i] == 0)


# 1 when the control peer is in 127.0.0.0/8.
int ftp_peer_is_loopback(ftp_client* c):
	return ((c.peer_ip >> 24) & 255) == 127


int ftp_login(ftp_client* c, char* user, char* password):
	if (ftp_begin_op(c) == 0): return 0
	if ((c.tls == 0) && (c.allow_insecure_login == 0) && (ftp_peer_is_loopback(c) == 0) && (ftp_is_anonymous_user(user) == 0)):
		return ftp_fail(c, ftp_error_insecure)
	int code = ftp_command(c, c"USER", user)
	if (code < 0): return 0
	if (code == 230): return 1
	if (code != 331):
		# 332 (account required) is not supported.
		return ftp_fail(c, ftp_error_reply())
	if ((password == 0) || (password[0] == 0)):
		# Some servers accept an empty password; send a bare PASS.
		return ftp_expect(c, c"PASS", 0, 2)
	return ftp_expect(c, c"PASS", password, 2)


int ftp_login_anonymous(ftp_client* c):
	return ftp_login(c, c"anonymous", c"anonymous@")


int ftp_type_binary(ftp_client* c):
	return ftp_expect(c, c"TYPE", c"I", 2)


int ftp_type_ascii(ftp_client* c):
	return ftp_expect(c, c"TYPE", c"A", 2)


int ftp_cwd(ftp_client* c, char* path):
	return ftp_expect(c, c"CWD", path, 2)


int ftp_cdup(ftp_client* c):
	return ftp_expect(c, c"CDUP", 0, 2)


int ftp_mkd(ftp_client* c, char* path):
	return ftp_expect(c, c"MKD", path, 2)


int ftp_rmd(ftp_client* c, char* path):
	return ftp_expect(c, c"RMD", path, 2)


int ftp_delete(ftp_client* c, char* path):
	return ftp_expect(c, c"DELE", path, 2)


int ftp_rename(ftp_client* c, char* from, char* to):
	if (ftp_begin_op(c) == 0): return 0
	# Validate both before sending RNFR so a bad target never leaves a
	# dangling rename-from on the server.
	if ((ftp_valid_argument(from) == 0) || (ftp_valid_argument(to) == 0)):
		return ftp_fail(c, ftp_error_bad_argument())
	if (ftp_expect(c, c"RNFR", from, 3) == 0): return 0
	return ftp_expect(c, c"RNTO", to, 2)


int ftp_noop(ftp_client* c):
	return ftp_expect(c, c"NOOP", 0, 2)


# Sends QUIT; the session is over afterwards either way (ftp_close
# still has to be called to release it).
int ftp_quit(ftp_client* c):
	int ok = ftp_expect(c, c"QUIT", 0, 2)
	c.broken = 1
	return ok


# Directory name from a 257 reply text: the first "quoted" string with
# "" as an escaped quote. Returns a fresh string, or 0 when malformed.
char* ftp_parse_pwd_reply(char* text):
	int i = 0
	while ((text[i] != 0) && (text[i] != '"')): i = i + 1
	if (text[i] != '"'): return 0
	i = i + 1
	string_builder* out = string_new()
	while (1):
		int ch = text[i] & 255
		if ((ch == 0) || (ch == 10)):
			string_free(out)
			return 0
		if (ch == '"'):
			if (text[i + 1] == '"'):
				string_append_char(out, '"')
				i = i + 2
			else:
				char* result = out.data
				free(out)
				return result
		else:
			string_append_char(out, ch)
			i = i + 1


char* ftp_pwd(ftp_client* c):
	if (ftp_expect(c, c"PWD", 0, 2) == 0): return 0
	char* dir = ftp_parse_pwd_reply(c.reply_text.data)
	if (dir == 0): ftp_fail(c, ftp_error_protocol())
	return dir


# Largest value an int holds on this target.
int ftp_int_max():
	int half = 1 << (__word_size__ * 8 - 2)
	return half - 1 + half


# Parses the decimal digits at text[at..] up to a space/end. Returns the
# value, or -1 when there are none, a non-digit follows, or it overflows.
int ftp_parse_decimal(char* text, int at):
	int value = 0
	int digits = 0
	int limit = ftp_int_max()
	while ((text[at] != 0) && (text[at] != ' ') && (text[at] != 10)):
		int ch = text[at] & 255
		if ((ch < '0') || (ch > '9')): return (-1)
		int d = ch - '0'
		if (value > (limit - d) / 10): return (-1)
		value = value * 10 + d
		digits = digits + 1
		at = at + 1
	if (digits == 0): return (-1)
	return value


# SIZE (RFC 3659): the transfer size in bytes, or -1 (c.error set).
int ftp_size(ftp_client* c, char* path):
	if (ftp_expect(c, c"SIZE", path, 2) == 0): return (-1)
	char* text = c.reply_text.data
	if ((c.reply_code != 213) || (text[3] != ' ')): return ftp_fail_neg(c, ftp_error_protocol())
	int value = ftp_parse_decimal(text, 4)
	if (value < 0): ftp_fail(c, ftp_error_protocol())
	return value


# MDTM (RFC 3659): the "YYYYMMDDHHMMSS[.sss]" UTC timestamp as a fresh
# string, or 0 (c.error set).
char* ftp_mdtm(ftp_client* c, char* path):
	if (ftp_expect(c, c"MDTM", path, 2) == 0): return 0
	char* text = c.reply_text.data
	if ((c.reply_code != 213) || (text[3] != ' ')):
		ftp_fail(c, ftp_error_protocol())
		return 0
	int end = 4
	while ((text[end] != 0) && (text[end] != 10)):
		int ch = text[end] & 255
		if (((ch < '0') || (ch > '9')) && (ch != '.')):
			ftp_fail(c, ftp_error_protocol())
			return 0
		end = end + 1
	if (end - 4 < 14):
		ftp_fail(c, ftp_error_protocol())
		return 0
	char* stamp = malloc(end - 4 + 1)
	for i in range(4, end): stamp[i - 4] = text[i]
	stamp[end - 4] = 0
	return stamp


/* Passive mode */

# Port from a 229 reply "... (<d><d><d>port<d>)" (RFC 2428), or -1.
int ftp_parse_epsv_reply(char* text):
	int i = 0
	while ((text[i] != 0) && (text[i] != '(')): i = i + 1
	if (text[i] != '('): return (-1)
	int d = text[i + 1] & 255
	if ((d < 33) || (d > 126) || ((d >= '0') && (d <= '9'))): return (-1)
	if (((text[i + 2] & 255) != d) || ((text[i + 3] & 255) != d)): return (-1)
	int at = i + 4
	int port = 0
	int digits = 0
	while (((text[at] & 255) >= '0') && ((text[at] & 255) <= '9')):
		port = port * 10 + (text[at] & 255) - '0'
		digits = digits + 1
		if (digits > 5): return (-1)
		at = at + 1
	if ((digits == 0) || ((text[at] & 255) != d) || (text[at + 1] != ')')): return (-1)
	if ((port < 1) || (port > 65535)): return (-1)
	return port


# Port from a 227 reply "... h1,h2,h3,h4,p1,p2" (parentheses optional),
# or -1. The advertised host is validated but deliberately discarded:
# see the SECURITY note at the top of this file. *out_host receives it
# (host order) for diagnostics only.
int ftp_parse_pasv_reply(char* text, int* out_host):
	# Skip the reply code, then find the first digit of h1.
	int i = 0
	while (((text[i] & 255) >= '0') && ((text[i] & 255) <= '9')): i = i + 1
	while ((text[i] != 0) && (((text[i] & 255) < '0') || ((text[i] & 255) > '9'))): i = i + 1
	int host = 0
	int port = 0
	int field = 0
	while (field < 6):
		int value = 0
		int digits = 0
		while (((text[i] & 255) >= '0') && ((text[i] & 255) <= '9')):
			value = value * 10 + (text[i] & 255) - '0'
			digits = digits + 1
			if (digits > 3): return (-1)
			i = i + 1
		if ((digits == 0) || (value > 255)): return (-1)
		if (field < 4): host = (host << 8) | value
		else: port = (port << 8) | value
		field = field + 1
		if (field < 6):
			if (text[i] != ','): return (-1)
			i = i + 1
	if (port == 0): return (-1)
	*out_host = host
	return port


# Negotiates a passive data connection (EPSV, else PASV) to the control
# peer. Returns the connected data fd, or -1 with c.error set.
int ftp_open_passive(ftp_client* c):
	int port = (-1)
	if (c.use_epsv != 0):
		int code = ftp_command(c, c"EPSV", 0)
		if (code < 0): return (-1)
		if (code == 229):
			port = ftp_parse_epsv_reply(c.reply_text.data)
			if (port < 0): return ftp_fail_neg(c, ftp_error_protocol())
		else if (code / 100 == 5):
			# Not understood: fall back to PASV for the whole session.
			c.use_epsv = 0
		else: return ftp_fail_neg(c, ftp_error_reply())
	if (port < 0):
		int code2 = ftp_command(c, c"PASV", 0)
		if (code2 < 0): return (-1)
		if (code2 != 227): return ftp_fail_neg(c, ftp_error_reply())
		int advertised = 0
		port = ftp_parse_pasv_reply(c.reply_text.data, &advertised)
		if (port < 0): return ftp_fail_neg(c, ftp_error_protocol())
	int fd = ftp_connect_fd(c.peer_ip, port, c.timeout_ms)
	if (fd < 0): return ftp_fail_neg(c, 0 - fd)
	return fd


/* Data protection (RFC 4217 sections 8-9) */

# Brings the server's data protection level in line with c.prot_want:
# "PBSZ 0" once, then "PROT P" or "PROT C". Nothing is sent while the
# wanted level is already in force (a plain session with PROT C wanted
# sends nothing at all). Returns 1, or 0 with c.error set.
int ftp_sync_prot(ftp_client* c):
	if (c.prot_want == c.prot_have): return 1
	if (c.tls == 0):
		# PROT P needs a protected control connection; never fall back.
		return ftp_fail(c, ftp_error_tls())
	if (c.pbsz_done == 0):
		if (ftp_expect(c, c"PBSZ", c"0", 2) == 0): return 0
		c.pbsz_done = 1
	char* level = c"C"
	if (c.prot_want != 0): level = c"P"
	if (ftp_expect(c, c"PROT", level, 2) == 0): return 0
	c.prot_have = c.prot_want
	return 1


# Selects Private (private != 0: PROT P, TLS data connections) or Clear
# (PROT C) data protection and negotiates it now. Returns 1, or 0 with
# c.error set (ftp_error_tls when Private is asked for on a session
# without TLS; ftp_error_reply when the server rejects it).
int ftp_prot(ftp_client* c, int private):
	if (ftp_begin_op(c) == 0): return 0
	c.prot_want = private != 0
	return ftp_sync_prot(c)


/* Data connections */

# Reads from a data connection (TLS when c.data_tls is set). Returns
# bytes read, 0 at a clean end, or the negated ftp_error_* code.
int ftp_data_recv(ftp_client* c, int fd, char* buf, int n):
	if (c.data_tls != 0):
		int got = tls_read(c.data_tls, buf, n)
		if (got < 0):
			# Includes a TCP close without close_notify (truncation).
			return 0 - ftp_error_io()
		return got
	int raw = socket_recv(fd, buf, n, 0)
	while (raw == (0 - 4)): raw = socket_recv(fd, buf, n, 0)
	if (raw < 0): return 0 - ftp_io_error_code(raw)
	return raw


# Sends all n bytes on a data connection. Returns 1, or 0 with *err set.
int ftp_data_send_all(ftp_client* c, int fd, char* data, int n, int* err):
	if (c.data_tls != 0):
		if (n == 0): return 1
		if (tls_write(c.data_tls, data, n) != n):
			*err = ftp_error_io()
			return 0
		return 1
	return ftp_send_all(fd, data, n, err)


# Closes a data connection; a TLS one gets close_notify first (the
# end-of-file marker of a protected upload).
void ftp_data_close(ftp_client* c, int fd):
	if (c.data_tls != 0):
		tls_close(c.data_tls)
		c.data_tls = 0
	close(fd)


# Opens a data connection and issues the transfer command. Returns the
# data fd once a 1xx preliminary reply arrived (and, under PROT P, the
# TLS handshake on it succeeded; c.data_tls holds that session), else
# -1 (data connection closed, c.error set).
int ftp_begin_transfer(ftp_client* c, char* verb, char* arg):
	if (ftp_begin_op(c) == 0): return (-1)
	# Validate before EPSV/PASV so a bad argument sends nothing at all.
	if ((arg != 0) && (ftp_valid_argument(arg) == 0)):
		return ftp_fail_neg(c, ftp_error_bad_argument())
	if (ftp_sync_prot(c) == 0): return (-1)
	int fd = ftp_open_passive(c)
	if (fd < 0): return (-1)
	int code = ftp_command(c, verb, arg)
	if (code < 0):
		close(fd)
		return (-1)
	if (code / 100 != 1):
		close(fd)
		return ftp_fail_neg(c, ftp_error_reply())
	if (c.prot_have != 0):
		# RFC 4217 section 7: the client is the TLS client on the data
		# connection too, verified against the same name and config.
		c.data_tls = tls_connect(fd, ftp_tls_name(c), c.tls_cfg)
		if (c.data_tls == 0):
			close(fd)
			# The server answers the dead data connection (425/426/451);
			# consume that reply so the control connection stays in step.
			ftp_read_reply(c)
			c.error = 0
			return ftp_fail_neg(c, ftp_error_tls())
	return fd


# Reads the completion reply after the data connection is done.
int ftp_finish_transfer(ftp_client* c):
	int code = ftp_read_reply(c)
	if (code < 0): return 0
	if (code / 100 != 2): return ftp_fail(c, ftp_error_reply())
	return 1


# Downloads the data connection into a buffer (verb = LIST/NLST/MLSD/
# RETR). Returns the NUL-terminated buffer, or 0 with c.error set.
char* ftp_download(ftp_client* c, char* verb, char* path, int* out_len):
	*out_len = 0
	int fd = ftp_begin_transfer(c, verb, path)
	if (fd < 0): return 0
	string_builder* out = string_new()
	char* chunk = malloc(16384)
	int failed = 0
	while (1):
		int got = ftp_data_recv(c, fd, chunk, 16384)
		if (got == 0): break
		else if (got < 0):
			failed = 0 - got
			break
		else:
			if (out.length + got > c.max_transfer):
				failed = ftp_error_overflow()
				break
			string_append_bytes(out, chunk, got)
	free(chunk)
	ftp_data_close(c, fd)
	if (failed != 0):
		# Closing the data connection early makes the server answer
		# 426/451 (or 226 if it had already sent everything); consume
		# that reply so the control connection stays in step.
		ftp_read_reply(c)
		c.error = 0
		ftp_fail(c, failed)
		string_free(out)
		return 0
	if (ftp_finish_transfer(c) == 0):
		string_free(out)
		return 0
	*out_len = out.length
	char* data = out.data
	free(out)
	return data


char* ftp_list(ftp_client* c, char* path, int* out_len):
	return ftp_download(c, c"LIST", path, out_len)


char* ftp_nlst(ftp_client* c, char* path, int* out_len):
	return ftp_download(c, c"NLST", path, out_len)


char* ftp_mlsd(ftp_client* c, char* path, int* out_len):
	return ftp_download(c, c"MLSD", path, out_len)


char* ftp_retr(ftp_client* c, char* path, int* out_len):
	*out_len = 0
	if (ftp_begin_op(c) == 0): return 0
	if (path == 0):
		ftp_fail(c, ftp_error_bad_argument())
		return 0
	return ftp_download(c, c"RETR", path, out_len)


# Streams RETR path into fd (no size cap). Returns the byte count, or
# -1 with c.error set.
int ftp_retr_fd(ftp_client* c, char* path, int out_fd):
	if (ftp_begin_op(c) == 0): return (-1)
	if (path == 0): return ftp_fail_neg(c, ftp_error_bad_argument())
	int fd = ftp_begin_transfer(c, c"RETR", path)
	if (fd < 0): return (-1)
	char* chunk = malloc(16384)
	int total = 0
	int failed = 0
	while (failed == 0):
		int got = ftp_data_recv(c, fd, chunk, 16384)
		if (got == 0): break
		if (got < 0): failed = 0 - got
		else:
			int written = 0
			while ((written < got) && (failed == 0)):
				int w = write(out_fd, chunk + written, got - written)
				if (w <= 0): failed = ftp_error_io()
				else: written = written + w
			total = total + got
	free(chunk)
	ftp_data_close(c, fd)
	if (failed != 0):
		ftp_read_reply(c)
		c.error = 0
		ftp_fail(c, failed)
		return (-1)
	if (ftp_finish_transfer(c) == 0): return (-1)
	return total


# Uploads len bytes with verb (STOR/APPE). Returns 1, or 0 with c.error.
int ftp_upload(ftp_client* c, char* verb, char* path, char* data, int len):
	if (ftp_begin_op(c) == 0): return 0
	if ((path == 0) || (len < 0) || ((data == 0) && (len > 0))):
		return ftp_fail(c, ftp_error_bad_argument())
	int fd = ftp_begin_transfer(c, verb, path)
	if (fd < 0): return 0
	int err = 0
	int ok = ftp_data_send_all(c, fd, data, len, &err)
	# Closing the data connection is the end-of-file marker in stream mode.
	ftp_data_close(c, fd)
	if (ok == 0):
		ftp_read_reply(c)
		c.error = 0
		return ftp_fail(c, err)
	return ftp_finish_transfer(c)


int ftp_stor(ftp_client* c, char* path, char* data, int len):
	return ftp_upload(c, c"STOR", path, data, len)


int ftp_appe(ftp_client* c, char* path, char* data, int len):
	return ftp_upload(c, c"APPE", path, data, len)
