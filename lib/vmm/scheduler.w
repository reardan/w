# Linux x64 session scheduler. Every session owns a separate process group.
# CPU/RAM are admission reservations, not cgroup host-resource quotas.
import lib.process
import lib.json_rpc
import lib.time
import lib.vmm.registry

const int vms_queued = 0
const int vms_booting = 1
const int vms_ready = 2
const int vms_busy = 3
const int vms_failed = 4

type vms_worker = fn(json_value*) -> void

struct vms_session:
	int id
	int state
	int pid
	int input_fd
	frame_reader* reader
	json_value* config
	json_value* result
	int cpus
	int memory_mb
	int lease_deadline
	int operation_deadline
	int submitted_ms
	int ready_ms
	int commands
	int status
	vm_workspace* workspace
	char* channel_directory
	int disk_mb

struct vm_scheduler:
	list[vms_session*] sessions
	int next_id
	vm_registry* registry
	int max_active
	int max_pending
	int max_cpus
	int max_memory_mb
	int active
	int queued
	int cpus
	int memory_mb
	int disk_mb
	int max_disk_mb
	int spawned
	int completed
	int failures
	int expired
	int cleanup_failures
	vms_worker* worker


json_value* vms_field(json_value* object, char* key):
	if (object == 0 || object.type != json_type_object()): return 0
	return json_object_get(object, key)


int vms_number(json_value* object, char* key, int fallback):
	json_value* value = vms_field(object, key)
	if (value == 0): return fallback
	if (value.type != json_type_int()): return -1
	return value.int_value


char* vms_text(json_value* object, char* key):
	json_value* value = vms_field(object, key)
	if (value == 0 || value.type != json_type_string()): return 0
	return value.string_value


json_value* vms_error(char* message):
	json_value* value = json_object()
	json_object_set(value, c"error", json_string(message))
	return value


vm_scheduler* vms_new(int active, int pending, int cpus, int memory_mb, vms_worker* worker):
	if (__word_size__ != 8 || active < 1 || active > 128 || pending < 0 || pending > 128 || cpus < 1 || memory_mb < 64): return 0
	vm_scheduler* scheduler = new vm_scheduler()
	mem_fill[char](cast(char*, scheduler), 0, sizeof(vm_scheduler))
	scheduler.sessions = new list[vms_session*]
	scheduler.next_id = 1
	scheduler.max_active = active
	scheduler.max_pending = pending
	scheduler.max_cpus = cpus
	scheduler.max_memory_mb = memory_mb
	scheduler.max_disk_mb = 1024
	scheduler.worker = worker
	return scheduler


vms_session* vms_find(vm_scheduler* scheduler, int id):
	for i in range(scheduler.sessions.length):
		vms_session* session = scheduler.sessions[i]
		if (session != 0 && session.id == id): return session
	return 0


int vms_admitted(vm_scheduler* scheduler, vms_session* session):
	return scheduler.active < scheduler.max_active && session.cpus <= scheduler.max_cpus - scheduler.cpus && session.memory_mb <= scheduler.max_memory_mb - scheduler.memory_mb && session.disk_mb <= scheduler.max_disk_mb - scheduler.disk_mb


