# wbuild: name=net_tls_alpn_test x64
/*
Tests for TLS ALPN (RFC 7301) in libs/standard/net/tls.w.

Positive paths run our own client against our own server over a forked
socketpair (the tls_server_test.w loopback pattern, fixture cert + key from
libs/standard/net/tls_fixtures/): server-preference selection, fallback to a
lower-preference common protocol, no-overlap with and without "required",
a client that offers nothing, and a server with ALPN unconfigured (which
must ignore the client's offer). The child server reports its view of the
negotiated protocol through its exit status.

Negative client paths use the deterministic in-memory replay (fixed client +
server ephemeral keys, the client's ClientHello pinned via test_client_hello
so the transcript matches): the server answers a ClientHello that offered
"h2", then a client configured WITHOUT ALPN (unsolicited extension) or with a
different list (selection it never offered) must reject the flight. The
no_application_protocol alert (120) is checked byte-for-byte in the
server's in-memory output.
*/
import lib.testing
import lib.memory
import lib.net
import lib.file
import libs.standard.crypto.x25519
import libs.standard.net.tls


# ---- helpers ------------------------------------------------------------------

char* alpnt_cert_path():
	return c"libs/standard/net/tls_fixtures/server_p256_cert.pem"


char* alpnt_key_path():
	return c"libs/standard/net/tls_fixtures/server_p256_key.pem"


void alpnt_fill(char* buf, int n, int seed):
	int i = 0
	while (i < n):
		buf[i] = (seed + i * 7 + (i >> 3)) & 255
		i = i + 1


# 1 if two optional C strings are equal (both 0 counts as equal).
int alpnt_same(char* a, char* b):
	if ((a == 0) || (b == 0)):
		return (a == 0) && (b == 0)
	return strcmp(a, b) == 0


int alpnt_exit_code(int status):
	return (status >> 8) & 255


# Forked loopback handshake. The child is a tls_accept server configured
# with server_protos (0 = no ALPN) / required; it exits 0 when the handshake
# succeeded and its negotiated protocol equals expect, 3 when tls_accept
# failed, 4 on a protocol mismatch, 5 on an I/O failure afterwards. The
# parent client offers client_protos (0 = none) and returns 1 if its
# handshake succeeded AND its own negotiated protocol equals expect (0 on a
# failed handshake). *out_status gets the child's wait status.
int alpnt_loopback(char* server_protos, int required, char* client_protos, char* expect, int* out_status):
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socketpair", socket_pair(fds) >= 0)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		close(fds[0])
		tls_server_config* scfg = tls_server_config_new()
		scfg.cert_chain_path = alpnt_cert_path()
		scfg.key_path = alpnt_key_path()
		if (server_protos != 0):
			if (tls_server_config_set_alpn(scfg, server_protos, required) == 0):
				exit(6)
		tls_conn* s = tls_accept(fds[1], scfg)
		if (s == 0):
			exit(3)
		if (alpnt_same(tls_alpn_selected(s), expect) == 0):
			exit(4)
		char* buf = malloc(64)
		if (tls_write(s, c"ok", 2) != 2):
			exit(5)
		if (tls_read(s, buf, 64) != 0):
			exit(5)
		tls_close(s)
		exit(0)
	close(fds[1])
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	if (client_protos != 0):
		asserts(c"client alpn list", tls_config_set_alpn(cfg, client_protos) != 0)
	int result = 0
	tls_conn* c = tls_connect(fds[0], c"test.w.example", cfg)
	if (c != 0):
		char* buf = malloc(64)
		int got = tls_read(c, buf, 64)
		if ((got == 2) && (alpnt_same(tls_alpn_selected(c), expect) != 0)):
			result = 1
		free(buf)
		tls_close(c)
	close(fds[0])
	tls_config_free(cfg)
	int status = 0
	wait4(pid, &status, 0, 0)
	*out_status = status
	free(fds)
	return result


# Wrap a handshake message in a TLS plaintext record (content type 22).
char* alpnt_wrap_handshake(char* msg, int mlen, int* out_len):
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


