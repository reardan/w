# X.509 certificate handling for the pure-W HTTPS stack (issue #199, part of
# #155): DER certificate parsing, PEM decoding, trust store loading, chain
# building + signature verification, RFC 6125 hostname matching, and EC
# private-key loading for the TLS server role. Built on net/asn1.w and the
# wave-1 crypto modules (sha2, base64, rsa_verify, ecdsa_p256).
#
# Public API (everything the TLS client/server roles need):
#   x509_cert* x509_parse(char* der, int len)             owned copy; 0 on error
#   void x509_cert_free(x509_cert* c)
#   list[pem_block*] pem_decode_blocks(char* text, int len, char* label)
#   void pem_blocks_free(list[pem_block*] blocks)
#   list[x509_cert*] pem_decode_certs(char* text, int len, int* out_skipped)
#   x509_trust_store* x509_store_new()
#   void x509_store_add(x509_trust_store* s, x509_cert* c)      takes ownership
#   int x509_store_add_pem_file(x509_trust_store* s, char* path)  count added
#   x509_trust_store* x509_load_trust_store(char* override_path)  0 on failure
#   void x509_store_free(x509_trust_store* s)
#   int x509_verify_chain(x509_cert* leaf, list[x509_cert*] extra,
#                         x509_trust_store* store, char* hostname,
#                         int now_unix, char** err_out)           1/0
#   int x509_match_hostname(x509_cert* c, char* hostname)         1/0
#   int x509_hostname_matches_pattern(char* pattern, char* hostname)
#   int x509_load_ec_private_key(char* pem_text, int len, char* out_d32)
#   int x509_ecdsa_sig_to_raw(char* sig, int len, char* out_r, char* out_s)
#
# Security posture (plan 11): fail closed everywhere. Any DER structure this
# module does not understand rejects the certificate, except that an unknown
# signature/public-key ALGORITHM is carried as "unsupported" so trust bundles
# containing exotic roots still load — using such a key or algorithm in a
# chain fails verification. Unknown non-critical extensions are ignored;
# unknown CRITICAL extensions reject the certificate. Error strings are
# static constants and never echo certificate or key material. The library
# never reads the clock: callers pass `now` as a unix timestamp (lib/time.w
# has helpers), and validity instants are stored as (day, second) pairs so
# notAfter dates past 2038 survive 32-bit arithmetic.
import lib.lib
import lib.memory
import lib.file
import lib.env
import lib.container
import libs.standard.crypto.sha2
import libs.standard.crypto.base64
import libs.standard.crypto.rsa_verify
import libs.standard.crypto.ecdsa_p256
import libs.standard.net.asn1


# ---- constants ----------------------------------------------------------------

# Largest certificate we will parse (DER bytes).
int X509_MAX_CERT_LEN():
	return 1048576


# Longest chain x509_verify_chain will build: leaf + 5 intermediates.
int X509_MAX_CHAIN_LEN():
	return 6


int X509_KEY_UNSUPPORTED():
	return 0


int X509_KEY_RSA():
	return 1


int X509_KEY_EC_P256():
	return 2


int X509_SIGALG_UNKNOWN():
	return 0


int X509_SIGALG_RSA_SHA256():
	return 1


int X509_SIGALG_RSA_SHA384():
	return 2


int X509_SIGALG_RSA_PSS_SHA256():
	return 3


int X509_SIGALG_RSA_PSS_SHA384():
	return 4


int X509_SIGALG_ECDSA_SHA256():
	return 5


int X509_SIGALG_ECDSA_SHA384():
	return 6


# keyUsage bits (RFC 5280 bit i maps to 1 << i here).
int X509_KU_DIGITAL_SIGNATURE():
	return 1


int X509_KU_KEY_CERT_SIGN():
	return 32


# ---- OID content bytes ----------------------------------------------------------

char* x509_oid_rsa_encryption():
	return c"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01"


char* x509_oid_sha256_rsa():
	return c"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0b"


char* x509_oid_sha384_rsa():
	return c"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0c"


char* x509_oid_rsassa_pss():
	return c"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0a"


char* x509_oid_mgf1():
	return c"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x08"


char* x509_oid_sha256():
	return c"\x60\x86\x48\x01\x65\x03\x04\x02\x01"


char* x509_oid_sha384():
	return c"\x60\x86\x48\x01\x65\x03\x04\x02\x02"


char* x509_oid_ec_public_key():
	return c"\x2a\x86\x48\xce\x3d\x02\x01"


char* x509_oid_prime256v1():
	return c"\x2a\x86\x48\xce\x3d\x03\x01\x07"


char* x509_oid_ecdsa_sha256():
	return c"\x2a\x86\x48\xce\x3d\x04\x03\x02"


char* x509_oid_ecdsa_sha384():
	return c"\x2a\x86\x48\xce\x3d\x04\x03\x03"


char* x509_oid_basic_constraints():
	return c"\x55\x1d\x13"


char* x509_oid_key_usage():
	return c"\x55\x1d\x0f"


char* x509_oid_ext_key_usage():
	return c"\x55\x1d\x25"


char* x509_oid_subject_alt_name():
	return c"\x55\x1d\x11"


char* x509_oid_server_auth():
	return c"\x2b\x06\x01\x05\x05\x07\x03\x01"


# Does the element at (start, len) in data equal the OID constant `oid`?
int x509_oid_is(char* data, int start, int len, char* oid):
	return asn1_bytes_equal(data, start, len, oid, strlen(oid))


# ---- certificate object -----------------------------------------------------------

# Offsets index into the owned `der` copy; spans marked "TLV" include the
# tag and length bytes, spans marked "content" do not.
struct x509_cert:
	char* der                 # owned copy of the certificate DER
	int der_len
	int tbs_start             # tbsCertificate TLV (what the signature covers)
	int tbs_len
	int version               # 1, 2 or 3
	int serial_start          # serialNumber content bytes
	int serial_len
	int sig_alg               # X509_SIGALG_* of signatureAlgorithm
	int issuer_start          # issuer Name TLV
	int issuer_len
	int subject_start         # subject Name TLV
	int subject_len
	int nb_day                # notBefore as (days since epoch, seconds in day)
	int nb_sec
	int na_day                # notAfter
	int na_sec
	int key_type              # X509_KEY_*
	int rsa_n_start           # RSA modulus content, sign byte stripped
	int rsa_n_len
	int rsa_e_start           # RSA public exponent content
	int rsa_e_len
	char* ec_qx               # 32-byte P-256 coords (malloc'd) when EC_P256
	char* ec_qy
	int sig_start             # signatureValue content (BIT STRING payload)
	int sig_len
	int has_basic_constraints
	int is_ca
	int path_len              # pathLenConstraint, -1 when absent
	int has_key_usage
	int key_usage             # X509_KU_* bit mask
	int has_eku
	int eku_server_auth
	int san_present
	list[char*] san_dns       # SAN dNSName entries (malloc'd strings)


void x509_cert_free(x509_cert* c):
	if (c == 0):
		return
	if (c.der != 0):
		free(c.der)
	if (c.ec_qx != 0):
		free(c.ec_qx)
	if (c.ec_qy != 0):
		free(c.ec_qy)
	int i = 0
	while (i < c.san_dns.length):
		free(c.san_dns[i])
		i = i + 1
	list_free[char*](c.san_dns)
	free(cast(char*, c))


# ---- date handling -------------------------------------------------------------

# Days since 1970-01-01 for a proleptic-Gregorian date (Hinnant's
# days-from-civil; exact for every year this module accepts).
int x509_days_from_civil(int y, int m, int d):
	if (m <= 2):
		y = y - 1
	int era = y / 400
	int yoe = y - era * 400
	int mp = m + 9
	if (m > 2):
		mp = m - 3
	int doy = (153 * mp + 2) / 5 + d - 1
	int doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468


int x509_days_in_month(int y, int m):
	if (m == 2):
		int leap = 0
		if (y % 4 == 0):
			leap = 1
		if (y % 100 == 0):
			leap = 0
		if (y % 400 == 0):
			leap = 1
		return 28 + leap
	if ((m == 4) | (m == 6) | (m == 9) | (m == 11)):
		return 30
	return 31


