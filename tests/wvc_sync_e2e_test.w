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
import lib.str
import tests.tool_e2e
import lib.path
import lib.file
import lib.time
import lib.result
import lib.container
import structures.string
import libs.standard.web.http_client
import libs.extras.vcs.cas


/* ---- server subprocess management ---- */

process* wst_serve_start(char* root_dir, int port):
	char* port_text = itoa(port)
	char** argv = strv_new(6)
	strv_set(argv, 0, c"wvc")
	strv_set(argv, 1, c"serve")
	strv_set(argv, 2, c"--port")
	strv_set(argv, 3, port_text)
	strv_set(argv, 4, c"--root")
	strv_set(argv, 5, root_dir)
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null()
	opts.stdout_mode = process_null()
	opts.stderr_mode = process_null()
	process* p = process_spawn(tool_bin(c"wvc"), argv, opts)
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
	for i in range(64):
		id[i] = '0'
	id[64] = 0
	return id


/* ---- test 1: pull (clone) then push back ---- */

char* wst_dir_a():
	return tool_scratch(c"wvc_sync_a_")


char* wst_dir_b():
	return tool_scratch(c"wvc_sync_b_")


void test_wvc_sync_pull_and_push():
	char* a = wst_dir_a()
	char* b = wst_dir_b()
	dir_remove_all(a)
	dir_remove_all(b)

	tool_ok(0, c"wvc", c"init", a)

	char* a1 = path_join(a, c"file1.txt")
	assert_equal(1, file_write_text(a1, c"hello\n"))
	char* commit1 = trim_eol(tool_ok(0, c"wvc", c"snapshot", a, c"-m", c"first"))
	assert1(cas_valid_id(commit1))

	char* a2 = path_join(a, c"file2.txt")
	assert_equal(1, file_write_text(a2, c"world\n"))
	char* commit2 = trim_eol(tool_ok(0, c"wvc", c"snapshot", a, c"-m", c"second"))
	assert1(cas_valid_id(commit2))

	int port = wst_base_port()
	process* server = wst_serve_start(a, port)
	asserts(c"server accepting connections", wst_wait_for_port(port, 50, 100) != 0)
	char* url = wst_url(port)

	tool_ok(0, c"wvc", c"init", b)

	char* r_pull = tool_ok(b, c"wvc", c"pull", url)
	assert_contains(r_pull, commit2)

	char* r_log_b = tool_ok(b, c"wvc", c"log")
	assert_contains(r_log_b, commit1)
	assert_contains(r_log_b, commit2)
	assert_contains(r_log_b, c"second")

	# Pulling again is a clean no-op.
	char* r_pull2 = tool_ok(b, c"wvc", c"pull", url)
	assert_contains(r_pull2, c"Already up to date.")

	# `pull` only updates the object store and the ref (see sync.w's
	# header comment: it does not materialize working-tree files), so
	# a further commit in B needs a fresh file to have real content.
	char* b3 = path_join(b, c"file3.txt")
	assert_equal(1, file_write_text(b3, c"from b\n"))
	char* commit3 = trim_eol(tool_ok(0, c"wvc", c"snapshot", b, c"-m", c"third (from b)"))
	assert1(cas_valid_id(commit3))

	char* r_push = tool_ok(b, c"wvc", c"push", url)
	assert_contains(r_push, commit3)

	# Verify over the wire, while the server is still up: /refs shows
	# the pushed tip, and /objects/<commit3> serves the raw commit
	# object bytes.
	char* refs_url = wst_url_path(port, c"/refs")
	http_response* refs_resp = http_get(refs_url)
	assert_equal(0, refs_resp.error)
	assert_equal(200, refs_resp.status)
	assert_contains(refs_resp.body, commit3)
	assert_contains(refs_resp.body, c"main")
	http_response_free(refs_resp)
	free(refs_url)

	char* obj_url = wst_object_url(port, commit3)
	http_response* obj_resp = http_get(obj_url)
	assert_equal(0, obj_resp.error)
	assert_equal(200, obj_resp.status)
	assert_contains(obj_resp.body, c"commit")
	http_response_free(obj_resp)
	free(obj_url)

	wst_serve_stop(server)

	# A's own on-disk state (server now dead) also shows the pushed
	# commit -- the ref update is durable, not just a live-server view.
	char* r_log_a = tool_ok(a, c"wvc", c"log")
	assert_contains(r_log_a, commit3)
	assert_contains(r_log_a, c"third (from b)")

	free(url)
	free(commit1)
	free(commit2)
	free(commit3)
	free(a1)
	free(a2)
	free(b3)
	dir_remove_all(a)
	dir_remove_all(b)


/* ---- test 2: divergence is reported and stops (no ref move) ---- */

char* wst_dir_div_a():
	return tool_scratch(c"wvc_sync_div_a_")


char* wst_dir_div_b():
	return tool_scratch(c"wvc_sync_div_b_")


