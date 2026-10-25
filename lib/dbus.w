/*
lib.dbus: a small D-Bus client with no libdbus dependency — the version 1
wire protocol in little-endian byte order, unix-socket transports (path
and abstract addresses), SASL EXTERNAL authentication, message building
and parsing, and blocking or polled receive. Enough for a bus peer that
exports objects and answers method calls; graphics.ui.accessibility_atspi
is the first user (docs/projects/accessibility.md).

	dbus_conn* bus = dbus_open(dbus_session_address())
	dbus_buf* body = dbus_body(bus)
	dbus_put_string(body, c"org.a11y.Bus")
	...
	dbus_message reply
	if (dbus_call_sync(bus, &reply, 2000, c"org.freedesktop.DBus", path, iface, member, c"s") == 1): ...
	dbus_message_free(&reply)

Outgoing messages are built in two buffers: the caller writes the body
into dbus_body(conn) with the dbus_put_* writers (each aligns itself
relative to the body start, which the header pads to 8), then one of
dbus_call / dbus_reply / dbus_error_reply / dbus_signal writes the header
and sends both. Incoming messages own their bytes; every string field
and dbus_read_string result points into them and is NUL-terminated, as
the wire format guarantees. Big-endian peers are not supported: their
messages are rejected by the parser and dropped.
*/
import lib.lib
import lib.net
import lib.poll
import lib.env
import lib.bytes


const int DBUS_METHOD_CALL = 1
const int DBUS_METHOD_RETURN = 2
const int DBUS_ERROR = 3
const int DBUS_SIGNAL = 4
const int DBUS_NO_REPLY_EXPECTED = 1

const int DBUS_FIELD_PATH = 1
const int DBUS_FIELD_INTERFACE = 2
const int DBUS_FIELD_MEMBER = 3
const int DBUS_FIELD_ERROR_NAME = 4
const int DBUS_FIELD_REPLY_SERIAL = 5
const int DBUS_FIELD_DESTINATION = 6
const int DBUS_FIELD_SENDER = 7
const int DBUS_FIELD_SIGNATURE = 8

# Largest message accepted from the bus (the specification's 128 MiB).
const int dbus_max_message = 134217728


struct dbus_buf:
	char* data
	int length
	int capacity


void dbus_buf_init(dbus_buf* b):
	b.data = 0
	b.length = 0
	b.capacity = 0


void dbus_buf_free(dbus_buf* b):
	free(b.data)
	dbus_buf_init(b)


void dbus_buf_reserve(dbus_buf* b, int extra):
	int need = b.length + extra
	if (need <= b.capacity): return
	int cap = b.capacity * 2
	if (cap < 256): cap = 256
	while (cap < need): cap = cap * 2
	char* d = cast(char*, malloc(cap))
	for i in range(b.length): d[i] = b.data[i]
	free(b.data)
	b.data = d
	b.capacity = cap


void dbus_put_byte(dbus_buf* b, int v):
	dbus_buf_reserve(b, 1)
	b.data[b.length] = v & 255
	b.length = b.length + 1


void dbus_put_bytes(dbus_buf* b, char* s, int n):
	dbus_buf_reserve(b, n)
	for i in range(n): b.data[b.length + i] = s[i]
	b.length = b.length + n


# Zero-pad to a multiple of align (1, 2, 4 or 8).
void dbus_pad(dbus_buf* b, int align):
	while ((b.length & (align - 1)) != 0): dbus_put_byte(b, 0)


void dbus_put_u16(dbus_buf* b, int v):
	dbus_pad(b, 2)
	dbus_put_byte(b, v)
	dbus_put_byte(b, v >> 8)


void dbus_put_u32(dbus_buf* b, int v):
	dbus_pad(b, 4)
	dbus_put_byte(b, v)
	dbus_put_byte(b, v >> 8)
	dbus_put_byte(b, v >> 16)
	dbus_put_byte(b, v >> 24)


