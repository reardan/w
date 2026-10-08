# Apple Silicon cell scheduler: exec-created workers, bounded framed RPC.
# Admission reservations are not OS-enforced cgroup quotas.
import lib.vmm.darwin_cell_snapshot
import lib.vmm.darwin_protocol

struct dvm_template:
	int id
	darwin_backing* backing
	int deadline

struct dvm_session:
	int id
	int state # 0 queued, 1 booting, 2 ready, 3 busy, 4 failed
	int backing_fd
	process* worker
	frame_reader* reader
	json_value* result
	int status
	int commands
	int lease_deadline
	int operation_deadline
	int submitted_ms
	int ready_ms

struct dvm_daemon:
	list[dvm_session*] sessions
	list[dvm_template*] templates
	int next_session
	int next_template
	int max_active
	int max_pending
	int max_memory_mb
	int running
	int completed
	int failures
	int expired
	char* executable


int dvm_active(dvm_daemon* daemon):
	int n = 0
	for dvm_session* session in daemon.sessions:
		if (session != 0 && session.worker != 0): n = n + 1
	return n

int dvm_template_count(dvm_daemon* daemon):
	int n = 0
	for dvm_template* template in daemon.templates:
		if (template != 0): n = n + 1
	return n

int dvm_session_count(dvm_daemon* daemon):
	int n = 0
	for dvm_session* session in daemon.sessions:
		if (session != 0): n = n + 1
	return n

int dvm_queued(dvm_daemon* daemon):
	int n = 0
	for dvm_session* session in daemon.sessions:
		if (session != 0 && session.state == 0): n = n + 1
	return n


dvm_session* dvm_find(dvm_daemon* daemon, int id):
	for dvm_session* session in daemon.sessions:
		if (session != 0 && session.id == id): return session
	return 0


dvm_template* dvm_template_find(dvm_daemon* daemon, int id):
	for dvm_template* template in daemon.templates:
		if (template != 0 && template.id == id): return template
	return 0


void dvm_worker_release(dvm_session* session):
	if (session.reader != 0): frame_reader_free(session.reader)
	session.reader = 0
	if (session.worker != 0): process_free(session.worker)
	session.worker = 0

void dvm_destroy(dvm_daemon* daemon, dvm_session* session):
	dvm_worker_release(session)
	close(session.backing_fd)
	json_free(session.result)
	for i in range(daemon.sessions.length):
		if (daemon.sessions[i] == session): daemon.sessions[i] = 0
	free(session)

void dvm_template_destroy(dvm_daemon* daemon, dvm_template* template):
	for i in range(daemon.templates.length):
		if (daemon.templates[i] == template): daemon.templates[i] = 0
	darwin_backing_free(template.backing)
	free(template)

void dvm_fail(dvm_daemon* daemon, dvm_session* session, int status):
	dvm_worker_release(session)
	session.state = 4
	session.status = status
	daemon.failures = daemon.failures + 1


char* dvm_state_name(int state):
	if (state == 0): return c"queued"
	if (state == 1): return c"booting"
	if (state == 2): return c"ready"
	if (state == 3): return c"busy"
	return c"failed"

json_value* dvm_status(dvm_session* session):
	json_value* value = json_object()
	json_object_set(value, c"session", json_int(session.id))
	json_object_set(value, c"state", json_string(dvm_state_name(session.state)))
	json_object_set(value, c"command", json_int(session.commands))
	json_object_set(value, c"status", json_int(session.status))
	json_object_set(value, c"cpus", json_int(1))
	json_object_set(value, c"memory_mb", json_int(256))
	json_object_set(value, c"lease_remaining_ms", json_int(session.lease_deadline - dhv_now_ms()))
	if (session.ready_ms): json_object_set(value, c"launch_ms", json_int(session.ready_ms - session.submitted_ms))
	return value