void test_wvc_sync_divergence():
	char* a = wst_dir_div_a()
	char* b = wst_dir_div_b()
	dir_remove_all(a)
	dir_remove_all(b)

	tool_ok(0, c"wvc", c"init", a)

	char* base_path = path_join(a, c"base.txt")
	assert_equal(1, file_write_text(base_path, c"base\n"))
	char* commit_base = trim_eol(tool_ok(0, c"wvc", c"snapshot", a, c"-m", c"base"))

	int port = wst_base_port() + 1
	process* server = wst_serve_start(a, port)
	asserts(c"server accepting connections", wst_wait_for_port(port, 50, 100) != 0)
	char* url = wst_url(port)

	tool_ok(0, c"wvc", c"init", b)

	tool_ok(b, c"wvc", c"pull", url)

	# Diverge: A gets a commit B never sees, B gets a DIFFERENT commit --
	# both children of the shared base.
	char* a_only_path = path_join(a, c"a_only.txt")
	assert_equal(1, file_write_text(a_only_path, c"a side\n"))
	tool_ok(0, c"wvc", c"snapshot", a, c"-m", c"a-side")

	char* b_only_path = path_join(b, c"b_only.txt")
	assert_equal(1, file_write_text(b_only_path, c"b side\n"))
	char* commit_b_side = trim_eol(tool_ok(0, c"wvc", c"snapshot", b, c"-m", c"b-side"))

	process_result* r_pull2 = tool_run(b, c"wvc", c"pull", url)
	assert_equal(1, r_pull2.status)
	assert_contains(r_pull2.stdout_text, c"diverged")
	process_result_free(r_pull2)

	# B's ref did not move: log still shows only the base + b-side chain.
	char* r_log_b = tool_ok(b, c"wvc", c"log")
	assert_contains(r_log_b, commit_b_side)
	assert_contains(r_log_b, c"b-side")
	assert_equal(-1, index_of(r_log_b, c"a-side"))

	wst_serve_stop(server)
	free(url)
	free(commit_base)
	free(commit_b_side)
	free(base_path)
	free(a_only_path)
	free(b_only_path)
	dir_remove_all(a)
	dir_remove_all(b)


/* ---- test 3: a mismatched-hash upload is rejected and never stored ---- */

char* wst_dir_corrupt():
	return tool_scratch(c"wvc_sync_corrupt_")


void test_wvc_sync_corrupt_upload_rejected():
	char* a = wst_dir_corrupt()
	dir_remove_all(a)

	tool_ok(0, c"wvc", c"init", a)

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
	dir_remove_all(a)


/* ---- test 4: sync over a mixed-format store (issue #252 "compressed
   objects" migration story -- an existing store's objects keep reading
   with no rewrite step, and that has to hold across the network too:
   the GET/POST wire protocol is defined over LOGICAL object bytes
   (sync.w's header comment), independent of whichever on-disk encoding
   either side's cas.w store happens to use for a given object) ---- */

char* wst_dir_mix_a():
	return tool_scratch(c"wvc_sync_mix_a_")


char* wst_dir_mix_b():
	return tool_scratch(c"wvc_sync_mix_b_")


# "<repo_root>/.wvc/objects/<2 hex>/<62 hex>" -- tools/wvc.w's own cas
# store root is "<repo_root>/.wvc" (see its header comment).
string_builder* wst_object_file_path(char* repo_root, char* id):
	string_builder* p = string_new()
	string_append(p, repo_root)
	string_append(p, c"/.wvc/objects/")
	string_append_char(p, id[0])
	string_append_char(p, id[1])
	string_append_char(p, '/')
	string_append(p, id + 2)
	return p


# Rewrites the already-stored object `id` in `repo_root`'s store from
# whichever on-disk encoding cas_put/cas_put_raw just used into the
# LEGACY "<type> <len>\0" + payload encoding, in place: same id, same
# logical content, different bytes on disk -- exactly the shape an
# existing (pre-compression) store's objects have. Used to build a
# store that genuinely mixes both encodings without needing a second,
# separately-constructed store (vcs_cas_test.w's vcst_write_legacy
# does the equivalent for a store this module opens directly instead of
# through the `wvc` CLI).
void wst_rewrite_as_legacy(char* repo_root, char* id, char* object_type, char* data, int length):
	string_builder* p = wst_object_file_path(repo_root, id)
	wstream* out = stream_open_write(p.data)
	assert1(cast(int, out) != 0)
	stream_write_cstr(out, object_type)
	stream_write_byte(out, ' ')
	stream_write_int(out, length)
	stream_write_byte(out, 0)
	stream_write(out, data, length)
	stream_close(out)
	string_free(p)