void dbus_put_i32(dbus_buf* b, int v):
	dbus_put_u32(b, v)


void dbus_put_bool(dbus_buf* b, int v):
	if (v): dbus_put_u32(b, 1)
	else: dbus_put_u32(b, 0)


# An integer as an IEEE 754 double ('d'), built without float64 so the
# module stays usable on 32-bit targets. Exact for |v| < 2^31.
void dbus_put_double_int(dbus_buf* b, int v):
	dbus_pad(b, 8)
	int sign = 0
	if (v < 0):
		sign = 1
		v = 0 - v
	int hi = 0
	int lo = 0
	if (v != 0):
		int p = 0
		while ((v >> (p + 1)) != 0): p = p + 1
		int frac = v - (1 << p)
		hi = (1023 + p) << 20
		if (p <= 20): hi = hi | (frac << (20 - p))
		else:
			hi = hi | (frac >> (p - 20))
			lo = frac << (52 - p)
	if (sign): hi = hi | (1 << 31)
	dbus_put_byte(b, lo)
	dbus_put_byte(b, lo >> 8)
	dbus_put_byte(b, lo >> 16)
	dbus_put_byte(b, lo >> 24)
	dbus_put_byte(b, hi)
	dbus_put_byte(b, hi >> 8)
	dbus_put_byte(b, hi >> 16)
	dbus_put_byte(b, hi >> 24)


void dbus_put_string_n(dbus_buf* b, char* s, int n):
	dbus_put_u32(b, n)
	dbus_put_bytes(b, s, n)
	dbus_put_byte(b, 0)


void dbus_put_string(dbus_buf* b, char* s):
	dbus_put_string_n(b, s, strlen(s))


void dbus_put_path(dbus_buf* b, char* s):
	dbus_put_string(b, s)


void dbus_put_sig(dbus_buf* b, char* s):
	int n = strlen(s)
	dbus_put_byte(b, n)
	dbus_put_bytes(b, s, n)
	dbus_put_byte(b, 0)


# Struct and dict-entry starts are 8-aligned.
void dbus_put_struct(dbus_buf* b):
	dbus_pad(b, 8)


# Start an array whose elements align to elem_align; returns the mark
# dbus_array_end needs. The length excludes the padding before the
# first element.
int dbus_array_begin(dbus_buf* b, int elem_align):
	dbus_put_u32(b, 0)
	int mark = b.length
	dbus_pad(b, elem_align)
	return mark


void dbus_array_end(dbus_buf* b, int mark, int elem_align):
	int start = (mark + elem_align - 1) & (0 - elem_align)
	int n = b.length - start
	if (n < 0): n = 0
	b.data[mark - 4] = n & 255
	b.data[mark - 3] = (n >> 8) & 255
	b.data[mark - 2] = (n >> 16) & 255
	b.data[mark - 1] = (n >> 24) & 255


# Alignment of the type whose code starts a signature element.
int dbus_type_align(int code):
	if ((code == 'y') || (code == 'g') || (code == 'v')): return 1
	if ((code == 'n') || (code == 'q')): return 2
	if ((code == 'x') || (code == 't') || (code == 'd') || (code == '(') || (code == '{')): return 8
	return 4


# Index just past the complete type starting at sig[i], or -1 when the
# signature is malformed there.
int dbus_sig_next(char* sig, int i):
	int c = sig[i]
	if (c == 0): return 0 - 1
	if (c == 'a'): return dbus_sig_next(sig, i + 1)
	if ((c == '(') || (c == '{')):
		int close = ')'
		if (c == '{'): close = '}'
		int j = i + 1
		while (sig[j] != close):
			j = dbus_sig_next(sig, j)
			if (j < 0): return 0 - 1
		return j + 1
	return i + 1


struct dbus_reader:
	char* data
	int length
	int pos
	int failed


