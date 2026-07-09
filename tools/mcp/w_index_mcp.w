# Stdio MCP server exposing the semantic index (tools/index/w_index.w) as
# agent tools: find_symbol, find_references, get_type, get_struct_fields,
# imports_for, callers, callees, changed_file_test_targets. Shells out to
# bin/windex and bin/wtest exactly like w-toolchain-mcp shells to bin/wv2;
# see docs/projects/semantic_index.md for the index's contract and known
# gaps (textual reference finding, indentation-approximated call spans).
#
# Build and register (see .cursor/mcp.json):
#   make wimcp && ./bin/wimcp
import lib.lib
import lib.args
import lib.path
import lib.framing
import lib.process
import structures.string
import structures.json


int imcp_max_output():
	return 64000


int imcp_default_timeout_ms():
	return 60000


char* imcp_error


void imcp_fail(char* message):
	free(imcp_error)
	imcp_error = strclone(message)


/* subprocess plumbing */


char* imcp_truncate(char* text, int length):
	if (length <= imcp_max_output()):
		return strclone(text)
	char* suffix = c"\n... truncated ...\n"
	int suffix_length = strlen(suffix)
	char* out = malloc(imcp_max_output() + suffix_length + 1)
	int i = 0
	while (i < imcp_max_output()):
		out[i] = text[i]
		i = i + 1
	strcpy(out + imcp_max_output(), suffix)
	return out


# Runs the command words to completion with stdio piped, routed through
# /usr/bin/env so PATH resolution works for bare commands like "make"
# (mirrors w-toolchain-mcp's mcp_run_cmd).
json_value* imcp_run_cmd(list[char*] words, int timeout_ms):
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
		imcp_fail(c"failed to spawn subprocess")
		return 0
	int exit_code = r.status
	char* stderr_text = imcp_truncate(r.stderr_text, r.stderr_length)
	if (r.status == process_status_timeout()):
		exit_code = 124
	char* stdout_text = imcp_truncate(r.stdout_text, r.stdout_length)
	json_value* result = json_object()
	json_object_set(result, c"exit_code", json_int(exit_code))
	json_object_set(result, c"stdout", json_string_take(stdout_text))
	json_object_set(result, c"stderr", json_string_take(stderr_text))
	process_result_free(r)
	return result


int imcp_ensure_windex():
	if (path_exists(c"bin/windex")):
		return 1
	list[char*] words = new list[char*]
	words.push(c"make")
	words.push(c"windex")
	json_value* result = imcp_run_cmd(words, 180000)
	if (result == 0):
		return 0
	json_value* exit_code = json_object_get(result, c"exit_code")
	if (exit_code.int_value != 0):
		imcp_fail(json_stringify(result))
		json_free(result)
		return 0
	json_free(result)
	return 1


int imcp_ensure_wtest():
	if (path_exists(c"bin/wtest")):
		return 1
	list[char*] words = new list[char*]
	words.push(c"make")
	words.push(c"wtest")
	json_value* result = imcp_run_cmd(words, 180000)
	if (result == 0):
		return 0
	json_value* exit_code = json_object_get(result, c"exit_code")
	if (exit_code.int_value != 0):
		imcp_fail(json_stringify(result))
		json_free(result)
		return 0
	json_free(result)
	return 1


/* argument helpers */


char* imcp_arg_string(json_value* args, char* key):
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


json_value* imcp_arg_array(json_value* args, char* key):
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


# Non-empty list of entry files from args.files, or 0 (with imcp_error
# set) when missing/empty/non-string.
list[char*] imcp_arg_files(json_value* args):
	json_value* files = imcp_arg_array(args, c"files")
	if (files == 0):
		imcp_fail(c"files must be a non-empty array")
		return 0
	if (json_array_length(files) == 0):
		imcp_fail(c"files must be a non-empty array")
		return 0
	list[char*] result = new list[char*]
	int i = 0
	while (i < json_array_length(files)):
		json_value* file = json_array_get(files, i)
		if (file.type != json_type_string()):
			imcp_fail(c"files entries must be strings")
			return 0
		result.push(file.string_value)
		i = i + 1
	return result


