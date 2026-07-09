/*
SHA-256 (FIPS 180-4), pure W. Written for the Mach-O ad-hoc code-signing
writer (code_generator/macho_sign.w), which hashes each code page and the
requirements blob into a CodeDirectory; also usable anywhere a content
hash is wanted (e.g. replacing the rolling hash in tools/wexec.w).

Two host-portability rules shape the code, because this module is compiled
into the seed-built compiler and must stay fixpoint-identical whether the
compiler runs as a 32- or 64-bit process:

  1. No integer literal with bit 31 set ever appears in the source. Such a
     literal parses positive on a 64-bit host and negative on the 32-bit
     seed, and the arm64 backend spills it into an 8-byte pool where the two
     differ — breaking verify_arm64. The round constants and initial hash
     therefore live in big-endian byte blobs read with sha256_be32, and the
     0xffffffff mask is built at runtime (sha256_mask32).
  2. Every 32-bit word is kept masked, and the right shift is done through
     sha256_shr, which masks off the sign bits an arithmetic >> would smear
     in on a 32-bit host. So a "32-bit word" may be stored as a negative int
     on the 32-bit host, but only its low 32 bits are ever observed.

xor is (a | b) - (a & b): the AND is a subset of the OR, so the subtraction
never borrows and yields the bitwise xor in two's complement on either host.
*/
import lib.memory
import code_generator.integer


int sha256_mask32():
	int h = 1 << 16
	return h * h - 1


int sha256_be32(char* p):
	return ((p[0] & 255) << 24) | ((p[1] & 255) << 16) | ((p[2] & 255) << 8) | (p[3] & 255)


void sha256_put_be32(char* p, int v):
	p[0] = (v >> 24) & 255
	p[1] = (v >> 16) & 255
	p[2] = (v >> 8) & 255
	p[3] = v & 255


int sha256_xor(int a, int b):
	return (a | b) - (a & b)


# Logical shift right of a 32-bit word: mask away the (arithmetic) sign
# copies a 32-bit host would shift in from bit 31.
int sha256_shr(int x, int n):
	return (x >> n) & ((1 << (32 - n)) - 1)


int sha256_rotr(int x, int n):
	return (sha256_shr(x, n) | (x << (32 - n))) & sha256_mask32()


# The 64 round constants (cube roots of the first 64 primes), big-endian.
char* sha256_k_table():
	return c"\x42\x8a\x2f\x98\x71\x37\x44\x91\xb5\xc0\xfb\xcf\xe9\xb5\xdb\xa5\x39\x56\xc2\x5b\x59\xf1\x11\xf1\x92\x3f\x82\xa4\xab\x1c\x5e\xd5\xd8\x07\xaa\x98\x12\x83\x5b\x01\x24\x31\x85\xbe\x55\x0c\x7d\xc3\x72\xbe\x5d\x74\x80\xde\xb1\xfe\x9b\xdc\x06\xa7\xc1\x9b\xf1\x74\xe4\x9b\x69\xc1\xef\xbe\x47\x86\x0f\xc1\x9d\xc6\x24\x0c\xa1\xcc\x2d\xe9\x2c\x6f\x4a\x74\x84\xaa\x5c\xb0\xa9\xdc\x76\xf9\x88\xda\x98\x3e\x51\x52\xa8\x31\xc6\x6d\xb0\x03\x27\xc8\xbf\x59\x7f\xc7\xc6\xe0\x0b\xf3\xd5\xa7\x91\x47\x06\xca\x63\x51\x14\x29\x29\x67\x27\xb7\x0a\x85\x2e\x1b\x21\x38\x4d\x2c\x6d\xfc\x53\x38\x0d\x13\x65\x0a\x73\x54\x76\x6a\x0a\xbb\x81\xc2\xc9\x2e\x92\x72\x2c\x85\xa2\xbf\xe8\xa1\xa8\x1a\x66\x4b\xc2\x4b\x8b\x70\xc7\x6c\x51\xa3\xd1\x92\xe8\x19\xd6\x99\x06\x24\xf4\x0e\x35\x85\x10\x6a\xa0\x70\x19\xa4\xc1\x16\x1e\x37\x6c\x08\x27\x48\x77\x4c\x34\xb0\xbc\xb5\x39\x1c\x0c\xb3\x4e\xd8\xaa\x4a\x5b\x9c\xca\x4f\x68\x2e\x6f\xf3\x74\x8f\x82\xee\x78\xa5\x63\x6f\x84\xc8\x78\x14\x8c\xc7\x02\x08\x90\xbe\xff\xfa\xa4\x50\x6c\xeb\xbe\xf9\xa3\xf7\xc6\x71\x78\xf2"