void dbus_reader_init(dbus_reader* r, char* data, int length):
	r.data = data
	r.length = length
	r.pos = 0
	r.failed = 0


int dbus_reader_need(dbus_reader* r, int n):
	if (r.failed || (n < 0) || (r.pos + n > r.length)):
		r.failed = 1
		return 0
	return 1


void dbus_read_align(dbus_reader* r, int align):
	int p = (r.pos + align - 1) & (0 - align)
	if (p > r.length):
		r.failed = 1
		return
	r.pos = p


int dbus_read_byte(dbus_reader* r):
	if (!dbus_reader_need(r, 1)): return 0
	int v = r.data[r.pos] & 255
	r.pos = r.pos + 1
	return v


int dbus_read_u32(dbus_reader* r):
	dbus_read_align(r, 4)
	if (!dbus_reader_need(r, 4)): return 0
	int v = load_le32(&r.data[r.pos])
	r.pos = r.pos + 4
	return v


# Signed 32-bit, sign-extended to the word.
int dbus_read_i32(dbus_reader* r):
	int v = dbus_read_u32(r)
	if ((__word_size__ == 8) && (((v >> 31) & 1) != 0)): v = v - (1 << 32)
	return v


int dbus_read_bool(dbus_reader* r):
	return dbus_read_u32(r) != 0


# A string, object path (or, via dbus_read_sig, signature) in place:
# NUL-terminated inside the message. length may be 0.
char* dbus_read_string(dbus_reader* r, int* length):
	int n = dbus_read_u32(r)
	if (!dbus_reader_need(r, n + 1)): return c""
	char* s = &r.data[r.pos]
	if (s[n] != 0):
		r.failed = 1
		return c""
	r.pos = r.pos + n + 1
	if (length != 0): length[0] = n
	return s


char* dbus_read_sig(dbus_reader* r):
	int n = dbus_read_byte(r)
	if (!dbus_reader_need(r, n + 1)): return c""
	char* s = &r.data[r.pos]
	if (s[n] != 0):
		r.failed = 1
		return c""
	r.pos = r.pos + n + 1
	return s


# Skip one value of the complete type at sig[i]; returns the index just
# past that type. Variants nest at most 64 deep.
int dbus_skip_depth(dbus_reader* r, char* sig, int i, int depth):
	int c = sig[i]
	if ((depth > 64) || (c == 0)):
		r.failed = 1
		return 0 - 1
	if (c == 'y'):
		dbus_read_byte(r)
		return i + 1
	if ((c == 'n') || (c == 'q')):
		dbus_read_align(r, 2)
		dbus_reader_need(r, 2)
		r.pos = r.pos + 2
		return i + 1
	if ((c == 'b') || (c == 'i') || (c == 'u') || (c == 'h')):
		dbus_read_u32(r)
		return i + 1
	if ((c == 'x') || (c == 't') || (c == 'd')):
		dbus_read_align(r, 8)
		if (dbus_reader_need(r, 8)): r.pos = r.pos + 8
		return i + 1
	if ((c == 's') || (c == 'o')):
		dbus_read_string(r, 0)
		return i + 1
	if (c == 'g'):
		dbus_read_sig(r)
		return i + 1
	if (c == 'v'):
		char* inner = dbus_read_sig(r)
		if (dbus_sig_next(inner, 0) != strlen(inner)):
			r.failed = 1
			return 0 - 1
		dbus_skip_depth(r, inner, 0, depth + 1)
		return i + 1
	if (c == 'a'):
		int n = dbus_read_u32(r)
		int next = dbus_sig_next(sig, i + 1)
		if (next < 0):
			r.failed = 1
			return 0 - 1
		dbus_read_align(r, dbus_type_align(sig[i + 1]))
		if (dbus_reader_need(r, n)): r.pos = r.pos + n
		return next
	if ((c == '(') || (c == '{')):
		int close = ')'
		if (c == '{'): close = '}'
		dbus_read_align(r, 8)
		int j = i + 1
		while ((sig[j] != close) && (r.failed == 0)):
			j = dbus_skip_depth(r, sig, j, depth + 1)
			if (j < 0): return 0 - 1
		return j + 1
	r.failed = 1
	return 0 - 1


