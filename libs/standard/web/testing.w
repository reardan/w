# Web-layer additions to libs/standard/net/testing.w's loopback fixture
# helpers: reaping around the HTTP client's keep-alive cache, and the
# raw HTTP/2 server-side handshake.
import lib.mem
import libs.standard.net.testing
import libs.standard.web.http2
import libs.standard.web.http_client


# Drops the client's cached keep-alive connection first (children that
# serve until EOF exit only once the client side is really closed, and
# it must not leak into the next test), then net_test_finish.
void web_test_finish(int pid, int listener):
	http_client_close_idle()
	net_test_finish(pid, listener)


# (child) Accepts one raw h2 connection: checks the client preface, then
# sends a SETTINGS frame carrying the given payload (0, 0 for none).
int h2_test_raw_accept(int listener, char* settings, int settings_len):
	int fd = socket_accept_connection(listener)
	if (fd < 0):
		exit(90)
	socket_set_recv_timeout(fd, 10000)
	char* pre = malloc(24)
	if (h2_fd_read_exact(fd, pre, 24) == 0):
		exit(91)
	if (mem_eq(pre, h2_preface(), 24) == 0):
		exit(92)
	free(pre)
	h2_raw_write_frame(fd, h2_frame_settings, 0, 0, settings, settings_len)
	return fd


# Server config with the checked-in synthetic P-256 fixture credentials
# (libs/standard/net/tls_fixtures/).
tls_server_config* web_test_server_config():
	tls_server_config* scfg = tls_server_config_new()
	scfg.cert_chain_path = c"libs/standard/net/tls_fixtures/server_p256_cert.pem"
	scfg.key_path = c"libs/standard/net/tls_fixtures/server_p256_key.pem"
	return scfg


# Client config that accepts the self-signed fixture certificate.
tls_config* web_test_client_config():
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	return cfg
