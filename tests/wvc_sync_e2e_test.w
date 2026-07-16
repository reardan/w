/*
tools/wvc.w's `serve`/`pull`/`push` subcommands: end-to-end test (VCS
wave 4, issue #252 "sync"; design and wire protocol:
libs/extras/vcs/sync.w's header comment). Hand-written
(build.base.json, not wbuildgen's convention) for the same reason
tests/wvc_e2e_test.w is: it needs "wvc" built first and spawns it as a
real subprocess -- twice at once for the sync tests, since `serve` is a
long-running background process the other `wvc` subprocesses talk to
over a real loopback TCP connection.

`wvc serve --port N --root dir` binds a kernel-assigned port only when
N is 0; this test instead picks a pid-derived port up front (with a
distinct offset per test function, so the three tests below never
contend for the same port even though they all run in one process) and
polls a plain TCP connect against it (wst_wait_for_port) until the
server accepts or the bound attempt count is exhausted -- avoiding both
a fixed sleep and the need to read the server's own "Listening on..."
announcement back over a pipe (which would need its own bounded-read
timeout to avoid ever hanging the test if the server failed to start).
The server subprocess itself runs with all three stdio streams
redirected to /dev/null (process_null()): nothing here drains its
output, and leaving stdout piped-but-undrained risks a full-pipe
deadlock once the accept loop's own "Listening on..." line (small, but
the OS pipe buffer is finite) plus anything unread later fills it.

Three scenarios, each with its own throwaway pid-scoped bin/ directory
pair and port offset:
  - test_wvc_sync_pull_and_push: repo A gets two commits, is served,
    repo B pulls (clone-from-empty), gets a third commit of its own,
    pushes back to A -- verified both through `wvc log`/direct HTTP
    GETs against the still-running server AND through a `wvc log` run
    against A's on-disk state after the server is killed (the ref
    update is durable, not just visible in the live server's answers).
  - test_wvc_sync_divergence: A and B share a base commit (via one
    pull), then each commits independently (siblings, not descended
    from one another) -- B's second pull must report divergence, exit
    1, and leave B's ref untouched.
  - test_wvc_sync_corrupt_upload_rejected: drives the wire protocol
    directly (libs/standard/web/http_client.w, not the `wvc` CLI, since
    the CLI has no way to construct a deliberately mismatched upload):
    POSTs well-formed object framing under an id that does NOT hash to
    it, and confirms the server rejects it (400) and never stores it
    (a follow-up GET on that id is still 404) -- the "reject if id
    doesn't verify, recompute the hash server-side" requirement.
*/
import lib.testing
import lib.net
import lib.process
import lib.path
import lib.file
import lib.time
import lib.result
import lib.container
import structures.string
import libs.standard.web.http_client
import libs.extras.vcs.cas


/* ---- shared helpers (deliberately not shared with wvc_e2e_test.w --
   separate compiled test binaries, same convention that file's own
   header comment already follows) ---- */

char* wst_repo_root_cache
char* wst_repo_root():
	if (wst_repo_root_cache == 0):
		char* buf = malloc(4096)
		int n = getcwd(buf, 4096)
		assert1(n > 0)
		wst_repo_root_cache = buf
	return wst_repo_root_cache


char* wst_bin_cache
char* wst_bin():
	if (wst_bin_cache == 0):
		wst_bin_cache = path_join(wst_repo_root(), c"bin/wvc")
	return wst_bin_cache


char** wst_argv(list[char*] args):
	char** v = strv_new(args.length)
	int i = 0
	for char* a in args:
		strv_set(v, i, a)
		i = i + 1
	return v


process_result* wst_run(list[char*] args, char* cwd):
	spawn_options* opts = 0
	if (cwd != 0):
		opts = spawn_options_new()
		opts.cwd = cwd
	char** argv = wst_argv(args)
	process_result* r = process_run(wst_bin(), argv, opts, 0, 10000)
	assert1(r != 0)
	if (opts != 0):
		free(opts)
	free(cast(void*, argv))
	return r