# Split a non-negative unix timestamp into (days since epoch, seconds in day).
void x509_unix_to_day_sec(int unix_time, int* out_day, int* out_sec):
	*out_day = unix_time / 86400
	*out_sec = unix_time % 86400


int x509_two_digits(char* data, int start):
	int a = data[start] & 255
	int b = data[start + 1] & 255
	if ((a < '0') | (a > '9')):
		return -1
	if ((b < '0') | (b > '9')):
		return -1
	return (a - '0') * 10 + (b - '0')


# Parse an RFC 5280 Time (UTCTime YYMMDDHHMMSSZ or GeneralizedTime
# YYYYMMDDHHMMSSZ, both mandatory-Z, no fractional seconds) into a
# (day, second) pair. Returns 1/0.
int x509_parse_time(char* data, int start, int len, int tag, int* out_day, int* out_sec):
	int year = 0
	int p = start
	if (tag == ASN1_UTCTIME()):
		if (len != 13):
			return 0
		int yy = x509_two_digits(data, p)
		if (yy < 0):
			return 0
		year = 2000 + yy
		if (yy >= 50):
			year = 1900 + yy
		p = p + 2
	else if (tag == ASN1_GENERALIZEDTIME()):
		if (len != 15):
			return 0
		int hi = x509_two_digits(data, p)
		int lo = x509_two_digits(data, p + 2)
		if ((hi < 0) | (lo < 0)):
			return 0
		year = hi * 100 + lo
		p = p + 4
	else:
		return 0
	if ((data[start + len - 1] & 255) != 'Z'):
		return 0
	int month = x509_two_digits(data, p)
	int day = x509_two_digits(data, p + 2)
	int hour = x509_two_digits(data, p + 4)
	int minute = x509_two_digits(data, p + 6)
	int second = x509_two_digits(data, p + 8)
	if ((month < 1) | (month > 12)):
		return 0
	if (day < 1):
		return 0
	if (day > x509_days_in_month(year, month)):
		return 0
	if ((hour < 0) | (hour > 23)):
		return 0
	if ((minute < 0) | (minute > 59)):
		return 0
	if ((second < 0) | (second > 59)):
		return 0
	*out_day = x509_days_from_civil(year, month, day)
	*out_sec = hour * 3600 + minute * 60 + second
	return 1


# -1 / 0 / 1 comparison of two (day, second) instants.
int x509_cmp_day_sec(int d1, int s1, int d2, int s2):
	if (d1 < d2):
		return -1
	if (d1 > d2):
		return 1
	if (s1 < s2):
		return -1
	if (s1 > s2):
		return 1
	return 0


# 0 = valid at (day, sec); 1 = not yet valid; 2 = expired.
int x509_time_status(x509_cert* c, int day, int sec):
	if (x509_cmp_day_sec(day, sec, c.nb_day, c.nb_sec) < 0):
		return 1
	if (x509_cmp_day_sec(day, sec, c.na_day, c.na_sec) > 0):
		return 2
	return 0


# ---- AlgorithmIdentifier -----------------------------------------------------------

# Parse the hash AlgorithmIdentifier inside PSS parameters: OID sha256 or
# sha384 with absent-or-NULL parameters. Returns 32, 48, or 0.
int x509_parse_pss_hash(char* data, int start, int len):
	asn1 a
	asn1_init(&a, data, start, start + len)
	int os = 0
	int ol = 0
	if (asn1_expect(&a, ASN1_OID(), &os, &ol) == 0):
		return 0
	int hlen = 0
	if (x509_oid_is(data, os, ol, x509_oid_sha256()) != 0):
		hlen = 32
	else if (x509_oid_is(data, os, ol, x509_oid_sha384()) != 0):
		hlen = 48
	else:
		return 0
	if (asn1_done(&a) == 0):
		int ns = 0
		int nl = 0
		if (asn1_expect(&a, ASN1_NULL(), &ns, &nl) == 0):
			return 0
		if (nl != 0):
			return 0
		if (asn1_done(&a) == 0):
			return 0
	return hlen


# Parse RSASSA-PSS-params (RFC 8017 A.2.3). Only the two shapes the TLS
# certificate profile uses are supported: SHA-256/MGF1-SHA256/salt 32 and
# SHA-384/MGF1-SHA384/salt 48, explicit fields, trailer 1. Anything else
# comes back X509_SIGALG_UNKNOWN (which verification rejects).
int x509_parse_pss_params(char* data, int start, int len):
	asn1 p
	asn1_init(&p, data, start, start + len)
	int s = 0
	int l = 0
	# [0] hashAlgorithm (required here: the sha1 default is unsupported)
	if (asn1_expect(&p, ASN1_CONTEXT(0), &s, &l) == 0):
		return X509_SIGALG_UNKNOWN()
	int hlen = 0
	asn1 h
	asn1_init(&h, data, s, s + l)
	int hs = 0
	int hl = 0
	if (asn1_expect(&h, ASN1_SEQUENCE(), &hs, &hl) == 0):
		return X509_SIGALG_UNKNOWN()
	if (asn1_done(&h) == 0):
		return X509_SIGALG_UNKNOWN()
	hlen = x509_parse_pss_hash(data, hs, hl)
	if (hlen == 0):
		return X509_SIGALG_UNKNOWN()
	# [1] maskGenAlgorithm: MGF1 with the same hash
	if (asn1_expect(&p, ASN1_CONTEXT(1), &s, &l) == 0):
		return X509_SIGALG_UNKNOWN()
	asn1 m
	asn1_init(&m, data, s, s + l)
	int ms = 0
	int ml = 0
	if (asn1_expect(&m, ASN1_SEQUENCE(), &ms, &ml) == 0):
		return X509_SIGALG_UNKNOWN()
	if (asn1_done(&m) == 0):
		return X509_SIGALG_UNKNOWN()
	asn1 mi
	asn1_init(&mi, data, ms, ms + ml)
	int os = 0
	int ol = 0
	if (asn1_expect(&mi, ASN1_OID(), &os, &ol) == 0):
		return X509_SIGALG_UNKNOWN()
	if (x509_oid_is(data, os, ol, x509_oid_mgf1()) == 0):
		return X509_SIGALG_UNKNOWN()
	if (asn1_expect(&mi, ASN1_SEQUENCE(), &ms, &ml) == 0):
		return X509_SIGALG_UNKNOWN()
	if (asn1_done(&mi) == 0):
		return X509_SIGALG_UNKNOWN()
	if (x509_parse_pss_hash(data, ms, ml) != hlen):
		return X509_SIGALG_UNKNOWN()
	# [2] saltLength: must equal the hash length
	if (asn1_expect(&p, ASN1_CONTEXT(2), &s, &l) == 0):
		return X509_SIGALG_UNKNOWN()
	asn1 sl
	asn1_init(&sl, data, s, s + l)
	int salt = 0
	if (asn1_read_small_int(&sl, &salt) == 0):
		return X509_SIGALG_UNKNOWN()
	if (asn1_done(&sl) == 0):
		return X509_SIGALG_UNKNOWN()
	if (salt != hlen):
		return X509_SIGALG_UNKNOWN()
	# [3] trailerField: absent or 1
	if (asn1_done(&p) == 0):
		if (asn1_expect(&p, ASN1_CONTEXT(3), &s, &l) == 0):
			return X509_SIGALG_UNKNOWN()
		asn1 t
		asn1_init(&t, data, s, s + l)
		int trailer = 0
		if (asn1_read_small_int(&t, &trailer) == 0):
			return X509_SIGALG_UNKNOWN()
		if (asn1_done(&t) == 0):
			return X509_SIGALG_UNKNOWN()
		if (trailer != 1):
			return X509_SIGALG_UNKNOWN()
		if (asn1_done(&p) == 0):
			return X509_SIGALG_UNKNOWN()
	if (hlen == 48):
		return X509_SIGALG_RSA_PSS_SHA384()
	return X509_SIGALG_RSA_PSS_SHA256()


