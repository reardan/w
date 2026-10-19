/*
SHA-3 and SHAKE (FIPS 202): the Keccak-f[1600] sponge with the four fixed
SHA3-224/256/384/512 digests and the SHAKE128/SHAKE256 extendable-output
functions (Python's hashlib.sha3_* / hashlib.shake_*).

Streaming interface, shaped like libs/standard/crypto/sha2.w's whash:

	sha3_ctx* h = sha3_new(SHA3_256)
	sha3_update(h, data, len)        # any number of times
	sha3_final(h, out)               # digest_size bytes; non-destructive,
	                                 # so h keeps absorbing afterwards
	sha3_free(h)

SHAKE contexts also have shake_final(h, out, n) (any n >= 0 bytes,
non-destructive, like Python's shake.digest(n)) and shake_squeeze(h, out,
n), which reads the output stream incrementally: successive calls continue
where the previous one stopped, and the context accepts no further input
afterwards (sha3_update is then a no-op; sha3_reset re-arms it).

One-shot helpers: sha3_224/256/384/512(data, len, out) and
shake128/256(data, len, out, n) write raw bytes; sha3_digest and
shake_digest return a malloc'd raw digest, sha3_hexdigest and
shake_hexdigest a malloc'd lowercase hex string.

32-bit portability (the lib/sha256.w / sha2.w conventions): each 64-bit
lane is a lo/hi pair of 32-bit words held in ints, lane i's low word at
state[2i] and high word at state[2i+1]. Every word is observed only
through its low 32 bits (& sha256_mask32()), right shifts that keep a
whole word go through sha256_shr so a 32-bit target's arithmetic shift
cannot smear sign bits, and no literal has bit 31 set: the round constants
and rotation offsets are generated at sha3_new time (FIPS 202 §3.2.5 LFSR,
§3.2.2 offset walk) rather than written out. Keccak needs no additions, so
xor/and/not/rotate on the halves are exact on x86, x64 and arm64 alike.
*/
import lib.memory
import lib.sha256
import lib.hex
import lib.mem


# Algorithm identifiers.
const int SHA3_224 = 1
const int SHA3_256 = 2
const int SHA3_384 = 3
const int SHA3_512 = 4
const int SHAKE_128 = 5
const int SHAKE_256 = 6

# Per-context int block layout (one malloc): state, theta/chi scratch,
# round constants, rotation offsets.
const int SHA3_STATE = 0       # 50 words: 25 lanes as lo/hi pairs
const int SHA3_B = 50          # 50 words: rho/pi output lanes
const int SHA3_C = 100         # 10 words: theta column parities
const int SHA3_D = 110         # 10 words: theta column effects
const int SHA3_RC = 120        # 48 words: 24 round constants as lo/hi
const int SHA3_RHO = 168       # 25 words: rotation offset per lane
const int SHA3_WORDS = 193


struct sha3_ctx:
	int alg
	int rate          # sponge rate in bytes (the block size)
	int digest_size   # fixed digest length; the SHAKE default (32 / 64)
	int suffix        # domain-separation bits + first pad bit: 6 or 31
	int pos           # bytes absorbed into the current block
	int squeezing     # 1 once shake_squeeze started reading output
	int* w            # SHA3_WORDS ints, laid out as above


# 1 when alg names one of the six FIPS 202 functions.
int sha3_valid_alg(int alg):
	return (alg >= SHA3_224) && (alg <= SHAKE_256)


# 1 for the extendable-output functions.
int sha3_is_xof(int alg):
	return (alg == SHAKE_128) || (alg == SHAKE_256)


# Digest length in bytes (SHAKE: the hashlib-compatible default of twice
# the security strength is not defined there, so the 32/64-byte lengths
# matching SHA3-256/512 are used as the nominal size). 0 for unknown ids.
int sha3_digest_size(int alg):
	if (alg == SHA3_224): return 28
	if (alg == SHA3_256): return 32
	if (alg == SHA3_384): return 48
	if (alg == SHA3_512): return 64
	if (alg == SHAKE_128): return 32
	if (alg == SHAKE_256): return 64
	return 0


