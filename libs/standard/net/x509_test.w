# Tests for libs/standard/net/x509.w. Fixtures live in
# libs/standard/net/x509_fixtures/ (see the README there for provenance):
# real Let's Encrypt / Google Trust Services / DigiCert certificates plus a
# synthetic OpenSSL-minted universe for the negative cases. Everything runs
# offline against checked-in files, and every date check uses a fixed `now`
# so nothing rots.
#
# Field expectations (serials, SAN entries, validity instants, key sizes)
# were cross-checked against `openssl x509 -text` when the fixtures were
# checked in.
import lib.testing
import lib.file
import lib.container
import libs.standard.crypto.base64
import libs.standard.net.asn1
import libs.standard.net.x509


# Fixed verification instants (see fixture README).
int XT_NOW_SYNTH():
	return 1785542400    # 2026-08-01, inside every synthetic validity window


int XT_NOW_GOOGLE():
	return 1676419200    # 2023-02-15, inside the archived Google chain window


int XT_NOW_TRUSTASIA():
	return 1559347200    # 2019-06-01, inside the TrustAsia chain window


int XT_NOW_PAST():
	return 1577836800    # 2020-01-01, before every synthetic notBefore


char* xt_fixture_dir():
	return c"libs/standard/net/x509_fixtures/"


char* xt_read_fixture(char* name):
	char* path = strjoin(xt_fixture_dir(), name)
	char* text = file_read_text(path)
	if (text == 0):
		print_string(c"missing fixture: ", path)
		exit(1)
	free(path)
	return text


# Load a single-certificate PEM fixture; dies if it does not parse cleanly.
x509_cert* xt_load_cert(char* name):
	char* text = xt_read_fixture(name)
	int skipped = 0
	list[x509_cert*] certs = pem_decode_certs(text, strlen(text), &skipped)
	free(text)
	if ((certs.length != 1) || (skipped != 0)):
		print_string(c"fixture did not parse: ", name)
		exit(1)
	x509_cert* c = certs[0]
	list_free[x509_cert*](certs)
	return c


# Decode the raw DER of a single-block PEM fixture (caller frees).
char* xt_load_der(char* name, int* out_len):
	char* text = xt_read_fixture(name)
	list[pem_block*] blocks = pem_decode_blocks(text, strlen(text), c"CERTIFICATE")
	free(text)
	asserts(c"expected one PEM block", blocks.length == 1)
	pem_block* b = blocks[0]
	char* der = malloc(b.len)
	int i = 0
	while (i < b.len):
		der[i] = b.data[i]
		i = i + 1
	*out_len = b.len
	pem_blocks_free(blocks)
	return der


void xt_assert_serial(x509_cert* c, char* want_hex):
	char* got = hex_encode(c.der + c.serial_start, c.serial_len)
	assert_strings_equal(want_hex, got)
	free(got)


# ---- parsing: real certificates -------------------------------------------------


void test_parse_google_leaf():
	x509_cert* c = xt_load_cert(c"google_leaf.pem")
	assert_equal(3, c.version)
	xt_assert_serial(c, c"111991593cd5a33d1231ea33c3644cdc")
	assert_equal(X509_SIGALG_RSA_SHA256(), c.sig_alg)
	assert_equal(X509_KEY_RSA(), c.key_type)
	assert_equal(256, c.rsa_n_len)          # RSA-2048
	# e = 65537
	assert_equal(3, c.rsa_e_len)
	assert_equal(1, c.der[c.rsa_e_start] & 255)
	assert_equal(0, c.der[c.rsa_e_start + 1] & 255)
	assert_equal(1, c.der[c.rsa_e_start + 2] & 255)
	# notBefore 2023-01-02 08:19:19, notAfter 2023-03-27 08:19:18
	assert_equal(19359, c.nb_day)
	assert_equal(29959, c.nb_sec)
	assert_equal(19443, c.na_day)
	assert_equal(29958, c.na_sec)
	assert_equal(1, c.san_present)
	assert_equal(1, c.san_dns.length)
	assert_strings_equal(c"www.google.com", c.san_dns[0])
	assert_equal(1, c.has_basic_constraints)
	assert_equal(0, c.is_ca)
	assert_equal(1, c.has_key_usage)
	# digitalSignature + keyEncipherment
	assert_equal(5, c.key_usage)
	assert_equal(1, c.has_eku)
	assert_equal(1, c.eku_server_auth)
	x509_cert_free(c)


