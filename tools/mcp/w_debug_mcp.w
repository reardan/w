# Stdio MCP server exposing wdbg as a real interactive debugging session:
# debug_start spawns './bin/wdbg <file> [args...] [--break_start]' with
# piped stdio and returns a session_id; debug_send writes one command and
# reads the response up to the next 'wdbg> ' prompt (or EOF/timeout);
# debug_stop tears the session down. Unlike w-toolchain-mcp/w-index-mcp
# (one-shot subprocess per call), the wdbg session survives across
# multiple tool calls in this server's own process, so an agent can see
# each response before deciding the next command -- the "programmatic
# stepping" ai_tooling.md named as the reason w-debug-mcp stayed deferred.
# See docs/projects/debug_mcp.md.
#
# Build and register (see .cursor/mcp.json):
#   make wdmcp && ./bin/wdmcp
import lib.lib
import lib.args
import lib.path
import lib.framing
import lib.process
import lib.poll
import structures.string
import structures.json


int dmcp_max_output():
	return 64000


int dmcp_default_timeout_ms():
	return 15000


char* dmcp_error


void dmcp_fail(char* message):
	free(dmcp_error)
	dmcp_error = strclone(message)


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


/* subprocess plumbing */


char* dmcp_truncate(char* text, int length):
	if (length <= dmcp_max_output()):
		return strclone(text)
	char* suffix = c"\n... truncated ...\n"
	int suffix_length = strlen(suffix)
	char* out = malloc(dmcp_max_output() + suffix_length + 1)
	int i = 0
	while (i < dmcp_max_output()):
		out[i] = text[i]
		i = i + 1
	strcpy(out + dmcp_max_output(), suffix)
	return out


# Runs the command words to completion with stdio piped, routed through
# /usr/bin/env so PATH resolution works for bare commands like "make"
# (mirrors w-toolchain-mcp's mcp_run_cmd).
json_value* dmcp_run_cmd(list[char*] words, int timeout_ms):
	mkdir(c"bin", 493)
	char** argv = strv_new(words.length + 1)
	strv_set(argv, 0, c"env")
	int i = 0
	while (i < words.length):
		strv_set(argv, i + 1, words[i])
		i = i + 1
	process_result* r = process_run(c"/usr/bin/env", argv, 0, 0, timeout_ms)
	free(cast(void*, argv))
	if (r == 0):
		dmcp_fail(c"failed to spawn subprocess")
		return 0
	int exit_code = r.status
	if (r.status == process_status_timeout()):
		exit_code = 124
	char* stdout_text = dmcp_truncate(r.stdout_text, r.stdout_length)
	char* stderr_text = dmcp_truncate(r.stderr_text, r.stderr_length)
	json_value* result = json_object()
	json_object_set(result, c"exit_code", json_int(exit_code))
	json_object_set(result, c"stdout", json_string_take(stdout_text))
	json_object_set(result, c"stderr", json_string_take(stderr_text))
	process_result_free(r)
	return result


int dmcp_ensure_wdbg():
	if (path_exists(c"bin/wdbg")):
		return 1
	list[char*] words = new list[char*]
	words.push(c"make")
	words.push(c"wdbg")
	json_value* result = dmcp_run_cmd(words, 180000)
	if (result == 0):
		return 0
	json_value* exit_code = json_object_get(result, c"exit_code")
	if (exit_code.int_value != 0):
		dmcp_fail(json_stringify(result))
		json_free(result)
		return 0
	json_free(result)
	return 1


/* argument helpers */


char* dmcp_arg_string(json_value* args, char* key):
	if (args == 0):
		return 0
	if (args.type != json_type_object()):
		return 0
	json_value* value = json_object_get(args, key)
	if (value == 0):
		return 0
	if (value.type != json_type_string()):
		return 0
	return value.string_value


json_value* dmcp_arg_array(json_value* args, char* key):
	if (args == 0):
		return 0
	if (args.type != json_type_object()):
		return 0
	json_value* value = json_object_get(args, key)
	if (value == 0):
		return 0
	if (value.type != json_type_array()):
		return 0
	return value


