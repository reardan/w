/*
BLAKE2b and BLAKE2s (RFC 7693), with the parameter surface of Python's
hashlib.blake2b / hashlib.blake2s: variable digest size, key (keyed MAC
mode), salt and personalization. Tree-hashing parameters (fanout, depth,
leaf_size, node_offset, node_depth, inner_size, last_node) are fixed at
their sequential-mode defaults.

	blake2* h = blake2b_new(64)                 # or blake2s_new(32)
	blake2_update(h, data, len)                 # any number of times
	char* digest = blake2_digest(h)             # digest_size bytes, malloc'd
	char* hex = blake2_hexdigest(h)             # 2*digest_size hex chars
	blake2_free(h)

	char* d = blake2b(data, len, 32)            # one-shot helpers
	char* x = blake2s_hex(data, len, 32)
	char* mac = blake2b_keyed(key, key_len, data, len, 32)

Like hashlib, digest/hexdigest are non-destructive: finalisation runs on
a copy of the chaining state, so the stream can keep absorbing afterwards
and blake2_copy forks an independent stream.

Invalid parameters (digest size outside 1..max, a key longer than the
maximum, a salt or personalization longer than its field) make the
constructors return 0, where Python raises ValueError. Shorter salt and
personalization strings are zero-padded, as in hashlib.

32-bit portability: BLAKE2b's 64-bit words are hi/lo pairs of 32-bit ints
(hi at index 2j, lo at 2j+1). Every 32-bit word is observed only through
its low 32 bits (& blake2_mask32(), built at runtime), right shifts go
through blake2_shr so a 32-bit target's arithmetic shift cannot smear sign
bits into the result, and no integer literal with bit 31 set appears in
the source: the IVs are hex text parsed per context. 64-bit additions
split the low words into 16-bit halves so the carry out of the low half
is exact on every target (the libs/standard/crypto/sha2.w scheme).
*/
import lib.memory
import lib.hex
import lib.bytes
import lib.mem


const int BLAKE2B_MAX_DIGEST_SIZE = 64
const int BLAKE2B_MAX_KEY_SIZE = 64
const int BLAKE2B_SALT_SIZE = 16
const int BLAKE2B_PERSON_SIZE = 16
const int BLAKE2B_BLOCK_SIZE = 128

const int BLAKE2S_MAX_DIGEST_SIZE = 32
const int BLAKE2S_MAX_KEY_SIZE = 32
const int BLAKE2S_SALT_SIZE = 8
const int BLAKE2S_PERSON_SIZE = 8
const int BLAKE2S_BLOCK_SIZE = 64


struct blake2:
	int wide          # 1 = BLAKE2b (64-bit words), 0 = BLAKE2s
	int digest_size
	int block_size
	int words         # ints per 8-word state: 16 (hi/lo pairs) or 8
	int* h            # chaining state
	int* iv           # the algorithm's IV, same layout as h
	int* v            # 16-word working vector (scratch)
	int* m            # 16 message words (scratch)
	char* buf         # pending input: up to one full block
	int buffered
	int t_hi          # bytes compressed so far, as a hi/lo pair
	int t_lo


/* 32-bit word helpers */


# 0xffffffff built at runtime: -1 on a 32-bit target, 4294967295 on a
# 64-bit one; the same low 32 bits.
int blake2_mask32():
	int h = 1 << 16
	return h * h - 1


# Logical right shift of a 32-bit word (n in 1..31).
int blake2_shr(int x, int n):
	return (x >> n) & ((1 << (32 - n)) - 1)


# 32-bit rotate right (n in 1..31).
int blake2_rotr32(int x, int n):
	return (blake2_shr(x, n) | (x << (32 - n))) & blake2_mask32()


# Parse 8 lowercase hex chars into one masked 32-bit word.
int blake2_hex32(char* s):
	int v = 0
	for i in range(8): v = (v << 4) | hex_decode_char(s[i] & 255)
	return v & blake2_mask32()


# Message word index for round r (0..9), position i (0..15): RFC 7693
# section 2.7's SIGMA table, one hex digit per entry.
int blake2_sigma(int r, int i):
	char* t = c"0123456789abcdefea489fd61c02b753b8c052fdae3671947931dcbe265a40f8905724afe1bc683d2c6a0b834d75fe19c51fed4a0763928bdb7ec13950f4862a6fe9b308c2d714a5a2847615fb9e3cd0"
	return hex_decode_char(t[r * 16 + i] & 255)