# Read a signature AlgorithmIdentifier. The TLV span (tag byte through end)
# comes back in out_tlv_start/out_tlv_end so the two copies in a certificate
# can be compared byte for byte; the classified algorithm (or
# X509_SIGALG_UNKNOWN for anything unsupported) in out_alg. Returns 1 as
# long as the outer structure is well-formed DER, 0 otherwise.
int x509_parse_sig_algorithm(asn1* r, int* out_alg, int* out_tlv_start, int* out_tlv_end):
	int hdr = r.pos
	int s = 0
	int l = 0
	if (asn1_expect(r, ASN1_SEQUENCE(), &s, &l) == 0):
		return 0
	*out_tlv_start = hdr
	*out_tlv_end = s + l
	asn1 a
	asn1_init(&a, r.data, s, s + l)
	int os = 0
	int ol = 0
	if (asn1_expect(&a, ASN1_OID(), &os, &ol) == 0):
		return 0
	int alg = X509_SIGALG_UNKNOWN()
	int want_null_params = 0
	if (x509_oid_is(r.data, os, ol, x509_oid_sha256_rsa()) != 0):
		alg = X509_SIGALG_RSA_SHA256()
		want_null_params = 1
	else if (x509_oid_is(r.data, os, ol, x509_oid_sha384_rsa()) != 0):
		alg = X509_SIGALG_RSA_SHA384()
		want_null_params = 1
	else if (x509_oid_is(r.data, os, ol, x509_oid_ecdsa_sha256()) != 0):
		alg = X509_SIGALG_ECDSA_SHA256()
	else if (x509_oid_is(r.data, os, ol, x509_oid_ecdsa_sha384()) != 0):
		alg = X509_SIGALG_ECDSA_SHA384()
	else if (x509_oid_is(r.data, os, ol, x509_oid_rsassa_pss()) != 0):
		int ps = 0
		int pl = 0
		if (asn1_expect(&a, ASN1_SEQUENCE(), &ps, &pl) == 0):
			return 0
		if (asn1_done(&a) == 0):
			return 0
		*out_alg = x509_parse_pss_params(r.data, ps, pl)
		return 1
	else:
		# Unknown algorithm: structurally skip any parameters.
		while (asn1_done(&a) == 0):
			if (asn1_skip(&a) == 0):
				return 0
		*out_alg = X509_SIGALG_UNKNOWN()
		return 1
	if (want_null_params != 0):
		# RSA algorithms carry explicit NULL parameters (absent tolerated).
		if (asn1_done(&a) == 0):
			int ns = 0
			int nl = 0
			if (asn1_expect(&a, ASN1_NULL(), &ns, &nl) == 0):
				return 0
			if (nl != 0):
				return 0
	# ECDSA algorithms: parameters MUST be absent (RFC 5758).
	if (asn1_done(&a) == 0):
		return 0
	*out_alg = alg
	return 1


# ---- SubjectPublicKeyInfo -----------------------------------------------------------

# Parse the SPKI at reader position into the cert. Structure must be valid;
# an unrecognized algorithm leaves key_type = X509_KEY_UNSUPPORTED. Returns 1/0.
int x509_parse_spki(asn1* r, x509_cert* c):
	int s = 0
	int l = 0
	if (asn1_expect(r, ASN1_SEQUENCE(), &s, &l) == 0):
		return 0
	asn1 spki
	asn1_init(&spki, r.data, s, s + l)
	int als = 0
	int all = 0
	if (asn1_expect(&spki, ASN1_SEQUENCE(), &als, &all) == 0):
		return 0
	asn1 alg
	asn1_init(&alg, r.data, als, als + all)
	int os = 0
	int ol = 0
	if (asn1_expect(&alg, ASN1_OID(), &os, &ol) == 0):
		return 0
	int kind = X509_KEY_UNSUPPORTED()
	if (x509_oid_is(r.data, os, ol, x509_oid_rsa_encryption()) != 0):
		kind = X509_KEY_RSA()
		# rsaEncryption parameters: NULL (absent tolerated).
		if (asn1_done(&alg) == 0):
			int ns = 0
			int nl = 0
			if (asn1_expect(&alg, ASN1_NULL(), &ns, &nl) == 0):
				return 0
			if (nl != 0):
				return 0
			if (asn1_done(&alg) == 0):
				return 0
	else if (x509_oid_is(r.data, os, ol, x509_oid_ec_public_key()) != 0):
		# Named-curve parameters; only P-256 is supported, other curves
		# degrade to an unsupported key.
		int cs = 0
		int cl = 0
		if (asn1_expect(&alg, ASN1_OID(), &cs, &cl) == 0):
			return 0
		if (asn1_done(&alg) == 0):
			return 0
		if (x509_oid_is(r.data, cs, cl, x509_oid_prime256v1()) != 0):
			kind = X509_KEY_EC_P256()
	else:
		while (asn1_done(&alg) == 0):
			if (asn1_skip(&alg) == 0):
				return 0
	int ks = 0
	int kl = 0
	if (asn1_read_bitstring_bytes(&spki, &ks, &kl) == 0):
		return 0
	if (asn1_done(&spki) == 0):
		return 0
	if (kind == X509_KEY_RSA()):
		asn1 rk
		asn1_init(&rk, r.data, ks, ks + kl)
		int rs = 0
		int rl = 0
		if (asn1_expect(&rk, ASN1_SEQUENCE(), &rs, &rl) == 0):
			return 0
		if (asn1_done(&rk) == 0):
			return 0
		asn1 nums
		asn1_init(&nums, r.data, rs, rs + rl)
		int ns = 0
		int nl = 0
		if (asn1_read_positive_integer(&nums, &ns, &nl) == 0):
			return 0
		int es = 0
		int el = 0
		if (asn1_read_positive_integer(&nums, &es, &el) == 0):
			return 0
		if (asn1_done(&nums) == 0):
			return 0
		# Modulus between 512 and 4096 bits (bignum headroom is 8400 bits
		# for products), exponent at most 64 bits.
		if ((nl < 64) | (nl > 512)):
			return 0
		if (el > 8):
			return 0
		c.key_type = X509_KEY_RSA()
		c.rsa_n_start = ns
		c.rsa_n_len = nl
		c.rsa_e_start = es
		c.rsa_e_len = el
	else if (kind == X509_KEY_EC_P256()):
		# Uncompressed point only: 0x04 || X(32) || Y(32).
		if (kl != 65):
			return 0
		if ((r.data[ks] & 255) != 4):
			return 0
		c.ec_qx = malloc(32)
		c.ec_qy = malloc(32)
		int i = 0
		while (i < 32):
			c.ec_qx[i] = r.data[ks + 1 + i]
			c.ec_qy[i] = r.data[ks + 33 + i]
			i = i + 1
		c.key_type = X509_KEY_EC_P256()
	else:
		c.key_type = X509_KEY_UNSUPPORTED()
	return 1


# ---- extensions ------------------------------------------------------------------

int x509_parse_ext_basic_constraints(x509_cert* c, char* data, int start, int len):
	if (c.has_basic_constraints != 0):
		return 0    # duplicate extension
	asn1 r
	asn1_init(&r, data, start, start + len)
	int s = 0
	int l = 0
	if (asn1_expect(&r, ASN1_SEQUENCE(), &s, &l) == 0):
		return 0
	if (asn1_done(&r) == 0):
		return 0
	asn1 b
	asn1_init(&b, data, s, s + l)
	int ca = 0
	if (asn1_peek(&b) == ASN1_BOOLEAN()):
		if (asn1_read_boolean(&b, &ca) == 0):
			return 0
	int plen = -1
	if (asn1_peek(&b) == ASN1_INTEGER()):
		if (asn1_read_small_int(&b, &plen) == 0):
			return 0
		if (plen < 0):
			return 0
	if (asn1_done(&b) == 0):
		return 0
	c.has_basic_constraints = 1
	c.is_ca = ca
	c.path_len = plen
	return 1


