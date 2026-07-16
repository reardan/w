# End-to-end test for wexec's shared remote build cache (issue #251
# Direction 3, D3-2; tools/wexec.w's "Shared remote build cache"
# section, just above wexec_launch). Spins up an in-repo HTTP object
# server over a throwaway libs/extras/vcs/cas.w store in a pid-scoped
# bin/ directory -- the fork()-based fixture-server pattern
# libs/standard/web/https_e2e_test.w's raw-socket child helpers use
# (hs_child_read_request_raw / hs_send_all_raw), except here the
# client under test is bin/wexec itself, invoked as a real child
# process (lib.process.process_run) with W_CACHE_URL/W_CACHE_PUSH set
# only in that child's environment. The server speaks just enough
# HTTP/1.1 (one request per connection, "Connection: close") to serve
# wexec's dumb GET/PUT protocol -- no framework dependency, just
# lib.net sockets, matching this repo's other loopback fixture
# servers.
#
# tests/wexec/remote_cache.json is the throwaway manifest (bin/wexec's
# own "-f" flag, the isolation trick tools/test_map.w documents for
# tests/wtest/: it lets a test drive the real executor without ever
# selecting a real build.json target, so this test can never corrupt
# the real bin/.wexec_cache or build.json). Its one target,
# "remote_target", declares an "outputs" file and two steps: the first
# writes a marker file that only a real run of the steps produces, the
# second produces the declared output -- so "marker absent, output
# present" is the signature of a target that was restored from the
# remote cache instead of actually running.
#
# Three phases share one manifest/input (so the cache key never
# changes) and one server:
#   1. fresh local build with W_CACHE_PUSH=1 (what CI sets): steps run
#      (marker + output both appear), then the bundle is pushed.
#   2. local state wiped (stamp, marker, output all removed), rerun
#      with only W_CACHE_URL set: the GET hits, the output is restored
#      from the bundle, and -- the whole point -- the marker is NOT
#      recreated, proving the steps never ran.
#   3. local state wiped again, server killed, rerun: the GET fails
#      fast (connection refused), wexec falls back to a normal local
#      build (marker + output both reappear), and the run still exits
#      0 -- a dead/misconfigured cache must never break a build.
import lib.testing
import lib.net
import lib.file
import lib.env
import lib.process
import structures.string
import libs.extras.vcs.cas


/* ---- raw-socket CAS object server (the "shared cache" fixture) ---- */

# "/objects/<2 hex>/<62 hex>" -> the 64-hex cas.w id, or 0 when the
# path doesn't match that shape. Mirrors cas_object_path in reverse.
char* wrct_extract_id(char* path):
	char* prefix = c"/objects/"
	if (starts_with(path, prefix) == 0):
		return 0
	char* rest = path + strlen(prefix)
	int i = 0
	while ((rest[i] != 0) && (rest[i] != '/')):
		i = i + 1
	if (i != 2):
		return 0
	if (rest[i] != '/'):
		return 0
	char* tail = rest + i + 1
	if (strlen(tail) != 62):
		return 0
	string_builder* s = string_new()
	string_append_char(s, rest[0])
	string_append_char(s, rest[1])
	string_append(s, tail)
	char* id = s.data
	free(s)
	if (cas_valid_id(id) == 0):
		free(id)
		return 0
	return id


# Exact-byte copy (no strlen/substring -- a request buffer keeps
# growing past the head into arbitrary binary body bytes).
char* wrct_bytes_dup(char* data, int start, int end):
	int n = end - start
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = data[start + i]
		i = i + 1
	out[n] = 0
	return out


# Offset just past the CRLFCRLF that ends a request head, or -1.
int wrct_head_end(char* buf, int total):
	int i = 0
	while (i + 3 < total):
		if ((buf[i] == 13) && (buf[i + 1] == 10) && (buf[i + 2] == 13) && (buf[i + 3] == 10)):
			return i + 4
		i = i + 1
	return -1


# Case-insensitive search for a "Content-Length: <digits>" header
# within head[0..head_len); 0 when absent (this server's requests are
# either bodiless GETs or PUTs that always set it).
int wrct_parse_content_length(char* head, int head_len):
	char* needle = c"content-length:"
	int n = strlen(needle)
	int i = 0
	while ((i + n) <= head_len):
		int j = 0
		int match = 1
		while (j < n):
			int a = head[i + j] & 255
			if ((a >= 'A') && (a <= 'Z')):
				a = a + 32
			if (a != (needle[j] & 255)):
				match = 0
				j = n
			else:
				j = j + 1
		if (match):
			int p = i + n
			while ((p < head_len) && (head[p] == ' ')):
				p = p + 1
			int value = 0
			while ((p < head_len) && (head[p] >= '0') && (head[p] <= '9')):
				value = value * 10 + (head[p] - '0')
				p = p + 1
			return value
		i = i + 1
	return 0


