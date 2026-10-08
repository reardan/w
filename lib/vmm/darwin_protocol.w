# Darwin control helpers. No VM is created by importing this module.
import lib.vmm.protocol
import lib.vmm.darwin_hv
import lib.net

c_lib "/usr/lib/libSystem.B.dylib"
extern int dvm_signal(int number, int handler) = "signal"
extern int dvm_umask(int mask) = "umask"
extern int dvm_chmod(char* path, int mode) = "chmod"

c_lib "/usr/lib/libproc.dylib"
extern int dvm_proc_pidinfo(int pid, int flavor, int arg, char* buffer, int length) = "proc_pidinfo"


json_value* dvm_capabilities():
	json_value* result = json_object()
	json_object_set(result, c"protocol", json_int(1))
	json_object_set(result, c"host_backend", json_string(c"hypervisor.framework"))
	json_object_set(result, c"guest_arch", json_string(c"arm64"))
	json_object_set(result, c"guest_abi", json_string(c"linux-aarch64"))
	json_object_set(result, c"guest_image", json_string(c"static-elf64-et-exec"))
	json_object_set(result, c"host_page_size", json_int(dhv_getpagesize()))
	json_object_set(result, c"guest_page_size", json_int(4096))
	json_object_set(result, c"vcpus", json_int(1))
	json_object_set(result, c"ready_templates", json_bool(1))
	json_object_set(result, c"private_clones", json_bool(1))
	json_object_set(result, c"reset", json_bool(1))
	json_object_set(result, c"host_quotas", json_bool(0))
	json_object_set(result, c"live_checkpoints", json_bool(0))
	json_object_set(result, c"debugger", json_bool(0))
	json_object_set(result, c"shared_regions", json_bool(0))
	json_object_set(result, c"boxes", json_bool(0))
	json_object_set(result, c"filesystem", json_bool(0))
	json_object_set(result, c"network", json_bool(0))
	return result


# Whitespace-separated known keys; reject unsupported flags even if false.
int dvm_keys(json_value* params, char* allowed):
	if (params == 0 || params.type != json_type_object()): return 0
	for char* key, json_value* member in params.object_values:
		int found = 0
		int at = 0
		while (allowed[at] != 0):
			while (allowed[at] == ' '): at = at + 1
			int start = at
			while (allowed[at] != 0 && allowed[at] != ' '): at = at + 1
			int length = at - start
			if (strlen(key) == length):
				int same = 1
				for i in range(length):
					if (key[i] != allowed[start + i]): same = 0
				if (same): found = 1
		if (found == 0): return 0
	return 1


char* dvm_hex(char* data, int length):
	char* out = cast(char*, malloc(length * 2 + 1))
	char* digits = c"0123456789abcdef"
	for i in range(length):
		int ch = cast(int, data[i]) & 255
		out[i * 2] = digits[ch >> 4]
		out[i * 2 + 1] = digits[ch & 15]
	out[length * 2] = 0
	return out


# One bounded frame. The caller decides whether an incomplete read is EOF.
json_value* dvm_take(frame_reader* reader, int maximum):
	char* body = vms_take_frame(reader, maximum)
	if (body == 0): return 0
	json_value* result = 0
	if (vms_json_safe(body)): result = json_parse(body)
	free(body)
	if (result == 0): reader.error = 1
	return result


int dvm_send(int fd, json_value* value):
	# Control channels use small writes; nonblocking EAGAIN is a failed
	# connection, never an unbounded wait on an abandoned client.
	char* body = json_stringify(value)
	int rc = frame_write_cstr(fd, body)
	free(body)
	return rc >= 0


json_value* dvm_read_deadline(frame_reader* reader, int maximum, int timeout_ms):
	int deadline = dhv_now_ms() + timeout_ms
	while (dhv_now_ms() < deadline):
		json_value* result = dvm_take(reader, maximum)
		if (result != 0 || reader.error): return result
		int remaining = deadline - dhv_now_ms()
		if (remaining <= 0): break
		int ready = poll_single(reader.fd, poll_in, remaining)
		if (ready == -4): continue
		if (ready <= 0): break
		int got = frame_reader_fill(reader)
		if (got == -4 || got == 0 - net_eagain()): continue
		if (got <= 0): break
	return 0


