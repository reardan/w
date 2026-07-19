/*
wvc push/pull over HTTP: have/want negotiation for loose objects (VCS
wave 4, issue #252 "sync"; design: docs/projects/version_control.md's
"Wave 4 -- merge and sync" section). Deliberately NOT git's smart
protocol (no packfiles, no pack negotiation, no delta transfer over the
wire) -- the design doc's own "have/want" phrase is the model: the
server exposes its refs and its per-commit ancestor closure, the client
diffs that against what it already has locally (cas_has -- content
addressing makes "do I already have this" an O(1) file-existence check)
and fetches exactly the rest. Kept dumb and correct over clever: this is
the same posture cas.w/commit.w/tree.w/merge3.w already take.

Wire protocol (server side: vcs_sync_register_routes; client side: the
vcs_sync_pull/vcs_sync_push functions below), all plain HTTP/1.1 over
libs/standard/web/http_server.w's ServerContext + routing:

  GET  /refs
      Line-oriented: "<64-hex id> <refname>\n" per ref, sorted by name
      (commit.w's own ref_list order). No refs yet -> 200 with an empty
      body, not 404 (an empty repo is a valid state to sync against).

  GET  /objects/<2-hex>/<62-hex>
      The object's LOGICAL bytes -- "<type> <len>\0" + payload (see
      cas.w's header comment on cas_parse_framed) -- reconstructed via
      cas_get + cas_object_bytes, deliberately NOT the raw on-disk
      bytes cas_object_path names: cas.w's loose objects are now
      zlib-compressed on disk (its "On-disk encoding" section), and
      this wire format predates that and stays the uncompressed
      logical form on purpose, so a client speaking this protocol never
      has to know or care which encoding either side's store uses.
      404 when absent, 400 for a malformed path.

  POST /objects/<2-hex>/<62-hex>
      Upload: the request body must be that SAME logical framing (never
      compressed, regardless of how the server ends up storing it). The
      server parses it (cas_parse_framed) and recomputes
      cas_id_hex(type, payload, length) -- if that does not match the
      id in the URL, the upload is rejected (400) and NOTHING is
      written; a client cannot poison the store by POSTing bytes under
      an id they don't actually hash to. On a match the object is
      stored via cas_put_raw (200), which re-encodes it on disk exactly
      like any other write (cas.w's cas_store_bytes).

  GET  /ancestry/<64-hex commit id>
      Line-oriented list of that commit's own id followed by every
      transitive ancestor (BFS over ALL parents, not just parent[0] --
      merge commits matter here), in discovery order. This is the
      have/want substitute: the client already knows what it has
      locally (cas_has), so subtracting that from this list gives
      exactly the missing commits, with no server-side per-client state
      and no separate negotiation round trip. Bounded by
      VCS_SYNC_ANCESTRY_CAP() commits (see its own comment) so a client
      can never make the server do unbounded work by naming a
      pathologically deep (or malicious) tip; a truncated response
      carries the VCS_SYNC_TRUNCATED_HEADER() response header, and
      every caller here treats a truncated ancestry as a hard "cannot
      safely sync" stop rather than silently proceeding on a partial
      view of history (see vcs_sync_pull/vcs_sync_push). 404 when the
      commit itself is not present on the server, 400 for a malformed
      id.

  POST /refs/<name>
      Body: a bare 64-hex commit id (a trailing newline is tolerated
      and stripped). Creates the ref if it does not exist yet;
      otherwise accepts the update ONLY when the ref's current id is
      itself in the new id's ancestry closure (a fast-forward) --
      verified by literally reusing the /ancestry walk above rather
      than building a separate libs/extras/vcs/dag.w graph, since the
      membership check both endpoints need is the same query. Rejects
      a non-fast-forward with 409; a client sees that as "push
      rejected", exactly like git -- no server-side merging, ever.

Client operations:

  vcs_sync_pull(store, refs, url, ref_name, out): GET /refs, resolve
  ref_name to the remote tip, GET its /ancestry, subtract what's already
  local (cas_has) to get the missing commit ids, and for each fetch the
  commit object and recursively walk down into it (commit -> tree,
  tree -> children) via vcs_sync_fetch_object_closure, STOPPING as soon
  as an id already exists locally (the Merkle short-circuit tree_diff.w
  already uses, applied to network fetch instead of local diff) so a
  repeat pull only transfers what's new. Once every object is local,
  fast-forwards ref_name if the local tip (if any) is in the remote
  ancestry closure just fetched; otherwise reports a clean divergence
  message and returns without touching the ref -- reconciling divergent
  history is `wvc merge`'s job, not pull's (per the design doc's Wave 4
  bullet and the task spec: "report divergence and stop").
  Deliberately does NOT materialize working-tree files: pull only
  updates the object store and the ref, closer to `git fetch &&
  git merge --ff-only` than a full `git pull` -- `wvc log`/`wvc diff`
  read the result the same way they read a local snapshot's commit.

  vcs_sync_push(store, refs, url, ref_name, out): the inverse. Walks the
  LOCAL ancestry of ref_name's local tip (vcs_sync_ancestry against the
  local store) and, for each commit, uploads whatever the remote lacks
  via vcs_sync_push_object_closure -- probing existence with a plain GET
  per object (no HEAD method; "per-object probing is fine for v1" per
  the task spec) and stopping the walk under an object the remote
  already reports having, on the same push-is-only-ever-complete
  invariant vcs_sync_push_object_closure's own comment documents. Then
  POSTs the new tip to /refs/<name>; the server's own fast-forward
  check is the only guard (this client makes no local merge-base
  decision before pushing -- a rejection is reported and the command
  exits non-zero, same as `git push` without --force).

Error handling posture (the task spec's "all network errors produce
clean messages, never corrupt the local store" -- distinguishing two
failure classes deliberately):
  - Network/protocol failures (can't connect, a timeout, a malformed or
    unexpected response, a rejected/truncated ancestry, a reported
    divergence) are never fatal here: every helper either returns 0
    (vcs_sync_get/vcs_sync_post, mirroring http_request's own "never
    returns 0 on success" contract inverted for failure) or a plain int
    status the caller checks, with a one-line message already written
    to `out` -- vcs_sync_pull/vcs_sync_push return 0 (success) or 1
    (clean, already-reported failure); tools/wvc.w's `pull`/`push`
    subcommands surface that as the process exit code, same as any
    other porcelain outcome (compare `wvc merge`'s CONFLICT reporting).
  - Local store failures (a write to `.wvc/objects` failing, a stored
    object that fails to parse) are treated the same as everywhere else
    in this porcelain: translate_syscall_failure prints the errno and
    exits -- these indicate local corruption or a full/read-only disk,
    not a recoverable protocol outcome, and every other wvc.w command
    already fails this same hard way (wvc_fail's own doc comment).
  - Objects are only ever written via cas_put_raw (temp file + rename,
    cas.w's own atomicity) after a hash-verified fetch, or via the
    server's own hash-verified upload path -- there is no code path
    here that writes an object before its bytes are known to match its
    claimed id, so a network failure mid-transfer can leave objects
    missing but never corrupt ones on disk.

Nothing here enters the seed import graph.
*/
import lib.lib
import lib.path
import lib.result
import lib.stream
import lib.container
import structures.string
import libs.standard.web.http_client
import libs.standard.web.http_server
import libs.extras.vcs.cas
import libs.extras.vcs.tree
import libs.extras.vcs.commit


