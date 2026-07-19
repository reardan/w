# wbuild: name=net_tls_server_test x64
/*
Tests for the TLS 1.3 server role (tls_accept, libs/standard/net/tls.w),
issue #203, part of #155.

Everything runs offline against the checked-in synthetic ECDSA P-256 cert +
key in libs/standard/net/tls_fixtures/ -- no network, no external tools.

The centrepiece is a two-way interop proof between our own client and our own
server. Because every server operation is deterministic (RFC 6979 ECDSA, a
fixed injected server ephemeral key + ServerHello random), it runs fully
in-memory as a three-pass replay:
  1. drive the server with a crafted ClientHello and capture its flight,
  2. run the real client against that flight (which succeeds only if the
     server's ECDSA CertificateVerify signature and server Finished MAC both
     verify) and capture the client Finished it emits,
  3. feed [ClientHello || clientFinished] back to a fresh server, which must
     accept the client Finished, then exchange application data both ways.
A second interop test does the same handshake over a real socketpair via
fork(), loading the cert + key from disk, exchanging app data both directions,
and closing with close_notify each way.

Negative / hostile-client tests drive the server directly in memory: a
ClientHello with no ChaCha20 suite and one with no X25519 key_share must both
fail with handshake_failure and emit NO ServerHello / HelloRetryRequest; a
length-field overflow must be rejected as decode_error without overreading; a
truncated ClientHello must fail closed; a tampered client Finished record must
trip bad_record_mac. Plus a direct CertificateVerify signature check and a
raw<->DER ECDSA signature round trip through the x509 helpers.
*/
import lib.testing
import lib.memory
import lib.net
import lib.file
import libs.standard.crypto.sha2
import libs.standard.crypto.chacha20poly1305
import libs.standard.crypto.x25519
import libs.standard.crypto.ecdsa_p256
import libs.standard.net.x509
import libs.standard.net.tls


# ---- small helpers ------------------------------------------------------------

char* tlss_cert_path():
	return c"libs/standard/net/tls_fixtures/server_p256_cert.pem"


char* tlss_key_path():
	return c"libs/standard/net/tls_fixtures/server_p256_key.pem"


# Fill n bytes of buf with a deterministic non-trivial pattern.
void tlss_fill(char* buf, int n, int seed):
	int i = 0
	while (i < n):
		buf[i] = (seed + i * 7 + (i >> 3)) & 255
		i = i + 1


int tlss_bytes_equal(char* a, char* b, int n):
	int i = 0
	int diff = 0
	while (i < n):
		diff = diff | ((a[i] & 255) ^ (b[i] & 255))
		i = i + 1
	return diff == 0


# Wrap a handshake message in a TLS plaintext record (content type 22).
char* tlss_wrap_handshake(char* msg, int mlen, int* out_len):
	char* rec = malloc(5 + mlen)
	rec[0] = 22
	rec[1] = 3
	rec[2] = 3
	rec[3] = (mlen >> 8) & 255
	rec[4] = mlen & 255
	int i = 0
	while (i < mlen):
		rec[5 + i] = msg[i]
		i = i + 1
	*out_len = 5 + mlen
	return rec


# Load the fixture cert + key PEM bytes into a fresh server config (injected).
tls_server_config* tlss_config_inmem():
	tls_server_config* scfg = tls_server_config_new()
	char* cert = file_read_text(tlss_cert_path())
	asserts(c"tlss: cert fixture missing", cert != 0)
	char* key = file_read_text(tlss_key_path())
	asserts(c"tlss: key fixture missing", key != 0)
	scfg.test_cert_pem = cert
	scfg.test_cert_pem_len = strlen(cert)
	scfg.test_key_pem = key
	scfg.test_key_pem_len = strlen(key)
	return scfg


void tlss_config_inmem_free(tls_server_config* scfg):
	if (scfg.test_cert_pem != 0):
		free(scfg.test_cert_pem)
	if (scfg.test_key_pem != 0):
		free(scfg.test_key_pem)
	tls_server_config_free(scfg)


