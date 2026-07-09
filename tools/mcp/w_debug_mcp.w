# Stdio MCP server exposing wdbg as a real interactive debugging session:
# debug_start spawns './bin/wdbg <file> [args...] [--break_start]' with
# piped stdio and returns a session_id; debug_send writes one command and
# reads the response up to the next 'wdbg> ' prompt (or EOF/timeout);
# debug_stop tears the session down. Unlike w-toolchain-mcp/w-index-mcp
# (one-shot subprocess per call), the wdbg session survives across
# multiple tool calls in this server's own process, so an agent can see
# each response before deciding the next command -- the "programmatic
# stepping" ai_tooling.md named as the reason w-debug-mcp stayed deferred.
# See docs/projects/debug_mcp.md. Protocol plumbing lives in
# tools/mcp/mcp_server.w, shared with w-toolchain-mcp and w-index-mcp.
#
# Build and register (see .cursor/mcp.json):
#   ./wbuild wdmcp && ./bin/wdmcp
import lib.lib
import lib.args
import lib.process
import lib.poll
import structures.json
import tools.mcp.mcp_server


int dmcp_default_timeout_ms():
	return 15000


int dmcp_ensure_wdbg():
	return mcp_ensure_built(c"bin/wdbg", c"wdbg", 180000)


/* session registry */


map[char*, process*] dmcp_sessions
int dmcp_next_session_id


char* dmcp_new_session_id():
	dmcp_next_session_id = dmcp_next_session_id + 1
	char* digits = itoa(dmcp_next_session_id)
	char* id = strjoin(c"session-", digits)
	free(digits)
	return id


process* dmcp_lookup_session(char* id):
	if (id == 0):
		return 0
	if (id in dmcp_sessions):
		return dmcp_sessions[id]
	return 0


void dmcp_drop_session(char* id):
	if (id in dmcp_sessions):
		dmcp_sessions[id] = 0


/* reading a session's output up to the next prompt */


# wdbg's command-loop prompt (debugger/wdbg.w's wdbg_command_loop).
char* dmcp_prompt():
	return c"wdbg> "


# Reads from stdout and stderr (merged, in whichever order each becomes
# ready) until the accumulated text ends with the wdbg prompt, both
# streams hit EOF, or timeout_ms elapses. Sets *prompt_seen accordingly;
# always returns a malloc'd string (possibly empty).
char* dmcp_read_until_prompt(process* p, int timeout_ms, int* prompt_seen):
	*prompt_seen = 0
	process_capture buffer
	process_capture_init(&buffer)
	int deadline = process_monotonic_ms() + timeout_ms
	int stdout_open = p.stdout_fd >= 0
	int stderr_open = p.stderr_fd >= 0
	while (stdout_open | stderr_open):
		int wait_ms = deadline - process_monotonic_ms()
		if (wait_ms <= 0):
			break
		pollfd* fds = pollfd_new_array(2)
		int stdout_slot = -1
		int stderr_slot = -1
		int nfds = 0
		if (stdout_open):
			stdout_slot = nfds
			pollfd_set(fds, nfds, p.stdout_fd, poll_in())
			nfds = nfds + 1
		if (stderr_open):
			stderr_slot = nfds
			pollfd_set(fds, nfds, p.stderr_fd, poll_in())
			nfds = nfds + 1
		int ready = poll_wait(fds, nfds, wait_ms)
		if (ready > 0):
			if (stdout_slot >= 0):
				if ((pollfd_at(fds, stdout_slot).revents & (poll_in() | poll_hup())) != 0):
					int stdout_count = process_capture_read(&buffer, p.stdout_fd)
					if (stdout_count <= 0):
						stdout_open = 0
			if (stderr_slot >= 0):
				if ((pollfd_at(fds, stderr_slot).revents & (poll_in() | poll_hup())) != 0):
					int stderr_count = process_capture_read(&buffer, p.stderr_fd)
					if (stderr_count <= 0):
						stderr_open = 0
		free(cast(void*, fds))
		if (ends_with(process_capture_take(&buffer), dmcp_prompt())):
			*prompt_seen = 1
			break
	return process_capture_take(&buffer)


/* tool handlers */


json_value* dmcp_tool_debug_start(json_value* args):
	if (dmcp_ensure_wdbg() == 0):
		return 0
	char* file = mcp_arg_string(args, c"file")
	if (file == 0):
		mcp_fail(c"file is required")
		return 0
	json_value* extra_args = mcp_arg_array(args, c"args")
	int break_start = mcp_arg_bool(args, c"break_start", 1)

	list[char*] words = new list[char*]
	words.push(c"./bin/wdbg")
	words.push(file)
	if (extra_args != 0):
		int i = 0
		while (i < json_array_length(extra_args)):
			json_value* extra = json_array_get(extra_args, i)
			if (extra.type != json_type_string()):
				mcp_fail(c"args entries must be strings")
				return 0
			words.push(extra.string_value)
			i = i + 1
	if (break_start):
		words.push(c"--break_start")

	char** argv = strv_new(words.length)
	int i = 0
	while (i < words.length):
		strv_set(argv, i, words[i])
		i = i + 1
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	opts.stdout_mode = process_pipe()
	opts.stderr_mode = process_pipe()
	process* p = process_spawn(c"./bin/wdbg", argv, opts)
	free(opts)
	free(cast(void*, argv))
	if (p == 0):
		mcp_fail(c"failed to spawn bin/wdbg")
		return 0

	int prompt_seen = 0
	char* output = dmcp_read_until_prompt(p, dmcp_default_timeout_ms(), &prompt_seen)

	char* session_id = dmcp_new_session_id()
	dmcp_sessions[session_id] = p

	json_value* result = json_object()
	json_object_set(result, c"session_id", json_string(session_id))
	json_object_set(result, c"output", json_string_take(output))
	json_object_set(result, c"prompt_seen", json_bool(prompt_seen))
	return result