int x509_parse_ext_key_usage(x509_cert* c, char* data, int start, int len):
	if (c.has_key_usage != 0):
		return 0
	asn1 r
	asn1_init(&r, data, start, start + len)
	int s = 0
	int l = 0
	if (asn1_expect(&r, ASN1_BIT_STRING(), &s, &l) == 0):
		return 0
	if (asn1_done(&r) == 0):
		return 0
	if (l < 1):
		return 0
	int unused = data[s] & 255
	if (unused > 7):
		return 0
	if (l == 1):
		if (unused != 0):
			return 0
	int nbits = (l - 1) * 8 - unused
	if (nbits > 9):
		nbits = 9    # decipherOnly (bit 8) is the last defined bit
	int ku = 0
	int i = 0
	while (i < nbits):
		int b = (data[s + 1 + i / 8] >> (7 - i % 8)) & 1
		if (b != 0):
			ku = ku | (1 << i)
		i = i + 1
	c.has_key_usage = 1
	c.key_usage = ku
	return 1


int x509_parse_ext_eku(x509_cert* c, char* data, int start, int len):
	if (c.has_eku != 0):
		return 0
	asn1 r
	asn1_init(&r, data, start, start + len)
	int s = 0
	int l = 0
	if (asn1_expect(&r, ASN1_SEQUENCE(), &s, &l) == 0):
		return 0
	if (asn1_done(&r) == 0):
		return 0
	asn1 e
	asn1_init(&e, data, s, s + l)
	int count = 0
	while (asn1_done(&e) == 0):
		int os = 0
		int ol = 0
		if (asn1_expect(&e, ASN1_OID(), &os, &ol) == 0):
			return 0
		if (x509_oid_is(data, os, ol, x509_oid_server_auth()) != 0):
			c.eku_server_auth = 1
		count = count + 1
	if (count == 0):
		return 0
	c.has_eku = 1
	return 1


# A SAN dNSName must be non-empty printable ASCII (no NULs, no controls).
int x509_valid_dns_name_bytes(char* data, int start, int len):
	if (len < 1):
		return 0
	if (len > 253):
		return 0
	int i = 0
	while (i < len):
		int ch = data[start + i] & 255
		if ((ch < 33) | (ch > 126)):
			return 0
		i = i + 1
	return 1


int x509_parse_ext_san(x509_cert* c, char* data, int start, int len):
	if (c.san_present != 0):
		return 0
	asn1 r
	asn1_init(&r, data, start, start + len)
	int s = 0
	int l = 0
	if (asn1_expect(&r, ASN1_SEQUENCE(), &s, &l) == 0):
		return 0
	if (asn1_done(&r) == 0):
		return 0
	asn1 g
	asn1_init(&g, data, s, s + l)
	int count = 0
	while (asn1_done(&g) == 0):
		int tag = 0
		int gs = 0
		int gl = 0
		if (asn1_next(&g, &tag, &gs, &gl) == 0):
			return 0
		if (tag == ASN1_CONTEXT_PRIMITIVE(2)):
			# dNSName IA5String
			if (x509_valid_dns_name_bytes(data, gs, gl) == 0):
				return 0
			char* name = malloc(gl + 1)
			int i = 0
			while (i < gl):
				name[i] = data[gs + i]
				i = i + 1
			name[gl] = 0
			c.san_dns.push(name)
		count = count + 1
	if (count == 0):
		return 0
	c.san_present = 1
	return 1


# Parse the Extensions SEQUENCE content. Returns 1/0.
int x509_parse_extensions(x509_cert* c, char* data, int start, int len):
	asn1 exts
	asn1_init(&exts, data, start, start + len)
	int count = 0
	while (asn1_done(&exts) == 0):
		int es = 0
		int el = 0
		if (asn1_expect(&exts, ASN1_SEQUENCE(), &es, &el) == 0):
			return 0
		asn1 e
		asn1_init(&e, data, es, es + el)
		int os = 0
		int ol = 0
		if (asn1_expect(&e, ASN1_OID(), &os, &ol) == 0):
			return 0
		int critical = 0
		if (asn1_peek(&e) == ASN1_BOOLEAN()):
			if (asn1_read_boolean(&e, &critical) == 0):
				return 0
		int vs = 0
		int vl = 0
		if (asn1_expect(&e, ASN1_OCTET_STRING(), &vs, &vl) == 0):
			return 0
		if (asn1_done(&e) == 0):
			return 0
		if (x509_oid_is(data, os, ol, x509_oid_basic_constraints()) != 0):
			if (x509_parse_ext_basic_constraints(c, data, vs, vl) == 0):
				return 0
		else if (x509_oid_is(data, os, ol, x509_oid_key_usage()) != 0):
			if (x509_parse_ext_key_usage(c, data, vs, vl) == 0):
				return 0
		else if (x509_oid_is(data, os, ol, x509_oid_ext_key_usage()) != 0):
			if (x509_parse_ext_eku(c, data, vs, vl) == 0):
				return 0
		else if (x509_oid_is(data, os, ol, x509_oid_subject_alt_name()) != 0):
			if (x509_parse_ext_san(c, data, vs, vl) == 0):
				return 0
		else:
			# Unknown extension: fatal when critical, ignored otherwise.
			if (critical != 0):
				return 0
		count = count + 1
	if (count == 0):
		return 0
	return 1


# ---- certificate parsing ------------------------------------------------------------

# Internal: parse the owned DER in c. Returns 1/0 (caller frees c on 0).
int x509_parse_into(x509_cert* c):
	char* d = c.der
	asn1 top
	asn1_init(&top, d, 0, c.der_len)
	int cs = 0
	int cl = 0
	if (asn1_expect(&top, ASN1_SEQUENCE(), &cs, &cl) == 0):
		return 0
	if (asn1_done(&top) == 0):
		return 0    # trailing garbage after the certificate
	asn1 cert
	asn1_init(&cert, d, cs, cs + cl)

	# tbsCertificate (record the full TLV span: it is what the CA signed)
	int tbs_hdr = cert.pos
	int ts = 0
	int tl = 0
	if (asn1_expect(&cert, ASN1_SEQUENCE(), &ts, &tl) == 0):
		return 0
	c.tbs_start = tbs_hdr
	c.tbs_len = (ts + tl) - tbs_hdr

	# signatureAlgorithm
	int outer_alg = 0
	int oas = 0
	int oae = 0
	if (x509_parse_sig_algorithm(&cert, &outer_alg, &oas, &oae) == 0):
		return 0

	# signatureValue
	int ss = 0
	int sl = 0
	if (asn1_read_bitstring_bytes(&cert, &ss, &sl) == 0):
		return 0
	if (sl < 1):
		return 0
	c.sig_start = ss
	c.sig_len = sl
	if (asn1_done(&cert) == 0):
		return 0

	# ---- inside tbsCertificate ----
	asn1 tbs
	asn1_init(&tbs, d, ts, ts + tl)

	# [0] EXPLICIT version (absent = v1)
	c.version = 1
	if (asn1_peek(&tbs) == ASN1_CONTEXT(0)):
		int vs = 0
		int vl = 0
		if (asn1_expect(&tbs, ASN1_CONTEXT(0), &vs, &vl) == 0):
			return 0
		asn1 v
		asn1_init(&v, d, vs, vs + vl)
		int vers = 0
		if (asn1_read_small_int(&v, &vers) == 0):
			return 0
		if (asn1_done(&v) == 0):
			return 0
		if ((vers < 0) | (vers > 2)):
			return 0
		c.version = vers + 1

	# serialNumber (raw content; RFC 5280 caps the encoding at 20 octets,
	# plus a possible sign byte)
	int sns = 0
	int snl = 0
	if (asn1_read_integer(&tbs, &sns, &snl) == 0):
		return 0
	if ((snl < 1) | (snl > 21)):
		return 0
	c.serial_start = sns
	c.serial_len = snl

	# signature AlgorithmIdentifier (must byte-match the outer one)
	int tbs_alg = 0
	int tas = 0
	int tae = 0
	if (x509_parse_sig_algorithm(&tbs, &tbs_alg, &tas, &tae) == 0):
		return 0
	if ((oae - oas) != (tae - tas)):
		return 0
	int i = 0
	while (i < oae - oas):
		if ((d[oas + i] & 255) != (d[tas + i] & 255)):
			return 0
		i = i + 1
	c.sig_alg = outer_alg

	# issuer Name (raw TLV span)
	int ihdr = tbs.pos
	int is = 0
	int il = 0
	if (asn1_expect(&tbs, ASN1_SEQUENCE(), &is, &il) == 0):
		return 0
	c.issuer_start = ihdr
	c.issuer_len = (is + il) - ihdr

	# validity
	int vds = 0
	int vdl = 0
	if (asn1_expect(&tbs, ASN1_SEQUENCE(), &vds, &vdl) == 0):
		return 0
	asn1 val
	asn1_init(&val, d, vds, vds + vdl)
	int t1tag = 0
	int t1s = 0
	int t1l = 0
	if (asn1_next(&val, &t1tag, &t1s, &t1l) == 0):
		return 0
	int nbd = 0
	int nbs = 0
	if (x509_parse_time(d, t1s, t1l, t1tag, &nbd, &nbs) == 0):
		return 0
	int t2tag = 0
	int t2s = 0
	int t2l = 0
	if (asn1_next(&val, &t2tag, &t2s, &t2l) == 0):
		return 0
	int nad = 0
	int nas = 0
	if (x509_parse_time(d, t2s, t2l, t2tag, &nad, &nas) == 0):
		return 0
	if (asn1_done(&val) == 0):
		return 0
	if (x509_cmp_day_sec(nbd, nbs, nad, nas) > 0):
		return 0
	c.nb_day = nbd
	c.nb_sec = nbs
	c.na_day = nad
	c.na_sec = nas

	# subject Name (raw TLV span)
	int shdr = tbs.pos
	int sjs = 0
	int sjl = 0
	if (asn1_expect(&tbs, ASN1_SEQUENCE(), &sjs, &sjl) == 0):
		return 0
	c.subject_start = shdr
	c.subject_len = (sjs + sjl) - shdr

	# subjectPublicKeyInfo
	if (x509_parse_spki(&tbs, c) == 0):
		return 0

	# optional issuerUniqueID [1] / subjectUniqueID [2] (v2/v3 only)
	if (asn1_peek(&tbs) == ASN1_CONTEXT_PRIMITIVE(1)):
		if (c.version < 2):
			return 0
		if (asn1_skip(&tbs) == 0):
			return 0
	if (asn1_peek(&tbs) == ASN1_CONTEXT_PRIMITIVE(2)):
		if (c.version < 2):
			return 0
		if (asn1_skip(&tbs) == 0):
			return 0

	# [3] EXPLICIT extensions (v3 only)
	if (asn1_peek(&tbs) == ASN1_CONTEXT(3)):
		if (c.version != 3):
			return 0
		int xs = 0
		int xl = 0
		if (asn1_expect(&tbs, ASN1_CONTEXT(3), &xs, &xl) == 0):
			return 0
		asn1 xw
		asn1_init(&xw, d, xs, xs + xl)
		int els = 0
		int ell = 0
		if (asn1_expect(&xw, ASN1_SEQUENCE(), &els, &ell) == 0):
			return 0
		if (asn1_done(&xw) == 0):
			return 0
		if (x509_parse_extensions(c, d, els, ell) == 0):
			return 0

	if (asn1_done(&tbs) == 0):
		return 0
	return 1


