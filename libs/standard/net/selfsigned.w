# Self-signed ECDSA P-256 certificates, minted in-process (issue #98). A
# local dev server (tools/wdbg_web.w) wants https:// without asking the
# user to run openssl first, so this module generates a fresh P-256 key
# pair and a matching self-signed X.509 v3 leaf certificate and returns
# both as PEM text in exactly the shapes libs/standard/net/tls.w's server
# role loads (a "CERTIFICATE" block and a SEC1 "EC PRIVATE KEY" block).
# Pass them to tls_server_config's test_cert_pem/test_key_pem knobs to
# keep the private key off the filesystem entirely.
#
# The certificate is deliberately minimal and fixed-shape:
#   version v3, a random positive 128-bit serial, ecdsa-with-SHA256,
#   issuer = subject = CN=<common_name>, validity 2020-01-01 through
#   2049-12-31 (UTCTime keeps both inside one encoding), an uncompressed
#   P-256 SubjectPublicKeyInfo, and four extensions: basicConstraints
#   (critical, CA:FALSE), keyUsage (critical, digitalSignature),
#   extendedKeyUsage serverAuth, and subjectAltName listing dns_name (0 =
#   none) and the IPv4 address ipv4 (host order, 0 = none); the SAN
#   extension is omitted when both are absent.
# Browsers still show their self-signed-certificate warning -- nothing
# here is trusted -- but once accepted the connection is real TLS 1.3.
#
# Public API:
#   int selfsigned_p256_generate(char* common_name, char* dns_name, int ipv4,
#                                char** out_cert_pem, char** out_key_pem)
#       1 on success (both outputs malloc'd, NUL-terminated), 0 on failure
#   wbuf* der_tlv(int tag, wbuf* content)       wraps and frees content
import lib.lib
import lib.memory
import libs.standard.crypto.sha2
import libs.standard.crypto.base64
import libs.standard.crypto.random
import libs.standard.crypto.ecdsa_p256
import libs.standard.net.x509
import libs.standard.net.tls


# ---- DER building --------------------------------------------------------------

# Append a DER length (short form below 128, else long form).
void der_put_length(wbuf* b, int n):
	if (n < 128):
		wbuf_u8(b, n)
	else if (n < 256):
		wbuf_u8(b, 0x81)
		wbuf_u8(b, n)
	else if (n < 65536):
		wbuf_u8(b, 0x82)
		wbuf_u16(b, n)
	else:
		wbuf_u8(b, 0x83)
		wbuf_u24(b, n)


# A new buffer holding tag || length || content. content is freed.
wbuf* der_tlv(int tag, wbuf* content):
	wbuf* out = wbuf_new(content.len + 8)
	wbuf_u8(out, tag)
	der_put_length(out, content.len)
	wbuf_bytes(out, content.data, content.len)
	wbuf_free(content)
	return out


# Append tag || length || bytes.
void der_put_bytes(wbuf* b, int tag, char* data, int len):
	wbuf_u8(b, tag)
	der_put_length(b, len)
	wbuf_bytes(b, data, len)


# Append an already-encoded element and free it.
void der_put(wbuf* b, wbuf* element):
	wbuf_bytes(b, element.data, element.len)
	wbuf_free(element)


# SEQUENCE { OID ecdsa-with-SHA256 } (RFC 5758: no parameters).
wbuf* der_alg_ecdsa_sha256():
	wbuf* b = wbuf_new(16)
	der_put_bytes(b, 0x06, x509_oid_ecdsa_sha256(), 8)
	return der_tlv(0x30, b)


# Name: SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String cn } } }
wbuf* der_name_cn(char* cn):
	wbuf* atv = wbuf_new(32)
	der_put_bytes(atv, 0x06, c"\x55\x04\x03", 3)
	der_put_bytes(atv, 0x0c, cn, strlen(cn))
	wbuf* rdn = wbuf_new(40)
	der_put(rdn, der_tlv(0x30, atv))
	wbuf* name = wbuf_new(48)
	der_put(name, der_tlv(0x31, rdn))
	return der_tlv(0x30, name)