/* BLAKE2b: 64-bit words as hi/lo pairs */


# v[i..i+1] += (hi, lo), word i given as its int index (2 * word).
void blake2b_add(int* v, int i, int hi, int lo):
	int mask = blake2_mask32()
	int a = v[i + 1]
	int lo0 = (a & 0xffff) + (lo & 0xffff)
	int lo1 = blake2_shr(a, 16) + blake2_shr(lo, 16) + (lo0 >> 16)
	v[i + 1] = ((lo1 << 16) | (lo0 & 0xffff)) & mask
	v[i] = (v[i] + hi + (lo1 >> 16)) & mask


# v[d] = (v[d] ^ v[s]) >>> n for word indices d, s and n in 1..63.
void blake2b_xor_rotr(int* v, int d, int s, int n):
	int mask = blake2_mask32()
	int hi = (v[2 * d] ^ v[2 * s]) & mask
	int lo = (v[2 * d + 1] ^ v[2 * s + 1]) & mask
	if (n == 32):
		v[2 * d] = lo
		v[2 * d + 1] = hi
		return
	if (n < 32):
		v[2 * d] = (blake2_shr(hi, n) | (lo << (32 - n))) & mask
		v[2 * d + 1] = (blake2_shr(lo, n) | (hi << (32 - n))) & mask
		return
	int k = n - 32
	v[2 * d] = (blake2_shr(lo, k) | (hi << (32 - k))) & mask
	v[2 * d + 1] = (blake2_shr(hi, k) | (lo << (32 - k))) & mask


# The mixing function G (RFC 7693 section 3.1) on words a, b, c, d with
# message words x, y.
void blake2b_g(int* v, int* m, int a, int b, int c, int d, int x, int y):
	blake2b_add(v, 2 * a, v[2 * b], v[2 * b + 1])
	blake2b_add(v, 2 * a, m[2 * x], m[2 * x + 1])
	blake2b_xor_rotr(v, d, a, 32)
	blake2b_add(v, 2 * c, v[2 * d], v[2 * d + 1])
	blake2b_xor_rotr(v, b, c, 24)
	blake2b_add(v, 2 * a, v[2 * b], v[2 * b + 1])
	blake2b_add(v, 2 * a, m[2 * y], m[2 * y + 1])
	blake2b_xor_rotr(v, d, a, 16)
	blake2b_add(v, 2 * c, v[2 * d], v[2 * d + 1])
	blake2b_xor_rotr(v, b, c, 63)


/* BLAKE2s: plain 32-bit words */


void blake2s_g(int* v, int* m, int a, int b, int c, int d, int x, int y):
	int mask = blake2_mask32()
	v[a] = (v[a] + v[b] + m[x]) & mask
	v[d] = blake2_rotr32(v[d] ^ v[a], 16)
	v[c] = (v[c] + v[d]) & mask
	v[b] = blake2_rotr32(v[b] ^ v[c], 12)
	v[a] = (v[a] + v[b] + m[y]) & mask
	v[d] = blake2_rotr32(v[d] ^ v[a], 8)
	v[c] = (v[c] + v[d]) & mask
	v[b] = blake2_rotr32(v[b] ^ v[c], 7)


/* Compression (RFC 7693 section 3.2) */