# Parse one DER certificate. Makes an owned copy of the input; returns 0 on
# any parse error (fail closed: nothing partially-parsed escapes).
x509_cert* x509_parse(char* der, int len):
	if (der == 0):
		return 0
	if ((len < 1) | (len > X509_MAX_CERT_LEN())):
		return 0
	x509_cert* c = new x509_cert()
	c.der = malloc(len)
	int i = 0
	while (i < len):
		c.der[i] = der[i]
		i = i + 1
	c.der_len = len
	c.tbs_start = 0
	c.tbs_len = 0
	c.version = 0
	c.serial_start = 0
	c.serial_len = 0
	c.sig_alg = X509_SIGALG_UNKNOWN()
	c.issuer_start = 0
	c.issuer_len = 0
	c.subject_start = 0
	c.subject_len = 0
	c.nb_day = 0
	c.nb_sec = 0
	c.na_day = 0
	c.na_sec = 0
	c.key_type = X509_KEY_UNSUPPORTED()
	c.rsa_n_start = 0
	c.rsa_n_len = 0
	c.rsa_e_start = 0
	c.rsa_e_len = 0
	c.ec_qx = 0
	c.ec_qy = 0
	c.sig_start = 0
	c.sig_len = 0
	c.has_basic_constraints = 0
	c.is_ca = 0
	c.path_len = -1
	c.has_key_usage = 0
	c.key_usage = 0
	c.has_eku = 0
	c.eku_server_auth = 0
	c.san_present = 0
	c.san_dns = new list[char*]
	if (x509_parse_into(c) == 0):
		x509_cert_free(c)
		return 0
	return c


# ---- PEM ------------------------------------------------------------------------

struct pem_block:
	char* data    # malloc'd decoded bytes
	int len


void pem_blocks_free(list[pem_block*] blocks):
	if (blocks == 0):
		return
	int i = 0
	while (i < blocks.length):
		pem_block* b = blocks[i]
		free(b.data)
		free(cast(char*, b))
		i = i + 1
	list_free[pem_block*](blocks)


# Does line [start, line_end) equal marker, ignoring trailing CR/spaces/tabs?
int pem_line_is(char* text, int start, int line_end, char* marker):
	int e = line_end
	while (e > start):
		int ch = text[e - 1] & 255
		if ((ch == 13) | (ch == 32) | (ch == 9)):
			e = e - 1
		else:
			break
	int ml = strlen(marker)
	if (e - start != ml):
		return 0
	int i = 0
	while (i < ml):
		if ((text[start + i] & 255) != (marker[i] & 255)):
			return 0
		i = i + 1
	return 1


# Decode every well-formed "-----BEGIN <label>-----" block in text. Blocks
# of other labels are skipped; malformed blocks (bad base64, stray
# characters, missing END line) are dropped rather than returned. The
# decoder is strict inside the armor: only base64 characters, '=' padding,
# and CR/LF/space/tab line structure are accepted.
list[pem_block*] pem_decode_blocks(char* text, int len, char* label):
	list[pem_block*] blocks = new list[pem_block*]
	if (text == 0):
		return blocks
	if (len < 0):
		return blocks
	char* begin_head = strjoin(c"-----BEGIN ", label)
	char* begin_marker = strjoin(begin_head, c"-----")
	char* end_head = strjoin(c"-----END ", label)
	char* end_marker = strjoin(end_head, c"-----")
	free(begin_head)
	free(end_head)
	char* b64 = malloc(len + 1)
	int b64len = 0
	int in_block = 0
	int block_bad = 0
	int pos = 0
	while (pos < len):
		int line_end = pos
		while (line_end < len):
			if ((text[line_end] & 255) == 10):
				break
			line_end = line_end + 1
		if (in_block == 0):
			if (pem_line_is(text, pos, line_end, begin_marker) != 0):
				in_block = 1
				block_bad = 0
				b64len = 0
		else:
			if (pem_line_is(text, pos, line_end, end_marker) != 0):
				if (block_bad == 0):
					int dlen = 0
					char* decoded = base64_decode(b64, b64len, &dlen)
					if (decoded != 0):
						pem_block* blk = new pem_block()
						blk.data = decoded
						blk.len = dlen
						blocks.push(blk)
				in_block = 0
			else:
				int i = pos
				while (i < line_end):
					int ch = text[i] & 255
					if ((ch == 13) | (ch == 32) | (ch == 9)):
						i = i + 1
						continue
					int ok = 0
					if (base64_decode_char(ch) >= 0):
						ok = 1
					if (ch == '='):
						ok = 1
					if (ok == 0):
						block_bad = 1
					else:
						b64[b64len] = ch
						b64len = b64len + 1
					i = i + 1
		pos = line_end + 1
	free(b64)
	free(begin_marker)
	free(end_marker)
	return blocks


# Decode and parse every CERTIFICATE block in text. Blocks that fail to
# parse are skipped and counted in *out_skipped (pass 0 to ignore); strict
# callers reject any nonzero count, the trust-store loader tolerates
# unsupported roots inside system bundles.
list[x509_cert*] pem_decode_certs(char* text, int len, int* out_skipped):
	list[x509_cert*] certs = new list[x509_cert*]
	int skipped = 0
	list[pem_block*] blocks = pem_decode_blocks(text, len, c"CERTIFICATE")
	int i = 0
	while (i < blocks.length):
		pem_block* b = blocks[i]
		x509_cert* c = x509_parse(b.data, b.len)
		if (c != 0):
			certs.push(c)
		else:
			skipped = skipped + 1
		i = i + 1
	pem_blocks_free(blocks)
	if (out_skipped != 0):
		*out_skipped = skipped
	return certs


