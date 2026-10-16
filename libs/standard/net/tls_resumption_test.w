# wbuild: name=net_tls_resumption_test x64
# Offline cache policy, ticket framing, lifetime and binder regression tests.
import lib.testing
import libs.standard.net.tls


tls_config* tr_config(tls_session_cache* cache):
	tls_config* cfg = tls_config_new()
	cfg.session_cache = cache
	cfg.server_port = 443
	cfg.trust_store_path = c"libs/standard/net/x509_fixtures/ca_ec.pem"
	return cfg


string_builder* tr_ticket():
	string_builder* msg = string_new()
	string_append_char(msg, TLS_HS_NEW_SESSION_TICKET)
	string_append_be24(msg, 0)
	string_append_bytes(msg, c"\x00\x00\x00\x3c\xff\xff\xff\xf0", 8)
	string_append_char(msg, 2)
	string_append_bytes(msg, c"ab", 2)
	string_append_be16(msg, 6)
	string_append_bytes(msg, c"ticket", 6)
	string_append_be16(msg, 0)
	store_be24(msg.data + 1, msg.length - 4)
	return msg


tls_conn* tr_issuer(tls_config* cfg):
	tls_conn* c = tls_conn_new(-1, 1, cfg)
	tls_session_prepare(c, c"localhost")
	c.peer_verified = 1
	c.resumption_ready = 1
	mem_fill(c.resumption_master, 0x42, 48)
	return c


void test_resumption_ticket_validation_and_fragmentation():
	tls_session_cache* cache = tls_session_cache_new()
	tls_config* cfg = tr_config(cache)
	tls_conn* c = tr_issuer(cfg)
	string_builder* ticket = tr_ticket()
	for n in range(ticket.length): assert_equal(0, tls_session_ticket(c, ticket.data, n))
	# Checked transport may release cfg immediately after handshake.
	c.cfg = 0
	tls_config_free(cfg)
	tls_post_handshake(c, ticket.data, 3)
	assert_equal(0, cache.entries.length)
	tls_post_handshake(c, ticket.data + 3, ticket.length - 3)
	assert_equal(0, c.broken)
	assert_equal(1, cache.entries.length)
	tls_session* session = cache.entries[0]
	char[48] expected
	tls13_hkdf_expand_label(c.hash_alg, c.resumption_master, c"resumption", 10, c"ab", 2, expected, 32)
	assert_bytes_equal(expected, session.psk, 32)
	assert_equal(60, session.lifetime)
	assert_equal(6, session.ticket_len)
	assert_bytes_equal(c"ticket", session.ticket, 6)
	# Coalesced messages replace the prior ticket rather than growing unbounded.
	string_builder* both = string_new()
	string_append_bytes(both, ticket.data, ticket.length)
	string_append_bytes(both, ticket.data, ticket.length)
	tls_post_handshake(c, both.data, both.length)
	assert_equal(1, cache.entries.length)
	assert_equal(0, c.broken)
	string_free(both)
	tls_session_cache_clear(cache)
	store_be32(ticket.data + 4, 0)
	assert_equal(1, tls_session_ticket(c, ticket.data, ticket.length))
	store_be32(ticket.data + 4, 604801)
	assert_equal(1, tls_session_ticket(c, ticket.data, ticket.length))
	store_be32(ticket.data + 4, cast(int, 0xffffffff))
	assert_equal(1, tls_session_ticket(c, ticket.data, ticket.length))
	assert_equal(0, cache.entries.length)
	# Empty ticket, invalid extension vector, duplicate extension are rejected.
	store_be32(ticket.data + 4, 60)
	store_be16(ticket.data + 15, 0)
	assert_equal(0, tls_session_ticket(c, ticket.data, ticket.length))
	store_be16(ticket.data + 15, 6)
	store_be16(ticket.data + ticket.length - 2, 8)
	string_append_bytes(ticket, c"\x00\x99\x00\x00\x00\x99\x00\x00", 8)
	store_be24(ticket.data + 1, ticket.length - 4)
	assert_equal(0, tls_session_ticket(c, ticket.data, ticket.length))
	tls_post_handshake(c, ticket.data, ticket.length)
	assert_equal(1, c.broken)
	string_free(ticket)
	tls_conn_free(c)
	tls_session_cache_free(cache)