# Admission is FIFO. Completed entries still occupy bounded table slots until
# destroy or lease expiry, preventing clients from retaining unbounded output.
json_value* vms_submit(vm_scheduler* scheduler, json_value* config):
	if (config == 0 || config.type != json_type_object()): return vms_error(c"configuration must be an object")
	int disk_mb = 0
	if (vms_text(config, c"workspace") != 0): disk_mb = vms_number(config, c"workspace_mb", 64)
	if ((vms_text(config, c"workspace") != 0 && disk_mb < 1) || disk_mb < 0 || disk_mb > scheduler.max_disk_mb || disk_mb > 1024): return vms_error(c"workspace exceeds preparation disk capacity")
	int cpus = vms_number(config, c"cpus", 1)
	int memory_mb = vms_number(config, c"memory_mb", 256)
	int lease_ms = vms_number(config, c"lease_ms", 60000)
	int timeout_ms = vms_number(config, c"timeout_ms", 30000)
	if (cpus < 1 || cpus > 64 || cpus > scheduler.max_cpus || memory_mb < 64 || memory_mb > 32768 || memory_mb > scheduler.max_memory_mb): return vms_error(c"session exceeds CPU or memory capacity")
	if (lease_ms < 100 || lease_ms > 3600000 || timeout_ms < 1 || timeout_ms > 600000): return vms_error(c"invalid lease or boot timeout")
	int slot = -1
	for i in range(scheduler.sessions.length):
		if (scheduler.sessions[i] == 0 && slot < 0): slot = i
	if (slot < 0 && scheduler.sessions.length >= scheduler.max_active + scheduler.max_pending): return vms_error(c"session table full; destroy completed sessions")
	vms_session candidate
	candidate.cpus = cpus
	candidate.memory_mb = memory_mb
	candidate.disk_mb = disk_mb
	if ((scheduler.queued > 0 || vms_admitted(scheduler, &candidate) == 0) && scheduler.queued >= scheduler.max_pending): return vms_error(c"launch queue full")
	vms_session* session = new vms_session()
	mem_fill[char](cast(char*, session), 0, sizeof(vms_session))
	session.id = scheduler.next_id
	scheduler.next_id = scheduler.next_id + 1
	session.input_fd = -1
	session.config = json_clone(config)
	session.cpus = cpus
	session.memory_mb = memory_mb
	session.disk_mb = disk_mb
	session.submitted_ms = time_monotonic_ms()
	session.lease_deadline = session.submitted_ms + lease_ms
	if (slot < 0): scheduler.sessions.push(session)
	else: scheduler.sessions[slot] = session
	scheduler.queued = scheduler.queued + 1
	json_value* answer = json_object()
	json_object_set(answer, c"session", json_int(session.id))
	json_object_set(answer, c"state", json_string(c"queued"))
	return answer


void vms_release_worker(vm_scheduler* scheduler, vms_session* session):
	int cleaned = 1
	if (session.pid > 0):
		kill(0 - session.pid, sigkill)
		kill(session.pid, sigkill)
		# Confirm every descendant has stopped before deleting its files.
		# If a process remains in uninterruptible sleep, retain admission
		# reservations and the durable record so later ticks can retry.
		if (registry_group_quiet(session.pid, 2000) == 0):
			scheduler.cleanup_failures = scheduler.cleanup_failures + 1
			return
		int status = 0
		int reaped = wait4(session.pid, &status, 1, 0)
		while (reaped == -4): reaped = wait4(session.pid, &status, 1, 0)
		# Daemon is a child subreaper; reap killed QEMU descendants too.
		int descendant = wait4(0 - session.pid, &status, 1, 0)
		while (descendant > 0 || descendant == -4): descendant = wait4(0 - session.pid, &status, 1, 0)
		session.pid = 0
		scheduler.active = scheduler.active - 1
		scheduler.cpus = scheduler.cpus - session.cpus
		scheduler.memory_mb = scheduler.memory_mb - session.memory_mb
	if (session.workspace != 0):
		if (workspace_destroy(session.workspace) != 0): cleaned = 0
		session.workspace = 0
		scheduler.disk_mb = scheduler.disk_mb - session.disk_mb
	if (session.channel_directory != 0):
		if (dir_remove_all(session.channel_directory) != 0): cleaned = 0
		free(session.channel_directory)
		session.channel_directory = 0
	if (scheduler.registry != 0 && cleaned):
		if (registry_remove(scheduler.registry, session.id) == 0): cleaned = 0
	if (cleaned == 0): scheduler.cleanup_failures = scheduler.cleanup_failures + 1
	if (session.input_fd >= 0): close(session.input_fd)
	session.input_fd = -1
	if (session.reader != 0):
		close(session.reader.fd)
		frame_reader_free(session.reader)
		session.reader = 0


