# wbuild: target=wvm_box_test tag=tests dep=wv2 dep=wvm dep=wvm_init dep=wvm_box_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_box_test.w -o bin/wvm_box_test"
# wbuild: step="bin/wvm_box_test" timeout=120000
import lib.testing
import lib.vmm.box_pool
import lib.file
import lib.str


int box_test_has(char** args, char* expected):
	int i = 0
	while (args[i] != 0):
		if (strcmp(args[i], expected) == 0): return 1
		i = i + 1
	return 0


void test_box_policy():
	vm_box_options* options = box_options_new()
	assert_equal(0, box_options_valid(options))
	options.kernel = c"kernel with spaces"
	options.initrd = c"root.cpio"
	char** command = box_command(options, c"qemu")
	asserts(c"KVM required", box_test_has(command, c"microvm,accel=kvm"))
	asserts(c"kernel argument preserved", box_test_has(command, options.kernel))
	assert_equal(0, box_test_has(command, c"-netdev"))
	assert_equal(0, box_test_has(command, c"-fsdev"))
	box_command_free(command)
	options.network = 1
	options.fs_root = c"/tmp/work,readonly=off"
	command = box_command(options, c"qemu")
	asserts(c"explicit network", box_test_has(command, c"user,id=net"))
	asserts(c"escaped path and readonly", box_test_has(command, c"local,id=work,security_model=mapped-xattr,multidevs=forbid,path=/tmp/work,,readonly=off,readonly=on"))
	box_command_free(command)
	options.channel_path = c"/tmp/a,b.sock"
	options.workspace_mb = 16
	options.fs_write = 1
	options.network = 2
	command = box_command(options, c"qemu")
	asserts(c"private virtio channel", box_test_has(command, c"virtserialport,chardev=agent,name=wvm.agent"))
	asserts(c"escaped socket path", box_test_has(command, c"socket,id=agent,path=/tmp/a,,b.sock,server=on,wait=off"))
	asserts(c"restricted network", box_test_has(command, c"user,id=net,restrict=on"))
	assert_equal(0, box_test_has(command, c"-fsdev"))
	assert_equal(0, box_test_has(command, c"virtio-9p-device,fsdev=work,mount_tag=work"))
	box_command_free(command)
	options.workspace_mb = 0
	options.cpus = 0
	assert_equal(0, box_options_valid(options))
	options.cpus = 65
	assert_equal(0, box_options_valid(options))
	options.cpus = 2
	options.fs_root = 0
	options.fs_write = 1
	assert_equal(0, box_options_valid(options))
	free(options)
	char** init_args = strv_new(1)
	strv_set(init_args, 0, c"bin/wvm_init")
	process_result* init_result = process_run(init_args[0], init_args, 0, 0, 1000)
	asserts(c"PID1 guard launched", init_result != 0)
	assert_equal(125, init_result.status)
	process_result_free(init_result)
	free(cast(void*, init_args))


void box_test_hex(string_builder* archive, int value):
	char* digits = c"0123456789abcdef"
	for i in range(8):
		string_append_char(archive, digits[(value >> ((7 - i) * 4)) & 15])


void box_test_pad(string_builder* archive):
	while (archive.length % 4): string_append_char(archive, 0)


# Minimal newc writer, including console device before PID 1 starts.
void box_test_entry(string_builder* archive, char* name, int mode, char* data, int size, int major, int minor):
	string_append(archive, c"070701")
	box_test_hex(archive, 1)
	box_test_hex(archive, mode)
	box_test_hex(archive, 0)
	box_test_hex(archive, 0)
	box_test_hex(archive, 1)
	box_test_hex(archive, 0)
	box_test_hex(archive, size)
	box_test_hex(archive, 0)
	box_test_hex(archive, 0)
	box_test_hex(archive, major)
	box_test_hex(archive, minor)
	box_test_hex(archive, strlen(name) + 1)
	box_test_hex(archive, 0)
	string_append_bytes(archive, name, strlen(name) + 1)
	box_test_pad(archive)
	if (size > 0): string_append_bytes(archive, data, size)
	box_test_pad(archive)


void box_test_file(string_builder* archive, char* name, char* path):
	int fd = open(path, 0, 0)
	asserts(c"initramfs source opened", fd >= 0)
	int size = file_size(fd)
	close(fd)
	char* data = file_read_text(path)
	asserts(c"initramfs source read", data != 0)
	box_test_entry(archive, name, 33261, data, size, 0, 0)
	free(data)