# Sponge rate (block size) in bytes: 200 - 2 * capacity/16.
int sha3_block_size(int alg):
	if (alg == SHA3_224): return 144
	if (alg == SHA3_256): return 136
	if (alg == SHA3_384): return 104
	if (alg == SHA3_512): return 72
	if (alg == SHAKE_128): return 168
	if (alg == SHAKE_256): return 136
	return 0


/* Lane arithmetic on lo/hi pairs */


# dst[0..1] = (lo, hi) rotated left by n (0..63).
void keccak_rotl(int* dst, int lo, int hi, int n):
	int mask = sha256_mask32()
	if (n == 0):
		dst[0] = lo
		dst[1] = hi
		return
	if (n >= 32):
		int t = lo
		lo = hi
		hi = t
		n = n - 32
		if (n == 0):
			dst[0] = lo
			dst[1] = hi
			return
	dst[0] = ((lo << n) | sha256_shr(hi, 32 - n)) & mask
	dst[1] = ((hi << n) | sha256_shr(lo, 32 - n)) & mask


# Fill the 24 round constants (FIPS 202 §3.2.5: rc(t) from the LFSR
# x^8 + x^6 + x^5 + x^4 + 1, bit 2^j - 1 of round i taken from rc(j + 7i))
# and the 25 rho offsets (§3.2.2) into w.
void keccak_tables(int* w):
	int r = 1
	for i in range(24):
		int lo = 0
		int hi = 0
		for j in range(7):
			if ((r & 1) == 1):
				int bit = (1 << j) - 1
				if (bit < 32): lo = lo | (1 << bit)
				else: hi = hi | (1 << (bit - 32))
			r = r << 1
			if ((r & 256) != 0): r = (r ^ 0x71) & 255
		w[SHA3_RC + i * 2] = lo & sha256_mask32()
		w[SHA3_RC + i * 2 + 1] = hi & sha256_mask32()
	w[SHA3_RHO] = 0
	int x = 1
	int y = 0
	for t in range(24):
		w[SHA3_RHO + x + 5 * y] = (((t + 1) * (t + 2)) / 2) % 64
		int nx = y
		y = (2 * x + 3 * y) % 5
		x = nx


# Keccak-f[1600] on the 25 lanes at st, using w's scratch and tables.
void keccak_f(int* st, int* w):
	int mask = sha256_mask32()
	int* b = &w[SHA3_B]
	int* c = &w[SHA3_C]
	int* d = &w[SHA3_D]
	int* rho = &w[SHA3_RHO]
	for round in range(24):
		# theta
		for x in range(5):
			int lo = st[x * 2] ^ st[(x + 5) * 2] ^ st[(x + 10) * 2] ^ st[(x + 15) * 2] ^ st[(x + 20) * 2]
			int hi = st[x * 2 + 1] ^ st[(x + 5) * 2 + 1] ^ st[(x + 10) * 2 + 1] ^ st[(x + 15) * 2 + 1] ^ st[(x + 20) * 2 + 1]
			c[x * 2] = lo & mask
			c[x * 2 + 1] = hi & mask
		for x in range(5):
			int xp = (x + 1) % 5
			int xm = (x + 4) % 5
			keccak_rotl(&d[x * 2], c[xp * 2], c[xp * 2 + 1], 1)
			d[x * 2] = d[x * 2] ^ c[xm * 2]
			d[x * 2 + 1] = d[x * 2 + 1] ^ c[xm * 2 + 1]
		for i in range(25):
			int col = i % 5
			st[i * 2] = st[i * 2] ^ d[col * 2]
			st[i * 2 + 1] = st[i * 2 + 1] ^ d[col * 2 + 1]
		# rho and pi: B[y, 2x + 3y] = rotl(A[x, y], rho[x, y])
		for y in range(5):
			for x in range(5):
				int src = x + 5 * y
				int dst = y + 5 * ((2 * x + 3 * y) % 5)
				keccak_rotl(&b[dst * 2], st[src * 2], st[src * 2 + 1], rho[src])
		# chi: A[x, y] = B[x, y] ^ (~B[x+1, y] & B[x+2, y])
		for y in range(5):
			for x in range(5):
				int i0 = (x + 5 * y) * 2
				int i1 = ((x + 1) % 5 + 5 * y) * 2
				int i2 = ((x + 2) % 5 + 5 * y) * 2
				st[i0] = b[i0] ^ ((b[i1] ^ mask) & b[i2])
				st[i0 + 1] = b[i0 + 1] ^ ((b[i1 + 1] ^ mask) & b[i2 + 1])
		# iota
		st[0] = st[0] ^ w[SHA3_RC + round * 2]
		st[1] = st[1] ^ w[SHA3_RC + round * 2 + 1]


