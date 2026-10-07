# wbuild: target=wvm_thread_test tag=tests dep=wv2 dep=wvm dep=wvm_thread_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_thread_test.w -o bin/wvm_thread_test"
# wbuild: step="bin/wvm_thread_test" timeout=30000
import lib.testing
import lib.vmm.cell
import lib.file
import lib.process
import lib.time
import lib.str
import lib.ci_skip


int thread_vm_available():
	int fd = kvm_open_system()
	if (fd < 0):
		test_skip_kvm(c"SKIP: /dev/kvm unavailable")
		return 0
	close(fd)
	return 1


process_result* thread_vm_run(char* mode, char* limit, char* timeout):
	char** args = strv_new(8)
	args[0] = c"bin/wvm"
	args[1] = c"run"
	args[2] = c"--max-threads"
	args[3] = limit
	args[4] = c"--timeout-ms"
	args[5] = timeout
	args[6] = c"bin/wvm_thread_fixture"
	args[7] = mode
	process_result* result = process_run(args[0], args, 0, 0, 15000)
	free(cast(void*, args))
	asserts(c"VM process returned", result != 0)
	return result


void test_cell_threads_tls_futex_and_reuse():
	if (thread_vm_available() == 0): return
	process_result* result = thread_vm_run(c"threads", c"4", c"5000")
	assert_equal(0, result.status)
	assert_strings_equal(c"threads OK\n", result.stdout_text)
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	result = thread_vm_run(c"futex", c"4", c"5000")
	assert_equal(0, result.status)
	assert_strings_equal(c"futex OK\n", result.stdout_text)
	process_result_free(result)


void test_cell_thread_exit_semantics_and_limit():
	if (thread_vm_available() == 0): return
	process_result* result = thread_vm_run(c"mainexit", c"4", c"5000")
	assert_equal(23, result.status)
	assert_strings_equal(c"surviving worker\n", result.stdout_text)
	process_result_free(result)
	result = thread_vm_run(c"group", c"4", c"5000")
	assert_equal(7, result.status)
	process_result_free(result)
	result = thread_vm_run(c"limit", c"2", c"5000")
	assert_equal(0, result.status)
	process_result_free(result)


void test_cell_thread_budget_includes_spinners_and_parked_threads():
	if (thread_vm_available() == 0): return
	int start = time_monotonic_ms()
	process_result* result = thread_vm_run(c"spin", c"4", c"100")
	assert_equal(124, result.status)
	asserts(c"spinning siblings respect total wall budget", time_monotonic_ms() - start < 3000)
	process_result_free(result)
	start = time_monotonic_ms()
	result = thread_vm_run(c"park", c"4", c"100")
	assert_equal(124, result.status)
	asserts(c"all-futex-wait respects wall budget", time_monotonic_ms() - start < 3000)
	process_result_free(result)


void test_cell_thread_cleanup_in_embedding_host():
	if (thread_vm_available() == 0): return
	int baseline = open(c"/dev/null", 0, 0)
	close(baseline)
	char* image = file_read_text(c"bin/wvm_thread_fixture")
	int fd = open(c"bin/wvm_thread_fixture", 0, 0)
	int size = file_size(fd)
	close(fd)
	for repeat in range(4):
		vm_cell* cell = cell_new()
		asserts(c"load threaded program", cell_elf_load(cell, image, size))
		char** args = strv_new(2)
		args[0] = c"fixture"
		args[1] = c"mainexit"
		asserts(c"threaded stack", cell_stack(cell, 2, args))
		free(cast(void*, args))
		asserts(c"run threaded cell", cell_run(cell, 5000))
		assert_equal(23, cell.status)
		cell_free(cell)
		fd = open(c"/dev/null", 0, 0)
		assert_equal(baseline, fd)
		close(fd)
	free(image)


void test_cell_thread_permission_changes_flush_sibling_tlb():
	if (thread_vm_available() == 0): return
	process_result* result = thread_vm_run(c"tlb", c"4", c"5000")
	assert_equal(139, result.status)
	asserts(c"sibling observes revoked page", contains(result.stderr_text, c"exception vector 14"))
	process_result_free(result)