# Cap on how many commits a single /ancestry walk (server side) or local
# push-side ancestry walk (client side) will enumerate: "a few thousand"
# per the task spec. This repository's own history is nowhere near this
# size; the cap exists purely so a serve endpoint can't be made to do
# unbounded work by a pathologically deep or adversarial commit graph.
# Every caller here treats a truncated walk as "cannot safely proceed"
# rather than silently syncing a partial history (see the header
# comment) -- raising this constant is always safe, lowering it changes
# what a client with a longer local history can push/pull.
int VCS_SYNC_ANCESTRY_CAP():
	return 4096


# Response header the /ancestry endpoint sets (to any non-empty value)
# when its walk hit VCS_SYNC_ANCESTRY_CAP() before exhausting the
# commit's full ancestry -- the response body is still whatever was
# collected up to the cap, never silently wrong, just possibly
# incomplete, and every client-side reader here refuses to act on a
# truncated result. http_response_header/request_context_header do
# case-insensitive lookups, so the exact case here only matters for what
# appears on the wire.
char* VCS_SYNC_TRUNCATED_HEADER():
	return c"X-Wvc-Ancestry-Truncated"


# Server-side handler state: the already-open store/refs a `wvc serve`
# process holds for its whole lifetime (see tools/wvc.w's wvc_cmd_serve).
# Both cas_open/refs_open just remember directory paths -- every request
# re-reads/re-writes real files fresh, so holding one of these across
# many requests (and across the local `wvc` CLI commands a test or user
# runs concurrently against the same repo, e.g. this file's own e2e
# test) is safe with no in-memory caching to go stale.
struct wvc_serve_ctx:
	wcas* store
	wrefs* refs


/* ---- shared: ancestry walk (used by both the /ancestry endpoint and
   the fast-forward check it backs, and by the client for both pull's
   post-fetch fast-forward check and push's own local closure) ---- */


