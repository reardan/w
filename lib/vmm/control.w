# Bounded local control plane for vm_scheduler. Content-Length JSON-RPC 2.0.
# Socket access is restricted to the daemon's Unix user (mode 0600).
import lib.vmm.scheduler
import lib.signal

struct vms_connection:
	frame_reader* reader
	int deadline

struct vms_control:
	vm_scheduler* scheduler
	int running

int vms_signal_stop

void vms_stop_signal(int sig, int context):
	vms_signal_stop = 1


void vms_ignore_pipe():
	int[4] action
	mem_fill[char](cast(char*, &action[0]), 0, 32)
	action[0] = 1
	rt_sigaction(13, &action[0], 0)


json_value* vms_dispatch(vms_control* control, char* method, json_value* params):
	vm_scheduler* scheduler = control.scheduler
	if (strcmp(method, c"stats") == 0): return vms_stats(scheduler)
	if (strcmp(method, c"stop") == 0):
		control.running = 0
		return json_object()
	if (strcmp(method, c"templates") == 0): return vms_templates(scheduler)
	if (strcmp(method, c"template_renew") == 0 || strcmp(method, c"region_renew") == 0):
		int lease = vms_number(params, c"lease_ms", 60000)
		if (lease < 100 || lease > 3600000): return vms_error(c"lease must be 100..3600000 ms")
		if (strcmp(method, c"template_renew") == 0):
			vm_template* template = vms_template_find(scheduler, vms_number(params, c"template", 0))
			if (template == 0): return vms_error(c"unknown template")
			template.lease_deadline = time_monotonic_ms() + lease
		else:
			vm_region* region = vms_region_find(scheduler, vms_number(params, c"region", 0))
			if (region == 0): return vms_error(c"unknown region")
			region.lease_deadline = time_monotonic_ms() + lease
		return json_object()
	if (strcmp(method, c"region_create") == 0): return vms_region_create(scheduler, params)
	if (strcmp(method, c"region_destroy") == 0): return vms_region_destroy(scheduler, vms_number(params, c"region", 0))
	if (strcmp(method, c"template_create") == 0):
		char* backend = vms_text(params, c"backend")
		if (backend != 0 && strcmp(backend, c"box") == 0): return vms_box_template_create(scheduler, vms_find(scheduler, vms_number(params, c"session", 0)), params)
		if (backend != 0 && strcmp(backend, c"cell") != 0): return vms_error(c"unknown template backend")
		return vms_template_create(scheduler, params)
	if (strcmp(method, c"template_destroy") == 0): return vms_template_destroy(scheduler, vms_number(params, c"template", 0))
	if (strcmp(method, c"vm_spawn") == 0):
		if (vms_field(params, c"fs_write") != 0 || vms_field(params, c"private_workspace") != 0 || vms_field(params, c"channel_directory") != 0): return vms_error(c"internal workspace options are not accepted")
		char* backend = vms_text(params, c"backend")
		if (backend != 0):
			if (strcmp(backend, c"cell") == 0): return vms_submit(scheduler, params)
			if (strcmp(backend, c"box") != 0): return vms_error(c"unknown VM backend")
			if (vms_field(params, c"template") != 0): return vms_submit(scheduler, params)
		char* kernel = vms_text(params, c"kernel")
		char* initrd = vms_text(params, c"initrd")
		if (kernel == 0 || initrd == 0 || kernel[0] == 0 || initrd[0] == 0): return vms_error(c"kernel and initrd are required")
		if (strlen(kernel) > 1024 || strlen(initrd) > 1024): return vms_error(c"image path too long")
		if (vms_field(params, c"fs_write") != 0 || vms_field(params, c"private_workspace") != 0 || vms_field(params, c"channel_directory") != 0): return vms_error(c"writable exports require workspace cloning")
		if (vms_field(params, c"network") != 0): return vms_error(c"daemon boxes have networking disabled")
		return vms_submit(scheduler, params)
	vms_session* session = vms_find(scheduler, vms_number(params, c"session", -1))
	if (session == 0): return vms_error(c"unknown session")
	if (strcmp(method, c"vm_status") == 0): return vms_status(session)
	if (strcmp(method, c"vm_result") == 0): return vms_result(session, params)
	if (strcmp(method, c"vm_snapshot") == 0): return vms_snapshot_operation(scheduler, session, c"snapshot")
	if (strcmp(method, c"vm_restore") == 0): return vms_snapshot_operation(scheduler, session, c"restore")
	if (strcmp(method, c"vm_exec") == 0): return vms_exec(scheduler, session, params)
	if (strcmp(method, c"vm_destroy") == 0 || strcmp(method, c"vm_cancel") == 0):
		vms_destroy(scheduler, session)
		return json_object()
	if (strcmp(method, c"vm_renew") == 0):
		int lease = vms_number(params, c"lease_ms", 60000)
		if (lease < 100 || lease > 3600000): return vms_error(c"lease must be 100..3600000 ms")
		session.lease_deadline = time_monotonic_ms() + lease
		return vms_status(session)
	return vms_error(c"unknown method")