void test_parse_isrg_root():
	x509_cert* c = xt_load_cert(c"isrg_root_x1.pem")
	assert_equal(3, c.version)
	# openssl serial 8210CFB0D240E3594463E0BB63828B00; the DER content
	# carries a sign-clearing 0x00 first.
	xt_assert_serial(c, c"008210cfb0d240e3594463e0bb63828b00")
	assert_equal(X509_KEY_RSA(), c.key_type)
	assert_equal(512, c.rsa_n_len)          # RSA-4096
	assert_equal(1, c.has_basic_constraints)
	assert_equal(1, c.is_ca)
	assert_equal(-1, c.path_len)
	assert_equal(1, c.has_key_usage)
	assert_equal((c.key_usage & X509_KU_KEY_CERT_SIGN()) != 0, 1)
	# Self-signed: issuer bytes equal subject bytes.
	assert_equal(1, x509_names_equal(c, c.subject_start, c.subject_len, c, c.issuer_start, c.issuer_len))
	# notAfter 2035-06-04 11:04:38
	assert_equal(23895, c.na_day)
	assert_equal(39878, c.na_sec)
	x509_cert_free(c)


void test_parse_trustasia_chain_certs():
	# EC P-256 leaf carrying an ecdsa-with-SHA384 signature and wildcard SAN.
	x509_cert* leaf = xt_load_cert(c"trustasia_leaf.pem")
	assert_equal(X509_KEY_EC_P256(), leaf.key_type)
	assert_equal(X509_SIGALG_ECDSA_SHA384(), leaf.sig_alg)
	assert_equal(2, leaf.san_dns.length)
	assert_strings_equal(c"*.tm.cn", leaf.san_dns[0])
	assert_strings_equal(c"tm.cn", leaf.san_dns[1])
	assert_equal(1, x509_match_hostname(leaf, c"www.tm.cn"))
	assert_equal(1, x509_match_hostname(leaf, c"tm.cn"))
	assert_equal(0, x509_match_hostname(leaf, c"a.b.tm.cn"))
	# Its issuer key is EC P-384: parseable, but unsupported for verifying.
	x509_cert* ca = xt_load_cert(c"trustasia_ca.pem")
	assert_equal(X509_KEY_UNSUPPORTED(), ca.key_type)
	assert_equal(X509_SIGALG_RSA_SHA384(), ca.sig_alg)
	x509_cert_free(leaf)
	x509_cert_free(ca)


# ---- chain verification: real certificates ------------------------------------------


void test_verify_google_chain():
	x509_cert* leaf = xt_load_cert(c"google_leaf.pem")
	x509_cert* inter = xt_load_cert(c"gts_ca_1c3.pem")
	x509_cert* root = xt_load_cert(c"gts_root_r1.pem")
	x509_trust_store* store = x509_store_new()
	x509_store_add(store, root)
	list[x509_cert*] extra = new list[x509_cert*]
	extra.push(inter)
	char* err = 0
	assert_equal(1, x509_verify_chain(leaf, extra, store, c"www.google.com", XT_NOW_GOOGLE(), &err))
	# Hostname is required and checked against SAN only.
	assert_equal(0, x509_verify_chain(leaf, extra, store, c"www.gogle.com", XT_NOW_GOOGLE(), &err))
	assert_strings_equal(c"x509: hostname mismatch", err)
	assert_equal(0, x509_verify_chain(leaf, extra, store, c"google.com", XT_NOW_GOOGLE(), &err))
	assert_strings_equal(c"x509: hostname mismatch", err)
	# Expired / not yet valid at fixed instants outside the window.
	assert_equal(0, x509_verify_chain(leaf, extra, store, c"www.google.com", XT_NOW_SYNTH(), &err))
	assert_strings_equal(c"x509: certificate expired", err)
	assert_equal(0, x509_verify_chain(leaf, extra, store, c"www.google.com", XT_NOW_PAST(), &err))
	assert_strings_equal(c"x509: certificate not yet valid", err)
	# Without the intermediate there is no path.
	list[x509_cert*] none = new list[x509_cert*]
	assert_equal(0, x509_verify_chain(leaf, none, store, c"www.google.com", XT_NOW_GOOGLE(), &err))
	assert_strings_equal(c"x509: no trusted issuer found", err)
	# Broken signature: flip one bit in the leaf's signatureValue.
	leaf.der[leaf.sig_start + 17] = leaf.der[leaf.sig_start + 17] ^ 32
	assert_equal(0, x509_verify_chain(leaf, extra, store, c"www.google.com", XT_NOW_GOOGLE(), &err))
	assert_strings_equal(c"x509: signature verification failed", err)
	leaf.der[leaf.sig_start + 17] = leaf.der[leaf.sig_start + 17] ^ 32
	assert_equal(1, x509_verify_chain(leaf, extra, store, c"www.google.com", XT_NOW_GOOGLE(), &err))
	list_free[x509_cert*](none)
	list_free[x509_cert*](extra)
	x509_cert_free(leaf)
	x509_cert_free(inter)
	x509_store_free(store)