int dbus_skip(dbus_reader* r, char* sig, int i):
	return dbus_skip_depth(r, sig, i, 0)


struct dbus_message:
	int type
	int flags
	int serial
	int reply_serial
	char* path
	char* interface
	char* member
	char* error_name
	char* destination
	char* sender
	char* signature
	char* body
	int body_length
	char* raw              # owned; every string above points into it


void dbus_message_init(dbus_message* m):
	m.type = 0
	m.flags = 0
	m.serial = 0
	m.reply_serial = 0
	m.path = c""
	m.interface = c""
	m.member = c""
	m.error_name = c""
	m.destination = c""
	m.sender = c""
	m.signature = c""
	m.body = 0
	m.body_length = 0
	m.raw = 0


void dbus_message_free(dbus_message* m):
	free(m.raw)
	dbus_message_init(m)


# Bytes a complete message needs, from its first 16, or -1 when the
# header is not a little-endian version 1 message within limits.
int dbus_message_size(char* head):
	if ((head[0] != 'l') || (head[3] != 1)): return 0 - 1
	int body = load_le32(&head[4])
	int fields = load_le32(&head[12])
	if ((body < 0) || (fields < 0) || (body > dbus_max_message) || (fields > dbus_max_message)): return 0 - 1
	return ((16 + fields + 7) & (0 - 8)) + body


# Parse a complete message whose bytes the message takes ownership of.
# Returns 0 (and frees raw) when it is malformed.
int dbus_message_parse(dbus_message* m, char* raw, int total):
	dbus_message_init(m)
	m.raw = raw
	if ((total < 16) || (dbus_message_size(raw) != total)):
		dbus_message_free(m)
		return 0
	m.type = raw[1] & 255
	m.flags = raw[2] & 255
	m.body_length = load_le32(&raw[4])
	m.serial = load_le32(&raw[8])
	int fields_end = 16 + load_le32(&raw[12])
	dbus_reader r
	dbus_reader_init(&r, raw, fields_end)
	r.pos = 16
	while ((r.pos < fields_end) && (r.failed == 0)):
		dbus_read_align(&r, 8)
		if (r.pos >= fields_end): break
		int code = dbus_read_byte(&r)
		char* sig = dbus_read_sig(&r)
		if (((code == DBUS_FIELD_PATH) && (sig[0] == 'o')) || (((code == DBUS_FIELD_INTERFACE) || (code == DBUS_FIELD_MEMBER) || (code == DBUS_FIELD_ERROR_NAME) || (code == DBUS_FIELD_DESTINATION) || (code == DBUS_FIELD_SENDER)) && (sig[0] == 's'))):
			char* s = dbus_read_string(&r, 0)
			if (code == DBUS_FIELD_PATH): m.path = s
			if (code == DBUS_FIELD_INTERFACE): m.interface = s
			if (code == DBUS_FIELD_MEMBER): m.member = s
			if (code == DBUS_FIELD_ERROR_NAME): m.error_name = s
			if (code == DBUS_FIELD_DESTINATION): m.destination = s
			if (code == DBUS_FIELD_SENDER): m.sender = s
		else if ((code == DBUS_FIELD_REPLY_SERIAL) && (sig[0] == 'u')): m.reply_serial = dbus_read_u32(&r)
		else if ((code == DBUS_FIELD_SIGNATURE) && (sig[0] == 'g')): m.signature = dbus_read_sig(&r)
		else if (dbus_sig_next(sig, 0) == strlen(sig)): dbus_skip(&r, sig, 0)
		else: r.failed = 1
	if (r.failed || (m.type < DBUS_METHOD_CALL) || (m.type > DBUS_SIGNAL)):
		dbus_message_free(m)
		return 0
	m.body = &raw[(fields_end + 7) & (0 - 8)]
	return 1