void vms_fail(vm_scheduler* scheduler, vms_session* session, int status):
	if (session.state == vms_queued): scheduler.queued = scheduler.queued - 1
	vms_release_worker(scheduler, session)
	session.state = vms_failed
	session.status = status
	scheduler.failures = scheduler.failures + 1


void vms_destroy(vm_scheduler* scheduler, vms_session* session):
	if (session.state == vms_queued): scheduler.queued = scheduler.queued - 1
	vms_release_worker(scheduler, session)
	if (session.pid > 0):
		session.state = vms_failed
		return
	for i in range(scheduler.sessions.length):
		if (scheduler.sessions[i] == session): scheduler.sessions[i] = 0
	json_free(session.config)
	json_free(session.result)
	free(session)


# Worker callback uses stdin/stdout exclusively for framed JSON. close_range
# is required so no daemon control sockets or other sessions' pipes leak.
void vms_launch(vm_scheduler* scheduler, vms_session* session):
	char* source = vms_text(session.config, c"workspace")
	if (source != 0):
		char* directory = c"/tmp"
		if (scheduler.registry != 0): directory = scheduler.registry.path
		session.workspace = workspace_create_in(source, directory, session.disk_mb * 1048576, 10000, 10000)
		if (session.workspace == 0):
			vms_fail(scheduler, session, 125)
			return
		scheduler.disk_mb = scheduler.disk_mb + session.disk_mb
		json_object_set(session.config, c"fs_root", json_string(session.workspace.path))
		json_object_set(session.config, c"private_workspace", json_int(1))
	char* workspace_path = 0
	if (session.workspace != 0): workspace_path = session.workspace.path
	if (scheduler.registry != 0):
		json_object_set(session.config, c"channel_directory", json_string(scheduler.registry.path))
		if (registry_record(scheduler.registry, session.id, workspace_path, 0) == 0):
			vms_fail(scheduler, session, 125)
			return
	int request_read = -1
	int request_write = -1
	int result_read = -1
	int result_write = -1
	if (process_make_pipe(&request_read, &request_write) < 0):
		vms_fail(scheduler, session, 125)
		return
	if (process_make_pipe(&result_read, &result_write) < 0):
		close(request_read)
		close(request_write)
		vms_fail(scheduler, session, 125)
		return
	int parent = getpid()
	int pid = fork()
	if (pid == 0):
		# PR_SET_PDEATHSIG, followed by parent identity check, covers death
		# between fork and prctl. This module is deliberately Linux x64.
		if (syscall7(157, 1, sigkill, 0, 0, 0, 0) < 0): exit(125)
		if (syscall(110, 0, 0, 0) != parent): exit(125)
		if (syscall(109, 0, 0, 0) < 0): exit(125)
		process_redirect(request_read, 0)
		process_redirect(result_write, 1)
		process_redirect_null(2, 1)
		int last_fd = 65535 * 65536 + 65535
		if (syscall(436, 3, last_fd, 0) < 0): exit(125)
		char gate
		if (read(0, &gate, 1) != 1): exit(125)
		scheduler.worker(session.config)
		exit(0)
	close(request_read)
	close(result_write)
	if (pid < 0):
		close(request_write)
		close(result_read)
		vms_fail(scheduler, session, 125)
		return
	syscall(109, pid, pid, 0)
	socket_set_nonblocking(result_read)
	socket_set_nonblocking(request_write)
	session.pid = pid
	session.input_fd = request_write
	session.reader = frame_reader_new(result_read)
	session.state = vms_booting
	session.operation_deadline = time_monotonic_ms() + vms_number(session.config, c"timeout_ms", 30000) + 1000
	scheduler.active = scheduler.active + 1
	scheduler.queued = scheduler.queued - 1
	scheduler.cpus = scheduler.cpus + session.cpus
	scheduler.memory_mb = scheduler.memory_mb + session.memory_mb
	scheduler.spawned = scheduler.spawned + 1
	if (scheduler.registry != 0):
		if (registry_record(scheduler.registry, session.id, workspace_path, pid) == 0):
			vms_fail(scheduler, session, 125)
			return
	if (write(session.input_fd, c"!", 1) != 1): vms_fail(scheduler, session, 125)


