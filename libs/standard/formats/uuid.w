/*
libs.standard.formats.uuid: Python `uuid`-style UUIDs (RFC 9562, which
obsoletes RFC 4122).

A uuid is 16 bytes in network (big-endian) order, held by value in a
small struct, so `uuid u` works as a local, a global or a struct field
and nothing here allocates except the string formatters:

	uuid id
	if (uuid4(&id) == 0): ...                  # CSPRNG failed
	char* text = uuid_format(&id)              # malloc'd, 36 chars
	uuid back
	if (uuid_parse(text, &back) == 0): ...     # not a UUID
	free(text)

Construction (each returns 1 on success, 0 on failure; out is left
unspecified on failure):
	uuid_parse(text, out)           Python UUID(hex): see below
	uuid_parse_canonical(text, out) only the 36-char 8-4-4-4-12 form
	uuid_from_bytes(out, src)       Python UUID(bytes=), 16 bytes
	uuid_from_bytes_le(out, src)    Python UUID(bytes_le=)
	uuid4(out)                      random (CSPRNG, crypto/secrets.w)
	uuid7(out)                      Unix-ms time-ordered, monotonic
	uuid7_next(state, sec, msec, out)  v7 with an explicit clock/state
	uuid3(out, ns, name, len)       MD5 name-based (needs uuid_use_md5)
	uuid5(out, ns, name, len)       SHA-1 name-based (needs uuid_use_sha1)
	uuid_nil(out) / uuid_max(out)   Python NIL / MAX
	uuid_namespace_dns/url/oid/x500(out)   Python NAMESPACE_* constants
	uuid_set_version(u, v)          Python UUID(..., version=v)

Output: uuid_format (str), uuid_hex (32 hex), uuid_urn ("urn:uuid:..."),
all malloc'd lowercase strings owned by the caller; uuid_format_into
writes 36 chars + NUL into a caller buffer of UUID_STR_LEN + 1 bytes.
uuid_to_bytes / uuid_to_bytes_le copy 16 bytes out.

Fields (Python attribute of the same name): uuid_version (-1 for
Python's None, i.e. when the variant is not RFC 4122), uuid_variant
(UUID_RESERVED_NCS / UUID_RFC_4122 / UUID_RESERVED_MICROSOFT /
UUID_RESERVED_FUTURE), uuid_time_low, uuid_time_mid,
uuid_time_hi_version, uuid_clock_seq_hi_variant, uuid_clock_seq_low,
uuid_clock_seq, uuid_node_bytes. uuid_time_low is the 32-bit pattern, so
on 32-bit x86 it reads negative when bit 31 is set. uuid_node (48 bits)
and uuid_time (60 bits; Unix ms for v7, the RFC 9562 reordering for v6)
need a 64-bit word: on 32-bit targets they return -1.

Comparison: uuid_compare (-1/0/1, the order of Python's UUID.int, i.e.
unsigned bytewise), uuid_equal, uuid_is_nil.

Parsing follows CPython's UUID(hex) exactly for hex input: every "urn:"
and then every "uuid:" substring is deleted, '{' and '}' are stripped
from both ends, every '-' is deleted, and the remainder must be 32 hex
digits (either case). So hyphenated, {braced}, urn:uuid: prefixed and
bare 32-hex forms all parse, and so do Python's looser spellings (hyphens
anywhere, unbalanced braces). Python then hands the digits to int(x, 16),
which additionally tolerates surrounding whitespace, a '+' sign, a "0x"
prefix and '_' separators; those are rejected here. "URN:UUID:" is
rejected, as in Python (the prefix match is case-sensitive).

Name-based UUIDs and the legacy-hash quarantine. v3 hashes with MD5 and
v5 with SHA-1, both of which live in libs/x/unsafe, which nothing under
libs/standard may import (unsafe_import_test). As in
libs/standard/web/websocket.w, the digests are reached through the whash
registry of libs/standard/crypto/sha2.w, and the APPLICATION (a leaf
program, never a libs/standard module) imports libs/x/unsafe/md5.w and
libs/x/unsafe/sha1.w and opts in once with

	uuid_use_md5(WHASH_MD5())
	uuid_use_sha1(WHASH_SHA1())

Each opt-in refuses anything that is not a registered whash extension of
the right digest size reproducing Python's uuid3/uuid5(NAMESPACE_DNS,
"python.org") answer; until it succeeds uuid3/uuid5 fail closed
(return 0). A UUID is an identifier, not a security token: the broken
collision resistance of MD5/SHA-1 is RFC 9562's own choice for v3/v5,
and new designs should prefer v5 (or v8 with a modern hash) over v3.
libs/x/unsafe/uuid_names_test.w is the worked example.

v4: 122 bits from libs/standard/crypto/secrets.w (getrandom/urandom).
v7 (RFC 9562 section 5.7, method 1 of 6.2, like CPython 3.14's uuid7):
48-bit Unix milliseconds, then a 42-bit counter (12 bits in rand_a, 30
in the top of rand_b) seeded randomly with its top bit clear, then 32
random bits. Within one millisecond, or when the clock steps backwards,
the previous timestamp is kept and the counter incremented, so values
from one state are strictly increasing; when the counter overflows the
timestamp is advanced by 1 ms and the counter reseeded. (CPython instead
moves a backwards clock to last + 1 ms; both are monotonic.) uuid7 uses
one process-global state read from CLOCK_REALTIME and is not
thread-safe; give each thread its own uuid7_state and call uuid7_next.
On 32-bit x86 the wall clock's seconds overflow in 2038 (lib/time.w).
v1 (MAC + Gregorian 100 ns time) is not provided.
*/
import lib.lib
import lib.time
import lib.hex
import libs.standard.crypto.secrets
import libs.standard.crypto.sha2


