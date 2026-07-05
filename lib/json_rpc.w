# JSON-RPC 2.0 helpers over Content-Length framing (lib/framing.w).
#
# Server usage:
#   jsonrpc_server* s = jsonrpc_server_new()
#   jsonrpc_register(s, c"add", handle_add)
#   jsonrpc_serve_blocking(s, in_fd, out_fd)
#
# Handlers receive the request params (may be 0) and the server context,
# and return an owned json_value* result, or 0 to signal an internal
# error. Notifications (no id) get no response. Unknown methods answer
# with error -32601 automatically.
import lib.lib
import lib.framing
import structures.json
import structures.hash_map


type jsonrpc_handler = fn(json_value*, void*) -> json_value*


struct jsonrpc_server:
	hash_map* handlers
	void* context
	int running


/* Standard JSON-RPC 2.0 error codes. */

int jsonrpc_error_parse():
	return -32700


int jsonrpc_error_invalid_request():
	return -32600


int jsonrpc_error_method_not_found():
	return -32601


int jsonrpc_error_invalid_params():
	return -32602


int jsonrpc_error_internal():
	return -32603


/* Message builders. All returned values are owned by the caller. */

# Shared envelope: {"jsonrpc": "2.0", "id": <clone(id) or null>}
json_value* jsonrpc_response_base(json_value* id):
	json_value* response = json_object()
	json_object_set(response, c"jsonrpc", json_string(c"2.0"))
	if (id == 0):
		json_object_set(response, c"id", json_null())
	else:
		json_object_set(response, c"id", json_clone(id))
	return response


# Takes ownership of result; id is borrowed (cloned into the response).
json_value* jsonrpc_response_result(json_value* id, json_value* result):
	json_value* response = jsonrpc_response_base(id)
	json_object_set(response, c"result", result)
	return response


json_value* jsonrpc_response_error(json_value* id, int code, char* message):
	json_value* response = jsonrpc_response_base(id)
	json_value* error_object = json_object()
	json_object_set(error_object, c"code", json_int(code))
	json_object_set(error_object, c"message", json_string(message))
	json_object_set(response, c"error", error_object)
	return response


# Takes ownership of params (which may be 0 to omit them).
json_value* jsonrpc_request_new(int id, char* method, json_value* params):
	json_value* request = json_object()
	json_object_set(request, c"jsonrpc", json_string(c"2.0"))
	json_object_set(request, c"id", json_int(id))
	json_object_set(request, c"method", json_string(method))
	if (params != 0):
		json_object_set(request, c"params", params)
	return request


json_value* jsonrpc_notification_new(char* method, json_value* params):
	json_value* request = json_object()
	json_object_set(request, c"jsonrpc", json_string(c"2.0"))
	json_object_set(request, c"method", json_string(method))
	if (params != 0):
		json_object_set(request, c"params", params)
	return request


/* Wire IO. */

# Serializes value and writes it as one framed message.
# Does not free value. Returns bytes written or a negative errno.
int jsonrpc_write_value(int fd, json_value* value):
	char* text = json_stringify(value)
	int written = frame_write_cstr(fd, text)
	free(text)
	return written


# Builds, writes, and frees a request in one call.
int jsonrpc_write_request(int fd, int id, char* method, json_value* params):
	json_value* request = jsonrpc_request_new(id, method, params)
	int written = jsonrpc_write_value(fd, request)
	json_free(request)
	return written


int jsonrpc_write_notification(int fd, char* method, json_value* params):
	json_value* request = jsonrpc_notification_new(method, params)
	int written = jsonrpc_write_value(fd, request)
	json_free(request)
	return written


# Reads one framed message and parses it. Returns an owned tree, or 0 on
# EOF, framing error, or malformed JSON.
json_value* jsonrpc_read_message(frame_reader* r):
	int length = 0
	char* body = frame_read_message(r, &length)
	if (body == 0):
		return 0
	json_value* message = json_parse(body)
	free(body)
	return message


/* Server. */

jsonrpc_server* jsonrpc_server_new():
	jsonrpc_server* s = new jsonrpc_server()
	s.handlers = hash_map_new()
	s.context = 0
	s.running = 0
	return s


void jsonrpc_server_free(jsonrpc_server* s):
	hash_map_free(s.handlers)
	free(s)


void jsonrpc_register(jsonrpc_server* s, char* method, jsonrpc_handler* handler):
	hash_map_set(s.handlers, method, cast(int, handler))


# Handlers may call this (via context) to make serve loops return.
void jsonrpc_stop(jsonrpc_server* s):
	s.running = 0


void jsonrpc_respond_error(int out_fd, json_value* id, int code, char* message):
	json_value* response = jsonrpc_response_error(id, code, message)
	jsonrpc_write_value(out_fd, response)
	json_free(response)


# Parses and dispatches one message body, writing any response to out_fd.
void jsonrpc_handle_body(jsonrpc_server* s, char* body, int out_fd):
	json_value* message = json_parse(body)
	if (message == 0):
		jsonrpc_respond_error(out_fd, 0, jsonrpc_error_parse(), c"parse error")
		return
	if (message.type != json_type_object()):
		jsonrpc_respond_error(out_fd, 0, jsonrpc_error_invalid_request(), c"request must be an object")
		json_free(message)
		return

	json_value* id = json_object_get(message, c"id")
	int has_id = json_object_has(message, c"id")

	json_value* version = json_object_get(message, c"jsonrpc")
	int version_ok = 0
	if (version != 0):
		if (version.type == json_type_string()):
			if (strcmp(version.string_value, c"2.0") == 0):
				version_ok = 1
	json_value* method = json_object_get(message, c"method")
	int method_ok = 0
	if (method != 0):
		if (method.type == json_type_string()):
			method_ok = 1
	if ((version_ok == 0) | (method_ok == 0)):
		jsonrpc_respond_error(out_fd, id, jsonrpc_error_invalid_request(), c"invalid request")
		json_free(message)
		return

	jsonrpc_handler* handler = cast(jsonrpc_handler*, hash_map_get_default(s.handlers, method.string_value, 0))
	if (cast(int, handler) == 0):
		if (has_id):
			jsonrpc_respond_error(out_fd, id, jsonrpc_error_method_not_found(), c"method not found")
		json_free(message)
		return

	json_value* params = json_object_get(message, c"params")
	json_value* result = handler(params, s.context)
	if (has_id):
		if (result == 0):
			jsonrpc_respond_error(out_fd, id, jsonrpc_error_internal(), c"internal error")
		else:
			json_value* response = jsonrpc_response_result(id, result)
			jsonrpc_write_value(out_fd, response)
			json_free(response)
	else:
		# Notification: any result is discarded.
		json_free(result)
	json_free(message)


# Reads framed messages from in_fd and dispatches until EOF or
# jsonrpc_stop(). Returns 0 on clean shutdown, -1 on a framing error.
int jsonrpc_serve_blocking(jsonrpc_server* s, int in_fd, int out_fd):
	frame_reader* r = frame_reader_new(in_fd)
	s.running = 1
	int status = 0
	while (s.running):
		int length = 0
		char* body = frame_read_message(r, &length)
		if (body == 0):
			if (r.error):
				status = -1
			break
		jsonrpc_handle_body(s, body, out_fd)
		free(body)
	frame_reader_free(r)
	return status
