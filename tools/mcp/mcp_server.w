# Shared plumbing for the W MCP servers (w-toolchain, w-index, w-debug):
# JSON-RPC 2.0 over Content-Length framing, the initialize / tools/list /
# tools/call protocol, subprocess helpers, and argument/schema builders.
#
# Each server keeps only its tool handlers, schemas and dispatch table,
# registers them with mcp_server_init(name, version, known, dispatch,
# schemas), and calls mcp_serve() to run the stdio loop. The three
# callbacks are typed function pointers so this module never needs to
# know the tool names.
import lib.lib
import lib.args
import lib.path
import lib.framing
import lib.process
import structures.string
import structures.json


# Returns 1 when the server exposes a tool by this name right now (the
# toolchain server gates escape_hatch on an environment variable).
type mcp_tool_known_handler = fn(char*) -> int

# Runs one tool by name. Returns the result object, or 0 with mcp_error
# set (unknown names are handled by the caller before dispatching).
type mcp_tool_dispatch_handler = fn(char*, json_value*) -> json_value*

# Builds the tools/list array of tool schema objects.
type mcp_tool_schemas_handler = fn() -> json_value*


char* mcp_server_name
char* mcp_server_version
mcp_tool_known_handler* mcp_tool_known_fn
mcp_tool_dispatch_handler* mcp_tool_dispatch_fn
mcp_tool_schemas_handler* mcp_tool_schemas_fn


void mcp_server_init(char* name, char* version, mcp_tool_known_handler* known, mcp_tool_dispatch_handler* dispatch, mcp_tool_schemas_handler* schemas):
	mcp_server_name = name
	mcp_server_version = version
	mcp_tool_known_fn = known
	mcp_tool_dispatch_fn = dispatch
	mcp_tool_schemas_fn = schemas


int mcp_max_output():
	return 64000


# Explanation for the current tool failure; tool handlers return 0 after
# setting this, and the dispatcher reports it as an isError result.
char* mcp_error


void mcp_fail(char* message):
	free(mcp_error)
	mcp_error = strclone(message)


void mcp_fail_take(char* message):
	free(mcp_error)
	mcp_error = message


/* subprocess plumbing */


# Cap stdout/stderr so a runaway command cannot flood the client.
# Returns a malloc'd string.
char* mcp_truncate(char* text, int length):
	if (length <= mcp_max_output()):
		return strclone(text)
	char* suffix = c"\n... truncated ...\n"
	int suffix_length = strlen(suffix)
	char* out = malloc(mcp_max_output() + suffix_length + 1)
	int i = 0
	while (i < mcp_max_output()):
		out[i] = text[i]
		i = i + 1
	strcpy(out + mcp_max_output(), suffix)
	return out


# Runs the command words to completion with stdio piped, routed through
# /usr/bin/env so PATH resolution works for bare commands. Returns
# {exit_code, stdout, stderr, duration_ms}; a timeout maps to exit code
# 124 with a note appended to stderr.
json_value* mcp_run_cmd(list[char*] words, char* stdin_text, int timeout_ms):
	mkdir(c"bin", 493)
	char** argv = strv_new(words.length + 1)
	strv_set(argv, 0, c"env")
	int i = 0
	while (i < words.length):
		strv_set(argv, i + 1, words[i])
		i = i + 1

	int start = process_monotonic_ms()
	process_result* r = process_run(c"/usr/bin/env", argv, 0, stdin_text, timeout_ms)
	int duration = process_monotonic_ms() - start
	free(cast(void*, argv))
	if (r == 0):
		mcp_fail(c"failed to spawn subprocess")
		return 0

	int exit_code = r.status
	char* stderr_text = 0
	if (r.status == process_status_timeout()):
		exit_code = 124
		char* truncated = mcp_truncate(r.stderr_text, r.stderr_length)
		string_builder* message = string_from(truncated)
		free(truncated)
		string_append(message, c"\ntimeout after ")
		string_append_int(message, timeout_ms / 1000)
		string_append(message, c"s")
		stderr_text = message.data
		free(message)
	else:
		stderr_text = mcp_truncate(r.stderr_text, r.stderr_length)

	json_value* result = json_object()
	json_object_set(result, c"exit_code", json_int(exit_code))
	json_object_set(result, c"stdout", json_string_take(mcp_truncate(r.stdout_text, r.stdout_length)))
	json_object_set(result, c"stderr", json_string_take(stderr_text))
	json_object_set(result, c"duration_ms", json_int(duration))
	process_result_free(r)
	return result