void test_verify_letsencrypt_intermediate():
	# Real RSA-4096/SHA-256 link: Let's Encrypt R11 signed by ISRG Root X1.
	# R11 stands in as the "leaf" (hostname 0 skips identity checks).
	x509_cert* r11 = xt_load_cert(c"le_r11.pem")
	x509_cert* root = xt_load_cert(c"isrg_root_x1.pem")
	xt_assert_serial(r11, c"008a7d3e13d62f30ef2386bd29076b34f8")
	x509_trust_store* store = x509_store_new()
	x509_store_add(store, root)
	char* err = 0
	assert_equal(1, x509_verify_chain(r11, 0, store, 0, XT_NOW_SYNTH(), &err))
	# The wrong root does not vouch for it.
	x509_trust_store* wrong = x509_store_new()
	x509_store_add(wrong, xt_load_cert(c"gts_root_r1.pem"))
	assert_equal(0, x509_verify_chain(r11, 0, wrong, 0, XT_NOW_SYNTH(), &err))
	assert_strings_equal(c"x509: no trusted issuer found", err)
	x509_cert_free(r11)
	x509_store_free(store)
	x509_store_free(wrong)


void test_verify_digicert_sha384_link():
	# Real sha384WithRSAEncryption verification: TrustAsia CA signed by
	# DigiCert Global Root CA.
	x509_cert* ta = xt_load_cert(c"trustasia_ca.pem")
	x509_cert* root = xt_load_cert(c"digicert_global_root_ca.pem")
	x509_trust_store* store = x509_store_new()
	x509_store_add(store, root)
	char* err = 0
	assert_equal(1, x509_verify_chain(ta, 0, store, 0, XT_NOW_TRUSTASIA(), &err))
	# The TrustAsia leaf cannot be verified: its issuer key is P-384,
	# which this stack does not support -> fail closed.
	x509_cert* leaf = xt_load_cert(c"trustasia_leaf.pem")
	x509_trust_store* tstore = x509_store_new()
	x509_store_add(tstore, xt_load_cert(c"trustasia_ca.pem"))
	assert_equal(0, x509_verify_chain(leaf, 0, tstore, c"www.tm.cn", XT_NOW_TRUSTASIA(), &err))
	assert_strings_equal(c"x509: signature verification failed", err)
	x509_cert_free(ta)
	x509_cert_free(leaf)
	x509_store_free(store)
	x509_store_free(tstore)


# ---- chain verification: synthetic chains --------------------------------------------


# Verify one synthetic leaf against the RSA chain (int_rsa under ca_rsa).
void xt_check_rsa_chain_leaf(char* leaf_name, char* hostname, int want, char* want_err):
	x509_cert* leaf = xt_load_cert(leaf_name)
	x509_cert* inter = xt_load_cert(c"int_rsa.pem")
	x509_cert* root = xt_load_cert(c"ca_rsa.pem")
	x509_trust_store* store = x509_store_new()
	x509_store_add(store, root)
	list[x509_cert*] extra = new list[x509_cert*]
	extra.push(inter)
	char* err = 0
	assert_equal(want, x509_verify_chain(leaf, extra, store, hostname, XT_NOW_SYNTH(), &err))
	if (want_err != 0):
		assert_strings_equal(want_err, err)
	list_free[x509_cert*](extra)
	x509_cert_free(leaf)
	x509_cert_free(inter)
	x509_store_free(store)


void test_verify_synthetic_rsa_chain():
	xt_check_rsa_chain_leaf(c"leaf_ec.pem", c"test.w.example", 1, 0)
	# Case-insensitive exact match.
	xt_check_rsa_chain_leaf(c"leaf_ec.pem", c"TEST.W.Example", 1, 0)
	# Wildcard SAN *.wild.w.example: one label, not zero, not two.
	xt_check_rsa_chain_leaf(c"leaf_ec.pem", c"a.wild.w.example", 1, 0)
	xt_check_rsa_chain_leaf(c"leaf_ec.pem", c"wild.w.example", 0, c"x509: hostname mismatch")
	xt_check_rsa_chain_leaf(c"leaf_ec.pem", c"b.a.wild.w.example", 0, c"x509: hostname mismatch")
	xt_check_rsa_chain_leaf(c"leaf_ec.pem", c"other.w.example", 0, c"x509: hostname mismatch")
	# hostname 0 skips identity checks (for the non-TLS-server uses).
	xt_check_rsa_chain_leaf(c"leaf_ec.pem", 0, 1, 0)