struct uuid:
	uint8[16] b     # big-endian (network order), as Python's UUID.bytes


# Length of the canonical 8-4-4-4-12 text, without the NUL.
const int UUID_STR_LEN = 36

# Python's variant strings, as ints.
const int UUID_RESERVED_NCS = 0
const int UUID_RFC_4122 = 1
const int UUID_RESERVED_MICROSOFT = 2
const int UUID_RESERVED_FUTURE = 3


# Monotonic v7 generator state. Zero it (or uuid7_state_init) before
# first use; one state yields strictly increasing UUIDs.
struct uuid7_state:
	uint8[6] last_ms    # big-endian 48-bit Unix ms of the last UUID
	int counter_hi      # 12 bits, stored in rand_a
	int counter_lo      # 30 bits, stored in the top of rand_b
	int started


uuid7_state uuid7_default_state

# whash algorithm ids opted in for v3 / v5 (0 = not available).
int uuid_md5_alg
int uuid_sha1_alg


void uuid_copy(uuid* dst, uuid* src):
	for i in range(16): dst.b[i] = src.b[i]


# Python UUID(bytes=src): src[0..16) in network order.
void uuid_from_bytes(uuid* out, char* src):
	for i in range(16): out.b[i] = src[i] & 255


# Python UUID.bytes: the 16 bytes in network order into dst.
void uuid_to_bytes(uuid* u, char* dst):
	for i in range(16): dst[i] = u.b[i]


# Index of byte i of the bytes_le layout in network order: time_low,
# time_mid and time_hi_version are little-endian, the rest unchanged.
int uuid_le_index(int i):
	if (i < 4): return 3 - i
	if (i < 6): return 9 - i
	if (i < 8): return 13 - i
	return i


# Python UUID(bytes_le=src).
void uuid_from_bytes_le(uuid* out, char* src):
	for i in range(16): out.b[uuid_le_index(i)] = src[i] & 255


# Python UUID.bytes_le into dst (16 bytes).
void uuid_to_bytes_le(uuid* u, char* dst):
	for i in range(16): dst[i] = u.b[uuid_le_index(i)]