darwin_backing* dvm_image_template(char* image):
	if (image == 0 || image[0] == 0 || strlen(image) > 1024): return 0
	darwin_cell* cell = darwin_cell_new()
	if (cell == 0): return 0
	darwin_backing* backing = 0
	char** args = strv_new(1)
	strv_set(args, 0, image)
	if (darwin_cell_load(cell, image) && darwin_cell_stack(cell, 1, args)):
		backing = darwin_cell_snapshot_create(cell)
	free(cast(void*, args))
	darwin_cell_free(cell)
	return backing


int dvm_config_valid(json_value* params):
	if (dvm_keys(params, c"backend image template cpus memory_mb lease_ms timeout_ms") == 0): return 0
	char* backend = vms_text(params, c"backend")
	if (backend == 0 || strcmp(backend, c"cell") != 0): return 0
	if (vms_number(params, c"cpus", 1) != 1 || vms_number(params, c"memory_mb", 256) != 256): return 0
	int lease = vms_number(params, c"lease_ms", 60000)
	int timeout = vms_number(params, c"timeout_ms", 30000)
	if (lease < 100 || lease > 3600000 || timeout < 1 || timeout > 600000): return 0
	if (vms_field(params, c"template") != 0): return vms_number(params, c"template", 0) > 0 && vms_field(params, c"image") == 0
	return vms_text(params, c"image") != 0

json_value* dvm_submit(dvm_daemon* daemon, json_value* params):
	if (dvm_config_valid(params) == 0): return vms_error(c"unsupported configuration: backend=cell, static ARM64 image/template, one vCPU, 256 MiB; no external capabilities")
	int count = dvm_session_count(daemon)
	if (count >= daemon.max_active + daemon.max_pending): return vms_error(c"session table full")
	if (count >= daemon.max_active && dvm_queued(daemon) >= daemon.max_pending): return vms_error(c"launch queue full")
	# Charge each retained backing conservatively, including queued clones.
	if ((count + dvm_template_count(daemon) + 1) * 256 > daemon.max_memory_mb): return vms_error(c"memory admission capacity exhausted")
	int fd = -1
	if (vms_field(params, c"template") != 0):
		dvm_template* template = dvm_template_find(daemon, vms_number(params, c"template", 0))
		if (template == 0): return vms_error(c"unknown template")
		fd = sys_fcntl(template.backing.fd, 0, 10)
	else:
		darwin_backing* backing = dvm_image_template(vms_text(params, c"image"))
		if (backing == 0): return vms_error(c"image requires a valid static ARM64 ELF")
		fd = sys_fcntl(backing.fd, 0, 10)
		darwin_backing_free(backing)
	if (fd < 0): return vms_error(c"cannot retain template backing")
	sys_fcntl(fd, 2, 1)
	dvm_session* session = new dvm_session()
	mem_fill[char](cast(char*, session), 0, sizeof(dvm_session))
	session.backing_fd = fd
	session.id = daemon.next_session
	daemon.next_session = daemon.next_session + 1
	session.submitted_ms = dhv_now_ms()
	session.lease_deadline = session.submitted_ms + vms_number(params, c"lease_ms", 60000)
	session.operation_deadline = vms_number(params, c"timeout_ms", 30000)
	int slot = -1
	for i in range(daemon.sessions.length):
		if (daemon.sessions[i] == 0): slot = i
	if (slot < 0): daemon.sessions.push(session)
	else: daemon.sessions[slot] = session
	return dvm_status(session)


void dvm_launch(dvm_daemon* daemon, dvm_session* session):
	session.worker = dvm_worker_spawn(daemon.executable, session.backing_fd)
	if (session.worker == 0):
		dvm_fail(daemon, session, 125)
		return
	session.reader = frame_reader_new(session.worker.stdout_fd)
	frame_reader_set_max_body(session.reader, 4300000)
	session.reader.max_header_bytes = 64
	session.state = 1
	session.operation_deadline = dhv_now_ms() + session.operation_deadline