# Build the standard test ClientHello (chacha + x25519 + tls13 + ecdsa) whose
# key_share carries the public key of client_priv. Returns the handshake
# message (not record-wrapped); *out_len its length.
char* tlss_build_client_hello(char* client_priv, int* out_len):
	char* pub = malloc(32)
	x25519_scalarmult_base(pub, client_priv)
	char* rnd = malloc(32)
	char* sid = malloc(32)
	tlss_fill(rnd, 32, 0x11)
	tlss_fill(sid, 32, 0x40)
	char* ch = tls_build_client_hello(c"test.w.example", rnd, sid, pub, out_len)
	free(pub)
	free(rnd)
	free(sid)
	return ch


# Run the server handshake in memory against a preloaded client flight,
# returning the raw connection (even on failure) so the test can inspect
# mem_out / broken. The caller frees with tls_conn_free.
tls_conn* tlss_run_server(char* client_flight, int flen, tls_server_config* scfg, int* out_ok):
	tls_conn* c = tls_conn_new(0 - 1, 1, 0)
	c.is_server = 1
	c.scfg = scfg
	wbuf_bytes(c.mem_in, client_flight, flen)
	*out_ok = tls_server_do_handshake(c)
	return c


# ---- raw <-> DER ECDSA signature round trip -----------------------------------

void tlss_check_der_roundtrip(int r_seed, int s_seed):
	char* r = malloc(32)
	char* s = malloc(32)
	tlss_fill(r, 32, r_seed)
	tlss_fill(s, 32, s_seed)
	char* der = malloc(80)
	int der_len = 0
	asserts(c"raw_to_der ok", x509_ecdsa_sig_raw_to_der(r, s, der, &der_len) != 0)
	# DER SEQUENCE of two INTEGERs; total length is short-form.
	assert_equal(0x30, der[0] & 255)
	assert_equal(der_len - 2, der[1] & 255)
	char* r2 = malloc(32)
	char* s2 = malloc(32)
	asserts(c"sig_to_raw ok", x509_ecdsa_sig_to_raw(der, der_len, r2, s2) != 0)
	asserts(c"r round trip", tlss_bytes_equal(r, r2, 32) != 0)
	asserts(c"s round trip", tlss_bytes_equal(s, s2, 32) != 0)
	free(r)
	free(s)
	free(der)
	free(r2)
	free(s2)


void test_ecdsa_sig_der_roundtrip():
	# High-bit-set leading byte (needs a 0x00 pad) in both r and s.
	tlss_check_der_roundtrip(0x80, 0x91)
	# Small leading byte (no pad) and a value with a leading zero byte.
	tlss_check_der_roundtrip(0x01, 0x00)
	tlss_check_der_roundtrip(0x7f, 0xff)


# ---- CertificateVerify signing ------------------------------------------------

