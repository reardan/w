# wbuild: target=wvm_fault_test tag=tests dep=wv2 dep=wvm dep=wvm_fault_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_fault_test.w -o bin/wvm_fault_test"
# wbuild: step="bin/wvm_fault_test" timeout=30000
import lib.testing
import lib.vmm.faults
import lib.vmm.cell
import lib.process
import lib.str
import lib.ci_skip

void test_fault_metadata_bounds():
	char[64] image
	mem_fill[char](&image[0], 0, 64)
	for length in range(65):
		char* symbol = cell_fault_symbol(&image[0], length, 1)
		assert_strings_equal(c"", symbol)
		free(symbol)
	save_int32(&image[0], 0x464c457f)
	image[4] = 2
	image[5] = 1
	save_int16(&image[58], 64)
	save_int16(&image[60], 65535)
	save_int64(&image[40], -64)
	char* symbol = cell_fault_symbol(&image[0], 64, 1)
	assert_strings_equal(c"", symbol)
	free(symbol)
	vm_debug_cursor cursor
	mem_fill[char](&image[0], 128, 64)
	cursor.data = &image[0]
	cursor.at = 0
	cursor.end = 64
	cursor.bad = 0
	vm_debug_leb(&cursor, 0)
	assert_equal(1, cursor.bad)
	asserts(c"bounded malformed LEB", cursor.at <= 8)

void test_fault_cli_source_position():
	int fd = kvm_open_system()
	if (fd < 0):
		test_skip_kvm(c"SKIP: /dev/kvm unavailable for symbolized guest fault")
		return
	close(fd)
	char** args = strv_new(3)
	strv_set(args, 0, c"bin/wvm")
	strv_set(args, 1, c"run")
	strv_set(args, 2, c"bin/wvm_fault_fixture")
	process_result* result = process_run(args[0], args, 0, 0, 10000)
	asserts(c"fault command completed", result != 0)
	assert_equal(139, result.status)
	asserts(c"raw vector retained", contains(result.stderr_text, c"exception vector 14 at guest RIP"))
	asserts(c"function symbol", contains(result.stderr_text, c"in guest_fault_site"))
	asserts(c"source line", contains(result.stderr_text, c"tests/wvm_fault_fixture.w:6)"))
	process_result_free(result)
	free(cast(void*, args))
