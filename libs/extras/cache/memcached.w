# Memcached basic text protocol, with explicit replies (never noreply).
# Binary-safe values; keys are 1..250 bytes without whitespace/control bytes.
# References: official protocol/server, pymemcache and libmemcached, linked
# in docs/projects/cache_clients.md. No serialization or hashing policy.
import libs.extras.cache.connection


const int memcached_value = 1
const int memcached_not_found = 2
const int memcached_stored = 3
const int memcached_not_stored = 4
const int memcached_exists = 5
const int memcached_deleted = 6
const int memcached_touched = 7
const int memcached_number = 8
const int memcached_error = 9


# All strings are owned. data is a binary value, decimal counter, or server
# error text according to status. flags (uint32) and cas (uint64) stay decimal
# strings so their full ranges round-trip on both x86 and x64.
struct memcached_reply:
	int status
	char* data
	int length
	char* flags
	char* cas


cache_connection* memcached_connect(char* host, int port, int timeout_ms):
	return cache_connect(host, port, timeout_ms)


void memcached_reply_free(memcached_reply* r):
	if (r == 0): return
	if (r.data != 0): free(r.data)
	if (r.flags != 0): free(r.flags)
	if (r.cas != 0): free(r.cas)
	free(r)


int memcached_key_valid(string key):
	if (key.data == 0 || key.length < 1 || key.length > 250): return 0
	for i in range(key.length):
		int ch = key.data[i] & 255
		if (ch <= 32 || ch == 127): return 0
	return 1


int memcached_server_error(char* text):
	if (strcmp(text, c"ERROR") == 0): return 1
	if (starts_with(text, c"CLIENT_ERROR ")): return 1
	return starts_with(text, c"SERVER_ERROR ")


# Memcached response headers cannot contain embedded NUL bytes.
int memcached_line(cache_connection* c, string_builder* line):
	if (cache_line(c, line) == 0): return 0
	if (strlen(line.data) != line.length): return cache_fail(c, cache_error_protocol)
	return 1


memcached_reply* memcached_status_reply(cache_connection* c, string_builder* line):
	memcached_reply* r = new memcached_reply(0, 0, 0, 0, 0)
	if (string_equals(line, c"STORED")): r.status = memcached_stored
	else if (string_equals(line, c"NOT_STORED")): r.status = memcached_not_stored
	else if (string_equals(line, c"NOT_FOUND")): r.status = memcached_not_found
	else if (string_equals(line, c"EXISTS")): r.status = memcached_exists
	else if (string_equals(line, c"DELETED")): r.status = memcached_deleted
	else if (string_equals(line, c"TOUCHED")): r.status = memcached_touched
	else if (memcached_server_error(line.data)):
		r.status = memcached_error
		c.error = cache_error_server
	else if (cache_decimal(line.data, line.length, c"18446744073709551615")):
		r.status = memcached_number
	if (r.status == 0):
		memcached_reply_free(r)
		cache_fail(c, cache_error_protocol)
		return 0
	r.data = strclone(line.data)
	r.length = line.length
	return r


memcached_reply* memcached_read_status(cache_connection* c):
	string_builder* line = string_new()
	memcached_reply* r = 0
	if (memcached_line(c, line)): r = memcached_status_reply(c, line)
	string_free(line)
	return r


# Reads one key, optionally with its CAS token. Misses are distinct from
# empty values and transport failures. Consume END before allowing reuse.
memcached_reply* memcached_fetch(cache_connection* c, string key, int with_cas):
	if (cache_begin(c) == 0): return 0
	if (memcached_key_valid(key) == 0):
		cache_fail(c, cache_error_argument)
		return 0
	string_builder* line = string_from(c"get ")
	if (with_cas):
		string_clear(line)
		string_append(line, c"gets ")
	string_append_string(line, key)
	string_append(line, c"\x0d\x0a")
	int ok = cache_write(c, line.data, line.length)
	if (ok): ok = memcached_line(c, line)
	memcached_reply* r = new memcached_reply(0, 0, 0, 0, 0)
	if (ok && string_equals(line, c"END")):
		r.status = memcached_not_found
	else if (ok && memcached_server_error(line.data)):
		r.status = memcached_error
		r.data = strclone(line.data)
		r.length = line.length
		c.error = cache_error_server
	else if (ok):
		list[char*] fields = new list[char*]
		fields.push(line.data)
		for i in range(line.length):
			if (line.data[i] == 32):
				line.data[i] = 0
				fields.push(line.data + i + 1)
		int expected = 4
		if (with_cas): expected = 5
		ok = fields.length == expected
		int count = (-1)
		if (ok):
			ok = strcmp(fields[0], c"VALUE") == 0
			if (strlen(fields[1]) != key.length): ok = 0
			else:
				for i in range(key.length):
					if (fields[1][i] != key.data[i]): ok = 0
			if (cache_decimal(fields[2], strlen(fields[2]), c"4294967295") == 0): ok = 0
			count = cache_size(fields[3], strlen(fields[3]))
			if (count < 0): ok = 0
			if (with_cas && cache_decimal(fields[4], strlen(fields[4]), c"18446744073709551615") == 0): ok = 0
		if (ok == 0): cache_fail(c, cache_error_protocol)
		else if (count > c.remaining - 7): cache_fail(c, cache_error_limit)
		else:
			r.status = memcached_value
			r.flags = strclone(fields[2])
			if (with_cas): r.cas = strclone(fields[4])
			r.data = cast(char*, malloc(count + 1))
			r.length = count
			r.data[count] = 0
			ok = cache_read(c, r.data, count)
			if (ok): ok = cache_crlf(c)
			if (ok): ok = memcached_line(c, line)
			if (ok && string_equals(line, c"END") == 0): cache_fail(c, cache_error_protocol)
		list_free[char*](fields)
	string_free(line)
	if (c.error != 0 && c.error != cache_error_server):
		memcached_reply_free(r)
		return 0
	return r