# The server's emitted CertificateVerify signature must verify under the leaf
# certificate's public key, use scheme ecdsa_secp256r1_sha256, and the leaf
# key must match the loaded private key.
void test_server_certverify_signature():
	char* cert_pem = file_read_text(tlss_cert_path())
	asserts(c"cert fixture", cert_pem != 0)
	char* key_pem = file_read_text(tlss_key_path())
	asserts(c"key fixture", key_pem != 0)

	int skipped = 0
	list[x509_cert*] certs = pem_decode_certs(cert_pem, strlen(cert_pem), &skipped)
	asserts(c"one leaf parsed", certs.length == 1)
	x509_cert* leaf = certs[0]
	assert_equal(X509_KEY_EC_P256(), leaf.key_type)

	char* d = malloc(32)
	asserts(c"key loads", x509_load_ec_private_key(key_pem, strlen(key_pem), d) != 0)

	# Private key matches the certificate's public key.
	char* qx = malloc(32)
	char* qy = malloc(32)
	asserts(c"pubkey derive", ecdsa_p256_public_key(d, qx, qy) != 0)
	asserts(c"qx matches cert", tlss_bytes_equal(qx, leaf.ec_qx, 32) != 0)
	asserts(c"qy matches cert", tlss_bytes_equal(qy, leaf.ec_qy, 32) != 0)

	# Build a CertificateVerify over a fixed transcript hash, then verify it.
	char* th = malloc(32)
	tlss_fill(th, 32, 0xab)
	int cv_len = 0
	char* cv = tls_build_certverify(d, th, 32, &cv_len)
	asserts(c"certverify built", cv != 0)
	# type(1) + len(3) + scheme(2) + siglen(2) + sig
	assert_equal(TLS_HS_CERTIFICATE_VERIFY(), cv[0] & 255)
	int scheme = ((cv[4] & 255) << 8) | (cv[5] & 255)
	assert_equal(TLS_SIG_ECDSA_SECP256R1_SHA256(), scheme)
	int sig_len = ((cv[6] & 255) << 8) | (cv[7] & 255)
	assert_equal(cv_len - 8, sig_len)

	# Recompute the signed content digest and check the signature.
	int clen = 0
	char* content = tls_certverify_content(th, 32, &clen)
	char* digest = malloc(32)
	whash_oneshot(WHASH_SHA256(), content, clen, digest)
	free(content)
	char* r = malloc(32)
	char* s = malloc(32)
	asserts(c"sig der->raw", x509_ecdsa_sig_to_raw(cv + 8, sig_len, r, s) != 0)
	asserts(c"sig verifies", ecdsa_p256_verify(leaf.ec_qx, leaf.ec_qy, digest, 32, r, s) != 0)

	free(digest)
	free(r)
	free(s)
	free(cv)
	free(th)
	free(qx)
	free(qy)
	free(d)
	x509_cert_free(leaf)
	list_free[x509_cert*](certs)
	free(cert_pem)
	free(key_pem)


# ---- in-memory client<->server interop ----------------------------------------

# Produce the server's flight for a given ClientHello record, using a fixed
# injected server ephemeral key + random so the flight is deterministic. The
# server run fails (no client Finished follows) but its flight is captured.
char* tlss_server_flight(char* chrec, int chrec_len, char* server_priv, char* server_random, int* out_len):
	tls_server_config* scfg = tlss_config_inmem()
	scfg.test_priv = server_priv
	scfg.test_random = server_random
	int ok = 0
	tls_conn* s = tlss_run_server(chrec, chrec_len, scfg, &ok)
	# The server sent its whole flight before hitting EOF on the missing
	# client Finished.
	char* flight = tls_mem_take_output(s, out_len)
	tls_conn_free(s)
	tlss_config_inmem_free(scfg)
	return flight


