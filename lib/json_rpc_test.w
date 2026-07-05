import lib.testing
import lib.net
import lib.json_rpc


json_value* rpc_test_handle_add(json_value* params, void* ctx):
	if (params == 0):
		return 0
	if (params.type != json_type_array()):
		return 0
	if (json_array_length(params) != 2):
		return 0
	json_value* a = json_array_get(params, 0)
	json_value* b = json_array_get(params, 1)
	return json_int(a.int_value + b.int_value)


json_value* rpc_test_handle_echo(json_value* params, void* ctx):
	if (params == 0):
		return json_null()
	return json_clone(params)


json_value* rpc_test_handle_fail(json_value* params, void* ctx):
	return 0


int rpc_test_note_count


json_value* rpc_test_handle_note(json_value* params, void* ctx):
	rpc_test_note_count = rpc_test_note_count + 1
	return 0


json_value* rpc_test_handle_shutdown(json_value* params, void* ctx):
	jsonrpc_stop(cast(jsonrpc_server*, ctx))
	return json_bool(1)


jsonrpc_server* rpc_test_server_new():
	jsonrpc_server* s = jsonrpc_server_new()
	s.context = cast(void*, s)
	jsonrpc_register(s, c"add", rpc_test_handle_add)
	jsonrpc_register(s, c"echo", rpc_test_handle_echo)
	jsonrpc_register(s, c"fail", rpc_test_handle_fail)
	jsonrpc_register(s, c"note", rpc_test_handle_note)
	jsonrpc_register(s, c"shutdown", rpc_test_handle_shutdown)
	return s


void rpc_test_assert_error_code(json_value* response, int code):
	json_value* error_object = json_object_get(response, c"error")
	asserts(c"expected an error member", cast(int, error_object) != 0)
	json_value* code_value = json_object_get(error_object, c"code")
	assert_equal(code, code_value.int_value)
	asserts(c"expected no result member", json_object_has(response, c"result") == 0)


void test_jsonrpc_builders_round_trip():
	json_value* request = jsonrpc_request_new(7, c"sum", json_array())
	char* text = json_stringify(request)
	json_value* parsed = json_parse(text)
	json_value* id = json_object_get(parsed, c"id")
	assert_equal(7, id.int_value)
	json_value* method = json_object_get(parsed, c"method")
	assert_strings_equal(c"sum", method.string_value)
	json_value* version = json_object_get(parsed, c"jsonrpc")
	assert_strings_equal(c"2.0", version.string_value)
	free(text)
	json_free(parsed)
	json_free(request)

	json_value* error_response = jsonrpc_response_error(0, jsonrpc_error_invalid_params(), c"bad params")
	rpc_test_assert_error_code(error_response, jsonrpc_error_invalid_params())
	json_value* null_id = json_object_get(error_response, c"id")
	assert_equal(json_type_null(), null_id.type)
	json_free(error_response)


void test_jsonrpc_server_round_trip():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	jsonrpc_server* s = rpc_test_server_new()
	rpc_test_note_count = 0

	# Queue every client message before running the blocking serve loop.
	json_value* add_params = json_array()
	json_array_push(add_params, json_int(2))
	json_array_push(add_params, json_int(3))
	asserts(c"write add", jsonrpc_write_request(fds[0], 1, c"add", add_params) > 0)
	asserts(c"write unknown", jsonrpc_write_request(fds[0], 2, c"missing", 0) > 0)
	asserts(c"write fail", jsonrpc_write_request(fds[0], 3, c"fail", 0) > 0)
	asserts(c"write bad json", frame_write_cstr(fds[0], c"{oops") > 0)
	asserts(c"write note", jsonrpc_write_notification(fds[0], c"note", 0) > 0)
	asserts(c"write shutdown", jsonrpc_write_request(fds[0], 4, c"shutdown", 0) > 0)

	assert_equal(0, jsonrpc_serve_blocking(s, fds[1], fds[1]))
	assert_equal(1, rpc_test_note_count)

	frame_reader* r = frame_reader_new(fds[0])

	json_value* add_response = jsonrpc_read_message(r)
	json_value* add_id = json_object_get(add_response, c"id")
	assert_equal(1, add_id.int_value)
	json_value* add_result = json_object_get(add_response, c"result")
	assert_equal(5, add_result.int_value)
	json_free(add_response)

	json_value* missing_response = jsonrpc_read_message(r)
	json_value* missing_id = json_object_get(missing_response, c"id")
	assert_equal(2, missing_id.int_value)
	rpc_test_assert_error_code(missing_response, jsonrpc_error_method_not_found())
	json_free(missing_response)

	json_value* fail_response = jsonrpc_read_message(r)
	rpc_test_assert_error_code(fail_response, jsonrpc_error_internal())
	json_free(fail_response)

	json_value* parse_response = jsonrpc_read_message(r)
	rpc_test_assert_error_code(parse_response, jsonrpc_error_parse())
	json_value* parse_id = json_object_get(parse_response, c"id")
	assert_equal(json_type_null(), parse_id.type)
	json_free(parse_response)

	# The notification produced no response; the next reply is shutdown's.
	json_value* shutdown_response = jsonrpc_read_message(r)
	json_value* shutdown_id = json_object_get(shutdown_response, c"id")
	assert_equal(4, shutdown_id.int_value)
	json_value* shutdown_result = json_object_get(shutdown_response, c"result")
	assert_equal(json_type_bool(), shutdown_result.type)
	json_free(shutdown_response)

	frame_reader_free(r)
	jsonrpc_server_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)


void test_jsonrpc_string_id_is_preserved():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	jsonrpc_server* s = rpc_test_server_new()

	char* body = c"{\x22jsonrpc\x22:\x222.0\x22,\x22id\x22:\x22req-9\x22,\x22method\x22:\x22echo\x22,\x22params\x22:{\x22k\x22:1}}"
	jsonrpc_handle_body(s, body, fds[1])

	frame_reader* r = frame_reader_new(fds[0])
	json_value* response = jsonrpc_read_message(r)
	json_value* id = json_object_get(response, c"id")
	assert_strings_equal(c"req-9", id.string_value)
	json_value* result = json_object_get(response, c"result")
	json_value* k = json_object_get(result, c"k")
	assert_equal(1, k.int_value)
	json_free(response)

	frame_reader_free(r)
	jsonrpc_server_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)


void test_jsonrpc_invalid_request_missing_version():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	jsonrpc_server* s = rpc_test_server_new()

	jsonrpc_handle_body(s, c"{\x22id\x22:5,\x22method\x22:\x22add\x22}", fds[1])

	frame_reader* r = frame_reader_new(fds[0])
	json_value* response = jsonrpc_read_message(r)
	rpc_test_assert_error_code(response, jsonrpc_error_invalid_request())
	json_value* id = json_object_get(response, c"id")
	assert_equal(5, id.int_value)
	json_free(response)

	frame_reader_free(r)
	jsonrpc_server_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)