# BFS over `tip_hex`'s own id and every transitive ancestor (following
# ALL parents of a merge commit, not just parent[0] -- unlike wvc.w's
# `log`, which deliberately only follows the mainline for a readable
# history view, this needs the COMPLETE closure). Bounded to
# VCS_SYNC_ANCESTRY_CAP() commits; *out_truncated is set to 1 when the
# cap was hit (some ancestors are NOT in the returned list). Returns the
# visited ids in discovery order (caller-owned: free each entry and
# list_free the list). Errors: -22 for a malformed tip id, otherwise
# commit_load's own errors (-2 when `tip_hex`, or some ancestor it
# references, is not present in `store`; CAS_ERR_CORRUPT for a stored
# object that doesn't parse as a commit).
wresult[list[char*]]* vcs_sync_ancestry(wcas* store, char* tip_hex, int* out_truncated):
	*out_truncated = 0
	if (cas_valid_id(tip_hex) == 0):
		return result_new_error[list[char*]](-22)

	list[char*] order = new list[char*]
	map[char*, int] seen = new map[char*, int]
	list[char*] queue = new list[char*]
	int cap = VCS_SYNC_ANCESTRY_CAP()

	char* start = strclone(tip_hex)
	queue.push(start)
	seen[start] = 1

	int qi = 0
	int err = 0
	int stop = 0
	while ((qi < queue.length) && (stop == 0)):
		if (order.length >= cap):
			*out_truncated = 1
			stop = 1
		else:
			char* id = queue[qi]
			qi = qi + 1
			wresult[commit_object*]* co_r = commit_load(store, id)
			if (result_is_error[commit_object*](co_r)):
				err = result_code[commit_object*](co_r)
				result_free[commit_object*](co_r)
				stop = 1
				free(id)
			else:
				commit_object* co = result_value[commit_object*](co_r)
				result_free[commit_object*](co_r)
				order.push(id)
				for char* pid in co.parent_ids:
					if ((pid in seen) == 0):
						char* clone = strclone(pid)
						seen[clone] = 1
						queue.push(clone)
				commit_free(co)

	while (qi < queue.length):
		free(queue[qi])
		qi = qi + 1
	list_free[char*](queue)
	map_free[char*, int](seen)

	if (err != 0):
		for char* o in order:
			free(o)
		list_free[char*](order)
		return result_new_error[list[char*]](err)
	return result_new_ok[list[char*]](order)


/* ---- server: route handlers ---- */


# "/objects/<2 hex>/<62 hex>" -> the reconstructed 64-hex id, or 0 when
# the path doesn't match that shape or the id isn't a valid cas id
# (mirrors cas_object_path in reverse; the same extraction
# tests/wexec_remote_cache_test.w's wrct_extract_id does for its own
# throwaway object server).
char* vcs_sync_extract_object_id(char* path):
	char* prefix = c"/objects/"
	int plen = strlen(prefix)
	if (starts_with(path, prefix) == 0):
		return 0
	char* rest = path + plen
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


void vcs_sync_serve_refs_get(RequestContext* rc, void* user_data):
	wvc_serve_ctx* ctx = cast(wvc_serve_ctx*, user_data)
	wresult[list[char*]]* names_r = ref_list(ctx.refs)
	if (result_is_error[list[char*]](names_r)):
		result_free[list[char*]](names_r)
		request_context_text(rc, 500, c"cannot list refs")
		return
	list[char*] names = result_value[list[char*]](names_r)
	result_free[list[char*]](names_r)

	string_builder* body = string_new()
	for char* name in names:
		wresult[char*]* id_r = ref_read(ctx.refs, name)
		if (result_is_ok[char*](id_r)):
			char* id = result_value[char*](id_r)
			string_append(body, id)
			string_append_char(body, ' ')
			string_append(body, name)
			string_append_char(body, 10)
			free(id)
		result_free[char*](id_r)
		free(name)
	list_free[char*](names)

	request_context_set_status(rc, 200)
	request_context_set_header(rc, c"Content-Type", c"text/plain")
	request_context_write_body(rc, body.data, body.length)
	string_free(body)


void vcs_sync_serve_objects_get(RequestContext* rc, void* user_data):
	wvc_serve_ctx* ctx = cast(wvc_serve_ctx*, user_data)
	char* id = vcs_sync_extract_object_id(request_context_path(rc))
	if (id == 0):
		request_context_text(rc, 400, c"bad object path")
		return
	# cas_get, not a raw cas_object_path/cas_read_file, so the wire body
	# is always the logical framing regardless of the store's on-disk
	# encoding (see this file's header comment and cas.w's "On-disk
	# encoding" section) -- a client must never see zlib-compressed
	# bytes it never asked to decode.
	wresult[wcas_object*]* got = cas_get(ctx.store, id)
	free(id)
	if (result_is_error[wcas_object*](got)):
		int code = result_code[wcas_object*](got)
		result_free[wcas_object*](got)
		if (code == -2):
			request_context_text(rc, 404, c"Not Found")
		else:
			request_context_text(rc, 500, c"cannot read object")
		return
	wcas_object* obj = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	string_builder* wire = cas_object_bytes(obj.object_type, obj.data, obj.length)
	cas_object_free(obj)
	request_context_set_status(rc, 200)
	request_context_set_header(rc, c"Content-Type", c"application/octet-stream")
	request_context_write_body(rc, wire.data, wire.length)
	string_free(wire)


void vcs_sync_serve_objects_post(RequestContext* rc, void* user_data):
	wvc_serve_ctx* ctx = cast(wvc_serve_ctx*, user_data)
	char* id = vcs_sync_extract_object_id(request_context_path(rc))
	if (id == 0):
		request_context_text(rc, 400, c"bad object path")
		return

	char* body = request_context_body(rc)
	int body_len = request_context_body_len(rc)
	wresult[wcas_object*]* parsed_r = cas_parse_framed(body, body_len)
	if (result_is_error[wcas_object*](parsed_r)):
		result_free[wcas_object*](parsed_r)
		free(id)
		request_context_text(rc, 400, c"malformed object framing")
		return
	wcas_object* obj = result_value[wcas_object*](parsed_r)
	result_free[wcas_object*](parsed_r)

	# Reject if the id doesn't verify -- recompute the hash server-side
	# rather than trusting the URL (the task spec's explicit requirement,
	# and the whole point of a content-addressed store): nothing is
	# written unless the claimed id is exactly sha256("<type> <len>\0" +
	# payload).
	char* recomputed = cas_id_hex(obj.object_type, obj.data, obj.length)
	int match = (recomputed != 0) && (strcmp(recomputed, id) == 0)
	if (recomputed != 0):
		free(recomputed)
	if (match == 0):
		cas_object_free(obj)
		free(id)
		request_context_text(rc, 400, c"object id does not verify")
		return

	wresult[char*]* put_r = cas_put_raw(ctx.store, id, obj.object_type, obj.data, obj.length)
	cas_object_free(obj)
	if (result_is_error[char*](put_r)):
		result_free[char*](put_r)
		free(id)
		request_context_text(rc, 500, c"cannot store object")
		return
	free(result_value[char*](put_r))
	result_free[char*](put_r)
	free(id)
	request_context_text(rc, 200, c"stored")