# Python NIL: all 128 bits zero.
void uuid_nil(uuid* out):
	for i in range(16): out.b[i] = 0


# Python MAX (RFC 9562 section 5.10): all 128 bits one.
void uuid_max(uuid* out):
	for i in range(16): out.b[i] = 255


int uuid_is_nil(uuid* u):
	for i in range(16):
		if (u.b[i] != 0): return 0
	return 1


# -1, 0 or 1 as a orders before, equal to, or after b (Python's UUID
# ordering: by the 128-bit unsigned value).
int uuid_compare(uuid* a, uuid* b):
	for i in range(16):
		if (a.b[i] < b.b[i]): return -1
		if (a.b[i] > b.b[i]): return 1
	return 0


int uuid_equal(uuid* a, uuid* b):
	return uuid_compare(a, b) == 0


# Python UUID(..., version=v): sets the RFC 4122 variant (10xx) and the
# 4-bit version. v must be 0..15.
void uuid_set_version(uuid* u, int v):
	u.b[6] = (u.b[6] & 15) | ((v & 15) << 4)
	u.b[8] = (u.b[8] & 63) | 128


# Writes the canonical lowercase 8-4-4-4-12 text and a NUL into out,
# which must hold UUID_STR_LEN + 1 bytes.
void uuid_format_into(uuid* u, char* out):
	int at = 0
	for i in range(16):
		if ((i == 4) || (i == 6) || (i == 8) || (i == 10)):
			out[at] = '-'
			at = at + 1
		hex_put_byte(&out[at], u.b[i])
		at = at + 2
	out[at] = 0


# Python str(u): malloc'd "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
char* uuid_format(uuid* u):
	char* out = cast(char*, malloc(UUID_STR_LEN + 1))
	uuid_format_into(u, out)
	return out


# Python u.hex: malloc'd 32 lowercase hex digits.
char* uuid_hex(uuid* u):
	char* out = cast(char*, malloc(33))
	for i in range(16): hex_put_byte(&out[i * 2], u.b[i])
	out[32] = 0
	return out


# Python u.urn: malloc'd "urn:uuid:" + str(u).
char* uuid_urn(uuid* u):
	char* out = cast(char*, malloc(9 + UUID_STR_LEN + 1))
	char* prefix = c"urn:uuid:"
	for i in range(9): out[i] = prefix[i]
	uuid_format_into(u, &out[9])
	return out


# Deletes every non-overlapping occurrence of pat from s in place,
# scanning left to right like Python's str.replace(pat, '').
void uuid_remove_all(char* s, char* pat):
	int plen = strlen(pat)
	int r = 0
	int w = 0
	while (s[r] != 0):
		int k = 0
		while ((k < plen) && (s[r + k] == pat[k])): k = k + 1
		if (k == plen):
			r = r + plen
		else:
			s[w] = s[r]
			w = w + 1
			r = r + 1
	s[w] = 0


# Decodes exactly 32 hex digits at s[0..32) into out.
int uuid_decode_hex32(char* s, uuid* out):
	for i in range(16):
		int hi = hex_decode_char(s[i * 2])
		int lo = hex_decode_char(s[i * 2 + 1])
		if ((hi < 0) || (lo < 0)): return 0
		out.b[i] = (hi << 4) | lo
	return 1


# Python UUID(text) (the hex= argument); see the header for the accepted
# spellings. Returns 1 and fills out, or 0 when text is not a UUID.
int uuid_parse(char* text, uuid* out):
	if (text == 0): return 0
	int n = strlen(text)
	char* s = cast(char*, malloc(n + 1))
	for i in range(n + 1): s[i] = text[i]
	uuid_remove_all(s, c"urn:")
	uuid_remove_all(s, c"uuid:")
	n = strlen(s)
	int start = 0
	while ((start < n) && ((s[start] == '{') || (s[start] == '}'))): start = start + 1
	while ((n > start) && ((s[n - 1] == '{') || (s[n - 1] == '}'))): n = n - 1
	s[n] = 0
	uuid_remove_all(&s[start], c"-")
	int ok = 0
	if (strlen(&s[start]) == 32): ok = uuid_decode_hex32(&s[start], out)
	free(s)
	return ok