void dvm_receive(dvm_daemon* daemon, dvm_session* session):
	int got = frame_reader_fill(session.reader)
	if (got == -4 || got == 0 - net_eagain()): return
	json_value* answer = dvm_take(session.reader, 4300000)
	if (answer != 0):
		int expected = session.commands
		if (session.state == 1): expected = 0
		if (vms_number(answer, c"protocol", -1) != 1 || vms_number(answer, c"request", -1) != expected || (session.state != 1 && session.state != 3)):
			json_free(answer)
			dvm_fail(daemon, session, 125)
			return
		int status = vms_number(answer, c"status", 125)
		if (session.state == 1):
			json_free(answer)
			if (status != 0):
				dvm_fail(daemon, session, status)
				return
			session.ready_ms = dhv_now_ms()
		else:
			json_free(session.result)
			session.result = answer
			daemon.completed = daemon.completed + 1
		session.status = status
		session.state = 2
	if (got <= 0 || session.reader.error): dvm_fail(daemon, session, 125)


void dvm_tick(dvm_daemon* daemon):
	int now = dhv_now_ms()
	for dvm_template* template in daemon.templates:
		if (template != 0 && now >= template.deadline): dvm_template_destroy(daemon, template)
	for dvm_session* session in daemon.sessions:
		if (session == 0): continue
		if (now >= session.lease_deadline):
			daemon.expired = daemon.expired + 1
			dvm_destroy(daemon, session)
			continue
		if ((session.state == 1 || session.state == 3) && now >= session.operation_deadline):
			dvm_fail(daemon, session, 124)
		else if (session.worker != 0): dvm_receive(daemon, session)
	while (dvm_active(daemon) < daemon.max_active):
		dvm_session* first = 0
		for dvm_session* session in daemon.sessions:
			if (session != 0 && session.state == 0):
				if (first == 0 || session.id < first.id): first = session
		if (first == 0): break
		dvm_launch(daemon, first)


int dvm_exec_valid(json_value* params);

json_value* dvm_execute(dvm_daemon* daemon, dvm_session* session, json_value* params):
	if (session.state != 2): return vms_error(c"session is not ready")
	if (dvm_exec_valid(params) == 0): return vms_error(c"invalid argv, timeout, output limit or unsupported exec capability")
	json_value* request = json_clone(params)
	json_object_set(request, c"protocol", json_int(1))
	json_object_set(request, c"request", json_int(session.commands + 1))
	int sent = dvm_send(session.worker.stdin_fd, request)
	json_free(request)
	if (sent == 0):
		dvm_fail(daemon, session, 125)
		return vms_error(c"worker transport failed")
	json_free(session.result)
	session.result = 0
	session.commands = session.commands + 1
	session.state = 3
	session.status = process_status_running
	session.operation_deadline = dhv_now_ms() + vms_number(params, c"timeout_ms", 30000) + 3000
	json_value* answer = json_object()
	json_object_set(answer, c"command", json_int(session.commands))
	return answer


void dvm_chunk(json_value* answer, json_value* result, char* key, int offset, int length):
	char* text = vms_text(result, key)
	if (text == 0): text = c""
	int total = strlen(text) / 2
	int count = total - offset
	if (count < 0): count = 0
	if (count > length): count = length
	char* chunk = cast(char*, malloc(count * 2 + 1))
	if (count): mem_copy[char](chunk, text + offset * 2, count * 2)
	chunk[count * 2] = 0
	json_object_set(answer, key, json_string(chunk))
	free(chunk)
	char* size_key = strjoin(key, c"_bytes")
	json_object_set(answer, size_key, json_int(total))
	free(size_key)