tls_server_config* alpnt_config_inmem():
	tls_server_config* scfg = tls_server_config_new()
	char* cert = file_read_text(alpnt_cert_path())
	asserts(c"cert fixture missing", cert != 0)
	char* key = file_read_text(alpnt_key_path())
	asserts(c"key fixture missing", key != 0)
	scfg.test_cert_pem = cert
	scfg.test_cert_pem_len = strlen(cert)
	scfg.test_key_pem = key
	scfg.test_key_pem_len = strlen(key)
	return scfg


void alpnt_config_inmem_free(tls_server_config* scfg):
	free(scfg.test_cert_pem)
	free(scfg.test_key_pem)
	tls_server_config_free(scfg)


# ClientHello message offering protos (0 = no ALPN extension), with the
# key_share of client_priv. *out_len gets its length.
char* alpnt_client_hello(char* client_priv, char* protos, int* out_len):
	char* pub = malloc(32)
	x25519_scalarmult_base(pub, client_priv)
	char* rnd = malloc(32)
	char* sid = malloc(32)
	alpnt_fill(rnd, 32, 0x11)
	alpnt_fill(sid, 32, 0x40)
	int alen = 0
	char* alpn = 0
	if (protos != 0):
		alpn = tls_alpn_encode(protos, &alen)
	char* ch = tls_build_client_hello_alpn(c"test.w.example", rnd, sid, pub, alpn, alen, out_len)
	if (alpn != 0):
		free(alpn)
	free(pub)
	free(rnd)
	free(sid)
	return ch


# Run the in-memory server over the record-wrapped ClientHello (no client
# Finished follows, so the run always ends in EOF); returns its captured
# output (the whole flight, or just an alert) and its last error.
char* alpnt_server_output(char* chrec, int chrec_len, char* server_protos, int required, char* server_priv, char* server_random, int* out_len, char** out_err):
	tls_server_config* scfg = alpnt_config_inmem()
	scfg.test_priv = server_priv
	scfg.test_random = server_random
	if (server_protos != 0):
		tls_server_config_set_alpn(scfg, server_protos, required)
	tls_conn* s = tls_conn_new(0 - 1, 1, 0)
	s.is_server = 1
	s.scfg = scfg
	string_append_bytes(s.mem_in, chrec, chrec_len)
	tls_server_do_handshake(s)
	char* out = tls_mem_take_output(s, out_len)
	*out_err = tls_server_last_error(scfg)
	tls_conn_free(s)
	alpnt_config_inmem_free(scfg)
	return out


# The server answers a ClientHello offering ch_protos; then a client with
# client_protos (0 = none) but the same pinned ClientHello processes that
# flight. Returns the client's tls_last_error (0 when it succeeded).
char* alpnt_client_vs_flight(char* ch_protos, char* client_protos):
	char* client_priv = malloc(32)
	char* server_priv = malloc(32)
	char* server_random = malloc(32)
	alpnt_fill(client_priv, 32, 0x21)
	alpnt_fill(server_priv, 32, 0x55)
	alpnt_fill(server_random, 32, 0x66)
	int ch_len = 0
	char* ch = alpnt_client_hello(client_priv, ch_protos, &ch_len)
	int chrec_len = 0
	char* chrec = alpnt_wrap_handshake(ch, ch_len, &chrec_len)
	int flen = 0
	char* serr = 0
	char* flight = alpnt_server_output(chrec, chrec_len, c"h2", 1, server_priv, server_random, &flen, &serr)
	asserts(c"server produced a flight", flen > 0)
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	cfg.test_priv = client_priv
	cfg.test_client_hello = ch
	cfg.test_client_hello_len = ch_len
	if (client_protos != 0):
		tls_config_set_alpn(cfg, client_protos)
	tls_conn* c = tls_connect_mem(flight, flen, c"test.w.example", cfg)
	char* err = 0
	if (c == 0):
		err = tls_last_error(cfg)
		asserts(c"failed client leaves an error", err != 0)
	else:
		asserts(c"client sees h2", alpnt_same(tls_alpn_selected(c), c"h2") != 0)
		tls_conn_free(c)
	tls_config_free(cfg)
	free(flight)
	free(chrec)
	free(ch)
	free(client_priv)
	free(server_priv)
	free(server_random)
	return err