# Strict parse of only the canonical 36-character 8-4-4-4-12 form (hex
# digits in either case, hyphens exactly at 8, 13, 18 and 23), for
# validating identifiers in protocols that mandate it. 1 or 0.
int uuid_parse_canonical(char* text, uuid* out):
	if (text == 0): return 0
	char[33] digits
	int d = 0
	for i in range(UUID_STR_LEN):
		int ch = text[i]
		if (ch == 0): return 0
		if ((i == 8) || (i == 13) || (i == 18) || (i == 23)):
			if (ch != '-'): return 0
		else:
			digits[d] = ch
			d = d + 1
	if (text[UUID_STR_LEN] != 0): return 0
	digits[32] = 0
	return uuid_decode_hex32(&digits[0], out)


# Python u.variant, as one of the UUID_RESERVED_* / UUID_RFC_4122 ints.
int uuid_variant(uuid* u):
	int v = u.b[8]
	if ((v & 128) == 0): return UUID_RESERVED_NCS
	if ((v & 64) == 0): return UUID_RFC_4122
	if ((v & 32) == 0): return UUID_RESERVED_MICROSOFT
	return UUID_RESERVED_FUTURE


# Python u.version: 0..15 for the RFC 4122 variant, else -1 (None).
int uuid_version(uuid* u):
	if (uuid_variant(u) != UUID_RFC_4122): return -1
	return u.b[6] >> 4


# The 32-bit time_low field (bytes 0..3). Negative on 32-bit x86 when
# its bit 31 is set; mask with a runtime-built 32-bit mask if needed.
int uuid_time_low(uuid* u):
	return (u.b[0] << 24) | (u.b[1] << 16) | (u.b[2] << 8) | u.b[3]


int uuid_time_mid(uuid* u):
	return (u.b[4] << 8) | u.b[5]


int uuid_time_hi_version(uuid* u):
	return (u.b[6] << 8) | u.b[7]


int uuid_clock_seq_hi_variant(uuid* u):
	return u.b[8]


int uuid_clock_seq_low(uuid* u):
	return u.b[9]


# Python u.clock_seq: the 14-bit clock sequence.
int uuid_clock_seq(uuid* u):
	return ((u.b[8] & 63) << 8) | u.b[9]


# The 6 node bytes (Python u.node, big-endian) into dst.
void uuid_node_bytes(uuid* u, char* dst):
	for i in range(6): dst[i] = u.b[10 + i]


# Big-endian value of u.b[first .. first + count) in one word; only
# meaningful when it fits (count <= 7 on a 64-bit word).
int uuid_be_value(uuid* u, int first, int count):
	int v = 0
	for i in range(count): v = (v << 8) | u.b[first + i]
	return v


# Python u.node (48 bits). -1 on 32-bit targets, where it cannot fit.
int uuid_node(uuid* u):
	if (__word_size__ < 8): return -1
	return uuid_be_value(u, 10, 6)


# Python u.time: the 60-bit Gregorian timestamp of v1 (and of any
# version other than 6 and 7, as Python does), the RFC 9562 reordered
# one of v6, or the 48-bit Unix milliseconds of v7. -1 on 32-bit targets.
int uuid_time(uuid* u):
	if (__word_size__ < 8): return -1
	int v = uuid_version(u)
	if (v == 7): return uuid_be_value(u, 0, 6)
	int mid = uuid_time_mid(u)
	int thv = uuid_time_hi_version(u) & 4095
	if (v == 6):
		int hi = uuid_be_value(u, 0, 4)
		return (hi << 28) | (mid << 12) | thv
	int lo = uuid_be_value(u, 0, 4)
	return (thv << 48) | (mid << 32) | lo