json_value* dvm_dispatch(dvm_daemon* daemon, char* method, json_value* params):
	if (strcmp(method, c"capabilities") == 0): return dvm_capabilities()
	if (strcmp(method, c"stop") == 0):
		daemon.running = 0
		return json_object()
	if (strcmp(method, c"stats") == 0):
		json_value* value = dvm_capabilities()
		json_object_set(value, c"active", json_int(dvm_active(daemon)))
		json_object_set(value, c"queued", json_int(dvm_queued(daemon)))
		json_object_set(value, c"sessions", json_int(dvm_session_count(daemon)))
		json_object_set(value, c"templates", json_int(dvm_template_count(daemon)))
		json_object_set(value, c"completed_commands", json_int(daemon.completed))
		json_object_set(value, c"failures", json_int(daemon.failures))
		json_object_set(value, c"expired", json_int(daemon.expired))
		json_object_set(value, c"reserved_memory_mb", json_int((dvm_session_count(daemon) + dvm_template_count(daemon)) * 256))
		return value
	if (strcmp(method, c"template_create") == 0):
		if (dvm_keys(params, c"backend image lease_ms") == 0 || vms_text(params, c"backend") == 0 || strcmp(vms_text(params, c"backend"), c"cell") != 0): return vms_error(c"only ready ARM64 cell templates are supported")
		int lease = vms_number(params, c"lease_ms", 60000)
		if (lease < 100 || lease > 3600000): return vms_error(c"invalid template lease")
		if (dvm_template_count(daemon) >= 16 || (dvm_session_count(daemon) + dvm_template_count(daemon) + 1) * 256 > daemon.max_memory_mb): return vms_error(c"template capacity exhausted")
		darwin_backing* backing = dvm_image_template(vms_text(params, c"image"))
		if (backing == 0): return vms_error(c"template requires a valid static ARM64 ELF")
		dvm_template* template = new dvm_template()
		template.id = daemon.next_template
		daemon.next_template = daemon.next_template + 1
		template.backing = backing
		template.deadline = dhv_now_ms() + lease
		int slot = -1
		for i in range(daemon.templates.length):
			if (daemon.templates[i] == 0): slot = i
		if (slot < 0): daemon.templates.push(template)
		else: daemon.templates[slot] = template
		json_value* value = json_object()
		json_object_set(value, c"template", json_int(template.id))
		return value
	if (strcmp(method, c"template_destroy") == 0 || strcmp(method, c"template_renew") == 0):
		if (dvm_keys(params, c"template lease_ms") == 0): return vms_error(c"unsupported template option")
		dvm_template* template = dvm_template_find(daemon, vms_number(params, c"template", 0))
		if (template == 0): return vms_error(c"unknown template")
		if (strcmp(method, c"template_destroy") == 0): dvm_template_destroy(daemon, template)
		else:
			int lease = vms_number(params, c"lease_ms", 60000)
			if (lease < 100 || lease > 3600000): return vms_error(c"invalid template lease")
			template.deadline = dhv_now_ms() + lease
		return json_object()
	if (strcmp(method, c"vm_spawn") == 0): return dvm_submit(daemon, params)
	if (strcmp(method, c"vm_snapshot") == 0 || strcmp(method, c"region_create") == 0 || strcmp(method, c"debug") == 0): return vms_error(c"unsupported-operation: live checkpoints, shared regions and debugger unavailable on Darwin")
	dvm_session* session = dvm_find(daemon, vms_number(params, c"session", -1))
	if (session == 0): return vms_error(c"unknown session")
	if (strcmp(method, c"vm_status") == 0): return dvm_status(session)
	if (strcmp(method, c"vm_exec") == 0): return dvm_execute(daemon, session, params)
	if (strcmp(method, c"vm_result") == 0):
		int offset = vms_number(params, c"offset", 0)
		int length = vms_number(params, c"length", 1024)
		if (offset < 0 || offset > 1048576 || length < 0 || length > 2048): return vms_error(c"invalid output chunk")
		json_value* value = dvm_status(session)
		dvm_chunk(value, session.result, c"stdout_hex", offset, length)
		dvm_chunk(value, session.result, c"stderr_hex", offset, length)
		char* diagnostic = vms_text(session.result, c"diagnostic")
		if (diagnostic != 0): json_object_set(value, c"diagnostic", json_string(diagnostic))
		return value
	if (strcmp(method, c"vm_destroy") == 0 || strcmp(method, c"vm_cancel") == 0):
		dvm_destroy(daemon, session)
		return json_object()
	if (strcmp(method, c"vm_restore") == 0):
		if (dvm_keys(params, c"session") == 0 || session.state == 3): return vms_error(c"restore requires an idle session and its ready template")
		dvm_worker_release(session)
		json_free(session.result)
		session.result = 0
		session.status = 0
		session.state = 0
		session.operation_deadline = 30000
		return dvm_status(session)
	if (strcmp(method, c"vm_renew") == 0):
		int lease = vms_number(params, c"lease_ms", 60000)
		if (lease < 100 || lease > 3600000): return vms_error(c"invalid lease")
		session.lease_deadline = dhv_now_ms() + lease
		return dvm_status(session)
	return vms_error(c"unsupported-operation")