void test_server_client_interop_inmem():
	char* client_priv = malloc(32)
	char* server_priv = malloc(32)
	char* server_random = malloc(32)
	tlss_fill(client_priv, 32, 0x21)
	tlss_fill(server_priv, 32, 0x55)
	tlss_fill(server_random, 32, 0x66)

	# ClientHello (message + plaintext record).
	int ch_len = 0
	char* ch = tlss_build_client_hello(client_priv, &ch_len)
	int chrec_len = 0
	char* chrec = tlss_wrap_handshake(ch, ch_len, &chrec_len)

	# Pass 1: capture the server flight.
	int flight_len = 0
	char* flight = tlss_server_flight(chrec, chrec_len, server_priv, server_random, &flight_len)
	asserts(c"server produced a flight", flight_len > 0)

	# Pass 2: run the real client against the flight. Success proves the
	# server's ECDSA CertificateVerify signature and server Finished verified.
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	cfg.test_priv = client_priv
	cfg.test_client_hello = ch
	cfg.test_client_hello_len = ch_len
	tls_conn* client = tls_connect_mem(flight, flight_len, c"test.w.example", cfg)
	asserts(c"client completes handshake vs our server", client != 0)

	# The client emitted ClientHello + clientFinished; isolate the Finished.
	int cout_len = 0
	char* cout = tls_mem_take_output(client, &cout_len)
	int ch_rec_len = 5 + (((cout[3] & 255) << 8) | (cout[4] & 255))
	int fin_len = cout_len - ch_rec_len

	# Pass 3: a fresh server must accept [ClientHello || clientFinished].
	char* full = malloc(chrec_len + fin_len)
	int i = 0
	while (i < chrec_len):
		full[i] = chrec[i]
		i = i + 1
	i = 0
	while (i < fin_len):
		full[chrec_len + i] = cout[ch_rec_len + i]
		i = i + 1
	tls_server_config* scfg = tlss_config_inmem()
	scfg.test_priv = server_priv
	scfg.test_random = server_random
	int ok = 0
	tls_conn* server = tlss_run_server(full, chrec_len + fin_len, scfg, &ok)
	asserts(c"server accepts client Finished", ok != 0)
	asserts(c"server not broken", server.broken == 0)

	# Application data both directions through the aligned record keys.
	char* junk = tls_mem_take_output(server, &i)   # discard nothing meaningful
	free(junk)

	# server -> client
	char* smsg = c"hello from the W server"
	int smsg_len = strlen(smsg)
	assert_equal(smsg_len, tls_write(server, smsg, smsg_len))
	int sout_len = 0
	char* sout = tls_mem_take_output(server, &sout_len)
	tls_mem_feed(client, sout, sout_len)
	char* rbuf = malloc(256)
	int got = tls_read(client, rbuf, 256)
	assert_equal(smsg_len, got)
	asserts(c"server->client payload", tlss_bytes_equal(smsg, rbuf, smsg_len) != 0)
	free(sout)

	# client -> server
	char* cmsg = c"and hello back from the W client"
	int cmsg_len = strlen(cmsg)
	assert_equal(cmsg_len, tls_write(client, cmsg, cmsg_len))
	int cdat_len = 0
	char* cdat = tls_mem_take_output(client, &cdat_len)
	tls_mem_feed(server, cdat, cdat_len)
	int got2 = tls_read(server, rbuf, 256)
	assert_equal(cmsg_len, got2)
	asserts(c"client->server payload", tlss_bytes_equal(cmsg, rbuf, cmsg_len) != 0)
	free(cdat)

	free(rbuf)
	tls_conn_free(server)
	tlss_config_inmem_free(scfg)
	free(full)
	free(cout)
	tls_conn_free(client)
	tls_config_free(cfg)
	free(flight)
	free(chrec)
	free(ch)
	free(client_priv)
	free(server_priv)
	free(server_random)


# ---- negative / hostile-client ------------------------------------------------

# A well-formed ClientHello that does not offer TLS_CHACHA20_POLY1305_SHA256
# must be answered with a fatal handshake_failure alert and NO ServerHello
# (and therefore no HelloRetryRequest).
void test_server_no_chacha_rejected():
	char* client_priv = malloc(32)
	tlss_fill(client_priv, 32, 0x21)
	int ch_len = 0
	char* ch = tlss_build_client_hello(client_priv, &ch_len)
	# cipher_suites: the single suite sits at message bytes 73..74.
	ch[73] = 0x13
	ch[74] = 0x01               # TLS_AES_128_GCM_SHA256 instead of ChaCha20
	int chrec_len = 0
	char* chrec = tlss_wrap_handshake(ch, ch_len, &chrec_len)

	tls_server_config* scfg = tlss_config_inmem()
	int ok = 0
	tls_conn* s = tlss_run_server(chrec, chrec_len, scfg, &ok)
	asserts(c"no-chacha handshake fails", ok == 0)
	asserts(c"connection broken", s.broken == 1)
	int out_len = 0
	char* out = tls_mem_take_output(s, &out_len)
	# Exactly one plaintext alert record: fatal handshake_failure. No
	# handshake record (type 22) means no ServerHello / HelloRetryRequest.
	assert_equal(7, out_len)
	assert_equal(TLS_CT_ALERT(), out[0] & 255)
	assert_equal(TLS_ALERT_FATAL(), out[5] & 255)
	assert_equal(TLS_ALERT_HANDSHAKE_FAILURE(), out[6] & 255)
	free(out)
	tls_conn_free(s)
	tlss_config_inmem_free(scfg)
	free(chrec)
	free(ch)
	free(client_priv)


