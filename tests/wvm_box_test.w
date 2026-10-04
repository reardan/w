# wbuild: target=wvm_box_test tag=tests dep=wv2 dep=wvm dep=wvm_init dep=wvm_box_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_box_test.w -o bin/wvm_box_test"
# wbuild: step="bin/wvm_box_test" timeout=60000
import lib.testing
import lib.vmm.box
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
	options.timeout_ms = 1
	assert_equal(124, box_run(options))
	free(options)
	assert_equal(0, unlink(c"bin/wvm_box_test.cpio"))