# ---- trust store -------------------------------------------------------------------

struct x509_trust_store:
	list[x509_cert*] certs


x509_trust_store* x509_store_new():
	x509_trust_store* s = new x509_trust_store()
	s.certs = new list[x509_cert*]
	return s


# The store takes ownership of the certificate.
void x509_store_add(x509_trust_store* s, x509_cert* c):
	s.certs.push(c)


void x509_store_free(x509_trust_store* s):
	if (s == 0):
		return
	int i = 0
	while (i < s.certs.length):
		x509_cert_free(s.certs[i])
		i = i + 1
	list_free[x509_cert*](s.certs)
	free(cast(char*, s))


# Load every parseable certificate from a PEM bundle file into the store.
# Returns the number added (0 when the file is missing or has none).
int x509_store_add_pem_file(x509_trust_store* s, char* path):
	char* text = file_read_text(path)
	if (text == 0):
		return 0
	int skipped = 0
	list[x509_cert*] certs = pem_decode_certs(text, strlen(text), &skipped)
	int added = certs.length
	int i = 0
	while (i < certs.length):
		x509_store_add(s, certs[i])
		i = i + 1
	list_free[x509_cert*](certs)
	free(text)
	return added


char* x509_default_bundle_path(int i):
	if (i == 0):
		return c"/etc/ssl/certs/ca-certificates.crt"
	if (i == 1):
		return c"/etc/pki/tls/certs/ca-bundle.crt"
	if (i == 2):
		return c"/etc/ssl/ca-bundle.pem"
	if (i == 3):
		return c"/etc/pki/tls/cacert.pem"
	if (i == 4):
		return c"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
	if (i == 5):
		return c"/etc/ssl/cert.pem"
	return 0


# Load the system trust store. Priority: the override_path argument, then
# the SSL_CERT_FILE environment variable, then the well-known bundle paths
# (Debian, RHEL, SUSE, Alpine layouts). Returns 0 when no certificates
# could be loaded — verification against an empty store always fails, so
# callers may treat 0 as fatal. On macOS there is no system PEM bundle;
# set SSL_CERT_FILE (e.g. to a brew ca-certificates bundle) or pass a path.
x509_trust_store* x509_load_trust_store(char* override_path):
	char* path = override_path
	if (path == 0):
		path = env_get(c"SSL_CERT_FILE")
	x509_trust_store* s = x509_store_new()
	if (path != 0):
		if (x509_store_add_pem_file(s, path) > 0):
			return s
		x509_store_free(s)
		return 0
	int i = 0
	while (x509_default_bundle_path(i) != 0):
		if (x509_store_add_pem_file(s, x509_default_bundle_path(i)) > 0):
			return s
		i = i + 1
	x509_store_free(s)
	return 0


# ---- hostname matching (RFC 6125) ---------------------------------------------------

int x509_lower_char(int c):
	if ((c >= 'A') & (c <= 'Z')):
		return c + 32
	return c


# Case-insensitive equality of hostname[hs..hs+n) and pattern[ps..ps+n).
int x509_labels_equal_ci(char* a, int as, char* b, int bs, int n):
	int i = 0
	while (i < n):
		if (x509_lower_char(a[as + i] & 255) != x509_lower_char(b[bs + i] & 255)):
			return 0
		i = i + 1
	return 1


# Does one SAN dNSName pattern match hostname? Exact match, or an RFC 6125
# wildcard: the pattern's leftmost label is exactly "*", it matches exactly
# one non-empty host label, never across dots, and the remaining labels
# compare case-insensitively. Partial-label wildcards ("f*o.example") and
# wildcards anywhere but the leftmost label never match; a bare "*.tld"
# (nothing but one label after the wildcard) is rejected as over-broad.
# IPv4-literal hostnames never match a dNSName.
int x509_hostname_matches_pattern(char* pattern, char* hostname):
	if (pattern == 0):
		return 0
	if (hostname == 0):
		return 0
	int plen = strlen(pattern)
	int hlen = strlen(hostname)
	# Ignore one trailing dot on either side ("example.com." form).
	if (plen > 0):
		if ((pattern[plen - 1] & 255) == '.'):
			plen = plen - 1
	if (hlen > 0):
		if ((hostname[hlen - 1] & 255) == '.'):
			hlen = hlen - 1
	if ((plen == 0) | (hlen == 0)):
		return 0
	# The hostname itself may not contain wildcards.
	int i = 0
	while (i < hlen):
		if ((hostname[i] & 255) == '*'):
			return 0
		i = i + 1
	# IPv4 literals (digits and dots only) never match dNSNames.
	int all_addr = 1
	i = 0
	while (i < hlen):
		int ch = hostname[i] & 255
		if ((ch >= '0') & (ch <= '9')):
			i = i + 1
			continue
		if (ch == '.'):
			i = i + 1
			continue
		all_addr = 0
		break
	if (all_addr != 0):
		return 0
	int wildcard = 0
	if (plen >= 2):
		if ((pattern[0] & 255) == '*'):
			if ((pattern[1] & 255) == '.'):
				wildcard = 1
	if (wildcard == 0):
		# Exact match; any other '*' placement never matches.
		i = 0
		while (i < plen):
			if ((pattern[i] & 255) == '*'):
				return 0
			i = i + 1
		if (plen != hlen):
			return 0
		return x509_labels_equal_ci(pattern, 0, hostname, 0, plen)
	# Wildcard: pattern is "*.<rest>". rest must be at least two labels
	# (reject "*.com"), contain no further wildcards, and not start with
	# a dot (which would make the wildcard span an empty label).
	int rest = 2
	int restlen = plen - 2
	if (restlen < 1):
		return 0
	if ((pattern[rest] & 255) == '.'):
		return 0
	int has_dot = 0
	i = 0
	while (i < restlen):
		int pc = pattern[rest + i] & 255
		if (pc == '*'):
			return 0
		if (pc == '.'):
			has_dot = 1
		i = i + 1
	if (has_dot == 0):
		return 0
	# Hostname: split off the first label; it must be non-empty and the
	# remainder must equal rest.
	int dot = -1
	i = 0
	while (i < hlen):
		if ((hostname[i] & 255) == '.'):
			dot = i
			break
		i = i + 1
	if (dot <= 0):
		return 0
	int tail = dot + 1
	int taillen = hlen - tail
	if (taillen != restlen):
		return 0
	return x509_labels_equal_ci(pattern, rest, hostname, tail, restlen)


# Does the certificate cover hostname? SAN dNSName entries only — no
# common-name fallback, per current TLS practice.
int x509_match_hostname(x509_cert* c, char* hostname):
	if (c == 0):
		return 0
	int i = 0
	while (i < c.san_dns.length):
		if (x509_hostname_matches_pattern(c.san_dns[i], hostname) != 0):
			return 1
		i = i + 1
	return 0


# ---- signature verification ----------------------------------------------------------

# Convert a DER-encoded ECDSA signature (SEQUENCE of two positive INTEGERs)
# into fixed 32-byte big-endian r and s. Strict: minimal integer encodings,
# values that fit 256 bits (an oversized r/s is rejected here; range checks
# against the group order happen in ecdsa_p256_verify), no trailing bytes.
int x509_ecdsa_sig_to_raw(char* sig, int len, char* out_r, char* out_s):
	if (sig == 0):
		return 0
	if (len < 1):
		return 0
	asn1 top
	asn1_init(&top, sig, 0, len)
	int s = 0
	int l = 0
	if (asn1_expect(&top, ASN1_SEQUENCE(), &s, &l) == 0):
		return 0
	if (asn1_done(&top) == 0):
		return 0
	asn1 nums
	asn1_init(&nums, sig, s, s + l)
	int rs = 0
	int rl = 0
	if (asn1_read_positive_integer(&nums, &rs, &rl) == 0):
		return 0
	int ss = 0
	int sl = 0
	if (asn1_read_positive_integer(&nums, &ss, &sl) == 0):
		return 0
	if (asn1_done(&nums) == 0):
		return 0
	if ((rl > 32) | (sl > 32)):
		return 0
	int i = 0
	while (i < 32):
		out_r[i] = 0
		out_s[i] = 0
		i = i + 1
	i = 0
	while (i < rl):
		out_r[32 - rl + i] = sig[rs + i]
		i = i + 1
	i = 0
	while (i < sl):
		out_s[32 - sl + i] = sig[ss + i]
		i = i + 1
	return 1


