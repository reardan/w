# RSA signature verification: PKCS#1 v1.5 (strict DigestInfo match) and PSS
# (MGF1, sLen = hLen). Part of the pure-W native HTTPS stack (issue #155,
# phase 6). Verify only -- W never signs with RSA. No FFI, no int64.
#
# The public exponent is small (typically 65537), so sig^e mod n is a handful
# of modular multiplications; verification handles only public data and may be
# variable-time.
#
# SCOPE: signatures arrive as raw EM bytes at this API (no ASN.1/X.509 parsing
# here -- that is a separate issue). PKCS#1 v1.5 supports SHA-256 and SHA-384
# DigestInfo (the digest is supplied by the caller; this module does not hash).
# PSS is implemented for SHA-256 (MGF1-SHA256); SHA-384 PSS additionally needs a
# SHA-384 core (crypto/sha2.w, another packet) to recompute H' and is left as a
# one-function follow-up -- the internal helper is already hash-parameterized.
import lib.lib
import lib.memory
import lib.sha256
import libs.standard.crypto.bignum


int RSA_HASH_SHA256():
	return 256


int RSA_HASH_SHA384():
	return 384


# DigestInfo ASN.1 prefixes (the bytes preceding the raw digest).
char* rsa_digestinfo_sha256():
	return c"\x30\x31\x30\x0d\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01\x05\x00\x04\x20"


char* rsa_digestinfo_sha384():
	return c"\x30\x41\x30\x0d\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x02\x05\x00\x04\x30"


int RSA_DIGESTINFO_LEN():
	return 19


# ---- RSA primitive ----------------------------------------------------------

# Compute the encoded message EM = (sig^e mod n) as k big-endian bytes, where
# k is the modulus byte length. Returns 1 on success, 0 if the signature
# representative is out of range (sig >= n). out must hold at least k bytes.
int rsa_recover(char* n, int nlen, char* e, int elen, char* sig, int siglen, char* out, int k):
	if (siglen != k):
		return 0
	bignum* nn = bignum_new()
	bignum* ee = bignum_new()
	bignum* ss = bignum_new()
	bignum* mm = bignum_new()
	bignum_from_bytes(nn, n, nlen)
	bignum_from_bytes(ee, e, elen)
	bignum_from_bytes(ss, sig, siglen)
	int ok = 0
	if (bignum_cmp(ss, nn) < 0):
		bignum_modexp(mm, ss, ee, nn)
		bignum_to_bytes(mm, out, k)
		ok = 1
	bignum_free(nn)
	bignum_free(ee)
	bignum_free(ss)
	bignum_free(mm)
	return ok


# ---- PKCS#1 v1.5 ------------------------------------------------------------

# Verify an RSASSA-PKCS1-v1_5 signature with a strict, full-length comparison of
# the encoded message (no lenient DigestInfo parsing). digest is the raw hash
# for the selected algorithm. Returns 1 if valid, 0 otherwise.
int rsa_pkcs1v15_verify(char* n, int nlen, char* e, int elen, char* sig, int siglen, char* digest, int hash_alg):
	int k = nlen
	char* prefix = rsa_digestinfo_sha256()
	int diglen = 32
	if (hash_alg == RSA_HASH_SHA384()):
		prefix = rsa_digestinfo_sha384()
		diglen = 48
	int prefixlen = RSA_DIGESTINFO_LEN()
	int tlen = prefixlen + diglen
	# PKCS#1 v1.5 requires at least 8 bytes of 0xFF padding.
	if (k < tlen + 11):
		return 0
	char* em = malloc(k)
	if (rsa_recover(n, nlen, e, elen, sig, siglen, em, k) == 0):
		free(em)
		return 0
	# Build the expected EM: 0x00 0x01 PS(0xFF..) 0x00 prefix digest.
	char* want = malloc(k)
	want[0] = 0
	want[1] = 1
	int pslen = k - tlen - 3
	int i = 0
	while (i < pslen):
		want[2 + i] = 255
		i = i + 1
	int pos = 2 + pslen
	want[pos] = 0
	pos = pos + 1
	i = 0
	while (i < prefixlen):
		want[pos + i] = prefix[i]
		i = i + 1
	pos = pos + prefixlen
	i = 0
	while (i < diglen):
		want[pos + i] = digest[i]
		i = i + 1
	# Strict full comparison.
	int match = 1
	i = 0
	while (i < k):
		if ((em[i] & 255) != (want[i] & 255)):
			match = 0
		i = i + 1
	free(em)
	free(want)
	return match


int rsa_pkcs1v15_verify_sha256(char* n, int nlen, char* e, int elen, char* sig, int siglen, char* digest):
	return rsa_pkcs1v15_verify(n, nlen, e, elen, sig, siglen, digest, RSA_HASH_SHA256())