int mcp_result_exit_code(json_value* result):
	json_value* code = json_object_get(result, c"exit_code")
	if (code == 0):
		return -1
	return code.int_value


# Builds a bin/ tool via './wbuild <target>' when its path is missing.
# Returns 1 when available; otherwise sets mcp_error to the serialized
# build result and returns 0.
int mcp_ensure_built(char* path, char* target, int timeout_ms):
	if (path_exists(path)):
		return 1
	list[char*] words = new list[char*]
	words.push(c"./wbuild")
	words.push(target)
	json_value* result = mcp_run_cmd(words, 0, timeout_ms)
	if (result == 0):
		return 0
	if (mcp_result_exit_code(result) != 0):
		mcp_fail_take(json_stringify(result))
		json_free(result)
		return 0
	json_free(result)
	return 1


/* argument helpers */


# String member of args, or 0 when absent or not a string.
char* mcp_arg_string(json_value* args, char* key):
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


# Array member of args, or 0 when absent or not an array.
json_value* mcp_arg_array(json_value* args, char* key):
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
int mcp_arg_bool(json_value* args, char* key, int missing):
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


# Splits text into non-blank lines and parses each as one JSON record.
# Returns 0 (with mcp_error set) on malformed output.
json_value* mcp_parse_ndjson(char* text):
	json_value* records = json_array()
	int i = 0
	string_builder* line = string_new()
	while (1):
		int c = text[i]
		if ((c == '\n') | (c == 0)):
			if (line.length > 0):
				json_value* record = json_parse(line.data)
				if (record == 0):
					json_free(records)
					string_free(line)
					mcp_fail(c"invalid json in command output")
					return 0
				json_array_push(records, record)
			string_clear(line)
			if (c == 0):
				string_free(line)
				return records
		else if (c != '\r'):
			string_append_char(line, c)
		i = i + 1
	return records


/* tools/list schema builders */


json_value* mcp_string_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"string"))
	return property


json_value* mcp_string_array_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"array"))
	json_object_set(property, c"items", mcp_string_property())
	return property


json_value* mcp_bool_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"boolean"))
	return property


# No "type" restricts nothing (valid JSON Schema): the property can be
# any shape.
json_value* mcp_any_property():
	return json_object()


json_value* mcp_tool_schema(char* name, char* description, json_value* properties):
	json_value* schema = json_object()
	json_object_set(schema, c"type", json_string(c"object"))
	json_object_set(schema, c"properties", properties)
	json_object_set(schema, c"additionalProperties", json_bool(1))
	json_value* tool = json_object()
	json_object_set(tool, c"name", json_string(name))
	json_object_set(tool, c"description", json_string(description))
	json_object_set(tool, c"inputSchema", schema)
	return tool


/* JSON-RPC plumbing */


void mcp_send(json_value* message):
	char* body = json_stringify(message)
	frame_write_cstr(1, body)
	free(body)
	json_free(message)


json_value* mcp_clone_id(json_value* id):
	if (id == 0):
		return json_null()
	return json_clone(id)


void mcp_success(json_value* id, json_value* result):
	json_value* response = json_object()
	json_object_set(response, c"jsonrpc", json_string(c"2.0"))
	json_object_set(response, c"id", mcp_clone_id(id))
	json_object_set(response, c"result", result)
	mcp_send(response)