# ---- tests --------------------------------------------------------------------

void test_alpn_encode():
	int n = 0
	char* e = tls_alpn_encode(c"h2,http/1.1", &n)
	asserts(c"encode ok", e != 0)
	assert_equal(12, n)
	assert_equal(2, e[0])
	assert_equal('h', e[1])
	assert_equal('2', e[2])
	assert_equal(8, e[3])
	assert_equal('/', e[8])
	asserts(c"list valid", tls_alpn_list_valid(e, n) != 0)
	asserts(c"contains h2", tls_alpn_list_contains(e, n, c"h2", 2) != 0)
	asserts(c"contains http/1.1", tls_alpn_list_contains(e, n, c"http/1.1", 8) != 0)
	asserts(c"not h3", tls_alpn_list_contains(e, n, c"h3", 2) == 0)
	asserts(c"not prefix h", tls_alpn_list_contains(e, n, c"h", 1) == 0)
	free(e)
	asserts(c"empty name rejected", tls_alpn_encode(c"h2,,x", &n) == 0)
	asserts(c"trailing comma rejected", tls_alpn_encode(c"h2,", &n) == 0)
	asserts(c"empty list rejected", tls_alpn_encode(c"", &n) == 0)
	tls_config* cfg = tls_config_new()
	assert_equal(1, tls_config_set_alpn(cfg, c"h2"))
	assert_equal(3, cfg.alpn_len)
	assert_equal(0, tls_config_set_alpn(cfg, c",h2"))
	asserts(c"bad list clears", cfg.alpn == 0)
	assert_equal(1, tls_config_set_alpn(cfg, c"h2"))
	assert_equal(1, tls_config_set_alpn(cfg, 0))
	asserts(c"0 clears", cfg.alpn == 0)
	tls_config_free(cfg)


void test_alpn_client_hello_extension():
	char* priv = malloc(32)
	alpnt_fill(priv, 32, 0x21)
	int plain_len = 0
	char* plain = alpnt_client_hello(priv, 0, &plain_len)
	int alpn_len = 0
	char* withx = alpnt_client_hello(priv, c"h2,http/1.1", &alpn_len)
	# type(2) + ext_len(2) + list_len(2) + 12 bytes of names.
	assert_equal(plain_len + 18, alpn_len)
	# The extension is appended last: 00 10 00 0e 00 0c 02 'h' '2' ...
	int p = plain_len
	assert_equal(0x00, withx[p] & 255)
	assert_equal(0x10, withx[p + 1] & 255)
	assert_equal(14, withx[p + 3] & 255)
	assert_equal(12, withx[p + 5] & 255)
	assert_equal(2, withx[p + 6] & 255)
	assert_equal('h', withx[p + 7])
	free(plain)
	free(withx)
	free(priv)


void test_alpn_server_preference_wins():
	int st = 0
	# The client prefers http/1.1, but the server's order puts h2 first.
	int ok = alpnt_loopback(c"h2,http/1.1", 1, c"http/1.1,h2", c"h2", &st)
	asserts(c"client negotiated h2", ok != 0)
	assert_equal(0, st)


void test_alpn_falls_back_to_common_protocol():
	int st = 0
	int ok = alpnt_loopback(c"h2,http/1.1", 1, c"http/1.1", c"http/1.1", &st)
	asserts(c"client negotiated http/1.1", ok != 0)
	assert_equal(0, st)


void test_alpn_no_overlap_required_fails():
	int st = 0
	int ok = alpnt_loopback(c"h2", 1, c"http/1.1", 0, &st)
	asserts(c"handshake must fail", ok == 0)
	assert_equal(3, alpnt_exit_code(st))