/* NDJSON parsing of windex's stdout */


json_value* imcp_parse_ndjson(char* text):
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
					imcp_fail(c"invalid json in windex output")
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


# Runs './bin/windex <subcommand> <name> <files...>' and returns
# {exit_code, stdout, stderr, records}, or 0 (with imcp_error set) on
# failure to spawn/build or malformed output.
json_value* imcp_run_windex(char* subcommand, char* name, list[char*] files):
	if (imcp_ensure_windex() == 0):
		return 0
	list[char*] words = new list[char*]
	words.push(c"./bin/windex")
	words.push(subcommand)
	words.push(name)
	int i = 0
	while (i < files.length):
		words.push(files[i])
		i = i + 1
	json_value* result = imcp_run_cmd(words, imcp_default_timeout_ms())
	if (result == 0):
		return 0
	json_value* stdout_value = json_object_get(result, c"stdout")
	json_value* records = imcp_parse_ndjson(stdout_value.string_value)
	if (records == 0):
		json_free(result)
		return 0
	json_object_set(result, c"records", records)
	return result


/* tool handlers */


json_value* imcp_named_tool(char* subcommand, json_value* args):
	char* name = imcp_arg_string(args, c"name")
	if (name == 0):
		imcp_fail(c"name is required")
		return 0
	list[char*] files = imcp_arg_files(args)
	if (files == 0):
		return 0
	return imcp_run_windex(subcommand, name, files)


json_value* imcp_tool_find_symbol(json_value* args):
	return imcp_named_tool(c"symbol", args)


json_value* imcp_tool_find_references(json_value* args):
	return imcp_named_tool(c"references", args)


json_value* imcp_tool_get_type(json_value* args):
	return imcp_named_tool(c"type", args)


json_value* imcp_tool_get_struct_fields(json_value* args):
	return imcp_named_tool(c"struct", args)


json_value* imcp_tool_callers(json_value* args):
	return imcp_named_tool(c"callers", args)


json_value* imcp_tool_callees(json_value* args):
	return imcp_named_tool(c"callees", args)


json_value* imcp_tool_imports_for(json_value* args):
	if (imcp_ensure_windex() == 0):
		return 0
	char* file = imcp_arg_string(args, c"file")
	if (file == 0):
		imcp_fail(c"file is required")
		return 0
	list[char*] words = new list[char*]
	words.push(c"./bin/windex")
	words.push(c"imports")
	words.push(file)
	json_value* result = imcp_run_cmd(words, imcp_default_timeout_ms())
	if (result == 0):
		return 0
	json_value* stdout_value = json_object_get(result, c"stdout")
	json_value* records = imcp_parse_ndjson(stdout_value.string_value)
	if (records == 0):
		json_free(result)
		return 0
	json_object_set(result, c"records", records)
	return result


json_value* imcp_tool_changed_file_test_targets(json_value* args):
	if (imcp_ensure_wtest() == 0):
		return 0
	list[char*] words = new list[char*]
	words.push(c"./bin/wtest")
	words.push(c"changed")
	json_value* files = imcp_arg_array(args, c"files")
	if (files != 0):
		int i = 0
		while (i < json_array_length(files)):
			json_value* file = json_array_get(files, i)
			if (file.type != json_type_string()):
				imcp_fail(c"files entries must be strings")
				return 0
			words.push(file.string_value)
			i = i + 1
	json_value* result = imcp_run_cmd(words, imcp_default_timeout_ms())
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


json_value* imcp_call_tool(char* name, json_value* args):
	if (strcmp(name, c"find_symbol") == 0):
		return imcp_tool_find_symbol(args)
	if (strcmp(name, c"find_references") == 0):
		return imcp_tool_find_references(args)
	if (strcmp(name, c"get_type") == 0):
		return imcp_tool_get_type(args)
	if (strcmp(name, c"get_struct_fields") == 0):
		return imcp_tool_get_struct_fields(args)
	if (strcmp(name, c"imports_for") == 0):
		return imcp_tool_imports_for(args)
	if (strcmp(name, c"callers") == 0):
		return imcp_tool_callers(args)
	if (strcmp(name, c"callees") == 0):
		return imcp_tool_callees(args)
	if (strcmp(name, c"changed_file_test_targets") == 0):
		return imcp_tool_changed_file_test_targets(args)
	return 0