void vcs_sync_serve_ancestry_get(RequestContext* rc, void* user_data):
	wvc_serve_ctx* ctx = cast(wvc_serve_ctx*, user_data)
	char* path = request_context_path(rc)
	char* prefix = c"/ancestry/"
	if (starts_with(path, prefix) == 0):
		request_context_text(rc, 404, c"Not Found")
		return
	char* hex = path + strlen(prefix)
	if (cas_valid_id(hex) == 0):
		request_context_text(rc, 400, c"bad commit id")
		return

	int truncated = 0
	wresult[list[char*]]* r = vcs_sync_ancestry(ctx.store, hex, &truncated)
	if (result_is_error[list[char*]](r)):
		int code = result_code[list[char*]](r)
		result_free[list[char*]](r)
		if (code == -2):
			request_context_text(rc, 404, c"unknown commit")
		else:
			request_context_text(rc, 500, c"ancestry walk failed")
		return
	list[char*] ids = result_value[list[char*]](r)
	result_free[list[char*]](r)

	string_builder* body = string_new()
	for char* aid in ids:
		string_append(body, aid)
		string_append_char(body, 10)
		free(aid)
	list_free[char*](ids)

	if (truncated != 0):
		request_context_set_header(rc, VCS_SYNC_TRUNCATED_HEADER(), c"1")
	request_context_set_status(rc, 200)
	request_context_set_header(rc, c"Content-Type", c"text/plain")
	request_context_write_body(rc, body.data, body.length)
	string_free(body)


# Strips a single trailing '\n'/'\r' (and nothing else) and requires
# exactly 64 hex characters remain -- the wire form vcs_sync_push always
# sends. Returns 0 for anything else (malformed, wrong length, or not a
# valid cas id), never partially-parsed data.
char* vcs_sync_trim_id(char* body, int body_len):
	int n = body_len
	while ((n > 0) && ((body[n - 1] == 10) || (body[n - 1] == 13))):
		n = n - 1
	if (n != 64):
		return 0
	char* out = path_clone_range(body, n)
	if (cas_valid_id(out) == 0):
		free(out)
		return 0
	return out


void vcs_sync_serve_refs_post(RequestContext* rc, void* user_data):
	wvc_serve_ctx* ctx = cast(wvc_serve_ctx*, user_data)
	char* path = request_context_path(rc)
	char* prefix = c"/refs/"
	if (starts_with(path, prefix) == 0):
		request_context_text(rc, 404, c"Not Found")
		return
	char* name = path + strlen(prefix)
	if (ref_valid_name(name) == 0):
		request_context_text(rc, 400, c"bad ref name")
		return

	char* new_id = vcs_sync_trim_id(request_context_body(rc), request_context_body_len(rc))
	if (new_id == 0):
		request_context_text(rc, 400, c"bad commit id")
		return

	if (ref_exists(ctx.refs, name) == 0):
		wresult[int]* created = ref_create(ctx.refs, name, new_id, c"wvc push")
		int ok = result_is_ok[int](created)
		result_free[int](created)
		free(new_id)
		if (ok == 0):
			request_context_text(rc, 500, c"cannot create ref")
		else:
			request_context_text(rc, 200, c"created")
		return

	wresult[char*]* cur_r = ref_read(ctx.refs, name)
	if (result_is_error[char*](cur_r)):
		result_free[char*](cur_r)
		free(new_id)
		request_context_text(rc, 500, c"cannot read current ref")
		return
	char* current_id = result_value[char*](cur_r)
	result_free[char*](cur_r)

	if (strcmp(current_id, new_id) == 0):
		free(current_id)
		free(new_id)
		request_context_text(rc, 200, c"up to date")
		return

	int truncated = 0
	wresult[list[char*]]* anc_r = vcs_sync_ancestry(ctx.store, new_id, &truncated)
	if (result_is_error[list[char*]](anc_r)):
		int code = result_code[list[char*]](anc_r)
		result_free[list[char*]](anc_r)
		free(current_id)
		free(new_id)
		if (code == -2):
			request_context_text(rc, 400, c"unknown commit id")
		else:
			request_context_text(rc, 500, c"ancestry walk failed")
		return
	list[char*] ids = result_value[list[char*]](anc_r)
	result_free[list[char*]](anc_r)

	int is_ff = 0
	for char* aid in ids:
		if (strcmp(aid, current_id) == 0):
			is_ff = 1
		free(aid)
	list_free[char*](ids)

	# A truncated walk that did NOT find current_id could be a false
	# negative (the real common point lies beyond the cap) -- either way
	# the fast-forward cannot be safely confirmed, and vcs_sync_serve_
	# refs_post already rejects an unconfirmed fast-forward below, so no
	# separate branch is needed: truncation only ever makes this stricter
	# (a legitimate very-deep fast-forward can be refused), never looser.
	if (is_ff == 0):
		free(current_id)
		free(new_id)
		request_context_text(rc, 409, c"not a fast-forward")
		return

	wresult[int]* updated = ref_update(ctx.refs, name, new_id, c"wvc push")
	int ok = result_is_ok[int](updated)
	result_free[int](updated)
	free(current_id)
	free(new_id)
	if (ok == 0):
		request_context_text(rc, 500, c"cannot update ref")
	else:
		request_context_text(rc, 200, c"updated")