# Compress one block into state h (s.h or a finalisation copy), using the
# current byte counter; last != 0 sets the final-block flag.
void blake2_compress(blake2* s, int* h, char* block, int last):
	int mask = blake2_mask32()
	int* v = s.v
	int* m = s.m
	int w = s.words
	mem_copy(v, h, w)
	mem_copy[int](&v[w], s.iv, w)
	if (s.wide):
		for i in range(16):
			m[2 * i + 1] = load_le32(&block[8 * i]) & mask
			m[2 * i] = load_le32(&block[8 * i + 4]) & mask
		# v12 ^= t (low 64 bits of the counter); v13 ^= 0.
		v[24] = (v[24] ^ s.t_hi) & mask
		v[25] = (v[25] ^ s.t_lo) & mask
		if (last):
			v[28] = (v[28] ^ mask) & mask
			v[29] = (v[29] ^ mask) & mask
		for r in range(12):
			int row = r % 10
			blake2b_g(v, m, 0, 4, 8, 12, blake2_sigma(row, 0), blake2_sigma(row, 1))
			blake2b_g(v, m, 1, 5, 9, 13, blake2_sigma(row, 2), blake2_sigma(row, 3))
			blake2b_g(v, m, 2, 6, 10, 14, blake2_sigma(row, 4), blake2_sigma(row, 5))
			blake2b_g(v, m, 3, 7, 11, 15, blake2_sigma(row, 6), blake2_sigma(row, 7))
			blake2b_g(v, m, 0, 5, 10, 15, blake2_sigma(row, 8), blake2_sigma(row, 9))
			blake2b_g(v, m, 1, 6, 11, 12, blake2_sigma(row, 10), blake2_sigma(row, 11))
			blake2b_g(v, m, 2, 7, 8, 13, blake2_sigma(row, 12), blake2_sigma(row, 13))
			blake2b_g(v, m, 3, 4, 9, 14, blake2_sigma(row, 14), blake2_sigma(row, 15))
	else:
		for i in range(16): m[i] = load_le32(&block[4 * i]) & mask
		v[12] = (v[12] ^ s.t_lo) & mask
		v[13] = (v[13] ^ s.t_hi) & mask
		if (last): v[14] = (v[14] ^ mask) & mask
		for r in range(10):
			blake2s_g(v, m, 0, 4, 8, 12, blake2_sigma(r, 0), blake2_sigma(r, 1))
			blake2s_g(v, m, 1, 5, 9, 13, blake2_sigma(r, 2), blake2_sigma(r, 3))
			blake2s_g(v, m, 2, 6, 10, 14, blake2_sigma(r, 4), blake2_sigma(r, 5))
			blake2s_g(v, m, 3, 7, 11, 15, blake2_sigma(r, 6), blake2_sigma(r, 7))
			blake2s_g(v, m, 0, 5, 10, 15, blake2_sigma(r, 8), blake2_sigma(r, 9))
			blake2s_g(v, m, 1, 6, 11, 12, blake2_sigma(r, 10), blake2_sigma(r, 11))
			blake2s_g(v, m, 2, 7, 8, 13, blake2_sigma(r, 12), blake2_sigma(r, 13))
			blake2s_g(v, m, 3, 4, 9, 14, blake2_sigma(r, 14), blake2_sigma(r, 15))
	for i in range(w): h[i] = (h[i] ^ v[i] ^ v[w + i]) & mask


# Advance the byte counter by n (0 <= n <= block size).
void blake2_count(blake2* s, int n):
	int mask = blake2_mask32()
	int lo0 = (s.t_lo & 0xffff) + n
	int lo1 = blake2_shr(s.t_lo, 16) + (lo0 >> 16)
	s.t_lo = ((lo1 << 16) | (lo0 & 0xffff)) & mask
	s.t_hi = (s.t_hi + (lo1 >> 16)) & mask


/* Construction */


