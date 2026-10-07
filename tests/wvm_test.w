# wbuild: target=wvm_test tag=tests dep=wv2 dep=wvm dep=wvm_fixture dep=map_set_builtin_64_test dep=compound_assign_64_test dep=x64_float64_conformance_test
# wbuild: step="bin/wv2 x64 tests/wvm_test.w -o bin/wvm_test"
# wbuild: step="bin/wvm_test" timeout=30000
import lib.testing
import lib.vmm.cell
import lib.file
import lib.process
import lib.env
import lib.str
import lib.ci_skip


int wvm_test_available():
	int fd = kvm_open_system()
	if (fd < 0):
		test_skip_kvm(c"SKIP: /dev/kvm unavailable (loader tests still ran)")
		return 0
	close(fd)
	return 1


process_result* wvm_test_command(char* image, char* mode, char* timeout):
	char** argv = strv_new(7)
	strv_set(argv, 0, c"bin/wvm")
	strv_set(argv, 1, c"run")
	strv_set(argv, 2, c"--timeout-ms")
	strv_set(argv, 3, timeout)
	strv_set(argv, 4, image)
	strv_set(argv, 5, mode)
	strv_set(argv, 6, c"payload")
	spawn_options* options = spawn_options_new()
	options.env = env_copy_with(0, c"W_VM_HOST_SECRET", c"must-not-reach-guest")
	process_result* result = process_run(argv[0], argv, options, 0, 15000)
	asserts(c"wvm process result", result != 0)
	free(options.env[0])
	free(cast(void*, options.env))
	free(options)
	free(cast(void*, argv))
	return result


void test_wvm_normal_programs():
	if (wvm_test_available() == 0): return
	process_result* result = wvm_test_command(c"bin/wvm_fixture", c"smoke", c"5000")
	assert_equal(0, result.status)
	assert_strings_equal(c"cell smoke OK\n", result.stdout_text)
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	result = wvm_test_command(c"bin/wvm_fixture", c"exit", c"5000")
	assert_equal(37, result.status)
	process_result_free(result)
	result = wvm_test_command(c"tests/wvm_hello_fixture.w", c"", c"5000")
	assert_equal(7, result.status)
	assert_strings_equal(c"hello from a cell\n", result.stdout_text)
	process_result_free(result)
	result = wvm_test_command(c"tests/hello.w", c"", c"5000")
	assert_equal(0, result.status)
	assert_strings_equal(c"hello, world!\n", result.stdout_text)
	process_result_free(result)
	list[char*] existing = new list[char*]
	existing.push(c"bin/map_set_builtin_64_test")
	existing.push(c"bin/compound_assign_64_test")
	existing.push(c"bin/x64_float64_conformance_test")
	for char* path in existing:
		result = wvm_test_command(path, c"", c"5000")
		assert_equal(0, result.status)
		asserts(c"existing x64 suite ran inside cell", contains(result.stdout_text, c"All tests passed!"))
		process_result_free(result)
	__w_list_free(cast(__w_list*, existing))


void test_wvm_denials_and_memory():
	if (wvm_test_available() == 0): return
	asserts(c"host sentinel", file_write_text(c"bin/wvm_host_sentinel", c"untouched"))
	process_result* result = wvm_test_command(c"bin/wvm_fixture", c"deny", c"5000")
	assert_equal(0, result.status)
	assert_strings_equal(c"cell denials OK\n", result.stdout_text)
	asserts(c"unsupported calls reported", contains(result.stderr_text, c"ENOSYS"))
	process_result_free(result)
	char* sentinel = file_read_text(c"bin/wvm_host_sentinel")
	asserts(c"guest did not unlink host file", sentinel != 0)
	assert_strings_equal(c"untouched", sentinel)
	free(sentinel)
	unlink(c"bin/wvm_host_sentinel")
	result = wvm_test_command(c"bin/wvm_fixture", c"memory", c"5000")
	assert_equal(0, result.status)
	assert_strings_equal(c"cell memory OK\n", result.stdout_text)
	process_result_free(result)
	result = wvm_test_command(c"bin/wvm_fixture", c"output", c"5000")
	assert_equal(125, result.status)
	asserts(c"bounded output", contains(result.stderr_text, c"output limit exceeded"))
	process_result_free(result)


void test_wvm_faults_and_timeout():
	if (wvm_test_available() == 0): return
	list[char*] modes = new list[char*]
	modes.push(c"supervisor")
	modes.push(c"readonly")
	modes.push(c"unmapped")
	modes.push(c"nx")
	modes.push(c"io")
	for char* mode in modes:
		process_result* result = wvm_test_command(c"bin/wvm_fixture", mode, c"5000")
		assert_equal(139, result.status)
		asserts(c"fault is diagnosed", contains(result.stderr_text, c"exception vector"))
		asserts(c"guest PC reported", contains(result.stderr_text, c"guest RIP"))
		process_result_free(result)
	__w_list_free(cast(__w_list*, modes))
	process_result* result = wvm_test_command(c"bin/wvm_fixture", c"spin", c"100")
	assert_equal(124, result.status)
	asserts(c"CPU-only loop times out", contains(result.stderr_text, c"guest timed out"))
	process_result_free(result)