# XOR one byte into the state at byte offset k (< 200) of the lane array.
void keccak_xor_byte(int* st, int k, int v):
	int idx = (k >> 3) * 2 + ((k >> 2) & 1)
	st[idx] = (st[idx] ^ ((v & 255) << ((k & 3) * 8))) & sha256_mask32()


# The byte at offset k of the lane array.
int keccak_get_byte(int* st, int k):
	int idx = (k >> 3) * 2 + ((k >> 2) & 1)
	return (st[idx] >> ((k & 3) * 8)) & 255


/* Streaming interface */


# A fresh context for alg, or 0 when alg is not a SHA3_* / SHAKE_* id.
sha3_ctx* sha3_new(int alg):
	if (!sha3_valid_alg(alg)): return cast(sha3_ctx*, 0)
	sha3_ctx* h = new sha3_ctx
	h.alg = alg
	h.rate = sha3_block_size(alg)
	h.digest_size = sha3_digest_size(alg)
	h.suffix = 6
	if (sha3_is_xof(alg)): h.suffix = 31
	h.w = cast(int*, malloc(SHA3_WORDS * __word_size__))
	keccak_tables(h.w)
	h.pos = 0
	h.squeezing = 0
	mem_fill(h.w, 0, 50)
	return h


# Restart from the empty message, keeping the allocation.
void sha3_reset(sha3_ctx* h):
	mem_fill(h.w, 0, 50)
	h.pos = 0
	h.squeezing = 0


# Independent copy with the same absorbed input.
sha3_ctx* sha3_clone(sha3_ctx* h):
	sha3_ctx* c = sha3_new(h.alg)
	mem_copy(c.w, h.w, 50)
	c.pos = h.pos
	c.squeezing = h.squeezing
	return c


void sha3_free(sha3_ctx* h):
	if (h == 0): return
	free(h.w)
	free(h)


# Absorb len bytes at data. Ignored once shake_squeeze has started.
void sha3_update(sha3_ctx* h, char* data, int len):
	if ((len <= 0) || (h.squeezing == 1)): return
	int* st = h.w
	int rate = h.rate
	int pos = h.pos
	int i = 0
	while (i < len):
		keccak_xor_byte(st, pos, data[i])
		pos = pos + 1
		i = i + 1
		if (pos == rate):
			keccak_f(st, h.w)
			pos = 0
	h.pos = pos


# Pad (suffix bits, final 1 bit) and permute the lanes at st, absorbed up
# to byte pos.
void sha3_pad(sha3_ctx* h, int* st, int pos):
	keccak_xor_byte(st, pos, h.suffix)
	keccak_xor_byte(st, h.rate - 1, 128)
	keccak_f(st, h.w)


# Squeeze n bytes from the padded lanes at st, starting at block offset
# *offp, permuting whenever a rate-sized block is used up. Updates *offp.
void sha3_squeeze_lanes(sha3_ctx* h, int* st, int* offp, char* out, int n):
	int off = *offp
	for i in range(n):
		if (off == h.rate):
			keccak_f(st, h.w)
			off = 0
		out[i] = keccak_get_byte(st, off)
		off = off + 1
	*offp = off


# Non-destructive output of n bytes over a padded copy of the state.
void sha3_output(sha3_ctx* h, char* out, int n):
	int* st = cast(int*, malloc(50 * __word_size__))
	mem_copy(st, h.w, 50)
	sha3_pad(h, st, h.pos)
	int off = 0
	sha3_squeeze_lanes(h, st, &off, out, n)
	free(st)