int vms_request(vms_control* control, int fd, char* body):
	if (vms_json_safe(body) == 0): return 0
	json_value* request = json_parse(body)
	char* version = vms_text(request, c"jsonrpc")
	char* method = vms_text(request, c"method")
	json_value* id = vms_field(request, c"id")
	if (version == 0 || strcmp(version, c"2.0") != 0 || method == 0 || id == 0 || id.type != json_type_int()):
		json_free(request)
		return 0
	json_value* result = vms_dispatch(control, method, vms_field(request, c"params"))
	json_value* response = jsonrpc_response_result(id, result)
	int written = jsonrpc_write_value(fd, response)
	json_free(response)
	json_free(request)
	return written >= 0


# Foreground server. Up to 32 clients, 8 KiB requests, 10-second idle
# deadline, one request per client per pass. A slow writer is disconnected
# on EAGAIN; bounded responses can be retried through vm_status/vm_result.
int vms_serve(vm_scheduler* scheduler, char* path):
	if (scheduler.registry == 0): scheduler.registry = registry_open(path)
	if (scheduler.registry == 0): return 125
	if (syscall7(157, 36, 1, 0, 0, 0, 0) < 0): return 125
	vms_ignore_pipe()
	vms_signal_stop = 0
	signal_install_handler(2, cast(int, vms_stop_signal), 0)
	signal_install_handler(15, cast(int, vms_stop_signal), 0)
	int mask = syscall(95, 63, 0, 0)
	int listener = socket_unix_stream()
	int bound = -1
	if (listener >= 0): bound = socket_bind_unix_replacing_stale(listener, path)
	syscall(95, mask, 0, 0)
	if (bound < 0):
		if (listener >= 0): close(listener)
		return 125
	if (chmod(path, 384) < 0 || socket_listen(listener, 32) < 0):
		close(listener)
		unlink(path)
		return 125
	socket_set_nonblocking(listener)
	vms_connection*[32] clients
	for i in range(32): clients[i] = 0
	pollfd* descriptors = pollfd_new_array(33)
	vms_control control
	control.scheduler = scheduler
	control.running = 1
	while (control.running && vms_signal_stop == 0):
		vms_tick(scheduler)
		pollfd_set(descriptors, 0, listener, poll_in)
		for i in range(32):
			int fd = -1
			if (clients[i] != 0): fd = clients[i].reader.fd
			pollfd_set(descriptors, i + 1, fd, poll_in)
		poll_wait(descriptors, 33, 10)
		if (pollfd_at(descriptors, 0).revents & poll_in):
			int fd = socket_accept_connection(listener)
			if (fd >= 0):
				int slot = -1
				for i in range(32):
					if (clients[i] == 0 && slot < 0): slot = i
				if (slot < 0): close(fd)
				else:
					socket_set_nonblocking(fd)
					clients[slot] = new vms_connection(frame_reader_new(fd), time_monotonic_ms() + 10000)
		for i in range(32):
			vms_connection* client = clients[i]
			if (client == 0): continue
			int closed = time_monotonic_ms() >= client.deadline
			if (pollfd_at(descriptors, i + 1).revents != 0 && closed == 0):
				int got = frame_reader_fill(client.reader)
				if (got <= 0 && got != -11 && got != -4): closed = 1
			char* body = vms_take_frame(client.reader, 8192)
			if (body != 0 && closed == 0):
				if (vms_request(&control, client.reader.fd, body) == 0): closed = 1
				client.deadline = time_monotonic_ms() + 10000
			if (body != 0): free(body)
			if (client.reader.error || client.reader.length - client.reader.offset > 16384): closed = 1
			if (closed):
				close(client.reader.fd)
				frame_reader_free(client.reader)
				free(client)
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
