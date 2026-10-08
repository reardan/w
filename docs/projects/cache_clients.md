# Redis and Memcached connections

Issue [#496](https://github.com/reardan/w/issues/496) is implemented as optional
pure-W modules: `libs.extras.cache.redis` and `libs.extras.cache.memcached`.
They share `libs.extras.cache.connection`, use the existing DNS/TCP/buffered
connection stack, and require no C client library. Importing the compiler or
core library does not pull them in.

## Connecting and ownership

`redis_connect(host, port, timeout_ms)` and
`memcached_connect(host, port, timeout_ms)` return a `cache_connection*` even
when connection fails. Check `c.error`, and always release it with
`cache_close(c)`. Use port 6379 for Redis or 11211 for Memcached explicitly.
Hostnames resolve through the existing IPv4 DNS resolver. `cache_attach(fd,
timeout_ms)` takes ownership of an already connected socket, including on
failure, and switches it to nonblocking mode.

Commands run synchronously on a persistent connection. Use one connection
per concurrent caller; calls on the same connection must not overlap. Timeout
values <= 0 select 5000 ms. Connect and each stalled read/write have a timeout;
this is not an overall command deadline. DNS uses the resolver's own timeout.
No command is retried automatically, because a lost reply may follow a
successful mutation.

Request strings and argument lists are borrowed for the duration of a call.
Returned replies own all their data and remain valid after the connection
closes. Release them with `redis_reply_free` or `memcached_reply_free` (both
accept null). Redis arrays recursively own their elements. All returned byte
buffers have an extra NUL terminator; use `length` for binary values.

The client's `error` describes the last operation:

| Error | Meaning / connection state |
| --- | --- |
| `0` | Success, including a cache miss or failed CAS comparison |
| `cache_error_argument` | Rejected before sending; connection remains usable |
| `cache_error_server` | Complete error reply, text in the returned reply; connection remains usable |
| `cache_error_resolve`, `cache_error_connect` | Connection could not be established |
| `cache_error_io`, `cache_error_timeout` | Connection closed; reply/effect may be incomplete |
| `cache_error_protocol`, `cache_error_limit` | Invalid/oversized reply; connection closed |

`cache_error_string(c.error)` describes the error. Fatal failures return a
null reply, discard partial reply allocations and close immediately. Later
calls on that object fail without writing; explicitly create a new connection.

Replies are bounded to 16 MiB of total wire bytes by default. Set `c.max_bytes`
before an operation to change this (1..64 MiB); it also caps outgoing value
bytes / Redis's total argument bytes. Each header line is limited to 8192
bytes. Redis additionally limits the complete reply tree to 65,536 nodes and
64 levels. The byte budget covers nested arrays cumulatively. Header lengths
are validated before allocating body buffers, and CRLF is checked strictly.

## Redis (RESP2)

```w
import libs.extras.cache.redis

int main():
	cache_connection* c = redis_connect(c"127.0.0.1", 6379, 3000)
	redis_reply* r = redis_set(c, "greeting", "hello\x00world")
	if (r == 0 || c.error != 0):
		println2(cache_error_string(c.error))
		redis_reply_free(r)
		cache_close(c)
		return 1
	redis_reply_free(r)
	r = redis_get(c, "greeting")
	if (r != 0 && r.kind == redis_bulk): write(1, r.data, r.length)
	redis_reply_free(r)
	cache_close(c)
	return 0
```

Convenience operations: `redis_ping(c)`, `redis_get(c, key)`,
`redis_set(c, key, value)`, and `redis_del(c, key)`. Keys and values are W
`string` descriptors, so embedded NUL/CR/LF bytes are supported.

`redis_command(c, list[string] args)` sends a binary-safe RESP array of bulk
strings. Use it for AUTH (password or username/password), SELECT, EXPIRE,
INCR, MGET, hashes, lists, transactions and other ordinary request/reply
commands. For example, SET with a TTL:

```w
list[string] args = new list[string]
args.push("SET")
args.push("key")
args.push("value")
args.push("EX")
args.push("60")
redis_reply* r = redis_command(c, args)
list_free[string](args)
# Inspect r and c.error, then redis_reply_free(r).
```

Replies expose `kind`, `data`, `length` and `elements`:

| Kind | Contents |
| --- | --- |
| `redis_simple`, `redis_error`, `redis_bulk` | Bytes in `data[0..length)` |
| `redis_integer` | Validated signed 64-bit decimal text in `data` |
| `redis_array` | Owned `list[redis_reply*] elements` |
| `redis_nil` | RESP2 null bulk string or null array |

Integers deliberately retain decimal text, including -9223372036854775808
and 9223372036854775807, on both 32- and 64-bit W. This avoids implicit
word-size truncation. Empty strings/arrays are distinct from null. An error
inside an array remains an error element; only a top-level error sets
`c.error = cache_error_server`.

This version uses RESP2 without HELLO negotiation. RESP3, Pub/Sub, MONITOR,
unsolicited pushes, pipelining, connection pools, Cluster routing, Sentinel,
TLS and automatic reconnect are outside this initial API. Do not issue
commands that switch the connection into those protocol modes. AUTH sends
credentials over the same plaintext connection; no TLS upgrade is implied.

## Memcached (basic text protocol)

```w
import libs.extras.cache.memcached

int main():
	cache_connection* c = memcached_connect(c"127.0.0.1", 11211, 3000)
	memcached_reply* r = memcached_set(c, "greeting", "hello", 60)
	if (r == 0 || r.status != memcached_stored):
		println2(cache_error_string(c.error))
		memcached_reply_free(r)
		cache_close(c)
		return 1
	memcached_reply_free(r)
	r = memcached_get(c, "greeting")
	if (r != 0 && r.status == memcached_value): write(1, r.data, r.length)
	memcached_reply_free(r)
	cache_close(c)
	return 0
```

| Operation | API |
| --- | --- |
| Fetch | `memcached_get(c, key)`, `memcached_gets(c, key)` |
| Store, flags=0 | `memcached_set(c, key, value, expiry)` |
| Storage variants | `memcached_store(c, verb, key, value, flags, expiry, cas_token)` |
| Compare-and-swap | `memcached_cas(c, key, value, flags, expiry, token)` |
| Delete / touch | `memcached_delete(c, key)`, `memcached_touch(c, key, expiry)` |
| Counters | `memcached_incr(c, key, delta)`, `memcached_decr(c, key, delta)` |

Keys and values are `string`; other textual arguments are `char*`. Storage
verbs are `set`, `add`, `replace`, `append`, `prepend` and `cas`. Pass a null
CAS token except for `cas`. `flags` is decimal uint32 text, and CAS tokens
and counter deltas/results are decimal uint64 text, preserving their complete
ranges on x86. Use canonical decimal spelling (no plus sign or leading zeros,
except `0` itself). `expiry` is a nonnegative W int: 0 means no expiration, up to
30 days means a relative duration, and larger values mean Unix timestamps,
as defined by the server. Append/prepend follow server semantics for flags
and expiration. No serializer or deserializer interprets the flag bits.

`memcached_reply` contains `status`, `data`, `length`, `flags`, and `cas`.
GET/GETS return `memcached_value` (even for an empty value) or
`memcached_not_found`. GETS supplies an owned CAS token. Other statuses are
`memcached_stored`, `memcached_not_stored`, `memcached_exists`,
`memcached_deleted`, `memcached_touched`, `memcached_number` and
`memcached_error`. Number/error replies contain their text in `data`.

Keys must be 1..250 bytes, without whitespace, NUL, other ASCII controls or
DEL. Values are binary-safe. The client checks arguments before sending and
consumes the entire VALUE/body/END response before reuse. Every mutation
requests a reply. Multi-get, noreply, stats/admin commands, UDP, binary/SASL,
meta protocol, TLS and client-side sharding are not implemented. The basic
text protocol remains useful for interoperability with the Python and C
clients below; Memcached recommends its newer meta protocol for new clients,
which can be added separately without changing this API's wire contract.

## Validation and references

`./wbuild cache_clients_test cache_clients_64_test` runs offline loopback
fixtures on ephemeral ports. These assert exact request bytes, split replies,
binary values, null/empty distinctions, nested replies, 64-bit boundaries,
CAS outcomes, connection reuse, injection rejection, framing/length errors,
EOF and timeout behavior. They are included in `./wbuild tests`.

`bin/wv2 libs/extras/cache/live_smoke.w -o bin/cache_live_smoke` builds an
optional interoperability executable.
Run `bin/cache_live_smoke <redis-port> <memcached-port>` against disposable
local plaintext servers. It writes/deletes `w-cache-smoke`, expects
`w-cache-smoke-absent` to be absent, and tests binary storage, MGET, full-width
flags, CAS success/conflict, counters, touch and deletion. It is not part of
the offline suite. Prepend `x64` to the compiler invocation to build the same
source for x64. Development smoke runs used Redis 7.0.15 and Memcached 1.6.24.

The implementation was written independently with these primary references:

- [Redis RESP specification](https://redis.io/docs/latest/develop/reference/protocol-spec/)
  and [Redis C server framing](https://github.com/redis/redis/blob/unstable/src/networking.c):
  command argument lengths and RESP2 reply types.
- [hiredis C reader](https://github.com/redis/hiredis/blob/master/read.c):
  strict framing, numeric validation and partial-reply cleanup.
- [redis-py RESP2 parser](https://github.com/redis/redis-py/blob/master/redis/_parsers/resp2.py):
  null versus empty replies and nested server errors.
- [Memcached protocol](https://github.com/memcached/memcached/blob/master/doc/protocol.txt)
  and [Memcached C text server](https://github.com/memcached/memcached/blob/master/proto_text.c):
  VALUE/END framing, storage outcomes, CAS, counters and expiration rules.
- [pymemcache Python client](https://github.com/pinterest/pymemcache/blob/master/pymemcache/client/base.py):
  key checks, explicit mutation replies and byte-counted values.
- [libmemcached C/C++ client](https://github.com/awesomized/libmemcached/blob/v1.x/src/libmemcached/response.cc):
  flags/CAS/value-length handling and reply statuses.
- [Memcached protocol guidance](https://docs.memcached.org/protocols/):
  basic/meta compatibility and the deprecated binary protocol.
