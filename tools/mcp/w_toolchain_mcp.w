# Minimal stdio MCP server for the W toolchain: JSON-RPC 2.0 over
# Content-Length framing, exposing build/verify/test/check/compile/run/
# repl_eval/test_changed tools that shell out to ./wbuild and bin/wv2.
#
# Also usable as a one-shot CLI, bypassing the JSON-RPC/stdio loop:
#   ./bin/wmcp call <tool> ['<json-arguments>']
#
# Build and register (see .cursor/mcp.json):
#   ./wbuild wmcp && ./bin/wmcp
import lib.lib
import lib.args
import lib.env
import lib.path
import lib.framing
import lib.process
import structures.string
import structures.json


int mcp_max_output():
	return 64000


int mcp_default_timeout_ms():
	return 120000


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


# Cap stdout/stderr like the Python server did so a runaway command
# cannot flood the client. Returns a malloc'd string.
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
# /usr/bin/env so PATH resolution matches what subprocess gave the Python
# server. Returns {exit_code, stdout, stderr, duration_ms}; a timeout maps
# to exit code 124 with a note appended to stderr.
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


# Builds bin/wv2 when missing. Returns 1 when available; otherwise sets
# mcp_error to the serialized ./wbuild result and returns 0.
int mcp_ensure_wv2():
	if (path_exists(c"bin/wv2")):
		return 1
	list[char*] words = new list[char*]
	words.push(c"./wbuild")
	words.push(c"build")
	json_value* result = mcp_run_cmd(words, 0, 240000)
	if (result == 0):
		return 0
	if (mcp_result_exit_code(result) != 0):
		mcp_fail_take(json_stringify(result))
		json_free(result)
		return 0
	json_free(result)
	return 1


int mcp_ensure_wtest():
	if (path_exists(c"bin/wtest")):
		return 1
	list[char*] words = new list[char*]
	words.push(c"./wbuild")
	words.push(c"wtest")
	json_value* result = mcp_run_cmd(words, 0, 180000)
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


int mcp_arch_is_x64(json_value* args):
	char* arch = mcp_arg_string(args, c"arch")
	if (arch == 0):
		return 0
	return strcmp(arch, c"x64") == 0


# The escape_hatch tool is a debug-only stub (see docs/projects/
# ai_tooling_next_steps.md); it must stay off unless a human opts in.
int mcp_escape_hatch_enabled():
	char* value = env_get(c"W_MCP_ESCAPE_HATCH")
	if (value == 0):
		return 0
	if (value[0] == 0):
		return 0
	if (strcmp(value, c"0") == 0):
		return 0
	return 1


# wbuild targets must match ^[a-z0-9_]+$ so a tool call cannot smuggle
# arbitrary wbuild arguments.
int mcp_valid_target(char* target):
	if (target[0] == 0):
		return 0
	int i = 0
	while (target[i]):
		int c = target[i]
		int ok = ((c >= 'a') & (c <= 'z')) | ((c >= '0') & (c <= '9')) | (c == '_')
		if (ok == 0):
			return 0
		i = i + 1
	return 1


/* tool handlers */


json_value* mcp_tool_build(json_value* args):
	list[char*] words = new list[char*]
	words.push(c"./wbuild")
	words.push(c"build")
	return mcp_run_cmd(words, 0, 240000)


json_value* mcp_tool_verify(json_value* args):
	list[char*] words = new list[char*]
	words.push(c"./wbuild")
	if (mcp_arch_is_x64(args)):
		words.push(c"verify_x64")
	else:
		words.push(c"verify")
	return mcp_run_cmd(words, 0, 240000)


json_value* mcp_tool_run_tests(json_value* args):
	json_value* targets = mcp_arg_array(args, c"targets")
	if (targets == 0):
		mcp_fail(c"targets must be a non-empty array")
		return 0
	if (json_array_length(targets) == 0):
		mcp_fail(c"targets must be a non-empty array")
		return 0
	list[char*] words = new list[char*]
	words.push(c"./wbuild")
	int i = 0
	while (i < json_array_length(targets)):
		json_value* target = json_array_get(targets, i)
		if (target.type != json_type_string()):
			mcp_fail(c"invalid target: not a string")
			return 0
		if (mcp_valid_target(target.string_value) == 0):
			char* message = strjoin(c"invalid target: ", target.string_value)
			mcp_fail_take(message)
			return 0
		words.push(target.string_value)
		i = i + 1
	return mcp_run_cmd(words, 0, 300000)


# Splits stdout into non-blank lines and parses each as one JSON
# diagnostic record. Returns 0 (with mcp_error set) on malformed output.
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


