# Smoke-test the stdio index MCP server: spawn bin/wimcp, run the
# initialize handshake, list tools, and exercise find_symbol/
# get_struct_fields/find_references/callers/callees/imports_for/
# changed_file_test_targets end to end against tests/index_fixture.w.
import lib.lib
import lib.assert
import lib.framing
import lib.process
import structures.string
import structures.json


process* imcp_test_server


void imcp_test_write(json_value* message):
	char* body = json_stringify(message)
	frame_write_cstr(imcp_test_server.stdin_fd, body)
	free(body)
	json_free(message)


json_value* imcp_test_read(frame_reader* r):
	int length = 0
	char* body = frame_read_message(r, &length)
	asserts(c"server closed stdout", body != 0)
	json_value* message = json_parse(body)
	free(body)
	asserts(c"response is valid json", message != 0)
	return message


json_value* imcp_test_message(int id, char* method, json_value* params):
	json_value* message = json_object()
	json_object_set(message, c"jsonrpc", json_string(c"2.0"))
	if (id > 0):
		json_object_set(message, c"id", json_int(id))
	json_object_set(message, c"method", json_string(method))
	if (params != 0):
		json_object_set(message, c"params", params)
	return message


json_value* imcp_test_request(frame_reader* r, int id, char* method, json_value* params):
	imcp_test_write(imcp_test_message(id, method, params))
	json_value* response = imcp_test_read(r)
	asserts(c"response carries no error", json_object_has(response, c"error") == 0)
	json_value* result = json_object_get(response, c"result")
	asserts(c"response carries a result", result != 0)
	return result


json_value* imcp_test_tool_result(frame_reader* r, int id, char* name, json_value* arguments):
	json_value* params = json_object()
	json_object_set(params, c"name", json_string(name))
	json_object_set(params, c"arguments", arguments)
	json_value* result = imcp_test_request(r, id, c"tools/call", params)
	json_value* is_error = json_object_get(result, c"isError")
	asserts(c"tool result is not an error", is_error != 0)
	asserts(c"tool result is not an error", is_error.int_value == 0)
	json_value* content = json_object_get(result, c"content")
	json_value* item = json_array_get(content, 0)
	json_value* text = json_object_get(item, c"text")
	json_value* payload = json_parse(text.string_value)
	asserts(c"tool payload is valid json", payload != 0)
	return payload


int imcp_test_tools_has(json_value* tools, char* name):
	int i = 0
	while (i < json_array_length(tools)):
		json_value* tool = json_array_get(tools, i)
		json_value* tool_name = json_object_get(tool, c"name")
		if (strcmp(tool_name.string_value, name) == 0):
			return 1
		i = i + 1
	return 0


json_value* imcp_test_name_files_args(char* name, char* file):
	json_value* files = json_array()
	json_array_push(files, json_string(file))
	json_value* args = json_object()
	json_object_set(args, c"name", json_string(name))
	json_object_set(args, c"files", files)
	return args


