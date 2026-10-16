# wbuild: name=net_tls_resumption_loopback_test x64
/*
Offline PSK-DHE end-to-end regression: one verified certificate handshake
issues a ticket, then a small fixture peer accepts that PSK without sending
Certificate or CertificateVerify. The client uses its real socket handshake,
cache lookup, binder, Finished verification, and application record paths.
The fixture peer deliberately implements only this test exchange, not a
production ticket service. No OpenSSL, DNS, or external network is required.
*/
import lib.testing
import lib.net
import lib.mem
import libs.standard.net.tls


char* tlsrl_cert():
	return c"libs/standard/distributed/raft_tls_fixtures/server.pem"


# The server handshake transcript stops before client Finished. Include the
# authenticated Finished retained in hs_buf before deriving the ticket PSK.
void tlsrl_issue_ticket(tls_conn* c, char* psk):
	int ds = c.digest_size
	char[48] digest_buf
	char* digest = cast(char*, digest_buf)
	char[48] master_buf
	char* master = cast(char*, master_buf)
	whash_update(c.transcript, c.hs_buf.data + c.hs_pos - ds - 4, ds + 4)
	whash_final(c.transcript, digest)
	tls13_hkdf_expand_label(c.hash_alg, c.master_secret, c"res master", 10, digest, ds, master, ds)
	tls13_hkdf_expand_label(c.hash_alg, master, c"resumption", 10, c"N", 1, psk, ds)
	tls_wipe(master, 48)
	# lifetime, age_add, nonce, opaque ticket, empty extensions.
	char[32] msg_buf
	char* msg = cast(char*, msg_buf)
	mem_fill(cast(char*, msg), 0, 32)
	msg[0] = TLS_HS_NEW_SESSION_TICKET
	store_be24(msg + 1, 28)
	store_be32(msg + 4, 3600)
	store_be32(msg + 8, 23)
	msg[12] = 1
	msg[13] = 'N'
	store_be16(msg + 14, 14)
	mem_copy(msg + 16, c"offline-ticket", 14)
	assert_equal(1, tls_send_record(c, TLS_CT_HANDSHAKE, msg, 32, 1))


# Check the real client's offered identity and binder independently of its
# ClientHello construction helper, before accepting the ticket.
void tlsrl_verify_binder(tls_conn* c, char* psk):
	char* msg = c.hello.data
	int pos = tls_hello_extensions(msg, c.hello.length) + 2
	int found = 0
	while (pos + 4 <= c.hello.length):
		int kind = load_be16(msg + pos)
		int len = load_be16(msg + pos + 2)
		if (kind == TLS_EXT_PRE_SHARED_KEY):
			assert_equal(c.hello.length, pos + 4 + len)
			int body = pos + 4
			assert_equal(20, load_be16(msg + body))
			assert_equal(14, load_be16(msg + body + 2))
			asserts(c"ticket identity", mem_eq(msg + body + 4, c"offline-ticket", 14))
			int truncated = body + 22
			int ds = c.digest_size
			assert_equal(ds + 1, load_be16(msg + truncated))
			assert_equal(ds, msg[truncated + 2] & 255)
			char[48] early_buf
			char* early = cast(char*, early_buf)
			char[48] binder_key_buf
			char* binder_key = cast(char*, binder_key_buf)
			char[48] finished_buf
			char* finished = cast(char*, finished_buf)
			char[48] digest_buf
			char* digest = cast(char*, digest_buf)
			char[48] expected_buf
			char* expected = cast(char*, expected_buf)
			hkdf_extract(c.hash_alg, c"", 0, psk, ds, early)
			tls13_derive_secret(c.hash_alg, early, c"res binder", 10, c"", 0, binder_key)
			tls_finished_key(c.hash_alg, binder_key, finished)
			whash* h = whash_new(c.hash_alg)
			whash_update(h, msg, truncated)
			whash_final(h, digest)
			whash_free(h)
			hmac_compute(c.hash_alg, finished, ds, digest, ds, expected)
			asserts(c"valid resumption binder", hmac_equal(expected, msg + truncated + 3, ds))
			found = 1
		pos += 4 + len
	assert_equal(1, found)


