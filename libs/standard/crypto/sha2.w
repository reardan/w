/*
SHA-2 streaming hashes for the native TLS stack (plan 11, issue #195):
SHA-384 and SHA-512 implemented here, SHA-256 delegated to the existing
lib/sha256.w core (which stays untouched — it sits in the seed-built
compiler's import graph).

The whash interface is the hash surface the rest of the stack (HMAC, HKDF,
the TLS 1.3 transcript hash, ECDSA digests) builds against:

	whash* h = whash_new(WHASH_SHA384())
	whash_update(h, data, len)        # any number of times
	whash_final(h, out)               # non-destructive: h keeps absorbing,
	                                  # so a TLS transcript can snapshot
	                                  # digests mid-stream
	whash_free(h)

32-bit portability (plan 11 "32-bit portability rule"): SHA-512's 64-bit
words are hi/lo pairs of 32-bit ints — no int64 anywhere, so the module
runs identically on the x86, x64 and arm64 targets. The conventions follow
lib/sha256.w: every 32-bit word is observed only through its low 32 bits
(& sha256_mask32()), right shifts go through sha256_shr so a 32-bit
target's arithmetic shift cannot smear sign bits, and no integer literal
with bit 31 set appears in the source (the K and H0 tables are hex text
parsed at first use). 64-bit additions split the low word into 16-bit
halves so the carry out of the low 32 bits is computed without overflow.

Out-of-tree hash modules (e.g. the quarantined legacy digests in
libs/x/unsafe) plug additional algorithms into this dispatcher through
whash_register, so HMAC/HKDF compose over them without this module — or
anything else under libs/standard — importing their namespace.
*/
import lib.memory
import lib.sha256


# Algorithm identifiers for the whash interface. Ids below 100 are
# reserved for the built-in SHA-2 family; algorithms plugged in through
# whash_register use ids of 100 and up.
int WHASH_SHA256():
	return 1


int WHASH_SHA384():
	return 2


int WHASH_SHA512():
	return 3


/* Extension registry: whash_register plugs an out-of-tree compression
   function into the whash dispatcher at runtime. The registrant supplies
   the algorithm geometry plus two callbacks; state is an int array of
   state_words masked 32-bit words (the lib/sha256.w conventions), block
   one input block of block_size bytes. Merkle–Damgård padding stays in
   whash_final: little_endian selects the MD5-style trailer (64-bit bit
   count little-endian, digest words emitted little-endian) over the
   SHA-style big-endian one. */


type whash_compress_fn = fn(int*, char*) -> void
type whash_iv_fn = fn(int*) -> void


struct whash_ext:
	int alg
	int digest_size
	int block_size
	int state_words
	int little_endian
	whash_compress_fn* compress
	whash_iv_fn* load_iv
	whash_ext* next


whash_ext* whash_ext_registry


# The registered extension for alg, or 0 for the built-in algorithms.
whash_ext* whash_ext_find(int alg):
	whash_ext* e = whash_ext_registry
	while (e != 0):
		if (e.alg == alg):
			return e
		e = e.next
	return cast(whash_ext*, 0)


# Register (or idempotently re-register) algorithm `alg`. Extension ids
# must be 100 or higher; ids below 100 belong to the built-in SHA-2
# family and are never looked up in the registry.
void whash_register(int alg, int digest_size, int block_size, int state_words, int little_endian, whash_compress_fn* compress, whash_iv_fn* load_iv):
	whash_ext* e = whash_ext_find(alg)
	if (e == 0):
		e = new whash_ext
		e.next = whash_ext_registry
		whash_ext_registry = e
	e.alg = alg
	e.digest_size = digest_size
	e.block_size = block_size
	e.state_words = state_words
	e.little_endian = little_endian
	e.compress = compress
	e.load_iv = load_iv


# Digest length in bytes.
int whash_digest_size(int alg):
	whash_ext* e = whash_ext_find(alg)
	if (e != 0):
		return e.digest_size
	if (alg == WHASH_SHA256()):
		return 32
	if (alg == WHASH_SHA384()):
		return 48
	return 64


# Input block length in bytes (HMAC pads keys to this size).
int whash_block_size(int alg):
	whash_ext* e = whash_ext_find(alg)
	if (e != 0):
		return e.block_size
	if (alg == WHASH_SHA256()):
		return 64
	return 128


