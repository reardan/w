/*
Poly1305 one-time authenticator (RFC 8439 section 2.5), pure W.

Part of the native HTTPS stack (issue #155, plan
libs/standard/plans/11_native_http_tls.md phase 4). The 32-byte key is
(r, s); the tag is ((m(r) mod 2^130-5) + s) mod 2^128 over the message
interpreted as 16-byte little-endian blocks, each padded with a high 0x01
byte.

32-bit portability (the "13-bit half-limb" scheme): `int` is only
guaranteed 32 bits (signed) on the x86 target, so the 130-bit accumulator
and clamped r are held in ten 13-bit limbs (10 * 13 = 130 exactly), the
radix-2^13 layout of poly1305-donna-16. Every value in this file is a
non-negative int, and the worst case is proven below to stay under
2^31 - 1, so the same code is exact on 32- and 64-bit hosts with no int64
and no masking tricks:

  - r limbs are at most 2^13 - 1 = 8191 (clamping only clears bits), so
    the reduction multiples 5*r[j] are at most 40955 < 2^16.
  - Between blocks the accumulator limbs satisfy h[0] <= 8191,
    h[1] <= 8831, h[2..9] <= 8191 (see the carry analysis in
    poly1305_block), so after adding a message limb (<= 8191, and the
    2^128 pad bit is inside limb 9's 13 bits) every h[j] <= 17022 < 2^15.
  - A single product h[j] * 5*r[k] is therefore at most
    17022 * 40955 = 697,136,010 < 2^30.
  - The row sum for one output limb folds its carry out every three
    products, so a partial sum never exceeds
    carry_in + 3 * 697,136,010 <= 2^20 + 2,091,408,030 = 2,092,456,606,
    which is below 2^31 - 1 = 2,147,483,647.

Because 10 * 13 = 130, the wrap of limb 10 back to limb 0 is a clean
multiply by 5 (2^130 = 5 mod 2^130 - 5) with no shift residue.

Constant-time discipline: all loop bounds and branch conditions depend
only on loop indices and the (public) message length; no branch or memory
index ever depends on the key, the accumulator, or message bytes.
*/
import lib.memory


struct poly1305:
	int* r     # clamped r, ten 13-bit limbs
	int* r5    # 5 * r[j], precomputed reduction multiples
	int* h     # accumulator, ten 13-bit limbs (bounded as above)
	int* pad   # s, eight 16-bit little-endian words
	int* ml    # scratch: message-block limbs
	int* t     # scratch: product row outputs
	char* buffer   # partial trailing block
	int buffered


# Split a 16-byte little-endian block into ten 13-bit limbs. hibit is the
# 2^128 pad bit as seen from limb 9 (1 << 11 for a full block, 0 when the
# 0x01 byte is already in the buffer of a short final block).
void poly1305_limbs(char* m, int hibit, int* out):
	int b0 = m[0] & 255
	int b1 = m[1] & 255
	int b2 = m[2] & 255
	int b3 = m[3] & 255
	int b4 = m[4] & 255
	int b5 = m[5] & 255
	int b6 = m[6] & 255
	int b7 = m[7] & 255
	int b8 = m[8] & 255
	int b9 = m[9] & 255
	int b10 = m[10] & 255
	int b11 = m[11] & 255
	int b12 = m[12] & 255
	int b13 = m[13] & 255
	int b14 = m[14] & 255
	int b15 = m[15] & 255
	out[0] = (b0 | (b1 << 8)) & 0x1fff
	out[1] = ((b1 >> 5) | (b2 << 3) | (b3 << 11)) & 0x1fff
	out[2] = ((b3 >> 2) | (b4 << 6)) & 0x1fff
	out[3] = ((b4 >> 7) | (b5 << 1) | (b6 << 9)) & 0x1fff
	out[4] = ((b6 >> 4) | (b7 << 4) | (b8 << 12)) & 0x1fff
	out[5] = ((b8 >> 1) | (b9 << 7)) & 0x1fff
	out[6] = ((b9 >> 6) | (b10 << 2) | (b11 << 10)) & 0x1fff
	out[7] = ((b11 >> 3) | (b12 << 5)) & 0x1fff
	out[8] = (b13 | (b14 << 8)) & 0x1fff
	out[9] = ((b14 >> 5) | (b15 << 3) | hibit) & 0x1fff