void test_verify_synthetic_leaf_fields():
	x509_cert* c = xt_load_cert(c"leaf_ec.pem")
	xt_assert_serial(c, c"5f5ccc499d4fc72841ddec7cdfcf15f62797c171")
	assert_equal(X509_KEY_EC_P256(), c.key_type)
	assert_equal(X509_SIGALG_RSA_SHA256(), c.sig_alg)
	# SAN had four entries; only the two dNSNames are kept.
	assert_equal(2, c.san_dns.length)
	assert_strings_equal(c"test.w.example", c.san_dns[0])
	assert_strings_equal(c"*.wild.w.example", c.san_dns[1])
	# notBefore 2026-07-10 03:07:54 -> notAfter 2036-07-07 03:07:54.
	assert_equal(20644, c.nb_day)
	assert_equal(11274, c.nb_sec)
	assert_equal(24294, c.na_day)
	assert_equal(11274, c.na_sec)
	x509_cert_free(c)
	# The 2046 CA notAfter would overflow a 32-bit unix time; the
	# (day, sec) representation carries it exactly.
	x509_cert* ca = xt_load_cert(c"ca_rsa.pem")
	assert_equal(27944, ca.na_day)
	assert_equal(11274, ca.na_sec)
	assert_equal(1, ca.is_ca)
	x509_cert_free(ca)


void test_verify_synthetic_sha384_and_pss():
	# PKCS#1 v1.5 SHA-384 signed leaf.
	xt_check_rsa_chain_leaf(c"leaf_rsa384.pem", c"test.w.example", 1, 0)
	# RSA-PSS SHA-256 and SHA-384 signed leaves.
	xt_check_rsa_chain_leaf(c"leaf_pss256.pem", c"test.w.example", 1, 0)
	xt_check_rsa_chain_leaf(c"leaf_pss384.pem", c"test.w.example", 1, 0)
	# The classified algorithms.
	x509_cert* a = xt_load_cert(c"leaf_rsa384.pem")
	assert_equal(X509_SIGALG_RSA_SHA384(), a.sig_alg)
	x509_cert_free(a)
	a = xt_load_cert(c"leaf_pss256.pem")
	assert_equal(X509_SIGALG_RSA_PSS_SHA256(), a.sig_alg)
	x509_cert_free(a)
	a = xt_load_cert(c"leaf_pss384.pem")
	assert_equal(X509_SIGALG_RSA_PSS_SHA384(), a.sig_alg)
	x509_cert_free(a)


void test_verify_synthetic_ecdsa_chain():
	x509_cert* leaf = xt_load_cert(c"leaf_ec_chain.pem")
	assert_equal(X509_SIGALG_ECDSA_SHA256(), leaf.sig_alg)
	x509_cert* inter = xt_load_cert(c"int_ec.pem")
	x509_cert* root = xt_load_cert(c"ca_ec.pem")
	x509_trust_store* store = x509_store_new()
	x509_store_add(store, root)
	list[x509_cert*] extra = new list[x509_cert*]
	extra.push(inter)
	char* err = 0
	assert_equal(1, x509_verify_chain(leaf, extra, store, c"test.w.example", XT_NOW_SYNTH(), &err))
	# Tamper with the ECDSA signature -> fail closed.
	leaf.der[leaf.sig_start + leaf.sig_len - 3] = leaf.der[leaf.sig_start + leaf.sig_len - 3] ^ 1
	assert_equal(0, x509_verify_chain(leaf, extra, store, c"test.w.example", XT_NOW_SYNTH(), &err))
	assert_strings_equal(c"x509: signature verification failed", err)
	list_free[x509_cert*](extra)
	x509_cert_free(leaf)
	x509_cert_free(inter)
	x509_store_free(store)


# ---- negative chains ------------------------------------------------------------------


void test_expired_and_not_yet_valid():
	# leaf_expired had a one-day validity ending 2026-07-11.
	xt_check_rsa_chain_leaf(c"leaf_expired.pem", c"test.w.example", 0, c"x509: certificate expired")
	# A good 2026 cert is not yet valid back in 2020.
	x509_cert* leaf = xt_load_cert(c"leaf_ec.pem")
	x509_trust_store* store = x509_store_new()
	x509_store_add(store, xt_load_cert(c"ca_rsa.pem"))
	char* err = 0
	assert_equal(0, x509_verify_chain(leaf, 0, store, c"test.w.example", XT_NOW_PAST(), &err))
	assert_strings_equal(c"x509: certificate not yet valid", err)
	x509_cert_free(leaf)
	x509_store_free(store)


void test_self_signed_leaf_rejected():
	xt_check_rsa_chain_leaf(c"selfsigned_leaf.pem", c"test.w.example", 0, c"x509: no trusted issuer found")


