# win64 stub for wexec's shared remote build cache HTTP transport (see
# the x86 sibling file and tools/wexec.w's "Shared remote build cache"
# section). Networking has no win64 backend yet -- lib.net's
# sys_socket has no lib/__arch__/win64/syscalls.w entry, the same gap
# libs/extras/vcs/__arch__/'s own doc comment documents for win64/wasm
# -- so the feature is simply unavailable on bin/wexec_win.exe: every
# GET/PUT reports a transport failure, which wexec's normal fallback
# path handles exactly like an unreachable cache server (one warning
# line, then a plain local build; never a broken one).


int wexec_remote_http_get(char* url, int timeout_ms, int* out_status, char** out_body, int* out_body_len, char** out_error):
	*out_error = c"remote cache not supported on this platform"
	return 0


int wexec_remote_http_put(char* url, char* body, int body_len, int timeout_ms, char** out_error):
	*out_error = c"remote cache not supported on this platform"
	return 0