memcached_reply* memcached_get(cache_connection* c, string key):
	return memcached_fetch(c, key, 0)


memcached_reply* memcached_gets(cache_connection* c, string key):
	return memcached_fetch(c, key, 1)


# verb: set/add/replace/append/prepend/cas. flags is uint32 decimal; expiry
# follows the server's seconds/Unix-time rule. cas_token is required only
# for cas. All arguments are checked before writing any bytes.
memcached_reply* memcached_store(cache_connection* c, char* verb, string key, string value, char* flags, int expiry, char* cas_token):
	if (cache_begin(c) == 0): return 0
	int valid = verb != 0 && flags != 0 && expiry >= 0 && memcached_key_valid(key)
	int is_cas = 0
	if (valid):
		is_cas = strcmp(verb, c"cas") == 0
		valid = is_cas || strcmp(verb, c"set") == 0 || strcmp(verb, c"add") == 0 || strcmp(verb, c"replace") == 0 || strcmp(verb, c"append") == 0 || strcmp(verb, c"prepend") == 0
		if (cache_decimal(flags, strlen(flags), c"4294967295") == 0): valid = 0
		if (is_cas):
			if (cas_token == 0 || cache_decimal(cas_token, strlen(cas_token), c"18446744073709551615") == 0): valid = 0
		else if (cas_token != 0): valid = 0
	if (value.length < 0 || value.length > c.max_bytes || (value.data == 0 && value.length > 0)): valid = 0
	if (valid == 0):
		cache_fail(c, cache_error_argument)
		return 0
	string_builder* line = string_from(verb)
	string_append_char(line, 32)
	string_append_string(line, key)
	string_append_char(line, 32)
	string_append(line, flags)
	string_append_char(line, 32)
	string_append_int(line, expiry)
	string_append_char(line, 32)
	string_append_int(line, value.length)
	if (is_cas):
		string_append_char(line, 32)
		string_append(line, cas_token)
	string_append(line, c"\x0d\x0a")
	int ok = cache_write(c, line.data, line.length)
	string_free(line)
	if (ok): ok = cache_write(c, value.data, value.length)
	if (ok): ok = cache_write(c, c"\x0d\x0a", 2)
	if (ok == 0): return 0
	memcached_reply* r = memcached_read_status(c)
	if (r == 0): return 0
	valid = r.status == memcached_stored || r.status == memcached_error
	if (is_cas): valid = valid || r.status == memcached_exists || r.status == memcached_not_found
	else if (strcmp(verb, c"set") != 0): valid = valid || r.status == memcached_not_stored
	if (valid == 0):
		memcached_reply_free(r)
		cache_fail(c, cache_error_protocol)
		return 0
	return r


memcached_reply* memcached_set(cache_connection* c, string key, string value, int expiry):
	return memcached_store(c, c"set", key, value, c"0", expiry, 0)


memcached_reply* memcached_cas(cache_connection* c, string key, string value, char* flags, int expiry, char* token):
	return memcached_store(c, c"cas", key, value, flags, expiry, token)


# Internal single-line key operation; callers validate the numeric suffix.
memcached_reply* memcached_key_op(cache_connection* c, char* verb, string key, char* suffix, int expected):
	if (memcached_key_valid(key) == 0):
		cache_fail(c, cache_error_argument)
		return 0
	string_builder* line = string_from(verb)
	string_append_char(line, 32)
	string_append_string(line, key)
	if (suffix != 0):
		string_append_char(line, 32)
		string_append(line, suffix)
	string_append(line, c"\x0d\x0a")
	int ok = cache_write(c, line.data, line.length)
	string_free(line)
	if (ok == 0): return 0
	memcached_reply* r = memcached_read_status(c)
	if (r != 0 && r.status != expected && r.status != memcached_not_found && r.status != memcached_error):
		memcached_reply_free(r)
		cache_fail(c, cache_error_protocol)
		return 0
	return r


memcached_reply* memcached_delete(cache_connection* c, string key):
	if (cache_begin(c) == 0): return 0
	return memcached_key_op(c, c"delete", key, 0, memcached_deleted)


memcached_reply* memcached_touch(cache_connection* c, string key, int expiry):
	if (cache_begin(c) == 0): return 0
	if (expiry < 0):
		cache_fail(c, cache_error_argument)
		return 0
	char* text = itoa(expiry)
	memcached_reply* r = memcached_key_op(c, c"touch", key, text, memcached_touched)
	free(text)
	return r


memcached_reply* memcached_counter(cache_connection* c, string key, char* delta, int decrement):
	if (cache_begin(c) == 0): return 0
	if (delta == 0 || cache_decimal(delta, strlen(delta), c"18446744073709551615") == 0):
		cache_fail(c, cache_error_argument)
		return 0
	char* verb = c"incr"
	if (decrement): verb = c"decr"
	return memcached_key_op(c, verb, key, delta, memcached_number)


memcached_reply* memcached_incr(cache_connection* c, string key, char* delta):
	return memcached_counter(c, key, delta, 0)


memcached_reply* memcached_decr(cache_connection* c, string key, char* delta):
	return memcached_counter(c, key, delta, 1)