void test_wvc_sync_mixed_format_store():
	char* a = wst_dir_mix_a()
	char* b = wst_dir_mix_b()
	dir_remove_all(a)
	dir_remove_all(b)

	tool_ok(0, c"wvc", c"init", a)

	char* content_a = c"tracked before the rewrite -- this blob becomes a legacy-format object on disk\n"
	int content_a_len = strlen(content_a)
	char* a1 = path_join(a, c"legacy.txt")
	assert_equal(1, file_write_text(a1, content_a))
	char* commit_a = trim_eol(tool_ok(0, c"wvc", c"snapshot", a, c"-m", c"legacy blob"))
	assert1(cas_valid_id(commit_a))

	# The snapshot just wrote legacy.txt's blob (like the tree and
	# commit objects) in the current zlib-compressed encoding; rewrite
	# ONLY the blob in place as a legacy-format object. The tree that
	# references it by id is none the wiser (on-disk encoding never
	# changes an object's id), so A's own store still reads and
	# verifies everything correctly right after the rewrite.
	char* blob_id = cas_id_hex(c"blob", content_a, content_a_len)
	assert1(blob_id != 0)
	wst_rewrite_as_legacy(a, blob_id, c"blob", content_a, content_a_len)

	char* meta_a = path_join(a, c".wvc")
	wcas* store_a = result_expect[wcas*](cas_open(meta_a))
	assert_equal(1, cas_verify(store_a, blob_id))
	wcas_object* local_check = result_expect[wcas_object*](cas_get(store_a, blob_id))
	assert_strings_equal(content_a, local_check.data)
	cas_object_free(local_check)
	cas_close(store_a)

	# Pull B from A: the server (vcs_sync_serve_objects_get) has to
	# read that legacy-format blob and still hand the client the
	# correct logical bytes over the wire.
	int port = wst_base_port() + 3
	process* server = wst_serve_start(a, port)
	asserts(c"server accepting connections", wst_wait_for_port(port, 50, 100) != 0)
	char* url = wst_url(port)

	tool_ok(0, c"wvc", c"init", b)

	char* r_pull = tool_ok(b, c"wvc", c"pull", url)
	assert_contains(r_pull, commit_a)

	# B stored the fetched blob via cas_put_raw, which always writes
	# the CURRENT (zlib-compressed) encoding -- so the same logical
	# object now exists on both sides under two different on-disk
	# encodings, and both read back identically.
	char* meta_b = path_join(b, c".wvc")
	wcas* store_b = result_expect[wcas*](cas_open(meta_b))
	assert_equal(1, cas_verify(store_b, blob_id))
	wcas_object* fetched = result_expect[wcas_object*](cas_get(store_b, blob_id))
	assert_strings_equal(content_a, fetched.data)
	cas_object_free(fetched)

	string_builder* b_obj_path = wst_object_file_path(b, blob_id)
	string_builder* b_obj_raw = cas_read_file(b_obj_path.data)
	assert1(b_obj_raw != 0)
	assert1(b_obj_raw.length >= 2)
	assert_equal('x', b_obj_raw.data[0] & 255)
	string_free(b_obj_raw)
	string_free(b_obj_path)

	# Now push a NEW commit from B back to A, after rewriting B's own
	# new blob as a legacy-format object too -- the push direction
	# (vcs_sync_push_object_closure) has to read a legacy-format LOCAL
	# object and still upload the correct logical bytes.
	char* content_b = c"tracked on b, then rewritten as a legacy-format object before pushing\n"
	int content_b_len = strlen(content_b)
	char* b2 = path_join(b, c"legacy_from_b.txt")
	assert_equal(1, file_write_text(b2, content_b))
	char* commit_b = trim_eol(tool_ok(0, c"wvc", c"snapshot", b, c"-m", c"legacy blob from b"))
	assert1(cas_valid_id(commit_b))

	char* blob_id_b = cas_id_hex(c"blob", content_b, content_b_len)
	assert1(blob_id_b != 0)
	wst_rewrite_as_legacy(b, blob_id_b, c"blob", content_b, content_b_len)
	assert_equal(1, cas_verify(store_b, blob_id_b))
	cas_close(store_b)

	char* r_push = tool_ok(b, c"wvc", c"push", url)
	assert_contains(r_push, commit_b)

	wst_serve_stop(server)

	# A's store, off the network entirely now, has the pushed blob --
	# uploaded from B's legacy-format on-disk bytes, stored via
	# cas_put_raw in A's current encoding.
	wcas* store_a2 = result_expect[wcas*](cas_open(meta_a))
	assert_equal(1, cas_verify(store_a2, blob_id_b))
	wcas_object* pushed = result_expect[wcas_object*](cas_get(store_a2, blob_id_b))
	assert_strings_equal(content_b, pushed.data)
	cas_object_free(pushed)
	cas_close(store_a2)

	free(blob_id)
	free(blob_id_b)
	free(url)
	free(commit_a)
	free(commit_b)
	free(a1)
	free(b2)
	free(meta_a)
	free(meta_b)
	dir_remove_all(a)
	dir_remove_all(b)
# wbuild: binary=wvc_sync_e2e_test tag=tests dep=wvc
# wbuild: step="bin/wvc_sync_e2e_test"