# Limit all control strings: json strings are C strings in this repository.
int vms_exec_valid(json_value* params):
	json_value* args = vms_field(params, c"argv")
	if (args == 0 || args.type != json_type_array()): return 0
	int count = json_array_length(args)
	if (count < 1 || count > 64): return 0
	int total = 0
	for i in range(count):
		json_value* arg = json_array_get(args, i)
		if (arg.type != json_type_string()): return 0
		total = total + strlen(arg.string_value) + 1
	if (json_array_get(args, 0).string_value[0] != '/'): return 0
	if (total > 4096): return 0
	int timeout = vms_number(params, c"timeout_ms", 30000)
	int limit = vms_number(params, c"output_limit", 65536)
	char* cwd = vms_text(params, c"cwd")
	if (cwd != 0 && strlen(cwd) > 1024): return 0
	return timeout > 0 && timeout <= 600000 && limit >= 1 && limit <= 1048576


json_value* vms_exec(vm_scheduler* scheduler, vms_session* session, json_value* params):
	if (session.state != vms_ready): return vms_error(c"session is not ready")
	if (vms_exec_valid(params) == 0): return vms_error(c"invalid argv, cwd, timeout or output limit")
	char* wire = json_stringify(params)
	int length = strlen(wire)
	if (length > 4000):
		free(wire)
		return vms_error(c"command exceeds control message limit")
	int written = frame_write_cstr(session.input_fd, wire)
	free(wire)
	if (written < 0):
		vms_fail(scheduler, session, 125)
		return vms_error(c"worker command transport failed")
	json_free(session.result)
	session.result = 0
	session.state = vms_busy
	session.status = process_status_running
	session.commands = session.commands + 1
	session.operation_deadline = time_monotonic_ms() + vms_number(params, c"timeout_ms", 30000) + 3000
	json_value* answer = json_object()
	json_object_set(answer, c"command", json_int(session.commands))
	return answer


char* vms_state_name(int state):
	if (state == vms_queued): return c"queued"
	if (state == vms_booting): return c"booting"
	if (state == vms_ready): return c"ready"
	if (state == vms_busy): return c"busy"
	return c"failed"


json_value* vms_status(vms_session* session):
	json_value* answer = json_object()
	json_object_set(answer, c"session", json_int(session.id))
	json_object_set(answer, c"state", json_string(vms_state_name(session.state)))
	json_object_set(answer, c"command", json_int(session.commands))
	json_object_set(answer, c"status", json_int(session.status))
	json_object_set(answer, c"cpus", json_int(session.cpus))
	json_object_set(answer, c"memory_mb", json_int(session.memory_mb))
	json_object_set(answer, c"lease_remaining_ms", json_int(session.lease_deadline - time_monotonic_ms()))
	if (session.ready_ms > 0): json_object_set(answer, c"launch_ms", json_int(session.ready_ms - session.submitted_ms))
	return answer


# Bounded chunks keep slow or abandoned clients from stalling the control
# loop. Hex preserves arbitrary guest bytes (including embedded NUL).
void vms_output_chunk(json_value* answer, json_value* result, char* key, int offset, int length):
	char* value = vms_text(result, key)
	if (value == 0): value = c""
	int bytes = strlen(value) / 2
	int count = bytes - offset
	if (count < 0): count = 0
	if (count > length): count = length
	char* text = malloc(count * 2 + 1)
	if (count > 0): mem_copy[char](text, value + offset * 2, count * 2)
	text[count * 2] = 0
	json_object_set(answer, key, json_string(text))
	free(text)
	char* size_key = strjoin(key, c"_bytes")
	json_object_set(answer, size_key, json_int(bytes))
	free(size_key)


