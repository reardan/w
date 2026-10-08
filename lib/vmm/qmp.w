# Serialized, deadline-bounded QMP over a private UNIX socket. Migration
# uses SCM_RIGHTS/getfd, never a shell command or caller-controlled URI.
import lib.vmm.channel
import lib.json_rpc


json_value* box_qmp_read(int fd, int deadline):
	string_builder* line = string_new()
	json_value* value = 0
	while (line.length < 65536):
		char ch
		if (box_channel_io(fd, &ch, 1, 0, 1, deadline) == 0): break
		if (ch == 10):
			value = json_parse(line.data)
			break
		string_append_char(line, ch)
	string_free(line)
	return value


json_value* box_qmp_call(int fd, char* command, json_value* arguments, int passed_fd, int deadline):
	json_value* request = json_object()
	json_object_set(request, c"execute", json_string(command))
	json_object_set(request, c"id", json_int(1))
	if (arguments != 0): json_object_set(request, c"arguments", json_clone(arguments))
	char* body = json_stringify(request)
	json_free(request)
	int length = strlen(body)
	int sent = 0
	if (passed_fd >= 0):
		char[56] message
		char[16] iov
		char[24] control
		mem_fill[char](&message[0], 0, 56)
		mem_fill[char](&control[0], 0, 24)
		save_int64(&iov[0], cast(int, body))
		save_int64(&iov[8], length)
		save_int64(&control[0], 20)
		save_int32(&control[8], 1) # SOL_SOCKET
		save_int32(&control[12], 1) # SCM_RIGHTS
		save_int32(&control[16], passed_fd)
		save_int64(&message[16], cast(int, &iov[0]))
		save_int64(&message[24], 1)
		save_int64(&message[32], cast(int, &control[0]))
		save_int64(&message[40], 24)
		while (1):
			sent = syscall(46, fd, cast(int, &message[0]), 16384)
			if (sent != -4 && sent != -11): break
			if (deadline <= process_monotonic_ms()): break
			poll_single(fd, poll_out, 1)
	int ok = sent >= 0
	if (ok): ok = box_channel_io(fd, body + sent, length - sent, 1, 1, deadline)
	free(body)
	if (ok): ok = box_channel_io(fd, c"\n", 1, 1, 1, deadline)
	if (ok == 0): return 0
	# Events may precede the reply; bound both their count and total time.
	for i in range(128):
		json_value* response = box_qmp_read(fd, deadline)
		if (response == 0): return 0
		json_value* id = json_object_get(response, c"id")
		if (id != 0 && id.type == json_type_int() && id.int_value == 1):
			json_value* result = json_object_get(response, c"return")
			json_value* copy = 0
			if (result != 0): copy = json_clone(result)
			json_free(response)
			return copy
		json_free(response)
	return 0


int box_qmp_simple(int fd, char* command, int deadline):
	json_value* response = box_qmp_call(fd, command, 0, -1, deadline)
	int ok = response != 0
	json_free(response)
	return ok


int box_qmp_ignore_shared(int fd, int enabled, int deadline):
	json_value* capability = json_object()
	json_object_set(capability, c"capability", json_string(c"x-ignore-shared"))
	json_object_set(capability, c"state", json_bool(enabled))
	json_value* capabilities = json_array()
	json_array_push(capabilities, capability)
	json_value* args = json_object()
	json_object_set(args, c"capabilities", capabilities)
	json_value* response = box_qmp_call(fd, c"migrate-set-capabilities", args, -1, deadline)
	int ok = response != 0
	json_free(response)
	json_free(args)
	return ok


int box_qmp_is_paused(int fd, int deadline):
	json_value* response = box_qmp_call(fd, c"query-status", 0, -1, deadline)
	json_value* status = json_object_get(response, c"status")
	int paused = status != 0 && status.type == json_type_string() && strcmp(status.string_value, c"paused") == 0
	json_free(response)
	return paused


int box_qmp_open(char* path, int deadline):
	int fd = -1
	while (deadline > process_monotonic_ms()):
		fd = socket_connect_unix_path(path)
		if (fd >= 0): break
		process_sleep_ms(5)
	if (fd < 0): return -1
	sys_fcntl(fd, 2, 1)
	socket_set_nonblocking(fd)
	json_value* greeting = box_qmp_read(fd, deadline)
	int ok = 0
	if (greeting != 0): ok = json_object_get(greeting, c"QMP") != 0
	json_free(greeting)
	if (ok): ok = box_qmp_simple(fd, c"qmp_capabilities", deadline)
	if (ok): return fd
	close(fd)
	return -1


int box_qmp_migrate(int fd, int image_fd, int incoming, int deadline):
	json_value* args = json_object()
	json_object_set(args, c"fdname", json_string(c"wvm-state"))
	json_value* response = box_qmp_call(fd, c"getfd", args, image_fd, deadline)
	json_free(args)
	if (response == 0): return 0
	json_free(response)
	args = json_object()
	json_object_set(args, c"uri", json_string(c"fd:wvm-state"))
	char* command = c"migrate"
	if (incoming): command = c"migrate-incoming"
	response = box_qmp_call(fd, command, args, -1, deadline)
	json_free(args)
	if (response == 0): return 0
	json_free(response)
	while (deadline > process_monotonic_ms()):
		response = box_qmp_call(fd, c"query-migrate", 0, -1, deadline)
		if (response == 0): return 0
		json_value* status = json_object_get(response, c"status")
		int done = 0
		int failed = 0
		if (status != 0 && status.type == json_type_string()):
			done = strcmp(status.string_value, c"completed") == 0
			failed = strcmp(status.string_value, c"failed") == 0 || strcmp(status.string_value, c"cancelled") == 0
		json_free(response)
		if (done): return 1
		if (failed): return 0
		process_sleep_ms(5)
	return 0
