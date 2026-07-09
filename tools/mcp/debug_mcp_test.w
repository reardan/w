# Smoke-test the stdio debug MCP server: spawn bin/wdmcp, run the
# initialize handshake, list tools, then drive one real interactive wdbg
# session against tests/debug_no_pause_fixture.w (which has no 'debugger'
# statement, so it only pauses before running at all because debug_start
# defaults to --break_start) across several debug_start/debug_send/
# debug_stop calls -- the whole point of this server over a one-shot
# subprocess is that each call's output can inform the next.
import lib.lib
import lib.assert
import lib.framing
import lib.process
import structures.string
import structures.json


process* dmcp_test_server


void dmcp_test_write(json_value* message):
	char* body = json_stringify(message)
	frame_write_cstr(dmcp_test_server.stdin_fd, body)
	free(body)
	json_free(message)


json_value* dmcp_test_read(frame_reader* r):
	int length = 0
	char* body = frame_read_message(r, &length)
	asserts(c"server closed stdout", body != 0)
	json_value* message = json_parse(body)
	free(body)
	asserts(c"response is valid json", message != 0)
	return message


json_value* dmcp_test_message(int id, char* method, json_value* params):
	json_value* message = json_object()
	json_object_set(message, c"jsonrpc", json_string(c"2.0"))
	if (id > 0):
		json_object_set(message, c"id", json_int(id))
	json_object_set(message, c"method", json_string(method))
	if (params != 0):
		json_object_set(message, c"params", params)
	return message


json_value* dmcp_test_request(frame_reader* r, int id, char* method, json_value* params):
	dmcp_test_write(dmcp_test_message(id, method, params))
	json_value* response = dmcp_test_read(r)
	asserts(c"response carries no error", json_object_has(response, c"error") == 0)
	json_value* result = json_object_get(response, c"result")
	asserts(c"response carries a result", result != 0)
	return result


json_value* dmcp_test_tool_result(frame_reader* r, int id, char* name, json_value* arguments):
	json_value* params = json_object()
	json_object_set(params, c"name", json_string(name))
	json_object_set(params, c"arguments", arguments)
	json_value* result = dmcp_test_request(r, id, c"tools/call", params)
	json_value* is_error = json_object_get(result, c"isError")
	asserts(c"tool result is not an error", is_error != 0)
	asserts(c"tool result is not an error", is_error.int_value == 0)
	json_value* content = json_object_get(result, c"content")
	json_value* item = json_array_get(content, 0)
	json_value* text = json_object_get(item, c"text")
	json_value* payload = json_parse(text.string_value)
	asserts(c"tool payload is valid json", payload != 0)
	return payload


int dmcp_test_tools_has(json_value* tools, char* name):
	int i = 0
	while (i < json_array_length(tools)):
		json_value* tool = json_array_get(tools, i)
		json_value* tool_name = json_object_get(tool, c"name")
		if (strcmp(tool_name.string_value, name) == 0):
			return 1
		i = i + 1
	return 0


char* dmcp_test_output(json_value* payload):
	json_value* output = json_object_get(payload, c"output")
	asserts(c"payload has output", output != 0)
	return output.string_value


int dmcp_test_contains(char* haystack, char* needle):
	int i = 0
	while (haystack[i] != 0):
		if (starts_with(haystack + i, needle)):
			return 1
		i = i + 1
	return 0