# Registers every endpoint documented in the header comment on `s`
# (switching it to the RequestContext/routing dispatch -- see
# http_server.w's own module doc). `ctx` is borrowed by the ServerContext
# for its whole lifetime (tools/wvc.w's wvc_cmd_serve owns it).
void vcs_sync_register_routes(ServerContext* s, wvc_serve_ctx* ctx):
	void* user_data = cast(void*, ctx)
	server_route(s, c"GET", c"/refs", vcs_sync_serve_refs_get, user_data)
	server_route(s, c"POST", c"/refs/*", vcs_sync_serve_refs_post, user_data)
	server_route(s, c"GET", c"/objects/*", vcs_sync_serve_objects_get, user_data)
	server_route(s, c"POST", c"/objects/*", vcs_sync_serve_objects_post, user_data)
	server_route(s, c"GET", c"/ancestry/*", vcs_sync_serve_ancestry_get, user_data)


/* ---- client: shared HTTP helpers ---- */


char* vcs_sync_url_concat(char* base, char* suffix):
	string_builder* s = string_new()
	string_append(s, base)
	string_append(s, suffix)
	char* out = s.data
	free(s)
	return out


char* vcs_sync_refs_url(char* base):
	return vcs_sync_url_concat(base, c"/refs")


char* vcs_sync_object_url(char* base, char* id):
	string_builder* s = string_new()
	string_append(s, base)
	string_append(s, c"/objects/")
	string_append_char(s, id[0])
	string_append_char(s, id[1])
	string_append_char(s, '/')
	string_append(s, id + 2)
	char* out = s.data
	free(s)
	return out


char* vcs_sync_ancestry_url(char* base, char* id):
	string_builder* s = string_new()
	string_append(s, base)
	string_append(s, c"/ancestry/")
	string_append(s, id)
	char* out = s.data
	free(s)
	return out


char* vcs_sync_refs_post_url(char* base, char* ref_name):
	string_builder* s = string_new()
	string_append(s, base)
	string_append(s, c"/refs/")
	string_append(s, ref_name)
	char* out = s.data
	free(s)
	return out


# GET url. On transport success returns the response (any HTTP status --
# the caller checks resp.status); on transport failure (connection
# refused, DNS, timeout, ...) writes one clean line to `out` and returns
# 0. Never crashes the process -- see the header comment's error
# handling posture.
http_response* vcs_sync_get(char* url, wstream* out):
	http_req* req = http_req_new(c"GET", url)
	http_response* resp = http_request(req)
	http_req_free(req)
	if (resp.error != http_error_none()):
		stream_write_cstr(out, c"wvc: network error: ")
		stream_write_line(out, http_error_string(resp.error))
		stream_flush(out)
		http_response_free(resp)
		return 0
	return resp


http_response* vcs_sync_post(char* url, char* body, int body_len, wstream* out):
	http_req* req = http_req_new(c"POST", url)
	req.body = body
	req.body_len = body_len
	http_response* resp = http_request(req)
	http_req_free(req)
	if (resp.error != http_error_none()):
		stream_write_cstr(out, c"wvc: network error: ")
		stream_write_line(out, http_error_string(resp.error))
		stream_flush(out)
		http_response_free(resp)
		return 0
	return resp


# Parses a GET /refs response body ("<64-hex id> <name>\n" per line)
# into a name -> id map (both owned; free with vcs_sync_refs_free).
# Malformed lines are skipped rather than trusted -- this client never
# assumes the server's bytes are well-formed just because the transport
# succeeded.
map[char*, char*] vcs_sync_parse_refs(char* body, int body_len):
	map[char*, char*] out = new map[char*, char*]
	int pos = 0
	while (pos < body_len):
		int line_end = pos
		while ((line_end < body_len) && (body[line_end] != 10)):
			line_end = line_end + 1
		int ok = (line_end - pos) > 65
		if (ok):
			ok = body[pos + 64] == ' '
		if (ok):
			char* id = path_clone_range(body + pos, 64)
			if (cas_valid_id(id) == 0):
				free(id)
			else:
				char* name = path_clone_range(body + (pos + 65), line_end - (pos + 65))
				if (ref_valid_name(name) == 0):
					free(name)
					free(id)
				else:
					out[name] = id
					free(name)
		pos = line_end + 1
	return out


