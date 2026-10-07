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
	socket_set_nosigpipe(fd)
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
		int count = sys_sendto(fd, wire.data + sent, wire.length - sent, msg_nosignal(), 0, 0)
		if (count == 0 - net_eagain() || count == -4): continue
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
		if (count == 0 - net_eagain() || count == -4): continue
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


# Owned result or null, including daemon-level errors inside the envelope.
json_value* wvm_client_result(char* socket_path, char* method, json_value* params, int timeout_ms):
	json_value* envelope = wvm_client_call(socket_path, method, params, timeout_ms)
	if (envelope == 0): return 0
	json_value* result = json_object_get(envelope, c"result")
	json_value* copy = 0
	if (result != 0 && result.type == json_type_object()):
		if (json_object_get(result, c"error") == 0): copy = json_clone(result)
	json_free(envelope)
	return copy


void wvm_client_destroy(char* socket_path, int session):
	json_value* params = wvm_client_session_params(session)
	json_value* result = wvm_client_result(socket_path, c"vm_destroy", params, 2000)
	json_free(params)
	json_free(result)


int wvm_client_ready(json_value* result):
	if (result == 0): return 0
	json_value* state = json_object_get(result, c"state")
	return state != 0 && state.type == json_type_string() && strcmp(state.string_value, c"ready") == 0


int wvm_client_open(char* socket_path, json_value* config, int timeout_ms):
	if (timeout_ms < 1 || timeout_ms > 600000): return 0
	int deadline = process_monotonic_ms() + timeout_ms
	json_value* result = wvm_client_result(socket_path, c"vm_spawn", config, timeout_ms)
	if (result == 0): return 0
	json_value* id = json_object_get(result, c"session")
	int session = 0
	if (id != 0 && id.type == json_type_int()): session = id.int_value
	json_free(result)
	if (session < 1): return 0
	json_value* params = wvm_client_session_params(session)
	int ready = 0
	while (deadline > process_monotonic_ms()):
		result = wvm_client_result(socket_path, c"vm_status", params, deadline - process_monotonic_ms())
		if (result == 0): break
		ready = wvm_client_ready(result)
		json_value* state = json_object_get(result, c"state")
		int failed = state != 0 && state.type == json_type_string() && strcmp(state.string_value, c"failed") == 0
		json_free(result)
		if (ready || failed): break
		process_sleep_ms(10)
	json_free(params)
	if (ready): return session
	wvm_client_destroy(socket_path, session)
	return 0


int wvm_client_unhex(char* output, char* hex, int length):
	for i in range(length):
		int value = 0
		for j in range(2):
			int ch = cast(int, hex[i * 2 + j])
			int digit = -1
			if (ch >= '0' && ch <= '9'): digit = ch - '0'
			if (ch >= 'a' && ch <= 'f'): digit = ch - 'a' + 10
			if (digit < 0): return 0
			value = value * 16 + digit
		output[i] = cast(char, value)
	return 1


# Synchronous harness bridge. One command owner per session. Any uncertain
# transport, deadline or output destroys the session; never execute locally.
process_result* wvm_client_exec_wait(char* socket_path, int session, char** argv, char* cwd, int timeout_ms, int output_limit):
	if (timeout_ms < 1 || timeout_ms > 600000 || output_limit < 1 || output_limit > 1048576): return 0
	int deadline = process_monotonic_ms() + timeout_ms + 5000
	json_value* params = wvm_client_exec_params(session, argv, cwd, timeout_ms, output_limit)
	json_value* result = wvm_client_result(socket_path, c"vm_exec", params, 2000)
	json_free(params)
	int ok = result != 0
	int command = -1
	if (ok):
		json_value* id = json_object_get(result, c"command")
		if (id != 0 && id.type == json_type_int()): command = id.int_value
	json_free(result)
	if (command < 1): ok = 0
	process_result* output = new process_result()
	mem_fill[char](cast(char*, output), 0, sizeof(process_result))
	output.status = -3
	output.stdout_text = cast(char*, malloc(output_limit + 1))
	output.stderr_text = cast(char*, malloc(output_limit + 1))
	output.stdout_text[0] = 0
	output.stderr_text[0] = 0
	int offset = 0
	int complete = 0
	params = wvm_client_session_params(session)
	json_object_set(params, c"length", json_int(2048))
	while (ok && complete == 0 && deadline > process_monotonic_ms()):
		json_object_set(params, c"offset", json_int(offset))
		int remaining = deadline - process_monotonic_ms()
		if (remaining > 2000): remaining = 2000
		result = wvm_client_result(socket_path, c"vm_result", params, remaining)
		if (result == 0):
			ok = 0
			break
		if (wvm_client_ready(result)):
			json_value* id = json_object_get(result, c"command")
			json_value* status = json_object_get(result, c"status")
			if (id == 0 || id.type != json_type_int() || id.int_value != command || status == 0 || status.type != json_type_int()): ok = 0
			if (ok): output.status = status.int_value
			int maximum = 0
			for i in range(2):
				char* key = c"stdout_hex"
				char* size_key = c"stdout_hex_bytes"
				char* data = output.stdout_text
				if (i == 1):
					key = c"stderr_hex"
					size_key = c"stderr_hex_bytes"
					data = output.stderr_text
				json_value* hex = json_object_get(result, key)
				json_value* size = json_object_get(result, size_key)
				if (hex == 0 || hex.type != json_type_string() || size == 0 || size.type != json_type_int()):
					ok = 0
					break
				int total = size.int_value
				if (total < 0 || total > output_limit):
					ok = 0
					break
				int count = total - offset
				if (count < 0): count = 0
				if (count > 2048): count = 2048
				if (strlen(hex.string_value) != count * 2): ok = 0
				else if (count > 0):
					if (wvm_client_unhex(data + offset, hex.string_value, count) == 0): ok = 0
				data[total] = 0
				if (i == 0): output.stdout_length = total
				else: output.stderr_length = total
				if (total > maximum): maximum = total
			offset = offset + 2048
			if (offset >= maximum): complete = 1
		else:
			json_value* state = json_object_get(result, c"state")
			if (state == 0 || state.type != json_type_string() || strcmp(state.string_value, c"busy") != 0): ok = 0
			process_sleep_ms(10)
		json_free(result)
	json_free(params)
	if (ok == 0 || complete == 0):
		wvm_client_destroy(socket_path, session)
		process_result_free(output)
		return 0
	return output
