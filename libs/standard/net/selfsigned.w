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
#   string_builder* der_tlv(int tag, string_builder* content)       wraps and frees content
import lib.lib
import lib.memory
import libs.standard.crypto.sha2
import libs.standard.crypto.base64
import libs.standard.crypto.random
import libs.standard.crypto.ecdsa_p256
import libs.standard.net.x509
import libs.standard.net.tls
import lib.bytes


# ---- DER building --------------------------------------------------------------

# Append a DER length (short form below 128, else long form).
void der_put_length(string_builder* b, int n):
	if (n < 128):
		string_append_char(b, n)
	else if (n < 256):
		string_append_char(b, 0x81)
		string_append_char(b, n)
	else if (n < 65536):
		string_append_char(b, 0x82)
		string_append_be16(b, n)
	else:
		string_append_char(b, 0x83)
		string_append_be24(b, n)


# A new buffer holding tag || length || content. content is freed.
string_builder* der_tlv(int tag, string_builder* content):
	string_builder* out = string_new_sized(content.length + 8)
	string_append_char(out, tag)
	der_put_length(out, content.length)
	string_append_bytes(out, content.data, content.length)
	string_free(content)
	return out


# Append tag || length || bytes.
void der_put_bytes(string_builder* b, int tag, char* data, int len):
	string_append_char(b, tag)
	der_put_length(b, len)
	string_append_bytes(b, data, len)


# Append an already-encoded element and free it.
void der_put(string_builder* b, string_builder* element):
	string_append_bytes(b, element.data, element.length)
	string_free(element)


# SEQUENCE { OID ecdsa-with-SHA256 } (RFC 5758: no parameters).
string_builder* der_alg_ecdsa_sha256():
	string_builder* b = string_new_sized(16)
	der_put_bytes(b, 0x06, x509_oid_ecdsa_sha256(), 8)
	return der_tlv(0x30, b)


# Name: SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String cn } } }
string_builder* der_name_cn(char* cn):
	string_builder* atv = string_new_sized(32)
	der_put_bytes(atv, 0x06, c"\x55\x04\x03", 3)
	der_put_bytes(atv, 0x0c, cn, strlen(cn))
	string_builder* rdn = string_new_sized(40)
	der_put(rdn, der_tlv(0x30, atv))
	string_builder* name = string_new_sized(48)
	der_put(name, der_tlv(0x31, rdn))
	return der_tlv(0x30, name)


# One Extension: SEQUENCE { OID, [BOOLEAN TRUE], OCTET STRING value }.
# value is freed.
void der_put_extension(string_builder* exts, char* oid, int oid_len, int critical, string_builder* value):
	string_builder* e = string_new_sized(value.length + 16)
	der_put_bytes(e, 0x06, oid, oid_len)
	if (critical):
		der_put_bytes(e, 0x01, c"\xff", 1)
	der_put(e, der_tlv(0x04, value))
	der_put(exts, der_tlv(0x30, e))


# The uncompressed EC point 04 || X || Y.
void der_put_ec_point_bytes(string_builder* b, char* qx, char* qy):
	string_append_char(b, 0x04)
	string_append_bytes(b, qx, 32)
	string_append_bytes(b, qy, 32)


# BIT STRING { 00 04 X Y } (no unused bits).
string_builder* der_ec_point_bitstring(char* qx, char* qy):
	string_builder* bits = string_new_sized(72)
	string_append_char(bits, 0)
	der_put_ec_point_bytes(bits, qx, qy)
	return der_tlv(0x03, bits)