# Absent means "use the default"; present-and-false is the only way to
# get 0, so a missing/non-bool key can't accidentally suppress it.
int dmcp_arg_bool(json_value* args, char* key, int missing):
	if (args == 0):
		return missing
	if (args.type != json_type_object()):
		return missing
	json_value* value = json_object_get(args, key)
	if (value == 0):
		return missing
	if ((value.type != json_type_bool()) & (value.type != json_type_int())):
		return missing
	return value.int_value


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
	char* file = dmcp_arg_string(args, c"file")
	if (file == 0):
		dmcp_fail(c"file is required")
		return 0
	json_value* extra_args = dmcp_arg_array(args, c"args")
	int break_start = dmcp_arg_bool(args, c"break_start", 1)

	list[char*] words = new list[char*]
	words.push(c"./bin/wdbg")
	words.push(file)
	if (extra_args != 0):
		int i = 0
		while (i < json_array_length(extra_args)):
			json_value* extra = json_array_get(extra_args, i)
			if (extra.type != json_type_string()):
				dmcp_fail(c"args entries must be strings")
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
		dmcp_fail(c"failed to spawn bin/wdbg")
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
	char* session_id = dmcp_arg_string(args, c"session_id")
	if (session_id == 0):
		dmcp_fail(c"session_id is required")
		return 0
	char* command = dmcp_arg_string(args, c"command")
	if (command == 0):
		dmcp_fail(c"command is required")
		return 0
	process* p = dmcp_lookup_session(session_id)
	if (p == 0):
		dmcp_fail(c"unknown or already-stopped session_id")
		return 0
	if (p.stdin_fd < 0):
		dmcp_fail(c"session has already exited; call debug_stop and debug_start a new one")
		return 0

	char* line = strjoin(command, c"\x0a")
	int wrote = write(p.stdin_fd, line, strlen(line))
	free(line)
	if (wrote < 0):
		dmcp_drop_session(session_id)
		dmcp_fail(c"session's stdin is closed (the debuggee likely exited)")
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
	char* session_id = dmcp_arg_string(args, c"session_id")
	if (session_id == 0):
		dmcp_fail(c"session_id is required")
		return 0
	process* p = dmcp_lookup_session(session_id)
	if (p == 0):
		dmcp_fail(c"unknown or already-stopped session_id")
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


json_value* dmcp_string_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"string"))
	return property


json_value* dmcp_string_array_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"array"))
	json_object_set(property, c"items", dmcp_string_property())
	return property


json_value* dmcp_bool_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"boolean"))
	return property


json_value* dmcp_tool_schema(char* name, char* description, json_value* properties):
	json_value* schema = json_object()
	json_object_set(schema, c"type", json_string(c"object"))
	json_object_set(schema, c"properties", properties)
	json_object_set(schema, c"additionalProperties", json_bool(1))
	json_value* tool = json_object()
	json_object_set(tool, c"name", json_string(name))
	json_object_set(tool, c"description", json_string(description))
	json_object_set(tool, c"inputSchema", schema)
	return tool


json_value* dmcp_tool_schemas():
	json_value* tools = json_array()

	json_value* start_properties = json_object()
	json_object_set(start_properties, c"file", dmcp_string_property())
	json_object_set(start_properties, c"args", dmcp_string_array_property())
	json_object_set(start_properties, c"break_start", dmcp_bool_property())
	char* start_desc = c"Start a wdbg session on file (default --break_start: true, so the debuggee is paused before it runs). Returns a session_id and the output up to the first prompt."
	json_array_push(tools, dmcp_tool_schema(c"debug_start", start_desc, start_properties))

	json_value* send_properties = json_object()
	json_object_set(send_properties, c"session_id", dmcp_string_property())
	json_object_set(send_properties, c"command", dmcp_string_property())
	char* send_desc = c"Send one wdbg command (break, condition, log, print, step, continue, ...) to a session and return the output up to the next prompt."
	json_array_push(tools, dmcp_tool_schema(c"debug_send", send_desc, send_properties))

	json_value* stop_properties = json_object()
	json_object_set(stop_properties, c"session_id", dmcp_string_property())
	char* stop_desc = c"Kill and clean up a wdbg session."
	json_array_push(tools, dmcp_tool_schema(c"debug_stop", stop_desc, stop_properties))

	return tools


/* JSON-RPC plumbing */


void dmcp_send(json_value* message):
	char* body = json_stringify(message)
	frame_write_cstr(1, body)
	free(body)
	json_free(message)