# Only EncryptedExtensions and Finished follow ServerHello here. Success
# therefore proves the client took the certificate-free PSK path.
tls_conn* tlsrl_accept_psk(int fd, tls_server_config* cfg, char* psk):
	tls_conn* c = tls_conn_new(fd, 0, 0)
	c.is_server = 1
	c.scfg = cfg
	char[32] sid_buf
	char* sid = cast(char*, sid_buf)
	char[65] peer_buf
	char* peer = cast(char*, peer_buf)
	int sid_len = 0
	assert_equal(1, tls_server_read_client_hello(c, sid, &sid_len, peer))
	tlsrl_verify_binder(c, psk)
	c.resumed = 1
	tls_session* session = new tls_session()
	session.server_name = 0
	session.context = 0
	session.ticket = 0
	session.nonce = 0
	session.ticket_len = 0
	session.peer_certificate_sha256 = 0
	session.psk = cast(char*, malloc(48))
	mem_copy(session.psk, psk, 48)
	c.offered_session = session
	char[32] priv_buf
	char* priv = cast(char*, priv_buf)
	char[65] pub_buf
	char* pub = cast(char*, pub_buf)
	char[32] random_buf
	char* random = cast(char*, random_buf)
	assert_equal(1, tls_make_key_share(c, c.key_group, priv, pub, 1))
	assert_equal(1, tls_server_gen_random(c, random))
	int sh_len = 0
	char* sh = tls_build_server_hello_group(random, sid, sid_len, pub, c.cipher_suite, c.key_group, &sh_len)
	sh = cast(char*, realloc(sh, sh_len, sh_len + 6))
	store_be16(sh + sh_len, TLS_EXT_PRE_SHARED_KEY)
	store_be16(sh + sh_len + 2, 2)
	store_be16(sh + sh_len + 4, 0)
	sh_len += 6
	store_be24(sh + 1, sh_len - 4)
	store_be16(sh + 42 + sid_len, sh_len - 44 - sid_len)
	whash_update(c.transcript, sh, sh_len)
	assert_equal(1, tls_send_record(c, TLS_CT_HANDSHAKE, sh, sh_len, 0))
	free(sh)
	char[32] shared_buf
	char* shared = cast(char*, shared_buf)
	assert_equal(1, tls_shared_secret(c.key_group, priv, peer, shared))
	int ds = c.digest_size
	char[48] digest_buf
	char* digest = cast(char*, digest_buf)
	char[48] hs_secret_buf
	char* hs_secret = cast(char*, hs_secret_buf)
	whash_final(c.transcript, digest)
	tls_derive_handshake(c, shared, digest, hs_secret)
	tls_install_write_keys(c, c.s_hs_secret)
	tls_install_read_keys(c, c.c_hs_secret)
	int ee_len = 0
	char* ee = tls_build_encrypted_extensions_alpn(0, &ee_len)
	whash_update(c.transcript, ee, ee_len)
	assert_equal(1, tls_send_record(c, TLS_CT_HANDSHAKE, ee, ee_len, 1))
	free(ee)
	whash_final(c.transcript, digest)
	char[48] finished_key_buf
	char* finished_key = cast(char*, finished_key_buf)
	char[52] fin_buf
	char* fin = cast(char*, fin_buf)
	tls_finished_key(c.hash_alg, c.s_hs_secret, finished_key)
	fin[0] = TLS_HS_FINISHED
	store_be24(fin + 1, ds)
	hmac_compute(c.hash_alg, finished_key, ds, digest, ds, fin + 4)
	whash_update(c.transcript, fin, ds + 4)
	assert_equal(1, tls_send_record(c, TLS_CT_HANDSHAKE, fin, ds + 4, 1))
	whash_final(c.transcript, digest)
	tls_derive_application(c, hs_secret, digest)
	tls_install_write_keys(c, c.s_ap_secret)
	assert_equal(1, tls_server_read_client_finished(c))
	return c


void tlsrl_loopback(int suite):
	int[2] first_buf
	int* first = cast(int*, first_buf)
	int[2] second_buf
	int* second = cast(int*, second_buf)
	asserts(c"first socketpair", socket_pair(first) >= 0)
	asserts(c"second socketpair", socket_pair(second) >= 0)
	for i in range(2):
		socket_set_recv_timeout(first[i], 10000)
		socket_set_send_timeout(first[i], 10000)
		socket_set_recv_timeout(second[i], 10000)
		socket_set_send_timeout(second[i], 10000)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		close(first[0])
		close(second[0])
		tls_server_config* cfg = tls_server_config_new()
		cfg.cert_chain_path = tlsrl_cert()
		cfg.key_path = c"libs/standard/distributed/raft_tls_fixtures/server_key.pem"
		cfg.cipher_suite = suite
		char[48] psk_buf
		char* psk = cast(char*, psk_buf)
		mem_fill(cast(char*, psk), 0, 48)
		char[8] buf_buf
		char* buf = cast(char*, buf_buf)
		int full_handshakes = 0
		for round in range(2):
			int fd = first[1]
			if (round): fd = second[1]
			tls_conn* c = 0
			if (round == 0):
				c = tls_accept(fd, cfg)
				asserts(tls_server_last_error(cfg), c != 0)
				full_handshakes += 1
			else: c = tlsrl_accept_psk(fd, cfg, psk)
			# Wait until the client has released its temporary config.
			assert_equal(4, tls_read(c, buf, 8))
			asserts(c"client request", mem_eq(buf, c"ping", 4))
			if (round == 0): tlsrl_issue_ticket(c, psk)
			assert_equal(4, tls_write(c, c"pong", 4))
			assert_equal(0, tls_read(c, buf, 8))
			tls_close(c)
			close(fd)
		assert_equal(1, full_handshakes)
		tls_server_config_free(cfg)
		exit(0)
	close(first[1])
	close(second[1])
	tls_session_cache* cache = tls_session_cache_new()
	for round in range(2):
		int fd = first[0]
		if (round): fd = second[0]
		tls_config* cfg = tls_config_new()
		cfg.trust_store_path = c"libs/standard/distributed/raft_tls_fixtures/ca.pem"
		cfg.session_cache = cache
		cfg.server_port = 443
		tls_conn* c = tls_connect(fd, c"test.w.example", cfg)
		asserts(tls_last_error(cfg), c != 0)
		assert_equal(round, c.resumed)
		assert_equal(1, c.peer_verified)
		# Checked transports discard their handshake config this way.
		c.cfg = 0
		tls_config_free(cfg)
		assert_equal(4, tls_write(c, c"ping", 4))
		char[8] buf_buf
		char* buf = cast(char*, buf_buf)
		assert_equal(4, tls_read(c, buf, 8))
		asserts(c"application response", mem_eq(buf, c"pong", 4))
		assert_equal(1 - round, cache.entries.length)
		tls_close(c)
		close(fd)
	tls_session_cache_free(cache)
	int status = 0
	wait4(pid, &status, 0, 0)
	assert_equal(0, status)


void test_resumption_loopback_sha256():
	tlsrl_loopback(TLS_SUITE_AES_128_GCM_SHA256)


void test_resumption_loopback_sha384():
	tlsrl_loopback(TLS_SUITE_AES_256_GCM_SHA384)
