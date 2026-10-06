# wbuild: target=wvm_fs_test tag=tests dep=wv2 dep=wvm dep=wvm_fs_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_fs_test.w -o bin/wvm_fs_test"
# wbuild: step="bin/wvm_fs_test" timeout=30000
import lib.testing
import lib.vmm.cell
import lib.vmm.filesystem
import lib.file
import lib.process
import lib.str
import lib.ci_skip


void wvm_fs_cli(char* root, int writable):
	char** args = strv_new(7)
	args[0] = c"bin/wvm"
	args[1] = c"run"
	args[2] = c"--fs-root"
	args[3] = root
	int at = 4
	if (writable):
		args[at] = c"--fs-write"
		at = at + 1
	args[at] = c"bin/wvm_fs_fixture"
	args[at + 1] = c"read"
	if (writable): args[at + 1] = c"write"
	process_result* result = process_run(args[0], args, 0, 0, 15000)
	asserts(c"filesystem CLI launched", result != 0)
	if (result.status != 0):
		println(result.stdout_text)
		println(result.stderr_text)
	assert_equal(0, result.status)
	if (writable): assert_strings_equal(c"filesystem write OK\n", result.stdout_text)
	else: assert_strings_equal(c"filesystem read OK\n", result.stdout_text)
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	free(cast(void*, args))


void wvm_fs_run(char* root, char* mode, int writable):
	char* image = file_read_text(c"bin/wvm_fs_fixture")
	int image_fd = open(c"bin/wvm_fs_fixture", 0, 0)
	asserts(c"fixture open", image_fd >= 0)
	int length = file_size(image_fd)
	close(image_fd)
	vm_cell* cell = cell_new()
	asserts(c"cell allocation", cell != 0)
	if (root != 0): asserts(c"configure filesystem", cell_fs_configure(cell, root, writable))
	asserts(c"load fixture", cell_elf_load(cell, image, length))
	char*[2] args
	args[0] = c"fixture"
	args[1] = mode
	asserts(c"guest stack", cell_stack(cell, 2, &args[0]))
	asserts(c"filesystem guest executed", cell_run(cell, 5000))
	if (cell.status != 0):
		println(cell.output.data)
		println(cell.errors.data)
	assert_equal(0, cell.status)
	assert_equal(-1, cell.unsupported_syscall)
	cell_free(cell)
	free(image)


void test_wvm_fs_confinement():
	int kvm = kvm_open_system()
	if (kvm < 0):
		test_skip(c"SKIP: /dev/kvm unavailable")
		return
	close(kvm)
	assert_equal(0, syscall(83, cast(int, c"bin/wvm_fs_test_root"), 448, 0))
	asserts(c"create fixture file", file_write_text(c"bin/wvm_fs_test_root/hello", c"hello"))
	assert_equal(0, syscall(88, cast(int, c"/etc/passwd"), cast(int, c"bin/wvm_fs_test_root/escape"), 0))
	assert_equal(0, syscall(88, cast(int, c"hello"), cast(int, c"bin/wvm_fs_test_root/local_link"), 0))
	assert_equal(0, syscall(133, cast(int, c"bin/wvm_fs_test_root/fifo"), 4480, 0))
	wvm_fs_run(0, c"default", 0)
	wvm_fs_run(c"bin/wvm_fs_test_root", c"read", 0)
	wvm_fs_run(c"bin/wvm_fs_test_root", c"write", 1)
	wvm_fs_cli(c"bin/wvm_fs_test_root", 0)
	wvm_fs_cli(c"bin/wvm_fs_test_root", 1)
	char* contents = file_read_text(c"bin/wvm_fs_test_root/hello")
	asserts(c"original remains", contents != 0)
	assert_strings_equal(c"hello", contents)
	free(contents)
	assert_equal(0, unlink(c"bin/wvm_fs_test_root/hello"))
	assert_equal(0, unlink(c"bin/wvm_fs_test_root/escape"))
	assert_equal(0, unlink(c"bin/wvm_fs_test_root/local_link"))
	assert_equal(0, unlink(c"bin/wvm_fs_test_root/fifo"))
	assert_equal(0, syscall(84, cast(int, c"bin/wvm_fs_test_root"), 0, 0))


void test_wvm_fs_configuration():
	vm_cell* cell = cell_new()
	assert_equal(0, cell_fs_configure(cell, c"bin/nonexistent-wvm-fs-root", 0))
	assert_equal(0, cast(int, cell.fs_state))
	assert_equal(1, cell_fs_configure(cell, c"bin", 0))
	assert_equal(0, cell_fs_configure(cell, c"bin", 1))
	cell_filesystem* fs = cast(cell_filesystem*, cell.fs_state)
	int host_root = fs.root
	cell_fs_free(cell)
	assert_equal(-9, syscall(72, host_root, 1, 0))
	assert_equal(0, cast(int, cell.fs_state))
	cell_fs_free(cell)
	cell_free(cell)
	cell = cell_new()
	assert_equal(1, cell_fs_configure(cell, c"/dev", 0))
	cell_map(cell, CELL_USER_MIN, 4096, 3)
	mem_copy[char](cell.ram + CELL_USER_MIN, c"null", 5)
	save_int64(cell.regs, 2)
	save_int64(cell.regs + 40, CELL_USER_MIN)
	assert_equal(-13, cell_fs_syscall(cell)) # no device is opened
	fs = cast(cell_filesystem*, cell.fs_state)
	host_root = fs.root
	cell_free(cell)
	assert_equal(-9, syscall(72, host_root, 1, 0))
	cell = cell_new()
	assert_equal(1, cell_fs_configure(cell, c"bin", 0))
	fs = cast(cell_filesystem*, cell.fs_state)
	assert_equal(3, cell_fs_open(fs, -100, c"wv2", 0, 0))
	int host_file = cell_fs_descriptor(fs, 3)
	asserts(c"host file descriptor", host_file >= 0)
	cell_free(cell)
	assert_equal(-9, syscall(72, host_file, 1, 0))


void test_wvm_fs_cli_invalid_policy():
	char** args = strv_new(4)
	args[0] = c"bin/wvm"
	args[1] = c"run"
	args[2] = c"--fs-write"
	args[3] = c"bin/wvm_fs_fixture"
	process_result* result = process_run(args[0], args, 0, 0, 15000)
	asserts(c"invalid policy CLI launched", result != 0)
	assert_equal(2, result.status)
	asserts(c"writable root requirement diagnosed", contains(result.stderr_text, c"--fs-write requires --fs-root"))
	process_result_free(result)
	args[2] = c"--fs-root"
	args[3] = 0
	result = process_run(args[0], args, 0, 0, 15000)
	asserts(c"missing root CLI launched", result != 0)
	assert_equal(2, result.status)
	asserts(c"missing root diagnosed", contains(result.stderr_text, c"missing option value"))
	process_result_free(result)
	free(cast(void*, args))
