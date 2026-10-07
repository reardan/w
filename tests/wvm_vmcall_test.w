# wbuild: target=wvm_vmcall_fixture dep=wv2
# wbuild: step="bin/wv2 x64 --syscall-abi=vmcall tests/wvm_fixture.w -o bin/wvm_vmcall_fixture"
# wbuild: target=wvm_vmcall_thread_fixture dep=wv2
# wbuild: step="bin/wv2 x64 --syscall-abi=vmcall tests/wvm_thread_fixture.w -o bin/wvm_vmcall_thread_fixture"
# wbuild: target=wvm_vmcall_test tag=tests dep=wv2 dep=wvm dep=wvm_vmcall_fixture dep=wvm_vmcall_thread_fixture
# wbuild: step="bin/wv2 --syscall-abi=vmcall tests/hello.w -o bin/vmcall_wrong_arch" expect_status=1 expect_stderr="requires static non-PIE x64 Linux"
# wbuild: step="bin/wv2 x64 --pie --syscall-abi=vmcall tests/hello.w -o bin/vmcall_wrong_pie" expect_status=1 expect_stderr="requires static non-PIE x64 Linux"
# wbuild: step="bin/wv2 x64 --syscall-abi=vmcall tests/dynamic_test.w -o bin/vmcall_wrong_dynamic" expect_status=1 expect_stderr="does not support dynamic imports"
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
	assert_equal(snapshot.hypercall_count, cell.hypercall_count)
	assert_equal(cell_hypercall_site_get(&snapshot.hypercall_sites, 0), cell_hypercall_site_get(&cell.hypercall_sites, 0))
	cell_snapshot_free(snapshot)
	cell.retain_cpus = 1
	for i in range(3):
		assert_equal(1, cell.syscall_abi)
		asserts(c"vmcall run", cell_run(cell, 5000))
		assert_equal(0, cell.status)
		assert_equal(kvm_hypercall_opcode(cell.machine), (cell.ram[cell_hypercall_site_get(&cell.hypercall_sites, 0) + 2] & 255))
		asserts(c"vmcall reset", cell_snapshot_reset(cell))
	cell_free(cell)


void test_vmcall_native_vendor_selection_and_exact_patching():
	assert_equal(193, kvm_hypercall_vendor_opcode(0x756e6547, 0x6c65746e, 0x49656e69))
	assert_equal(217, kvm_hypercall_vendor_opcode(0x68747541, 0x444d4163, 0x69746e65))
	assert_equal(217, kvm_hypercall_vendor_opcode(0x6f677948, 0x656e6975, 0x6e65476e))
	assert_equal(0, kvm_hypercall_vendor_opcode(0, 0, 0))
	vm_cell* cell = cell_new()
	cell_page_tables(cell)
	cell_map(cell, CELL_IMAGE_MIN, 4096, PROT_READ | PROT_EXEC)
	for i in range(3):
		char* site = cell.ram + CELL_IMAGE_MIN + i * 8
		site[0] = 15
		site[1] = 1
		site[2] = 193
	cell.hypercall_count = 2
	cell_hypercall_site_set(&cell.hypercall_sites, 0, CELL_IMAGE_MIN)
	cell_hypercall_site_set(&cell.hypercall_sites, 1, CELL_IMAGE_MIN + 8)
	asserts(c"AMD patch", cell_hypercall_patch(cell, 217))
	assert_equal(217, (cell.ram[CELL_IMAGE_MIN + 2] & 255))
	assert_equal(217, (cell.ram[CELL_IMAGE_MIN + 10] & 255))
	assert_equal(193, (cell.ram[CELL_IMAGE_MIN + 18] & 255))
	assert_equal(0, cell_range(cell, CELL_IMAGE_MIN, 3, 1))
	asserts(c"Intel repatch", cell_hypercall_patch(cell, 193))
	cell.ram[CELL_IMAGE_MIN + 9] = 0
	assert_equal(0, cell_hypercall_patch(cell, 217))
	assert_equal(193, (cell.ram[CELL_IMAGE_MIN + 2] & 255))
	cell.ram[CELL_IMAGE_MIN + 9] = 1
	cell_hypercall_site_set(&cell.hypercall_sites, 1, CELL_IMAGE_MIN)
	assert_equal(0, cell_hypercall_patch(cell, 217))
	cell_hypercall_site_set(&cell.hypercall_sites, 1, CELL_IMAGE_MIN + 8)
	cell_map(cell, CELL_IMAGE_MIN, 4096, PROT_READ)
	assert_equal(0, cell_hypercall_patch(cell, 217))
	cell_free(cell)


void test_vmcall_rejects_malformed_metadata():
	char* image = file_read_text(c"bin/wvm_vmcall_fixture")
	int fd = open(c"bin/wvm_vmcall_fixture", 0, 0)
	int size = file_size(fd)
	close(fd)
	int phoff = load_int64(image + 32)
	int phcount = load_int16(image + 56)
	int note = cell_elf_hypercall_note(image, size, phoff, phcount)
	asserts(c"compiler declares exact sites", note >= 0)
	int sites = load_int32(image + note + 20)
	asserts(c"compiler emits multiple sites", sites > 1)
	for mode in range(9):
		char* copy = cast(char*, malloc(size))
		mem_copy[char](copy, image, size)
		if (mode == 0): save_int32(copy + 48, 0x57564d01)
		if (mode == 1): save_int32(copy + note + 16, 2)
		if (mode == 2): save_int32(copy + note + 20, 65)
		if (mode == 3): save_int32(copy + note + 20, 0)
		if (mode == 4): save_int64(copy + note + 32, load_int64(copy + note + 24))
		if (mode == 5): save_int64(copy + note + 24, CELL_STACK_LOW)
		if (mode == 6): save_int32(copy + note + 4, 512)
		if (mode == 7):
			int address = load_int64(copy + note + 24)
			for i in range(phcount):
				char* ph = copy + phoff + i * 56
				int start = load_int64(ph + 16)
				if (load_int32(ph) == 1 && address >= start && address - start < load_int64(ph + 32)):
					copy[load_int64(ph + 8) + address - start + 2] = 217
		if (mode == 8):
			for i in range(phcount):
				char* ph = copy + phoff + i * 56
				if (load_int32(ph) == 4 && load_int64(ph + 8) == note): save_int64(ph + 32, size)
		vm_cell* cell = cell_new()
		assert_equal(0, cell_elf_load(cell, copy, size))
		assert_equal(0, cell.loaded)
		assert_equal(0, cell.hypercall_count)
		cell_free(cell)
		free(copy)
	free(image)