json_value* dmcp_tool_debug_send(json_value* args):
	char* session_id = mcp_arg_string(args, c"session_id")
	if (session_id == 0):
		mcp_fail(c"session_id is required")
		return 0
	char* command = mcp_arg_string(args, c"command")
	if (command == 0):
		mcp_fail(c"command is required")
		return 0
	process* p = dmcp_lookup_session(session_id)
	if (p == 0):
		mcp_fail(c"unknown or already-stopped session_id")
		return 0
	if (p.stdin_fd < 0):
		mcp_fail(c"session has already exited; call debug_stop and debug_start a new one")
		return 0

	char* line = strjoin(command, c"\x0a")
	int wrote = write(p.stdin_fd, line, strlen(line))
	free(line)
	if (wrote < 0):
		dmcp_drop_session(session_id)
		mcp_fail(c"session's stdin is closed (the debuggee likely exited)")
		return 0

	int prompt_seen = 0
	char* output = dmcp_read_until_prompt(p, dmcp_default_timeout_ms(), &prompt_seen)

	int exited = (p.stdout_fd < 0) | ((prompt_seen == 0) & (dmcp_lookup_session(session_id) != 0))
	json_value* result = json_object()
	json_object_set(result, c"output", json_string_take(output))
	json_object_set(result, c"prompt_seen", json_bool(prompt_seen))
	if (prompt_seen == 0):
		# Both streams hit EOF (rather than a real timeout): the debuggee
		# process has ended. Reap it so the exit status is available and
		# mark the session gone -- debug_send on it again would just hang
		# writing to a closed pipe otherwise.
		int status = process_try_wait(p)
		if (status != process_status_running()):
			json_object_set(result, c"exit_code", json_int(status))
			dmcp_drop_session(session_id)
	return result


json_value* dmcp_tool_debug_stop(json_value* args):
	char* session_id = mcp_arg_string(args, c"session_id")
	if (session_id == 0):
		mcp_fail(c"session_id is required")
		return 0
	process* p = dmcp_lookup_session(session_id)
	if (p == 0):
		mcp_fail(c"unknown or already-stopped session_id")
		return 0
	int status = process_wait_or_kill(p, 5000)
	process_free(p)
	dmcp_drop_session(session_id)
	json_value* result = json_object()
	json_object_set(result, c"exit_code", json_int(status))
	return result


json_value* dmcp_call_tool(char* name, json_value* args):
	if (strcmp(name, c"debug_start") == 0):
		return dmcp_tool_debug_start(args)
	if (strcmp(name, c"debug_send") == 0):
		return dmcp_tool_debug_send(args)
	if (strcmp(name, c"debug_stop") == 0):
		return dmcp_tool_debug_stop(args)
	return 0


int dmcp_tool_known(char* name):
	if (strcmp(name, c"debug_start") == 0):
		return 1
	if (strcmp(name, c"debug_send") == 0):
		return 1
	if (strcmp(name, c"debug_stop") == 0):
		return 1
	return 0


/* tools/list schemas */


json_value* dmcp_tool_schemas():
	json_value* tools = json_array()

	json_value* start_properties = json_object()
	json_object_set(start_properties, c"file", mcp_string_property())
	json_object_set(start_properties, c"args", mcp_string_array_property())
	json_object_set(start_properties, c"break_start", mcp_bool_property())
	char* start_desc = c"Start a wdbg session on file (default --break_start: true, so the debuggee is paused before it runs). Returns a session_id and the output up to the first prompt."
	json_array_push(tools, mcp_tool_schema(c"debug_start", start_desc, start_properties))

	json_value* send_properties = json_object()
	json_object_set(send_properties, c"session_id", mcp_string_property())
	json_object_set(send_properties, c"command", mcp_string_property())
	char* send_desc = c"Send one wdbg command (break, condition, log, print, step, continue, ...) to a session and return the output up to the next prompt."
	json_array_push(tools, mcp_tool_schema(c"debug_send", send_desc, send_properties))

	json_value* stop_properties = json_object()
	json_object_set(stop_properties, c"session_id", mcp_string_property())
	char* stop_desc = c"Kill and clean up a wdbg session."
	json_array_push(tools, mcp_tool_schema(c"debug_stop", stop_desc, stop_properties))

	return tools


int main(int argc, int argv):
	args_init(argc, argv)
	mcp_chdir_root()
	dmcp_sessions = new map[char*, process*]
	dmcp_next_session_id = 0
	mcp_server_init(c"w-debug", c"0.1.0", dmcp_tool_known, dmcp_call_tool, dmcp_tool_schemas)
	return mcp_serve()
