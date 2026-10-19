# Shared bounded POSIX RPC and evidence helpers for the native Darwin VM gate.
import tools.host_report
import tools.mac.vm_source_identity
import lib.net
import libs.standard.cli.argparse

void vm_native():
	ht_require(strcmp(vm_command(c"uname -s"), c"Darwin") == 0 && strcmp(vm_command(c"uname -m"), c"arm64") == 0, c"native Apple Silicon macOS required; measurements cannot be skipped")

int vm_connect(char* path, int timeout = 5000):
	int fd = socket_unix_stream()
	ht_require(fd >= 0, c"cannot create RPC channel")
	socket_set_recv_timeout(fd, timeout)
	socket_set_send_timeout(fd, timeout)
	ht_require(socket_connect_unix(fd, path) == 0, strjoin(c"cannot connect to ", path))
	return fd

void vm_send(int fd, char* text, int length):
	int sent = 0
	while (sent < length):
		int size = socket_send(fd, text + sent, length - sent, msg_nosignal())
		ht_require(size > 0, c"RPC send failed or timed out")
		sent = sent + size

json_value* vm_rpc(char* path, char* method, json_value* params = 0):
	if (params == 0): params = json_object()
	json_value* request = json_parse(c"{\"jsonrpc\":\"2.0\",\"id\":31}")
	vj_s(request, c"method", method)
	json_object_set(request, c"params", params)
	char* body = json_stringify(request)
	char* frame = strjoin(strjoin(c"Content-Length: ", itoa(strlen(body))), strjoin(c"\r\n\r\n", body))
	int fd = vm_connect(path)
	vm_send(fd, frame, strlen(frame))
	string_builder* header = string_new()
	char ch = 0
	int deadline = process_monotonic_ms() + 5000
	while (!contains(header.data, c"\r\n\r\n")):
		ht_require(process_monotonic_ms() < deadline && header.length < 16384 && socket_recv(fd, &ch, 1, 0) == 1, c"closed, oversized or timed out RPC header")
		string_append_char(header, ch)
	ht_require(starts_with(header.data, c"Content-Length: "), c"invalid RPC frame header")
	int length = atoi(header.data + 16)
	ht_require(length > 0 && length <= 16384, c"unbounded RPC response")
	string_builder* response = string_new_sized(length + 1)
	int received = 0
	while (received < length):
		int size = socket_recv(fd, response.data + received, length - received, 0)
		ht_require(size > 0 && process_monotonic_ms() < deadline, c"truncated or timed out RPC response")
		received = received + size
	response.data[length] = 0
	close(fd)
	json_value* envelope = json_parse(response.data)
	ht_require(strcmp(ht_text(envelope, c"jsonrpc"), c"2.0") == 0 && ht_number(envelope, c"id") == 31, c"RPC envelope mismatch")
	return ht_field(envelope, c"result")

json_value* vm_ok(char* path, char* method, json_value* params = 0):
	json_value* result = vm_rpc(path, method, params)
	ht_require(!json_object_has(result, c"error"), json_stringify(result))
	return result

json_value* vm_state(char* path, char* session, char* allowed = 0, int timeout = 8000):
	if (allowed == 0): allowed = c"ready"
	int deadline = process_monotonic_ms() + timeout
	while (process_monotonic_ms() < deadline):
		json_value* state = vm_ok(path, c"vm_status", vj_one(c"session", session))
		for char* value in ht_split(allowed, ' '):
			if (strcmp(ht_text(state, c"state"), value) == 0): return state
		process_sleep_ms(10)
	ht_require(0, strjoin(c"session did not reach state ", allowed))
	return 0

hm_sample* vm_start(char* daemon, char* worker, char* path, int active = 1, int pending = 2, int inherited = -1):
	list[char*] command = ht_argv(daemon, c"serve", c"--socket", path, c"--worker", worker, c"--max-active", itoa(active), c"--max-pending", itoa(pending))
	command.push(c"--memory-mb")
	command.push(c"2048")
	hm_sample* process = hm_start(command, 0, 0, -1, inherited)
	int deadline = process_monotonic_ms() + 10000
	while (!path_exists(path)):
		ht_require(process_try_wait(process.child) == process_status_running && process_monotonic_ms() < deadline, c"daemon startup failed or timed out")
		process_sleep_ms(1)
	return process

json_value* vm_image(char* image, int lease = 60000):
	json_value* params = vj_one(c"backend", c"cell")
	vj_s(params, c"image", image)
	vj_i(params, c"lease_ms", lease)
	return params
json_value* vm_template(char* template_id):
	json_value* params = vj_one(c"backend", c"cell")
	vj_s(params, c"template", template_id)
	vj_i(params, c"lease_ms", 60000)
	return params
json_value* vm_exec(char* path, char* session, char* mode, int timeout = 1000, int limit = 65536, char* input_hex = 0):
	json_value* params = vj_one(c"session", session)
	json_object_set(params, c"argv", vj_strings(ht_argv(c"cell", mode)))
	vj_i(params, c"timeout_ms", timeout)
	vj_i(params, c"output_limit", limit)
	if (input_hex != 0): vj_s(params, c"stdin_hex", input_hex)
	json_value* result = vm_ok(path, c"vm_exec", params)
	ht_require(json_object_has(result, c"command"), c"missing command id")
	return result
json_value* vm_execute(char* path, char* session, char* mode, int status = 0, char* text = 0, int timeout = 1000, char* input_hex = 0):
	if (text == 0): text = c""
	vm_exec(path, session, mode, timeout, 65536, input_hex)
	json_value* state = vm_state(path, session, c"ready failed")
	ht_require(strcmp(ht_text(state, c"state"), c"ready") == 0, c"worker failed")
	json_value* params = vj_one(c"session", session)
	vj_i(params, c"length", 2048)
	json_value* result = vm_ok(path, c"vm_result", params)
	ht_require(ht_number(result, c"status") == status, json_stringify(result))
	int length = 0
	char* stdout_hex = ht_text(result, c"stdout_hex")
	char* decoded = hex_decode(stdout_hex, strlen(stdout_hex), &length)
	ht_require(decoded != 0 && contains(decoded, text), c"guest stdout mismatch")
	return result

json_value* vm_quantiles(list[int] values, char* unit = 0, int median = 1):
	if (unit == 0): unit = c"ms"
	ht_require(values.length > 0, c"missing measurements")
	values.sort()
	json_value* result = json_object()
	vj_i(result, c"samples", values.length)
	for char* p in ht_command(c"50 95 99"):
		int rank = (values.length * atoi(p) + 99) / 100 - 1
		float value = cast(float, values[rank])
		if (median && atoi(p) == 50 && values.length % 2 == 0): value = (cast(float, values[values.length / 2 - 1]) + cast(float, values[values.length / 2])) / 2.0
		if (strcmp(unit, c"ms") == 0): value = value / 1000000.0
		vj_f(result, strjoin(strjoin(c"p", p), strjoin(c"_", unit)), value)
	return result