# Minimal valid ELF for loader tests. All offsets are inside 256 bytes.
char* wvm_test_elf():
	char* image = malloc(256)
	mem_fill[char](image, 0, 256)
	save_int32(image, 0x464c457f)
	image[4] = 2
	image[5] = 1
	image[6] = 1
	save_int16(image + 16, 2)
	save_int16(image + 18, 62)
	save_int32(image + 20, 1)
	save_int64(image + 24, CELL_IMAGE_MIN + 128)
	save_int64(image + 32, 64)
	save_int16(image + 52, 64)
	save_int16(image + 54, 56)
	save_int16(image + 56, 1)
	save_int32(image + 64, 1)
	save_int32(image + 68, 5)
	save_int64(image + 80, CELL_IMAGE_MIN)
	save_int64(image + 96, 256)
	save_int64(image + 104, 4096)
	save_int64(image + 112, 4096)
	return image


void wvm_reject_elf(char* image, int length):
	vm_cell* cell = cell_new()
	asserts(c"allocate loader cell", cell != 0)
	assert_equal(0, cell_elf_load(cell, image, length))
	asserts(c"malformed ELF diagnosed", cell.error != 0)
	assert_equal(0, cell.loaded)
	cell_free(cell)


void test_wvm_loader_bounds():
	char* image = wvm_test_elf()
	wvm_reject_elf(image, 63)
	save_int64(image + 32, -1)
	wvm_reject_elf(image, 256)
	save_int64(image + 32, 240)
	wvm_reject_elf(image, 256)
	save_int64(image + 32, 64)
	image[4] = 1
	wvm_reject_elf(image, 256)
	image[4] = 2
	save_int32(image + 64, 3)
	wvm_reject_elf(image, 256)
	save_int32(image + 64, 1)
	save_int64(image + 104, -1)
	wvm_reject_elf(image, 256)
	save_int64(image + 104, 4096)
	save_int64(image + 72, 200)
	wvm_reject_elf(image, 256)
	save_int64(image + 72, 0)
	save_int64(image + 80, 4096)
	wvm_reject_elf(image, 256)
	save_int64(image + 80, CELL_IMAGE_MAX - 1)
	wvm_reject_elf(image, 256)
	save_int64(image + 80, CELL_IMAGE_MIN)
	save_int64(image + 112, 3)
	wvm_reject_elf(image, 256)
	save_int64(image + 112, 4096)
	save_int64(image + 24, CELL_STACK_LOW)
	wvm_reject_elf(image, 256)
	save_int64(image + 24, CELL_IMAGE_MIN + 128)
	# A second load header overlaps the first one's page.
	save_int16(image + 56, 2)
	mem_copy[char](image + 120, image + 64, 56)
	wvm_reject_elf(image, 256)
	save_int16(image + 56, 1)
	vm_cell* cell = cell_new()
	asserts(c"valid ELF", cell_elf_load(cell, image, 256))
	assert_equal(0, cell.ram[CELL_IMAGE_MIN + 4095]) # zero-filled BSS
	assert_equal(1, cell_range(cell, CELL_IMAGE_MIN, 4096, 0))
	assert_equal(0, cell_range(cell, CELL_IMAGE_MIN, 4096, 1))
	assert_equal(0, cell_range(cell, CELL_IMAGE_MIN, -1, 0))
	assert_equal(0, cell_range(cell, CELL_RAM_SIZE - 1, 2, 0))
	assert_equal(0, cell_range(cell, 4096, 1, 0))
	assert_equal(0, cell_range(cell, CELL_IMAGE_MIN + 4096, 1, 0))
	assert_equal(0, cell_elf_load(cell, image, 256)) # one-shot loading
	cell_free(cell)
	free(image)


void test_wvm_library_input_and_cleanup():
	if (wvm_test_available() == 0): return
	char* image = file_read_text(c"bin/wvm_fixture")
	int fd = open(c"bin/wvm_fixture", 0, 0)
	asserts(c"open fixture", fd >= 0)
	int length = file_size(fd)
	close(fd)
	# Repeated creation/destruction and binary stdin/stdout in the API.
	int thunk_end = 0
	for iteration in range(3):
		vm_cell* cell = cell_new()
		asserts(c"load fixture", cell_elf_load(cell, image, length))
		char** argv = strv_new(2)
		argv[0] = c"fixture"
		argv[1] = c"input"
		asserts(c"guest stack", cell_stack(cell, 2, argv))
		free(cast(void*, argv))
		cell.input = c"a\x00b"
		cell.input_length = 3
		asserts(c"run cell", cell_run(cell, 5000))
		if (iteration == 0): thunk_end = signal_thunk_pos
		assert_equal(thunk_end, signal_thunk_pos)
		assert_equal(0, cell.status)
		assert_equal(3, cell.output.length)
		assert_equal(97, cell.output.data[0])
		assert_equal(0, cell.output.data[1])
		assert_equal(98, cell.output.data[2])
		cell_free(cell)
	# The watchdog works even when the embedding host blocks SIGALRM,
	# and restores that mask after the timed-out execution.
	vm_cell* loop = cell_new()
	asserts(c"load looping guest", cell_elf_load(loop, image, length))
	char** args = strv_new(2)
	args[0] = c"fixture"
	args[1] = c"spin"
	asserts(c"loop stack", cell_stack(loop, 2, args))
	free(cast(void*, args))
	int mask = 8192
	int old_mask = 0
	assert_equal(0, syscall7(14, 0, cast(int, &mask), cast(int, &old_mask), 8, 0, 0))
	asserts(c"watchdog interrupts KVM", cell_run(loop, 50))
	assert_equal(124, loop.status)
	int after = 0
	assert_equal(0, syscall7(14, 2, 0, cast(int, &after), 8, 0, 0))
	assert_equal(8192, after & 8192)
	assert_equal(0, syscall7(14, 2, cast(int, &old_mask), 0, 8, 0, 0))
	cell_free(loop)
	free(image)