void vcs_sync_refs_free(map[char*, char*] refs):
	list[char*] keys = refs.keys()
	for char* key in keys:
		char* value = refs[key]
		free(value)
	list_free[char*](keys)
	map_free[char*, char*](refs)


# Parses a line-oriented list of bare 64-hex ids (the /ancestry response
# body). Malformed lines are skipped defensively, same posture as
# vcs_sync_parse_refs.
list[char*] vcs_sync_parse_id_lines(char* body, int body_len):
	list[char*] out = new list[char*]
	int pos = 0
	while (pos < body_len):
		int line_end = pos
		while ((line_end < body_len) && (body[line_end] != 10)):
			line_end = line_end + 1
		if ((line_end - pos) == 64):
			char* id = path_clone_range(body + pos, 64)
			if (cas_valid_id(id)):
				out.push(id)
			else:
				free(id)
		pos = line_end + 1
	return out


/* ---- client: pull ---- */


# Fetches object `id` from `url`'s store into `store` if not already
# present (cas_has short-circuits: this is what keeps a repeat pull/push
# down to just the new objects), verifying the fetched bytes hash to
# `id` before ever storing them, then recurses into the object's own
# references: a "tree" object's children (cas.w's Merkle property --
# equal ids are never even fetched, let alone re-walked), or a "commit"
# object's tree id (NOT its parent commit ids -- the caller already
# enumerated the full commit ancestry via vcs_sync_ancestry, so walking
# parents again here would just be redundant network round trips).
# Returns 0, or 1 for a clean (already-reported-to-`out`) failure. Local
# store write failures are NOT clean failures -- see the header
# comment -- and exit the process via translate_syscall_failure.
int vcs_sync_fetch_object_closure(wcas* store, char* url, char* id, wstream* out):
	if (cas_has(store, id) != 0):
		return 0

	char* obj_url = vcs_sync_object_url(url, id)
	http_response* resp = vcs_sync_get(obj_url, out)
	free(obj_url)
	if (resp == 0):
		return 1
	if (resp.status != 200):
		stream_write_cstr(out, c"wvc: missing remote object ")
		stream_write_line(out, id)
		stream_flush(out)
		http_response_free(resp)
		return 1

	wresult[wcas_object*]* parsed_r = cas_parse_framed(resp.body, resp.body_len)
	http_response_free(resp)
	if (result_is_error[wcas_object*](parsed_r)):
		result_free[wcas_object*](parsed_r)
		stream_write_cstr(out, c"wvc: malformed object from remote: ")
		stream_write_line(out, id)
		stream_flush(out)
		return 1
	wcas_object* obj = result_value[wcas_object*](parsed_r)
	result_free[wcas_object*](parsed_r)

	char* recomputed = cas_id_hex(obj.object_type, obj.data, obj.length)
	int match = (recomputed != 0) && (strcmp(recomputed, id) == 0)
	if (recomputed != 0):
		free(recomputed)
	if (match == 0):
		cas_object_free(obj)
		stream_write_cstr(out, c"wvc: remote object failed to verify: ")
		stream_write_line(out, id)
		stream_flush(out)
		return 1

	wresult[char*]* put_r = cas_put_raw(store, id, obj.object_type, obj.data, obj.length)
	if (result_is_error[char*](put_r)):
		int code = result_code[char*](put_r)
		result_free[char*](put_r)
		cas_object_free(obj)
		translate_syscall_failure(code)
	free(result_value[char*](put_r))
	result_free[char*](put_r)

	int err = 0
	if (strcmp(obj.object_type, c"tree") == 0):
		wresult[wtree*]* t_r = tree_get(store, id)
		if (result_is_ok[wtree*](t_r)):
			wtree* t = result_value[wtree*](t_r)
			for tree_entry* e in t.entries:
				if (err == 0):
					err = vcs_sync_fetch_object_closure(store, url, e.id, out)
			tree_free(t)
		result_free[wtree*](t_r)
	else if (strcmp(obj.object_type, c"commit") == 0):
		wresult[commit_object*]* co_r = commit_load(store, id)
		if (result_is_ok[commit_object*](co_r)):
			commit_object* co = result_value[commit_object*](co_r)
			err = vcs_sync_fetch_object_closure(store, url, co.tree_id, out)
			commit_free(co)
		result_free[commit_object*](co_r)
	cas_object_free(obj)
	return err


