# wexec's actual HTTP transport for the shared remote build cache
# (issue #251 Direction 3, D3-2; see tools/wexec.w's "Shared remote
# build cache" section for the protocol). Isolated behind lib/__arch__
# -style per-target resolution purely because tools/wexec.w is also
# compiled for win64 (bin/wexec_win.exe): libs.standard.web.http_client
# pulls in lib.net, whose sys_socket has no win64
# lib/__arch__/win64/syscalls.w entry -- the same networking gap
# libs/extras/vcs/__arch__/'s own doc comment already documents for
# win64/wasm. This x86 file (the default-arch resolution) and the x64
# and arm64_darwin siblings all share this real implementation; the
# win64 sibling is a stub that always reports a transport failure, so
# the feature is simply unavailable there -- exactly like an
# unreachable cache server on any other platform, handled by wexec's
# existing fallback path.
import libs.standard.web.http_client


# GET url. On a transport success (any HTTP status), returns 1 and
# fills *out_status/*out_body/*out_body_len (*out_body is malloc'd and
# NUL-terminated; the caller frees it). On transport failure returns 0
# and sets *out_error to a static, never-freed description.
int wexec_remote_http_get(char* url, int timeout_ms, int* out_status, char** out_body, int* out_body_len, char** out_error):
	http_req* req = http_req_new(c"GET", url)
	req.timeout_ms = timeout_ms
	req.max_redirects = 0
	http_response* resp = http_request(req)
	int ok = 0
	if (resp.error != http_error_none()):
		*out_error = http_error_string(resp.error)
	else:
		ok = 1
		*out_status = resp.status
		*out_body_len = resp.body_len
		char* copy = malloc(resp.body_len + 1)
		int i = 0
		while (i < resp.body_len):
			copy[i] = resp.body[i]
			i = i + 1
		copy[resp.body_len] = 0
		*out_body = copy
	http_response_free(resp)
	http_req_free(req)
	return ok


# PUT body (body_len bytes, borrowed -- kept alive by the caller for
# the duration of this call) to url. Returns 1 on transport success
# (any HTTP status; the caller never inspects it, a push is
# best-effort), 0 with *out_error set on transport failure.
int wexec_remote_http_put(char* url, char* body, int body_len, int timeout_ms, char** out_error):
	http_req* req = http_req_new(c"PUT", url)
	req.timeout_ms = timeout_ms
	req.max_redirects = 0
	req.body = body
	req.body_len = body_len
	http_response* resp = http_request(req)
	int ok = resp.error == http_error_none()
	if (ok == 0):
		*out_error = http_error_string(resp.error)
	http_response_free(resp)
	http_req_free(req)
	return ok
