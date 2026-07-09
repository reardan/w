# Minimal stdio MCP server for the W toolchain: JSON-RPC 2.0 over
# Content-Length framing, exposing build/verify/test/check/compile/run/
# repl_eval/test_changed tools that shell out to ./wbuild and bin/wv2.
# Protocol plumbing lives in tools/mcp/mcp_server.w, shared with
# w-index-mcp and w-debug-mcp.
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
import structures.string
import structures.json
import tools.mcp.mcp_server


int mcp_default_timeout_ms():
	return 120000


# Builds bin/wv2 when missing. Returns 1 when available; otherwise sets
# mcp_error to the serialized ./wbuild result and returns 0.
int mcp_ensure_wv2():
	return mcp_ensure_built(c"bin/wv2", c"build", 240000)


int mcp_ensure_wtest():
	return mcp_ensure_built(c"bin/wtest", c"wtest", 180000)


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


int main(int argc, int argv):
	args_init(argc, argv)
	mcp_chdir_root()
	mcp_server_init(c"w-toolchain", c"0.1.0", mcp_tool_known, mcp_call_tool, mcp_tool_schemas)
	if (args_positional_count() >= 1):
		if (strcmp(args_positional(0), c"call") == 0):
			return mcp_cli_call()
	return mcp_serve()
