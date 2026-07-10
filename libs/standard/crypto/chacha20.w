/*
ChaCha20 stream cipher (RFC 8439 section 2.1-2.4), pure W.

Part of the native HTTPS stack (issue #155, plan
libs/standard/plans/11_native_http_tls.md phase 4). Provides the block
function and stream encryption used by the ChaCha20-Poly1305 AEAD in
libs/standard/crypto/chacha20poly1305.w.

32-bit portability: `int` is word-sized (32-bit on the x86 target, 64-bit
on x64), so every 32-bit word is kept masked to its low 32 bits with
chacha20_mask32() and right shifts go through chacha20_shr(), which strips
the sign bits an arithmetic >> would smear in on a 32-bit host (the same
discipline as lib/sha256.w). Addition may wrap through the sign bit on the
32-bit host; only the low 32 bits are ever observed.

Constant-time discipline: the round structure is fixed, rotation counts are
constants, and no branch or memory index ever depends on key, nonce, or
keystream material.
*/
import lib.memory


int chacha20_mask32():
	int h = 1 << 16
	return h * h - 1


# Logical shift right of a 32-bit word: mask away the (arithmetic) sign
# copies a 32-bit host would shift in from bit 31.
int chacha20_shr(int x, int n):
	return (x >> n) & ((1 << (32 - n)) - 1)


# Rotate a 32-bit word left by n (1 <= n <= 31).
int chacha20_rotl(int x, int n):
	return ((x << n) | chacha20_shr(x, 32 - n)) & chacha20_mask32()


int chacha20_le32(char* p):
	return ((p[0] & 255) | ((p[1] & 255) << 8) | ((p[2] & 255) << 16) | ((p[3] & 255) << 24)) & chacha20_mask32()


void chacha20_put_le32(char* p, int v):
	p[0] = v & 255
	p[1] = (v >> 8) & 255
	p[2] = (v >> 16) & 255
	p[3] = (v >> 24) & 255


# One quarter round on state words a, b, c, d (indices are compile-time
# constants at every call site, never data).
void chacha20_quarter(int* x, int a, int b, int c, int d):
	int mask = chacha20_mask32()
	x[a] = (x[a] + x[b]) & mask
	x[d] = chacha20_rotl(x[d] ^ x[a], 16)
	x[c] = (x[c] + x[d]) & mask
	x[b] = chacha20_rotl(x[b] ^ x[c], 12)
	x[a] = (x[a] + x[b]) & mask
	x[d] = chacha20_rotl(x[d] ^ x[a], 8)
	x[c] = (x[c] + x[d]) & mask
	x[b] = chacha20_rotl(x[b] ^ x[c], 7)


# Fill the 16-word ChaCha state: constants, 256-bit key (8 little-endian
# words), 32-bit block counter, 96-bit nonce (3 little-endian words).
void chacha20_init_state(int* s, char* key, int counter, char* nonce):
	s[0] = 0x61707865
	s[1] = 0x3320646e
	s[2] = 0x79622d32
	s[3] = 0x6b206574
	int i = 0
	while (i < 8):
		s[4 + i] = chacha20_le32(key + i * 4)
		i = i + 1
	s[12] = counter & chacha20_mask32()
	s[13] = chacha20_le32(nonce)
	s[14] = chacha20_le32(nonce + 4)
	s[15] = chacha20_le32(nonce + 8)


# Run 20 rounds over a copy of state s (using w as scratch), add the
# original state back in, and serialize the 64-byte keystream block.
void chacha20_core(int* s, int* w, char* out):
	int mask = chacha20_mask32()
	int i = 0
	while (i < 16):
		w[i] = s[i]
		i = i + 1
	i = 0
	while (i < 10):
		chacha20_quarter(w, 0, 4, 8, 12)
		chacha20_quarter(w, 1, 5, 9, 13)
		chacha20_quarter(w, 2, 6, 10, 14)
		chacha20_quarter(w, 3, 7, 11, 15)
		chacha20_quarter(w, 0, 5, 10, 15)
		chacha20_quarter(w, 1, 6, 11, 12)
		chacha20_quarter(w, 2, 7, 8, 13)
		chacha20_quarter(w, 3, 4, 9, 14)
		i = i + 1
	i = 0
	while (i < 16):
		chacha20_put_le32(out + i * 4, (w[i] + s[i]) & mask)
		i = i + 1


# The ChaCha20 block function (RFC 8439 section 2.3): 32-byte key, block
# counter, 12-byte nonce -> 64 keystream bytes written to out.
void chacha20_block(char* key, int counter, char* nonce, char* out):
	int* s = cast(int*, malloc(16 * __word_size__))
	int* w = cast(int*, malloc(16 * __word_size__))
	chacha20_init_state(s, key, counter, nonce)
	chacha20_core(s, w, out)
	free(w)
	free(s)


# Encrypt (or, identically, decrypt) `len` bytes at `data` into `out` by
# XOR with the ChaCha20 keystream (RFC 8439 section 2.4). The counter names
# the first 64-byte block and increments per block. `out` may alias `data`
# for in-place operation.
void chacha20_xor(char* key, int counter, char* nonce, char* data, int len, char* out):
	int* s = cast(int*, malloc(16 * __word_size__))
	int* w = cast(int*, malloc(16 * __word_size__))
	char* ks = malloc(64)
	chacha20_init_state(s, key, counter, nonce)
	int off = 0
	int i = 0
	while (off < len):
		chacha20_core(s, w, ks)
		s[12] = (s[12] + 1) & chacha20_mask32()
		int n = len - off
		if (n > 64):
			n = 64
		i = 0
		while (i < n):
			out[off + i] = (data[off + i] ^ ks[i]) & 255
			i = i + 1
		off = off + 64
	# Keystream bytes are secret; scrub before returning the buffer.
	i = 0
	while (i < 64):
		ks[i] = 0
		i = i + 1
	free(ks)
	free(w)
	free(s)
