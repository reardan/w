# CLI entry point for the semantic index (see w_index_core.w for the
# query engine and docs/projects/semantic_index.md for the overall
# contract). Every invocation first tries a warm bin/windexd daemon
# (docs/projects/index_daemon.md) over its discovery file at
# bin/.windexd.port; on any failure to reach it (no daemon, stale port,
# refused connection) it falls back to today's behavior — build the
# index in-process via a fresh 'wv2 symbols --json' compile — and,
# before falling back, fires off a detached bin/windexd so later calls
# in this repo checkout get a warm daemon. This keeps the CLI usable
# with zero setup while making repeated queries fast once a daemon has
# had a chance to start.
#
# Build and run:
#   make windex && ./bin/windex symbol sym_fixture_add tests/symbols_fixture.w
import lib.lib
import lib.args
import lib.path
import lib.file
import lib.process
import lib.net
import lib.framing
import lib.json_rpc
import structures.string
import structures.json
import tools.index.w_index_core


char* windexd_spawn_lock_file():
	return c"bin/.windexd.spawn.lock"


# The lock file holds the pid of the last windexd this CLI spawned.
# There is no unlink() available in this codebase's syscall surface, so
# rather than an exclusive-create lock we track liveness with
# kill(pid, 0): once that daemon has exited the file is naturally
# treated as stale (no cleanup needed) and the next caller is free to
# spawn again. This does not close every spawn race (two callers can
# still both pass the check within the same instant) but it turns "every
# fallback query spawns another daemon" into "at most one live daemon
# per spawn attempt that wins the race", which is what actually mattered
# in practice — see docs/projects/index_daemon.md's known limitations.
int windexd_spawn_lock_holder_alive():
	char* text = file_read_text(windexd_spawn_lock_file())
	if (text == 0):
		return 0
	int pid = atoi(text)
	free(text)
	if (pid <= 0):
		return 0
	return kill(pid, 0) >= 0


# Spawns 'bin/windexd' detached (stdio to /dev/null, not waited on) so a
# daemon is warm for the *next* call. Best-effort: failure here just
# means the CLI keeps working the slow way, same as if this were never
# called.
void windexd_spawn_detached():
	if (path_exists(c"bin/windexd") == 0):
		return
	if (windexd_spawn_lock_holder_alive()):
		return
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null()
	opts.stdout_mode = process_null()
	opts.stderr_mode = process_null()
	char** argv = strv_new(1)
	strv_set(argv, 0, c"./bin/windexd")
	process* p = process_spawn(c"./bin/windexd", argv, opts)
	free(cast(void*, argv))
	if (p != 0):
		string_builder* s = string_new()
		string_append_int(s, p.pid)
		file_write_text(windexd_spawn_lock_file(), s.data)
		string_free(s)


json_value* windexd_files_array(list[char*] files):
	json_value* array = json_array()
	for char* file in files:
		json_array_push(array, json_string(strclone(file)))
	return array


# Tries a single request against a warm daemon. Returns the NDJSON
# 'stdout' string on success (caller owns it), or 0 on any failure
# (no port file, connection refused, malformed response) — every failure
# path is treated identically by the caller: fall back to a local build.
# A plain blocking connect is fine here: loopback connect to a closed or
# dead port fails (ECONNREFUSED) essentially instantly, it does not hang.
char* windexd_try_query(char* subcommand, char* name, list[char*] files):
	int port = windexd_read_port()
	if (port < 0):
		return 0
	int sock = socket_tcp_ipv4()
	if (sock < 0):
		return 0
	if (socket_connect_ipv4(sock, ip4_from_string(c"127.0.0.1"), port) < 0):
		close(sock)
		return 0

	json_value* params = json_object()
	json_object_set(params, c"subcommand", json_string(strclone(subcommand)))
	json_object_set(params, c"name", json_string(strclone(name)))
	json_object_set(params, c"files", windexd_files_array(files))
	if (jsonrpc_write_request(sock, 1, c"windex_query", params) <= 0):
		close(sock)
		return 0

	frame_reader* r = frame_reader_new(sock)
	json_value* response = jsonrpc_read_message(r)
	frame_reader_free(r)
	close(sock)
	if (response == 0):
		return 0
	json_value* error = json_object_get(response, c"error")
	if (error != 0):
		json_free(response)
		return 0
	json_value* result = json_object_get(response, c"result")
	char* out = 0
	if (result != 0):
		json_value* stdout_value = json_object_get(result, c"stdout")
		if (stdout_value != 0):
			if (stdout_value.type == json_type_string()):
				out = strclone(stdout_value.string_value)
	json_free(response)
	return out


# name is 0 for the stateless 'imports' subcommand.
void windex_run(char* subcommand, char* name, list[char*] entry_files):
	char* daemon_output = 0
	if (strcmp(subcommand, c"imports") != 0):
		daemon_output = windexd_try_query(subcommand, name, entry_files)
	if (daemon_output != 0):
		write(1, daemon_output, strlen(daemon_output))
		free(daemon_output)
		return

	windexd_spawn_detached()

	string_builder* out = string_new()
	if (strcmp(subcommand, c"imports") == 0):
		windex_cmd_imports(entry_files[0], out)
	else:
		windex_index* idx = windex_build(entry_files)
		if (idx != 0):
			windex_dispatch(idx, subcommand, name, out)
	write(1, out.data, out.length)
	string_free(out)


/* lifecycle and dispatch */


int windex_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: windex symbol|references|type|struct|callers|callees <name> <file...>")
	stream_write_line(err, c"       windex imports <file>")
	stream_flush(err)
	return 1


# The binary lives in bin/, so when launched by a path ending in bin/ hop
# to the parent (the repo root) so ./bin/wv2 (and bin/windexd, bin/.windexd.port) resolve.
void windex_chdir_root():
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


int main(int argc, int argv):
	args_init(argc, argv)
	windex_chdir_root()
	if (argc < 2):
		return windex_usage()
	char** command_ptr = argv + __word_size__
	char* command = *command_ptr
	if (strcmp(command, c"imports") == 0):
		if (argc < 3):
			return windex_usage()
		char** file_ptr = argv + 2 * __word_size__
		list[char*] files = new list[char*]
		files.push(*file_ptr)
		windex_run(c"imports", 0, files)
		return 0
	if (argc < 4):
		return windex_usage()
	char** name_ptr = argv + 2 * __word_size__
	char* name = *name_ptr
	list[char*] entry_files = new list[char*]
	int i = 3
	while (i < argc):
		char** arg_ptr = argv + i * __word_size__
		entry_files.push(*arg_ptr)
		i = i + 1
	if ((strcmp(command, c"symbol") == 0) | (strcmp(command, c"references") == 0) | (strcmp(command, c"type") == 0) | (strcmp(command, c"struct") == 0) | (strcmp(command, c"callers") == 0) | (strcmp(command, c"callees") == 0)):
		windex_run(command, name, entry_files)
	else:
		return windex_usage()
	return 0