void test_unknown_critical_extension_rejected():
	# x509_parse must reject the whole certificate.
	char* text = xt_read_fixture(c"leaf_critext.pem")
	int skipped = 0
	list[x509_cert*] certs = pem_decode_certs(text, strlen(text), &skipped)
	assert_equal(0, certs.length)
	assert_equal(1, skipped)
	list_free[x509_cert*](certs)
	free(text)


void test_pathlen_violation():
	# ca_rsa -> int_rsa (pathlen:0) -> int_rsa2 -> leaf_deep needs int_rsa
	# to tolerate one intermediate below it, which pathlen:0 forbids.
	x509_cert* leaf = xt_load_cert(c"leaf_deep.pem")
	x509_trust_store* store = x509_store_new()
	x509_store_add(store, xt_load_cert(c"ca_rsa.pem"))
	list[x509_cert*] extra = new list[x509_cert*]
	extra.push(xt_load_cert(c"int_rsa2.pem"))
	extra.push(xt_load_cert(c"int_rsa.pem"))
	char* err = 0
	assert_equal(0, x509_verify_chain(leaf, extra, store, c"test.w.example", XT_NOW_SYNTH(), &err))
	assert_strings_equal(c"x509: path length constraint violated", err)
	int i = 0
	while (i < extra.length):
		x509_cert_free(extra[i])
		i = i + 1
	list_free[x509_cert*](extra)
	x509_cert_free(leaf)
	x509_store_free(store)


void test_truncated_and_mangled_der():
	int len = 0
	char* der = xt_load_der(c"leaf_ec.pem", &len)
	asserts(c"parses whole", x509_parse(der, len) != 0)
	# Any truncation fails.
	asserts(c"truncated tail", x509_parse(der, len - 1) == 0)
	asserts(c"truncated half", x509_parse(der, len / 2) == 0)
	asserts(c"truncated head", x509_parse(der, 3) == 0)
	asserts(c"empty", x509_parse(der, 0) == 0)
	# Trailing garbage after the certificate fails.
	char* padded = malloc(len + 1)
	int i = 0
	while (i < len):
		padded[i] = der[i]
		i = i + 1
	padded[len] = 0
	asserts(c"trailing garbage", x509_parse(padded, len + 1) == 0)
	free(padded)
	# Mangle the outer tag and the outer length.
	int save = der[0] & 255
	der[0] = 49
	asserts(c"bad outer tag", x509_parse(der, len) == 0)
	der[0] = save
	save = der[1] & 255
	der[1] = 132
	asserts(c"bad outer length", x509_parse(der, len) == 0)
	der[1] = save
	asserts(c"restored parses", x509_parse(der, len) != 0)
	free(der)


void test_verify_argument_errors():
	x509_cert* leaf = xt_load_cert(c"leaf_ec.pem")
	x509_trust_store* empty = x509_store_new()
	char* err = 0
	assert_equal(0, x509_verify_chain(leaf, 0, empty, 0, XT_NOW_SYNTH(), &err))
	assert_strings_equal(c"x509: empty trust store", err)
	assert_equal(0, x509_verify_chain(0, 0, empty, 0, XT_NOW_SYNTH(), &err))
	assert_strings_equal(c"x509: no certificate", err)
	x509_store_add(empty, xt_load_cert(c"ca_rsa.pem"))
	assert_equal(0, x509_verify_chain(leaf, 0, empty, 0, 0 - 1, &err))
	assert_strings_equal(c"x509: invalid verification time", err)
	x509_cert_free(leaf)
	x509_store_free(empty)


# ---- ECDSA signature DER conversion ---------------------------------------------------