void mcp_respond_error(json_value* id, int code, char* message):
	json_value* error = json_object()
	json_object_set(error, c"code", json_int(code))
	json_object_set(error, c"message", json_string(message))
	json_value* response = json_object()
	json_object_set(response, c"jsonrpc", json_string(c"2.0"))
	json_object_set(response, c"id", mcp_clone_id(id))
	json_object_set(response, c"error", error)
	mcp_send(response)


# Wraps tool output (or a failure message) as an MCP content result.
json_value* mcp_content_result(char* text, int is_error):
	json_value* item = json_object()
	json_object_set(item, c"type", json_string(c"text"))
	json_object_set(item, c"text", json_string(text))
	json_value* content = json_array()
	json_array_push(content, item)
	json_value* result = json_object()
	json_object_set(result, c"content", content)
	json_object_set(result, c"isError", json_bool(is_error))
	return result


void mcp_handle_tools_call(json_value* id, json_value* params):
	char* name = mcp_arg_string(params, c"name")
	if (name == 0):
		mcp_respond_error(id, -32602, c"unknown tool: (missing name)")
		return
	if (mcp_tool_known_fn(name) == 0):
		char* message = strjoin(c"unknown tool: ", name)
		mcp_respond_error(id, -32602, message)
		free(message)
		return
	json_value* args = 0
	if (params != 0):
		if (params.type == json_type_object()):
			args = json_object_get(params, c"arguments")
	mcp_fail(c"tool failed")
	json_value* tool_result = mcp_tool_dispatch_fn(name, args)
	if (tool_result == 0):
		mcp_success(id, mcp_content_result(mcp_error, 1))
		return
	char* text = json_stringify(tool_result)
	json_free(tool_result)
	mcp_success(id, mcp_content_result(text, 0))
	free(text)


void mcp_handle_initialize(json_value* id):
	json_value* server_info = json_object()
	json_object_set(server_info, c"name", json_string(mcp_server_name))
	json_object_set(server_info, c"version", json_string(mcp_server_version))
	json_value* capabilities = json_object()
	json_object_set(capabilities, c"tools", json_object())
	json_value* result = json_object()
	json_object_set(result, c"protocolVersion", json_string(c"2024-11-05"))
	json_object_set(result, c"capabilities", capabilities)
	json_object_set(result, c"serverInfo", server_info)
	mcp_success(id, result)


void mcp_handle(json_value* request):
	char* method = 0
	json_value* id = 0
	if (request.type == json_type_object()):
		method = mcp_arg_string(request, c"method")
		id = json_object_get(request, c"id")
	if (method == 0):
		mcp_respond_error(id, -32600, c"invalid request")
		return
	if (strcmp(method, c"initialize") == 0):
		mcp_handle_initialize(id)
	else if (strcmp(method, c"notifications/initialized") == 0):
		return
	else if (strcmp(method, c"tools/list") == 0):
		json_value* result = json_object()
		json_object_set(result, c"tools", mcp_tool_schemas_fn())
		mcp_success(id, result)
	else if (strcmp(method, c"tools/call") == 0):
		mcp_handle_tools_call(id, json_object_get(request, c"params"))
	else:
		char* message = strjoin(c"method not found: ", method)
		mcp_respond_error(id, -32601, message)
		free(message)


# The binary lives in bin/, so when launched by a path ending in bin/
# hop to the parent — the repo root — so ./wbuild and ./bin/* resolve.
# Any other launch keeps the current directory.
void mcp_chdir_root():
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


# The stdio serve loop: framed JSON-RPC requests in, responses out,
# until EOF. Returns the process exit code.
int mcp_serve():
	frame_reader* r = frame_reader_new(0)
	while (1):
		int length = 0
		char* body = frame_read_message(r, &length)
		if (body == 0):
			break
		json_value* request = json_parse(body)
		free(body)
		if (request == 0):
			mcp_respond_error(0, -32700, c"parse error")
		else:
			mcp_handle(request)
			json_free(request)
	frame_reader_free(r)
	return 0