void test_resumption_cache_isolation_and_expiry():
	tls_session_cache* cache = tls_session_cache_new()
	tls_config* cfg = tr_config(cache)
	tls_conn* issuer = tr_issuer(cfg)
	string_builder* ticket = tr_ticket()
	for mode in range(10):
		assert_equal(1, tls_session_ticket(issuer, ticket.data, ticket.length))
		tls_config* other = tr_config(cache)
		char* host = c"localhost"
		if (mode == 0): host = c"other.localhost"
		if (mode == 1): other.server_port = 444
		if (mode == 2): other.insecure_skip_verify = 1
		if (mode == 3): other.trust_store_path = c"libs/standard/net/x509_fixtures/ca_rsa.pem"
		if (mode == 4): other.has_now_unix = 1
		if (mode == 5): other.require_client_auth = 1
		if (mode == 6): other.client_cert_chain_path = c"client.pem"
		if (mode == 7): tls_config_set_alpn(other, c"h2")
		if (mode == 8): cache.entries[0].received_unix -= 61
		if (mode == 9): cache.entries[0].received_ms -= 61000
		tls_conn* c = tls_conn_new(-1, 1, other)
		tls_session_prepare(c, host)
		assert_equal(0, cast(int, c.offered_session))
		tls_conn_free(c)
		tls_config_free(other)
		tls_session_cache_clear(cache)
	assert_equal(1, tls_session_ticket(issuer, ticket.data, ticket.length))
	tls_conn* c = tls_conn_new(-1, 1, cfg)
	tls_session_prepare(c, c"localhost")
	assert_equal(1, cast(int, c.offered_session != 0))
	assert_equal(0, cache.entries.length)
	tls_conn_free(c)
	tls_conn_free(issuer)
	string_free(ticket)
	tls_config_free(cfg)
	tls_session_cache_free(cache)


void test_resumption_client_hello_binder():
	tls_session_cache* cache = tls_session_cache_new()
	tls_config* cfg = tr_config(cache)
	tls_conn* issuer = tr_issuer(cfg)
	string_builder* ticket = tr_ticket()
	assert_equal(1, tls_session_ticket(issuer, ticket.data, ticket.length))
	tls_conn* c = tls_conn_new(-1, 1, cfg)
	tls_session_prepare(c, c"localhost")
	char[32] zero
	mem_fill(cast(char*, zero), 0, 32)
	int len = 0
	char* hello = tls_build_client_hello(c"localhost", zero, zero, zero, &len)
	hello = tls_session_client_hello(c, hello, &len)
	int pos = tls_hello_extensions(hello, len) + 2
	int psk = 0
	int modes = 0
	while (pos < len):
		int kind = load_be16(hello + pos)
		int size = load_be16(hello + pos + 2)
		if (kind == TLS_EXT_PSK_MODES): modes += 1
		if (kind == TLS_EXT_PRE_SHARED_KEY):
			psk = pos
			assert_equal(len, pos + size + 4)
		pos += size + 4
	assert_equal(1, modes)
	assert_equal(1, cast(int, psk > 0))
	int truncate = psk + 6 + load_be16(hello + psk + 4)
	char[32] early
	char[32] binder
	char[32] key
	char[32] hash
	char[32] expected
	hkdf_extract(WHASH_SHA256, zero, 32, c.offered_session.psk, 32, early)
	tls13_derive_secret(WHASH_SHA256, early, c"res binder", 10, c"", 0, binder)
	tls_finished_key(WHASH_SHA256, binder, key)
	whash_oneshot(WHASH_SHA256, hello, truncate, hash)
	hmac_compute(WHASH_SHA256, key, 32, hash, 32, expected)
	assert_bytes_equal(expected, hello + truncate + 3, 32)
	free(hello)
	tls_conn_free(c)
	# First full handshake advertises psk_dhe_ke so servers may issue tickets.
	hello = tls_build_client_hello(c"localhost", zero, zero, zero, &len)
	hello = tls_session_client_hello(issuer, hello, &len)
	assert_equal(TLS_EXT_PSK_MODES, load_be16(hello + len - 6))
	free(hello)
	tls_conn_free(issuer)
	string_free(ticket)
	tls_config_free(cfg)
	tls_session_cache_free(cache)


# A server without ticket issuance/acceptance still permits a PSK offer to
# fall back to certificates through HRR. Binders change, and incompatible
# hash PSKs may be removed from CH2 (RFC 8446 section 4.1.2).
void test_resumption_server_retry_fallback():
	tls_session_cache* cache = tls_session_cache_new()
	tls_config* cfg = tr_config(cache)
	tls_conn* issuer = tr_issuer(cfg)
	string_builder* ticket = tr_ticket()
	assert_equal(1, tls_session_ticket(issuer, ticket.data, ticket.length))
	tls_conn* c = tls_conn_new(-1, 1, cfg)
	tls_session_prepare(c, c"localhost")
	char[65] pub
	mem_fill(cast(char*, pub), 7, 65)
	int first_len = 0
	char* first = tls_build_client_hello(c"localhost", pub, pub, pub, &first_len)
	first = tls_session_client_hello(c, first, &first_len)
	int invariant_len = 0
	char* invariant = tls_retry_invariant(first, first_len, &invariant_len)
	assert_equal(1, cast(int, invariant != 0))
	for compatible in range(2):
		int second_len = 0
		char* second = tls_retry_client_hello(first, first_len, TLS_GROUP_SECP256R1, pub, c.retry_cookie, &second_len)
		assert_equal(1, cast(int, second != 0))
		if (compatible):
			c.retry_seen = 1
			second = tls_session_client_hello(c, second, &second_len)
		int actual_len = 0
		char* actual = tls_retry_invariant(second, second_len, &actual_len)
		assert_equal(1, cast(int, actual != 0))
		assert_equal(invariant_len, actual_len)
		assert_bytes_equal(invariant, actual, actual_len)
		free(actual)
		free(second)
	free(invariant)
	free(first)
	tls_conn_free(c)
	tls_conn_free(issuer)
	string_free(ticket)
	tls_config_free(cfg)
	tls_session_cache_free(cache)