# Write the digest of everything absorbed so far to out (digest_size
# bytes; for SHAKE the nominal 32 / 64). The context keeps absorbing.
void sha3_final(sha3_ctx* h, char* out):
	sha3_output(h, out, h.digest_size)


# SHAKE: write n bytes of output for everything absorbed so far. Like
# sha3_final it leaves the context absorbing; any n >= 0 is allowed, and
# shorter outputs are prefixes of longer ones.
void shake_final(sha3_ctx* h, char* out, int n):
	if (n <= 0): return
	sha3_output(h, out, n)


# SHAKE: read the next n bytes of the output stream. The first call
# finishes absorption; later calls continue the same stream, so reading
# 10 then 90 bytes yields the same 100 bytes as shake_final(h, out, 100).
void shake_squeeze(sha3_ctx* h, char* out, int n):
	if (h.squeezing == 0):
		sha3_pad(h, h.w, h.pos)
		h.squeezing = 1
		h.pos = 0
	if (n <= 0): return
	int off = h.pos
	sha3_squeeze_lanes(h, h.w, &off, out, n)
	h.pos = off


/* One-shot helpers */


# Digest of len bytes at data into out (sha3_digest_size(alg) bytes).
# Returns 0 on success, -1 for an unknown alg.
int sha3_oneshot(int alg, char* data, int len, char* out):
	sha3_ctx* h = sha3_new(alg)
	if (h == 0): return -1
	sha3_update(h, data, len)
	sha3_final(h, out)
	sha3_free(h)
	return 0


# n bytes of SHAKE output for len bytes at data. Returns 0 on success, -1
# when alg is not SHAKE_128 / SHAKE_256.
int shake_oneshot(int alg, char* data, int len, char* out, int n):
	if (!sha3_is_xof(alg)): return -1
	sha3_ctx* h = sha3_new(alg)
	sha3_update(h, data, len)
	shake_final(h, out, n)
	sha3_free(h)
	return 0


void sha3_224(char* data, int len, char* out):
	sha3_oneshot(SHA3_224, data, len, out)


void sha3_256(char* data, int len, char* out):
	sha3_oneshot(SHA3_256, data, len, out)


void sha3_384(char* data, int len, char* out):
	sha3_oneshot(SHA3_384, data, len, out)


void sha3_512(char* data, int len, char* out):
	sha3_oneshot(SHA3_512, data, len, out)


void shake128(char* data, int len, char* out, int n):
	shake_oneshot(SHAKE_128, data, len, out, n)


void shake256(char* data, int len, char* out, int n):
	shake_oneshot(SHAKE_256, data, len, out, n)


# Malloc'd raw digest (sha3_digest_size(alg) bytes), or 0 for an unknown
# alg.
char* sha3_digest(int alg, char* data, int len):
	int ds = sha3_digest_size(alg)
	if (ds == 0): return cast(char*, 0)
	char* out = cast(char*, malloc(ds))
	sha3_oneshot(alg, data, len, out)
	return out


# Malloc'd lowercase hex digest, or 0 for an unknown alg.
char* sha3_hexdigest(int alg, char* data, int len):
	char* raw = sha3_digest(alg, data, len)
	if (raw == 0): return cast(char*, 0)
	char* hex = hex_encode(raw, sha3_digest_size(alg))
	free(raw)
	return hex


# Malloc'd n bytes of SHAKE output (at least one byte is allocated, so
# n == 0 returns an empty buffer), or 0 for a non-SHAKE alg or n < 0.
char* shake_digest(int alg, char* data, int len, int n):
	if ((!sha3_is_xof(alg)) || (n < 0)): return cast(char*, 0)
	char* out = cast(char*, malloc(n + 1))
	shake_oneshot(alg, data, len, out, n)
	out[n] = 0
	return out


# Malloc'd 2n-character hex of n SHAKE output bytes, or 0 for a non-SHAKE
# alg or n < 0.
char* shake_hexdigest(int alg, char* data, int len, int n):
	char* raw = shake_digest(alg, data, len, n)
	if (raw == 0): return cast(char*, 0)
	char* hex = hex_encode(raw, n)
	free(raw)
	return hex