# Prove CoW through the actual QEMU RAM mapping, not aggregate process RSS
# (which also includes shared libraries and QEMU executable pages).
int box_test_shared_ram(int pid):
	string_builder* path = string_from(c"/proc/")
	string_append_int(path, pid)
	string_append(path, c"/smaps")
	char* text = file_read_text(path.data)
	string_free(path)
	asserts(c"QEMU memory accounting readable", text != 0)
	int at = 0
	int active = 0
	int shared = 0
	while (text[at]):
		int end = at
		while (text[end] && text[end] != '\n'): end = end + 1
		int more = text[end] != 0
		text[end] = 0
		char* line = text + at
		int header = 0
		for i in range(strlen(line)):
			if (line[i] == ' '): break
			if (line[i] == '-'): header = 1
		if (header):
			active = contains(line, c"/memfd:wvm-linux-ram") != 0
			if (active): asserts(c"guest RAM mapped privately", contains(line, c" rw-p ") != 0)
		else if (active && (starts_with(line, c"Shared_Clean:") || starts_with(line, c"Shared_Dirty:"))):
			int offset = 13
			while (line[offset] == ' '): offset = offset + 1
			shared = shared + atoi(line + offset)
		at = end + more
	free(text)
	return shared


void test_box_linux_boot():
	char* kernel = env_get(c"WVM_TEST_KERNEL")
	if (kernel == 0):
		println(c"SKIP: set WVM_TEST_KERNEL to test a real Linux boot")
		return
	string_builder* archive = string_new()
	box_test_entry(archive, c"dev", 16877, 0, 0, 0, 0)
	box_test_entry(archive, c"dev/console", 8576, 0, 0, 5, 1)
	box_test_file(archive, c"init", c"bin/wvm_init")
	box_test_file(archive, c"test", c"bin/wvm_box_fixture")
	box_test_entry(archive, c"TRAILER!!!", 0, 0, 0, 0, 0)
	io_result written
	assert_equal(IO_OK, file_write_text_checked(c"bin/wvm_box_test.cpio", archive.data, archive.length, &written))
	string_free(archive)
	char** command = strv_new(8)
	strv_set(command, 0, c"bin/wvm")
	strv_set(command, 1, c"box")
	strv_set(command, 2, c"--kernel")
	strv_set(command, 3, kernel)
	strv_set(command, 4, c"--initrd")
	strv_set(command, 5, c"bin/wvm_box_test.cpio")
	strv_set(command, 6, c"--append")
	strv_set(command, 7, c"quiet -- /test")
	process_result* result = process_run(command[0], command, 0, 0, 45000)
	asserts(c"Linux guest launched", result != 0)
	if (result.status != 0 || contains(result.stdout_text, c"wvm-init: exit 7") == 0):
		println(result.stdout_text)
		println(result.stderr_text)
	assert_equal(0, result.status)
	asserts(c"guest ran under Linux", contains(result.stdout_text, c"Linux guest filesystem and threads passed") != 0)
	asserts(c"guest command returned 7", contains(result.stdout_text, c"wvm-init: exit 7") != 0)
	process_result_free(result)
	free(cast(void*, command))
	vm_box_options* options = box_options_new()
	options.kernel = kernel
	options.initrd = c"bin/wvm_box_test.cpio"
	string_builder* channel_parent = string_new()
	string_append(channel_parent, c"/tmp/wvm-box-long-state-path-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-")
	string_append_int(channel_parent, getpid())
	assert_equal(0, mkdir(channel_parent.data, 448))
	options.channel_directory = channel_parent.data
	vm_box_session* session = box_session_open(options)
	asserts(c"persistent Linux guest ready", session != 0)
	asserts(c"socket physical path exceeds UNIX address limit", strlen(session.socket_path) > 107)
	char** guest_args = strv_new(2)
	strv_set(guest_args, 0, c"/test")
	strv_set(guest_args, 1, c"output")
	for i in range(2):
		process_result* reply = box_session_exec(session, guest_args, c"/", 5000, 128)
		asserts(c"persistent guest response", reply != 0)
		assert_equal(9, reply.status)
		assert_equal(3, reply.stdout_length)
		assert_equal(0, cast(int, reply.stdout_text[1]))
		assert_strings_equal(c"guest stderr", reply.stderr_text)
		process_result_free(reply)
	strv_set(guest_args, 1, c"snapshot-write")
	process_result* saved = box_session_exec(session, guest_args, c"/", 5000, 128)
	assert_equal(0, saved.status)
	process_result_free(saved)
	session.snapshot_allowed = 0
	asserts(c"external device snapshot rejected without stopping source", box_snapshot_create(session, 10000) == 0 && session.alive)
	session.snapshot_allowed = 1
	box_snapshot* snapshot = box_snapshot_create(session, 10000)
	asserts(c"capture live Linux RAM and devices", snapshot != 0)
	assert_equal(15, sys_fcntl(snapshot.fd, F_GET_SEALS, 0))
	box_session_close(session)
	session = box_snapshot_restore_in(snapshot, 10000, channel_parent.data)
	asserts(c"snapshot survives source destruction", session != 0)
	strv_set(guest_args, 1, c"snapshot-read")
	saved = box_session_exec(session, guest_args, c"/", 5000, 128)
	assert_equal(0, saved.status)
	process_result_free(saved)
	for i in range(2):
		vm_box_session* restored = box_snapshot_restore(snapshot, 10000)
		asserts(c"restore independent Linux clone", restored != 0)
		saved = box_session_exec(restored, guest_args, c"/", 2000, 128)
		asserts(c"restored channel responds", saved != 0)
		assert_equal(0, saved.status)
		process_result_free(saved)
		box_session_close(restored)
	box_snapshot_free(snapshot)
	strv_set(guest_args, 1, c"caps")
	process_result* caps = box_session_exec(session, guest_args, 0, 5000, 128)
	assert_equal(0, caps.status)
	process_result_free(caps)
	strv_set(guest_args, 1, c"wait")
	process_result* reply = box_session_exec(session, guest_args, 0, 50, 128)
	assert_equal(process_status_timeout, reply.status)
	process_result_free(reply)
	strv_set(guest_args, 1, c"flood")
	reply = box_session_exec(session, guest_args, 0, 1000, 37)
	assert_equal(box_status_output_limit, reply.status)
	assert_equal(37, reply.stdout_length)
	process_result_free(reply)
	free(cast(void*, guest_args))
	box_session_close(session)
	assert_equal(0, syscall(84, cast(int, channel_parent.data), 0, 0))
	string_free(channel_parent)
	options.channel_directory = 0
	# Imported workspaces require only tmpfs, not 9p or overlay drivers.
	string_builder* workspace = string_new()
	string_append(workspace, c"/tmp/wvm-box-test-")
	string_append_int(workspace, getpid())
	assert_equal(0, mkdir(workspace.data, 448))
	char* base_path = strjoin(workspace.data, c"/base.txt")
	asserts(c"workspace fixture", file_write_text(base_path, c"immutable base"))
	options.fs_root = workspace.data
	options.workspace_mb = 1
	session = box_session_open(options)
	asserts(c"bounded imported workspace ready", session != 0)
	assert_equal(1, session.snapshot_allowed)
	guest_args = strv_new(2)
	strv_set(guest_args, 0, c"/test")
	strv_set(guest_args, 1, c"workspace")
	reply = box_session_exec(session, guest_args, c"/work", 5000, 128)
	assert_equal(0, reply.status)
	process_result_free(reply)
	box_snapshot* work_snapshot = box_snapshot_create(session, 10000)
	asserts(c"workspace captured without external filesystem device", work_snapshot != 0)
	box_snapshot* cow_snapshot = box_snapshot_create_cow(session, 15000)
	asserts(c"CoW workspace template captured", cow_snapshot != 0)
	asserts(c"CoW owns RAM separately", cow_snapshot.ram_fd >= 0)
	assert_equal(15, sys_fcntl(cow_snapshot.ram_fd, F_GET_SEALS, 0))
	assert_equal(15, sys_fcntl(cow_snapshot.fd, F_GET_SEALS, 0))
	asserts(c"device stream excludes guest RAM", file_size(cow_snapshot.fd) < 1048576)
	strv_set(guest_args, 1, c"workspace-change")
	reply = box_session_exec(session, guest_args, c"/work", 5000, 128)
	assert_equal(0, reply.status)
	process_result_free(reply)
	box_session_close(session)
	char* original_base = file_read_text(base_path)
	assert_strings_equal(c"immutable base", original_base)
	free(original_base)
	# Removing the source proves restore has no dependency on host files.
	assert_equal(0, unlink(base_path))
	assert_equal(0, syscall(84, cast(int, workspace.data), 0, 0))
	for clone in range(2):
		session = box_snapshot_restore(work_snapshot, 10000)
		asserts(c"independent imported workspace clone", session != 0)
		strv_set(guest_args, 1, c"workspace-check")
		reply = box_session_exec(session, guest_args, c"/work", 5000, 128)
		assert_equal(0, reply.status)
		process_result_free(reply)
		strv_set(guest_args, 1, c"workspace-change")
		reply = box_session_exec(session, guest_args, c"/work", 5000, 128)
		assert_equal(0, reply.status)
		process_result_free(reply)
		if (clone == 0): box_session_close(session)
	box_snapshot_free(work_snapshot)
	strv_set(guest_args, 1, c"workspace-full")
	reply = box_session_exec(session, guest_args, c"/work", 5000, 128)
	assert_equal(0, reply.status)
	process_result_free(reply)
	box_session_close(session)
	vm_box_session* cow_first = box_snapshot_restore(cow_snapshot, 10000)
	vm_box_session* cow_second = box_snapshot_restore(cow_snapshot, 10000)
	asserts(c"two concurrent CoW clones", cow_first != 0 && cow_second != 0)
	for clone in range(2):
		session = cow_first
		if (clone): session = cow_second
		strv_set(guest_args, 1, c"workspace-check")
		reply = box_session_exec(session, guest_args, c"/work", 5000, 128)
		assert_equal(0, reply.status)
		process_result_free(reply)
	asserts(c"first clone shares physical RAM pages", box_test_shared_ram(cow_first.child.pid) > 0)
	asserts(c"second clone shares physical RAM pages", box_test_shared_ram(cow_second.child.pid) > 0)
	box_pool* pool = box_pool_new(cow_snapshot, 2, 15000)
	asserts(c"ready Linux pool", pool != 0)
	box_snapshot_free(cow_snapshot)
	# Original template and source filesystem are gone; pool owns its backing.
	vm_box_session* pooled_first = box_pool_acquire(pool)
	vm_box_session* pooled_second = box_pool_acquire(pool)
	asserts(c"pool capacity leased", pooled_first != 0 && pooled_second != 0)
	asserts(c"pool exhaustion bounded", box_pool_acquire(pool) == 0)
	assert_equal(0, box_pool_release(pool, cow_first))
	strv_set(guest_args, 1, c"workspace-change")
	reply = box_session_exec(pooled_first, guest_args, c"/work", 5000, 128)
	assert_equal(0, reply.status)
	process_result_free(reply)
	strv_set(guest_args, 1, c"workspace-check")
	reply = box_session_exec(pooled_second, guest_args, c"/work", 5000, 128)
	assert_equal(0, reply.status)
	process_result_free(reply)
	assert_equal(1, box_pool_release(pool, pooled_first))
	for cycle in range(4):
		vm_box_session* clean = box_pool_acquire(pool)
		asserts(c"pool replacement ready", clean != 0)
		strv_set(guest_args, 1, c"workspace-check")
		reply = box_session_exec(clean, guest_args, c"/work", 5000, 128)
		assert_equal(0, reply.status)
		process_result_free(reply)
		strv_set(guest_args, 1, c"workspace-change")
		reply = box_session_exec(clean, guest_args, c"/work", 5000, 128)
		assert_equal(0, reply.status)
		process_result_free(reply)
		assert_equal(1, box_pool_release(pool, clean))
	assert_equal(1, pool.active)
	assert_equal(5, pool.replacements)
	# Missing artifacts fail replacement explicitly and leave bounded vacancy.
	char* pool_kernel = pool.snapshot.kernel
	pool.snapshot.kernel = c"/missing-wvm-pool-kernel"
	assert_equal(0, box_pool_release(pool, pooled_second))
	pool.snapshot.kernel = pool_kernel
	assert_equal(0, pool.active)
	pooled_first = box_pool_acquire(pool)
	asserts(c"healthy slot remains usable", pooled_first != 0)
	asserts(c"failed replacement does not cold fallback", box_pool_acquire(pool) == 0)
	assert_equal(1, box_pool_refill(pool))
	asserts(c"explicit refill recovers capacity", box_pool_acquire(pool) != 0)
	# Free also retires both outstanding leases.
	box_pool_free(pool)
	strv_set(guest_args, 1, c"workspace-change")
	reply = box_session_exec(cow_first, guest_args, c"/work", 5000, 128)
	assert_equal(0, reply.status)
	process_result_free(reply)
	box_snapshot* dirty_snapshot = box_snapshot_create_cow(cow_first, 15000)
	asserts(c"checkpoint a dirty CoW clone", dirty_snapshot != 0)
	box_session_close(cow_first)
	strv_set(guest_args, 1, c"workspace-check")
	reply = box_session_exec(cow_second, guest_args, c"/work", 5000, 128)
	assert_equal(0, reply.status)
	process_result_free(reply)
	box_session_close(cow_second)
	session = box_snapshot_restore(dirty_snapshot, 10000)
	asserts(c"restore checkpoint of dirty clone", session != 0)
	box_snapshot_free(dirty_snapshot)
	strv_set(guest_args, 1, c"workspace-changed-check")
	reply = box_session_exec(session, guest_args, c"/work", 5000, 128)
	assert_equal(0, reply.status)
	process_result_free(reply)
	box_session_close(session)
	free(cast(void*, guest_args))
	char* private_path = strjoin(workspace.data, c"/private.txt")
	assert_equal(0, cast(int, file_read_text(private_path)))
	free(private_path)
	free(base_path)
	string_free(workspace)
	options.fs_root = 0
	options.workspace_mb = 0
	options.timeout_ms = 1
	assert_equal(124, box_run(options))
	free(options)
	assert_equal(0, unlink(c"bin/wvm_box_test.cpio"))