void test_ecdsa_sig_to_raw():
	char* r32 = malloc(32)
	char* s32 = malloc(32)
	# SEQUENCE { INTEGER 1, INTEGER 2 }
	char* sig = malloc(64)
	sig[0] = 48
	sig[1] = 6
	sig[2] = 2
	sig[3] = 1
	sig[4] = 1
	sig[5] = 2
	sig[6] = 1
	sig[7] = 2
	assert_equal(1, x509_ecdsa_sig_to_raw(sig, 8, r32, s32))
	assert_equal(0, r32[0] & 255)
	assert_equal(1, r32[31] & 255)
	assert_equal(2, s32[31] & 255)
	# Trailing garbage after the SEQUENCE.
	sig[8] = 0
	assert_equal(0, x509_ecdsa_sig_to_raw(sig, 9, r32, s32))
	# Trailing garbage inside the SEQUENCE.
	sig[1] = 7
	sig[8] = 0
	assert_equal(0, x509_ecdsa_sig_to_raw(sig, 9, r32, s32))
	sig[1] = 6
	# Non-minimal r (leading zero before a low byte).
	sig[1] = 7
	sig[2] = 2
	sig[3] = 2
	sig[4] = 0
	sig[5] = 1
	sig[6] = 2
	sig[7] = 1
	sig[8] = 2
	assert_equal(0, x509_ecdsa_sig_to_raw(sig, 9, r32, s32))
	# Negative r.
	sig[1] = 6
	sig[2] = 2
	sig[3] = 1
	sig[4] = 128
	sig[5] = 2
	sig[6] = 1
	sig[7] = 2
	assert_equal(0, x509_ecdsa_sig_to_raw(sig, 8, r32, s32))
	# Oversized r: 33 magnitude bytes exceeds 256 bits.
	sig[0] = 48
	sig[1] = 40
	sig[2] = 2
	sig[3] = 33
	sig[4] = 1
	int i = 0
	while (i < 32):
		sig[5 + i] = 170
		i = i + 1
	sig[37] = 2
	sig[38] = 1
	sig[39] = 2
	assert_equal(0, x509_ecdsa_sig_to_raw(sig, 42, r32, s32))
	free(sig)
	free(r32)
	free(s32)
	# A real OpenSSL-produced ECDSA signature converts.
	int len = 0
	char* der = xt_load_der(c"leaf_ec_chain.pem", &len)
	x509_cert* c = x509_parse(der, len)
	asserts(c"leaf_ec_chain parses", c != 0)
	char* rr = malloc(32)
	char* ss = malloc(32)
	assert_equal(1, x509_ecdsa_sig_to_raw(c.der + c.sig_start, c.sig_len, rr, ss))
	free(rr)
	free(ss)
	x509_cert_free(c)
	free(der)


# ---- hostname matching -------------------------------------------------------------------


void test_hostname_rules():
	# Exact matches, case-insensitive, trailing-dot tolerant.
	assert_equal(1, x509_hostname_matches_pattern(c"example.com", c"example.com"))
	assert_equal(1, x509_hostname_matches_pattern(c"Example.COM", c"eXaMpLe.com"))
	assert_equal(1, x509_hostname_matches_pattern(c"example.com.", c"example.com"))
	assert_equal(1, x509_hostname_matches_pattern(c"example.com", c"example.com."))
	assert_equal(0, x509_hostname_matches_pattern(c"example.com", c"example.org"))
	assert_equal(0, x509_hostname_matches_pattern(c"example.com", c"www.example.com"))
	assert_equal(0, x509_hostname_matches_pattern(c"", c"example.com"))
	assert_equal(0, x509_hostname_matches_pattern(c"example.com", c""))
	# Wildcards: leftmost label only, exactly one non-empty label.
	assert_equal(1, x509_hostname_matches_pattern(c"*.example.com", c"foo.example.com"))
	assert_equal(1, x509_hostname_matches_pattern(c"*.example.com", c"FOO.Example.Com"))
	assert_equal(0, x509_hostname_matches_pattern(c"*.example.com", c"example.com"))
	assert_equal(0, x509_hostname_matches_pattern(c"*.example.com", c"a.b.example.com"))
	assert_equal(0, x509_hostname_matches_pattern(c"*.example.com", c".example.com"))
	assert_equal(0, x509_hostname_matches_pattern(c"*.example.com", c"fooexample.com"))
	# No partial-label wildcards, no wildcard past the first label.
	assert_equal(0, x509_hostname_matches_pattern(c"f*o.example.com", c"foo.example.com"))
	assert_equal(0, x509_hostname_matches_pattern(c"foo.*.com", c"foo.example.com"))
	assert_equal(0, x509_hostname_matches_pattern(c"*.*.example.com", c"a.b.example.com"))
	# A bare "*.tld" is over-broad.
	assert_equal(0, x509_hostname_matches_pattern(c"*.com", c"example.com"))
	# IPv4 literals never match dNSNames, and hostnames cannot carry '*'.
	assert_equal(0, x509_hostname_matches_pattern(c"1.2.3.4", c"1.2.3.4"))
	assert_equal(0, x509_hostname_matches_pattern(c"*.2.3.4", c"1.2.3.4"))
	assert_equal(0, x509_hostname_matches_pattern(c"*.example.com", c"*.example.com"))


# ---- time parsing --------------------------------------------------------------------------


