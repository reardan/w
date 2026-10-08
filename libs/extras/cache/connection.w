# Shared, synchronous TCP transport for the optional cache clients (#496).
# See docs/projects/cache_clients.md for ownership, limits and references.
import lib.lib
import lib.net
import libs.standard.net.dns
import libs.standard.web.connection
import structures.string


const int cache_error_argument = 1
const int cache_error_resolve = 2
const int cache_error_connect = 3
const int cache_error_io = 4
const int cache_error_timeout = 5
const int cache_error_protocol = 6
const int cache_error_limit = 7
const int cache_error_server = 8


struct cache_connection:
	ConnectionContext* io
	int error
	int max_bytes
	int remaining
	int nodes


# Takes ownership of fd, including on setup failure. timeout <= 0 uses 5s.
cache_connection* cache_attach(int fd, int timeout_ms):
	cache_connection* c = new cache_connection(0, 0, 16777216, 0, 0)
	if (timeout_ms <= 0): timeout_ms = 5000
	if (fd < 0):
		c.error = cache_error_connect
	else if (socket_set_nonblocking(fd) < 0):
		close(fd)
		c.error = cache_error_io
	else:
		socket_set_nosigpipe(fd)
		c.io = connection_context_client(fd, timeout_ms, cache_error_io, cache_error_io, cache_error_timeout)
	return c


# Always returns an owned object; inspect error even when connect fails.
cache_connection* cache_connect(char* host, int port, int timeout_ms):
	cache_connection* c = cache_attach(-1, timeout_ms)
	if (host == 0 || port < 1 || port > 65535):
		c.error = cache_error_argument
		return c
	int ip = 0
	if (dns_resolve_ipv4(host, &ip) == 0):
		c.error = cache_error_resolve
		return c
	if (timeout_ms <= 0): timeout_ms = 5000
	int fd = net_connect_timeout(ip, port, timeout_ms)
	if (fd < 0):
		if (fd == -2): c.error = cache_error_timeout
		return c
	free(c)
	return cache_attach(fd, timeout_ms)


void cache_close(cache_connection* c):
	if (c == 0): return
	connection_context_destroy(c.io)
	free(c)


char* cache_error_string(int error):
	if (error == 0): return c""
	if (error == cache_error_argument): return c"invalid argument"
	if (error == cache_error_resolve): return c"host lookup failed"
	if (error == cache_error_connect): return c"connection failed"
	if (error == cache_error_io): return c"connection closed or I/O failed"
	if (error == cache_error_timeout): return c"timed out"
	if (error == cache_error_protocol): return c"malformed reply"
	if (error == cache_error_limit): return c"reply limit exceeded"
	if (error == cache_error_server): return c"server returned an error"
	return c"unknown cache error"


# Invalid arguments/server errors leave framing intact. All other failures
# close immediately; never retry a command whose effects may have occurred.
int cache_fail(cache_connection* c, int error):
	c.error = error
	if (error != cache_error_argument && error != cache_error_server):
		connection_context_destroy(c.io)
		c.io = 0
	return 0


int cache_begin(cache_connection* c):
	if (c.io == 0):
		if (c.error == 0): c.error = cache_error_io
		return 0
	c.error = 0
	if (c.max_bytes < 1 || c.max_bytes > 67108864):
		return cache_fail(c, cache_error_argument)
	c.remaining = c.max_bytes
	c.nodes = 65536
	return 1


int cache_io_failed(cache_connection* c):
	int error = c.io.error
	if (error == 0): error = cache_error_io
	return cache_fail(c, error)


int cache_write(cache_connection* c, char* data, int length):
	if (connection_context_write_all(c.io, data, length) == 0):
		return cache_io_failed(c)
	return 1


int cache_read(cache_connection* c, char* out, int length):
	if (length > c.remaining): return cache_fail(c, cache_error_limit)
	c.remaining = c.remaining - length
	if (connection_context_read_exact(c.io, out, length) == 0):
		return cache_io_failed(c)
	return 1


int cache_crlf(cache_connection* c):
	char[2] ending
	if (cache_read(c, ending, 2) == 0): return 0
	if (ending[0] != 13 || ending[1] != 10):
		return cache_fail(c, cache_error_protocol)
	return 1


# Strict CRLF (the shared HTTP reader deliberately also accepts bare LF).
int cache_line(cache_connection* c, string_builder* line):
	string_clear(line)
	char[1] ch
	while (1):
		if (cache_read(c, ch, 1) == 0): return 0
		if (ch[0] == 13):
			if (cache_read(c, ch, 1) == 0): return 0
			if (ch[0] == 10): return 1
			return cache_fail(c, cache_error_protocol)
		if (ch[0] == 10): return cache_fail(c, cache_error_protocol)
		if (line.length >= 8192): return cache_fail(c, cache_error_limit)
		string_append_char(line, ch[0])
	return 0


# Decimal validation without word-size truncation. Canonical unsigned text.
int cache_decimal(char* data, int length, char* maximum):
	int max_len = strlen(maximum)
	if (length < 1 || length > max_len): return 0
	if (length > 1 && data[0] == 48): return 0
	int order = 0
	for i in range(length):
		if (data[i] < 48 || data[i] > 57): return 0
		if (length == max_len && order == 0): order = data[i] - maximum[i]
	return order <= 0


int cache_size(char* data, int length):
	if (cache_decimal(data, length, c"67108864") == 0): return (-1)
	int value = 0
	for i in range(length): value = value * 10 + data[i] - 48
	return value