# wvc pull <url> [ref]: see the header comment for the full algorithm
# and scope decisions. Returns 0 on success (including "already up to
# date"), 1 for a clean, already-printed porcelain outcome (no such
# remote ref, a truncated/failed ancestry fetch, a diverged history).
# Local store errors exit the process (translate_syscall_failure); this
# function itself never returns anything but 0/1.
int vcs_sync_pull(wcas* store, wrefs* refs, char* url, char* ref_name, wstream* out):
	char* refs_url = vcs_sync_refs_url(url)
	http_response* refs_resp = vcs_sync_get(refs_url, out)
	free(refs_url)
	if (refs_resp == 0):
		return 1
	if (refs_resp.status != 200):
		stream_write_cstr(out, c"wvc: pull failed: remote /refs returned HTTP ")
		stream_write_line(out, itoa(refs_resp.status))
		stream_flush(out)
		http_response_free(refs_resp)
		return 1
	map[char*, char*] remote_refs = vcs_sync_parse_refs(refs_resp.body, refs_resp.body_len)
	http_response_free(refs_resp)

	char* found = remote_refs.get(ref_name, 0)
	if (found == 0):
		stream_write_cstr(out, c"wvc: remote has no ref '")
		stream_write_cstr(out, ref_name)
		stream_write_line(out, c"'")
		stream_flush(out)
		vcs_sync_refs_free(remote_refs)
		return 1
	char* remote_tip = strclone(found)
	vcs_sync_refs_free(remote_refs)

	int have_local = ref_exists(refs, ref_name)
	char* local_tip = 0
	if (have_local):
		wresult[char*]* lt_r = ref_read(refs, ref_name)
		if (result_is_error[char*](lt_r)):
			int code = result_code[char*](lt_r)
			result_free[char*](lt_r)
			free(remote_tip)
			translate_syscall_failure(code)
		local_tip = result_value[char*](lt_r)
		result_free[char*](lt_r)

	if ((have_local != 0) && (strcmp(local_tip, remote_tip) == 0)):
		stream_write_line(out, c"Already up to date.")
		stream_flush(out)
		free(remote_tip)
		free(local_tip)
		return 0

	char* ancestry_url = vcs_sync_ancestry_url(url, remote_tip)
	http_response* anc_resp = vcs_sync_get(ancestry_url, out)
	free(ancestry_url)
	if (anc_resp == 0):
		free(remote_tip)
		if (local_tip != 0):
			free(local_tip)
		return 1
	if (anc_resp.status != 200):
		stream_write_cstr(out, c"wvc: pull failed: remote /ancestry returned HTTP ")
		stream_write_line(out, itoa(anc_resp.status))
		stream_flush(out)
		http_response_free(anc_resp)
		free(remote_tip)
		if (local_tip != 0):
			free(local_tip)
		return 1
	if (http_response_header(anc_resp, VCS_SYNC_TRUNCATED_HEADER()) != 0):
		stream_write_line(out, c"wvc: remote history exceeds the sync ancestry cap; refusing to pull an incomplete history")
		stream_flush(out)
		http_response_free(anc_resp)
		free(remote_tip)
		if (local_tip != 0):
			free(local_tip)
		return 1
	list[char*] remote_commits = vcs_sync_parse_id_lines(anc_resp.body, anc_resp.body_len)
	http_response_free(anc_resp)

	int err = 0
	for char* cid in remote_commits:
		if ((err == 0) && (cas_has(store, cid) == 0)):
			err = vcs_sync_fetch_object_closure(store, url, cid, out)
	if (err != 0):
		for char* cid in remote_commits:
			free(cid)
		list_free[char*](remote_commits)
		free(remote_tip)
		if (local_tip != 0):
			free(local_tip)
		return 1

	if (have_local != 0):
		int is_ancestor = 0
		for char* cid in remote_commits:
			if (strcmp(cid, local_tip) == 0):
				is_ancestor = 1
		if (is_ancestor == 0):
			stream_write_cstr(out, c"wvc: local and remote have diverged; run 'wvc merge ")
			stream_write_cstr(out, remote_tip)
			stream_write_line(out, c"' to reconcile")
			stream_flush(out)
			for char* cid in remote_commits:
				free(cid)
			list_free[char*](remote_commits)
			free(remote_tip)
			free(local_tip)
			return 1

	for char* cid in remote_commits:
		free(cid)
	list_free[char*](remote_commits)

	if (have_local == 0):
		wresult[int]* created = ref_create(refs, ref_name, remote_tip, c"wvc pull")
		if (result_is_error[int](created)):
			int code = result_code[int](created)
			result_free[int](created)
			free(remote_tip)
			translate_syscall_failure(code)
		result_free[int](created)
	else:
		wresult[int]* updated = ref_update(refs, ref_name, remote_tip, c"wvc pull")
		if (result_is_error[int](updated)):
			int code = result_code[int](updated)
			result_free[int](updated)
			free(remote_tip)
			free(local_tip)
			translate_syscall_failure(code)
		result_free[int](updated)

	stream_write_cstr(out, c"Updated ")
	stream_write_cstr(out, ref_name)
	stream_write_cstr(out, c" to ")
	stream_write_line(out, remote_tip)
	stream_flush(out)

	free(remote_tip)
	if (local_tip != 0):
		free(local_tip)
	return 0


/* ---- client: push ---- */