# Words of internal state: 8 ints for SHA-256, 8 hi/lo pairs for SHA-512.
int whash_state_words(int alg):
	whash_ext* e = whash_ext_find(alg)
	if (e != 0):
		return e.state_words
	if (alg == WHASH_SHA256()):
		return 8
	return 16


/* 64-bit words as hi/lo pairs of masked 32-bit ints */


# r[0] = hi, r[1] = lo of the pair sum r + (bh, bl), both masked. The low
# word is added in 16-bit halves: every partial sum stays below 2^17, so
# the carry into the high word is exact on a 32-bit target.
void sha2_add64(int* r, int bh, int bl):
	int mask = sha256_mask32()
	int lo0 = (r[1] & 0xffff) + (bl & 0xffff)
	int lo1 = sha256_shr(r[1], 16) + sha256_shr(bl, 16) + (lo0 >> 16)
	r[1] = (((lo1 & 0xffff) << 16) | (lo0 & 0xffff)) & mask
	r[0] = (r[0] + bh + (lo1 >> 16)) & mask


# High word of (hi:lo) rotated right by n (1..63).
int sha2_rotr_hi(int hi, int lo, int n):
	int mask = sha256_mask32()
	if (n == 32):
		return lo & mask
	if (n < 32):
		return (sha256_shr(hi, n) | (lo << (32 - n))) & mask
	int m = n - 32
	return (sha256_shr(lo, m) | (hi << (32 - m))) & mask


# Low word of (hi:lo) rotated right by n.
int sha2_rotr_lo(int hi, int lo, int n):
	int mask = sha256_mask32()
	if (n == 32):
		return hi & mask
	if (n < 32):
		return (sha256_shr(lo, n) | (hi << (32 - n))) & mask
	int m = n - 32
	return (sha256_shr(hi, m) | (lo << (32 - m))) & mask


/* The four SHA-512 sigma functions, one 32-bit half at a time. */


# BSIG0 = rotr28 ^ rotr34 ^ rotr39
int sha2_bsig0_hi(int hi, int lo):
	return (sha2_rotr_hi(hi, lo, 28) ^ sha2_rotr_hi(hi, lo, 34) ^ sha2_rotr_hi(hi, lo, 39)) & sha256_mask32()


int sha2_bsig0_lo(int hi, int lo):
	return (sha2_rotr_lo(hi, lo, 28) ^ sha2_rotr_lo(hi, lo, 34) ^ sha2_rotr_lo(hi, lo, 39)) & sha256_mask32()


# BSIG1 = rotr14 ^ rotr18 ^ rotr41
int sha2_bsig1_hi(int hi, int lo):
	return (sha2_rotr_hi(hi, lo, 14) ^ sha2_rotr_hi(hi, lo, 18) ^ sha2_rotr_hi(hi, lo, 41)) & sha256_mask32()


int sha2_bsig1_lo(int hi, int lo):
	return (sha2_rotr_lo(hi, lo, 14) ^ sha2_rotr_lo(hi, lo, 18) ^ sha2_rotr_lo(hi, lo, 41)) & sha256_mask32()


# SSIG0 = rotr1 ^ rotr8 ^ shr7
int sha2_ssig0_hi(int hi, int lo):
	return (sha2_rotr_hi(hi, lo, 1) ^ sha2_rotr_hi(hi, lo, 8) ^ sha256_shr(hi, 7)) & sha256_mask32()


int sha2_ssig0_lo(int hi, int lo):
	int shr7_lo = (sha256_shr(lo, 7) | (hi << 25)) & sha256_mask32()
	return (sha2_rotr_lo(hi, lo, 1) ^ sha2_rotr_lo(hi, lo, 8) ^ shr7_lo) & sha256_mask32()


# SSIG1 = rotr19 ^ rotr61 ^ shr6
int sha2_ssig1_hi(int hi, int lo):
	return (sha2_rotr_hi(hi, lo, 19) ^ sha2_rotr_hi(hi, lo, 61) ^ sha256_shr(hi, 6)) & sha256_mask32()