void test_alpn_no_overlap_optional_proceeds():
	int st = 0
	int ok = alpnt_loopback(c"h2", 0, c"http/1.1", 0, &st)
	asserts(c"handshake without ALPN", ok != 0)
	assert_equal(0, st)


void test_alpn_client_offers_nothing():
	int st = 0
	int ok = alpnt_loopback(c"h2", 0, 0, 0, &st)
	asserts(c"optional: proceeds without ALPN", ok != 0)
	assert_equal(0, st)
	ok = alpnt_loopback(c"h2", 1, 0, 0, &st)
	asserts(c"required: fails", ok == 0)
	assert_equal(3, alpnt_exit_code(st))


void test_alpn_server_unconfigured_ignores_offer():
	int st = 0
	int ok = alpnt_loopback(0, 0, c"h2,http/1.1", 0, &st)
	asserts(c"no ALPN when the server has none", ok != 0)
	assert_equal(0, st)


void test_alpn_no_application_protocol_alert():
	char* client_priv = malloc(32)
	char* server_priv = malloc(32)
	char* server_random = malloc(32)
	alpnt_fill(client_priv, 32, 0x21)
	alpnt_fill(server_priv, 32, 0x55)
	alpnt_fill(server_random, 32, 0x66)
	int ch_len = 0
	char* ch = alpnt_client_hello(client_priv, c"http/1.1,spdy/3", &ch_len)
	int chrec_len = 0
	char* chrec = alpnt_wrap_handshake(ch, ch_len, &chrec_len)
	int out_len = 0
	char* err = 0
	char* out = alpnt_server_output(chrec, chrec_len, c"h2", 1, server_priv, server_random, &out_len, &err)
	# Exactly one plaintext fatal alert record, no ServerHello: 15 03 03 00 02 02 78.
	assert_equal(7, out_len)
	assert_equal(21, out[0] & 255)
	assert_equal(2, out[5] & 255)
	assert_equal(120, out[6] & 255)
	assert_strings_equal(c"tls: no common ALPN protocol", err)
	free(out)
	free(chrec)
	free(ch)
	free(client_priv)
	free(server_priv)
	free(server_random)


void test_alpn_malformed_client_list_is_decode_error():
	char* client_priv = malloc(32)
	char* server_priv = malloc(32)
	char* server_random = malloc(32)
	alpnt_fill(client_priv, 32, 0x21)
	alpnt_fill(server_priv, 32, 0x55)
	alpnt_fill(server_random, 32, 0x66)
	int ch_len = 0
	char* ch = alpnt_client_hello(client_priv, c"h2", &ch_len)
	# Corrupt the single name's length byte (last 3 bytes: 02 'h' '2') so it
	# overruns the list.
	ch[ch_len - 3] = 9
	int chrec_len = 0
	char* chrec = alpnt_wrap_handshake(ch, ch_len, &chrec_len)
	int out_len = 0
	char* err = 0
	char* out = alpnt_server_output(chrec, chrec_len, c"h2", 0, server_priv, server_random, &out_len, &err)
	assert_equal(7, out_len)
	assert_equal(50, out[6] & 255)
	assert_strings_equal(c"tls: malformed ALPN extension", err)
	free(out)
	free(chrec)
	free(ch)
	free(client_priv)
	free(server_priv)
	free(server_random)


void test_alpn_client_accepts_offered_selection():
	char* err = alpnt_client_vs_flight(c"http/1.1,h2", c"http/1.1,h2")
	asserts(c"client accepts h2", err == 0)


void test_alpn_client_rejects_unsolicited_extension():
	char* err = alpnt_client_vs_flight(c"h2", 0)
	assert_strings_equal(c"tls: unsolicited ALPN extension", err)


void test_alpn_client_rejects_unoffered_selection():
	char* err = alpnt_client_vs_flight(c"h2", c"http/1.1")
	assert_strings_equal(c"tls: server selected an ALPN protocol we did not offer", err)
