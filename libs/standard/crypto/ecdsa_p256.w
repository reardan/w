# ECDSA over NIST P-256 (secp256r1): signature verification, plus deterministic
# signing per RFC 6979 for the TLS server role. Part of the pure-W native HTTPS
# stack (issue #155, phase 6). No FFI, no int64; all arithmetic runs through the
# base-2^15 bignum in libs/standard/crypto/bignum.w.
#
# Curve: y^2 = x^3 - 3x + b over F_p, group order n, base point G.
#
# CONSTANT-TIME POSTURE. The signing path multiplies the secret nonce k and the
# private key d by curve points. Those multiplications use a fixed 256-iteration
# double-and-add-*always* ladder (p256_scalar_mult_ct) built on the complete
# (exception-free) Renes-Costello-Batina projective addition formulas
# (Alg. 1, "Complete addition formulas for prime order elliptic curves", 2015),
# with a branch-free conditional select on the secret scalar bits. The nonce is
# derived deterministically (RFC 6979), removing the nonce-reuse/bias footgun.
# Verification handles only public data and uses a variable-time ladder.
#
# RESIDUAL CAVEAT: the underlying bignum multiply/reduce/inverse are themselves
# variable-time (data-independent branch structure, but not cycle-constant).
# Full constant-time limb arithmetic is out of scope for this packet; the ladder
# removes the key-dependent *control-flow* leak, which is the dominant risk.
import lib.lib
import lib.memory
import lib.sha256
import libs.standard.crypto.bignum


# ---- curve constants (loaded once) ------------------------------------------

int P256_INITED
bignum* P256_P
bignum* P256_N
bignum* P256_A       # a = p - 3 (i.e. -3 mod p)
bignum* P256_B
bignum* P256_B3      # 3*b mod p
bignum* P256_GX
bignum* P256_GY

# Field-multiply scratch (no per-call allocation in the hot ladder loop).
bignum* FP_T
bignum* FP_Q
bignum* FP_S

# Complete-addition scratch (Algorithm 1 temporaries + result coords).
bignum* PA_T0
bignum* PA_T1
bignum* PA_T2
bignum* PA_T3
bignum* PA_T4
bignum* PA_T5
bignum* PA_RX
bignum* PA_RY
bignum* PA_RZ