# Post-handshake tickets and close_notify must be encrypted. Plaintext records
# injected into an authenticated stream cannot populate the cache or report
# clean EOF. Early plaintext alerts before keys remain valid.
void test_resumption_reject_plaintext_ticket_and_alert():
	for kind in range(2):
		tls_session_cache* cache = tls_session_cache_new()
		tls_config* cfg = tr_config(cache)
		tls_conn* c = tr_issuer(cfg)
		string_builder* ticket = tr_ticket()
		char* payload = ticket.data
		int payload_len = ticket.length
		int record_type = TLS_CT_HANDSHAKE
		if (kind):
			payload = c"\x01\x00"
			payload_len = 2
			record_type = TLS_CT_ALERT
		string_append_char(c.mem_in, record_type)
		string_append_be16(c.mem_in, 0x0303)
		string_append_be16(c.mem_in, payload_len)
		string_append_bytes(c.mem_in, payload, payload_len)
		c.r_active = 1
		char[8] output
		assert_equal(-1, tls_read(c, output, 8))
		assert_equal(1, c.broken)
		assert_equal(0, c.at_eof)
		assert_equal(0, cache.entries.length)
		string_free(ticket)
		tls_conn_free(c)
		tls_config_free(cfg)
		tls_session_cache_free(cache)
	tls_conn* early = tls_conn_new(-1, 1, 0)
	string_append_bytes(early.mem_in, c"\x15\x03\x03\x00\x02\x02\x28", 7)
	int record_type = 0
	char* alert = 0
	int alert_len = 0
	assert_equal(1, tls_recv_record(early, &record_type, &alert, &alert_len))
	assert_equal(TLS_CT_ALERT, record_type)
	assert_equal(2, alert_len)
	free(alert)
	tls_conn_free(early)


void test_resumption_verifies_exact_trust_snapshot():
	char* path = c"bin/tls_resumption_snapshot32.pem"
	if (__word_size__ == 8): path = c"bin/tls_resumption_snapshot64.pem"
	char* trusted = file_read_text(c"libs/standard/distributed/raft_tls_fixtures/ca.pem")
	char* unrelated = file_read_text(c"libs/standard/net/x509_fixtures/ca_ec.pem")
	char* chain = file_read_text(c"libs/standard/distributed/raft_tls_fixtures/server.pem")
	asserts(c"fixtures readable", trusted != 0 && unrelated != 0 && chain != 0)
	int skipped = 0
	list[x509_cert*] certs = pem_decode_certs(chain, strlen(chain), &skipped)
	assert_equal(0, skipped)
	assert_equal(1, cast(int, certs.length > 0))
	for original_trusted in range(2):
		char* original = unrelated
		char* replacement = trusted
		if (original_trusted):
			original = trusted
			replacement = unrelated
		assert_equal(1, file_write_text(path, original))
		tls_session_cache* cache = tls_session_cache_new()
		tls_config* cfg = tr_config(cache)
		cfg.trust_store_path = path
		tls_conn* c = tls_conn_new(-1, 1, cfg)
		tls_session_prepare(c, c"test.w.example")
		assert_equal(1, cast(int, c.session_trust != 0))
		assert_equal(1, file_write_text(path, replacement))
		# Verification follows the original snapshot in both directions. A
		# newly introduced CA cannot authenticate a ticket labelled old trust.
		assert_equal(original_trusted, tls_check_chain(c, certs, c"test.w.example"))
		assert_equal(0, cast(int, c.session_trust))
		tls_conn_free(c)
		tls_config_free(cfg)
		tls_session_cache_free(cache)
	tls_free_cert_list(certs)
	free(chain)
	free(trusted)
	free(unrelated)
	assert_equal(0, unlink(path))


void test_resumption_rejects_interleaved_application_record():
	tls_session_cache* cache = tls_session_cache_new()
	tls_config* cfg = tr_config(cache)
	tls_conn* receiver = tr_issuer(cfg)
	tls_conn* sender = tls_conn_new(-1, 1, 0)
	tls_install_write_keys(sender, sender.s_ap_secret)
	tls_install_read_keys(receiver, receiver.s_ap_secret)
	string_builder* ticket = tr_ticket()
	assert_equal(1, tls_send_record(sender, TLS_CT_HANDSHAKE, ticket.data, 3, 1))
	assert_equal(1, tls_send_record(sender, TLS_CT_APPLICATION_DATA, c"data", 4, 1))
	tls_mem_feed(receiver, sender.mem_out.data, sender.mem_out.length)
	char[8] buf
	assert_equal(-1, tls_read(receiver, buf, 8))
	assert_equal(1, receiver.broken)
	assert_equal(0, cache.entries.length)
	string_free(ticket)
	tls_conn_free(sender)
	tls_conn_free(receiver)
	tls_config_free(cfg)
	tls_session_cache_free(cache)
