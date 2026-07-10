/*
libs/x/unsafe: SHA-1 (RFC 3174 / FIPS 180-4).

*** BROKEN FOR SECURITY PURPOSES — INTEROP/LEGACY USE ONLY. ***
SHA-1 collisions are practical (SHAttered, chosen-prefix attacks);
nothing that relies on collision resistance may use it, and new designs
must not use it at all. It exists solely to interoperate with formats
and protocols that still require SHA-1: git object ids, legacy
HMAC-SHA1 authentication, old certificate fingerprints. No side-channel
or constant-time guarantees are made.

Plugs into the whash streaming interface of libs/standard/crypto/sha2.w
via whash_register, so libs/standard/crypto/hmac.w composes for legacy
HMAC-SHA1 without anything under libs/standard importing this
quarantine namespace:

	whash* h = whash_new(WHASH_SHA1())
	whash_update(h, data, len)        # any number of times
	whash_final(h, out)               # 20 bytes; non-destructive
	whash_free(h)

or one-shot: sha1(data, len, out). WHASH_SHA1() registers the algorithm
on first use, so passing it to hmac_new/whash_oneshot just works.

32-bit portability follows lib/sha256.w: no integer literal with bit 31
set appears in the source (the K constants and initial state are hex
text parsed at first use), every 32-bit word is observed only through
its low 32 bits, and right shifts go through sha256_shr.
*/
import lib.memory
import lib.sha256
import libs.standard.crypto.sha2


# whash extension id for SHA-1 (extension ids start at 100; see the
# registry in libs/standard/crypto/sha2.w).
int sha1_alg_id():
	return 101


int* sha1_k_cache


# The four round constants K (FIPS 180-4 section 4.2.1), parsed from hex
# text so no literal carries bit 31.
int* sha1_k_table():
	if (sha1_k_cache == 0):
		sha1_k_cache = sha2_parse_words(c"5a8279996ed9eba18f1bbcdcca62c1d6", 4)
	return sha1_k_cache


int* sha1_iv_cache


# Initial hash value H0..H4 (FIPS 180-4 section 5.3.1).
int* sha1_iv_table():
	if (sha1_iv_cache == 0):
		sha1_iv_cache = sha2_parse_words(c"67452301efcdab8998badcfe10325476c3d2e1f0", 5)
	return sha1_iv_cache


# Rotate a 32-bit word left by n (1 <= n <= 31).
int sha1_rotl(int x, int n):
	return ((x << n) | sha256_shr(x, 32 - n)) & sha256_mask32()


# f_t for round i (FIPS 180-4 section 4.1.1): Ch, Parity, Maj, Parity —
# lib/sha256.w's ch and maj apply directly.
int sha1_round_f(int i, int b, int c, int d):
	if (i < 20):
		return sha256_ch(b, c, d)
	if ((i >= 40) && (i < 60)):
		return sha256_maj(b, c, d)
	return (b ^ c ^ d) & sha256_mask32()


# K_t for round i.
int sha1_round_k(int i, int* k):
	if (i < 20):
		return k[0]
	if (i < 40):
		return k[1]
	if (i < 60):
		return k[2]
	return k[3]


# Compress one 64-byte block into the five-word state (FIPS 180-4
# section 6.1.2).
void sha1_block(int* state, char* block):
	int mask = sha256_mask32()
	int* k = sha1_k_table()
	int* w = cast(int*, malloc(80 * __word_size__))
	int i = 0
	while (i < 16):
		w[i] = sha256_be32(block + i * 4)
		i = i + 1
	while (i < 80):
		w[i] = sha1_rotl((w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]) & mask, 1)
		i = i + 1

	int a = state[0]
	int b = state[1]
	int c = state[2]
	int d = state[3]
	int e = state[4]

	i = 0
	while (i < 80):
		int t = (sha1_rotl(a, 5) + sha1_round_f(i, b, c, d) + e + sha1_round_k(i, k) + w[i]) & mask
		e = d
		d = c
		c = sha1_rotl(b, 30)
		b = a
		a = t
		i = i + 1

	state[0] = (state[0] + a) & mask
	state[1] = (state[1] + b) & mask
	state[2] = (state[2] + c) & mask
	state[3] = (state[3] + d) & mask
	state[4] = (state[4] + e) & mask
	free(w)


# whash_iv_fn: load the initial state.
void sha1_load_iv(int* state):
	int* iv = sha1_iv_table()
	int i = 0
	while (i < 5):
		state[i] = iv[i]
		i = i + 1


# whash algorithm descriptor: registers SHA-1 with the whash dispatcher
# on first use (20-byte digest, 64-byte block, 5 state words, big-endian
# like the rest of the SHA family) and returns its id.
int WHASH_SHA1():
	whash_register(sha1_alg_id(), 20, 64, 5, 0, sha1_block, sha1_load_iv)
	return sha1_alg_id()


# One-shot SHA-1: digest of len bytes at data into out (20 bytes).
void sha1(char* data, int len, char* out):
	whash_oneshot(WHASH_SHA1(), data, len, out)