# One Extension: SEQUENCE { OID, [BOOLEAN TRUE], OCTET STRING value }.
# value is freed.
void der_put_extension(wbuf* exts, char* oid, int oid_len, int critical, wbuf* value):
	wbuf* e = wbuf_new(value.len + 16)
	der_put_bytes(e, 0x06, oid, oid_len)
	if (critical):
		der_put_bytes(e, 0x01, c"\xff", 1)
	der_put(e, der_tlv(0x04, value))
	der_put(exts, der_tlv(0x30, e))


# The uncompressed EC point 04 || X || Y.
void der_put_ec_point_bytes(wbuf* b, char* qx, char* qy):
	wbuf_u8(b, 0x04)
	wbuf_bytes(b, qx, 32)
	wbuf_bytes(b, qy, 32)


# BIT STRING { 00 04 X Y } (no unused bits).
wbuf* der_ec_point_bitstring(char* qx, char* qy):
	wbuf* bits = wbuf_new(72)
	wbuf_u8(bits, 0)
	der_put_ec_point_bytes(bits, qx, qy)
	return der_tlv(0x03, bits)


wbuf* selfsigned_tbs(char* cn, char* dns_name, int ipv4, char* serial, char* qx, char* qy):
	wbuf* tbs = wbuf_new(512)
	# [0] EXPLICIT Version v3 (INTEGER 2)
	wbuf* ver = wbuf_new(4)
	der_put_bytes(ver, 0x02, c"\x02", 1)
	der_put(tbs, der_tlv(0xa0, ver))
	der_put_bytes(tbs, 0x02, serial, 16)
	der_put(tbs, der_alg_ecdsa_sha256())
	der_put(tbs, der_name_cn(cn))
	wbuf* validity = wbuf_new(32)
	der_put_bytes(validity, 0x17, c"200101000000Z", 13)
	der_put_bytes(validity, 0x17, c"491231235959Z", 13)
	der_put(tbs, der_tlv(0x30, validity))
	der_put(tbs, der_name_cn(cn))
	# SubjectPublicKeyInfo
	wbuf* alg = wbuf_new(24)
	der_put_bytes(alg, 0x06, x509_oid_ec_public_key(), 7)
	der_put_bytes(alg, 0x06, x509_oid_prime256v1(), 8)
	wbuf* spki = wbuf_new(96)
	der_put(spki, der_tlv(0x30, alg))
	der_put(spki, der_ec_point_bitstring(qx, qy))
	der_put(tbs, der_tlv(0x30, spki))
	# Extensions
	wbuf* exts = wbuf_new(128)
	wbuf* bc = wbuf_new(2)
	der_put_extension(exts, x509_oid_basic_constraints(), 3, 1, der_tlv(0x30, bc))
	wbuf* ku = wbuf_new(4)
	der_put_bytes(ku, 0x03, c"\x07\x80", 2)
	der_put_extension(exts, x509_oid_key_usage(), 3, 1, ku)
	wbuf* eku = wbuf_new(12)
	der_put_bytes(eku, 0x06, x509_oid_server_auth(), 8)
	der_put_extension(exts, x509_oid_ext_key_usage(), 3, 0, der_tlv(0x30, eku))
	wbuf* names = wbuf_new(32)
	if (dns_name != 0):
		der_put_bytes(names, 0x82, dns_name, strlen(dns_name))
	if (ipv4 != 0):
		char* ip = malloc(4)
		ip[0] = (ipv4 >> 24) & 255
		ip[1] = (ipv4 >> 16) & 255
		ip[2] = (ipv4 >> 8) & 255
		ip[3] = ipv4 & 255
		der_put_bytes(names, 0x87, ip, 4)
		free(ip)
	if (names.len > 0):
		der_put_extension(exts, x509_oid_subject_alt_name(), 3, 0, der_tlv(0x30, names))
	else:
		wbuf_free(names)
	wbuf* ext_seq = der_tlv(0x30, exts)
	der_put(tbs, der_tlv(0xa3, ext_seq))
	return der_tlv(0x30, tbs)


