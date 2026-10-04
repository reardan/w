# wbuild: target=wvm_snapshot_test tag=tests dep=wv2 dep=wvm_fixture dep=wvm_thread_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_snapshot_test.w -o bin/wvm_snapshot_test"
# wbuild: step="bin/wvm_snapshot_test" timeout=30000
import lib.testing
import lib.vmm.pool
import lib.file
import lib.str
import lib.process
import lib.dir


vm_cell* snapshot_test_image(char* path, char* mode, int argc):
	int fd = open(path, 0, 0)
	asserts(c"open snapshot fixture", fd >= 0)
	int length = file_size(fd)
	close(fd)
	char* image = file_read_text(path)
	asserts(c"read snapshot fixture", image != 0)
	vm_cell* cell = cell_new()
	asserts(c"allocate snapshot template", cell != 0)
	asserts(c"load snapshot fixture", cell_elf_load(cell, image, length))
	free(image)
	char** argv = strv_new(3)
	argv[0] = c"fixture"
	argv[1] = mode
	argv[2] = c"payload"
	asserts(c"snapshot stack", cell_stack(cell, argc, argv))
	free(cast(void*, argv))
	return cell


vm_cell* snapshot_test_template(char* mode):
	return snapshot_test_image(c"bin/wvm_fixture", mode, 3)


void test_snapshot_rejects_unsafe_capture():
	vm_cell* cell = cell_new()
	asserts(c"reject unloaded", cell_snapshot_create(cell) == 0)
	cell_free(cell)
	cell = snapshot_test_template(c"input")
	cell.started = 1
	asserts(c"reject started", cell_snapshot_create(cell) == 0)
	cell.started = 0
	cell.fs_state = cast(void*, 1)
	asserts(c"reject filesystem resources", cell_snapshot_create(cell) == 0)
	cell.fs_state = 0
	cell.net_state = cast(void*, 1)
	asserts(c"reject socket resources", cell_snapshot_create(cell) == 0)
	cell.net_state = 0
	cell.input_length = 1
	asserts(c"reject missing input", cell_snapshot_create(cell) == 0)
	cell.input_length = 0
	cell.input_pos = 1
	asserts(c"reject consumed input", cell_snapshot_create(cell) == 0)
	cell.input_pos = 0
	assert_equal(0, cell_snapshot_reset(cell))
	cell_free(cell)


void test_snapshot_cow_reset_and_lifetime():
	vm_cell* source = snapshot_test_template(c"input")
	source.input = c"a\x00b"
	source.input_length = 3
	source.max_threads = 4
	# An arbitrary page outside loaded segments must also survive capture.
	source.ram[CELL_USER_MIN + 123] = 41
	cell_snapshot* snapshot = cell_snapshot_create(source)
	asserts(c"capture ready cell", snapshot != 0)
	asserts(c"sparse immutable backing", snapshot.resident_pages > 0 && snapshot.resident_pages < 65536)
	assert_equal(15, sys_fcntl(snapshot.fd, F_GET_SEALS, 0))
	asserts(c"sealed against writes", write(snapshot.fd, c"x", 1) < 0)
	asserts(c"sealed against truncate", sys_ftruncate(snapshot.fd, 4096) < 0)
	vm_cell* first = cell_snapshot_clone(snapshot)
	vm_cell* second = cell_snapshot_clone(snapshot)
	asserts(c"two clones", first != 0 && second != 0)
	assert_equal(3, snapshot.references)
	int baseline_heap = source.heap_end
	int baseline_entry = source.entry
	cell_free(source)
	cell_snapshot_free(snapshot) # clones keep the sealed fd alive
	assert_equal(41, first.ram[CELL_USER_MIN + 123])
	first.ram[CELL_USER_MIN + 123] = 99
	first.ram[CELL_STACK_LOW] = 88
	first.input[0] = 120
	assert_equal(41, second.ram[CELL_USER_MIN + 123])
	assert_equal(0, second.ram[CELL_STACK_LOW])
	assert_equal(97, second.input[0])
	first.heap_end = CELL_HEAP_MAX
	first.mmap_next = CELL_IMAGE_MIN
	first.entry = 7
	first.max_threads = 64
	first.started = 1
	first.exited = 1
	first.status = 37
	first.fault_vector = 14
	first.fault_rip = 123
	first.last_exit = 2
	first.unsupported_syscall = 999
	first.input_pos = 3
	first.closed_fds = 7
	first.output_bytes = 3
	first.deadline_ms = 9999
	first.regs[0] = 99
	first.sregs[0] = 99
	string_append(first.output, c"old output")
	string_append(first.errors, c"old errors")
	asserts(c"reset clone", cell_snapshot_reset(first))
	assert_equal(41, first.ram[CELL_USER_MIN + 123])
	assert_equal(0, first.ram[CELL_STACK_LOW])
	assert_equal(97, first.input[0])
	assert_equal(baseline_heap, first.heap_end)
	assert_equal(baseline_entry, first.entry)
	assert_equal(CELL_USER_MIN, first.mmap_next)
	assert_equal(4, first.max_threads)
	assert_equal(0, first.started)
	assert_equal(0, first.exited)
	assert_equal(125, first.status)
	assert_equal(-1, first.fault_vector)
	assert_equal(0, first.fault_rip)
	assert_equal(0, first.last_exit)
	assert_equal(-1, first.unsupported_syscall)
	assert_equal(0, first.input_pos)
	assert_equal(0, first.closed_fds)
	assert_equal(0, first.output_bytes)
	assert_equal(0, first.output.length)
	assert_equal(0, first.errors.length)
	assert_equal(0, first.deadline_ms)
	assert_equal(0, first.regs[0])
	assert_equal(0, first.sregs[0])
	cell_free(second)
	asserts(c"last clone can still reset", cell_snapshot_reset(first))
	cell_free(first)