# Python NAMESPACE_DNS, NAMESPACE_URL, NAMESPACE_OID, NAMESPACE_X500.
void uuid_namespace_dns(uuid* out):
	uuid_parse(c"6ba7b810-9dad-11d1-80b4-00c04fd430c8", out)


void uuid_namespace_url(uuid* out):
	uuid_parse(c"6ba7b811-9dad-11d1-80b4-00c04fd430c8", out)


void uuid_namespace_oid(uuid* out):
	uuid_parse(c"6ba7b812-9dad-11d1-80b4-00c04fd430c8", out)


void uuid_namespace_x500(uuid* out):
	uuid_parse(c"6ba7b814-9dad-11d1-80b4-00c04fd430c8", out)


# --- v4 -------------------------------------------------------------------

# Python uuid4(): 122 CSPRNG bits. 1, or 0 when the CSPRNG fails (out is
# then zeroed, never a predictable value).
int uuid4(uuid* out):
	char[16] raw
	if (secrets_token_bytes(&raw[0], 16) == 0):
		uuid_nil(out)
		return 0
	uuid_from_bytes(out, &raw[0])
	secrets_wipe(&raw[0], 16)
	uuid_set_version(out, 4)
	return 1


# --- v3 / v5 --------------------------------------------------------------

# hash(ns.bytes + name) with whash alg, truncated to 16 bytes, stamped
# with version.
void uuid_name_hash(int alg, int version, uuid* out, uuid* ns, char* name, int len):
	char[20] digest
	char[16] nsb
	uuid_to_bytes(ns, &nsb[0])
	whash* h = whash_new(alg)
	whash_update(h, &nsb[0], 16)
	whash_update(h, name, len)
	whash_final(h, &digest[0])
	whash_free(h)
	uuid_from_bytes(out, &digest[0])
	uuid_set_version(out, version)


# 1 when alg is a registered whash extension with the given digest size
# whose version-`version` UUID of (NAMESPACE_DNS, "python.org") is the
# known answer.
int uuid_probe_alg(int alg, int digest_size, int version, char* want):
	if (alg < 100): return 0
	if (whash_ext_find(alg) == 0): return 0
	if (whash_digest_size(alg) != digest_size): return 0
	uuid ns
	uuid got
	uuid expect
	uuid_namespace_dns(&ns)
	uuid_name_hash(alg, version, &got, &ns, c"python.org", 10)
	uuid_parse(want, &expect)
	return uuid_equal(&got, &expect)


# Opts in to v3 with an application-supplied MD5 (WHASH_MD5() from
# libs/x/unsafe/md5.w). 1 when accepted; 0 keeps the previous setting.
int uuid_use_md5(int alg):
	if (uuid_probe_alg(alg, 16, 3, c"6fa459ea-ee8a-3ca4-894e-db77e160355e") == 0): return 0
	uuid_md5_alg = alg
	return 1


# Opts in to v5 with an application-supplied SHA-1 (WHASH_SHA1() from
# libs/x/unsafe/sha1.w). 1 when accepted; 0 keeps the previous setting.
int uuid_use_sha1(int alg):
	if (uuid_probe_alg(alg, 20, 5, c"886313e1-3b8a-5372-9b90-0c9aee199e5d") == 0): return 0
	uuid_sha1_alg = alg
	return 1


# Python uuid3(namespace, name) with name as len bytes (UTF-8 for text).
# 0 when uuid_use_md5 was never accepted or len < 0.
int uuid3(uuid* out, uuid* ns, char* name, int len):
	if ((uuid_md5_alg == 0) || (len < 0)): return 0
	uuid_name_hash(uuid_md5_alg, 3, out, ns, name, len)
	return 1


# Python uuid5(namespace, name); 0 when uuid_use_sha1 was never accepted
# or len < 0.
int uuid5(uuid* out, uuid* ns, char* name, int len):
	if ((uuid_sha1_alg == 0) || (len < 0)): return 0
	uuid_name_hash(uuid_sha1_alg, 5, out, ns, name, len)
	return 1


