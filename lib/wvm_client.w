# Explicit local daemon client for agent harnesses. No auto-launch or host
# execution fallback. Calls return an owned JSON-RPC envelope, or 0 on
# timeout/transport failure. Params stay owned by the caller.
import lib.json_rpc
import lib.process


json_value* wvm_client_call(char* socket_path, char* method, json_value* params, int timeout_ms):
	if (timeout_ms < 1 || timeout_ms > 600000): return 0
	int fd = socket_unix_stream()
	if (fd < 0): return 0
	socket_set_nonblocking(fd)
	if (socket_connect_unix(fd, socket_path) < 0):
		close(fd)
		return 0
	json_value* request = jsonrpc_request_new(1, method, json_clone(params))
	char* body = json_stringify(request)
	json_free(request)
	int length = strlen(body)
	if (length > 8192):
		free(body)
		close(fd)
		return 0
	string_builder* wire = string_new()
	string_append(wire, c"Content-Length: ")
	string_append_int(wire, length)
	string_append(wire, c"\r\n\r\n")
	string_append(wire, body)
	free(body)
	int deadline = process_monotonic_ms() + timeout_ms
	int sent = 0
	int failed = 0
	while (sent < wire.length && failed == 0):
		int remaining = deadline - process_monotonic_ms()
		if (remaining <= 0):
			failed = 1
			break
		int events = poll_single(fd, poll_out, remaining)
		if (events == -4): continue
		if (events <= 0):
			failed = 1
			break
		# MSG_NOSIGNAL: disconnected daemon must not kill its client.
		int count = sys_sendto(fd, wire.data + sent, wire.length - sent, 16384, 0, 0)
		if (count == -11 || count == -4): continue
		if (count <= 0): failed = 1
		else: sent = sent + count
	string_free(wire)
	frame_reader* reader = frame_reader_new(fd)
	json_value* response = 0
	while (failed == 0 && response == 0):
		int remaining = deadline - process_monotonic_ms()
		if (remaining <= 0): break
		int events = poll_single(fd, poll_in, remaining)
		if (events == -4): continue
		if (events <= 0): break
		int count = frame_reader_fill(reader)
		if (count == -11 || count == -4): continue
		if (count <= 0 || reader.length > 32768): break
		int end = frame_find_header_end(reader)
		if (end < 0):
			if (reader.length > 512): break
			continue
		# The daemon is same-user trusted. Bound the complete frame and
		# reject absurd headers before passing to the shared parser.
		if (end > 512): break
		int body_length = frame_parse_content_length(reader, end)
		if (body_length < 1 || body_length > 16384): break
		int received = 0
		char* answer = frame_take_buffered_message(reader, &received)
		if (answer != 0):
			response = json_parse(answer)
			free(answer)
		if (reader.error): break
	frame_reader_free(reader)
	close(fd)
	return response


json_value* wvm_client_session_params(int session):
	json_value* params = json_object()
	json_object_set(params, c"session", json_int(session))
	return params


json_value* wvm_client_exec_params(int session, char** argv, char* cwd, int timeout_ms, int output_limit):
	json_value* params = wvm_client_session_params(session)
	json_value* args = json_array()
	int at = 0
	while (argv[at] != 0):
		json_array_push(args, json_string(argv[at]))
		at = at + 1
	json_object_set(params, c"argv", args)
	if (cwd != 0): json_object_set(params, c"cwd", json_string(cwd))
	json_object_set(params, c"timeout_ms", json_int(timeout_ms))
	json_object_set(params, c"output_limit", json_int(output_limit))
	return params