# Verify that issuer's public key signed child's tbsCertificate. Returns 1/0.
int x509_check_signature(x509_cert* child, x509_cert* issuer):
	int alg = child.sig_alg
	if (alg == X509_SIGALG_UNKNOWN()):
		return 0
	int whash_alg = WHASH_SHA256()
	int dlen = 32
	if ((alg == X509_SIGALG_RSA_SHA384()) | (alg == X509_SIGALG_RSA_PSS_SHA384()) | (alg == X509_SIGALG_ECDSA_SHA384())):
		whash_alg = WHASH_SHA384()
		dlen = 48
	char* digest = malloc(48)
	whash_oneshot(whash_alg, child.der + child.tbs_start, child.tbs_len, digest)
	int result = 0
	int is_rsa = 0
	if ((alg == X509_SIGALG_RSA_SHA256()) | (alg == X509_SIGALG_RSA_SHA384())):
		is_rsa = 1
	if ((alg == X509_SIGALG_RSA_PSS_SHA256()) | (alg == X509_SIGALG_RSA_PSS_SHA384())):
		is_rsa = 2
	if (is_rsa != 0):
		if (issuer.key_type == X509_KEY_RSA()):
			char* n = issuer.der + issuer.rsa_n_start
			char* e = issuer.der + issuer.rsa_e_start
			char* sig = child.der + child.sig_start
			if (is_rsa == 1):
				if (dlen == 32):
					result = rsa_pkcs1v15_verify_sha256(n, issuer.rsa_n_len, e, issuer.rsa_e_len, sig, child.sig_len, digest)
				else:
					result = rsa_pkcs1v15_verify_sha384(n, issuer.rsa_n_len, e, issuer.rsa_e_len, sig, child.sig_len, digest)
			else:
				if (dlen == 32):
					result = rsa_pss_verify_sha256(n, issuer.rsa_n_len, e, issuer.rsa_e_len, sig, child.sig_len, digest)
				else:
					result = rsa_pss_verify_sha384(n, issuer.rsa_n_len, e, issuer.rsa_e_len, sig, child.sig_len, digest)
	else:
		if (issuer.key_type == X509_KEY_EC_P256()):
			char* r32 = malloc(32)
			char* s32 = malloc(32)
			if (x509_ecdsa_sig_to_raw(child.der + child.sig_start, child.sig_len, r32, s32) != 0):
				result = ecdsa_p256_verify(issuer.ec_qx, issuer.ec_qy, digest, dlen, r32, s32)
			free(r32)
			free(s32)
	free(digest)
	return result


# ---- chain verification ---------------------------------------------------------------

# Byte equality of two encoded Names (RFC 5280 name chaining in practice:
# CAs emit issuer bytes identical to the parent's subject bytes).
int x509_names_equal(x509_cert* a, int a_start, int a_len, x509_cert* b, int b_start, int b_len):
	if (a_len != b_len):
		return 0
	int i = 0
	while (i < a_len):
		if ((a.der[a_start + i] & 255) != (b.der[b_start + i] & 255)):
			return 0
		i = i + 1
	return 1


void x509_set_err(char** err_out, char* msg):
	if (err_out != 0):
		*err_out = msg


# Can `issuer` sign certificates with `below` intermediates already under it
# (the leaf does not count)? Returns 0 when acceptable, else a static reason.
char* x509_issuer_check(x509_cert* issuer, int below, int now_day, int now_sec, int is_anchor):
	int status = x509_time_status(issuer, now_day, now_sec)
	if (status == 1):
		return c"x509: issuer certificate not yet valid"
	if (status == 2):
		return c"x509: issuer certificate expired"
	if (issuer.has_basic_constraints != 0):
		if (issuer.is_ca == 0):
			return c"x509: issuer is not a CA"
		if (issuer.path_len >= 0):
			if (below > issuer.path_len):
				return c"x509: path length constraint violated"
	else:
		# No basicConstraints: only a v1 trust anchor is grandfathered in;
		# every intermediate must be a v3 CA.
		if (is_anchor == 0):
			return c"x509: issuer is not a CA"
		if (issuer.version >= 3):
			return c"x509: issuer is not a CA"
	if (issuer.has_key_usage != 0):
		if ((issuer.key_usage & X509_KU_KEY_CERT_SIGN()) == 0):
			return c"x509: issuer key usage does not allow certificate signing"
	return 0


# Verify leaf against the trust store at time now_unix (seconds since epoch;
# the library never reads the clock — pass lib/time.w's current time or a
# fixed test instant). extra holds unordered candidate intermediates (may
# be 0). hostname of 0 skips hostname verification (for non-server-identity
# uses); otherwise the leaf's SAN dNSNames must cover it. On failure
# returns 0 and points *err_out (if non-0) at a static message that never
# echoes certificate contents.
int x509_verify_chain(x509_cert* leaf, list[x509_cert*] extra, x509_trust_store* store, char* hostname, int now_unix, char** err_out):
	x509_set_err(err_out, 0)
	if (leaf == 0):
		x509_set_err(err_out, c"x509: no certificate")
		return 0
	if (store == 0):
		x509_set_err(err_out, c"x509: empty trust store")
		return 0
	if (store.certs.length == 0):
		x509_set_err(err_out, c"x509: empty trust store")
		return 0
	if (now_unix < 0):
		x509_set_err(err_out, c"x509: invalid verification time")
		return 0
	int now_day = 0
	int now_sec = 0
	x509_unix_to_day_sec(now_unix, &now_day, &now_sec)

	# Leaf checks first so their errors take priority.
	int status = x509_time_status(leaf, now_day, now_sec)
	if (status == 1):
		x509_set_err(err_out, c"x509: certificate not yet valid")
		return 0
	if (status == 2):
		x509_set_err(err_out, c"x509: certificate expired")
		return 0
	if (leaf.has_key_usage != 0):
		if ((leaf.key_usage & X509_KU_DIGITAL_SIGNATURE()) == 0):
			x509_set_err(err_out, c"x509: certificate not valid for server authentication")
			return 0
	if (leaf.has_eku != 0):
		if (leaf.eku_server_auth == 0):
			x509_set_err(err_out, c"x509: certificate not valid for server authentication")
			return 0
	if (hostname != 0):
		if (x509_match_hostname(leaf, hostname) == 0):
			x509_set_err(err_out, c"x509: hostname mismatch")
			return 0

	# Build leaf -> root greedily: prefer a trust anchor at every step,
	# otherwise extend with a matching intermediate from the pile.
	list[x509_cert*] chain = new list[x509_cert*]
	chain.push(leaf)
	x509_cert* current = leaf
	char* reason = 0
	int verified = 0
	int searching = 1
	while (searching != 0):
		int below = chain.length - 1
		# 1) a trust anchor whose subject matches current's issuer
		int ai = 0
		while (ai < store.certs.length):
			x509_cert* anchor = store.certs[ai]
			if (x509_names_equal(anchor, anchor.subject_start, anchor.subject_len, current, current.issuer_start, current.issuer_len) != 0):
				char* fail = x509_issuer_check(anchor, below, now_day, now_sec, 1)
				if (fail != 0):
					reason = fail
				else if (x509_check_signature(current, anchor) == 0):
					reason = c"x509: signature verification failed"
				else:
					verified = 1
					searching = 0
					break
			ai = ai + 1
		if (searching == 0):
			break
		# 2) an intermediate from the extras pile
		if (chain.length >= X509_MAX_CHAIN_LEN()):
			reason = c"x509: certificate chain too long"
			break
		int advanced = 0
		if (extra != 0):
			int ei = 0
			while (ei < extra.length):
				x509_cert* cand = extra[ei]
				ei = ei + 1
				if (cand == 0):
					continue
				# Never reuse a certificate (loop protection).
				int used = 0
				int ci = 0
				while (ci < chain.length):
					if (chain[ci] == cand):
						used = 1
					ci = ci + 1
				if (used != 0):
					continue
				if (x509_names_equal(cand, cand.subject_start, cand.subject_len, current, current.issuer_start, current.issuer_len) == 0):
					continue
				char* fail = x509_issuer_check(cand, below, now_day, now_sec, 0)
				if (fail != 0):
					reason = fail
					continue
				if (x509_check_signature(current, cand) == 0):
					reason = c"x509: signature verification failed"
					continue
				chain.push(cand)
				current = cand
				advanced = 1
				break
		if (advanced == 0):
			break
	list_free[x509_cert*](chain)
	if (verified != 0):
		return 1
	if (reason == 0):
		reason = c"x509: no trusted issuer found"
	x509_set_err(err_out, reason)
	return 0