void wst_rm_rf(char* path):
	list[char*] args = new list[char*]
	args.push(c"/bin/rm")
	args.push(c"-rf")
	args.push(path)
	char** argv = wst_argv(args)
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 10000)
	if (r != 0):
		process_result_free(r)
	free(cast(void*, argv))


int wst_index_of(char* haystack, char* needle):
	int hl = strlen(haystack)
	int nl = strlen(needle)
	if (nl == 0):
		return 0
	int i = 0
	while ((i + nl) <= hl):
		int j = 0
		while ((j < nl) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == nl):
			return i
		i = i + 1
	return -1


void wst_assert_contains(char* haystack, char* needle):
	int found = wst_index_of(haystack, needle) >= 0
	if (found == 0):
		wstream* err = stderr_writer()
		stream_write_cstr(err, c"expected to find '")
		stream_write_cstr(err, needle)
		stream_write_cstr(err, c"' in: ")
		stream_write_line(err, haystack)
		stream_flush(err)
	assert1(found)


char* wst_trim(char* s):
	char* out = strclone(s)
	int n = strlen(out)
	while ((n > 0) && ((out[n - 1] == 10) || (out[n - 1] == 13))):
		n = n - 1
		out[n] = 0
	return out


/* ---- server subprocess management ---- */

process* wst_serve_start(char* root_dir, int port):
	char* port_text = itoa(port)
	list[char*] args = new list[char*]
	args.push(c"wvc")
	args.push(c"serve")
	args.push(c"--port")
	args.push(port_text)
	args.push(c"--root")
	args.push(root_dir)
	char** argv = wst_argv(args)
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null()
	opts.stdout_mode = process_null()
	opts.stderr_mode = process_null()
	process* p = process_spawn(wst_bin(), argv, opts)
	assert1(p != 0)
	free(cast(void*, argv))
	free(opts)
	free(port_text)
	return p


void wst_serve_stop(process* p):
	process_kill(p, sigkill())
	process_wait(p)
	process_free(p)


# Polls a plain TCP connect against 127.0.0.1:port up to `attempts`
# times (sleeping `delay_ms` between failures) -- the readiness check
# for a `wvc serve` subprocess that was just spawned; see the header
# comment for why this is preferred here over reading the server's own
# stdout announcement.
int wst_wait_for_port(int port, int attempts, int delay_ms):
	int i = 0
	int ok = 0
	while ((i < attempts) && (ok == 0)):
		int fd = socket_tcp_ipv4()
		if (fd >= 0):
			int rc = socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port)
			close(fd)
			if (rc == 0):
				ok = 1
		if (ok == 0):
			process_sleep_ms(delay_ms)
		i = i + 1
	return ok


int wst_base_port_cache
int wst_base_port():
	if (wst_base_port_cache == 0):
		wst_base_port_cache = 21000 + (getpid() % 30000)
	return wst_base_port_cache


char* wst_url(int port):
	string_builder* s = string_new()
	string_append(s, c"http://127.0.0.1:")
	string_append_int(s, port)
	char* out = s.data
	free(s)
	return out


char* wst_url_path(int port, char* path):
	string_builder* s = string_new()
	string_append(s, c"http://127.0.0.1:")
	string_append_int(s, port)
	string_append(s, path)
	char* out = s.data
	free(s)
	return out


char* wst_object_url(int port, char* id):
	string_builder* s = string_new()
	string_append(s, c"http://127.0.0.1:")
	string_append_int(s, port)
	string_append(s, c"/objects/")
	string_append_char(s, id[0])
	string_append_char(s, id[1])
	string_append_char(s, '/')
	string_append(s, id + 2)
	char* out = s.data
	free(s)
	return out


char* wst_zero_id():
	char* id = malloc(65)
	int i = 0
	while (i < 64):
		id[i] = '0'
		i = i + 1
	id[64] = 0
	return id


/* ---- test 1: pull (clone) then push back ---- */