json_value* mcp_tool_check(json_value* args):
	if (mcp_ensure_wv2() == 0):
		return 0
	char* file = mcp_arg_string(args, c"file")
	if (file == 0):
		mcp_fail(c"file is required")
		return 0
	list[char*] words = new list[char*]
	words.push(c"./bin/wv2")
	words.push(c"check")
	words.push(c"--json")
	if (mcp_arch_is_x64(args)):
		words.push(c"x64")
	words.push(file)
	json_value* result = mcp_run_cmd(words, 0, mcp_default_timeout_ms())
	if (result == 0):
		return 0
	json_value* stdout_value = json_object_get(result, c"stdout")
	json_value* diagnostics = mcp_parse_ndjson(stdout_value.string_value)
	if (diagnostics == 0):
		json_free(result)
		return 0
	json_object_set(result, c"diagnostics", diagnostics)
	return result


json_value* mcp_tool_compile(json_value* args):
	if (mcp_ensure_wv2() == 0):
		return 0
	char* file = mcp_arg_string(args, c"file")
	if (file == 0):
		mcp_fail(c"file is required")
		return 0
	char* output = mcp_arg_string(args, c"output")
	if (output == 0):
		output = c"bin/mcp_compile_out"
	list[char*] words = new list[char*]
	words.push(c"./bin/wv2")
	if (mcp_arch_is_x64(args)):
		words.push(c"x64")
	words.push(file)
	words.push(c"-o")
	words.push(output)
	return mcp_run_cmd(words, 0, mcp_default_timeout_ms())


json_value* mcp_tool_run(json_value* args):
	char* path = mcp_arg_string(args, c"path")
	if (path == 0):
		mcp_fail(c"path is required")
		return 0
	list[char*] words = new list[char*]
	words.push(path)
	json_value* run_args = mcp_arg_array(args, c"args")
	if (run_args != 0):
		int i = 0
		while (i < json_array_length(run_args)):
			json_value* arg = json_array_get(run_args, i)
			if (arg.type == json_type_string()):
				words.push(arg.string_value)
			else if (arg.type == json_type_int()):
				words.push(itoa(arg.int_value))
			else:
				mcp_fail(c"args entries must be strings or integers")
				return 0
			i = i + 1
	return mcp_run_cmd(words, mcp_arg_string(args, c"stdin"), mcp_default_timeout_ms())


json_value* mcp_tool_repl_eval(json_value* args):
	if (mcp_ensure_wv2() == 0):
		return 0
	if (path_exists(c"bin/repl") == 0):
		list[char*] build_words = new list[char*]
		build_words.push(c"./bin/wv2")
		build_words.push(c"repl.w")
		build_words.push(c"-o")
		build_words.push(c"./bin/repl")
		json_value* build_result = mcp_run_cmd(build_words, 0, 180000)
		if (build_result == 0):
			return 0
		if (mcp_result_exit_code(build_result) != 0):
			return build_result
		json_free(build_result)
	string_builder* stdin_text = string_new()
	json_value* entries = mcp_arg_array(args, c"entries")
	if (entries != 0):
		int i = 0
		while (i < json_array_length(entries)):
			json_value* entry = json_array_get(entries, i)
			if (entry.type != json_type_string()):
				mcp_fail(c"entries must be strings")
				string_free(stdin_text)
				return 0
			if (i > 0):
				string_append(stdin_text, c"\n")
			string_append(stdin_text, entry.string_value)
			i = i + 1
	string_append(stdin_text, c"\n:quit\n")
	list[char*] words = new list[char*]
	words.push(c"./bin/repl")
	json_value* result = mcp_run_cmd(words, stdin_text.data, mcp_default_timeout_ms())
	string_free(stdin_text)
	return result


json_value* mcp_tool_test_changed(json_value* args):
	if (mcp_ensure_wtest() == 0):
		return 0
	list[char*] words = new list[char*]
	words.push(c"./bin/wtest")
	words.push(c"changed")
	json_value* files = mcp_arg_array(args, c"files")
	if (files != 0):
		int i = 0
		while (i < json_array_length(files)):
			json_value* file = json_array_get(files, i)
			if (file.type != json_type_string()):
				mcp_fail(c"files entries must be strings")
				return 0
			words.push(file.string_value)
			i = i + 1
	json_value* result = mcp_run_cmd(words, 0, mcp_default_timeout_ms())
	if (result == 0):
		return 0
	json_value* targets = json_array()
	json_value* stdout_value = json_object_get(result, c"stdout")
	char* text = stdout_value.string_value
	string_builder* line = string_new()
	int i = 0
	while (1):
		int c = text[i]
		if ((c == '\n') | (c == 0)):
			if (line.length > 0):
				json_array_push(targets, json_string(line.data))
			string_clear(line)
			if (c == 0):
				break
		else if (c != '\r'):
			string_append_char(line, c)
		i = i + 1
	string_free(line)
	json_object_set(result, c"targets", targets)
	return result


