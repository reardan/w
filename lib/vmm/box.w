# Linux guests use QEMU's microvm machine with hardware KVM acceleration.
# No shell invocation and no software-emulation fallback. Kernel/initramfs
# are caller-supplied artifacts; nothing is downloaded at runtime.
import lib.process
import lib.kvm
import lib.vmm.channel
import lib.vmm.qmp
import lib.file

struct vm_box_options:
	char* kernel
	char* initrd
	char* command_line
	char* fs_root
	int fs_write
	int network
	int cpus
	int memory_mb
	int timeout_ms
	char* channel_path # private host socket; set by box_session_open
	int workspace_mb # guest tmpfs upper bound, 0 uses the supplied share policy
	char* channel_directory # borrowed private parent; null uses /tmp
	char* qmp_path # internal private control socket
	int snapshot_fd # borrowed migration image, -1 for cold boot


vm_box_options* box_options_new():
	vm_box_options* options = cast(vm_box_options*, malloc(sizeof(vm_box_options)))
	mem_fill[char](cast(char*, options), 0, sizeof(vm_box_options))
	options.snapshot_fd = -1
	options.cpus = 2
	options.memory_mb = 256
	options.timeout_ms = 30000
	return options


int box_options_valid(vm_box_options* options):
	if (options == 0): return 0
	if (options.kernel == 0 || options.initrd == 0): return 0
	if (options.kernel[0] == 0 || options.initrd[0] == 0): return 0
	if (options.cpus < 1 || options.cpus > 64): return 0
	if (options.memory_mb < 64 || options.memory_mb > 32768): return 0
	if (options.timeout_ms < 1 || options.timeout_ms > 600000): return 0
	if (options.fs_write != 0 && options.fs_root == 0): return 0
	if (options.workspace_mb < 0 || options.workspace_mb > 32768): return 0
	if (options.workspace_mb > 0 && options.fs_root == 0): return 0
	if (options.network < 0 || options.network > 2): return 0
	return 1


# QEMU key/value options escape a literal comma by doubling it.
void box_append_path(string_builder* builder, char* path):
	for i in range(strlen(path)):
		string_append_char(builder, path[i])
		if (path[i] == ','): string_append_char(builder, ',')


void box_arg(char** args, int* count, char* value):
	strv_set(args, *count, strjoin(value, c""))
	*count = *count + 1


void box_command_free(char** args):
	if (args == 0): return
	int i = 0
	while (args[i] != 0):
		free(args[i])
		i = i + 1
	free(cast(void*, args))


