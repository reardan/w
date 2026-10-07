/* C twin of tests/bench/sha256_1m.w (see bench.h): a port of lib/sha256.w
 * with uint32_t words (the masks the W code needs for width independence
 * are the type here). Same block loop, same schedule, same padding. */
#include "bench.h"

static const uint32_t sha256_k[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

static const uint32_t sha256_h0[8] = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
};

static void sha256_put_be32(unsigned char* p, uint32_t v) {
	p[0] = (v >> 24) & 255;
	p[1] = (v >> 16) & 255;
	p[2] = (v >> 8) & 255;
	p[3] = v & 255;
}

/* sha256_block_w: compress one 64-byte block into h[0..7] using w as the
 * message schedule. The rotations are written out inline like the W. */
static void sha256_block_w(uint32_t* h, const unsigned char* block, uint32_t* w) {
	const uint32_t* k = sha256_k;
	word i = 0;
	while (i < 16) {
		const unsigned char* p = block + i * 4;
		w[i] = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
		i = i + 1;
	}
	while (i < 64) {
		uint32_t x = w[i - 15];
		uint32_t s0 = ((x >> 7) | (x << 25)) ^ ((x >> 18) | (x << 14)) ^ (x >> 3);
		uint32_t y = w[i - 2];
		uint32_t s1 = ((y >> 17) | (y << 15)) ^ ((y >> 19) | (y << 13)) ^ (y >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
		i = i + 1;
	}

	uint32_t a = h[0];
	uint32_t b = h[1];
	uint32_t c = h[2];
	uint32_t d = h[3];
	uint32_t e = h[4];
	uint32_t f = h[5];
	uint32_t g = h[6];
	uint32_t hh = h[7];

	i = 0;
	while (i < 64) {
		uint32_t bs1 = ((e >> 6) | (e << 26)) ^ ((e >> 11) | (e << 21)) ^ ((e >> 25) | (e << 7));
		uint32_t ch = (e & f) ^ ((~e) & g);
		uint32_t t1 = hh + bs1 + ch + k[i] + w[i];
		uint32_t bs0 = ((a >> 2) | (a << 30)) ^ ((a >> 13) | (a << 19)) ^ ((a >> 22) | (a << 10));
		uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
		uint32_t t2 = bs0 + maj;
		hh = g;
		g = f;
		f = e;
		e = d + t1;
		d = c;
		c = b;
		b = a;
		a = t1 + t2;
		i = i + 1;
	}

	h[0] += a;
	h[1] += b;
	h[2] += c;
	h[3] += d;
	h[4] += e;
	h[5] += f;
	h[6] += g;
	h[7] += hh;
}

static void sha256(const unsigned char* data, word len, unsigned char* out) {
	uint32_t h[8];
	word i = 0;
	while (i < 8) {
		h[i] = sha256_h0[i];
		i = i + 1;
	}
	uint32_t* w = malloc(64 * sizeof(uint32_t));
	word full = len / 64;
	i = 0;
	while (i < full) {
		sha256_block_w(h, data + i * 64, w);
		i = i + 1;
	}
	word rem = len - full * 64;
	unsigned char tail[128];
	memset(tail, 0, 128);
	word j = 0;
	while (j < rem) {
		tail[j] = data[full * 64 + j];
		j = j + 1;
	}
	tail[rem] = 128;
	word blocks = 1;
	if (rem >= 56) blocks = 2;
	word bitlen_pos = blocks * 64 - 8;
	sha256_put_be32(tail + bitlen_pos, (uint32_t)((uword)len >> 29));
	sha256_put_be32(tail + bitlen_pos + 4, (uint32_t)((uword)len << 3));
	sha256_block_w(h, tail, w);
	if (blocks == 2) sha256_block_w(h, tail + 64, w);
	free(w);
	i = 0;
	while (i < 8) {
		sha256_put_be32(out + i * 4, h[i]);
		i = i + 1;
	}
}

int main(int argc, char** argv) {
	word mb = bench_size(argc, argv, 16);
	word len = mb * 1048576;
	unsigned char* data = malloc((size_t)len);
	uint32_t state = 123456789;
	word i = 0;
	while (i < len) {
		data[i] = bench_rand(&state) & 255;
		i = i + 1;
	}
	unsigned char digest[32];
	sha256(data, len, digest);
	char hex[65];
	const char* digits = "0123456789abcdef";
	i = 0;
	while (i < 32) {
		hex[i * 2] = digits[(digest[i] >> 4) & 15];
		hex[i * 2 + 1] = digits[digest[i] & 15];
		i = i + 1;
	}
	hex[64] = 0;
	printf("sha256_1m size=%ld checksum=%s\n", (long)mb, hex);
	return 0;
}