# SEC1 ECPrivateKey (RFC 5915) with the curve parameters and public key.
wbuf* selfsigned_sec1_key(char* d, char* qx, char* qy):
	wbuf* k = wbuf_new(128)
	der_put_bytes(k, 0x02, c"\x01", 1)
	der_put_bytes(k, 0x04, d, 32)
	wbuf* params = wbuf_new(12)
	der_put_bytes(params, 0x06, x509_oid_prime256v1(), 8)
	der_put(k, der_tlv(0xa0, params))
	wbuf* pub = wbuf_new(72)
	der_put(pub, der_ec_point_bitstring(qx, qy))
	der_put(k, der_tlv(0xa1, pub))
	return der_tlv(0x30, k)


# PEM-armor DER bytes under label, 64 base64 characters per line.
char* selfsigned_pem(char* label, char* der, int len):
	char* b64 = base64_encode(der, len)
	int n = strlen(b64)
	wbuf* out = wbuf_new(n + n / 64 + 80)
	wbuf_bytes(out, c"-----BEGIN ", 11)
	wbuf_bytes(out, label, strlen(label))
	wbuf_bytes(out, c"-----\n", 6)
	int i = 0
	while (i < n):
		int take = n - i
		if (take > 64):
			take = 64
		wbuf_bytes(out, b64 + i, take)
		wbuf_u8(out, 10)
		i = i + take
	wbuf_bytes(out, c"-----END ", 9)
	wbuf_bytes(out, label, strlen(label))
	wbuf_bytes(out, c"-----\n", 6)
	wbuf_u8(out, 0)
	free(b64)
	char* text = out.data
	free(cast(char*, out))
	return text


int selfsigned_p256_generate(char* common_name, char* dns_name, int ipv4, char** out_cert_pem, char** out_key_pem):
	char* d = malloc(32)
	char* qx = malloc(32)
	char* qy = malloc(32)
	int ok = 0
	int tries = 0
	while ((ok == 0) && (tries < 8)):
		if (random_bytes(d, 32)):
			ok = ecdsa_p256_public_key(d, qx, qy)
		tries = tries + 1
	if (ok == 0):
		free(d)
		free(qx)
		free(qy)
		return 0

	# A positive, minimal 16-byte serial: top bit clear, first byte non-zero.
	char* serial = malloc(16)
	random_bytes(serial, 16)
	serial[0] = (serial[0] & 0x7f) | 0x40

	wbuf* tbs = selfsigned_tbs(common_name, dns_name, ipv4, serial, qx, qy)
	free(serial)
	char* digest = malloc(32)
	whash_oneshot(WHASH_SHA256(), tbs.data, tbs.len, digest)
	char* r = malloc(32)
	char* s = malloc(32)
	ok = ecdsa_p256_sign(d, digest, 32, r, s)
	free(digest)
	if (ok == 0):
		x509_wipe(d, 32)
		free(d)
		free(qx)
		free(qy)
		free(r)
		free(s)
		wbuf_free(tbs)
		return 0
	char* sig = malloc(80)
	int sig_len = 0
	x509_ecdsa_sig_raw_to_der(r, s, sig, &sig_len)
	free(r)
	free(s)

	wbuf* cert = wbuf_new(tbs.len + 128)
	der_put(cert, tbs)
	der_put(cert, der_alg_ecdsa_sha256())
	wbuf* sigbits = wbuf_new(sig_len + 1)
	wbuf_u8(sigbits, 0)
	wbuf_bytes(sigbits, sig, sig_len)
	free(sig)
	der_put(cert, der_tlv(0x03, sigbits))
	wbuf* cert_der = der_tlv(0x30, cert)
	*out_cert_pem = selfsigned_pem(c"CERTIFICATE", cert_der.data, cert_der.len)
	wbuf_free(cert_der)

	wbuf* key_der = selfsigned_sec1_key(d, qx, qy)
	*out_key_pem = selfsigned_pem(c"EC PRIVATE KEY", key_der.data, key_der.len)
	x509_wipe(key_der.data, key_der.len)
	wbuf_free(key_der)
	x509_wipe(d, 32)
	free(d)
	free(qx)
	free(qy)
	return 1