# Exposed separately so policy/device selection is testable without KVM.
char** box_command(vm_box_options* options, char* qemu):
	if (box_options_valid(options) == 0 || qemu == 0): return 0
	char** args = strv_new(64)
	int count = 0
	box_arg(args, &count, qemu)
	box_arg(args, &count, c"-machine")
	box_arg(args, &count, c"microvm,accel=kvm")
	box_arg(args, &count, c"-cpu")
	box_arg(args, &count, c"host")
	box_arg(args, &count, c"-m")
	string_builder* value = string_new()
	string_append_int(value, options.memory_mb)
	box_arg(args, &count, value.data)
	string_clear(value)
	string_append_int(value, options.cpus)
	box_arg(args, &count, c"-smp")
	box_arg(args, &count, value.data)
	box_arg(args, &count, c"-nodefaults")
	box_arg(args, &count, c"-no-user-config")
	box_arg(args, &count, c"-display")
	box_arg(args, &count, c"none")
	box_arg(args, &count, c"-monitor")
	box_arg(args, &count, c"none")
	box_arg(args, &count, c"-serial")
	box_arg(args, &count, c"stdio")
	if (options.channel_path != 0):
		box_arg(args, &count, c"-device")
		box_arg(args, &count, c"virtio-serial-device")
		string_clear(value)
		string_append(value, c"socket,id=agent,path=")
		box_append_path(value, options.channel_path)
		string_append(value, c",server=on,wait=off")
		box_arg(args, &count, c"-chardev")
		box_arg(args, &count, value.data)
		box_arg(args, &count, c"-device")
		box_arg(args, &count, c"virtserialport,chardev=agent,name=wvm.agent")
	if (options.qmp_path != 0):
		string_clear(value)
		string_append(value, c"unix:")
		box_append_path(value, options.qmp_path)
		string_append(value, c",server=on,wait=off")
		box_arg(args, &count, c"-qmp")
		box_arg(args, &count, value.data)
	if (options.snapshot_fd >= 0):
		box_arg(args, &count, c"-incoming")
		box_arg(args, &count, c"defer")
	box_arg(args, &count, c"-no-reboot")
	box_arg(args, &count, c"-kernel")
	box_arg(args, &count, options.kernel)
	box_arg(args, &count, c"-initrd")
	box_arg(args, &count, options.initrd)
	box_arg(args, &count, c"-append")
	string_clear(value)
	string_append(value, c"console=ttyS0 reboot=t panic=-1")
	if (options.channel_path != 0):
		string_append(value, c" -- --agent")
		if (options.fs_root != 0): string_append(value, c" --work")
		if (options.workspace_mb > 0):
			string_append(value, c" --workspace-mb ")
			string_append_int(value, options.workspace_mb)
	else if (options.command_line != 0):
		string_append_char(value, ' ')
		string_append(value, options.command_line)
	box_arg(args, &count, value.data)
	if (options.fs_root != 0):
		string_clear(value)
		string_append(value, c"local,id=work,security_model=mapped-xattr,multidevs=forbid,path=")
		box_append_path(value, options.fs_root)
		if (options.fs_write == 0 || options.workspace_mb > 0): string_append(value, c",readonly=on")
		box_arg(args, &count, c"-fsdev")
		box_arg(args, &count, value.data)
		box_arg(args, &count, c"-device")
		box_arg(args, &count, c"virtio-9p-device,fsdev=work,mount_tag=work")
	if (options.network):
		box_arg(args, &count, c"-netdev")
		if (options.network == 2): box_arg(args, &count, c"user,id=net,restrict=on")
		else: box_arg(args, &count, c"user,id=net")
		box_arg(args, &count, c"-device")
		box_arg(args, &count, c"virtio-net-device,netdev=net")
	string_free(value)
	return args


# Console streams directly to the caller's stdio, avoiding unbounded host
# capture. Status is QEMU's status, NOT an init command's exit code.
int box_run(vm_box_options* options):
	if (box_options_valid(options) == 0): return 2
	int probe = kvm_open_system()
	if (probe < 0): return 125
	close(probe)
	char* qemu = process_which(c"qemu-system-x86_64")
	if (qemu == 0): return 125
	char** args = box_command(options, qemu)
	# QEMU's stdio backend makes an attached terminal raw. SIGKILL on a
	# deadline bypasses its cleanup, so preserve the Linux termios here.
	char[64] terminal
	int restore_terminal = syscall(16, 0, 21505, cast(int, &terminal[0])) == 0
	process* child = process_spawn(qemu, args, 0)
	box_command_free(args)
	free(qemu)
	if (child == 0): return 125
	int status = process_wait_or_kill(child, options.timeout_ms)
	process_free(child)
	if (restore_terminal): syscall(16, 0, 21506, cast(int, &terminal[0]))
	if (status == process_status_timeout): return 124
	if (status < 0): return 125
	return status


# One caller at a time. Commands preserve guest filesystem state, but PID 1
# kills command descendants before replying. Cancellation destroys the VM.
struct vm_box_session:
	process* child
	int fd
	char* directory
	char* socket_path
	char* transport_path
	int directory_fd
	int alive
	int qmp_fd
	char* qmp_path
	char* kernel
	char* initrd
	int cpus
	int memory_mb
	int snapshot_allowed


void box_session_cancel(vm_box_session* session):
	if (session == 0): return
	if (session.qmp_fd >= 0):
		close(session.qmp_fd)
		session.qmp_fd = -1
	if (session.fd >= 0):
		close(session.fd)
		session.fd = -1
	if (session.child != 0):
		process_kill(session.child, sigkill)
		process_wait(session.child)
	session.alive = 0