json_value* vms_result(vms_session* session, json_value* params):
	int offset = vms_number(params, c"offset", 0)
	int length = vms_number(params, c"length", 1024)
	if (offset < 0 || offset > 1048576 || length < 0 || length > 2048): return vms_error(c"invalid output chunk range")
	json_value* answer = vms_status(session)
	vms_output_chunk(answer, session.result, c"stdout_hex", offset, length)
	vms_output_chunk(answer, session.result, c"stderr_hex", offset, length)
	return answer


json_value* vms_stats(vm_scheduler* scheduler):
	json_value* answer = json_object()
	json_object_set(answer, c"active", json_int(scheduler.active))
	json_object_set(answer, c"queued", json_int(scheduler.queued))
	json_object_set(answer, c"cpus", json_int(scheduler.cpus))
	json_object_set(answer, c"memory_mb", json_int(scheduler.memory_mb))
	json_object_set(answer, c"workspace_reserved_mb", json_int(scheduler.disk_mb))
	json_object_set(answer, c"spawned", json_int(scheduler.spawned))
	json_object_set(answer, c"completed_commands", json_int(scheduler.completed))
	json_object_set(answer, c"failures", json_int(scheduler.failures))
	json_object_set(answer, c"expired", json_int(scheduler.expired))
	json_object_set(answer, c"cleanup_failures", json_int(scheduler.cleanup_failures))
	int recovered = 0
	if (scheduler.registry != 0): recovered = scheduler.registry.recovered
	json_object_set(answer, c"recovered", json_int(recovered))
	return answer


void vms_receive(vm_scheduler* scheduler, vms_session* session):
	if (session.reader == 0): return
	# A command emits at most four MiB hex plus JSON overhead.
	if (session.reader.length > 4300000):
		vms_fail(scheduler, session, 125)
		return
	int got = frame_reader_fill(session.reader)
	if (got == -11 || got == -4): return
	int length = 0
	char* body = frame_take_buffered_message(session.reader, &length)
	if (body != 0):
		json_value* result = json_parse(body)
		free(body)
		int status = vms_number(result, c"status", 125)
		if (result == 0 || result.type != json_type_object()):
			json_free(result)
			vms_fail(scheduler, session, 125)
			return
		if (session.state == vms_booting):
			char* channel = vms_text(result, c"channel_directory")
			if (channel != 0): session.channel_directory = strclone(channel)
			json_free(result)
			if (status != 0):
				vms_fail(scheduler, session, status)
				return
			session.ready_ms = time_monotonic_ms()
		else:
			json_free(session.result)
			session.result = result
			scheduler.completed = scheduler.completed + 1
			session.status = status
		session.state = vms_ready
		if (status < 0):
			vms_fail(scheduler, session, status)
			return
	if (got <= 0 || session.reader.error): vms_fail(scheduler, session, 125)


void vms_tick(vm_scheduler* scheduler):
	int now = time_monotonic_ms()
	for i in range(scheduler.sessions.length):
		vms_session* session = scheduler.sessions[i]
		if (session == 0): continue
		if (now >= session.lease_deadline):
			scheduler.expired = scheduler.expired + 1
			vms_destroy(scheduler, session)
			continue
		if ((session.state == vms_booting || session.state == vms_busy) && now >= session.operation_deadline):
			vms_fail(scheduler, session, 124)
		else if (session.state == vms_failed && session.pid > 0): vms_release_worker(scheduler, session)
		else if (session.pid > 0): vms_receive(scheduler, session)
	# Find oldest queued ID, independent of reclaimed table slots.
	while (scheduler.queued > 0):
		vms_session* first = 0
		for i in range(scheduler.sessions.length):
			vms_session* session = scheduler.sessions[i]
			if (session != 0 && session.state == vms_queued):
				if (first == 0 || session.id < first.id): first = session
		if (first == 0 || vms_admitted(scheduler, first) == 0): break
		vms_launch(scheduler, first)


void vms_free(vm_scheduler* scheduler):
	for i in range(scheduler.sessions.length):
		if (scheduler.sessions[i] != 0): vms_destroy(scheduler, scheduler.sessions[i])
	list_free[vms_session*](scheduler.sessions)
	registry_close(scheduler.registry)
	free(scheduler)