struct dvm_connection:
	frame_reader* reader
	int deadline

int dvm_serve(dvm_daemon* daemon, char* path):
	dvm_signal(13, 1)
	int listener = socket_unix_stream()
	if (listener < 0): return 125
	# Bind only a new socket; never unlink a live daemon or arbitrary path.
	int previous_mask = dvm_umask(63)
	int bound = socket_bind_unix(listener, path)
	dvm_umask(previous_mask)
	if (bound < 0):
		close(listener)
		return 125
	if ((dvm_chmod(path, 384) & 65535) != 0 || socket_listen(listener, 32) < 0):
		close(listener)
		unlink(path)
		return 125
	socket_set_nonblocking(listener)
	socket_set_nosigpipe(listener)
	sys_fcntl(listener, 2, 1)
	dvm_connection*[32] clients
	for i in range(32): clients[i] = 0
	pollfd* descriptors = pollfd_new_array(33)
	while (daemon.running):
		dvm_tick(daemon)
		pollfd_set(descriptors, 0, listener, poll_in)
		for i in range(32):
			int fd = -1
			if (clients[i] != 0): fd = clients[i].reader.fd
			pollfd_set(descriptors, i + 1, fd, poll_in)
		poll_wait(descriptors, 33, 10)
		int accepted = socket_accept_connection(listener)
		if (accepted >= 0):
			int slot = -1
			for i in range(32):
				if (clients[i] == 0 && slot < 0): slot = i
			if (slot < 0): close(accepted)
			else:
				socket_set_nonblocking(accepted)
				socket_set_nosigpipe(accepted)
				sys_fcntl(accepted, 2, 1)
				dvm_connection* connection = new dvm_connection()
				connection.reader = frame_reader_new(accepted)
				frame_reader_set_max_body(connection.reader, 8192)
				connection.reader.max_header_bytes = 64
				connection.deadline = dhv_now_ms() + 10000
				clients[slot] = connection
		for i in range(32):
			dvm_connection* connection = clients[i]
			if (connection == 0): continue
			int done = dhv_now_ms() >= connection.deadline
			if (done == 0):
				int got = frame_reader_fill(connection.reader)
				if (got == 0 || (got < 0 && got != -4 && got != 0 - net_eagain())): done = 1
				json_value* request = dvm_take(connection.reader, 8192)
				if (request != 0):
					char* version = vms_text(request, c"jsonrpc")
					char* method = vms_text(request, c"method")
					json_value* id = vms_field(request, c"id")
					if (version != 0 && strcmp(version, c"2.0") == 0 && method != 0 && id != 0 && id.type == json_type_int()):
						json_value* result = dvm_dispatch(daemon, method, vms_field(request, c"params"))
						json_value* response = jsonrpc_response_result(id, result)
						dvm_send(connection.reader.fd, response)
						json_free(response)
					json_free(request)
					done = 1
				if (connection.reader.error): done = 1
			if (done):
				close(connection.reader.fd)
				frame_reader_free(connection.reader)
				free(connection)
				clients[i] = 0
	for i in range(32):
		if (clients[i] != 0):
			close(clients[i].reader.fd)
			frame_reader_free(clients[i].reader)
			free(clients[i])
	free(descriptors)
	close(listener)
	unlink(path)
	return 0
