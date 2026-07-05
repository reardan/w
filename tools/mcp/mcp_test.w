# Smoke-test the stdio MCP server: spawn bin/wmcp, run the initialize
# handshake, list tools, and exercise test_changed and check end to end.
import lib.lib
import lib.assert
import lib.framing
import lib.process
import structures.string
import structures.json


process* mcp_test_server


void mcp_test_write(json_value* message):
	char* body = json_stringify(message)
	frame_write_cstr(mcp_test_server.stdin_fd, body)
	free(body)
	json_free(message)


json_value* mcp_test_read(frame_reader* r):
	int length = 0
	char* body = frame_read_message(r, &length)
	asserts(c"server closed stdout", body != 0)
	json_value* message = json_parse(body)
	free(body)
	asserts(c"response is valid json", message != 0)
	return message


json_value* mcp_test_message(int id, char* method, json_value* params):
	json_value* message = json_object()
	json_object_set(message, c"jsonrpc", json_string(c"2.0"))
	if (id > 0):
		json_object_set(message, c"id", json_int(id))
	json_object_set(message, c"method", json_string(method))
	if (params != 0):
		json_object_set(message, c"params", params)
	return message


# Sends a request and returns its result member (the response is freed
# except for that detached result). Fails the test on an error response.
json_value* mcp_test_request(frame_reader* r, int id, char* method, json_value* params):
	mcp_test_write(mcp_test_message(id, method, params))
	json_value* response = mcp_test_read(r)
	asserts(c"response carries no error", json_object_has(response, c"error") == 0)
	json_value* result = json_object_get(response, c"result")
	asserts(c"response carries a result", result != 0)
	return result


# Calls a tool and parses the JSON payload out of its text content.
json_value* mcp_test_tool_result(frame_reader* r, int id, char* name, json_value* arguments):
	json_value* params = json_object()
	json_object_set(params, c"name", json_string(name))
	json_object_set(params, c"arguments", arguments)
	json_value* result = mcp_test_request(r, id, c"tools/call", params)
	json_value* is_error = json_object_get(result, c"isError")
	asserts(c"tool result is not an error", is_error != 0)
	asserts(c"tool result is not an error", is_error.int_value == 0)
	json_value* content = json_object_get(result, c"content")
	json_value* item = json_array_get(content, 0)
	json_value* text = json_object_get(item, c"text")
	json_value* payload = json_parse(text.string_value)
	asserts(c"tool payload is valid json", payload != 0)
	return payload


int mcp_test_tools_has(json_value* tools, char* name):
	int i = 0
	while (i < json_array_length(tools)):
		json_value* tool = json_array_get(tools, i)
		json_value* tool_name = json_object_get(tool, c"name")
		if (strcmp(tool_name.string_value, name) == 0):
			return 1
		i = i + 1
	return 0


int main(int argc, int argv):
	char** server_argv = strv_new(1)
	strv_set(server_argv, 0, c"./bin/wmcp")
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	opts.stdout_mode = process_pipe()
	opts.stderr_mode = process_inherit()
	mcp_test_server = process_spawn(c"./bin/wmcp", server_argv, opts)
	free(opts)
	free(cast(void*, server_argv))
	asserts(c"server spawned", mcp_test_server != 0)
	frame_reader* r = frame_reader_new(mcp_test_server.stdout_fd)

	json_value* init_params = json_object()
	json_object_set(init_params, c"protocolVersion", json_string(c"2024-11-05"))
	json_object_set(init_params, c"capabilities", json_object())
	json_value* client_info = json_object()
	json_object_set(client_info, c"name", json_string(c"mcp_test"))
	json_object_set(client_info, c"version", json_string(c"0"))
	json_object_set(init_params, c"clientInfo", client_info)
	json_value* init = mcp_test_request(r, 1, c"initialize", init_params)
	json_value* server_info = json_object_get(init, c"serverInfo")
	json_value* server_name = json_object_get(server_info, c"name")
	assert_strings_equal(c"w-toolchain", server_name.string_value)

	mcp_test_write(mcp_test_message(0, c"notifications/initialized", json_object()))

	json_value* listed = mcp_test_request(r, 2, c"tools/list", 0)
	json_value* tools = json_object_get(listed, c"tools")
	assert_equal(8, json_array_length(tools))
	asserts(c"tools include build", mcp_test_tools_has(tools, c"build"))
	asserts(c"tools include verify", mcp_test_tools_has(tools, c"verify"))
	asserts(c"tools include run_tests", mcp_test_tools_has(tools, c"run_tests"))
	asserts(c"tools include check", mcp_test_tools_has(tools, c"check"))
	asserts(c"tools include compile", mcp_test_tools_has(tools, c"compile"))
	asserts(c"tools include run", mcp_test_tools_has(tools, c"run"))
	asserts(c"tools include repl_eval", mcp_test_tools_has(tools, c"repl_eval"))
	asserts(c"tools include test_changed", mcp_test_tools_has(tools, c"test_changed"))

	json_value* changed_files = json_array()
	json_array_push(changed_files, json_string(c"structures/json.w"))
	json_value* changed_args = json_object()
	json_object_set(changed_args, c"files", changed_files)
	json_value* changed = mcp_test_tool_result(r, 3, c"test_changed", changed_args)
	json_value* targets = json_object_get(changed, c"targets")
	assert_equal(3, json_array_length(targets))
	json_value* target0 = json_array_get(targets, 0)
	json_value* target1 = json_array_get(targets, 1)
	json_value* target2 = json_array_get(targets, 2)
	assert_strings_equal(c"json_test", target0.string_value)
	assert_strings_equal(c"json_codec_test", target1.string_value)
	assert_strings_equal(c"json_rpc_test", target2.string_value)
	json_free(changed)

	json_value* check_args = json_object()
	json_object_set(check_args, c"file", json_string(c"tests/hello.w"))
	json_value* checked = mcp_test_tool_result(r, 4, c"check", check_args)
	json_value* exit_code = json_object_get(checked, c"exit_code")
	assert_equal(0, exit_code.int_value)
	json_value* diagnostics = json_object_get(checked, c"diagnostics")
	assert_equal(0, json_array_length(diagnostics))
	json_free(checked)

	# EOF on stdin makes the server exit its read loop.
	process_close_stdin(mcp_test_server)
	int status = process_wait_or_kill(mcp_test_server, 5000)
	assert_equal(0, status)
	process_free(mcp_test_server)
	frame_reader_free(r)
	println2(c"mcp test OK")
	return 0
