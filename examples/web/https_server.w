# https_server -- serves ONE request over TLS 1.3 using the pure-W TLS
# server role (tls_accept, libs/standard/net/tls.w; plan 11 phase 9, issue
# #204, part of #155). A minimal raw-socket accept loop terminates TLS with
# a configured ECDSA P-256 certificate + key and answers with a small
# text/plain body. Plan 08's http_server framework composes with tls_accept
# later; this demo keeps the socket handling explicit.
#
# It defaults to the checked-in synthetic P-256 fixture (SAN test.w.example,
# a throwaway TEST key), so it runs with no setup:
#   https_server --port=8443
#   # then, in another shell:
#   examples/web/https_get --url=https://127.0.0.1:8443/ --insecure
import lib.lib
import lib.args
import lib.str
import lib.net
import structures.string
import libs.standard.net.tls


void https_server_usage():
	println(c"usage: https_server [--ip=127.0.0.1] [--port=8443] [--cert=PATH] [--key=PATH]")


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_has_flag(c"help")):
		https_server_usage()
		return 0

	char* ip = args_value(c"ip")
	if (ip == 0):
		ip = c"127.0.0.1"
	int port = 8443
	char* port_arg = args_value(c"port")
	if (port_arg != 0):
		port = atoi(port_arg)
	char* cert = args_value(c"cert")
	if (cert == 0):
		cert = c"libs/standard/net/tls_fixtures/server_p256_cert.pem"
	char* key = args_value(c"key")
	if (key == 0):
		key = c"libs/standard/net/tls_fixtures/server_p256_key.pem"

	int listener = socket_tcp_ipv4()
	if (listener < 0):
		println(c"socket failed")
		return 1
	socket_set_reuseaddr(listener)
	if (socket_bind_ipv4(listener, ip4_from_string(ip), port) < 0):
		println(c"bind failed")
		close(listener)
		return 1
	if (socket_listen(listener, 8) < 0):
		println(c"listen failed")
		close(listener)
		return 1
	print_string(c"serving one https:// request on ", ip)
	print_int(c"  port ", port)

	int conn = socket_accept_connection(listener)
	if (conn < 0):
		println(c"accept failed")
		close(listener)
		return 1

	tls_server_config* scfg = tls_server_config_new()
	scfg.cert_chain_path = cert
	scfg.key_path = key
	tls_conn* tc = tls_accept(conn, scfg)
	if (tc == 0):
		print_string(c"tls_accept failed: ", tls_server_last_error(scfg))
		tls_server_config_free(scfg)
		close(conn)
		close(listener)
		return 1

	# Read (and discard) the request head over TLS. A real server would
	# parse it; the demo just proves the decrypted bytes arrive.
	char* buf = malloc(4096)
	int got = tls_read(tc, buf, 4096)
	print_int(c"decrypted request bytes: ", got)
	free(buf)

	char* body = c"hello from tls_accept\n"
	string_builder* out = string_new()
	string_append(out, c"HTTP/1.1 200 OK\x0d\x0a")
	string_append(out, c"Content-Type: text/plain\x0d\x0a")
	string_append(out, c"Content-Length: ")
	char* len_text = itoa(strlen(body))
	string_append(out, len_text)
	free(len_text)
	string_append(out, c"\x0d\x0a")
	string_append(out, c"Connection: close\x0d\x0a\x0d\x0a")
	string_append(out, body)
	tls_write(tc, out.data, out.length)
	string_free(out)

	tls_close(tc)
	close(conn)
	close(listener)
	tls_server_config_free(scfg)
	println(c"done")
	return 0