# --- v7 -------------------------------------------------------------------

void uuid7_state_init(uuid7_state* st):
	for i in range(6): st.last_ms[i] = 0
	st.counter_hi = 0
	st.counter_lo = 0
	st.started = 0


# Draws a fresh 42-bit counter (top bit clear) into st and 4 tail bytes.
int uuid7_reseed(uuid7_state* st, char* tail):
	char[10] raw
	if (secrets_token_bytes(&raw[0], 10) == 0): return 0
	st.counter_hi = ((raw[0] & 7) << 8) | (raw[1] & 255)
	st.counter_lo = ((raw[2] & 63) << 24) | ((raw[3] & 255) << 16) | ((raw[4] & 255) << 8) | (raw[5] & 255)
	for i in range(4): tail[i] = raw[6 + i]
	secrets_wipe(&raw[0], 10)
	return 1


# ts (6 bytes, big-endian) += 1, wrapping at 48 bits.
void uuid7_ts_increment(char* ts):
	int i = 5
	while (i >= 0):
		int v = (ts[i] & 255) + 1
		ts[i] = v & 255
		if (v < 256): return
		i = i - 1


# Next v7 UUID for Unix time unix_sec + msec/1000 (0 <= msec <= 999)
# from state st (see the header for the monotonic rules). 1, or 0 when
# the arguments are out of range or the CSPRNG fails (st unchanged).
int uuid7_next(uuid7_state* st, int unix_sec, int msec, uuid* out):
	if ((unix_sec < 0) || (msec < 0) || (msec > 999)): return 0
	char[6] ts
	int s = unix_sec
	int i = 5
	while (i >= 0):
		ts[i] = s & 255
		s = s >> 8
		i = i - 1
	int carry = msec
	i = 5
	while (i >= 0):
		int v = (ts[i] & 255) * 1000 + carry
		ts[i] = v & 255
		carry = v >> 8
		i = i - 1
	int newer = 1
	if (st.started):
		newer = 0
		i = 0
		while (i < 6):
			int a = ts[i] & 255
			if (a > st.last_ms[i]):
				newer = 1
				i = 6
			else if (a < st.last_ms[i]):
				i = 6
			else:
				i = i + 1
	char[4] tail
	int hi = st.counter_hi
	int lo = st.counter_lo
	uuid7_state next
	if (newer):
		if (uuid7_reseed(&next, &tail[0]) == 0): return 0
		hi = next.counter_hi
		lo = next.counter_lo
	else:
		for k in range(6): ts[k] = st.last_ms[k]
		lo = lo + 1
		if (lo == (1 << 30)):
			lo = 0
			hi = hi + 1
		if (hi == 4096):
			uuid7_ts_increment(&ts[0])
			if (uuid7_reseed(&next, &tail[0]) == 0): return 0
			hi = next.counter_hi
			lo = next.counter_lo
		else if (secrets_token_bytes(&tail[0], 4) == 0):
			return 0
	for k in range(6):
		st.last_ms[k] = ts[k]
		out.b[k] = ts[k]
	st.counter_hi = hi
	st.counter_lo = lo
	st.started = 1
	out.b[6] = 112 | (hi >> 8)
	out.b[7] = hi & 255
	out.b[8] = 128 | ((lo >> 24) & 63)
	out.b[9] = (lo >> 16) & 255
	out.b[10] = (lo >> 8) & 255
	out.b[11] = lo & 255
	for k in range(4): out.b[12 + k] = tail[k]
	return 1


# Python 3.14 uuid7(): time-ordered from CLOCK_REALTIME with the
# process-global state (not thread-safe). 1, or 0 when the clock or the
# CSPRNG fails.
int uuid7(uuid* out):
	timespec now
	if (sys_clock_gettime(0, cast(int, &now)) < 0): return 0
	return uuid7_next(&uuid7_default_state, now.seconds, now.nanoseconds / 1000000, out)