# Reads until the request head is fully buffered (CRLFCRLF seen) or the
# connection ends early. Returns the head-end offset, or -1.
int wrct_read_head(int conn, string_builder* buf):
	char* tmp = malloc(4096)
	int head_end = -1
	int done = 0
	while (done == 0):
		int got = read(conn, tmp, 4096)
		if (got <= 0):
			done = 1
		else:
			string_append_bytes(buf, tmp, got)
			head_end = wrct_head_end(buf.data, buf.length)
			if (head_end >= 0):
				done = 1
	free(tmp)
	return head_end


void wrct_send_all(int conn, char* data, int n):
	int total = 0
	while (total < n):
		int got = socket_send(conn, data + total, n - total, msg_nosignal())
		if (got <= 0):
			total = n
		else:
			total = total + got


void wrct_respond(int conn, int status, char* status_text, char* body, int body_len):
	string_builder* head = string_new()
	string_append(head, c"HTTP/1.1 ")
	string_append_int(head, status)
	string_append_char(head, ' ')
	string_append(head, status_text)
	string_append(head, c"\x0d\x0aConnection: close\x0d\x0aContent-Length: ")
	string_append_int(head, body_len)
	string_append(head, c"\x0d\x0a\x0d\x0a")
	wrct_send_all(conn, head.data, head.length)
	string_free(head)
	if (body_len > 0):
		wrct_send_all(conn, body, body_len)


# One request/response over an already-accepted connection: read the
# head, pull in exactly as much body as Content-Length declares, route
# GET/PUT "/objects/<id>" against the cas.w store, respond, done (the
# response always says "Connection: close", so the client never tries
# to reuse this socket).
void wrct_serve_one(int conn, wcas* store):
	string_builder* buf = string_new()
	int head_end = wrct_read_head(conn, buf)
	if (head_end < 0):
		string_free(buf)
		return
	int content_length = wrct_parse_content_length(buf.data, head_end)
	int need = head_end + content_length
	char* more = malloc(4096)
	while (buf.length < need):
		int want = need - buf.length
		if (want > 4096):
			want = 4096
		int got = read(conn, more, want)
		if (got <= 0):
			need = buf.length
		else:
			string_append_bytes(buf, more, got)
	free(more)

	int method_end = 0
	while ((buf.data[method_end] != 0) && (buf.data[method_end] != ' ')):
		method_end = method_end + 1
	char* method = wrct_bytes_dup(buf.data, 0, method_end)
	int path_start = method_end + 1
	int path_end = path_start
	while ((buf.data[path_end] != 0) && (buf.data[path_end] != ' ')):
		path_end = path_end + 1
	char* path = wrct_bytes_dup(buf.data, path_start, path_end)

	int body_len = buf.length - head_end
	if (body_len < 0):
		body_len = 0
	char* body = buf.data + head_end

	char* id = wrct_extract_id(path)
	if (id == 0):
		wrct_respond(conn, 404, c"Not Found", c"", 0)
	else if (strcmp(method, c"GET") == 0):
		wresult[wcas_object*]* got_obj = cas_get(store, id)
		if (result_is_ok[wcas_object*](got_obj) == 0):
			result_free[wcas_object*](got_obj)
			wrct_respond(conn, 404, c"Not Found", c"", 0)
		else:
			wcas_object* obj = result_value[wcas_object*](got_obj)
			result_free[wcas_object*](got_obj)
			wrct_respond(conn, 200, c"OK", obj.data, obj.length)
			cas_object_free(obj)
	else if (strcmp(method, c"PUT") == 0):
		wresult[char*]* put = cas_put_raw(store, id, c"wexec-bundle", body, body_len)
		int ok = result_is_ok[char*](put)
		if (ok):
			free(result_value[char*](put))
		result_free[char*](put)
		if (ok):
			wrct_respond(conn, 200, c"OK", c"", 0)
		else:
			wrct_respond(conn, 500, c"Internal Server Error", c"", 0)
	else:
		wrct_respond(conn, 405, c"Method Not Allowed", c"", 0)
	if (id != 0):
		free(id)
	free(method)
	free(path)
	string_free(buf)


void wrct_serve_forever(int listener, wcas* store):
	while (1):
		int conn = socket_accept_connection(listener)
		if (conn >= 0):
			socket_set_recv_timeout(conn, 5000)
			socket_set_send_timeout(conn, 5000)
			wrct_serve_one(conn, store)
			close(conn)


/* ---- test helpers ---- */