int p256_hexval(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	if ((c >= 'a') && (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')):
		return c - 'A' + 10
	return 0


# Load a 64-hex-digit (32-byte) big-endian constant into dst.
void p256_load_hex(bignum* dst, char* h):
	int l = strlen(h)
	char* buf = malloc(l / 2 + 2)
	int hi = 0
	int oi = 0
	if ((l & 1) == 1):
		buf[0] = p256_hexval(h[0])
		hi = 1
		oi = 1
	while (hi < l):
		buf[oi] = (p256_hexval(h[hi]) << 4) | p256_hexval(h[hi + 1])
		hi = hi + 2
		oi = oi + 1
	bignum_from_bytes(dst, buf, oi)
	free(buf)


void p256_init():
	if (P256_INITED != 0):
		return
	P256_P = bignum_new()
	P256_N = bignum_new()
	P256_A = bignum_new()
	P256_B = bignum_new()
	P256_B3 = bignum_new()
	P256_GX = bignum_new()
	P256_GY = bignum_new()
	FP_T = bignum_new()
	FP_Q = bignum_new()
	FP_S = bignum_new()
	PA_T0 = bignum_new()
	PA_T1 = bignum_new()
	PA_T2 = bignum_new()
	PA_T3 = bignum_new()
	PA_T4 = bignum_new()
	PA_T5 = bignum_new()
	PA_RX = bignum_new()
	PA_RY = bignum_new()
	PA_RZ = bignum_new()

	p256_load_hex(P256_P, c"ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")
	p256_load_hex(P256_N, c"ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
	p256_load_hex(P256_B, c"5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b")
	p256_load_hex(P256_GX, c"6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")
	p256_load_hex(P256_GY, c"4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")

	# a = p - 3
	bignum_copy(P256_A, P256_P)
	bignum_sub_small(P256_A, 3)
	# b3 = 3*b mod p
	bignum* three = bignum_new()
	bignum_set_u32(three, 3)
	bignum_modmul(P256_B3, P256_B, three, P256_P)
	bignum_free(three)

	P256_INITED = 1


# ---- field arithmetic mod p -------------------------------------------------

# r = (a * b) mod p. Alloc-free (module scratch); r must differ from FP_T/FP_Q.
void fp_mul(bignum* r, bignum* a, bignum* b):
	bignum_mul(FP_T, a, b)
	bignum_divmod(FP_T, P256_P, FP_Q, r)


# r = (a + b) mod p, tolerates r aliasing a or b.
void fp_add(bignum* r, bignum* a, bignum* b):
	bignum_add(FP_S, a, b)
	if (bignum_cmp(FP_S, P256_P) >= 0):
		bignum_sub(FP_S, P256_P)
	bignum_copy(r, FP_S)


# r = (a - b) mod p, tolerates r aliasing a or b.
void fp_sub(bignum* r, bignum* a, bignum* b):
	if (bignum_cmp(a, b) >= 0):
		bignum_copy(FP_S, a)
		bignum_sub(FP_S, b)
	else:
		bignum_add(FP_S, a, P256_P)
		bignum_sub(FP_S, b)
	bignum_copy(r, FP_S)


# ---- points (homogeneous projective X:Y:Z; identity is 0:1:0) ---------------

struct ec_point:
	bignum* X
	bignum* Y
	bignum* Z


ec_point* ec_point_new():
	ec_point* p = new ec_point()
	p.X = bignum_new()
	p.Y = bignum_new()
	p.Z = bignum_new()
	return p


void ec_point_free(ec_point* p):
	bignum_free(p.X)
	bignum_free(p.Y)
	bignum_free(p.Z)
	free(cast(char*, p))


void point_set_infinity(ec_point* p):
	bignum_set_zero(p.X)
	bignum_set_u32(p.Y, 1)
	bignum_set_zero(p.Z)


int point_is_infinity(ec_point* p):
	return bignum_is_zero(p.Z)


void point_copy(ec_point* dst, ec_point* src):
	bignum_copy(dst.X, src.X)
	bignum_copy(dst.Y, src.Y)
	bignum_copy(dst.Z, src.Z)


void p256_set_generator(ec_point* g):
	bignum_copy(g.X, P256_GX)
	bignum_copy(g.Y, P256_GY)
	bignum_set_u32(g.Z, 1)


void p256_set_affine(ec_point* p, char* xb, char* yb):
	bignum_from_bytes(p.X, xb, 32)
	bignum_from_bytes(p.Y, yb, 32)
	bignum_set_u32(p.Z, 1)


# Constant-time projective select of each coordinate: dst = bit ? src : dst.
void point_cselect(int bit, ec_point* dst, ec_point* src):
	bignum_cselect(bit, dst.X, src.X)
	bignum_cselect(bit, dst.Y, src.Y)
	bignum_cselect(bit, dst.Z, src.Z)


# out = P + Q using the complete Renes-Costello-Batina addition (a = -3).
# Exception-free: handles P == Q, P == -Q, and either operand at infinity.
# out may alias P and/or Q (results are staged in module scratch first).
void point_add(ec_point* out, ec_point* p, ec_point* q):
	bignum* x1 = p.X
	bignum* y1 = p.Y
	bignum* z1 = p.Z
	bignum* x2 = q.X
	bignum* y2 = q.Y
	bignum* z2 = q.Z
	fp_mul(PA_T0, x1, x2)          # 1
	fp_mul(PA_T1, y1, y2)          # 2
	fp_mul(PA_T2, z1, z2)          # 3
	fp_add(PA_T3, x1, y1)          # 4
	fp_add(PA_T4, x2, y2)          # 5
	fp_mul(PA_T3, PA_T3, PA_T4)    # 6
	fp_add(PA_T4, PA_T0, PA_T1)    # 7
	fp_sub(PA_T3, PA_T3, PA_T4)    # 8
	fp_add(PA_T4, x1, z1)          # 9
	fp_add(PA_T5, x2, z2)          # 10
	fp_mul(PA_T4, PA_T4, PA_T5)    # 11
	fp_add(PA_T5, PA_T0, PA_T2)    # 12
	fp_sub(PA_T4, PA_T4, PA_T5)    # 13
	fp_add(PA_T5, y1, z1)          # 14
	fp_add(PA_RX, y2, z2)          # 15
	fp_mul(PA_T5, PA_T5, PA_RX)    # 16
	fp_add(PA_RX, PA_T1, PA_T2)    # 17
	fp_sub(PA_T5, PA_T5, PA_RX)    # 18
	fp_mul(PA_RZ, P256_A, PA_T4)   # 19
	fp_mul(PA_RX, P256_B3, PA_T2)  # 20
	fp_add(PA_RZ, PA_RX, PA_RZ)    # 21
	fp_sub(PA_RX, PA_T1, PA_RZ)    # 22
	fp_add(PA_RZ, PA_T1, PA_RZ)    # 23
	fp_mul(PA_RY, PA_RX, PA_RZ)    # 24
	fp_add(PA_T1, PA_T0, PA_T0)    # 25
	fp_add(PA_T1, PA_T1, PA_T0)    # 26
	fp_mul(PA_T2, P256_A, PA_T2)   # 27
	fp_mul(PA_T4, P256_B3, PA_T4)  # 28
	fp_add(PA_T1, PA_T1, PA_T2)    # 29
	fp_sub(PA_T2, PA_T0, PA_T2)    # 30
	fp_mul(PA_T2, P256_A, PA_T2)   # 31
	fp_add(PA_T4, PA_T4, PA_T2)    # 32
	fp_mul(PA_T0, PA_T1, PA_T4)    # 33
	fp_add(PA_RY, PA_RY, PA_T0)    # 34
	fp_mul(PA_T0, PA_T5, PA_T4)    # 35
	fp_mul(PA_RX, PA_T3, PA_RX)    # 36
	fp_sub(PA_RX, PA_RX, PA_T0)    # 37
	fp_mul(PA_T0, PA_T3, PA_T1)    # 38
	fp_mul(PA_RZ, PA_T5, PA_RZ)    # 39
	fp_add(PA_RZ, PA_RZ, PA_T0)    # 40
	bignum_copy(out.X, PA_RX)
	bignum_copy(out.Y, PA_RY)
	bignum_copy(out.Z, PA_RZ)


# out = k * base, constant-time (fixed 256 iterations, branch-free select).
# For the secret nonce/key multiplications in the signing path.
void p256_scalar_mult_ct(ec_point* out, bignum* k, ec_point* base):
	ec_point* r = ec_point_new()
	ec_point* t = ec_point_new()
	point_set_infinity(r)
	int i = 255
	while (i >= 0):
		point_add(r, r, r)
		point_add(t, r, base)
		int bit = bignum_get_bit(k, i)
		point_cselect(bit, r, t)
		i = i - 1
	point_copy(out, r)
	ec_point_free(r)
	ec_point_free(t)


# out = k * base, variable-time. Verification only (public inputs).
void p256_scalar_mult_vartime(ec_point* out, bignum* k, ec_point* base):
	ec_point* r = ec_point_new()
	point_set_infinity(r)
	int i = bignum_bit_length(k) - 1
	while (i >= 0):
		point_add(r, r, r)
		if (bignum_get_bit(k, i) != 0):
			point_add(r, r, base)
		i = i - 1
	point_copy(out, r)
	ec_point_free(r)


# Convert projective point to affine coordinates mod p. Returns 0 for infinity.
int p256_affine(ec_point* p, bignum* out_x, bignum* out_y):
	if (point_is_infinity(p) != 0):
		return 0
	bignum* zi = bignum_new()
	bignum_modinv(zi, p.Z, P256_P)
	fp_mul(out_x, p.X, zi)
	fp_mul(out_y, p.Y, zi)
	bignum_free(zi)
	return 1


# Is the affine point (x, y) on the curve and in range? (public-key validation)
int p256_on_curve(bignum* x, bignum* y):
	if (bignum_cmp(x, P256_P) >= 0):
		return 0
	if (bignum_cmp(y, P256_P) >= 0):
		return 0
	bignum* lhs = bignum_new()
	bignum* rhs = bignum_new()
	bignum* t = bignum_new()
	fp_mul(lhs, y, y)             # y^2
	fp_mul(rhs, x, x)            # x^2
	fp_mul(rhs, rhs, x)         # x^3
	fp_add(t, x, x)            # 2x
	fp_add(t, t, x)          # 3x
	fp_sub(rhs, rhs, t)     # x^3 - 3x
	fp_add(rhs, rhs, P256_B) # x^3 - 3x + b
	int ok = 0
	if (bignum_cmp(lhs, rhs) == 0):
		ok = 1
	bignum_free(lhs)
	bignum_free(rhs)
	bignum_free(t)
	return ok


# ---- hash-to-scalar (RFC 6279 bits2int for qlen = 256) ----------------------

# z = leftmost 256 bits of the hash as an integer (no reduction mod n here).
void p256_hash_scalar(bignum* z, char* hash, int hashlen):
	int use = hashlen
	if (use > 32):
		use = 32
	bignum_from_bytes(z, hash, use)


# ---- HMAC-SHA256 (private to this module; RFC 6979 needs it) ----------------

void hmac_sha256(char* key, int keylen, char* msg, int msglen, char* out):
	char* kb = malloc(64)
	int i = 0
	while (i < 64):
		kb[i] = 0
		i = i + 1
	if (keylen > 64):
		sha256(key, keylen, kb)
	else:
		i = 0
		while (i < keylen):
			kb[i] = key[i]
			i = i + 1
	char* ipad = malloc(64 + msglen)
	char* opad = malloc(64 + 32)
	i = 0
	while (i < 64):
		int kv = kb[i] & 255
		ipad[i] = kv ^ 54     # 0x36
		opad[i] = kv ^ 92     # 0x5c
		i = i + 1
	i = 0
	while (i < msglen):
		ipad[64 + i] = msg[i]
		i = i + 1
	char* inner = malloc(32)
	sha256(ipad, 64 + msglen, inner)
	i = 0
	while (i < 32):
		opad[64 + i] = inner[i]
		i = i + 1
	sha256(opad, 96, out)
	free(kb)
	free(ipad)
	free(opad)
	free(inner)


# ---- RFC 6979 deterministic nonce generator ---------------------------------

struct rfc6979:
	char* k        # 32-byte HMAC key
	char* v        # 32-byte value
	int started


# d_oct and h_oct are int2octets(privkey) and bits2octets(hash), each 32 bytes.
rfc6979* rfc6979_new(char* d_oct, char* h_oct):
	rfc6979* g = new rfc6979()
	g.k = malloc(32)
	g.v = malloc(32)
	g.started = 0
	int i = 0
	while (i < 32):
		g.v[i] = 1
		g.k[i] = 0
		i = i + 1
	char* buf = malloc(97)
	# K = HMAC_K(V || 0x00 || d_oct || h_oct)
	i = 0
	while (i < 32):
		buf[i] = g.v[i]
		i = i + 1
	buf[32] = 0
	i = 0
	while (i < 32):
		buf[33 + i] = d_oct[i]
		buf[65 + i] = h_oct[i]
		i = i + 1
	hmac_sha256(g.k, 32, buf, 97, g.k)
	hmac_sha256(g.k, 32, g.v, 32, g.v)
	# K = HMAC_K(V || 0x01 || d_oct || h_oct)
	i = 0
	while (i < 32):
		buf[i] = g.v[i]
		i = i + 1
	buf[32] = 1
	hmac_sha256(g.k, 32, buf, 97, g.k)
	hmac_sha256(g.k, 32, g.v, 32, g.v)
	free(buf)
	return g


void rfc6979_free(rfc6979* g):
	free(g.k)
	free(g.v)
	free(cast(char*, g))


# Produce the next candidate nonce as 32 big-endian bytes into out. Applies the
# RFC 6979 rejection update between candidates.
void rfc6979_next(rfc6979* g, char* out):
	if (g.started != 0):
		char* buf = malloc(33)
		int j = 0
		while (j < 32):
			buf[j] = g.v[j]
			j = j + 1
		buf[32] = 0
		hmac_sha256(g.k, 32, buf, 33, g.k)
		hmac_sha256(g.k, 32, g.v, 32, g.v)
		free(buf)
	g.started = 1
	# qlen == hlen == 256, so one HMAC block fills the 32-byte candidate.
	hmac_sha256(g.k, 32, g.v, 32, g.v)
	int i = 0
	while (i < 32):
		out[i] = g.v[i]
		i = i + 1


# ---- public API -------------------------------------------------------------

# Verify an ECDSA/P-256 signature. qx/qy: 32-byte public-key coords; hash:
# message digest (leftmost 256 bits used); r/s: 32-byte signature components.
# Returns 1 if valid, 0 otherwise.
int ecdsa_p256_verify(char* qx, char* qy, char* hash, int hashlen, char* r_bytes, char* s_bytes):
	p256_init()
	bignum* r = bignum_new()
	bignum* s = bignum_new()
	bignum_from_bytes(r, r_bytes, 32)
	bignum_from_bytes(s, s_bytes, 32)
	int result = 0
	int ok = 1
	if (bignum_is_zero(r) != 0):
		ok = 0
	if (bignum_cmp(r, P256_N) >= 0):
		ok = 0
	if (bignum_is_zero(s) != 0):
		ok = 0
	if (bignum_cmp(s, P256_N) >= 0):
		ok = 0
	ec_point* q = ec_point_new()
	ec_point* g = ec_point_new()
	ec_point* r1 = ec_point_new()
	ec_point* r2 = ec_point_new()
	ec_point* racc = ec_point_new()
	bignum* z = bignum_new()
	bignum* w = bignum_new()
	bignum* u1 = bignum_new()
	bignum* u2 = bignum_new()
	bignum* xr = bignum_new()
	bignum* yr = bignum_new()
	bignum* rr = bignum_new()
	if (ok != 0):
		p256_set_affine(q, qx, qy)
		if (p256_on_curve(q.X, q.Y) == 0):
			ok = 0
	if (ok != 0):
		p256_set_generator(g)
		p256_hash_scalar(z, hash, hashlen)
		bignum_modinv(w, s, P256_N)            # w = s^{-1} mod n
		bignum_modmul(u1, z, w, P256_N)        # u1 = z*w mod n
		bignum_modmul(u2, r, w, P256_N)        # u2 = r*w mod n
		p256_scalar_mult_vartime(r1, u1, g)
		p256_scalar_mult_vartime(r2, u2, q)
		point_add(racc, r1, r2)
		if (p256_affine(racc, xr, yr) != 0):
			bignum_mod(rr, xr, P256_N)         # x_R mod n
			if (bignum_cmp(rr, r) == 0):
				result = 1
	bignum_free(r)
	bignum_free(s)
	bignum_free(z)
	bignum_free(w)
	bignum_free(u1)
	bignum_free(u2)
	bignum_free(xr)
	bignum_free(yr)
	bignum_free(rr)
	ec_point_free(q)
	ec_point_free(g)
	ec_point_free(r1)
	ec_point_free(r2)
	ec_point_free(racc)
	return result


# Deterministic ECDSA/P-256 signature (RFC 6979) of a message digest.
# d: 32-byte private key; hash: digest; writes 32-byte r,s. Returns 1 on
# success, 0 on invalid key. Constant-time nonce/key scalar multiplication.
int ecdsa_p256_sign(char* d_bytes, char* hash, int hashlen, char* out_r, char* out_s):
	p256_init()
	bignum* d = bignum_new()
	bignum_from_bytes(d, d_bytes, 32)
	if (bignum_is_zero(d) != 0):
		bignum_free(d)
		return 0
	if (bignum_cmp(d, P256_N) >= 0):
		bignum_free(d)
		return 0
	bignum* z = bignum_new()
	bignum* zmod = bignum_new()
	p256_hash_scalar(z, hash, hashlen)
	bignum_mod(zmod, z, P256_N)                # z mod n
	char* doct = malloc(32)
	char* hoct = malloc(32)
	bignum_to_bytes(d, doct, 32)               # int2octets(d)
	bignum_to_bytes(zmod, hoct, 32)            # bits2octets(hash)
	rfc6979* gen = rfc6979_new(doct, hoct)
	ec_point* g = ec_point_new()
	p256_set_generator(g)
	ec_point* rp = ec_point_new()
	bignum* k = bignum_new()
	bignum* r = bignum_new()
	bignum* s = bignum_new()
	bignum* xr = bignum_new()
	bignum* yr = bignum_new()
	bignum* kinv = bignum_new()
	bignum* rd = bignum_new()
	bignum* zrd = bignum_new()
	char* kb = malloc(32)
	int result = 0
	int guard = 0
	while ((result == 0) && (guard < 1000)):
		guard = guard + 1
		rfc6979_next(gen, kb)
		bignum_from_bytes(k, kb, 32)
		if (bignum_is_zero(k) != 0):
			continue
		if (bignum_cmp(k, P256_N) >= 0):
			continue
		p256_scalar_mult_ct(rp, k, g)
		if (p256_affine(rp, xr, yr) == 0):
			continue
		bignum_mod(r, xr, P256_N)              # r = x_R mod n
		if (bignum_is_zero(r) != 0):
			continue
		bignum_modinv(kinv, k, P256_N)         # k^{-1} mod n
		bignum_modmul(rd, r, d, P256_N)        # r*d mod n
		bignum_addmod(zrd, zmod, rd, P256_N)   # (z + r*d) mod n
		bignum_modmul(s, kinv, zrd, P256_N)    # s = k^{-1}(z + r*d) mod n
		if (bignum_is_zero(s) != 0):
			continue
		bignum_to_bytes(r, out_r, 32)
		bignum_to_bytes(s, out_s, 32)
		result = 1
	rfc6979_free(gen)
	free(doct)
	free(hoct)
	free(kb)
	bignum_free(d)
	bignum_free(z)
	bignum_free(zmod)
	bignum_free(k)
	bignum_free(r)
	bignum_free(s)
	bignum_free(xr)
	bignum_free(yr)
	bignum_free(kinv)
	bignum_free(rd)
	bignum_free(zrd)
	ec_point_free(g)
	ec_point_free(rp)
	return result


# Derive the public key Q = d*G for a 32-byte private key. Writes 32-byte
# affine coords. Returns 1 on success. Constant-time scalar multiplication.
int ecdsa_p256_public_key(char* d_bytes, char* out_qx, char* out_qy):
	p256_init()
	bignum* d = bignum_new()
	bignum_from_bytes(d, d_bytes, 32)
	int result = 0
	if ((bignum_is_zero(d) == 0) & (bignum_cmp(d, P256_N) < 0)):
		ec_point* g = ec_point_new()
		ec_point* rp = ec_point_new()
		p256_set_generator(g)
		p256_scalar_mult_ct(rp, d, g)
		bignum* x = bignum_new()
		bignum* y = bignum_new()
		if (p256_affine(rp, x, y) != 0):
			bignum_to_bytes(x, out_qx, 32)
			bignum_to_bytes(y, out_qy, 32)
			result = 1
		bignum_free(x)
		bignum_free(y)
		ec_point_free(g)
		ec_point_free(rp)
	bignum_free(d)
	return result