# Initial hash values (square roots of the first 8 primes), big-endian.
char* sha256_h0_table():
	return c"\x6a\x09\xe6\x67\xbb\x67\xae\x85\x3c\x6e\xf3\x72\xa5\x4f\xf5\x3a\x51\x0e\x52\x7f\x9b\x05\x68\x8c\x1f\x83\xd9\xab\x5b\xe0\xcd\x19"


int sha256_ch(int e, int f, int g):
	int not_e = sha256_mask32() - (e & sha256_mask32())
	return sha256_xor(e & f, not_e & g)


int sha256_maj(int a, int b, int c):
	return sha256_xor(sha256_xor(a & b, a & c), b & c)


int sha256_big_sigma0(int a):
	return sha256_xor(sha256_xor(sha256_rotr(a, 2), sha256_rotr(a, 13)), sha256_rotr(a, 22))


int sha256_big_sigma1(int e):
	return sha256_xor(sha256_xor(sha256_rotr(e, 6), sha256_rotr(e, 11)), sha256_rotr(e, 25))


int sha256_small_sigma0(int x):
	return sha256_xor(sha256_xor(sha256_rotr(x, 7), sha256_rotr(x, 18)), sha256_shr(x, 3))


int sha256_small_sigma1(int x):
	return sha256_xor(sha256_xor(sha256_rotr(x, 17), sha256_rotr(x, 19)), sha256_shr(x, 10))


# Compress one 64-byte block into the eight-word state h[0..7].
void sha256_block(int* h, char* block):
	char* k = sha256_k_table()
	int* w = cast(int*, malloc(64 * __word_size__))
	int mask = sha256_mask32()

	int i = 0
	while (i < 16):
		w[i] = sha256_be32(block + i * 4)
		i = i + 1
	while (i < 64):
		int s0 = sha256_small_sigma0(w[i - 15])
		int s1 = sha256_small_sigma1(w[i - 2])
		w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & mask
		i = i + 1

	int a = h[0]
	int b = h[1]
	int c = h[2]
	int d = h[3]
	int e = h[4]
	int f = h[5]
	int g = h[6]
	int hh = h[7]

	i = 0
	while (i < 64):
		int t1 = (hh + sha256_big_sigma1(e) + sha256_ch(e, f, g) + sha256_be32(k + i * 4) + w[i]) & mask
		int t2 = (sha256_big_sigma0(a) + sha256_maj(a, b, c)) & mask
		hh = g
		g = f
		f = e
		e = (d + t1) & mask
		d = c
		c = b
		b = a
		a = (t1 + t2) & mask
		i = i + 1

	h[0] = (h[0] + a) & mask
	h[1] = (h[1] + b) & mask
	h[2] = (h[2] + c) & mask
	h[3] = (h[3] + d) & mask
	h[4] = (h[4] + e) & mask
	h[5] = (h[5] + f) & mask
	h[6] = (h[6] + g) & mask
	h[7] = (h[7] + hh) & mask
	free(w)


# Hash `len` bytes at `data`, writing 32 raw digest bytes to `out`.
void sha256(char* data, int len, char* out):
	char* h0 = sha256_h0_table()
	int* h = cast(int*, malloc(8 * __word_size__))
	int i = 0
	while (i < 8):
		h[i] = sha256_be32(h0 + i * 4)
		i = i + 1

	int full = len / 64
	i = 0
	while (i < full):
		sha256_block(h, data + i * 64)
		i = i + 1

	# Final block(s): the remaining bytes, a 0x80 terminator, zero padding
	# and the 64-bit big-endian bit length, rounded to 64 bytes (two blocks
	# when the remainder leaves no room for the length field).
	int rem = len - full * 64
	char* tail = malloc(128)
	int j = 0
	while (j < 128):
		tail[j] = 0
		j = j + 1
	j = 0
	while (j < rem):
		tail[j] = data[full * 64 + j]
		j = j + 1
	tail[rem] = 128 /* 0x80 */

	int blocks = 1
	if (rem >= 56):
		blocks = 2
	int bitlen_pos = blocks * 64 - 8
	# bit length = len * 8, as a 64-bit big-endian value.
	sha256_put_be32(tail + bitlen_pos, (len >> 29) & sha256_mask32())
	sha256_put_be32(tail + bitlen_pos + 4, (len << 3) & sha256_mask32())

	sha256_block(h, tail)
	if (blocks == 2):
		sha256_block(h, tail + 64)
	free(tail)

	i = 0
	while (i < 8):
		sha256_put_be32(out + i * 4, h[i])
		i = i + 1
	free(h)
