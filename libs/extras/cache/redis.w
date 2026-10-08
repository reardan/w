# Redis RESP2 client. Independent implementation informed by the Redis
# protocol/server, hiredis and redis-py; references in cache_clients.md.
import libs.extras.cache.connection


const int redis_simple = 1
const int redis_error = 2
const int redis_integer = 3
const int redis_bulk = 4
const int redis_array = 5
const int redis_nil = 6


# data is owned and length-delimited (also NUL-terminated). Integers keep
# their signed 64-bit decimal text even on x86. elements owns its children.
struct redis_reply:
	int kind
	char* data
	int length
	list[redis_reply*] elements


cache_connection* redis_connect(char* host, int port, int timeout_ms):
	return cache_connect(host, port, timeout_ms)


void redis_reply_free(redis_reply* r):
	if (r == 0): return
	if (r.data != 0): free(r.data)
	for i in range(r.elements.length): redis_reply_free(r.elements[i])
	list_free[redis_reply*](r.elements)
	free(r)


int redis_integer_valid(char* data, int length):
	if (length > 0 && data[0] == 45):
		return cache_decimal(data + 1, length - 1, c"9223372036854775808")
	return cache_decimal(data, length, c"9223372036854775807")


redis_reply* redis_read_reply(cache_connection* c, int depth):
	if (depth >= 64 || c.nodes <= 0):
		cache_fail(c, cache_error_limit)
		return 0
	c.nodes = c.nodes - 1
	string_builder* line = string_new()
	if (cache_line(c, line) == 0):
		string_free(line)
		return 0
	redis_reply* r = new redis_reply(0, 0, 0, new list[redis_reply*])
	int tag = line.data[0]
	char* payload = line.data + 1
	int n = line.length - 1
	if (line.length == 0):
		cache_fail(c, cache_error_protocol)
	else if (tag == 43 || tag == 45 || tag == 58):
		if (tag == 43): r.kind = redis_simple
		if (tag == 45): r.kind = redis_error
		if (tag == 58): r.kind = redis_integer
		if (tag == 58 && redis_integer_valid(payload, n) == 0):
			cache_fail(c, cache_error_protocol)
		else:
			r.data = cast(char*, malloc(n + 1))
			mem_copy(r.data, payload, n)
			r.data[n] = 0
			r.length = n
	else if (tag == 36 || tag == 42):
		if (n == 2 && payload[0] == 45 && payload[1] == 49):
			r.kind = redis_nil
		else:
			int count = cache_size(payload, n)
			if (count < 0): cache_fail(c, cache_error_protocol)
			else if (tag == 36):
				if (count > c.remaining - 2): cache_fail(c, cache_error_limit)
				else:
					r.kind = redis_bulk
					r.length = count
					r.data = cast(char*, malloc(count + 1))
					r.data[count] = 0
					if (cache_read(c, r.data, count)): cache_crlf(c)
			else:
				r.kind = redis_array
				if (count > c.nodes): cache_fail(c, cache_error_limit)
				else:
					for i in range(count):
						redis_reply* child = redis_read_reply(c, depth + 1)
						if (child == 0): break
						r.elements.push(child)
	else:
		cache_fail(c, cache_error_protocol)
	string_free(line)
	if (c.error != 0):
		redis_reply_free(r)
		return 0
	return r


# Binary-safe argv, borrowed until return. Each string carries an explicit
# length. No inline commands, printf formatting, retries or auto reconnect.
redis_reply* redis_command(cache_connection* c, list[string] args):
	if (cache_begin(c) == 0): return 0
	int size = 0
	int valid = args.length > 0 && args.length <= 65536
	for i in range(args.length):
		string arg = args[i]
		if (arg.length < 0 || arg.length > c.max_bytes - size || (arg.data == 0 && arg.length > 0)):
			valid = 0
			break
		size = size + arg.length
	if (valid == 0):
		cache_fail(c, cache_error_argument)
		return 0
	string_builder* header = string_new()
	string_append_char(header, 42)
	string_append_int(header, args.length)
	string_append(header, c"\x0d\x0a")
	int ok = cache_write(c, header.data, header.length)
	for i in range(args.length):
		if (ok == 0): break
		string arg = args[i]
		string_clear(header)
		string_append_char(header, 36)
		string_append_int(header, arg.length)
		string_append(header, c"\x0d\x0a")
		ok = cache_write(c, header.data, header.length)
		if (ok): ok = cache_write(c, arg.data, arg.length)
		if (ok): ok = cache_write(c, c"\x0d\x0a", 2)
	string_free(header)
	if (ok == 0): return 0
	redis_reply* r = redis_read_reply(c, 0)
	if (r != 0 && r.kind == redis_error): c.error = cache_error_server
	return r


redis_reply* redis_ping(cache_connection* c):
	list[string] args = new list[string]
	args.push("PING")
	redis_reply* r = redis_command(c, args)
	list_free[string](args)
	return r


redis_reply* redis_get(cache_connection* c, string key):
	list[string] args = new list[string]
	args.push("GET")
	args.push(key)
	redis_reply* r = redis_command(c, args)
	list_free[string](args)
	return r


redis_reply* redis_set(cache_connection* c, string key, string value):
	list[string] args = new list[string]
	args.push("SET")
	args.push(key)
	args.push(value)
	redis_reply* r = redis_command(c, args)
	list_free[string](args)
	return r


redis_reply* redis_del(cache_connection* c, string key):
	list[string] args = new list[string]
	args.push("DEL")
	args.push(key)
	redis_reply* r = redis_command(c, args)
	list_free[string](args)
	return r