# One NDJSON line to stderr per call, so a human reviewing the server's
# log afterward can see what an agent probed and decide whether it is
# worth building for real (this is the whole point of the description
# argument). Stdout is reserved for JSON-RPC/CLI results, so this cannot
# go there.
void mcp_escape_hatch_log(char* tool_call_name, char* description, json_value* parameters):
	json_value* entry = json_object()
	json_object_set(entry, c"escape_hatch_call", json_string(tool_call_name))
	json_object_set(entry, c"description", json_string(description))
	if (parameters == 0):
		json_object_set(entry, c"parameters", json_null())
	else:
		json_object_set(entry, c"parameters", json_clone(parameters))
	char* text = json_stringify(entry)
	json_free(entry)
	println2(text)
	free(text)


# Debug-only stub, disabled unless W_MCP_ESCAPE_HATCH is set (see
# mcp_escape_hatch_enabled). Stands in for a theoretical/not-yet-built
# tool or compiler function: it never dispatches to anything real, it
# just logs and echoes what was asked for and returns an empty result,
# so an agent or human can probe "what if this tool existed" without
# anyone having to wire up a real handler first.
json_value* mcp_tool_escape_hatch(json_value* args):
	char* tool_call_name = mcp_arg_string(args, c"tool_call_name")
	if (tool_call_name == 0):
		mcp_fail(c"tool_call_name is required")
		return 0
	char* description = mcp_arg_string(args, c"description")
	if (description == 0):
		description = c""
	json_value* parameters = 0
	if (args != 0):
		if (args.type == json_type_object()):
			parameters = json_object_get(args, c"parameters")
	mcp_escape_hatch_log(tool_call_name, description, parameters)
	json_value* result = json_object()
	json_object_set(result, c"tool_call_name", json_string(tool_call_name))
	json_object_set(result, c"description", json_string(description))
	if (parameters == 0):
		json_object_set(result, c"parameters", json_null())
	else:
		json_object_set(result, c"parameters", json_clone(parameters))
	json_object_set(result, c"result", json_string(c""))
	return result


# Dispatches one tools/call by name. Returns the result object, or 0
# with mcp_error set (unknown names are handled by the caller).
json_value* mcp_call_tool(char* name, json_value* args):
	if (strcmp(name, c"build") == 0):
		return mcp_tool_build(args)
	if (strcmp(name, c"verify") == 0):
		return mcp_tool_verify(args)
	if (strcmp(name, c"run_tests") == 0):
		return mcp_tool_run_tests(args)
	if (strcmp(name, c"check") == 0):
		return mcp_tool_check(args)
	if (strcmp(name, c"compile") == 0):
		return mcp_tool_compile(args)
	if (strcmp(name, c"run") == 0):
		return mcp_tool_run(args)
	if (strcmp(name, c"repl_eval") == 0):
		return mcp_tool_repl_eval(args)
	if (strcmp(name, c"test_changed") == 0):
		return mcp_tool_test_changed(args)
	if (strcmp(name, c"escape_hatch") == 0):
		return mcp_tool_escape_hatch(args)
	return 0


int mcp_tool_known(char* name):
	if (strcmp(name, c"build") == 0):
		return 1
	if (strcmp(name, c"verify") == 0):
		return 1
	if (strcmp(name, c"run_tests") == 0):
		return 1
	if (strcmp(name, c"check") == 0):
		return 1
	if (strcmp(name, c"compile") == 0):
		return 1
	if (strcmp(name, c"run") == 0):
		return 1
	if (strcmp(name, c"repl_eval") == 0):
		return 1
	if (strcmp(name, c"test_changed") == 0):
		return 1
	if (strcmp(name, c"escape_hatch") == 0):
		return mcp_escape_hatch_enabled()
	return 0


/* tools/list schemas */


json_value* mcp_string_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"string"))
	return property


json_value* mcp_string_array_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"array"))
	json_object_set(property, c"items", mcp_string_property())
	return property


# No "type" restricts nothing (valid JSON Schema): parameters can be any
# shape, since escape_hatch is meant to describe a call to a tool that
# does not exist yet.
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