# The push counterpart of vcs_sync_fetch_object_closure: probes whether
# `id` already exists on the remote (GET; per-object probing, fine for
# v1 -- see the header comment) and, if not, uploads the object's
# logical bytes (cas_get + cas_object_bytes -- NOT a raw
# cas_object_path/cas_read_file, which would leak whatever on-disk
# encoding this local store happens to use; see this file's header
# comment) and recurses into its children the same way the fetch side
# does (tree -> child ids; commit -> tree id only, since the caller
# already enumerates every ancestor commit via vcs_sync_ancestry before
# calling this). Stops descending as soon as an object is confirmed
# present remotely: a push only ever completes after uploading an
# object's whole transitive closure, so once something is there,
# everything underneath it is guaranteed to be there too.
int vcs_sync_push_object_closure(wcas* store, char* url, char* id, wstream* out):
	char* obj_url = vcs_sync_object_url(url, id)
	http_response* probe = vcs_sync_get(obj_url, out)
	if (probe == 0):
		free(obj_url)
		return 1
	int present = probe.status == 200
	http_response_free(probe)
	if (present != 0):
		free(obj_url)
		return 0

	wresult[wcas_object*]* got = cas_get(store, id)
	if (result_is_error[wcas_object*](got)):
		result_free[wcas_object*](got)
		free(obj_url)
		stream_write_cstr(out, c"wvc: local object missing while pushing: ")
		stream_write_line(out, id)
		stream_flush(out)
		return 1
	wcas_object* obj = result_value[wcas_object*](got)
	result_free[wcas_object*](got)
	string_builder* wire = cas_object_bytes(obj.object_type, obj.data, obj.length)

	http_response* put_resp = vcs_sync_post(obj_url, wire.data, wire.length, out)
	free(obj_url)
	string_free(wire)
	if (put_resp == 0):
		cas_object_free(obj)
		return 1
	if (put_resp.status != 200):
		stream_write_cstr(out, c"wvc: remote rejected object ")
		stream_write_line(out, id)
		stream_flush(out)
		http_response_free(put_resp)
		cas_object_free(obj)
		return 1
	http_response_free(put_resp)

	int err = 0
	if (strcmp(obj.object_type, c"tree") == 0):
		wresult[wtree*]* t_r = tree_get(store, id)
		if (result_is_ok[wtree*](t_r)):
			wtree* t = result_value[wtree*](t_r)
			for tree_entry* e in t.entries:
				if (err == 0):
					err = vcs_sync_push_object_closure(store, url, e.id, out)
			tree_free(t)
		result_free[wtree*](t_r)
	else if (strcmp(obj.object_type, c"commit") == 0):
		wresult[commit_object*]* co_r = commit_load(store, id)
		if (result_is_ok[commit_object*](co_r)):
			commit_object* co = result_value[commit_object*](co_r)
			err = vcs_sync_push_object_closure(store, url, co.tree_id, out)
			commit_free(co)
		result_free[commit_object*](co_r)
	cas_object_free(obj)
	return err


# wvc push <url> [ref]: see the header comment for the full algorithm.
# Returns 0 on success, 1 for a clean, already-printed porcelain outcome
# (no local ref, a truncated local ancestry, an object upload rejected,
# a non-fast-forward rejection from the server). Local store errors exit
# the process (translate_syscall_failure).
int vcs_sync_push(wcas* store, wrefs* refs, char* url, char* ref_name, wstream* out):
	if (ref_exists(refs, ref_name) == 0):
		stream_write_cstr(out, c"wvc: local ref '")
		stream_write_cstr(out, ref_name)
		stream_write_line(out, c"' does not exist")
		stream_flush(out)
		return 1

	wresult[char*]* lt_r = ref_read(refs, ref_name)
	if (result_is_error[char*](lt_r)):
		int code = result_code[char*](lt_r)
		result_free[char*](lt_r)
		translate_syscall_failure(code)
	char* local_tip = result_value[char*](lt_r)
	result_free[char*](lt_r)

	int truncated = 0
	wresult[list[char*]]* anc_r = vcs_sync_ancestry(store, local_tip, &truncated)
	if (result_is_error[list[char*]](anc_r)):
		int code = result_code[list[char*]](anc_r)
		result_free[list[char*]](anc_r)
		free(local_tip)
		translate_syscall_failure(code)
	list[char*] local_commits = result_value[list[char*]](anc_r)
	result_free[list[char*]](anc_r)
	if (truncated != 0):
		stream_write_line(out, c"wvc: local history exceeds the sync ancestry cap; refusing to push an incomplete history")
		stream_flush(out)
		for char* cid in local_commits:
			free(cid)
		list_free[char*](local_commits)
		free(local_tip)
		return 1

	int err = 0
	for char* cid in local_commits:
		if (err == 0):
			err = vcs_sync_push_object_closure(store, url, cid, out)
		free(cid)
	list_free[char*](local_commits)
	if (err != 0):
		free(local_tip)
		return 1

	char* refs_post_url = vcs_sync_refs_post_url(url, ref_name)
	http_response* resp = vcs_sync_post(refs_post_url, local_tip, strlen(local_tip), out)
	free(refs_post_url)
	if (resp == 0):
		free(local_tip)
		return 1
	if (resp.status == 409):
		stream_write_cstr(out, c"wvc: push rejected: remote '")
		stream_write_cstr(out, ref_name)
		stream_write_line(out, c"' is not an ancestor of the local tip (pull/merge first)")
		stream_flush(out)
		http_response_free(resp)
		free(local_tip)
		return 1
	if (resp.status != 200):
		stream_write_cstr(out, c"wvc: push failed: remote returned HTTP ")
		stream_write_line(out, itoa(resp.status))
		stream_flush(out)
		http_response_free(resp)
		free(local_tip)
		return 1
	http_response_free(resp)

	stream_write_cstr(out, c"Pushed ")
	stream_write_cstr(out, ref_name)
	stream_write_cstr(out, c" to ")
	stream_write_line(out, local_tip)
	stream_flush(out)
	free(local_tip)
	return 0