# The full constructor: wide = 1 for BLAKE2b, 0 for BLAKE2s. key, salt
# and person may be 0 when their length is 0. Returns 0 on invalid
# parameters (see the module comment).
blake2* blake2_new_params(int wide, int digest_size, char* key, int key_len, char* salt, int salt_len, char* person, int person_len):
	int max_digest = BLAKE2S_MAX_DIGEST_SIZE
	int field = BLAKE2S_SALT_SIZE
	int bs = BLAKE2S_BLOCK_SIZE
	if (wide):
		max_digest = BLAKE2B_MAX_DIGEST_SIZE
		field = BLAKE2B_SALT_SIZE
		bs = BLAKE2B_BLOCK_SIZE
	# Max key size equals max digest size and salt size equals person
	# size for both variants.
	if ((digest_size < 1) || (digest_size > max_digest)): return cast(blake2*, 0)
	if ((key_len < 0) || (key_len > max_digest)): return cast(blake2*, 0)
	if ((salt_len < 0) || (salt_len > field)): return cast(blake2*, 0)
	if ((person_len < 0) || (person_len > field)): return cast(blake2*, 0)

	blake2* s = new blake2
	s.wide = wide
	s.digest_size = digest_size
	s.block_size = bs
	s.words = 8
	if (wide): s.words = 16
	s.h = cast(int*, malloc(s.words * __word_size__))
	s.iv = cast(int*, malloc(s.words * __word_size__))
	s.v = cast(int*, malloc(2 * s.words * __word_size__))
	s.m = cast(int*, malloc(2 * s.words * __word_size__))
	s.buf = cast(char*, malloc(bs))
	s.buffered = 0
	s.t_hi = 0
	s.t_lo = 0

	# The IVs are the SHA-512 / SHA-256 initial hash values; BLAKE2b's
	# are listed hi word first, matching the pair layout.
	char* iv_hex = c"6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19"
	if (wide): iv_hex = c"6a09e667f3bcc908bb67ae8584caa73b3c6ef372fe94f82ba54ff53a5f1d36f1510e527fade682d19b05688c2b3e6c1f1f83d9abfb41bd6b5be0cd19137e2179"
	for i in range(s.words): s.iv[i] = blake2_hex32(&iv_hex[i * 8])

	# Parameter block (RFC 7693 section 2.5 / BLAKE2 spec section 2.8):
	# digest length, key length, fanout 1, depth 1, everything else zero
	# apart from salt and personalization, which fill the last two fields.
	int pb_len = 32
	if (wide): pb_len = 64
	char* pb = cast(char*, malloc(pb_len))
	mem_fill(pb, 0, pb_len)
	pb[0] = digest_size
	pb[1] = key_len
	pb[2] = 1
	pb[3] = 1
	if (salt_len > 0): mem_copy[char](&pb[pb_len - 2 * field], salt, salt_len)
	if (person_len > 0): mem_copy[char](&pb[pb_len - field], person, person_len)
	int mask = blake2_mask32()
	if (wide):
		for i in range(8):
			s.h[2 * i] = (s.iv[2 * i] ^ load_le32(&pb[8 * i + 4])) & mask
			s.h[2 * i + 1] = (s.iv[2 * i + 1] ^ load_le32(&pb[8 * i])) & mask
	else:
		for i in range(8): s.h[i] = (s.iv[i] ^ load_le32(&pb[4 * i])) & mask
	free(pb)

	# Keyed mode: the key, zero-padded to a full block, is the first
	# block of input.
	if (key_len > 0):
		mem_fill(s.buf, 0, bs)
		mem_copy(s.buf, key, key_len)
		s.buffered = bs
	return s


blake2* blake2b_new(int digest_size):
	return blake2_new_params(1, digest_size, 0, 0, 0, 0, 0, 0)


blake2* blake2s_new(int digest_size):
	return blake2_new_params(0, digest_size, 0, 0, 0, 0, 0, 0)


blake2* blake2b_new_keyed(int digest_size, char* key, int key_len):
	return blake2_new_params(1, digest_size, key, key_len, 0, 0, 0, 0)


blake2* blake2s_new_keyed(int digest_size, char* key, int key_len):
	return blake2_new_params(0, digest_size, key, key_len, 0, 0, 0, 0)


void blake2_free(blake2* s):
	if (s == 0): return
	free(s.h)
	free(s.iv)
	free(s.v)
	free(s.m)
	free(s.buf)
	free(s)


# Independent copy with the same absorbed input (hashlib's .copy()).
blake2* blake2_copy(blake2* s):
	blake2* c = new blake2
	c.wide = s.wide
	c.digest_size = s.digest_size
	c.block_size = s.block_size
	c.words = s.words
	c.h = cast(int*, malloc(s.words * __word_size__))
	c.iv = cast(int*, malloc(s.words * __word_size__))
	c.v = cast(int*, malloc(2 * s.words * __word_size__))
	c.m = cast(int*, malloc(2 * s.words * __word_size__))
	c.buf = cast(char*, malloc(s.block_size))
	mem_copy(c.h, s.h, s.words)
	mem_copy(c.iv, s.iv, s.words)
	mem_copy(c.buf, s.buf, s.buffered)
	c.buffered = s.buffered
	c.t_hi = s.t_hi
	c.t_lo = s.t_lo
	return c


int blake2_digest_size(blake2* s):
	return s.digest_size


int blake2_block_size(blake2* s):
	return s.block_size


/* Streaming */