int imcp_tool_known(char* name):
	if (strcmp(name, c"find_symbol") == 0):
		return 1
	if (strcmp(name, c"find_references") == 0):
		return 1
	if (strcmp(name, c"get_type") == 0):
		return 1
	if (strcmp(name, c"get_struct_fields") == 0):
		return 1
	if (strcmp(name, c"imports_for") == 0):
		return 1
	if (strcmp(name, c"callers") == 0):
		return 1
	if (strcmp(name, c"callees") == 0):
		return 1
	if (strcmp(name, c"changed_file_test_targets") == 0):
		return 1
	return 0


/* tools/list schemas */


json_value* imcp_string_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"string"))
	return property


json_value* imcp_string_array_property():
	json_value* property = json_object()
	json_object_set(property, c"type", json_string(c"array"))
	json_object_set(property, c"items", imcp_string_property())
	return property


json_value* imcp_tool_schema(char* name, char* description, json_value* properties):
	json_value* schema = json_object()
	json_object_set(schema, c"type", json_string(c"object"))
	json_object_set(schema, c"properties", properties)
	json_object_set(schema, c"additionalProperties", json_bool(1))
	json_value* tool = json_object()
	json_object_set(tool, c"name", json_string(name))
	json_object_set(tool, c"description", json_string(description))
	json_object_set(tool, c"inputSchema", schema)
	return tool


json_value* imcp_name_files_properties():
	json_value* properties = json_object()
	json_object_set(properties, c"name", imcp_string_property())
	json_object_set(properties, c"files", imcp_string_array_property())
	return properties


json_value* imcp_tool_schemas():
	json_value* tools = json_array()

	char* find_symbol_desc = c"Declaration(s) of 'name' reachable from 'files' via wv2 symbols --json"
	json_array_push(tools, imcp_tool_schema(c"find_symbol", find_symbol_desc, imcp_name_files_properties()))
	char* find_references_desc = c"Every textual occurrence of 'name' across the files 'files' compiles in, with is_declaration flagged"
	json_array_push(tools, imcp_tool_schema(c"find_references", find_references_desc, imcp_name_files_properties()))
	char* get_type_desc = c"Declared type/kind of 'name' (same data as find_symbol, kept separate for query intent)"
	json_array_push(tools, imcp_tool_schema(c"get_type", get_type_desc, imcp_name_files_properties()))
	char* get_struct_fields_desc = c"Field name/type/offset for the struct or union named 'name'"
	json_array_push(tools, imcp_tool_schema(c"get_struct_fields", get_struct_fields_desc, imcp_name_files_properties()))
	char* callers_desc = c"Functions with a call site to 'name', approximated from indentation-based function spans"
	json_array_push(tools, imcp_tool_schema(c"callers", callers_desc, imcp_name_files_properties()))
	char* callees_desc = c"Functions called from within 'name', approximated from indentation-based function spans"
	json_array_push(tools, imcp_tool_schema(c"callees", callees_desc, imcp_name_files_properties()))

	json_value* imports_properties = json_object()
	json_object_set(imports_properties, c"file", imcp_string_property())
	char* imports_for_desc = c"Import statements in 'file' (module path, alias, line), parsed textually"
	json_array_push(tools, imcp_tool_schema(c"imports_for", imports_for_desc, imports_properties))

	json_value* changed_properties = json_object()
	json_object_set(changed_properties, c"files", imcp_string_array_property())
	char* changed_desc = c"Map changed files to focused test targets (delegates to bin/wtest changed)"
	json_array_push(tools, imcp_tool_schema(c"changed_file_test_targets", changed_desc, changed_properties))

	return tools


/* JSON-RPC plumbing */


void imcp_send(json_value* message):
	char* body = json_stringify(message)
	frame_write_cstr(1, body)
	free(body)
	json_free(message)


json_value* imcp_clone_id(json_value* id):
	if (id == 0):
		return json_null()
	return json_clone(id)


