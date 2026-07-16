# https_server -- serves https:// requests over TLS 1.3 using
# libs/standard/web/http_server.w's ServerContext + server_route
# (issue #235 phases 1-5), which composes the pure-W TLS server role
# (tls_accept, libs/standard/net/tls.w; plan 11 phase 9, issue #204,
# part of #155) via server_context_set_tls. This used to hand-roll the
# accept()/tls_accept()/response-write sequence directly over a raw
# socket -- the framework now does all of that (request parsing,
# keep-alive, response framing); this file is just the one route.
#
# It defaults to the checked-in synthetic P-256 fixture (SAN test.w.example,
# a throwaway TEST key), so it runs with no setup:
#   https_server --port=8443
#   # then, in another shell:
#   examples/web/https_get --url=https://127.0.0.1:8443/ --insecure
import lib.args
import lib.lib
import libs.standard.web.http_server


void https_server_usage():
	println(c"usage: https_server [--ip=127.0.0.1] [--port=8443] [--cert=PATH] [--key=PATH]")


# server_context_new requires a server_handler_fn even when the context
# only ever dispatches through server_route (server_serve_connection
# never calls this once a route is registered below).
ServerResponse* https_server_unused_handler(ServerRequest* req, void* context):
	return server_response_new(500)


# The one route -- "*"/"*" matches every method and path, mirroring the
# original demo's single fixed response.
void https_server_handle(RequestContext* rc, void* user_data):
	request_context_text(rc, 200, c"hello from tls_accept\n")


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

	ServerContext* s = server_context_new(ip, port, https_server_unused_handler, 0)
	server_context_set_tls(s, cert, key)
	if (server_context_bind(s) == 0):
		print_string(c"bind failed: ", server_error_string(s.error))
		server_context_free(s)
		return 1
	server_route(s, c"*", c"*", https_server_handle, 0)

	print_string(c"serving https:// requests on ", ip)
	print_int(c"  port ", port)
	server_context_accept_loop(s, 1)
	server_context_close(s)
	server_context_free(s)
	println(c"done")
	return 0
