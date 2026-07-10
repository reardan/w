/*
libs/x/unsafe: MD5 (RFC 1321).

*** BROKEN FOR SECURITY PURPOSES — INTEROP/LEGACY USE ONLY. ***
MD5 collisions are practical on commodity hardware; nothing that relies
on collision or preimage resistance may use it. Do not reach for this
module in new designs — it exists solely to interoperate with legacy
formats and protocols that still speak MD5 (old checksum files,
HMAC-MD5 in legacy authentication). No side-channel or constant-time
guarantees are made.

Plugs into the whash streaming interface of libs/standard/crypto/sha2.w
via whash_register, so libs/standard/crypto/hmac.w composes for legacy
HMAC-MD5 without anything under libs/standard importing this quarantine
namespace:

	whash* h = whash_new(WHASH_MD5())
	whash_update(h, data, len)        # any number of times
	whash_final(h, out)               # 16 bytes; non-destructive
	whash_free(h)

or one-shot: md5(data, len, out). WHASH_MD5() registers the algorithm on
first use, so passing it to hmac_new/whash_oneshot just works.

32-bit portability follows lib/sha256.w: no integer literal with bit 31
set appears in the source (the sine-derived T table and the initial
state are hex text parsed at first use), every 32-bit word is observed
only through its low 32 bits, and right shifts go through sha256_shr.
*/
import lib.memory
import lib.sha256
import libs.standard.crypto.sha2


# whash extension id for MD5 (extension ids start at 100; see the
# registry in libs/standard/crypto/sha2.w).
int md5_alg_id():
	return 100


int* md5_t_cache


# The 64 sine-derived round constants T[i] = floor(2^32 * abs(sin(i+1)))
# (RFC 1321 section 3.4), parsed from hex text so no literal carries
# bit 31.
int* md5_t_table():
	if (md5_t_cache == 0):
		md5_t_cache = sha2_parse_words(c"d76aa478e8c7b756242070dbc1bdceeef57c0faf4787c62aa8304613fd469501698098d88b44f7afffff5bb1895cd7be6b901122fd987193a679438e49b40821f61e2562c040b340265e5a51e9b6c7aad62f105d02441453d8a1e681e7d3fbc821e1cde6c33707d6f4d50d87455a14eda9e3e905fcefa3f8676f02d98d2a4c8afffa39428771f6816d9d6122fde5380ca4beea444bdecfa9f6bb4b60bebfbc70289b7ec6eaa127fad4ef308504881d05d9d4d039e6db99e51fa27cf8c4ac5665f4292244432aff97ab9423a7fc93a039655b59c38f0ccc92ffeff47d85845dd16fa87e4ffe2ce6e0a30143144e0811a1f7537e82bd3af2352ad7d2bbeb86d391", 64)
	return md5_t_cache


int* md5_iv_cache


# Initial state A, B, C, D (RFC 1321 section 3.3), as word values.
int* md5_iv_table():
	if (md5_iv_cache == 0):
		md5_iv_cache = sha2_parse_words(c"67452301efcdab8998badcfe10325476", 4)
	return md5_iv_cache


# Left-rotation amounts: row r holds the four counts cycled through by
# round r (RFC 1321 section 3.4).
char* md5_s_table():
	return c"\x07\x0c\x11\x16\x05\x09\x0e\x14\x04\x0b\x10\x17\x06\x0a\x0f\x15"


# Little-endian load of a 32-bit word, masked per lib/sha256.w.
int md5_le32(char* p):
	return ((p[0] & 255) | ((p[1] & 255) << 8) | ((p[2] & 255) << 16) | ((p[3] & 255) << 24)) & sha256_mask32()


# Rotate a 32-bit word left by n (1 <= n <= 31).
int md5_rotl(int x, int n):
	return ((x << n) | sha256_shr(x, 32 - n)) & sha256_mask32()


# Round function for step i: F, G, H, I (RFC 1321 section 3.4). F and G
# are choose functions, so lib/sha256.w's ch applies; H is parity; I is
# c xor (b or not d).
int md5_round_f(int i, int b, int c, int d):
	if (i < 16):
		return sha256_ch(b, c, d)
	if (i < 32):
		return sha256_ch(d, b, c)
	if (i < 48):
		return (b ^ c ^ d) & sha256_mask32()
	int mask = sha256_mask32()
	int not_d = mask - (d & mask)
	return (c ^ (b | not_d)) & mask


# Message word index for step i (RFC 1321 section 3.4).
int md5_round_g(int i):
	if (i < 16):
		return i
	if (i < 32):
		return (i * 5 + 1) & 15
	if (i < 48):
		return (i * 3 + 5) & 15
	return (i * 7) & 15


# Compress one 64-byte block into the four-word state (RFC 1321
# section 3.4).
void md5_block(int* state, char* block):
	int mask = sha256_mask32()
	int* t = md5_t_table()
	char* s = md5_s_table()
	int* m = cast(int*, malloc(16 * __word_size__))
	int i = 0
	while (i < 16):
		m[i] = md5_le32(block + i * 4)
		i = i + 1

	int a = state[0]
	int b = state[1]
	int c = state[2]
	int d = state[3]

	i = 0
	while (i < 64):
		int f = (md5_round_f(i, b, c, d) + a + t[i] + m[md5_round_g(i)]) & mask
		a = d
		d = c
		c = b
		b = (b + md5_rotl(f, s[(i >> 4) * 4 + (i & 3)] & 255)) & mask
		i = i + 1

	state[0] = (state[0] + a) & mask
	state[1] = (state[1] + b) & mask
	state[2] = (state[2] + c) & mask
	state[3] = (state[3] + d) & mask
	free(m)


# whash_iv_fn: load the initial state.
void md5_load_iv(int* state):
	int* iv = md5_iv_table()
	state[0] = iv[0]
	state[1] = iv[1]
	state[2] = iv[2]
	state[3] = iv[3]


# whash algorithm descriptor: registers MD5 with the whash dispatcher on
# first use (16-byte digest, 64-byte block, 4 state words, little-endian
# trailer and output) and returns its id.
int WHASH_MD5():
	whash_register(md5_alg_id(), 16, 64, 4, 1, md5_block, md5_load_iv)
	return md5_alg_id()


# One-shot MD5: digest of len bytes at data into out (16 bytes).
void md5(char* data, int len, char* out):
	whash_oneshot(WHASH_MD5(), data, len, out)