void imcp_success(json_value* id, json_value* result):
	json_value* response = json_object()
	json_object_set(response, c"jsonrpc", json_string(c"2.0"))
	json_object_set(response, c"id", imcp_clone_id(id))
	json_object_set(response, c"result", result)
	imcp_send(response)


void imcp_respond_error(json_value* id, int code, char* message):
	json_value* error = json_object()
	json_object_set(error, c"code", json_int(code))
	json_object_set(error, c"message", json_string(message))
	json_value* response = json_object()
	json_object_set(response, c"jsonrpc", json_string(c"2.0"))
	json_object_set(response, c"id", imcp_clone_id(id))
	json_object_set(response, c"error", error)
	imcp_send(response)


json_value* imcp_content_result(char* text, int is_error):
	json_value* item = json_object()
	json_object_set(item, c"type", json_string(c"text"))
	json_object_set(item, c"text", json_string(text))
	json_value* content = json_array()
	json_array_push(content, item)
	json_value* result = json_object()
	json_object_set(result, c"content", content)
	json_object_set(result, c"isError", json_bool(is_error))
	return result


void imcp_handle_tools_call(json_value* id, json_value* params):
	char* name = imcp_arg_string(params, c"name")
	if (name == 0):
		imcp_respond_error(id, -32602, c"unknown tool: (missing name)")
		return
	if (imcp_tool_known(name) == 0):
		char* message = strjoin(c"unknown tool: ", name)
		imcp_respond_error(id, -32602, message)
		free(message)
		return
	json_value* args = 0
	if (params != 0):
		if (params.type == json_type_object()):
			args = json_object_get(params, c"arguments")
	imcp_fail(c"tool failed")
	json_value* tool_result = imcp_call_tool(name, args)
	if (tool_result == 0):
		imcp_success(id, imcp_content_result(imcp_error, 1))
		return
	char* text = json_stringify(tool_result)
	json_free(tool_result)
	imcp_success(id, imcp_content_result(text, 0))
	free(text)


void imcp_handle_initialize(json_value* id):
	json_value* server_info = json_object()
	json_object_set(server_info, c"name", json_string(c"w-index"))
	json_object_set(server_info, c"version", json_string(c"0.1.0"))
	json_value* capabilities = json_object()
	json_object_set(capabilities, c"tools", json_object())
	json_value* result = json_object()
	json_object_set(result, c"protocolVersion", json_string(c"2024-11-05"))
	json_object_set(result, c"capabilities", capabilities)
	json_object_set(result, c"serverInfo", server_info)
	imcp_success(id, result)


void imcp_handle(json_value* request):
	char* method = 0
	json_value* id = 0
	if (request.type == json_type_object()):
		method = imcp_arg_string(request, c"method")
		id = json_object_get(request, c"id")
	if (method == 0):
		imcp_respond_error(id, -32600, c"invalid request")
		return
	if (strcmp(method, c"initialize") == 0):
		imcp_handle_initialize(id)
	else if (strcmp(method, c"notifications/initialized") == 0):
		return
	else if (strcmp(method, c"tools/list") == 0):
		json_value* result = json_object()
		json_object_set(result, c"tools", imcp_tool_schemas())
		imcp_success(id, result)
	else if (strcmp(method, c"tools/call") == 0):
		imcp_handle_tools_call(id, json_object_get(request, c"params"))
	else:
		char* message = strjoin(c"method not found: ", method)
		imcp_respond_error(id, -32601, message)
		free(message)


# The binary lives in bin/, so when launched by a path ending in bin/ hop
# to the parent (the repo root) so ./bin/windex and ./bin/wtest resolve.
void imcp_chdir_root():
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
	imcp_chdir_root()
	frame_reader* r = frame_reader_new(0)
	while (1):
		int length = 0
		char* body = frame_read_message(r, &length)
		if (body == 0):
			break
		json_value* request = json_parse(body)
		free(body)
		if (request == 0):
			imcp_respond_error(0, -32700, c"parse error")
		else:
			imcp_handle(request)
			json_free(request)
	frame_reader_free(r)
	return 0