void box_session_close(vm_box_session* session):
	if (session == 0): return
	box_session_cancel(session)
	if (session.child != 0): process_free(session.child)
	free(session.kernel)
	free(session.initrd)
	if (session.qmp_path != 0):
		unlink(session.qmp_path)
		free(session.qmp_path)
	if (session.socket_path != 0):
		unlink(session.socket_path)
		free(session.socket_path)
	if (session.transport_path != 0): free(session.transport_path)
	if (session.directory != 0):
		if (session.directory_fd >= 0): close(session.directory_fd)
		syscall(84, cast(int, session.directory), 0, 0) # rmdir, Linux x64
		free(session.directory)
	free(session)


# Child-side PR_SET_PDEATHSIG prevents a dead scheduler worker orphaning
# QEMU. The parent-PID check closes the fork/prctl race. No shell involved.
process* box_session_spawn(char* qemu, char** args):
	int parent = getpid()
	int pid = fork()
	if (pid < 0): return 0
	if (pid == 0):
		if (syscall7(157, 1, sigkill, 0, 0, 0, 0) < 0): exit(125)
		if (syscall(110, 0, 0, 0) != parent): exit(125)
		process_redirect_null(0, 0)
		process_redirect_null(1, 1)
		process_redirect_null(2, 1)
		# Do not hand scheduler sockets, locks or host file descriptors to QEMU.
		if (syscall(436, 3, -1, 0) < 0): exit(125) # close_range (Linux 5.9+)
		execve(qemu, args, env_current())
		exit(127)
	process* child = new process()
	child.pid = pid
	child.stdin_fd = -1
	child.stdout_fd = -1
	child.stderr_fd = -1
	child.status = 0
	child.reaped = 0
	child.win_handle = 0
	return child


# Boot and require the WVM1 readiness greeting. KVM and caller-supplied
# Linux kernel/initramfs are mandatory. No host command execution fallback.
vm_box_session* box_session_open(vm_box_options* options):
	if (box_options_valid(options) == 0 || __word_size__ != 8): return 0
	int probe = kvm_open_system()
	if (probe < 0): return 0
	close(probe)
	char* qemu = process_which(c"qemu-system-x86_64")
	if (qemu == 0): return 0
	vm_box_session* session = new vm_box_session()
	mem_fill[char](cast(char*, session), 0, sizeof(vm_box_session))
	session.fd = -1
	session.qmp_fd = -1
	session.directory_fd = -1
	session.kernel = strclone(options.kernel)
	session.initrd = strclone(options.initrd)
	session.cpus = options.cpus
	session.memory_mb = options.memory_mb
	session.snapshot_allowed = options.fs_root == 0 && options.network == 0
	char[16] random
	if (sys_getrandom(&random[0], 16, 0) != 16):
		free(qemu)
		box_session_close(session)
		return 0
	string_builder* path = string_new()
	if (options.channel_directory != 0): string_append(path, options.channel_directory)
	else: string_append(path, c"/tmp")
	string_append(path, c"/wvm-channel-")
	char* digits = c"0123456789abcdef"
	for i in range(16):
		int value = cast(int, random[i]) & 255
		string_append_char(path, digits[value >> 4])
		string_append_char(path, digits[value & 15])
	if (mkdir(path.data, 448) < 0):
		string_free(path)
		free(qemu)
		box_session_close(session)
		return 0
	session.directory = strclone(path.data)
	string_append(path, c"/agent.sock")
	session.socket_path = strclone(path.data)
	# The physical state path can exceed sockaddr_un's 107-byte limit.
	# Resolve through this worker's open directory fd; QEMU is its child
	# and retains the same uid. Keep the fd alive until after QEMU exits.
	session.directory_fd = open(session.directory, 2686976, 0) # O_PATH|O_DIRECTORY|O_CLOEXEC
	if (session.directory_fd < 0):
		string_free(path)
		free(qemu)
		box_session_close(session)
		return 0
	string_clear(path)
	string_append(path, c"/proc/")
	string_append_int(path, getpid())
	string_append(path, c"/fd/")
	string_append_int(path, session.directory_fd)
	string_append(path, c"/agent.sock")
	session.transport_path = strclone(path.data)
	string_clear(path)
	string_append(path, session.directory)
	string_append(path, c"/qmp.sock")
	session.qmp_path = strclone(path.data)
	string_free(path)
	vm_box_options copied
	mem_copy[char](cast(char*, &copied), cast(char*, options), sizeof(vm_box_options))
	copied.channel_path = session.transport_path
	char* qmp_transport = strclone(session.transport_path)
	# Replace the ten-byte agent.sock basename with qmp.sock.
	mem_copy[char](qmp_transport + strlen(qmp_transport) - 10, c"qmp.sock", 9)
	copied.qmp_path = qmp_transport
	char** args = box_command(&copied, qemu)
	session.child = box_session_spawn(qemu, args)
	box_command_free(args)
	free(qemu)
	if (session.child == 0):
		free(qmp_transport)
		box_session_close(session)
		return 0
	int deadline = process_monotonic_ms() + options.timeout_ms
	session.qmp_fd = box_qmp_open(qmp_transport, deadline)
	free(qmp_transport)
	if (session.qmp_fd < 0):
		box_session_close(session)
		return 0
	while (deadline - process_monotonic_ms() > 0):
		if (process_try_wait(session.child) != process_status_running): break
		session.fd = socket_connect_unix_path(session.transport_path)
		if (session.fd >= 0): break
		process_sleep_ms(5)
	if (session.fd >= 0):
		sys_fcntl(session.fd, 2, 1) # FD_CLOEXEC
		socket_set_nonblocking(session.fd)
		if (options.snapshot_fd >= 0):
			if (box_qmp_migrate(session.qmp_fd, options.snapshot_fd, 1, deadline) && box_qmp_simple(session.qmp_fd, c"cont", deadline)):
				session.alive = 1
				return session
			box_session_close(session)
			return 0
		char[4] greeting
		if (box_channel_io(session.fd, &greeting[0], 4, 0, 1, deadline)):
			if (load_int32(&greeting[0]) == box_channel_magic):
				session.alive = 1
				return session
	box_session_close(session)
	return 0


