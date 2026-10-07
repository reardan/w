# wbuild: target=wvm_vmcall_fixture dep=wv2
# wbuild: step="bin/wv2 x64 --syscall-abi=vmcall tests/wvm_fixture.w -o bin/wvm_vmcall_fixture"
# wbuild: target=wvm_vmcall_thread_fixture dep=wv2
# wbuild: step="bin/wv2 x64 --syscall-abi=vmcall tests/wvm_thread_fixture.w -o bin/wvm_vmcall_thread_fixture"
# wbuild: target=wvm_vmcall_test tag=tests dep=wv2 dep=wvm dep=wvm_vmcall_fixture dep=wvm_vmcall_thread_fixture
# wbuild: step="bin/wv2 --syscall-abi=vmcall tests/hello.w -o bin/vmcall_wrong_arch" expect_fail expect_stderr="requires static non-PIE x64 Linux"
# wbuild: step="bin/wv2 x64 --pie --syscall-abi=vmcall tests/hello.w -o bin/vmcall_wrong_pie" expect_fail expect_stderr="requires static non-PIE x64 Linux"
# wbuild: step="bin/wv2 x64 tests/wvm_vmcall_test.w -o bin/wvm_vmcall_test"
# wbuild: step="bin/wvm_vmcall_test" timeout=30000
import lib.testing
import lib.vmm.snapshot
import lib.process
import lib.file
import lib.str
import lib.ci_skip

int vmcall_test_available():
	kvm_machine vm
	if (kvm_create(&vm) == 0):
		kvm_destroy(&vm)
		test_skip_kvm(c"SKIP: KVM unavailable for vmcall")
		return 0
	int ok = kvm_enable_vmcall(&vm)
	kvm_destroy(&vm)
	if (ok == 0): test_skip(c"SKIP: KVM ring-3 hypercall interception unavailable")
	return ok

void vmcall_test_mode(char* image, char* mode, int expected):
	char** args = strv_new(7)
	args[0] = c"bin/wvm"
	args[1] = c"run"
	args[2] = c"--timeout-ms"
	args[3] = c"1000"
	args[4] = image
	args[5] = mode
	args[6] = c"payload"
	if (contains(image, c"thread")): args[6] = 0
	process_result* result = process_run(args[0], args, 0, 0, 5000)
	asserts(mode, result != 0)
	if (result.status != expected): println(result.stderr_text)
	assert_equal(expected, result.status)
	process_result_free(result)
	free(cast(void*, args))

void test_vmcall_syscalls_and_permissions():
	if (vmcall_test_available() == 0): return
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"smoke", 0)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"deny", 0)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"memory", 0)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"exit", 37)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"supervisor", 139)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"readonly", 139)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"unmapped", 139)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"nx", 139)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"io", 139)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"output", 125)
	vmcall_test_mode(c"bin/wvm_vmcall_fixture", c"spin", 124)

void test_vmcall_threads_tls_futex():
	if (vmcall_test_available() == 0): return
	vmcall_test_mode(c"bin/wvm_vmcall_thread_fixture", c"threads", 0)
	vmcall_test_mode(c"bin/wvm_vmcall_thread_fixture", c"futex", 0)
	vmcall_test_mode(c"bin/wvm_vmcall_thread_fixture", c"mainexit", 23)
	vmcall_test_mode(c"bin/wvm_vmcall_thread_fixture", c"group", 7)
	vmcall_test_mode(c"bin/wvm_vmcall_thread_fixture", c"tlb", 139)

void test_vmcall_snapshot_abi_and_reset():
	if (vmcall_test_available() == 0): return
	char* image = file_read_text(c"bin/wvm_vmcall_fixture")
	int fd = open(c"bin/wvm_vmcall_fixture", 0, 0)
	int size = file_size(fd)
	close(fd)
	vm_cell* cell = cell_new()
	asserts(c"vmcall load", cell_elf_load(cell, image, size))
	free(image)
	char** args = strv_new(3)
	args[0] = c"fixture"
	args[1] = c"smoke"
	args[2] = c"payload"
	asserts(c"vmcall stack", cell_stack(cell, 3, args))
	free(cast(void*, args))
	cell_snapshot* snapshot = cell_snapshot_create(cell)
	asserts(c"vmcall snapshot", snapshot != 0)
	cell_free(cell)
	cell = cell_snapshot_clone(snapshot)
	asserts(c"vmcall clone", cell != 0)
	cell_snapshot_free(snapshot)
	for i in range(3):
		assert_equal(1, cell.syscall_abi)
		asserts(c"vmcall run", cell_run(cell, 5000))
		assert_equal(0, cell.status)
		asserts(c"vmcall reset", cell_snapshot_reset(cell))
	cell_free(cell)
