# wbuild: target=wvm_box_test tag=tests dep=wv2 dep=wvm dep=wvm_init dep=wvm_box_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_box_test.w -o bin/wvm_box_test"
# wbuild: step="bin/wvm_box_test" timeout=60000
import lib.testing
import lib.vmm.box_snapshot
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
	asserts(c"bounded workspace readonly lower", box_test_has(command, c"local,id=work,security_model=mapped-xattr,multidevs=forbid,path=/tmp/work,,readonly=off,readonly=on"))
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
		process_result* reply = box_session_exec(session, guest_args, c"/", 1000, 128)
		asserts(c"persistent guest response", reply != 0)
		assert_equal(9, reply.status)
		assert_equal(3, reply.stdout_length)
		assert_equal(0, cast(int, reply.stdout_text[1]))
		assert_strings_equal(c"guest stderr", reply.stderr_text)
		process_result_free(reply)
	strv_set(guest_args, 1, c"snapshot-write")
	process_result* saved = box_session_exec(session, guest_args, c"/", 1000, 128)
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
	saved = box_session_exec(session, guest_args, c"/", 1000, 128)
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
	process_result* caps = box_session_exec(session, guest_args, 0, 1000, 128)
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
	char* workspace_kernel = env_get(c"WVM_TEST_WORKSPACE_KERNEL")
	if (workspace_kernel == 0):
		println(c"SKIP: set WVM_TEST_WORKSPACE_KERNEL for bounded overlay boot (built-in 9p and overlay)")
	else:
		options.kernel = workspace_kernel
		string_builder* workspace = string_new()
		string_append(workspace, c"/tmp/wvm-box-test-")
		string_append_int(workspace, getpid())
		assert_equal(0, mkdir(workspace.data, 448))
		char* base_path = strjoin(workspace.data, c"/base.txt")
		asserts(c"workspace fixture", file_write_text(base_path, c"immutable base"))
		options.fs_root = workspace.data
		options.workspace_mb = 1
		session = box_session_open(options)
		asserts(c"bounded overlay guest ready", session != 0)
		guest_args = strv_new(2)
		strv_set(guest_args, 0, c"/test")
		strv_set(guest_args, 1, c"workspace")
		reply = box_session_exec(session, guest_args, c"/work", 1000, 128)
		assert_equal(0, reply.status)
		process_result_free(reply)
		strv_set(guest_args, 1, c"workspace-full")
		reply = box_session_exec(session, guest_args, c"/work", 1000, 128)
		assert_equal(0, reply.status)
		process_result_free(reply)
		box_session_close(session)
		free(cast(void*, guest_args))
		char* private_path = strjoin(workspace.data, c"/private.txt")
		assert_equal(0, cast(int, file_read_text(private_path)))
		free(private_path)
		assert_equal(0, unlink(base_path))
		free(base_path)
		assert_equal(0, syscall(84, cast(int, workspace.data), 0, 0))
		string_free(workspace)
		options.fs_root = 0
		options.workspace_mb = 0
	options.timeout_ms = 1
	assert_equal(124, box_run(options))
	free(options)
	assert_equal(0, unlink(c"bin/wvm_box_test.cpio"))