# A reader over a parsed message's body.
void dbus_message_reader(dbus_message* m, dbus_reader* r):
	dbus_reader_init(r, m.body, m.body_length)


struct dbus_conn:
	int fd
	int serial
	char* unique_name      # owned, from Hello
	dbus_buf in            # received bytes not yet parsed into messages
	dbus_buf head          # outgoing header scratch
	dbus_buf body          # the outgoing body being written
	int failed


int dbus_hex_digit(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')): return c - 'A' + 10
	return 0 - 1


char* dbus_strdup(char* s):
	int n = strlen(s)
	char* out = cast(char*, malloc(n + 1))
	for i in range(n + 1): out[i] = s[i]
	return out


# Decode %XX escapes in a D-Bus address value into a fresh string.
char* dbus_address_unescape(char* s, int n):
	char* out = cast(char*, malloc(n + 1))
	int k = 0
	int i = 0
	while (i < n):
		int c = s[i] & 255
		if ((c == '%') && (i + 2 < n)):
			int hi = dbus_hex_digit(s[i + 1])
			int lo = dbus_hex_digit(s[i + 2])
			if ((hi >= 0) && (lo >= 0)):
				c = hi * 16 + lo
				i = i + 2
		out[k] = c
		k = k + 1
		i = i + 1
	out[k] = 0
	return out


# The value of key in one "transport:key=value,..." address entry
# (entry spans n bytes), unescaped, or 0.
char* dbus_address_value(char* entry, int n, char* key):
	int colon = 0
	while ((colon < n) && (entry[colon] != ':')): colon = colon + 1
	int i = colon + 1
	int klen = strlen(key)
	while (i < n):
		int end = i
		while ((end < n) && (entry[end] != ',')): end = end + 1
		int eq = i
		while ((eq < end) && (entry[eq] != '=')): eq = eq + 1
		if ((eq - i == klen) && (eq < end)):
			int same = 1
			for k in range(klen):
				if (entry[i + k] != key[k]): same = 0
			if (same): return dbus_address_unescape(&entry[eq + 1], end - eq - 1)
		i = end + 1
	return 0


# Connect to a unix socket by filesystem path or (abstract = 1) by
# abstract name. Returns the fd or a negative errno.
int dbus_connect_unix(char* name, int abstract):
	if (abstract == 0): return socket_connect_unix_path(name)
	int n = strlen(name)
	if (n > 106): return 0 - 22
	char* addr = cast(char*, malloc(SOCKADDR_UN_SIZE))
	for i in range(SOCKADDR_UN_SIZE): addr[i] = 0
	save_int16(addr, socket_abi_family_word(af_unix))
	for i in range(n): addr[3 + i] = name[i]
	int fd = socket_unix_stream()
	if (fd < 0):
		free(addr)
		return fd
	int err = sys_connect(fd, cast(int, addr), 3 + n)
	free(addr)
	if (err < 0):
		close(fd)
		return err
	return fd


# Connect to the first usable unix entry of an address list
# ("unix:path=...;unix:abstract=..."). Returns the fd or -1.
int dbus_connect_address(char* address):
	if (address == 0): return 0 - 1
	int total = strlen(address)
	int i = 0
	while (i < total):
		int end = i
		while ((end < total) && (address[end] != ';')): end = end + 1
		char* entry = &address[i]
		int n = end - i
		if ((n > 5) && (entry[0] == 'u') && (entry[1] == 'n') && (entry[2] == 'i') && (entry[3] == 'x') && (entry[4] == ':')):
			char* path = dbus_address_value(entry, n, c"path")
			int fd = 0 - 1
			if (path != 0):
				fd = dbus_connect_unix(path, 0)
				free(path)
			else:
				char* name = dbus_address_value(entry, n, c"abstract")
				if (name != 0):
					fd = dbus_connect_unix(name, 1)
					free(name)
			if (fd >= 0): return fd
		i = end + 1
	return 0 - 1


# The session bus address: $DBUS_SESSION_BUS_ADDRESS, else the
# conventional $XDG_RUNTIME_DIR/bus socket. A fresh string, or 0.
char* dbus_session_address():
	char* env = env_get(c"DBUS_SESSION_BUS_ADDRESS")
	if ((env != 0) && (env[0] != 0)): return dbus_strdup(env)
	char* runtime = env_get(c"XDG_RUNTIME_DIR")
	if ((runtime == 0) || (runtime[0] == 0)): return 0
	char* prefix = c"unix:path="
	int a = strlen(prefix)
	int b = strlen(runtime)
	char* out = cast(char*, malloc(a + b + 5))
	for i in range(a): out[i] = prefix[i]
	for i in range(b): out[a + i] = runtime[i]
	out[a + b] = '/'
	out[a + b + 1] = 'b'
	out[a + b + 2] = 'u'
	out[a + b + 3] = 's'
	out[a + b + 4] = 0
	return out


# Write all of data, waiting for the socket to drain when it is full.
int dbus_write_all(dbus_conn* c, char* data, int n):
	int sent = 0
	while (sent < n):
		int k = socket_send(c.fd, &data[sent], n - sent, msg_nosignal())
		if (k == 0 - net_eagain()):
			if (poll_single(c.fd, poll_out, 1000) <= 0):
				c.failed = 1
				return 0
		else if (k <= 0):
			c.failed = 1
			return 0
		else: sent = sent + k
	return 1


# Read one CRLF-terminated authentication line (blocking, bounded).
int dbus_auth_line(int fd, char* line, int cap):
	int n = 0
	while (n < cap - 1):
		if (poll_single(fd, poll_in, 2000) <= 0): return 0 - 1
		char[1] ch
		if (read(fd, &ch[0], 1) != 1): return 0 - 1
		line[n] = ch[0]
		n = n + 1
		if ((n >= 2) && (line[n - 2] == 13) && (line[n - 1] == 10)):
			line[n - 2] = 0
			return n - 2
	return 0 - 1


# SASL EXTERNAL: the uid in decimal, hex-encoded.
int dbus_authenticate(dbus_conn* c):
	char[24] digits
	int uid = getuid()
	int nd = 0
	if (uid == 0):
		digits[0] = '0'
		nd = 1
	while (uid > 0):
		digits[nd] = '0' + uid % 10
		uid = uid / 10
		nd = nd + 1
	dbus_buf line
	dbus_buf_init(&line)
	dbus_put_byte(&line, 0)
	dbus_put_bytes(&line, c"AUTH EXTERNAL ", 14)
	char* hex = c"0123456789abcdef"
	int k = nd - 1
	while (k >= 0):
		dbus_put_byte(&line, hex[(digits[k] >> 4) & 15])
		dbus_put_byte(&line, hex[digits[k] & 15])
		k = k - 1
	dbus_put_bytes(&line, c"\r\n", 2)
	int ok = dbus_write_all(c, line.data, line.length)
	dbus_buf_free(&line)
	if (!ok): return 0
	char[256] reply
	if (dbus_auth_line(c.fd, &reply[0], 256) < 3): return 0
	if ((reply[0] != 'O') || (reply[1] != 'K') || (reply[2] != ' ')): return 0
	return dbus_write_all(c, c"BEGIN\r\n", 7)


# Start a new outgoing body and return it for the dbus_put_* writers.
dbus_buf* dbus_body(dbus_conn* c):
	c.body.length = 0
	return &c.body


void dbus_head_string_field(dbus_buf* h, int code, char* sig, char* value):
	if (value == 0): return
	dbus_put_struct(h)
	dbus_put_byte(h, code)
	dbus_put_sig(h, sig)
	if (sig[0] == 'g'): dbus_put_sig(h, value)
	else: dbus_put_string(h, value)


# Frame the current body (signature sig) with a header and send it.
# Returns the message's serial, or 0 on failure.
int dbus_send(dbus_conn* c, int type, int flags, char* path, char* interface, char* member, char* destination, char* error_name, int reply_serial, char* sig):
	if ((c == 0) || c.failed): return 0
	c.serial = c.serial + 1
	dbus_buf* h = &c.head
	h.length = 0
	dbus_put_byte(h, 'l')
	dbus_put_byte(h, type)
	dbus_put_byte(h, flags)
	dbus_put_byte(h, 1)
	dbus_put_u32(h, c.body.length)
	dbus_put_u32(h, c.serial)
	int mark = dbus_array_begin(h, 8)
	dbus_head_string_field(h, DBUS_FIELD_PATH, c"o", path)
	dbus_head_string_field(h, DBUS_FIELD_INTERFACE, c"s", interface)
	dbus_head_string_field(h, DBUS_FIELD_MEMBER, c"s", member)
	dbus_head_string_field(h, DBUS_FIELD_ERROR_NAME, c"s", error_name)
	if (reply_serial != 0):
		dbus_put_struct(h)
		dbus_put_byte(h, DBUS_FIELD_REPLY_SERIAL)
		dbus_put_sig(h, c"u")
		dbus_put_u32(h, reply_serial)
	dbus_head_string_field(h, DBUS_FIELD_DESTINATION, c"s", destination)
	if ((sig != 0) && (sig[0] != 0)): dbus_head_string_field(h, DBUS_FIELD_SIGNATURE, c"g", sig)
	dbus_array_end(h, mark, 8)
	dbus_pad(h, 8)
	dbus_put_bytes(h, c.body.data, c.body.length)
	c.body.length = 0
	if (!dbus_write_all(c, h.data, h.length)): return 0
	return c.serial


int dbus_call(dbus_conn* c, char* destination, char* path, char* interface, char* member, char* sig):
	return dbus_send(c, DBUS_METHOD_CALL, 0, path, interface, member, destination, 0, 0, sig)


# Reply to a method call with the current body; a call flagged
# NO_REPLY_EXPECTED gets nothing (and 1 is returned).
int dbus_reply(dbus_conn* c, dbus_message* call, char* sig):
	if ((call.flags & DBUS_NO_REPLY_EXPECTED) != 0):
		c.body.length = 0
		return 1
	char* dest = call.sender
	if (dest[0] == 0): dest = 0
	return dbus_send(c, DBUS_METHOD_RETURN, DBUS_NO_REPLY_EXPECTED, 0, 0, 0, dest, 0, call.serial, sig) != 0


int dbus_error_reply(dbus_conn* c, dbus_message* call, char* name, char* text):
	dbus_buf* b = dbus_body(c)
	dbus_put_string(b, text)
	if ((call.flags & DBUS_NO_REPLY_EXPECTED) != 0):
		c.body.length = 0
		return 1
	char* dest = call.sender
	if (dest[0] == 0): dest = 0
	return dbus_send(c, DBUS_ERROR, DBUS_NO_REPLY_EXPECTED, 0, 0, 0, dest, name, call.serial, c"s") != 0


int dbus_signal(dbus_conn* c, char* path, char* interface, char* member, char* sig):
	return dbus_send(c, DBUS_SIGNAL, DBUS_NO_REPLY_EXPECTED, path, interface, member, 0, 0, 0, sig) != 0


# Move whatever the socket has into the receive buffer without blocking.
# Returns bytes read, 0 when none were waiting, -1 on EOF or error.
int dbus_fill(dbus_conn* c):
	dbus_buf_reserve(&c.in, 4096)
	int k = socket_recv(c.fd, &c.in.data[c.in.length], c.in.capacity - c.in.length, 0)
	if (k == 0 - net_eagain()): return 0
	if (k <= 0):
		c.failed = 1
		return 0 - 1
	c.in.length = c.in.length + k
	return k


# Take the next complete message without blocking: 1 with *m filled
# (free it with dbus_message_free), 0 when none is complete yet, -1
# once the connection has failed. Malformed messages are dropped.
int dbus_next(dbus_conn* c, dbus_message* m):
	while (1):
		if (c.failed): return 0 - 1
		if (c.in.length >= 16):
			int total = dbus_message_size(c.in.data)
			if (total < 0):
				c.failed = 1
				return 0 - 1
			if (c.in.length >= total):
				char* raw = cast(char*, malloc(total))
				for i in range(total): raw[i] = c.in.data[i]
				int rest = c.in.length - total
				for i in range(rest): c.in.data[i] = c.in.data[total + i]
				c.in.length = rest
				if (dbus_message_parse(m, raw, total)): return 1
				continue
		if (dbus_fill(c) <= 0):
			if (c.failed): return 0 - 1
			return 0


# Block up to timeout_ms for the next message.
int dbus_wait(dbus_conn* c, dbus_message* m, int timeout_ms):
	int left = timeout_ms
	while (1):
		int got = dbus_next(c, m)
		if (got != 0): return got
		if (left <= 0): return 0
		int step = 50
		if (left < step): step = left
		poll_single(c.fd, poll_in, step)
		left = left - step


# Send a call and block for its reply, discarding anything else that
# arrives meanwhile (only for setup, before objects are exported).
# Returns 1 with *reply filled for a method return, -1 (also filled)
# for an error reply, 0 on timeout or failure.
int dbus_call_sync(dbus_conn* c, dbus_message* reply, int timeout_ms, char* destination, char* path, char* interface, char* member, char* sig):
	dbus_message_init(reply)
	int serial = dbus_call(c, destination, path, interface, member, sig)
	if (serial == 0): return 0
	int left = timeout_ms
	while (left > 0):
		dbus_message m
		int got = dbus_wait(c, &m, 50)
		if (got < 0): return 0
		if (got == 1):
			if (((m.type == DBUS_METHOD_RETURN) || (m.type == DBUS_ERROR)) && (m.reply_serial == serial)):
				reply[0] = m
				if (m.type == DBUS_ERROR): return 0 - 1
				return 1
			dbus_message_free(&m)
		else: left = left - 50
	return 0


void dbus_close(dbus_conn* c):
	if (c == 0): return
	if (c.fd >= 0): close(c.fd)
	free(c.unique_name)
	dbus_buf_free(&c.in)
	dbus_buf_free(&c.head)
	dbus_buf_free(&c.body)
	free(c)


# Connect, authenticate and say Hello. The connection is non-blocking
# afterwards. Returns 0 when any step fails.
dbus_conn* dbus_open(char* address):
	int fd = dbus_connect_address(address)
	if (fd < 0): return 0
	dbus_conn* c = new dbus_conn()
	c.fd = fd
	c.serial = 0
	c.unique_name = 0
	c.failed = 0
	dbus_buf_init(&c.in)
	dbus_buf_init(&c.head)
	dbus_buf_init(&c.body)
	if (!dbus_authenticate(c)):
		dbus_close(c)
		return 0
	socket_set_nonblocking(fd)
	dbus_body(c)
	dbus_message reply
	if (dbus_call_sync(c, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"Hello", 0) != 1):
		dbus_message_free(&reply)
		dbus_close(c)
		return 0
	dbus_reader r
	dbus_message_reader(&reply, &r)
	char* name = dbus_read_string(&r, 0)
	if (r.failed == 0): c.unique_name = dbus_strdup(name)
	dbus_message_free(&reply)
	if (c.unique_name == 0):
		dbus_close(c)
		return 0
	return c