void test_snapshot_pool_capacity_and_reuse():
	vm_cell* source = snapshot_test_template(c"input")
	cell_snapshot* snapshot = cell_snapshot_create(source)
	asserts(c"pool snapshot", snapshot != 0)
	asserts(c"reject zero pool", cell_pool_new(snapshot, 0) == 0)
	asserts(c"reject excessive pool", cell_pool_new(snapshot, 257) == 0)
	cell_pool* pool = cell_pool_new(snapshot, 2)
	asserts(c"create pool", pool != 0)
	cell_snapshot_free(snapshot)
	cell_free(source)
	vm_cell* first = cell_pool_acquire(pool)
	vm_cell* second = cell_pool_acquire(pool)
	asserts(c"distinct leases", first != 0 && second != 0 && first != second)
	asserts(c"capacity bound", cell_pool_acquire(pool) == 0)
	first.ram[CELL_STACK_LOW] = 61
	asserts(c"release lease", cell_pool_release(pool, first))
	assert_equal(0, cell_pool_release(pool, first))
	vm_cell* stranger = cell_new()
	assert_equal(0, cell_pool_release(pool, stranger))
	cell_free(stranger)
	vm_cell* reused = cell_pool_acquire(pool)
	asserts(c"reuse allocation", reused == first)
	assert_equal(0, reused.ram[CELL_STACK_LOW])
	assert_equal(2, pool.active)
	assert_equal(2, pool.high_water)
	assert_equal(3, pool.acquisitions)
	assert_equal(1, pool.resets)
	assert_equal(1, pool.exhausted)
	cell_pool_free(pool) # also reclaims both outstanding leases


int snapshot_test_fd_count():
	list[dir_entry*] entries = dir_read(c"/proc/self/fd")
	asserts(c"enumerate descriptors", entries != 0)
	int count = entries.length
	dir_entries_free(entries)
	return count


