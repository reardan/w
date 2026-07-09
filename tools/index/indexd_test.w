# End-to-end test for the index daemon (docs/projects/index_daemon.md):
# spawns a real bin/windexd, talks JSON-RPC to it directly (not through
# the CLI, so failures point at the daemon rather than the CLI's
# fallback logic), and asserts both plain query correctness and the
# cache-invalidation contract — a query against a file whose content
# changed between two calls must reflect the new content, not a stale
# cached windex_index.
import lib.lib
import lib.assert
import lib.file
import lib.process
import lib.net
import lib.framing
import lib.json_rpc
import structures.string
import structures.json
import tools.index.w_index_core


int indexd_test_timeout_ms():
	return 5000


char* indexd_test_scratch_file():
	return c"bin/indexd_test_fixture.w"


/* connection setup */


int indexd_test_port_reachable(int port):
	if (port <= 0):
		return 0
	int sock = socket_tcp_ipv4()
	if (sock < 0):
		return 0
	int reachable = socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) >= 0
	close(sock)
	return reachable


void indexd_test_wait_port_closed(int port):
	int waited = 0
	while (waited < indexd_test_timeout_ms()):
		if (indexd_test_port_reachable(port) == 0):
			return
		process_sleep_ms(20)
		waited = waited + 20


# If a previous run (or an unrelated dev session) left a daemon
# advertised at bin/.windexd.port, ask it to shut down so this test
# starts from a clean slate instead of racing windexd_already_running().
void indexd_test_shutdown_stale():
	int port = windexd_read_port()
	if (port <= 0):
		return
	int sock = socket_tcp_ipv4()
	if (sock < 0):
		return
	int connected = 0
	if (socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) >= 0):
		connected = 1
		jsonrpc_write_request(sock, 1, c"shutdown", 0)
		frame_reader* r = frame_reader_new(sock)
		json_value* response = jsonrpc_read_message(r)
		json_free(response)
		frame_reader_free(r)
	close(sock)
	if (connected):
		indexd_test_wait_port_closed(port)


process* indexd_test_spawn(int* port_out):
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null()
	opts.stdout_mode = process_null()
	opts.stderr_mode = process_null()
	char** argv = strv_new(1)
	strv_set(argv, 0, c"./bin/windexd")
	process* p = process_spawn(c"./bin/windexd", argv, opts)
	free(cast(void*, argv))
	asserts(c"windexd spawned", p != 0)

	int waited = 0
	while (waited < indexd_test_timeout_ms()):
		int port = windexd_read_port()
		if (port > 0):
			int sock = socket_tcp_ipv4()
			if (sock >= 0):
				if (socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) >= 0):
					asserts(c"spawned windexd still owns reachable port", process_try_wait(p) == process_status_running())
					close(sock)
					*port_out = port
					return p
				close(sock)
		process_sleep_ms(20)
		waited = waited + 20
	asserts(c"windexd never became reachable", 0)
	*port_out = -1
	return p


void indexd_test_shutdown(process* p, int sock, frame_reader* r):
	jsonrpc_write_request(sock, 99, c"shutdown", 0)
	jsonrpc_read_message(r)
	frame_reader_free(r)
	close(sock)
	assert_equal(0, process_wait_or_kill(p, indexd_test_timeout_ms()))
	process_free(p)


/* RPC helpers */


list[json_value*] indexd_test_query(int sock, frame_reader* r, char* subcommand, char* name, list[char*] files):
	json_value* params = json_object()
	json_object_set(params, c"subcommand", json_string(strclone(subcommand)))
	json_object_set(params, c"name", json_string(strclone(name)))
	json_value* files_array = json_array()
	for char* f in files:
		json_array_push(files_array, json_string(strclone(f)))
	json_object_set(params, c"files", files_array)
	asserts(c"windex_query request sent", jsonrpc_write_request(sock, 1, c"windex_query", params) > 0)

	json_value* response = jsonrpc_read_message(r)
	asserts(c"daemon responded", response != 0)
	json_value* error = json_object_get(response, c"error")
	asserts(c"windex_query returned no error", error == 0)
	json_value* result = json_object_get(response, c"result")
	asserts(c"windex_query returned a result", result != 0)
	json_value* stdout_value = json_object_get(result, c"stdout")
	asserts(c"result carries stdout", stdout_value != 0)
	list[json_value*] records = windex_parse_ndjson(stdout_value.string_value)
	json_free(response)
	return records


int indexd_test_has_name(list[json_value*] records, char* key, char* name):
	for json_value* record in records:
		if (strcmp(windex_string_member(record, key), name) == 0):
			return 1
	return 0


list[char*] indexd_test_files(char* f):
	list[char*] files = new list[char*]
	files.push(f)
	return files


/* scenarios */