void test_time_parsing():
	assert_equal(0, x509_days_from_civil(1970, 1, 1))
	assert_equal(24855, x509_days_from_civil(2038, 1, 19))
	assert_equal(29220, x509_days_from_civil(2050, 1, 1))
	int day = 0
	int sec = 0
	# UTCTime pivot: 49 -> 2049, 50 -> 1950.
	assert_equal(1, x509_parse_time(c"491231235959Z", 0, 13, ASN1_UTCTIME(), &day, &sec))
	assert_equal(x509_days_from_civil(2049, 12, 31), day)
	assert_equal(86399, sec)
	assert_equal(1, x509_parse_time(c"500101000000Z", 0, 13, ASN1_UTCTIME(), &day, &sec))
	assert_equal(x509_days_from_civil(1950, 1, 1), day)
	# GeneralizedTime.
	assert_equal(1, x509_parse_time(c"20500101000000Z", 0, 15, ASN1_GENERALIZEDTIME(), &day, &sec))
	assert_equal(29220, day)
	assert_equal(0, sec)
	# Leap day valid in 2024, invalid in 2050 (not a leap year).
	assert_equal(1, x509_parse_time(c"240229120000Z", 0, 13, ASN1_UTCTIME(), &day, &sec))
	assert_equal(0, x509_parse_time(c"20500229000000Z", 0, 15, ASN1_GENERALIZEDTIME(), &day, &sec))
	# Malformed forms.
	assert_equal(0, x509_parse_time(c"491231235959", 0, 12, ASN1_UTCTIME(), &day, &sec))
	assert_equal(0, x509_parse_time(c"4912312359590", 0, 13, ASN1_UTCTIME(), &day, &sec))
	assert_equal(0, x509_parse_time(c"491331235959Z", 0, 13, ASN1_UTCTIME(), &day, &sec))
	assert_equal(0, x509_parse_time(c"490100235959Z", 0, 13, ASN1_UTCTIME(), &day, &sec))
	assert_equal(0, x509_parse_time(c"491231245959Z", 0, 13, ASN1_UTCTIME(), &day, &sec))
	assert_equal(0, x509_parse_time(c"20491231235959Z", 0, 15, ASN1_UTCTIME(), &day, &sec))
	int now_day = 0
	int now_sec = 0
	x509_unix_to_day_sec(1785542400, &now_day, &now_sec)
	assert_equal(20666, now_day)
	assert_equal(0, now_sec)


# ---- PEM ------------------------------------------------------------------------------------


void test_pem_multi_block_and_garbage():
	char* a = xt_read_fixture(c"ca_rsa.pem")
	char* b = xt_read_fixture(c"ca_ec.pem")
	char* joined0 = strjoin(a, c"some text between blocks\x0a")
	char* joined = strjoin(joined0, b)
	int skipped = 0
	list[x509_cert*] certs = pem_decode_certs(joined, strlen(joined), &skipped)
	assert_equal(2, certs.length)
	assert_equal(0, skipped)
	int i = 0
	while (i < certs.length):
		x509_cert_free(certs[i])
		i = i + 1
	list_free[x509_cert*](certs)
	# A block with a stray character inside the armor is dropped.
	char* bad0 = strjoin(c"-----BEGIN CERTIFICATE-----\x0aMIIB!AAA\x0a-----END CERTIFICATE-----\x0a", a)
	list[pem_block*] blocks = pem_decode_blocks(bad0, strlen(bad0), c"CERTIFICATE")
	assert_equal(1, blocks.length)
	pem_blocks_free(blocks)
	# A BEGIN without END yields nothing.
	blocks = pem_decode_blocks(c"-----BEGIN CERTIFICATE-----\x0aMIIB\x0a", 33, c"CERTIFICATE")
	assert_equal(0, blocks.length)
	pem_blocks_free(blocks)
	# Invalid base64 padding is rejected by the strict decoder.
	blocks = pem_decode_blocks(c"-----BEGIN CERTIFICATE-----\x0aMIIB=BAD\x0a-----END CERTIFICATE-----\x0a", 63, c"CERTIFICATE")
	assert_equal(0, blocks.length)
	pem_blocks_free(blocks)
	# CRLF line endings decode fine.
	char* crlf = strjoin(c"-----BEGIN TEST-----\x0d\x0aaGVsbG8=\x0d\x0a-----END TEST-----\x0d\x0a", c"")
	blocks = pem_decode_blocks(crlf, strlen(crlf), c"TEST")
	assert_equal(1, blocks.length)
	pem_block* blk = blocks[0]
	assert_equal(5, blk.len)
	assert_strings_equal(c"hello", blk.data)
	pem_blocks_free(blocks)
	free(crlf)
	free(bad0)
	free(joined0)
	free(joined)
	free(a)
	free(b)


# ---- trust store ------------------------------------------------------------------------------