int main(int argc, int argv):
	char** server_argv = strv_new(1)
	strv_set(server_argv, 0, c"./bin/wdmcp")
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	opts.stdout_mode = process_pipe()
	opts.stderr_mode = process_inherit()
	dmcp_test_server = process_spawn(c"./bin/wdmcp", server_argv, opts)
	free(opts)
	free(cast(void*, server_argv))
	asserts(c"server spawned", dmcp_test_server != 0)
	frame_reader* r = frame_reader_new(dmcp_test_server.stdout_fd)

	json_value* init_params = json_object()
	json_object_set(init_params, c"protocolVersion", json_string(c"2024-11-05"))
	json_object_set(init_params, c"capabilities", json_object())
	json_value* init = dmcp_test_request(r, 1, c"initialize", init_params)
	json_value* server_info = json_object_get(init, c"serverInfo")
	json_value* server_name = json_object_get(server_info, c"name")
	assert_strings_equal(c"w-debug", server_name.string_value)

	dmcp_test_write(dmcp_test_message(0, c"notifications/initialized", json_object()))

	json_value* listed = dmcp_test_request(r, 2, c"tools/list", 0)
	json_value* tools = json_object_get(listed, c"tools")
	assert_equal(3, json_array_length(tools))
	asserts(c"tools include debug_start", dmcp_test_tools_has(tools, c"debug_start"))
	asserts(c"tools include debug_send", dmcp_test_tools_has(tools, c"debug_send"))
	asserts(c"tools include debug_stop", dmcp_test_tools_has(tools, c"debug_stop"))

	# debug_start defaults to --break_start: the debuggee is paused before
	# main runs, so the very first response already reflects a stop, not
	# a race against the debuggee running unmanaged.
	json_value* start_args = json_object()
	json_object_set(start_args, c"file", json_string(c"tests/debug_no_pause_fixture.w"))
	json_value* started = dmcp_test_tool_result(r, 3, c"debug_start", start_args)
	json_value* prompt_seen = json_object_get(started, c"prompt_seen")
	asserts(c"debug_start reaches a prompt", prompt_seen.int_value)
	asserts(c"debug_start output shows the pre-main stop", dmcp_test_contains(dmcp_test_output(started), c"outside the debuggee"))
	json_value* session_id_value = json_object_get(started, c"session_id")
	char* session_id = strclone(session_id_value.string_value)
	json_free(started)

	# set a breakpoint before running, then continue into it -- with no
	# 'debugger' statement in the source, only the --break_start default
	# makes this reliable (see tests/debug_no_pause_fixture.w)
	json_value* break_args = json_object()
	json_object_set(break_args, c"session_id", json_string(session_id))
	json_object_set(break_args, c"command", json_string(c"break helper"))
	json_value* after_break = dmcp_test_tool_result(r, 4, c"debug_send", break_args)
	asserts(c"breakpoint set on helper", dmcp_test_contains(dmcp_test_output(after_break), c"breakpoint 1 at helper"))
	json_free(after_break)

	json_value* continue_args = json_object()
	json_object_set(continue_args, c"session_id", json_string(session_id))
	json_object_set(continue_args, c"command", json_string(c"c"))
	json_value* after_continue = dmcp_test_tool_result(r, 5, c"debug_send", continue_args)
	asserts(c"continue reaches the breakpoint", dmcp_test_contains(dmcp_test_output(after_continue), c"hit breakpoint 1"))
	json_free(after_continue)

	# inspect a local at the stop -- this is the "decide the next command
	# from what you just saw" loop a batch script can't do
	json_value* print_args = json_object()
	json_object_set(print_args, c"session_id", json_string(session_id))
	json_object_set(print_args, c"command", json_string(c"p a"))
	json_value* after_print = dmcp_test_tool_result(r, 6, c"debug_send", print_args)
	asserts(c"printed local matches the known fixture value", dmcp_test_contains(dmcp_test_output(after_print), c"a = 3"))
	json_free(after_print)

	json_value* stop_args = json_object()
	json_object_set(stop_args, c"session_id", json_string(session_id))
	json_value* stopped = dmcp_test_tool_result(r, 7, c"debug_stop", stop_args)
	json_value* exit_code = json_object_get(stopped, c"exit_code")
	asserts(c"debug_stop reports an exit code", exit_code != 0)
	json_free(stopped)
	free(session_id)

	process_close_stdin(dmcp_test_server)
	int status = process_wait_or_kill(dmcp_test_server, 5000)
	assert_equal(0, status)
	process_free(dmcp_test_server)
	frame_reader_free(r)
	println2(c"debug mcp test OK")
	return 0