char* wrct_root_cache
char* wrct_root():
	if (wrct_root_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wexec_remote_cache_store_")
		string_append_int(p, getpid())
		wrct_root_cache = p.data
		free(p)
	return wrct_root_cache


char* wrct_url(int port):
	string_builder* s = string_new()
	string_append(s, c"http://127.0.0.1:")
	string_append_int(s, port)
	char* text = s.data
	free(s)
	return text


int wrct_file_exists(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0
	close(fd)
	return 1


int wrct_contains(char* hay, char* needle):
	int i = 0
	while (hay[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (hay[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		i = i + 1
	return 0


# Runs 'bin/wexec -f tests/wexec/remote_cache.json remote_target' as a
# real child process with W_CACHE_URL (and, if push, W_CACHE_PUSH=1)
# set only in that child's environment -- never in this test process's
# own environment, so nothing here leaks into any other test sharing
# the suite's process tree.
process_result* wrct_run_wexec(char* url, int push):
	char** argv = strv_new(4)
	strv_set(argv, 0, c"bin/wexec")
	strv_set(argv, 1, c"-f")
	strv_set(argv, 2, c"tests/wexec/remote_cache.json")
	strv_set(argv, 3, c"remote_target")
	char** child_env = env_copy_with(env_current(), c"W_CACHE_URL", url)
	if (push):
		child_env = env_copy_with(child_env, c"W_CACHE_PUSH", c"1")
	spawn_options* opts = spawn_options_new()
	opts.env = child_env
	process_result* result = process_run(c"bin/wexec", argv, opts, 0, 10000)
	free(cast(char*, argv))
	free(opts)
	return result


void wrct_reset_local_state():
	unlink(c"bin/.wexec_cache/remote_target")
	unlink(c"bin/wexec_remote_cache_marker.txt")
	unlink(c"bin/wexec_remote_cache_out.txt")


/* ---- the test ---- */

void test_remote_cache_round_trip():
	wresult[wcas*]* store_r = cas_open(wrct_root())
	asserts(c"cas_open", result_is_ok[wcas*](store_r))
	wcas* store = result_value[wcas*](store_r)
	result_free[wcas*](store_r)

	asserts(c"write fixture input", file_write_text(c"bin/wexec_remote_cache_input.txt", c"remote cache fixture v1\n"))
	wrct_reset_local_state()

	int listener = socket_tcp_ipv4()
	asserts(c"listener socket", listener >= 0)
	socket_set_reuseaddr(listener)
	asserts(c"listener bind", socket_bind_ipv4(listener, ip4_from_string(c"127.0.0.1"), 0) >= 0)
	asserts(c"listener listen", socket_listen(listener, 8) >= 0)
	sockaddr_in bound
	asserts(c"listener getsockname", socket_getsockname_ipv4(listener, &bound) >= 0)
	int port = net_htons(bound.port)

	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		wrct_serve_forever(listener, store)
		exit(0)
	close(listener)

	char* url = wrct_url(port)

	# Phase 1: local cache miss, server up, W_CACHE_PUSH=1 -- steps run
	# for real (marker + output both appear) and the bundle is pushed.
	process_result* r1 = wrct_run_wexec(url, 1)
	asserts(c"phase1 exit 0", r1.status == 0)
	asserts(c"phase1 not served from any cache", wrct_contains(r1.stdout_text, c"(cached)") == 0)
	asserts(c"phase1 not served from remote cache", wrct_contains(r1.stdout_text, c"(remote cache)") == 0)
	asserts(c"phase1 marker created (steps ran)", wrct_file_exists(c"bin/wexec_remote_cache_marker.txt"))
	asserts(c"phase1 output created", wrct_file_exists(c"bin/wexec_remote_cache_out.txt"))
	process_result_free(r1)

	# Phase 2: wipe every trace of the local run, then rerun with only
	# W_CACHE_URL set. The remote GET must hit, restoring the output
	# without ever running the steps -- the marker must stay absent.
	wrct_reset_local_state()
	process_result* r2 = wrct_run_wexec(url, 0)
	asserts(c"phase2 exit 0", r2.status == 0)
	asserts(c"phase2 logged as remote cache", wrct_contains(r2.stdout_text, c"(remote cache)"))
	asserts(c"phase2 steps did NOT run (marker absent)", wrct_file_exists(c"bin/wexec_remote_cache_marker.txt") == 0)
	asserts(c"phase2 output restored from bundle", wrct_file_exists(c"bin/wexec_remote_cache_out.txt"))
	char* restored = file_read_text(c"bin/wexec_remote_cache_out.txt")
	assert_strings_equal(c"remote cache fixture v1\n", restored)
	free(restored)
	process_result_free(r2)

	# Take the server down before phase 3: kill + reap so the listening
	# socket is provably gone (not just "probably done answering").
	kill(pid, sigkill())
	int server_status = 0
	wait4(pid, &server_status, 0, 0)

	# Phase 3: wipe local state again, server unreachable. The GET must
	# fail fast (connection refused, well inside wexec's short cache
	# timeout) and wexec must fall back to a completely normal local
	# build -- steps run again, and the run still exits 0. A dead cache
	# must never be able to break a build.
	wrct_reset_local_state()
	process_result* r3 = wrct_run_wexec(url, 0)
	asserts(c"phase3 exit 0 (cache outage does not break the build)", r3.status == 0)
	asserts(c"phase3 warns once about the unreachable cache", wrct_contains(r3.stderr_text, c"remote cache unreachable"))
	asserts(c"phase3 not served from remote cache", wrct_contains(r3.stdout_text, c"(remote cache)") == 0)
	asserts(c"phase3 marker created (steps ran locally)", wrct_file_exists(c"bin/wexec_remote_cache_marker.txt"))
	asserts(c"phase3 output created", wrct_file_exists(c"bin/wexec_remote_cache_out.txt"))
	process_result_free(r3)

	free(url)
