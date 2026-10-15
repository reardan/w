# SEC 1 ECDH over P-256. TLS uses uncompressed 65-byte public points and
# the fixed-width 32-byte affine x coordinate as the shared secret.
# Reuses the P-256 complete-addition ladder and bignum backend. The ladder
# has a fixed 256-bit schedule; the bignum backend retains its existing
# variable-time arithmetic caveat. No signing or verification bypass.
import libs.standard.crypto.ecdsa_p256
import libs.standard.crypto.random


void ecdh_p256_clear(bignum* n):
	mem_fill(n.limbs, 0, BIGNUM_CAP)
	n.n = 0


void ecdh_p256_point_free(ec_point* p):
	ecdh_p256_clear(p.X)
	ecdh_p256_clear(p.Y)
	ecdh_p256_clear(p.Z)
	ec_point_free(p)


int ecdh_p256_private_valid(char* priv):
	p256_init()
	bignum* d = bignum_new()
	bignum_from_bytes(d, priv, 32)
	int ok = bignum_is_zero(d) == 0 && bignum_cmp(d, P256_N) < 0
	ecdh_p256_clear(d)
	bignum_free(d)
	return ok


int ecdh_p256_generate(char* priv):
	for i in range(128):
		if (random_bytes(priv, 32) == 0): break
		if (ecdh_p256_private_valid(priv)): return 1
	mem_fill(priv, 0, 32)
	return 0


# peer is null for public-key generation, otherwise a validated SEC1 point.
# Output is untouched on invalid private scalar or invalid peer point.
int ecdh_p256_multiply(char* priv, char* peer, char* out):
	if (ecdh_p256_private_valid(priv) == 0): return 0
	ec_point* q = ec_point_new()
	if (peer == 0): p256_set_generator(q)
	else:
		if ((peer[0] & 255) != 4):
			ec_point_free(q)
			return 0
		p256_set_affine(q, peer + 1, peer + 33)
		if (p256_on_curve(q.X, q.Y) == 0):
			ec_point_free(q)
			return 0
	bignum* d = bignum_new()
	bignum_from_bytes(d, priv, 32)
	ec_point* r = ec_point_new()
	ec_point* t = ec_point_new()
	point_set_infinity(r)
	int i = 255
	while (i >= 0):
		point_add(r, r, r)
		point_add(t, r, q)
		point_cselect(bignum_get_bit(d, i), r, t)
		i -= 1
	bignum* x = bignum_new()
	bignum* y = bignum_new()
	int ok = p256_affine(r, x, y)
	if (ok):
		if (peer == 0):
			out[0] = 4
			bignum_to_bytes(x, out + 1, 32)
			bignum_to_bytes(y, out + 33, 32)
		else: bignum_to_bytes(x, out, 32)
	ecdh_p256_clear(d)
	ecdh_p256_clear(x)
	ecdh_p256_clear(y)
	bignum_free(d)
	bignum_free(x)
	bignum_free(y)
	ecdh_p256_point_free(q)
	ecdh_p256_point_free(r)
	ecdh_p256_point_free(t)
	return ok


int ecdh_p256_public_key(char* priv, char* out):
	return ecdh_p256_multiply(priv, 0, out)


int ecdh_p256_shared_secret(char* priv, char* peer, int peer_len, char* out):
	if (peer == 0 || peer_len != 65): return 0
	return ecdh_p256_multiply(priv, peer, out)