int sha2_ssig1_lo(int hi, int lo):
	int shr6_lo = (sha256_shr(lo, 6) | (hi << 26)) & sha256_mask32()
	return (sha2_rotr_lo(hi, lo, 19) ^ sha2_rotr_lo(hi, lo, 61) ^ shr6_lo) & sha256_mask32()


/* Constant tables, parsed from hex text at first use so no literal ever
   carries bit 31 (see lib/sha256.w's portability note). */


int sha2_hex_nibble(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	return c - 'a' + 10


# Parse 8 lowercase hex chars into one masked 32-bit word.
int sha2_hex32(char* s):
	int v = 0
	int i = 0
	while (i < 8):
		v = (v << 4) | sha2_hex_nibble(s[i] & 255)
		i = i + 1
	return v & sha256_mask32()


# Little-endian store of a masked 32-bit word (MD5-style trailers and
# digests; the big-endian twin lives in lib/sha256.w).
void sha2_put_le32(char* p, int v):
	p[0] = v & 255
	p[1] = (v >> 8) & 255
	p[2] = (v >> 16) & 255
	p[3] = (v >> 24) & 255


# Parse `words` 32-bit words from hex text into a malloc'd int array.
int* sha2_parse_words(char* hex, int words):
	int* out = cast(int*, malloc(words * __word_size__))
	int i = 0
	while (i < words):
		out[i] = sha2_hex32(hex + i * 8)
		i = i + 1
	return out


int* sha2_k512_cache


# The 80 SHA-512 round constants (fractional cube roots of the first 80
# primes, FIPS 180-4 §4.2.3) as hi/lo pairs: k[2i] is the high word of
# K[i], k[2i+1] the low word.
int* sha2_k512_table():
	if (sha2_k512_cache == 0):
		sha2_k512_cache = sha2_parse_words(c"428a2f98d728ae227137449123ef65cdb5c0fbcfec4d3b2fe9b5dba58189dbbc3956c25bf348b53859f111f1b605d019923f82a4af194f9bab1c5ed5da6d8118d807aa98a303024212835b0145706fbe243185be4ee4b28c550c7dc3d5ffb4e272be5d74f27b896f80deb1fe3b1696b19bdc06a725c71235c19bf174cf692694e49b69c19ef14ad2efbe4786384f25e30fc19dc68b8cd5b5240ca1cc77ac9c652de92c6f592b02754a7484aa6ea6e4835cb0a9dcbd41fbd476f988da831153b5983e5152ee66dfaba831c66d2db43210b00327c898fb213fbf597fc7beef0ee4c6e00bf33da88fc2d5a79147930aa72506ca6351e003826f142929670a0e6e7027b70a8546d22ffc2e1b21385c26c9264d2c6dfc5ac42aed53380d139d95b3df650a73548baf63de766a0abb3c77b2a881c2c92e47edaee692722c851482353ba2bfe8a14cf10364a81a664bbc423001c24b8b70d0f89791c76c51a30654be30d192e819d6ef5218d69906245565a910f40e35855771202a106aa07032bbd1b819a4c116b8d2d0c81e376c085141ab532748774cdf8eeb9934b0bcb5e19b48a8391c0cb3c5c95a634ed8aa4ae3418acb5b9cca4f7763e373682e6ff3d6b2b8a3748f82ee5defb2fc78a5636f43172f6084c87814a1f0ab728cc702081a6439ec90befffa23631e28a4506cebde82bde9bef9a3f7b2c67915c67178f2e372532bca273eceea26619cd186b8c721c0c207eada7dd6cde0eb1ef57d4f7fee6ed17806f067aa72176fba0a637dc5a2c898a6113f9804bef90dae1b710b35131c471b28db77f523047d8432caab7b40c724933c9ebe0a15c9bebc431d67c49c100d4c4cc5d4becb3e42b6597f299cfc657e2a5fcb6fab3ad6faec6c44198c4a475817", 160)
	return sha2_k512_cache


int* sha2_h512_cache


# SHA-512 initial hash (fractional square roots of the first 8 primes).
int* sha2_h512_table():
	if (sha2_h512_cache == 0):
		sha2_h512_cache = sha2_parse_words(c"6a09e667f3bcc908bb67ae8584caa73b3c6ef372fe94f82ba54ff53a5f1d36f1510e527fade682d19b05688c2b3e6c1f1f83d9abfb41bd6b5be0cd19137e2179", 16)
	return sha2_h512_cache


int* sha2_h384_cache


# SHA-384 initial hash (fractional square roots of the 9th..16th primes).
int* sha2_h384_table():
	if (sha2_h384_cache == 0):
		sha2_h384_cache = sha2_parse_words(c"cbbb9d5dc1059ed8629a292a367cd5079159015a3070dd17152fecd8f70e593967332667ffc00b318eb44a8768581511db0c2e0d64f98fa747b5481dbefa4fa4", 16)
	return sha2_h384_cache


# Compress one 128-byte block into the SHA-512 state: 8 hi/lo pairs, hi
# word of word j at state[2j], lo word at state[2j+1].
void sha512_block(int* state, char* block):
	int* k = sha2_k512_table()
	int* w = cast(int*, malloc(160 * __word_size__))
	int* t = cast(int*, malloc(2 * __word_size__))

	int i = 0
	while (i < 16):
		w[i * 2] = sha256_be32(block + i * 8)
		w[i * 2 + 1] = sha256_be32(block + i * 8 + 4)
		i = i + 1
	while (i < 80):
		# w[i] = SSIG1(w[i-2]) + w[i-7] + SSIG0(w[i-15]) + w[i-16]
		int w2h = w[(i - 2) * 2]
		int w2l = w[(i - 2) * 2 + 1]
		int w15h = w[(i - 15) * 2]
		int w15l = w[(i - 15) * 2 + 1]
		t[0] = sha2_ssig1_hi(w2h, w2l)
		t[1] = sha2_ssig1_lo(w2h, w2l)
		sha2_add64(t, w[(i - 7) * 2], w[(i - 7) * 2 + 1])
		sha2_add64(t, sha2_ssig0_hi(w15h, w15l), sha2_ssig0_lo(w15h, w15l))
		sha2_add64(t, w[(i - 16) * 2], w[(i - 16) * 2 + 1])
		w[i * 2] = t[0]
		w[i * 2 + 1] = t[1]
		i = i + 1

	int a_hi = state[0]
	int a_lo = state[1]
	int b_hi = state[2]
	int b_lo = state[3]
	int c_hi = state[4]
	int c_lo = state[5]
	int d_hi = state[6]
	int d_lo = state[7]
	int e_hi = state[8]
	int e_lo = state[9]
	int f_hi = state[10]
	int f_lo = state[11]
	int g_hi = state[12]
	int g_lo = state[13]
	int h_hi = state[14]
	int h_lo = state[15]

	i = 0
	while (i < 80):
		# t1 = h + BSIG1(e) + CH(e,f,g) + K[i] + W[i]. CH and MAJ act on
		# each 32-bit half independently, so lib/sha256.w's ch/maj apply.
		t[0] = h_hi
		t[1] = h_lo
		sha2_add64(t, sha2_bsig1_hi(e_hi, e_lo), sha2_bsig1_lo(e_hi, e_lo))
		sha2_add64(t, sha256_ch(e_hi, f_hi, g_hi), sha256_ch(e_lo, f_lo, g_lo))
		sha2_add64(t, k[i * 2], k[i * 2 + 1])
		sha2_add64(t, w[i * 2], w[i * 2 + 1])
		int t1_hi = t[0]
		int t1_lo = t[1]

		# t2 = BSIG0(a) + MAJ(a,b,c)
		t[0] = sha2_bsig0_hi(a_hi, a_lo)
		t[1] = sha2_bsig0_lo(a_hi, a_lo)
		sha2_add64(t, sha256_maj(a_hi, b_hi, c_hi), sha256_maj(a_lo, b_lo, c_lo))
		int t2_hi = t[0]
		int t2_lo = t[1]

		h_hi = g_hi
		h_lo = g_lo
		g_hi = f_hi
		g_lo = f_lo
		f_hi = e_hi
		f_lo = e_lo
		t[0] = d_hi
		t[1] = d_lo
		sha2_add64(t, t1_hi, t1_lo)
		e_hi = t[0]
		e_lo = t[1]
		d_hi = c_hi
		d_lo = c_lo
		c_hi = b_hi
		c_lo = b_lo
		b_hi = a_hi
		b_lo = a_lo
		t[0] = t1_hi
		t[1] = t1_lo
		sha2_add64(t, t2_hi, t2_lo)
		a_hi = t[0]
		a_lo = t[1]
		i = i + 1

	t[0] = state[0]
	t[1] = state[1]
	sha2_add64(t, a_hi, a_lo)
	state[0] = t[0]
	state[1] = t[1]
	t[0] = state[2]
	t[1] = state[3]
	sha2_add64(t, b_hi, b_lo)
	state[2] = t[0]
	state[3] = t[1]
	t[0] = state[4]
	t[1] = state[5]
	sha2_add64(t, c_hi, c_lo)
	state[4] = t[0]
	state[5] = t[1]
	t[0] = state[6]
	t[1] = state[7]
	sha2_add64(t, d_hi, d_lo)
	state[6] = t[0]
	state[7] = t[1]
	t[0] = state[8]
	t[1] = state[9]
	sha2_add64(t, e_hi, e_lo)
	state[8] = t[0]
	state[9] = t[1]
	t[0] = state[10]
	t[1] = state[11]
	sha2_add64(t, f_hi, f_lo)
	state[10] = t[0]
	state[11] = t[1]
	t[0] = state[12]
	t[1] = state[13]
	sha2_add64(t, g_hi, g_lo)
	state[12] = t[0]
	state[13] = t[1]
	t[0] = state[14]
	t[1] = state[15]
	sha2_add64(t, h_hi, h_lo)
	state[14] = t[0]
	state[15] = t[1]

	free(t)
	free(w)


/* Streaming interface */


struct whash:
	int alg
	int digest_size
	int block_size
	int state_words
	whash_ext* ext   # registered extension entry, 0 for the built-ins
	int* state       # 8 words (SHA-256) or 8 hi/lo pairs (SHA-384/512)
	char* buffer     # up to block_size-1 pending input bytes
	int buffered
	int len_hi       # total input length in bytes, as a hi/lo pair
	int len_lo
	int* scratch     # one hi/lo pair reused by internal arithmetic


# Load the initial hash values for h.alg into h.state.
void whash_load_iv(whash* h):
	whash_ext* e = h.ext
	if (e != 0):
		e.load_iv(h.state)
		return
	if (h.alg == WHASH_SHA256()):
		char* h0 = sha256_h0_table()
		int i = 0
		while (i < 8):
			h.state[i] = sha256_be32(h0 + i * 4)
			i = i + 1
		return
	int* iv = sha2_h512_table()
	if (h.alg == WHASH_SHA384()):
		iv = sha2_h384_table()
	int j = 0
	while (j < 16):
		h.state[j] = iv[j]
		j = j + 1


whash* whash_new(int alg):
	whash* h = new whash
	h.alg = alg
	h.ext = whash_ext_find(alg)
	h.digest_size = whash_digest_size(alg)
	h.block_size = whash_block_size(alg)
	h.state_words = whash_state_words(alg)
	h.state = cast(int*, malloc(h.state_words * __word_size__))
	h.buffer = malloc(h.block_size)
	h.buffered = 0
	h.len_hi = 0
	h.len_lo = 0
	h.scratch = cast(int*, malloc(2 * __word_size__))
	whash_load_iv(h)
	return h


# Restart the hash from the empty message, keeping the allocations.
void whash_reset(whash* h):
	h.buffered = 0
	h.len_hi = 0
	h.len_lo = 0
	whash_load_iv(h)


# Independent copy with the same absorbed input (transcript snapshots).
whash* whash_clone(whash* h):
	whash* c = whash_new(h.alg)
	int i = 0
	while (i < h.state_words):
		c.state[i] = h.state[i]
		i = i + 1
	i = 0
	while (i < h.buffered):
		c.buffer[i] = h.buffer[i]
		i = i + 1
	c.buffered = h.buffered
	c.len_hi = h.len_hi
	c.len_lo = h.len_lo
	return c


void whash_free(whash* h):
	free(h.state)
	free(h.buffer)
	free(h.scratch)
	free(h)


void whash_compress(whash* h, char* block):
	whash_ext* e = h.ext
	if (e != 0):
		e.compress(h.state, block)
		return
	if (h.alg == WHASH_SHA256()):
		sha256_block(h.state, block)
	else:
		sha512_block(h.state, block)


# Absorb len bytes at data.
void whash_update(whash* h, char* data, int len):
	if (len <= 0):
		return
	h.scratch[0] = h.len_hi
	h.scratch[1] = h.len_lo
	sha2_add64(h.scratch, 0, len)
	h.len_hi = h.scratch[0]
	h.len_lo = h.scratch[1]

	int bs = h.block_size
	int pos = 0
	# Top up a partial buffer first.
	if (h.buffered > 0):
		while ((h.buffered < bs) & (pos < len)):
			h.buffer[h.buffered] = data[pos]
			h.buffered = h.buffered + 1
			pos = pos + 1
		if (h.buffered == bs):
			whash_compress(h, h.buffer)
			h.buffered = 0
	# Whole blocks straight from the input.
	while (pos + bs <= len):
		whash_compress(h, data + pos)
		pos = pos + bs
	# Stash the remainder.
	while (pos < len):
		h.buffer[h.buffered] = data[pos]
		h.buffered = h.buffered + 1
		pos = pos + 1


# Write the digest of everything absorbed so far to out (digest_size
# bytes). Non-destructive: padding runs on a copy of the state, so the
# stream can keep absorbing afterwards — the TLS transcript hash needs
# exactly this mid-handshake snapshot.
void whash_final(whash* h, char* out):
	int* st = cast(int*, malloc(h.state_words * __word_size__))
	int i = 0
	while (i < h.state_words):
		st[i] = h.state[i]
		i = i + 1

	int bs = h.block_size
	int length_field = 8
	if (bs == 128):
		length_field = 16
	char* tail = malloc(bs * 2)
	int j = 0
	while (j < bs * 2):
		tail[j] = 0
		j = j + 1
	j = 0
	while (j < h.buffered):
		tail[j] = h.buffer[j]
		j = j + 1
	tail[h.buffered] = 128 /* 0x80 terminator */

	int blocks = 1
	if (h.buffered >= bs - length_field):
		blocks = 2
	# Message length in bits in the trailing length field: big-endian for
	# the SHA family, little-endian (low word first) for MD5-style
	# extensions. bits = bytes * 8: a left shift by 3 across the hi/lo
	# byte count.
	whash_ext* e = h.ext
	int le = 0
	if (e != 0):
		le = e.little_endian
	int mask = sha256_mask32()
	int bits_mid = ((h.len_hi << 3) | sha256_shr(h.len_lo, 29)) & mask
	int bits_lo = (h.len_lo << 3) & mask
	int end = blocks * bs
	if (le == 1):
		sha2_put_le32(tail + end - 8, bits_lo)
		sha2_put_le32(tail + end - 4, bits_mid)
	else:
		if (bs == 128):
			# 128-bit field; the byte count fits 64 bits, so the top word
			# is the 3 bits shifted out of len_hi.
			sha256_put_be32(tail + end - 12, sha256_shr(h.len_hi, 29))
		sha256_put_be32(tail + end - 8, bits_mid)
		sha256_put_be32(tail + end - 4, bits_lo)

	if (e != 0):
		e.compress(st, tail)
		if (blocks == 2):
			e.compress(st, tail + bs)
	else:
		if (h.alg == WHASH_SHA256()):
			sha256_block(st, tail)
			if (blocks == 2):
				sha256_block(st, tail + bs)
		else:
			sha512_block(st, tail)
			if (blocks == 2):
				sha512_block(st, tail + bs)
	free(tail)

	# Digest output, truncated to digest_size (SHA-384 keeps the first 6
	# of the 8 state words); word order follows the algorithm's
	# endianness.
	int words = h.digest_size / 4
	i = 0
	while (i < words):
		if (le == 1):
			sha2_put_le32(out + i * 4, st[i])
		else:
			sha256_put_be32(out + i * 4, st[i])
		i = i + 1
	free(st)


# One-shot convenience: digest of len bytes at data into out.
void whash_oneshot(int alg, char* data, int len, char* out):
	if (alg == WHASH_SHA256()):
		# lib/sha256.w already implements the one-shot form.
		sha256(data, len, out)
		return
	whash* h = whash_new(alg)
	whash_update(h, data, len)
	whash_final(h, out)
	whash_free(h)