string_builder* selfsigned_tbs(char* cn, char* dns_name, int ipv4, char* serial, char* qx, char* qy):
	string_builder* tbs = string_new_sized(512)
	# [0] EXPLICIT Version v3 (INTEGER 2)
	string_builder* ver = string_new_sized(4)
	der_put_bytes(ver, 0x02, c"\x02", 1)
	der_put(tbs, der_tlv(0xa0, ver))
	der_put_bytes(tbs, 0x02, serial, 16)
	der_put(tbs, der_alg_ecdsa_sha256())
	der_put(tbs, der_name_cn(cn))
	string_builder* validity = string_new_sized(32)
	der_put_bytes(validity, 0x17, c"200101000000Z", 13)
	der_put_bytes(validity, 0x17, c"491231235959Z", 13)
	der_put(tbs, der_tlv(0x30, validity))
	der_put(tbs, der_name_cn(cn))
	# SubjectPublicKeyInfo
	string_builder* alg = string_new_sized(24)
	der_put_bytes(alg, 0x06, x509_oid_ec_public_key(), 7)
	der_put_bytes(alg, 0x06, x509_oid_prime256v1(), 8)
	string_builder* spki = string_new_sized(96)
	der_put(spki, der_tlv(0x30, alg))
	der_put(spki, der_ec_point_bitstring(qx, qy))
	der_put(tbs, der_tlv(0x30, spki))
	# Extensions
	string_builder* exts = string_new_sized(128)
	string_builder* bc = string_new_sized(2)
	der_put_extension(exts, x509_oid_basic_constraints(), 3, 1, der_tlv(0x30, bc))
	string_builder* ku = string_new_sized(4)
	der_put_bytes(ku, 0x03, c"\x07\x80", 2)
	der_put_extension(exts, x509_oid_key_usage(), 3, 1, ku)
	string_builder* eku = string_new_sized(12)
	der_put_bytes(eku, 0x06, x509_oid_server_auth(), 8)
	der_put_extension(exts, x509_oid_ext_key_usage(), 3, 0, der_tlv(0x30, eku))
	string_builder* names = string_new_sized(32)
	if (dns_name != 0):
		der_put_bytes(names, 0x82, dns_name, strlen(dns_name))
	if (ipv4 != 0):
		char* ip = malloc(4)
		store_be32(ip, ipv4)
		der_put_bytes(names, 0x87, ip, 4)
		free(ip)
	if (names.length > 0):
		der_put_extension(exts, x509_oid_subject_alt_name(), 3, 0, der_tlv(0x30, names))
	else:
		string_free(names)
	string_builder* ext_seq = der_tlv(0x30, exts)
	der_put(tbs, der_tlv(0xa3, ext_seq))
	return der_tlv(0x30, tbs)


# SEC1 ECPrivateKey (RFC 5915) with the curve parameters and public key.
string_builder* selfsigned_sec1_key(char* d, char* qx, char* qy):
	string_builder* k = string_new_sized(128)
	der_put_bytes(k, 0x02, c"\x01", 1)
	der_put_bytes(k, 0x04, d, 32)
	string_builder* params = string_new_sized(12)
	der_put_bytes(params, 0x06, x509_oid_prime256v1(), 8)
	der_put(k, der_tlv(0xa0, params))
	string_builder* pub = string_new_sized(72)
	der_put(pub, der_ec_point_bitstring(qx, qy))
	der_put(k, der_tlv(0xa1, pub))
	return der_tlv(0x30, k)


# PEM-armor DER bytes under label, 64 base64 characters per line.
char* selfsigned_pem(char* label, char* der, int len):
	char* b64 = base64_encode(der, len)
	int n = strlen(b64)
	string_builder* out = string_new_sized(n + n / 64 + 80)
	string_append_bytes(out, c"-----BEGIN ", 11)
	string_append_bytes(out, label, strlen(label))
	string_append_bytes(out, c"-----\n", 6)
	int i = 0
	while (i < n):
		int take = n - i
		if (take > 64):
			take = 64
		string_append_bytes(out, b64 + i, take)
		string_append_char(out, 10)
		i = i + take
	string_append_bytes(out, c"-----END ", 9)
	string_append_bytes(out, label, strlen(label))
	string_append_bytes(out, c"-----\n", 6)
	string_append_char(out, 0)
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

	string_builder* tbs = selfsigned_tbs(common_name, dns_name, ipv4, serial, qx, qy)
	free(serial)
	char* digest = malloc(32)
	whash_oneshot(WHASH_SHA256, tbs.data, tbs.length, digest)
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
		string_free(tbs)
		return 0
	char* sig = malloc(80)
	int sig_len = 0
	x509_ecdsa_sig_raw_to_der(r, s, sig, &sig_len)
	free(r)
	free(s)

	string_builder* cert = string_new_sized(tbs.length + 128)
	der_put(cert, tbs)
	der_put(cert, der_alg_ecdsa_sha256())
	string_builder* sigbits = string_new_sized(sig_len + 1)
	string_append_char(sigbits, 0)
	string_append_bytes(sigbits, sig, sig_len)
	free(sig)
	der_put(cert, der_tlv(0x03, sigbits))
	string_builder* cert_der = der_tlv(0x30, cert)
	*out_cert_pem = selfsigned_pem(c"CERTIFICATE", cert_der.data, cert_der.length)
	string_free(cert_der)

	string_builder* key_der = selfsigned_sec1_key(d, qx, qy)
	*out_key_pem = selfsigned_pem(c"EC PRIVATE KEY", key_der.data, key_der.length)
	x509_wipe(key_der.data, key_der.length)
	string_free(key_der)
	x509_wipe(d, 32)
	free(d)
	free(qx)
	free(qy)
	return 1