# Only stdio and one explicitly supplied read-only backing fd survive exec.
# The daemon never initializes HV state, so this fork precedes HV creation.
process* dvm_worker_spawn(char* executable, int backing_fd):
	int saved = sys_fcntl(backing_fd, 0, 10) # F_DUPFD; avoid stdio/pipe overlap
	if (saved < 0): return 0
	sys_fcntl(saved, 2, 1)
	int in_read = -1
	int in_write = -1
	int out_read = -1
	int out_write = -1
	int ok = process_make_pipe(&in_read, &in_write) == 0
	if (ok): ok = process_make_pipe(&out_read, &out_write) == 0
	# Enumerate actual descriptors, including inherited handles above a lowered
	# RLIMIT_NOFILE. Parent has no threads/VM, so the set stays stable here.
	char* descriptors = cast(char*, malloc(524288))
	int descriptor_bytes = dvm_proc_pidinfo(getpid(), 1, 0, descriptors, 524288) & 2147483647
	if (descriptor_bytes <= 0 || descriptor_bytes >= 524288 || descriptor_bytes % 8 != 0): ok = 0
	int pid = -1
	if (ok): pid = fork()
	if (pid == 0):
		setpgid(0, 0)
		close(in_write)
		close(out_read)
		process_redirect(in_read, 0)
		process_redirect(out_write, 1)
		process_redirect_null(2, 1)
		if (dup2(saved, 3) < 0): exit(127)
		sys_fcntl(3, 2, 0)
		for i in range(descriptor_bytes / 8):
			int fd = load_int32(descriptors + i * 8)
			if (fd > 3): close(fd)
		char** args = strv_new(2)
		strv_set(args, 0, executable)
		strv_set(args, 1, c"worker")
		# No host secrets in the worker environment; the guest has its own.
		char** environment = strv_new(0)
		execve(executable, args, environment)
		exit(127)
	free(descriptors)
	close(saved)
	process_close_fd_if_open(in_read)
	process_close_fd_if_open(out_write)
	if (pid < 0):
		process_close_fd_if_open(in_write)
		process_close_fd_if_open(out_read)
		return 0
	setpgid(pid, pid)
	process* result = new process()
	mem_fill[char](cast(char*, result), 0, sizeof(process))
	result.pid = pid
	result.stdin_fd = in_write
	result.stdout_fd = out_read
	result.stderr_fd = -1
	socket_set_nonblocking(in_write)
	socket_set_nonblocking(out_read)
	return result


# Worker output may exceed pipe capacity. Poll/drain against a monotonic
# deadline so a stopped/nonreading parent cannot retain a worker forever.
int dvm_send_bounded(int fd, json_value* value, int timeout_ms):
	char* body = json_stringify(value)
	string_builder* wire = string_from(c"Content-Length: ")
	string_append_int(wire, strlen(body))
	string_append(wire, c"\r\n\r\n")
	string_append(wire, body)
	free(body)
	int flags = sys_fcntl(fd, 3, 0)
	if (flags < 0):
		string_free(wire)
		return 0
	socket_set_nonblocking(fd)
	int deadline = dhv_now_ms() + timeout_ms
	int sent = 0
	while (sent < wire.length):
		int left = deadline - dhv_now_ms()
		if (left <= 0): break
		int ready = poll_single(fd, poll_out, left)
		if (ready == -4): continue
		if (ready <= 0): break
		int count = write(fd, wire.data + sent, wire.length - sent)
		if (count == -4 || count == 0 - net_eagain()): continue
		if (count <= 0): break
		sent = sent + count
	int ok = sent == wire.length
	sys_fcntl(fd, 4, flags)
	string_free(wire)
	return ok
