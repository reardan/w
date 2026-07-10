# https_get -- the curl-replacement demo for the pure-W HTTPS stack
# (plan 11 phase 9, issue #204, part of #155). Fetches an https:// (or
# http://) URL through libs/standard/web/http_client.w -- which wraps the
# socket with the native TLS 1.3 client (libs/standard/net/tls.w) for
# https, doing a real X25519 + ChaCha20-Poly1305 handshake with X.509
# chain + hostname validation against the system trust store -- and prints
# the status line, response headers, and the head of the body.
#
# Examples:
#   https_get --url=https://example.com/
#   https_get --url=https://127.0.0.1:8443/ --insecure --max-body=256
import lib.lib
import lib.args
import lib.str
import lib.container
import structures.string
import libs.standard.web.http_client


void https_get_usage():
	println(c"usage: https_get [--url=https://example.com/] [--insecure] [--max-body=512]")


# Prints every response header as "name: value", one per line.
void https_get_print_headers(http_response* resp):
	list[char*] keys = resp.headers.keys()
	for char* name in keys:
		char* value = resp.headers[name]
		string_builder* line = string_new()
		string_append(line, name)
		string_append(line, c": ")
		string_append(line, value)
		println(line.data)
		string_free(line)
	list_free[char*](keys)


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_has_flag(c"help")):
		https_get_usage()
		return 0

	char* target = args_value(c"url")
	if (target == 0):
		target = c"https://example.com/"
	int max_body = 512
	char* max_body_arg = args_value(c"max-body")
	if (max_body_arg != 0):
		max_body = atoi(max_body_arg)
	if (max_body < 0):
		max_body = 0

	http_req* req = http_req_new(c"GET", target)
	# --insecure skips chain + hostname verification (tests/dev only); the
	# handshake signature and Finished MAC are still checked.
	if (args_has_flag(c"insecure")):
		req.tls_insecure_skip_verify = 1

	http_response* resp = http_request(req)
	if (resp.error != 0):
		print_string(c"request failed: ", resp.error_message)
		http_response_free(resp)
		http_req_free(req)
		return 1

	print_int(c"status: ", resp.status)
	println(c"headers:")
	https_get_print_headers(resp)

	int n = resp.body_len
	if (n > max_body):
		n = max_body
	print_int(c"body bytes: ", resp.body_len)
	println(c"body head:")
	if (n > 0):
		write(1, resp.body, n)
	println(c"")

	http_response_free(resp)
	http_req_free(req)
	return 0
