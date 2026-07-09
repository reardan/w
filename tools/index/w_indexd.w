# Persistent semantic-index daemon: keeps windex_index results warm in
# memory across queries instead of re-running 'wv2 symbols --json' (the
# dominant cost of every windex/w-index-mcp query, see
# docs/projects/index_daemon.md) on every single call.
#
# Protocol: JSON-RPC 2.0 (lib.json_rpc) over a TCP socket bound to
# 127.0.0.1 on an OS-assigned ephemeral port, advertised to clients via
# the bin/.windexd.port discovery file (windexd_port_file() in
# w_index_core.w). One method, 'windex_query', taking
# {subcommand, name, files} — the same shape as a 'windex <subcommand>
# <name> <file...>' CLI call — and returning {"stdout": "<ndjson>"}.
#
# Cache: keyed by the requested entry files (sorted, joined), one
# windex_index per key, unbounded (no eviction — see the design doc's
# known limitations). Freshness is checked on every request by rehashing
# every file in the cached transitive closure (windex_index.files); any
# mismatch rebuilds that one cache entry from scratch. This is the same
# content-hash approach tools/wexec.w uses for its build cache, just
# applied to source files instead of target definitions.
#
# Run directly: ./wbuild windexd && ./bin/windexd
# Normally auto-started by the windex CLI the first time it cannot reach
# a daemon (see windexd_spawn_detached() in w_index.w).
import lib.lib
import lib.args
import lib.path
import lib.file
import lib.process
import lib.net
import lib.poll
import lib.framing
import lib.json_rpc
import lib.event_loop
import structures.string
import structures.json
import structures.hash_map
import structures.array_list
import tools.index.w_index_core


/* cache */


struct windexd_cache_entry:
	windex_index* idx


map[char*, windexd_cache_entry*] windexd_cache
map[char*, char*] windexd_file_hashes


char* windexd_cache_key(list[char*] entry_files):
	list[char*] sorted_files = new list[char*]
	for char* f in entry_files:
		sorted_files.push(f)
	sorted_files.sort()
	string_builder* s = string_new()
	int first = 1
	for char* f in sorted_files:
		if (first == 0):
			string_append_char(s, 31)
		string_append(s, f)
		first = 0
	char* key = strclone(s.data)
	string_free(s)
	return key


# file_hashes is a flat map[char*, char*] shared across every cache
# entry (files often show up in more than one entry's transitive
# closure), keyed by "<cache key>\x1e<file>" so entries never see each
# other's stamps.
char* windexd_hash_key(char* cache_key, char* file):
	string_builder* s = string_new()
	string_append(s, cache_key)
	string_append_char(s, 30)
	string_append(s, file)
	char* result = strclone(s.data)
	string_free(s)
	return result


int windexd_cache_fresh(char* cache_key, windexd_cache_entry* entry):
	for char* file in entry.idx.files:
		char* hkey = windexd_hash_key(cache_key, file)
		char* current = windex_hash_file(file)
		int same = 0
		if (hkey in windexd_file_hashes):
			same = strcmp(windexd_file_hashes[hkey], current) == 0
		free(hkey)
		free(current)
		if (same == 0):
			return 0
	return 1


void windexd_stamp_entry(char* cache_key, windexd_cache_entry* entry):
	for char* file in entry.idx.files:
		char* hkey = windexd_hash_key(cache_key, file)
		windexd_file_hashes[hkey] = windex_hash_file(file)
		free(hkey)


# Returns 0 (with nothing printed by callers) when the underlying
# 'wv2 symbols --json' compile fails — same contract as windex_build.
windexd_cache_entry* windexd_get_entry(list[char*] entry_files):
	char* cache_key = windexd_cache_key(entry_files)
	if (cache_key in windexd_cache):
		windexd_cache_entry* cached = windexd_cache[cache_key]
		if (windexd_cache_fresh(cache_key, cached)):
			free(cache_key)
			return cached
	windex_index* idx = windex_build(entry_files)
	if (idx == 0):
		free(cache_key)
		return 0
	windexd_cache_entry* entry = new windexd_cache_entry()
	entry.idx = idx
	windexd_cache[cache_key] = entry
	windexd_stamp_entry(cache_key, entry)
	free(cache_key)
	return entry


/* RPC handlers */


json_value* windexd_handle_query(json_value* params, void* context):
	char* subcommand = windex_string_member(params, c"subcommand")
	char* name = windex_string_member(params, c"name")
	json_value* files_json = windex_member(params, c"files")
	if ((subcommand == 0) | (name == 0) | (files_json == 0)):
		return 0
	if (files_json.type != json_type_array()):
		return 0
	list[char*] entry_files = new list[char*]
	int i = 0
	while (i < json_array_length(files_json)):
		json_value* f = json_array_get(files_json, i)
		if (f.type == json_type_string()):
			entry_files.push(f.string_value)
		i = i + 1
	if (entry_files.length == 0):
		return 0

	string_builder* out = string_new()
	windexd_cache_entry* entry = windexd_get_entry(entry_files)
	if (entry != 0):
		windex_dispatch(entry.idx, subcommand, name, out)

	json_value* result = json_object()
	json_object_set(result, c"stdout", json_string(strclone(out.data)))
	string_free(out)
	return result


json_value* windexd_handle_shutdown(json_value* params, void* context):
	jsonrpc_stop(cast(jsonrpc_server*, context))
	return json_bool(1)


/* lifecycle */


void windexd_chdir_root():
	char* program = args_program()
	if (program == 0):
		return
	char* dir = path_dirname(program)
	char* base = path_basename(dir)
	if (strcmp(base, c"bin") == 0):
		char* root = path_join(dir, c"..")
		chdir(root)
		free(root)
	free(dir)
	free(base)


# 1 when a daemon already answers on the port file's port (so this
# process should not also bind and overwrite it), 0 otherwise (no port
# file, or nothing answering — a stale file from a daemon that died).
int windexd_already_running():
	int port = windexd_read_port()
	if (port < 0):
		return 0
	int sock = socket_tcp_ipv4()
	if (sock < 0):
		return 0
	int connected = socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) >= 0
	close(sock)
	return connected


int main(int argc, int argv):
	args_init(argc, argv)
	windexd_chdir_root()
	if (windexd_already_running()):
		return 0

	windexd_cache = new map[char*, windexd_cache_entry*]
	windexd_file_hashes = new map[char*, char*]

	int listen_fd = socket_tcp_ipv4()
	if (listen_fd < 0):
		return 1
	socket_set_reuseaddr(listen_fd)
	if (socket_bind_ipv4(listen_fd, ip4_from_string(c"127.0.0.1"), 0) < 0):
		return 1
	if (socket_listen(listen_fd, 16) < 0):
		return 1
	sockaddr_in bound_addr
	socket_getsockname_ipv4(listen_fd, &bound_addr)
	int port = net_htons(bound_addr.port)
	windexd_write_port(port)

	jsonrpc_server* server = jsonrpc_server_new()
	jsonrpc_register(server, c"windex_query", windexd_handle_query)
	jsonrpc_register(server, c"shutdown", windexd_handle_shutdown)
	server.context = cast(void*, server)

	event_loop* loop = event_loop_new()
	jsonrpc_serve_listener(server, loop, listen_fd)
	event_loop_run(loop)

	event_loop_free(loop)
	jsonrpc_server_free(server)
	return 0