void snapshot_execution_after_reset(int retained):
	int fd = kvm_open_system()
	if (fd < 0):
		println(c"SKIP: /dev/kvm unavailable (snapshot isolation/reset tests still ran)")
		return
	close(fd)
	int fd_count = snapshot_test_fd_count()
	vm_cell* source = snapshot_test_template(c"input")
	source.input = c"a\x00b"
	source.input_length = 3
	cell_snapshot* snapshot = cell_snapshot_create(source)
	asserts(c"execution snapshot", snapshot != 0)
	cell_pool* pool = 0
	if (retained): pool = cell_pool_new_retained(snapshot, 2)
	else: pool = cell_pool_new(snapshot, 2)
	asserts(c"execution pool", pool != 0)
	cell_free(source)
	cell_snapshot_free(snapshot)
	kvm_machine* original = pool.cells[0].machine
	for iteration in range(3):
		vm_cell* cell = cell_pool_acquire(pool)
		asserts(c"per-lease filesystem", cell_fs_configure(cell, c"bin", 0))
		asserts(c"per-lease network", cell_net_allow(cell, c"127.0.0.1", 9))
		assert_equal(64, cell_net_socket(cell, 2, 1, 6))
		asserts(c"run clone", cell_run(cell, 5000))
		assert_equal(0, cell.status)
		assert_equal(3, cell.output.length)
		assert_equal(97, cell.output.data[0])
		assert_equal(0, cell.output.data[1])
		assert_equal(98, cell.output.data[2])
		if (retained):
			char[416] fpu
			mem_fill[char](&fpu[0], 0, 416)
			assert_equal(0, sys_ioctl(cell.machine.cpu_fd, kvm_request(2, 416, 140), cast(int, &fpu[0])))
			fpu[160] = 77 # poison XMM0 before returning the lease
			assert_equal(0, sys_ioctl(cell.machine.cpu_fd, kvm_request(1, 416, 141), cast(int, &fpu[0])))
		asserts(c"reset executed clone", cell_pool_release(pool, cell))
		if (retained):
			char[416] fpu
			assert_equal(0, sys_ioctl(cell.machine.cpu_fd, kvm_request(2, 416, 140), cast(int, &fpu[0])))
			assert_equal(0, cast(int, fpu[160]))
		if (retained): asserts(c"vCPU retained", cell.machine == original && cell.thread_state != 0)
		else: asserts(c"vCPU resources reclaimed", cell.machine == 0 && cell.thread_state == 0)
		asserts(c"lease capabilities revoked", cell.fs_state == 0 && cell.net_state == 0)
		assert_equal(-13, cell_net_socket(cell, 2, 1, 6))
	assert_equal(3, pool.resets)
	cell_pool_free(pool)
	assert_equal(fd_count, snapshot_test_fd_count())


void snapshot_restores_fault_timeout_and_thread_state(int retained):
	int fd = kvm_open_system()
	if (fd < 0): return
	close(fd)
	int baseline_fds = snapshot_test_fd_count()
	list[char*] modes = new list[char*]
	modes.push(c"memory")
	modes.push(c"supervisor")
	modes.push(c"spin")
	modes.push(c"threads")
	for char* mode in modes:
		vm_cell* source = 0
		int expected = 0
		int timeout = 5000
		if (strcmp(mode, c"threads") == 0): source = snapshot_test_image(c"bin/wvm_thread_fixture", mode, 2)
		else: source = snapshot_test_template(mode)
		if (strcmp(mode, c"supervisor") == 0): expected = 139
		if (strcmp(mode, c"spin") == 0):
			expected = 124
			timeout = 20
		cell_snapshot* snapshot = cell_snapshot_create(source)
		asserts(c"capture fault/thread fixture", snapshot != 0)
		vm_cell* clone = cell_snapshot_clone(snapshot)
		asserts(c"clone fault/thread fixture", clone != 0)
		clone.retain_cpus = retained
		cell_snapshot_free(snapshot)
		cell_free(source)
		for iteration in range(2):
			asserts(c"execute restored state", cell_run(clone, timeout))
			assert_equal(expected, clone.status)
			asserts(c"never capture executed VM", cell_snapshot_create(clone) == 0)
			asserts(c"reset fault/thread fixture", cell_snapshot_reset(clone))
			if (retained): asserts(c"retain vCPU references", clone.machine != 0 && clone.thread_state != 0)
			else: asserts(c"clear all vCPU references", clone.machine == 0 && clone.thread_state == 0)
		cell_free(clone)
	__w_list_free(cast(__w_list*, modes))
	assert_equal(baseline_fds, snapshot_test_fd_count())


void test_snapshot_execution_after_reset():
	snapshot_execution_after_reset(0)
	snapshot_execution_after_reset(1)


void test_snapshot_restores_fault_timeout_and_thread_state():
	snapshot_restores_fault_timeout_and_thread_state(0)
	snapshot_restores_fault_timeout_and_thread_state(1)
