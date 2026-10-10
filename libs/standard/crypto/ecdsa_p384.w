# ECDSA P-384 verification (NIST SP 800-186).
# Public inputs only: variable-time arithmetic, no signing API.
# Uses the same complete projective addition formula as ecdsa_p256.w,
# with a per-call context so P-384 does not change P-256's curve/scratch.
# Coordinates/signatures are 48-byte big-endian values. Cofactor is one;
# range and on-curve checks exclude invalid public keys.
import libs.standard.crypto.ecdsa_p256


struct p384_context:
	bignum* P
	bignum* N
	bignum* A
	bignum* B
	bignum* B3
	bignum* GX
	bignum* GY
	bignum* FP_T
	bignum* FP_Q
	bignum* FP_S
	bignum* PA_T0
	bignum* PA_T1
	bignum* PA_T2
	bignum* PA_T3
	bignum* PA_T4
	bignum* PA_T5
	bignum* PA_RX
	bignum* PA_RY
	bignum* PA_RZ


p384_context* p384_context_new():
	p384_context* ctx = new p384_context()
	ctx.P = bignum_new()
	ctx.N = bignum_new()
	ctx.A = bignum_new()
	ctx.B = bignum_new()
	ctx.B3 = bignum_new()
	ctx.GX = bignum_new()
	ctx.GY = bignum_new()
	ctx.FP_T = bignum_new()
	ctx.FP_Q = bignum_new()
	ctx.FP_S = bignum_new()
	ctx.PA_T0 = bignum_new()
	ctx.PA_T1 = bignum_new()
	ctx.PA_T2 = bignum_new()
	ctx.PA_T3 = bignum_new()
	ctx.PA_T4 = bignum_new()
	ctx.PA_T5 = bignum_new()
	ctx.PA_RX = bignum_new()
	ctx.PA_RY = bignum_new()
	ctx.PA_RZ = bignum_new()
	p256_load_hex(ctx.P, c"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff")
	p256_load_hex(ctx.N, c"ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973")
	p256_load_hex(ctx.B, c"b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef")
	p256_load_hex(ctx.GX, c"aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7")
	p256_load_hex(ctx.GY, c"3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f")
	bignum_copy(ctx.A, ctx.P)
	bignum_sub_small(ctx.A, 3)
	bignum* three = bignum_new()
	bignum_set_u32(three, 3)
	bignum_modmul(ctx.B3, ctx.B, three, ctx.P)
	bignum_free(three)
	return ctx


void p384_context_free(p384_context* ctx):
	bignum_free(ctx.P)
	bignum_free(ctx.N)
	bignum_free(ctx.A)
	bignum_free(ctx.B)
	bignum_free(ctx.B3)
	bignum_free(ctx.GX)
	bignum_free(ctx.GY)
	bignum_free(ctx.FP_T)
	bignum_free(ctx.FP_Q)
	bignum_free(ctx.FP_S)
	bignum_free(ctx.PA_T0)
	bignum_free(ctx.PA_T1)
	bignum_free(ctx.PA_T2)
	bignum_free(ctx.PA_T3)
	bignum_free(ctx.PA_T4)
	bignum_free(ctx.PA_T5)
	bignum_free(ctx.PA_RX)
	bignum_free(ctx.PA_RY)
	bignum_free(ctx.PA_RZ)
	free(cast(char*, ctx))


void p384_fp_mul(p384_context* ctx, bignum* r, bignum* a, bignum* b):
	bignum_mul(ctx.FP_T, a, b)
	bignum_divmod(ctx.FP_T, ctx.P, ctx.FP_Q, r)


void p384_fp_add(p384_context* ctx, bignum* r, bignum* a, bignum* b):
	bignum_add(ctx.FP_S, a, b)
	if (bignum_cmp(ctx.FP_S, ctx.P) >= 0): bignum_sub(ctx.FP_S, ctx.P)
	bignum_copy(r, ctx.FP_S)


void p384_fp_sub(p384_context* ctx, bignum* r, bignum* a, bignum* b):
	if (bignum_cmp(a, b) >= 0):
		bignum_copy(ctx.FP_S, a)
		bignum_sub(ctx.FP_S, b)
	else:
		bignum_add(ctx.FP_S, a, ctx.P)
		bignum_sub(ctx.FP_S, b)
	bignum_copy(r, ctx.FP_S)


void p384_set_generator(p384_context* ctx, ec_point* g):
	bignum_copy(g.X, ctx.GX)
	bignum_copy(g.Y, ctx.GY)
	bignum_set_u32(g.Z, 1)


void p384_set_affine(ec_point* p, char* xb, char* yb):
	bignum_from_bytes(p.X, xb, 48)
	bignum_from_bytes(p.Y, yb, 48)
	bignum_set_u32(p.Z, 1)