int rsa_pkcs1v15_verify_sha384(char* n, int nlen, char* e, int elen, char* sig, int siglen, char* digest):
	return rsa_pkcs1v15_verify(n, nlen, e, elen, sig, siglen, digest, RSA_HASH_SHA384())


# ---- MGF1 (SHA-256) ---------------------------------------------------------

# out[0 .. mask_len) = MGF1(seed, mask_len) with SHA-256.
void mgf1_sha256(char* seed, int seedlen, int mask_len, char* out):
	char* buf = malloc(seedlen + 4)
	int i = 0
	while (i < seedlen):
		buf[i] = seed[i]
		i = i + 1
	char* dig = malloc(32)
	int counter = 0
	int outpos = 0
	while (outpos < mask_len):
		buf[seedlen] = (counter >> 24) & 255
		buf[seedlen + 1] = (counter >> 16) & 255
		buf[seedlen + 2] = (counter >> 8) & 255
		buf[seedlen + 3] = counter & 255
		sha256(buf, seedlen + 4, dig)
		int take = 32
		if (mask_len - outpos < 32):
			take = mask_len - outpos
		int j = 0
		while (j < take):
			out[outpos + j] = dig[j]
			j = j + 1
		outpos = outpos + 32
		counter = counter + 1
	free(buf)
	free(dig)


# ---- PSS (SHA-256, sLen = hLen = 32) ----------------------------------------

# Verify an RSASSA-PSS signature (EMSA-PSS-VERIFY, RFC 8017 9.1.2) with SHA-256,
# MGF1-SHA256, and salt length equal to the hash length. mhash is the 32-byte
# message digest. Returns 1 if valid, 0 otherwise.
int rsa_pss_verify_sha256(char* n, int nlen, char* e, int elen, char* sig, int siglen, char* mhash):
	int hlen = 32
	int slen = 32
	int k = nlen
	bignum* nn = bignum_new()
	bignum_from_bytes(nn, n, nlen)
	int modbits = bignum_bit_length(nn)
	bignum_free(nn)
	int embits = modbits - 1
	int emlen = (embits + 7) / 8
	# Consistency: EM must hold PS(>=0) 0x01 salt H 0xbc.
	if (emlen < hlen + slen + 2):
		return 0
	char* em = malloc(k)
	if (rsa_recover(n, nlen, e, elen, sig, siglen, em, k) == 0):
		free(em)
		return 0
	# rsa_recover writes k bytes; when emlen < k (modbits % 8 == 1) the leading
	# byte is zero and EM is the trailing emlen bytes.
	char* emp = em + (k - emlen)
	int result = 0
	int ok = 1
	# Trailer byte must be 0xbc.
	if ((emp[emlen - 1] & 255) != 188):
		ok = 0
	int dblen = emlen - hlen - 1
	# Top (8*emlen - embits) bits of the leading maskedDB byte must be zero.
	int topbits = 8 * emlen - embits
	int topmask = 255 >> topbits            # keep the low (8-topbits) bits
	if (ok != 0):
		if (((emp[0] & 255) & ~topmask) != 0):
			ok = 0
	char* db = malloc(dblen)
	char* h = malloc(hlen)
	char* dbmask = malloc(dblen)
	char* mprime = malloc(8 + hlen + slen)
	char* hprime = malloc(hlen)
	if (ok != 0):
		int i = 0
		while (i < hlen):
			h[i] = emp[dblen + i]
			i = i + 1
		mgf1_sha256(h, hlen, dblen, dbmask)
		i = 0
		while (i < dblen):
			db[i] = (emp[i] & 255) ^ (dbmask[i] & 255)
			i = i + 1
		# Clear the top bits of DB[0] that were forced to zero at encode time.
		db[0] = db[0] & topmask
		# DB must be PS(zeros) || 0x01 || salt.
		int pslen = dblen - slen - 1
		i = 0
		while (i < pslen):
			if ((db[i] & 255) != 0):
				ok = 0
			i = i + 1
		if ((db[pslen] & 255) != 1):
			ok = 0
	if (ok != 0):
		# M' = (0x00)*8 || mHash || salt ; salt = last slen bytes of DB.
		int i = 0
		while (i < 8):
			mprime[i] = 0
			i = i + 1
		i = 0
		while (i < hlen):
			mprime[8 + i] = mhash[i]
			i = i + 1
		int saltpos = dblen - slen
		i = 0
		while (i < slen):
			mprime[8 + hlen + i] = db[saltpos + i]
			i = i + 1
		sha256(mprime, 8 + hlen + slen, hprime)
		int eqv = 1
		i = 0
		while (i < hlen):
			if ((hprime[i] & 255) != (h[i] & 255)):
				eqv = 0
			i = i + 1
		if (eqv != 0):
			result = 1
	free(em)
	free(db)
	free(h)
	free(dbmask)
	free(mprime)
	free(hprime)
	return result
