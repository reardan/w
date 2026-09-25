# wbuild: x64
# Tests for libs/standard/net/selfsigned.w (issue #98): the generated
# certificate parses with x509.w, carries the promised fields, verifies
# against its own public key, and pairs with the generated private key.
import lib.testing
import libs.standard.net.x509
import libs.standard.net.selfsigned


int st_bytes_equal(char* a, char* b, int n):
	int i = 0
	while (i < n):
		if (a[i] != b[i]):
			return 0
		i = i + 1
	return 1


void test_der_lengths():
	wbuf* small = wbuf_new(4)
	wbuf_bytes(small, c"abc", 3)
	wbuf* t = der_tlv(0x04, small)
	assert_equal(5, t.len)
	assert_equal(0x04, t.data[0] & 255)
	assert_equal(3, t.data[1] & 255)
	wbuf_free(t)
	wbuf* big = wbuf_new(300)
	int i = 0
	while (i < 300):
		wbuf_u8(big, i)
		i = i + 1
	t = der_tlv(0x30, big)
	assert_equal(304, t.len)
	assert_equal(0x82, t.data[1] & 255)
	assert_equal(1, t.data[2] & 255)
	assert_equal(44, t.data[3] & 255)
	wbuf_free(t)


void test_generate_parses_and_self_verifies():
	char* cert_pem = 0
	char* key_pem = 0
	assert_equal(1, selfsigned_p256_generate(c"wdbg_web", c"localhost", 0x7f000001, &cert_pem, &key_pem))
	int skipped = 0
	list[x509_cert*] certs = pem_decode_certs(cert_pem, strlen(cert_pem), &skipped)
	assert_equal(1, certs.length)
	assert_equal(0, skipped)
	x509_cert* c = certs[0]
	assert_equal(3, c.version)
	assert_equal(X509_SIGALG_ECDSA_SHA256(), c.sig_alg)
	assert_equal(X509_KEY_EC_P256(), c.key_type)
	assert_equal(1, c.has_basic_constraints)
	assert_equal(0, c.is_ca)
	assert_equal(1, c.has_key_usage)
	assert_equal(X509_KU_DIGITAL_SIGNATURE(), c.key_usage)
	assert_equal(1, c.eku_server_auth)
	assert_equal(1, c.san_present)
	assert_equal(1, c.san_dns.length)
	assert_strings_equal(c"localhost", c.san_dns[0])
	assert_equal(1, x509_match_hostname(c, c"localhost"))
	# notBefore 2020-01-01, notAfter 2049-12-31 23:59:59
	assert_equal(x509_days_from_civil(2020, 1, 1), c.nb_day)
	assert_equal(x509_days_from_civil(2049, 12, 31), c.na_day)
	assert_equal(86399, c.na_sec)
	# Self-signed: the cert's own key verifies its signature.
	assert_equal(1, x509_check_signature(c, c))

	# The key PEM loads as the matching private scalar.
	char* d = malloc(32)
	assert_equal(1, x509_load_ec_private_key(key_pem, strlen(key_pem), d))
	char* qx = malloc(32)
	char* qy = malloc(32)
	assert_equal(1, ecdsa_p256_public_key(d, qx, qy))
	assert_equal(1, st_bytes_equal(qx, c.ec_qx, 32))
	assert_equal(1, st_bytes_equal(qy, c.ec_qy, 32))
	free(d)
	free(qx)
	free(qy)
	x509_cert_free(c)
	list_free[x509_cert*](certs)
	free(cert_pem)
	free(key_pem)


void test_two_generations_differ():
	char* a_cert = 0
	char* a_key = 0
	char* b_cert = 0
	char* b_key = 0
	assert_equal(1, selfsigned_p256_generate(c"a", 0, 0, &a_cert, &a_key))
	assert_equal(1, selfsigned_p256_generate(c"a", 0, 0, &b_cert, &b_key))
	assert1(strcmp(a_cert, b_cert) != 0)
	assert1(strcmp(a_key, b_key) != 0)
	free(a_cert)
	free(a_key)
	free(b_cert)
	free(b_key)