# Complete Renes-Costello-Batina addition, Algorithm 1 (as in P-256).
# Aliasing is safe: stage all three output coordinates in ctx scratch.
void p384_point_add(p384_context* ctx, ec_point* out, ec_point* p, ec_point* q):
	bignum* x1 = p.X
	bignum* y1 = p.Y
	bignum* z1 = p.Z
	bignum* x2 = q.X
	bignum* y2 = q.Y
	bignum* z2 = q.Z
	p384_fp_mul(ctx, ctx.PA_T0, x1, x2)          # 1
	p384_fp_mul(ctx, ctx.PA_T1, y1, y2)          # 2
	p384_fp_mul(ctx, ctx.PA_T2, z1, z2)          # 3
	p384_fp_add(ctx, ctx.PA_T3, x1, y1)          # 4
	p384_fp_add(ctx, ctx.PA_T4, x2, y2)          # 5
	p384_fp_mul(ctx, ctx.PA_T3, ctx.PA_T3, ctx.PA_T4)    # 6
	p384_fp_add(ctx, ctx.PA_T4, ctx.PA_T0, ctx.PA_T1)    # 7
	p384_fp_sub(ctx, ctx.PA_T3, ctx.PA_T3, ctx.PA_T4)    # 8
	p384_fp_add(ctx, ctx.PA_T4, x1, z1)          # 9
	p384_fp_add(ctx, ctx.PA_T5, x2, z2)          # 10
	p384_fp_mul(ctx, ctx.PA_T4, ctx.PA_T4, ctx.PA_T5)    # 11
	p384_fp_add(ctx, ctx.PA_T5, ctx.PA_T0, ctx.PA_T2)    # 12
	p384_fp_sub(ctx, ctx.PA_T4, ctx.PA_T4, ctx.PA_T5)    # 13
	p384_fp_add(ctx, ctx.PA_T5, y1, z1)          # 14
	p384_fp_add(ctx, ctx.PA_RX, y2, z2)          # 15
	p384_fp_mul(ctx, ctx.PA_T5, ctx.PA_T5, ctx.PA_RX)    # 16
	p384_fp_add(ctx, ctx.PA_RX, ctx.PA_T1, ctx.PA_T2)    # 17
	p384_fp_sub(ctx, ctx.PA_T5, ctx.PA_T5, ctx.PA_RX)    # 18
	p384_fp_mul(ctx, ctx.PA_RZ, ctx.A, ctx.PA_T4)   # 19
	p384_fp_mul(ctx, ctx.PA_RX, ctx.B3, ctx.PA_T2)  # 20
	p384_fp_add(ctx, ctx.PA_RZ, ctx.PA_RX, ctx.PA_RZ)    # 21
	p384_fp_sub(ctx, ctx.PA_RX, ctx.PA_T1, ctx.PA_RZ)    # 22
	p384_fp_add(ctx, ctx.PA_RZ, ctx.PA_T1, ctx.PA_RZ)    # 23
	p384_fp_mul(ctx, ctx.PA_RY, ctx.PA_RX, ctx.PA_RZ)    # 24
	p384_fp_add(ctx, ctx.PA_T1, ctx.PA_T0, ctx.PA_T0)    # 25
	p384_fp_add(ctx, ctx.PA_T1, ctx.PA_T1, ctx.PA_T0)    # 26
	p384_fp_mul(ctx, ctx.PA_T2, ctx.A, ctx.PA_T2)   # 27
	p384_fp_mul(ctx, ctx.PA_T4, ctx.B3, ctx.PA_T4)  # 28
	p384_fp_add(ctx, ctx.PA_T1, ctx.PA_T1, ctx.PA_T2)    # 29
	p384_fp_sub(ctx, ctx.PA_T2, ctx.PA_T0, ctx.PA_T2)    # 30
	p384_fp_mul(ctx, ctx.PA_T2, ctx.A, ctx.PA_T2)   # 31
	p384_fp_add(ctx, ctx.PA_T4, ctx.PA_T4, ctx.PA_T2)    # 32
	p384_fp_mul(ctx, ctx.PA_T0, ctx.PA_T1, ctx.PA_T4)    # 33
	p384_fp_add(ctx, ctx.PA_RY, ctx.PA_RY, ctx.PA_T0)    # 34
	p384_fp_mul(ctx, ctx.PA_T0, ctx.PA_T5, ctx.PA_T4)    # 35
	p384_fp_mul(ctx, ctx.PA_RX, ctx.PA_T3, ctx.PA_RX)    # 36
	p384_fp_sub(ctx, ctx.PA_RX, ctx.PA_RX, ctx.PA_T0)    # 37
	p384_fp_mul(ctx, ctx.PA_T0, ctx.PA_T3, ctx.PA_T1)    # 38
	p384_fp_mul(ctx, ctx.PA_RZ, ctx.PA_T5, ctx.PA_RZ)    # 39
	p384_fp_add(ctx, ctx.PA_RZ, ctx.PA_RZ, ctx.PA_T0)    # 40
	bignum_copy(out.X, ctx.PA_RX)
	bignum_copy(out.Y, ctx.PA_RY)
	bignum_copy(out.Z, ctx.PA_RZ)