# Invalid caller input returns null without affecting a healthy session.
# Transport/deadline failures kill QEMU; callers cannot reuse uncertain state.
# Output is binary-safe via process_result lengths and capped per stream.
process_result* box_session_exec(vm_box_session* session, char** args, char* cwd, int timeout_ms, int output_limit):
	if (session == 0 || session.alive == 0): return 0
	int request_length = 0
	char* request = box_channel_request(args, cwd, timeout_ms, output_limit, &request_length)
	if (request == 0): return 0
	int deadline = process_monotonic_ms() + timeout_ms + 2000
	int ok = box_channel_io(session.fd, request, request_length, 1, 1, deadline)
	free(request)
	char[16] header
	if (ok): ok = box_channel_io(session.fd, &header[0], 16, 0, 1, deadline)
	process_result* result = box_channel_result(box_status_transport)
	if (ok):
		int status = load_int32(&header[0] + 4)
		int out_length = load_int32(&header[0] + 8)
		int err_length = load_int32(&header[0] + 12)
		if (load_int32(&header[0]) != box_channel_magic): ok = 0
		if (out_length < 0 || out_length > output_limit): ok = 0
		if (err_length < 0 || err_length > output_limit): ok = 0
		if ((status < 0 || status > 255) && status != process_status_timeout && status != box_status_output_limit): ok = 0
		if (ok):
			free(result.stdout_text)
			free(result.stderr_text)
			result.stdout_text = cast(char*, malloc(out_length + 1))
			result.stderr_text = cast(char*, malloc(err_length + 1))
			result.stdout_text[out_length] = 0
			result.stderr_text[err_length] = 0
			ok = box_channel_io(session.fd, result.stdout_text, out_length, 0, 1, deadline)
			if (ok): ok = box_channel_io(session.fd, result.stderr_text, err_length, 0, 1, deadline)
			if (ok):
				result.status = status
				result.stdout_length = out_length
				result.stderr_length = err_length
	if (ok == 0):
		if (deadline - process_monotonic_ms() <= 0): result.status = process_status_timeout
		box_session_cancel(session)
	return result