# Start a MAC with a 32-byte one-time key: r = key[0..15] clamped
# (RFC 8439 section 2.5: clear the top 4 bits of bytes 3/7/11/15 and the
# bottom 2 bits of bytes 4/8/12), s = key[16..31].
poly1305* poly1305_new(char* key):
	poly1305* st = new poly1305()
	st.r = cast(int*, malloc(10 * __word_size__))
	st.r5 = cast(int*, malloc(10 * __word_size__))
	st.h = cast(int*, malloc(10 * __word_size__))
	st.pad = cast(int*, malloc(8 * __word_size__))
	st.ml = cast(int*, malloc(10 * __word_size__))
	st.t = cast(int*, malloc(10 * __word_size__))
	st.buffer = malloc(16)
	st.buffered = 0

	char* rb = malloc(16)
	int i = 0
	while (i < 16):
		rb[i] = key[i] & 255
		i = i + 1
	rb[3] = rb[3] & 15
	rb[7] = rb[7] & 15
	rb[11] = rb[11] & 15
	rb[15] = rb[15] & 15
	rb[4] = rb[4] & 252
	rb[8] = rb[8] & 252
	rb[12] = rb[12] & 252
	poly1305_limbs(rb, 0, st.r)
	i = 0
	while (i < 16):
		rb[i] = 0
		i = i + 1
	free(rb)

	i = 0
	while (i < 10):
		st.r5[i] = 5 * st.r[i]
		st.h[i] = 0
		i = i + 1
	i = 0
	while (i < 8):
		st.pad[i] = (key[16 + i * 2] & 255) | ((key[17 + i * 2] & 255) << 8)
		i = i + 1
	return st


# Absorb one 16-byte block: h = (h + m) * r mod 2^130 - 5 (partially
# reduced). See the file comment for the bound proof; the fold every three
# products keeps every partial sum under 2^31 - 1.
void poly1305_block(poly1305* st, char* m, int hibit):
	poly1305_limbs(m, hibit, st.ml)
	int j = 0
	while (j < 10):
		st.h[j] = st.h[j] + st.ml[j]
		j = j + 1

	# Schoolbook product with on-the-fly reduction: the coefficient of
	# 2^(13*(i+10)) wraps to limb i multiplied by 5. c carries between
	# output limbs; hi collects the carries folded out mid-row.
	int c = 0
	int i = 0
	while (i < 10):
		int d = c
		int hi = 0
		j = 0
		while (j < 10):
			# The branch condition depends only on loop indices.
			if (j <= i):
				d = d + st.h[j] * st.r[i - j]
			else:
				d = d + st.h[j] * st.r5[i + 10 - j]
			if (j % 3 == 2):
				hi = hi + (d >> 13)
				d = d & 0x1fff
			j = j + 1
		st.t[i] = d & 0x1fff
		c = hi + (d >> 13)
		i = i + 1

	# Carry out of limb 9 is a multiple of 2^130 == 5 (mod p). After this
	# fold c <= 2^20, so u <= 8191 + 5 * 2^20 and the carry into h[1] is
	# at most 640, giving the h[1] <= 8831 inter-block bound.
	int u = st.t[0] + c * 5
	st.h[0] = u & 0x1fff
	st.h[1] = st.t[1] + (u >> 13)
	i = 2
	while (i < 10):
		st.h[i] = st.t[i]
		i = i + 1


# Absorb `len` message bytes. Chunking only depends on the public length.
void poly1305_update(poly1305* st, char* data, int len):
	int off = 0
	if (st.buffered > 0):
		while (st.buffered < 16 && off < len):
			st.buffer[st.buffered] = data[off] & 255
			st.buffered = st.buffered + 1
			off = off + 1
		if (st.buffered == 16):
			poly1305_block(st, st.buffer, 1 << 11)
			st.buffered = 0
	while (len - off >= 16):
		poly1305_block(st, data + off, 1 << 11)
		off = off + 16
	while (off < len):
		st.buffer[st.buffered] = data[off] & 255
		st.buffered = st.buffered + 1
		off = off + 1