void p384_scalar_mult_vartime(p384_context* ctx, ec_point* out, bignum* k, ec_point* base):
	ec_point* r = ec_point_new()
	point_set_infinity(r)
	int i = bignum_bit_length(k) - 1
	while (i >= 0):
		p384_point_add(ctx, r, r, r)
		if (bignum_get_bit(k, i) != 0): p384_point_add(ctx, r, r, base)
		i = i - 1
	point_copy(out, r)
	ec_point_free(r)


int p384_affine(p384_context* ctx, ec_point* p, bignum* out_x, bignum* out_y):
	if (point_is_infinity(p) != 0): return 0
	bignum* zi = bignum_new()
	bignum_modinv(zi, p.Z, ctx.P)
	p384_fp_mul(ctx, out_x, p.X, zi)
	p384_fp_mul(ctx, out_y, p.Y, zi)
	bignum_free(zi)
	return 1


int p384_on_curve(p384_context* ctx, bignum* x, bignum* y):
	if (bignum_cmp(x, ctx.P) >= 0): return 0
	if (bignum_cmp(y, ctx.P) >= 0): return 0
	bignum* lhs = bignum_new()
	bignum* rhs = bignum_new()
	bignum* t = bignum_new()
	p384_fp_mul(ctx, lhs, y, y)             # y^2
	p384_fp_mul(ctx, rhs, x, x)            # x^2
	p384_fp_mul(ctx, rhs, rhs, x)         # x^3
	p384_fp_add(ctx, t, x, x)            # 2x
	p384_fp_add(ctx, t, t, x)          # 3x
	p384_fp_sub(ctx, rhs, rhs, t)     # x^3 - 3x
	p384_fp_add(ctx, rhs, rhs, ctx.B) # x^3 - 3x + b
	int ok = 0
	if (bignum_cmp(lhs, rhs) == 0): ok = 1
	bignum_free(lhs)
	bignum_free(rhs)
	bignum_free(t)
	return ok


void p384_hash_scalar(bignum* z, char* hash, int hashlen):
	int use = hashlen
	if (use > 48): use = 48
	bignum_from_bytes(z, hash, use)


# Verify a digest using 48-byte coordinates and signature components.
# Digests longer than 384 bits are truncated on the right (ECDSA bits2int).
int ecdsa_p384_verify(char* qx, char* qy, char* hash, int hashlen, char* r_bytes, char* s_bytes):
	if (qx == 0 || qy == 0 || hash == 0 || r_bytes == 0 || s_bytes == 0 || hashlen <= 0): return 0
	p384_context* ctx = p384_context_new()
	bignum* r = bignum_new()
	bignum* s = bignum_new()
	bignum_from_bytes(r, r_bytes, 48)
	bignum_from_bytes(s, s_bytes, 48)
	int result = 0
	int ok = 1
	if (bignum_is_zero(r) != 0): ok = 0
	if (bignum_cmp(r, ctx.N) >= 0): ok = 0
	if (bignum_is_zero(s) != 0): ok = 0
	if (bignum_cmp(s, ctx.N) >= 0): ok = 0
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
		p384_set_affine(q, qx, qy)
		if (p384_on_curve(ctx, q.X, q.Y) == 0): ok = 0
	if (ok != 0):
		p384_set_generator(ctx, g)
		p384_hash_scalar(z, hash, hashlen)
		bignum_modinv(w, s, ctx.N)            # w = s^{-1} mod n
		bignum_modmul(u1, z, w, ctx.N)        # u1 = z*w mod n
		bignum_modmul(u2, r, w, ctx.N)        # u2 = r*w mod n
		p384_scalar_mult_vartime(ctx, r1, u1, g)
		p384_scalar_mult_vartime(ctx, r2, u2, q)
		p384_point_add(ctx, racc, r1, r2)
		if (p384_affine(ctx, racc, xr, yr) != 0):
			bignum_mod(rr, xr, ctx.N)         # x_R mod n
			if (bignum_cmp(rr, r) == 0): result = 1
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
	p384_context_free(ctx)
	return result