# ---- EC private key loading (TLS server role) -------------------------------------------

void x509_wipe(char* p, int len):
	int i = 0
	while (i < len):
		p[i] = 0
		i = i + 1


# Parse a SEC1 ECPrivateKey structure (RFC 5915) at data[start, end):
#   SEQUENCE { INTEGER 1, OCTET STRING d(32),
#              [0] curve OID OPTIONAL, [1] BIT STRING pubkey OPTIONAL }
# When require_params is 1 the [0] curve parameters must be present (the
# bare "BEGIN EC PRIVATE KEY" form); inside PKCS#8 they are optional. Any
# present curve OID must be prime256v1; any embedded public key must match
# the one derived from d. Writes the 32-byte scalar to out_d32; returns 1/0.
int x509_parse_sec1_key(char* data, int start, int end, int require_params, char* out_d32):
	asn1 top
	asn1_init(&top, data, start, end)
	int s = 0
	int l = 0
	if (asn1_expect(&top, ASN1_SEQUENCE(), &s, &l) == 0):
		return 0
	if (asn1_done(&top) == 0):
		return 0
	asn1 k
	asn1_init(&k, data, s, s + l)
	int version = 0
	if (asn1_read_small_int(&k, &version) == 0):
		return 0
	if (version != 1):
		return 0
	int ds = 0
	int dl = 0
	if (asn1_expect(&k, ASN1_OCTET_STRING(), &ds, &dl) == 0):
		return 0
	if (dl != 32):
		return 0
	int have_params = 0
	if (asn1_peek(&k) == ASN1_CONTEXT(0)):
		int ps = 0
		int pl = 0
		if (asn1_expect(&k, ASN1_CONTEXT(0), &ps, &pl) == 0):
			return 0
		asn1 p
		asn1_init(&p, data, ps, ps + pl)
		int os = 0
		int ol = 0
		if (asn1_expect(&p, ASN1_OID(), &os, &ol) == 0):
			return 0
		if (asn1_done(&p) == 0):
			return 0
		if (x509_oid_is(data, os, ol, x509_oid_prime256v1()) == 0):
			return 0
		have_params = 1
	if (require_params != 0):
		if (have_params == 0):
			return 0
	int have_pub = 0
	int pub_start = 0
	if (asn1_peek(&k) == ASN1_CONTEXT(1)):
		int ws = 0
		int wl = 0
		if (asn1_expect(&k, ASN1_CONTEXT(1), &ws, &wl) == 0):
			return 0
		asn1 w
		asn1_init(&w, data, ws, ws + wl)
		int bs = 0
		int bl = 0
		if (asn1_read_bitstring_bytes(&w, &bs, &bl) == 0):
			return 0
		if (asn1_done(&w) == 0):
			return 0
		if (bl != 65):
			return 0
		if ((data[bs] & 255) != 4):
			return 0
		have_pub = 1
		pub_start = bs + 1
	if (asn1_done(&k) == 0):
		return 0
	# Validate the scalar by deriving Q = d*G (rejects d == 0 and d >= n).
	char* d32 = malloc(32)
	int i = 0
	while (i < 32):
		d32[i] = data[ds + i]
		i = i + 1
	char* qx = malloc(32)
	char* qy = malloc(32)
	int ok = ecdsa_p256_public_key(d32, qx, qy)
	if (ok != 0):
		if (have_pub != 0):
			i = 0
			while (i < 32):
				if ((qx[i] & 255) != (data[pub_start + i] & 255)):
					ok = 0
				if ((qy[i] & 255) != (data[pub_start + 32 + i] & 255)):
					ok = 0
				i = i + 1
	if (ok != 0):
		i = 0
		while (i < 32):
			out_d32[i] = d32[i]
			i = i + 1
	x509_wipe(d32, 32)
	free(d32)
	free(qx)
	free(qy)
	return ok


# Parse a PKCS#8 PrivateKeyInfo (RFC 5958) wrapping a P-256 ECPrivateKey.
int x509_parse_pkcs8_ec_key(char* data, int start, int end, char* out_d32):
	asn1 top
	asn1_init(&top, data, start, end)
	int s = 0
	int l = 0
	if (asn1_expect(&top, ASN1_SEQUENCE(), &s, &l) == 0):
		return 0
	if (asn1_done(&top) == 0):
		return 0
	asn1 k
	asn1_init(&k, data, s, s + l)
	int version = 0
	if (asn1_read_small_int(&k, &version) == 0):
		return 0
	if (version != 0):
		return 0
	int als = 0
	int all = 0
	if (asn1_expect(&k, ASN1_SEQUENCE(), &als, &all) == 0):
		return 0
	asn1 alg
	asn1_init(&alg, data, als, als + all)
	int os = 0
	int ol = 0
	if (asn1_expect(&alg, ASN1_OID(), &os, &ol) == 0):
		return 0
	if (x509_oid_is(data, os, ol, x509_oid_ec_public_key()) == 0):
		return 0
	int cs = 0
	int cl = 0
	if (asn1_expect(&alg, ASN1_OID(), &cs, &cl) == 0):
		return 0
	if (x509_oid_is(data, cs, cl, x509_oid_prime256v1()) == 0):
		return 0
	if (asn1_done(&alg) == 0):
		return 0
	int ps = 0
	int pl = 0
	if (asn1_expect(&k, ASN1_OCTET_STRING(), &ps, &pl) == 0):
		return 0
	# Optional attributes [0] are tolerated and ignored.
	if (asn1_peek(&k) == ASN1_CONTEXT(0)):
		if (asn1_skip(&k) == 0):
			return 0
	if (asn1_done(&k) == 0):
		return 0
	return x509_parse_sec1_key(data, ps, ps + pl, 0, out_d32)


# Load a P-256 private key for the TLS server role from PEM text: PKCS#8
# ("BEGIN PRIVATE KEY") or SEC1 ("BEGIN EC PRIVATE KEY"). The scalar is
# validated by deriving its public key, and compared against any public key
# embedded in the file. Writes 32 bytes to out_d32 and returns 1; on any
# failure returns 0 without leaking key material (all intermediate buffers
# are wiped, and there are no error strings on this path).
int x509_load_ec_private_key(char* pem_text, int len, char* out_d32):
	if (pem_text == 0):
		return 0
	if (out_d32 == 0):
		return 0
	int result = 0
	list[pem_block*] blocks = pem_decode_blocks(pem_text, len, c"PRIVATE KEY")
	if (blocks.length > 0):
		pem_block* b = blocks[0]
		result = x509_parse_pkcs8_ec_key(b.data, 0, b.len, out_d32)
	else:
		pem_blocks_free(blocks)
		blocks = pem_decode_blocks(pem_text, len, c"EC PRIVATE KEY")
		if (blocks.length > 0):
			pem_block* b2 = blocks[0]
			result = x509_parse_sec1_key(b2.data, 0, b2.len, 1, out_d32)
	# The decoded blocks hold the raw private key: wipe before freeing.
	int i = 0
	while (i < blocks.length):
		pem_block* wb = blocks[i]
		x509_wipe(wb.data, wb.len)
		i = i + 1
	pem_blocks_free(blocks)
	return result