# A ClientHello whose only key_share is not X25519 must be answered with
# handshake_failure and NO ServerHello (no HelloRetryRequest in MVP).
void test_server_no_x25519_rejected():
	char* client_priv = malloc(32)
	tlss_fill(client_priv, 32, 0x21)
	int ch_len = 0
	char* ch = tlss_build_client_hello(client_priv, &ch_len)
	# key_share group sits 36 bytes from the end (before kx_len + 32-byte key).
	ch[ch_len - 36] = 0x00
	ch[ch_len - 35] = 0x17      # secp256r1 instead of x25519
	int chrec_len = 0
	char* chrec = tlss_wrap_handshake(ch, ch_len, &chrec_len)

	tls_server_config* scfg = tlss_config_inmem()
	int ok = 0
	tls_conn* s = tlss_run_server(chrec, chrec_len, scfg, &ok)
	asserts(c"no-x25519 handshake fails", ok == 0)
	asserts(c"connection broken", s.broken == 1)
	int out_len = 0
	char* out = tls_mem_take_output(s, &out_len)
	assert_equal(7, out_len)
	assert_equal(TLS_CT_ALERT(), out[0] & 255)
	assert_equal(TLS_ALERT_HANDSHAKE_FAILURE(), out[6] & 255)
	free(out)
	tls_conn_free(s)
	tlss_config_inmem_free(scfg)
	free(chrec)
	free(ch)
	free(client_priv)


# A ClientHello with a length field that overruns the message must be rejected
# as decode_error with no overread / crash.
void test_server_oversized_length_field():
	# Minimal ClientHello body: version + 32-byte random + empty session_id +
	# a cipher_suites length of 0xffff with no suite bytes present.
	char* body = malloc(37)
	body[0] = 0x03
	body[1] = 0x03
	int i = 0
	while (i < 32):
		body[2 + i] = 0
		i = i + 1
	body[34] = 0                # legacy_session_id length
	body[35] = 0xff             # cipher_suites length high byte (overflow)
	body[36] = 0xff
	char* msg = malloc(41)
	msg[0] = TLS_HS_CLIENT_HELLO()
	msg[1] = 0
	msg[2] = 0
	msg[3] = 37
	i = 0
	while (i < 37):
		msg[4 + i] = body[i]
		i = i + 1
	int chrec_len = 0
	char* chrec = tlss_wrap_handshake(msg, 41, &chrec_len)

	tls_server_config* scfg = tlss_config_inmem()
	int ok = 0
	tls_conn* s = tlss_run_server(chrec, chrec_len, scfg, &ok)
	asserts(c"oversized length rejected", ok == 0)
	asserts(c"connection broken", s.broken == 1)
	int out_len = 0
	char* out = tls_mem_take_output(s, &out_len)
	assert_equal(TLS_CT_ALERT(), out[0] & 255)
	assert_equal(TLS_ALERT_DECODE_ERROR(), out[6] & 255)
	free(out)
	tls_conn_free(s)
	tlss_config_inmem_free(scfg)
	free(chrec)
	free(msg)
	free(body)


# A truncated ClientHello (record ends mid-message) must fail closed with no
# crash.
void test_server_truncated_clienthello():
	char* client_priv = malloc(32)
	tlss_fill(client_priv, 32, 0x21)
	int ch_len = 0
	char* ch = tlss_build_client_hello(client_priv, &ch_len)
	# Wrap only the first 20 bytes of the handshake message: the u24 length
	# still advertises the full body, so the reassembler waits for bytes that
	# never arrive.
	int chrec_len = 0
	char* chrec = tlss_wrap_handshake(ch, 20, &chrec_len)

	tls_server_config* scfg = tlss_config_inmem()
	int ok = 0
	tls_conn* s = tlss_run_server(chrec, chrec_len, scfg, &ok)
	asserts(c"truncated ClientHello fails", ok == 0)
	tls_conn_free(s)
	tlss_config_inmem_free(scfg)
	free(chrec)
	free(ch)
	free(client_priv)