int main(int argc, int argv):
	char** server_argv = strv_new(1)
	strv_set(server_argv, 0, c"./bin/wimcp")
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	opts.stdout_mode = process_pipe()
	opts.stderr_mode = process_inherit()
	imcp_test_server = process_spawn(c"./bin/wimcp", server_argv, opts)
	free(opts)
	free(cast(void*, server_argv))
	asserts(c"server spawned", imcp_test_server != 0)
	frame_reader* r = frame_reader_new(imcp_test_server.stdout_fd)

	json_value* init_params = json_object()
	json_object_set(init_params, c"protocolVersion", json_string(c"2024-11-05"))
	json_object_set(init_params, c"capabilities", json_object())
	json_value* init = imcp_test_request(r, 1, c"initialize", init_params)
	json_value* server_info = json_object_get(init, c"serverInfo")
	json_value* server_name = json_object_get(server_info, c"name")
	assert_strings_equal(c"w-index", server_name.string_value)

	imcp_test_write(imcp_test_message(0, c"notifications/initialized", json_object()))

	json_value* listed = imcp_test_request(r, 2, c"tools/list", 0)
	json_value* tools = json_object_get(listed, c"tools")
	assert_equal(8, json_array_length(tools))
	asserts(c"tools include find_symbol", imcp_test_tools_has(tools, c"find_symbol"))
	asserts(c"tools include find_references", imcp_test_tools_has(tools, c"find_references"))
	asserts(c"tools include get_type", imcp_test_tools_has(tools, c"get_type"))
	asserts(c"tools include get_struct_fields", imcp_test_tools_has(tools, c"get_struct_fields"))
	asserts(c"tools include imports_for", imcp_test_tools_has(tools, c"imports_for"))
	asserts(c"tools include callers", imcp_test_tools_has(tools, c"callers"))
	asserts(c"tools include callees", imcp_test_tools_has(tools, c"callees"))
	asserts(c"tools include changed_file_test_targets", imcp_test_tools_has(tools, c"changed_file_test_targets"))

	json_value* symbol = imcp_test_tool_result(r, 3, c"find_symbol", imcp_test_name_files_args(c"index_fixture_helper", c"tests/index_fixture.w"))
	json_value* symbol_records = json_object_get(symbol, c"records")
	assert_equal(1, json_array_length(symbol_records))
	json_value* symbol_kind = json_object_get(json_array_get(symbol_records, 0), c"kind")
	assert_strings_equal(c"function", symbol_kind.string_value)
	json_free(symbol)

	json_value* fields = imcp_test_tool_result(r, 4, c"get_struct_fields", imcp_test_name_files_args(c"index_fixture_point", c"tests/index_fixture.w"))
	json_value* field_records = json_object_get(fields, c"records")
	assert_equal(2, json_array_length(field_records))
	json_free(fields)

	json_value* refs = imcp_test_tool_result(r, 5, c"find_references", imcp_test_name_files_args(c"index_fixture_helper", c"tests/index_fixture.w"))
	json_value* ref_records = json_object_get(refs, c"records")
	assert_equal(3, json_array_length(ref_records))
	json_free(refs)

	json_value* callers = imcp_test_tool_result(r, 6, c"callers", imcp_test_name_files_args(c"index_fixture_helper", c"tests/index_fixture.w"))
	json_value* caller_records = json_object_get(callers, c"records")
	assert_equal(2, json_array_length(caller_records))
	json_value* caller_name = json_object_get(json_array_get(caller_records, 0), c"caller")
	assert_strings_equal(c"index_fixture_caller", caller_name.string_value)
	json_free(callers)

	json_value* callees = imcp_test_tool_result(r, 7, c"callees", imcp_test_name_files_args(c"index_fixture_caller", c"tests/index_fixture.w"))
	json_value* callee_records = json_object_get(callees, c"records")
	assert_equal(2, json_array_length(callee_records))
	json_value* callee_name = json_object_get(json_array_get(callee_records, 0), c"callee")
	assert_strings_equal(c"index_fixture_helper", callee_name.string_value)
	json_free(callees)

	json_value* imports_args = json_object()
	json_object_set(imports_args, c"file", json_string(c"tests/index_fixture.w"))
	json_value* imports = imcp_test_tool_result(r, 8, c"imports_for", imports_args)
	json_value* import_records = json_object_get(imports, c"records")
	assert_equal(1, json_array_length(import_records))
	json_value* import_module = json_object_get(json_array_get(import_records, 0), c"module")
	assert_strings_equal(c"lib.lib", import_module.string_value)
	json_free(imports)

	json_value* changed_files = json_array()
	json_array_push(changed_files, json_string(c"structures/json.w"))
	json_value* changed_args = json_object()
	json_object_set(changed_args, c"files", changed_files)
	json_value* changed = imcp_test_tool_result(r, 9, c"changed_file_test_targets", changed_args)
	json_value* targets = json_object_get(changed, c"targets")
	assert_equal(6, json_array_length(targets))
	json_free(changed)

	process_close_stdin(imcp_test_server)
	int status = process_wait_or_kill(imcp_test_server, 5000)
	assert_equal(0, status)
	process_free(imcp_test_server)
	frame_reader_free(r)
	println2(c"index mcp test OK")
	return 0