void test_indexd_query_matches_direct_build():
	int port = 0
	process* p = indexd_test_spawn(&port)
	int sock = socket_tcp_ipv4()
	asserts(c"client socket", sock >= 0)
	asserts(c"client connect", socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) >= 0)
	frame_reader* r = frame_reader_new(sock)

	list[char*] files = indexd_test_files(c"tests/index_fixture.w")
	list[json_value*] symbol_records = indexd_test_query(sock, r, c"symbol", c"index_fixture_helper", files)
	asserts(c"find_symbol finds index_fixture_helper", symbol_records.length >= 1)

	list[json_value*] caller_records = indexd_test_query(sock, r, c"callers", c"index_fixture_helper", files)
	asserts(c"callers finds at least one call site", caller_records.length >= 1)
	asserts(c"index_fixture_caller calls index_fixture_helper", indexd_test_has_name(caller_records, c"caller", c"index_fixture_caller"))

	indexd_test_shutdown(p, sock, r)


void test_indexd_cache_invalidates_on_file_change():
	int port = 0
	process* p = indexd_test_spawn(&port)
	int sock = socket_tcp_ipv4()
	asserts(c"client socket", sock >= 0)
	asserts(c"client connect", socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) >= 0)
	frame_reader* r = frame_reader_new(sock)

	list[char*] files = indexd_test_files(indexd_test_scratch_file())

	asserts(c"scratch fixture v1 written", file_write_text(indexd_test_scratch_file(), c"import lib.lib\n\nint indexd_test_marker_a():\n\treturn 1\n"))
	list[json_value*] a_first = indexd_test_query(sock, r, c"symbol", c"indexd_test_marker_a", files)
	asserts(c"marker_a found before rename", a_first.length == 1)
	list[json_value*] b_first = indexd_test_query(sock, r, c"symbol", c"indexd_test_marker_b", files)
	asserts(c"marker_b absent before rename", b_first.length == 0)

	# Same entry file, unchanged content: must still find marker_a (cache
	# hit path returns the same answer, not an empty/stale miss).
	list[json_value*] a_repeat = indexd_test_query(sock, r, c"symbol", c"indexd_test_marker_a", files)
	asserts(c"marker_a still found on repeat query", a_repeat.length == 1)

	asserts(c"scratch fixture v2 written", file_write_text(indexd_test_scratch_file(), c"import lib.lib\n\nint indexd_test_marker_b():\n\treturn 2\n"))
	list[json_value*] a_after = indexd_test_query(sock, r, c"symbol", c"indexd_test_marker_a", files)
	asserts(c"marker_a gone after rewrite (cache invalidated)", a_after.length == 0)
	list[json_value*] b_after = indexd_test_query(sock, r, c"symbol", c"indexd_test_marker_b", files)
	asserts(c"marker_b found after rewrite", b_after.length == 1)

	indexd_test_shutdown(p, sock, r)


# test_indexd_cache_invalidates_on_file_change only ever queries
# 'symbol' (declaration lookup, windex_index.by_name — never touches
# the per-file scan cache). This scenario uses 'references', which
# does go through windex_file_identifiers, to prove that cache's
# content-hash invalidation independently: a second call site added to
# an unchanged-looking query (same target name, same entry file) must
# show up, not be served from a stale cached scan.
void test_indexd_scan_cache_reflects_file_changes():
	int port = 0
	process* p = indexd_test_spawn(&port)
	int sock = socket_tcp_ipv4()
	asserts(c"client socket", sock >= 0)
	asserts(c"client connect", socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) >= 0)
	frame_reader* r = frame_reader_new(sock)

	list[char*] files = indexd_test_files(indexd_test_scratch_file())

	char* v1 = c"import lib.lib\n\nint indexd_scan_target():\n\treturn 1\n\nint indexd_scan_caller_a():\n\treturn indexd_scan_target()\n"
	asserts(c"scan scratch fixture v1 written", file_write_text(indexd_test_scratch_file(), v1))
	list[json_value*] refs_first = indexd_test_query(sock, r, c"references", c"indexd_scan_target", files)
	asserts(c"one declaration plus one call site before edit", refs_first.length == 2)

	# Unchanged content: repeat query must return the same count (scan
	# cache hit, not an empty/stale miss).
	list[json_value*] refs_repeat = indexd_test_query(sock, r, c"references", c"indexd_scan_target", files)
	asserts(c"same reference count on repeat query", refs_repeat.length == 2)

	char* v2 = c"import lib.lib\n\nint indexd_scan_target():\n\treturn 1\n\nint indexd_scan_caller_a():\n\treturn indexd_scan_target()\n\nint indexd_scan_caller_b():\n\treturn indexd_scan_target()\n"
	asserts(c"scan scratch fixture v2 written", file_write_text(indexd_test_scratch_file(), v2))
	list[json_value*] refs_after = indexd_test_query(sock, r, c"references", c"indexd_scan_target", files)
	asserts(c"new call site visible after edit (scan cache invalidated)", refs_after.length == 3)

	indexd_test_shutdown(p, sock, r)


int main():
	indexd_test_shutdown_stale()
	test_indexd_query_matches_direct_build()
	test_indexd_cache_invalidates_on_file_change()
	test_indexd_scan_cache_reflects_file_changes()
	return 0