# A tampered client Finished record (flipped ciphertext byte) must trip
# bad_record_mac when the server tries to decrypt it.
void test_server_tampered_client_finished():
	char* client_priv = malloc(32)
	char* server_priv = malloc(32)
	char* server_random = malloc(32)
	tlss_fill(client_priv, 32, 0x21)
	tlss_fill(server_priv, 32, 0x55)
	tlss_fill(server_random, 32, 0x66)

	int ch_len = 0
	char* ch = tlss_build_client_hello(client_priv, &ch_len)
	int chrec_len = 0
	char* chrec = tlss_wrap_handshake(ch, ch_len, &chrec_len)

	int flight_len = 0
	char* flight = tlss_server_flight(chrec, chrec_len, server_priv, server_random, &flight_len)

	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	cfg.test_priv = client_priv
	cfg.test_client_hello = ch
	cfg.test_client_hello_len = ch_len
	tls_conn* client = tls_connect_mem(flight, flight_len, c"test.w.example", cfg)
	asserts(c"client handshake for tamper setup", client != 0)
	int cout_len = 0
	char* cout = tls_mem_take_output(client, &cout_len)
	int ch_rec_len = 5 + (((cout[3] & 255) << 8) | (cout[4] & 255))
	int fin_len = cout_len - ch_rec_len

	# Assemble [ClientHello || clientFinished] and flip a ciphertext byte in
	# the Finished record (offset 5 = first byte past the record header).
	char* full = malloc(chrec_len + fin_len)
	int i = 0
	while (i < chrec_len):
		full[i] = chrec[i]
		i = i + 1
	i = 0
	while (i < fin_len):
		full[chrec_len + i] = cout[ch_rec_len + i]
		i = i + 1
	full[chrec_len + 5] = full[chrec_len + 5] ^ 0xff

	tls_server_config* scfg = tlss_config_inmem()
	scfg.test_priv = server_priv
	scfg.test_random = server_random
	int ok = 0
	tls_conn* server = tlss_run_server(full, chrec_len + fin_len, scfg, &ok)
	asserts(c"tampered client Finished rejected", ok == 0)
	asserts(c"server broken after bad mac", server.broken == 1)

	tls_conn_free(server)
	tlss_config_inmem_free(scfg)
	free(full)
	free(cout)
	tls_conn_free(client)
	tls_config_free(cfg)
	free(flight)
	free(chrec)
	free(ch)
	free(client_priv)
	free(server_priv)
	free(server_random)


# ---- real-socket loopback (fork) ----------------------------------------------

# Our client and our server complete a full handshake over a socketpair,
# exchange application data both directions, and close with close_notify each
# way. The server loads its cert + key from disk (exercising the file path);
# the client trusts the leaf with insecure_skip_verify but still verifies the
# ECDSA CertificateVerify signature and both Finished MACs.
void test_server_loopback_fork():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socketpair", socket_pair(fds) >= 0)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		# Child: the TLS server.
		close(fds[0])
		tls_server_config* scfg = tls_server_config_new()
		scfg.cert_chain_path = tlss_cert_path()
		scfg.key_path = tlss_key_path()
		tls_conn* s = tls_accept(fds[1], scfg)
		if (s == 0):
			exit(11)
		char* buf = malloc(256)
		int got = tls_read(s, buf, 256)
		if (got <= 0):
			exit(12)
		# Echo a fixed response.
		char* reply = c"pong from tls_accept"
		if (tls_write(s, reply, strlen(reply)) != strlen(reply)):
			exit(13)
		# Expect the client's close_notify (clean EOF).
		if (tls_read(s, buf, 256) != 0):
			exit(14)
		tls_close(s)
		exit(0)

	# Parent: the TLS client.
	close(fds[1])
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	tls_conn* c = tls_connect(fds[0], c"test.w.example", cfg)
	asserts(c"client connects to our server", c != 0)
	char* ping = c"ping to tls_accept"
	assert_equal(strlen(ping), tls_write(c, ping, strlen(ping)))
	char* buf = malloc(256)
	int got = tls_read(c, buf, 256)
	char* reply = c"pong from tls_accept"
	assert_equal(strlen(reply), got)
	asserts(c"server reply payload", tlss_bytes_equal(reply, buf, got) != 0)
	tls_close(c)
	free(buf)
	tls_config_free(cfg)
	int status = 0
	wait4(pid, &status, 0, 0)
	asserts(c"server child exited cleanly", status == 0)
	close(fds[0])
	free(fds)