json_value* dmcp_clone_id(json_value* id):
	if (id == 0):
		return json_null()
	return json_clone(id)


void dmcp_success(json_value* id, json_value* result):
	json_value* response = json_object()
	json_object_set(response, c"jsonrpc", json_string(c"2.0"))
	json_object_set(response, c"id", dmcp_clone_id(id))
	json_object_set(response, c"result", result)
	dmcp_send(response)


void dmcp_respond_error(json_value* id, int code, char* message):
	json_value* error = json_object()
	json_object_set(error, c"code", json_int(code))
	json_object_set(error, c"message", json_string(message))
	json_value* response = json_object()
	json_object_set(response, c"jsonrpc", json_string(c"2.0"))
	json_object_set(response, c"id", dmcp_clone_id(id))
	json_object_set(response, c"error", error)
	dmcp_send(response)


json_value* dmcp_content_result(char* text, int is_error):
	json_value* item = json_object()
	json_object_set(item, c"type", json_string(c"text"))
	json_object_set(item, c"text", json_string(text))
	json_value* content = json_array()
	json_array_push(content, item)
	json_value* result = json_object()
	json_object_set(result, c"content", content)
	json_object_set(result, c"isError", json_bool(is_error))
	return result


void dmcp_handle_tools_call(json_value* id, json_value* params):
	char* name = dmcp_arg_string(params, c"name")
	if (name == 0):
		dmcp_respond_error(id, -32602, c"unknown tool: (missing name)")
		return
	if (dmcp_tool_known(name) == 0):
		char* message = strjoin(c"unknown tool: ", name)
		dmcp_respond_error(id, -32602, message)
		free(message)
		return
	json_value* args = 0
	if (params != 0):
		if (params.type == json_type_object()):
			args = json_object_get(params, c"arguments")
	dmcp_fail(c"tool failed")
	json_value* tool_result = dmcp_call_tool(name, args)
	if (tool_result == 0):
		dmcp_success(id, dmcp_content_result(dmcp_error, 1))
		return
	char* text = json_stringify(tool_result)
	json_free(tool_result)
	dmcp_success(id, dmcp_content_result(text, 0))
	free(text)


void dmcp_handle_initialize(json_value* id):
	json_value* server_info = json_object()
	json_object_set(server_info, c"name", json_string(c"w-debug"))
	json_object_set(server_info, c"version", json_string(c"0.1.0"))
	json_value* capabilities = json_object()
	json_object_set(capabilities, c"tools", json_object())
	json_value* result = json_object()
	json_object_set(result, c"protocolVersion", json_string(c"2024-11-05"))
	json_object_set(result, c"capabilities", capabilities)
	json_object_set(result, c"serverInfo", server_info)
	dmcp_success(id, result)


void dmcp_handle(json_value* request):
	char* method = 0
	json_value* id = 0
	if (request.type == json_type_object()):
		method = dmcp_arg_string(request, c"method")
		id = json_object_get(request, c"id")
	if (method == 0):
		dmcp_respond_error(id, -32600, c"invalid request")
		return
	if (strcmp(method, c"initialize") == 0):
		dmcp_handle_initialize(id)
	else if (strcmp(method, c"notifications/initialized") == 0):
		return
	else if (strcmp(method, c"tools/list") == 0):
		json_value* result = json_object()
		json_object_set(result, c"tools", dmcp_tool_schemas())
		dmcp_success(id, result)
	else if (strcmp(method, c"tools/call") == 0):
		dmcp_handle_tools_call(id, json_object_get(request, c"params"))
	else:
		char* message = strjoin(c"method not found: ", method)
		dmcp_respond_error(id, -32601, message)
		free(message)


# The binary lives in bin/, so when launched by a path ending in bin/ hop
# to the parent (the repo root) so ./bin/wdbg resolves.
void dmcp_chdir_root():
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
	dmcp_chdir_root()
	dmcp_sessions = new map[char*, process*]
	dmcp_next_session_id = 0
	frame_reader* r = frame_reader_new(0)
	while (1):
		int length = 0
		char* body = frame_read_message(r, &length)
		if (body == 0):
			break
		json_value* request = json_parse(body)
		free(body)
		if (request == 0):
			dmcp_respond_error(0, -32700, c"parse error")
		else:
			dmcp_handle(request)
			json_free(request)
	frame_reader_free(r)
	return 0