void test_trust_store_loading():
	# Build a bundle: two good CAs plus one cert that fails to parse
	# (unknown critical extension) — the loader keeps the good ones.
	char* a = xt_read_fixture(c"ca_rsa.pem")
	char* b = xt_read_fixture(c"ca_ec.pem")
	char* cst = xt_read_fixture(c"leaf_critext.pem")
	char* j0 = strjoin(a, b)
	char* bundle = strjoin(j0, cst)
	char* path = c"bin/x509_test_bundle.pem"
	asserts(c"bundle write", file_write_text(path, bundle) != 0)
	x509_trust_store* store = x509_load_trust_store(path)
	asserts(c"store loaded", store != 0)
	assert_equal(2, store.certs.length)
	# The loaded store verifies the synthetic chain.
	x509_cert* leaf = xt_load_cert(c"leaf_ec.pem")
	list[x509_cert*] extra = new list[x509_cert*]
	extra.push(xt_load_cert(c"int_rsa.pem"))
	char* err = 0
	assert_equal(1, x509_verify_chain(leaf, extra, store, c"test.w.example", XT_NOW_SYNTH(), &err))
	x509_cert_free(leaf)
	x509_cert_free(extra[0])
	list_free[x509_cert*](extra)
	x509_store_free(store)
	# A missing override path fails closed.
	asserts(c"missing file", x509_load_trust_store(c"bin/x509_missing_bundle_11aa.pem") == 0)
	# When this machine has a system bundle, the default lookup finds it
	# (skipped silently where none exists — CI images without
	# ca-certificates would otherwise fail this suite).
	char* sysbundle = file_read_text(c"/etc/ssl/certs/ca-certificates.crt")
	if (sysbundle != 0):
		free(sysbundle)
		x509_trust_store* sys = x509_load_trust_store(0)
		asserts(c"system store loads", sys != 0)
		asserts(c"system store has roots", sys.certs.length > 10)
		x509_store_free(sys)
	free(a)
	free(b)
	free(cst)
	free(j0)
	free(bundle)


# ---- EC private key loading ---------------------------------------------------------------------


char* XT_KEY_D_HEX():
	return c"24750e10a64bf51cfab4e0645be3836a83d7a9ab46bc4009c003cd9efd5ffc8e"


void test_ec_private_key_loading():
	char* want = malloc(33)
	int wlen = 0
	char* wtmp = hex_decode(XT_KEY_D_HEX(), 64, &wlen)
	assert_equal(32, wlen)
	int i = 0
	while (i < 32):
		want[i] = wtmp[i]
		i = i + 1
	free(wtmp)
	char* d1 = malloc(32)
	char* d2 = malloc(32)
	# PKCS#8 and SEC1 encodings of the same key load identically.
	char* p8 = xt_read_fixture(c"key_p256_pkcs8.pem")
	assert_equal(1, x509_load_ec_private_key(p8, strlen(p8), d1))
	char* s1 = xt_read_fixture(c"key_p256_sec1.pem")
	assert_equal(1, x509_load_ec_private_key(s1, strlen(s1), d2))
	i = 0
	while (i < 32):
		assert_equal(want[i] & 255, d1[i] & 255)
		assert_equal(d1[i] & 255, d2[i] & 255)
		i = i + 1
	# Wrong curve (P-384) fails.
	char* p384 = xt_read_fixture(c"key_p384_pkcs8.pem")
	assert_equal(0, x509_load_ec_private_key(p384, strlen(p384), d1))
	# Not a key at all.
	char* cert = xt_read_fixture(c"ca_rsa.pem")
	assert_equal(0, x509_load_ec_private_key(cert, strlen(cert), d1))
	assert_equal(0, x509_load_ec_private_key(c"garbage", 7, d1))
	free(p8)
	free(s1)
	free(p384)
	free(cert)
	free(want)
	free(d1)
	free(d2)


void test_ec_private_key_corruption():
	# Byte-surgery on the decoded PKCS#8 DER: flipping a bit of the
	# embedded public key must make loading fail (derived Q mismatch).
	char* p8 = xt_read_fixture(c"key_p256_pkcs8.pem")
	list[pem_block*] blocks = pem_decode_blocks(p8, strlen(p8), c"PRIVATE KEY")
	assert_equal(1, blocks.length)
	pem_block* b = blocks[0]
	char* d = malloc(32)
	assert_equal(1, x509_parse_pkcs8_ec_key(b.data, 0, b.len, d))
	# The embedded uncompressed point ends the structure; flip its last byte.
	b.data[b.len - 1] = b.data[b.len - 1] ^ 1
	assert_equal(0, x509_parse_pkcs8_ec_key(b.data, 0, b.len, d))
	b.data[b.len - 1] = b.data[b.len - 1] ^ 1
	# Truncated DER fails.
	assert_equal(0, x509_parse_pkcs8_ec_key(b.data, 0, b.len - 4, d))
	assert_equal(1, x509_parse_pkcs8_ec_key(b.data, 0, b.len, d))
	pem_blocks_free(blocks)
	free(p8)
	free(d)