# Finish the MAC and write the 16-byte tag. The state keeps its buffers
# (call poly1305_free to release them); reusing it for another message is
# not supported -- the key is one-time by construction.
void poly1305_finish(poly1305* st, char* out):
	if (st.buffered > 0):
		# Short final block: append 0x01 then zeros; no 2^128 bit.
		st.buffer[st.buffered] = 1
		int k = st.buffered + 1
		while (k < 16):
			st.buffer[k] = 0
			k = k + 1
		poly1305_block(st, st.buffer, 0)
		st.buffered = 0

	# Fully carry h so every limb is 13 bits (h < 2^130).
	int* h = st.h
	int c = h[1] >> 13
	h[1] = h[1] & 0x1fff
	int i = 2
	while (i < 10):
		h[i] = h[i] + c
		c = h[i] >> 13
		h[i] = h[i] & 0x1fff
		i = i + 1
	h[0] = h[0] + c * 5
	c = h[0] >> 13
	h[0] = h[0] & 0x1fff
	h[1] = h[1] + c
	c = h[1] >> 13
	h[1] = h[1] & 0x1fff
	h[2] = h[2] + c

	# g = h + 5 - 2^130; the carry out of g[9] is 1 exactly when h >= p.
	# Select h or g with a mask, not a branch (constant time).
	int* g = cast(int*, malloc(10 * __word_size__))
	g[0] = h[0] + 5
	c = g[0] >> 13
	g[0] = g[0] & 0x1fff
	i = 1
	while (i < 10):
		g[i] = h[i] + c
		c = g[i] >> 13
		g[i] = g[i] & 0x1fff
		i = i + 1
	int mask = (c ^ 1) - 1   # all ones when h >= p, else zero
	i = 0
	while (i < 10):
		h[i] = (h[i] & ~mask) | (g[i] & mask)
		g[i] = 0
		i = i + 1
	free(g)

	# Repack the ten 13-bit limbs into eight 16-bit words (mod 2^128) and
	# add s with 16-bit carries.
	int* w = cast(int*, malloc(8 * __word_size__))
	w[0] = (h[0] | (h[1] << 13)) & 0xffff
	w[1] = ((h[1] >> 3) | (h[2] << 10)) & 0xffff
	w[2] = ((h[2] >> 6) | (h[3] << 7)) & 0xffff
	w[3] = ((h[3] >> 9) | (h[4] << 4)) & 0xffff
	w[4] = ((h[4] >> 12) | (h[5] << 1) | (h[6] << 14)) & 0xffff
	w[5] = ((h[6] >> 2) | (h[7] << 11)) & 0xffff
	w[6] = ((h[7] >> 5) | (h[8] << 8)) & 0xffff
	w[7] = ((h[8] >> 8) | (h[9] << 5)) & 0xffff
	int f = 0
	i = 0
	while (i < 8):
		f = w[i] + st.pad[i] + (f >> 16)
		out[i * 2] = f & 255
		out[i * 2 + 1] = (f >> 8) & 255
		i = i + 1
	i = 0
	while (i < 8):
		w[i] = 0
		i = i + 1
	free(w)


# Zero and release a MAC state (the key material in r/pad is secret).
void poly1305_free(poly1305* st):
	int i = 0
	while (i < 10):
		st.r[i] = 0
		st.r5[i] = 0
		st.h[i] = 0
		st.ml[i] = 0
		st.t[i] = 0
		i = i + 1
	i = 0
	while (i < 8):
		st.pad[i] = 0
		i = i + 1
	i = 0
	while (i < 16):
		st.buffer[i] = 0
		i = i + 1
	free(st.r)
	free(st.r5)
	free(st.h)
	free(st.pad)
	free(st.ml)
	free(st.t)
	free(st.buffer)
	free(st)


# One-shot MAC: tag of `len` bytes at `data` under the 32-byte one-time
# key, written as 16 bytes to `out`.
void poly1305_mac(char* data, int len, char* key, char* out):
	poly1305* st = poly1305_new(key)
	poly1305_update(st, data, len)
	poly1305_finish(st, out)
	poly1305_free(st)