# Absorb len bytes at data. The last block is held back until more input
# arrives, since it must be compressed with the final-block flag.
void blake2_update(blake2* s, char* data, int len):
	int bs = s.block_size
	int pos = 0
	while (pos < len):
		if (s.buffered == bs):
			blake2_count(s, bs)
			blake2_compress(s, s.h, s.buf, 0)
			s.buffered = 0
		if (s.buffered == 0):
			# Whole blocks straight from the input, keeping at least one
			# byte back.
			while (len - pos > bs):
				blake2_count(s, bs)
				blake2_compress(s, s.h, &data[pos], 0)
				pos = pos + bs
		int take = bs - s.buffered
		if (take > len - pos): take = len - pos
		mem_copy[char](&s.buf[s.buffered], &data[pos], take)
		s.buffered = s.buffered + take
		pos = pos + take


# Write the digest of everything absorbed so far to out (digest_size
# bytes). Non-destructive: the stream can keep absorbing afterwards.
void blake2_final(blake2* s, char* out):
	int w = s.words
	int bs = s.block_size
	int* h = cast(int*, malloc(w * __word_size__))
	mem_copy(h, s.h, w)
	char* block = cast(char*, malloc(bs))
	mem_fill(block, 0, bs)
	mem_copy(block, s.buf, s.buffered)
	int save_hi = s.t_hi
	int save_lo = s.t_lo
	blake2_count(s, s.buffered)
	blake2_compress(s, h, block, 1)
	s.t_hi = save_hi
	s.t_lo = save_lo
	# Little-endian serialisation of the state, truncated.
	for i in range(8): store_le32(&block[8 * i], 0)
	if (s.wide):
		for i in range(8):
			store_le32(&block[8 * i], h[2 * i + 1])
			store_le32(&block[8 * i + 4], h[2 * i])
	else:
		for i in range(8): store_le32(&block[4 * i], h[i])
	mem_copy(out, block, s.digest_size)
	free(block)
	free(h)


# Digest as a malloc'd buffer of blake2_digest_size(s) bytes.
char* blake2_digest(blake2* s):
	char* out = cast(char*, malloc(s.digest_size))
	blake2_final(s, out)
	return out


# Digest as a malloc'd NUL-terminated lowercase hex string.
char* blake2_hexdigest(blake2* s):
	char* d = blake2_digest(s)
	char* hex = hex_encode(d, s.digest_size)
	free(d)
	return hex


/* One-shot helpers (all results malloc'd; 0 on invalid parameters) */


char* blake2_oneshot(int wide, int digest_size, char* key, int key_len, char* data, int len, int as_hex):
	blake2* s = blake2_new_params(wide, digest_size, key, key_len, 0, 0, 0, 0)
	if (s == 0): return cast(char*, 0)
	blake2_update(s, data, len)
	char* out = 0
	if (as_hex): out = blake2_hexdigest(s)
	else: out = blake2_digest(s)
	blake2_free(s)
	return out


char* blake2b(char* data, int len, int digest_size):
	return blake2_oneshot(1, digest_size, 0, 0, data, len, 0)


char* blake2b_hex(char* data, int len, int digest_size):
	return blake2_oneshot(1, digest_size, 0, 0, data, len, 1)


char* blake2s(char* data, int len, int digest_size):
	return blake2_oneshot(0, digest_size, 0, 0, data, len, 0)


char* blake2s_hex(char* data, int len, int digest_size):
	return blake2_oneshot(0, digest_size, 0, 0, data, len, 1)


# Keyed BLAKE2 (the MAC mode hashlib exposes as blake2b(key=...)).
char* blake2b_keyed(char* key, int key_len, char* data, int len, int digest_size):
	return blake2_oneshot(1, digest_size, key, key_len, data, len, 0)


char* blake2b_keyed_hex(char* key, int key_len, char* data, int len, int digest_size):
	return blake2_oneshot(1, digest_size, key, key_len, data, len, 1)


char* blake2s_keyed(char* key, int key_len, char* data, int len, int digest_size):
	return blake2_oneshot(0, digest_size, key, key_len, data, len, 0)


char* blake2s_keyed_hex(char* key, int key_len, char* data, int len, int digest_size):
	return blake2_oneshot(0, digest_size, key, key_len, data, len, 1)