json_value* mcp_tool_schemas():
	json_value* tools = json_array()

	json_array_push(tools, mcp_tool_schema(c"build", c"Run ./wbuild build", json_object()))

	json_value* verify_properties = json_object()
	json_object_set(verify_properties, c"arch", mcp_string_property())
	json_array_push(tools, mcp_tool_schema(c"verify", c"Run ./wbuild verify or verify_x64", verify_properties))

	json_value* run_tests_properties = json_object()
	json_object_set(run_tests_properties, c"targets", mcp_string_array_property())
	json_array_push(tools, mcp_tool_schema(c"run_tests", c"Run validated wbuild test targets", run_tests_properties))

	json_value* check_properties = json_object()
	json_object_set(check_properties, c"file", mcp_string_property())
	json_object_set(check_properties, c"arch", mcp_string_property())
	json_array_push(tools, mcp_tool_schema(c"check", c"Run w check --json and parse diagnostics", check_properties))

	json_value* compile_properties = json_object()
	json_object_set(compile_properties, c"file", mcp_string_property())
	json_object_set(compile_properties, c"arch", mcp_string_property())
	json_object_set(compile_properties, c"output", mcp_string_property())
	json_array_push(tools, mcp_tool_schema(c"compile", c"Compile a W source file", compile_properties))

	json_value* run_properties = json_object()
	json_object_set(run_properties, c"path", mcp_string_property())
	json_object_set(run_properties, c"args", mcp_string_array_property())
	json_object_set(run_properties, c"stdin", mcp_string_property())
	json_array_push(tools, mcp_tool_schema(c"run", c"Run a compiled binary", run_properties))

	json_value* repl_properties = json_object()
	json_object_set(repl_properties, c"entries", mcp_string_array_property())
	json_array_push(tools, mcp_tool_schema(c"repl_eval", c"Evaluate entries in the W REPL", repl_properties))

	json_value* changed_properties = json_object()
	json_object_set(changed_properties, c"files", mcp_string_array_property())
	json_array_push(tools, mcp_tool_schema(c"test_changed", c"Map changed files to focused test targets", changed_properties))

	if (mcp_escape_hatch_enabled()):
		json_value* escape_properties = json_object()
		json_object_set(escape_properties, c"tool_call_name", mcp_string_property())
		json_object_set(escape_properties, c"parameters", mcp_any_property())
		json_object_set(escape_properties, c"description", mcp_string_property())
		char* escape_desc = c"DEBUG ONLY, opt-in via W_MCP_ESCAPE_HATCH: probe a theoretical/not-yet-built tool call by name. Never dispatches to anything real; always returns an empty result. Not a code-exec sandbox."
		json_array_push(tools, mcp_tool_schema(c"escape_hatch", escape_desc, escape_properties))

	return tools


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
	if (mcp_tool_known(name) == 0):
		char* message = strjoin(c"unknown tool: ", name)
		mcp_respond_error(id, -32602, message)
		free(message)
		return
	json_value* args = 0
	if (params != 0):
		if (params.type == json_type_object()):
			args = json_object_get(params, c"arguments")
	mcp_fail(c"tool failed")
	json_value* tool_result = mcp_call_tool(name, args)
	if (tool_result == 0):
		mcp_success(id, mcp_content_result(mcp_error, 1))
		return
	char* text = json_stringify(tool_result)
	json_free(tool_result)
	mcp_success(id, mcp_content_result(text, 0))
	free(text)


void mcp_handle_initialize(json_value* id):
	json_value* server_info = json_object()
	json_object_set(server_info, c"name", json_string(c"w-toolchain"))
	json_object_set(server_info, c"version", json_string(c"0.1.0"))
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
		json_object_set(result, c"tools", mcp_tool_schemas())
		mcp_success(id, result)
	else if (strcmp(method, c"tools/call") == 0):
		mcp_handle_tools_call(id, json_object_get(request, c"params"))
	else:
		char* message = strjoin(c"method not found: ", method)
		mcp_respond_error(id, -32601, message)
		free(message)


# One-shot CLI mode: `./bin/wmcp call <tool> ['<json-arguments>']` runs a
# single tool through the same dispatcher the stdio loop uses and prints
# its JSON result to stdout, no JSON-RPC framing or client required.
# Lets a human (or an agent debugging the server itself) exercise a tool
# — including escape_hatch, once opted in — directly from a shell.
int mcp_cli_call():
	char* name = args_positional(1)
	if (name == 0):
		println2(c"usage: wmcp call <tool> ['<json-arguments>']")
		return 1
	char* args_text = args_positional(2)
	json_value* tool_args = 0
	if (args_text != 0):
		tool_args = json_parse(args_text)
		if (tool_args == 0):
			println2(c"invalid json arguments")
			return 1
	if (mcp_tool_known(name) == 0):
		char* message = strjoin(c"unknown tool: ", name)
		println2(message)
		free(message)
		return 1
	mcp_fail(c"tool failed")
	json_value* result = mcp_call_tool(name, tool_args)
	if (result == 0):
		println2(mcp_error)
		return 1
	char* text = json_stringify(result)
	json_free(result)
	println(text)
	free(text)
	return 0


# The binary lives in bin/, so when launched by a path ending in bin/
# hop to the parent — the repo root — the way the Python server resolved
# its root from __file__. Any other launch keeps the current directory.
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


int main(int argc, int argv):
	args_init(argc, argv)
	mcp_chdir_root()
	if (args_positional_count() >= 1):
		if (strcmp(args_positional(0), c"call") == 0):
			return mcp_cli_call()
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