char* wst_dir_a_cache
char* wst_dir_a():
	if (wst_dir_a_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_sync_a_")
		string_append_int(p, getpid())
		wst_dir_a_cache = p.data
		free(p)
	return wst_dir_a_cache


char* wst_dir_b_cache
char* wst_dir_b():
	if (wst_dir_b_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_sync_b_")
		string_append_int(p, getpid())
		wst_dir_b_cache = p.data
		free(p)
	return wst_dir_b_cache


void test_wvc_sync_pull_and_push():
	char* a = wst_dir_a()
	char* b = wst_dir_b()
	wst_rm_rf(a)
	wst_rm_rf(b)

	list[char*] init_a = new list[char*]
	init_a.push(c"wvc")
	init_a.push(c"init")
	init_a.push(a)
	process_result* r_init_a = wst_run(init_a, 0)
	assert_equal(0, r_init_a.status)
	process_result_free(r_init_a)

	char* a1 = path_join(a, c"file1.txt")
	assert_equal(1, file_write_text(a1, c"hello\n"))
	list[char*] snap1 = new list[char*]
	snap1.push(c"wvc")
	snap1.push(c"snapshot")
	snap1.push(a)
	snap1.push(c"-m")
	snap1.push(c"first")
	process_result* r_snap1 = wst_run(snap1, 0)
	assert_equal(0, r_snap1.status)
	char* commit1 = wst_trim(r_snap1.stdout_text)
	assert1(cas_valid_id(commit1))
	process_result_free(r_snap1)

	char* a2 = path_join(a, c"file2.txt")
	assert_equal(1, file_write_text(a2, c"world\n"))
	list[char*] snap2 = new list[char*]
	snap2.push(c"wvc")
	snap2.push(c"snapshot")
	snap2.push(a)
	snap2.push(c"-m")
	snap2.push(c"second")
	process_result* r_snap2 = wst_run(snap2, 0)
	assert_equal(0, r_snap2.status)
	char* commit2 = wst_trim(r_snap2.stdout_text)
	assert1(cas_valid_id(commit2))
	process_result_free(r_snap2)

	int port = wst_base_port()
	process* server = wst_serve_start(a, port)
	asserts(c"server accepting connections", wst_wait_for_port(port, 50, 100) != 0)
	char* url = wst_url(port)

	list[char*] init_b = new list[char*]
	init_b.push(c"wvc")
	init_b.push(c"init")
	init_b.push(b)
	process_result* r_init_b = wst_run(init_b, 0)
	assert_equal(0, r_init_b.status)
	process_result_free(r_init_b)

	list[char*] pull_args = new list[char*]
	pull_args.push(c"wvc")
	pull_args.push(c"pull")
	pull_args.push(url)
	process_result* r_pull = wst_run(pull_args, b)
	assert_equal(0, r_pull.status)
	wst_assert_contains(r_pull.stdout_text, commit2)
	process_result_free(r_pull)

	list[char*] log_args = new list[char*]
	log_args.push(c"wvc")
	log_args.push(c"log")
	process_result* r_log_b = wst_run(log_args, b)
	assert_equal(0, r_log_b.status)
	wst_assert_contains(r_log_b.stdout_text, commit1)
	wst_assert_contains(r_log_b.stdout_text, commit2)
	wst_assert_contains(r_log_b.stdout_text, c"second")
	process_result_free(r_log_b)

	# Pulling again is a clean no-op.
	process_result* r_pull2 = wst_run(pull_args, b)
	assert_equal(0, r_pull2.status)
	wst_assert_contains(r_pull2.stdout_text, c"Already up to date.")
	process_result_free(r_pull2)

	# `pull` only updates the object store and the ref (see sync.w's
	# header comment: it does not materialize working-tree files), so
	# a further commit in B needs a fresh file to have real content.
	char* b3 = path_join(b, c"file3.txt")
	assert_equal(1, file_write_text(b3, c"from b\n"))
	list[char*] snap3 = new list[char*]
	snap3.push(c"wvc")
	snap3.push(c"snapshot")
	snap3.push(b)
	snap3.push(c"-m")
	snap3.push(c"third (from b)")
	process_result* r_snap3 = wst_run(snap3, 0)
	assert_equal(0, r_snap3.status)
	char* commit3 = wst_trim(r_snap3.stdout_text)
	assert1(cas_valid_id(commit3))
	process_result_free(r_snap3)

	list[char*] push_args = new list[char*]
	push_args.push(c"wvc")
	push_args.push(c"push")
	push_args.push(url)
	process_result* r_push = wst_run(push_args, b)
	assert_equal(0, r_push.status)
	wst_assert_contains(r_push.stdout_text, commit3)
	process_result_free(r_push)

	# Verify over the wire, while the server is still up: /refs shows
	# the pushed tip, and /objects/<commit3> serves the raw commit
	# object bytes.
	char* refs_url = wst_url_path(port, c"/refs")
	http_response* refs_resp = http_get(refs_url)
	assert_equal(0, refs_resp.error)
	assert_equal(200, refs_resp.status)
	wst_assert_contains(refs_resp.body, commit3)
	wst_assert_contains(refs_resp.body, c"main")
	http_response_free(refs_resp)
	free(refs_url)

	char* obj_url = wst_object_url(port, commit3)
	http_response* obj_resp = http_get(obj_url)
	assert_equal(0, obj_resp.error)
	assert_equal(200, obj_resp.status)
	wst_assert_contains(obj_resp.body, c"commit")
	http_response_free(obj_resp)
	free(obj_url)

	wst_serve_stop(server)

	# A's own on-disk state (server now dead) also shows the pushed
	# commit -- the ref update is durable, not just a live-server view.
	process_result* r_log_a = wst_run(log_args, a)
	assert_equal(0, r_log_a.status)
	wst_assert_contains(r_log_a.stdout_text, commit3)
	wst_assert_contains(r_log_a.stdout_text, c"third (from b)")
	process_result_free(r_log_a)

	free(url)
	free(commit1)
	free(commit2)
	free(commit3)
	free(a1)
	free(a2)
	free(b3)
	wst_rm_rf(a)
	wst_rm_rf(b)


/* ---- test 2: divergence is reported and stops (no ref move) ---- */

char* wst_dir_div_a_cache
char* wst_dir_div_a():
	if (wst_dir_div_a_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_sync_div_a_")
		string_append_int(p, getpid())
		wst_dir_div_a_cache = p.data
		free(p)
	return wst_dir_div_a_cache


char* wst_dir_div_b_cache
char* wst_dir_div_b():
	if (wst_dir_div_b_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_sync_div_b_")
		string_append_int(p, getpid())
		wst_dir_div_b_cache = p.data
		free(p)
	return wst_dir_div_b_cache


void test_wvc_sync_divergence():
	char* a = wst_dir_div_a()
	char* b = wst_dir_div_b()
	wst_rm_rf(a)
	wst_rm_rf(b)

	list[char*] init_a = new list[char*]
	init_a.push(c"wvc")
	init_a.push(c"init")
	init_a.push(a)
	process_result* r_init_a = wst_run(init_a, 0)
	assert_equal(0, r_init_a.status)
	process_result_free(r_init_a)

	char* base_path = path_join(a, c"base.txt")
	assert_equal(1, file_write_text(base_path, c"base\n"))
	list[char*] snap_base = new list[char*]
	snap_base.push(c"wvc")
	snap_base.push(c"snapshot")
	snap_base.push(a)
	snap_base.push(c"-m")
	snap_base.push(c"base")
	process_result* r_base = wst_run(snap_base, 0)
	assert_equal(0, r_base.status)
	char* commit_base = wst_trim(r_base.stdout_text)
	process_result_free(r_base)

	int port = wst_base_port() + 1
	process* server = wst_serve_start(a, port)
	asserts(c"server accepting connections", wst_wait_for_port(port, 50, 100) != 0)
	char* url = wst_url(port)

	list[char*] init_b = new list[char*]
	init_b.push(c"wvc")
	init_b.push(c"init")
	init_b.push(b)
	process_result* r_init_b = wst_run(init_b, 0)
	assert_equal(0, r_init_b.status)
	process_result_free(r_init_b)

	list[char*] pull_args = new list[char*]
	pull_args.push(c"wvc")
	pull_args.push(c"pull")
	pull_args.push(url)
	process_result* r_pull1 = wst_run(pull_args, b)
	assert_equal(0, r_pull1.status)
	process_result_free(r_pull1)

	# Diverge: A gets a commit B never sees, B gets a DIFFERENT commit --
	# both children of the shared base.
	char* a_only_path = path_join(a, c"a_only.txt")
	assert_equal(1, file_write_text(a_only_path, c"a side\n"))
	list[char*] snap_a_side = new list[char*]
	snap_a_side.push(c"wvc")
	snap_a_side.push(c"snapshot")
	snap_a_side.push(a)
	snap_a_side.push(c"-m")
	snap_a_side.push(c"a-side")
	process_result* r_a_side = wst_run(snap_a_side, 0)
	assert_equal(0, r_a_side.status)
	process_result_free(r_a_side)

	char* b_only_path = path_join(b, c"b_only.txt")
	assert_equal(1, file_write_text(b_only_path, c"b side\n"))
	list[char*] snap_b_side = new list[char*]
	snap_b_side.push(c"wvc")
	snap_b_side.push(c"snapshot")
	snap_b_side.push(b)
	snap_b_side.push(c"-m")
	snap_b_side.push(c"b-side")
	process_result* r_b_side = wst_run(snap_b_side, 0)
	assert_equal(0, r_b_side.status)
	char* commit_b_side = wst_trim(r_b_side.stdout_text)
	process_result_free(r_b_side)

	process_result* r_pull2 = wst_run(pull_args, b)
	assert_equal(1, r_pull2.status)
	wst_assert_contains(r_pull2.stdout_text, c"diverged")
	process_result_free(r_pull2)

	# B's ref did not move: log still shows only the base + b-side chain.
	list[char*] log_args = new list[char*]
	log_args.push(c"wvc")
	log_args.push(c"log")
	process_result* r_log_b = wst_run(log_args, b)
	assert_equal(0, r_log_b.status)
	wst_assert_contains(r_log_b.stdout_text, commit_b_side)
	wst_assert_contains(r_log_b.stdout_text, c"b-side")
	assert_equal(-1, wst_index_of(r_log_b.stdout_text, c"a-side"))
	process_result_free(r_log_b)

	wst_serve_stop(server)
	free(url)
	free(commit_base)
	free(commit_b_side)
	free(base_path)
	free(a_only_path)
	free(b_only_path)
	wst_rm_rf(a)
	wst_rm_rf(b)


/* ---- test 3: a mismatched-hash upload is rejected and never stored ---- */

char* wst_dir_corrupt_cache
char* wst_dir_corrupt():
	if (wst_dir_corrupt_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/wvc_sync_corrupt_")
		string_append_int(p, getpid())
		wst_dir_corrupt_cache = p.data
		free(p)
	return wst_dir_corrupt_cache


void test_wvc_sync_corrupt_upload_rejected():
	char* a = wst_dir_corrupt()
	wst_rm_rf(a)

	list[char*] init_a = new list[char*]
	init_a.push(c"wvc")
	init_a.push(c"init")
	init_a.push(a)
	process_result* r_init_a = wst_run(init_a, 0)
	assert_equal(0, r_init_a.status)
	process_result_free(r_init_a)

	int port = wst_base_port() + 2
	process* server = wst_serve_start(a, port)
	asserts(c"server accepting connections", wst_wait_for_port(port, 50, 100) != 0)

	# Well-formed cas.w framing ("blob 5\0hello"), but POSTed under an
	# id that is NOT sha256("blob 5\0hello") -- the server must
	# recompute the hash itself and reject the upload rather than
	# trusting the URL.
	string_builder* payload = string_new()
	string_append(payload, c"blob 5")
	string_append_char(payload, 0)
	string_append(payload, c"hello")

	char* bogus_id = wst_zero_id()
	char* obj_url = wst_object_url(port, bogus_id)

	http_req* req = http_req_new(c"POST", obj_url)
	req.body = payload.data
	req.body_len = payload.length
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(400, resp.status)
	http_req_free(req)
	http_response_free(resp)
	string_free(payload)

	# Never stored: a GET on the same id is still 404.
	http_response* get_resp = http_get(obj_url)
	assert_equal(0, get_resp.error)
	assert_equal(404, get_resp.status)
	http_response_free(get_resp)

	free(bogus_id)
	free(obj_url)
	wst_serve_stop(server)
	wst_rm_rf(a)
