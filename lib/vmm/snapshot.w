# Immutable Linux x64 cell templates. Only ready, never-run cells can be
# captured: live descriptors, vCPUs and pending syscalls are not snapshots.
# Callers serialize this API with cell_run, just like ordinary cell runs.
# Clones retain backing independently of the template owner's lifetime.
import lib.vmm.cell

struct cell_snapshot:
	int fd
	int references
	int entry
	int stack
	int heap_start
	int heap_end
	int mmap_next
	int max_threads
	char* input
	int input_length
	int resident_pages


void cell_snapshot_free(cell_snapshot* snapshot):
	if (snapshot == 0): return
	snapshot.references = snapshot.references - 1
	if (snapshot.references != 0): return
	close(snapshot.fd)
	free(snapshot.input)
	free(snapshot)


void cell_snapshot_detach(vm_cell* cell):
	cell_snapshot_free(cast(cell_snapshot*, cell.snapshot_state))
	cell.snapshot_state = 0
	cell.snapshot_cleanup = 0


cell_snapshot* cell_snapshot_create(vm_cell* cell):
	if (__word_size__ != 8): return 0
	if (cell == 0): return 0
	if (cell.loaded == 0 || cell.stack == 0 || cell.started || cell.machine != 0 || cell_timer_run != 0):
		cell_fail(cell, c"snapshot requires a ready, never-run cell")
		return 0
	if (cell.fs_state != 0 || cell.fs_cleanup != 0 || cell.net_state != 0 || cell.net_cleanup != 0 || cell.thread_state != 0 || cell.thread_cleanup != 0):
		cell_fail(cell, c"snapshot cannot capture external resources")
		return 0
	if (cell.input_length < 0 || cell.input_length > CELL_OUTPUT_LIMIT || (cell.input_length != 0 && cell.input == 0)):
		cell_fail(cell, c"invalid snapshot input")
		return 0
	if (cell.input_pos != 0 || cell.output.length != 0 || cell.errors.length != 0 || cell.closed_fds != 0):
		cell_fail(cell, c"snapshot requires pristine I/O state")
		return 0
	int fd = memfd_create(c"wvm-cell-template", MFD_CLOEXEC | MFD_ALLOW_SEALING)
	if (fd < 0):
		cell_fail(cell, c"snapshot memfd creation failed")
		return 0
	if (sys_ftruncate(fd, CELL_RAM_SIZE) < 0):
		close(fd)
		cell_fail(cell, c"snapshot backing allocation failed")
		return 0
	int address = mmap_fd(0, CELL_RAM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
	if (address < 0 && address > -4096):
		close(fd)
		cell_fail(cell, c"snapshot backing mapping failed")
		return 0
	# Preserve sparse backing by storing only nonzero pages. Read every
	# page: mincore alone cannot distinguish untouched zero pages from
	# nonzero pages evicted to swap. Capture is an up-front full scan;
	# clones and resets do not copy the image.
	int pages = CELL_RAM_SIZE / 4096
	int copied = 0
	for i in range(pages):
		char* page = cell.ram + i * 4096
		int nonzero = 0
		int offset = 0
		while (offset < 4096 && nonzero == 0):
			if (load_int64(page + offset) != 0): nonzero = 1
			offset = offset + 8
		if (nonzero):
			mem_copy[char](cast(char*, address) + i * 4096, page, 4096)
			copied = copied + 1
	munmap(address, CELL_RAM_SIZE)
	int seals = F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL
	if (sys_fcntl(fd, F_ADD_SEALS, seals) < 0):
		close(fd)
		cell_fail(cell, c"snapshot capture or sealing failed")
		return 0
	cell_snapshot* snapshot = new cell_snapshot()
	mem_fill[char](cast(char*, snapshot), 0, sizeof(cell_snapshot))
	snapshot.fd = fd
	snapshot.references = 1
	snapshot.entry = cell.entry
	snapshot.stack = cell.stack
	snapshot.heap_start = cell.heap_start
	snapshot.heap_end = cell.heap_end
	snapshot.mmap_next = cell.mmap_next
	snapshot.max_threads = cell.max_threads
	snapshot.input_length = cell.input_length
	if (cell.input_length != 0):
		snapshot.input = malloc(cell.input_length)
		mem_copy[char](snapshot.input, cell.input, cell.input_length)
	snapshot.resident_pages = copied
	return snapshot


# Reset revokes per-run resources and discards private pages. Ordinary
# clones destroy CPUs; retained pools restore pristine CPU state instead.
# Page tables, heap/stack, I/O, watchdog and fault state reset together.
int cell_snapshot_reset(vm_cell* cell):
	if (cell == 0): return 0
	if (cell_timer_run != 0): return cell_fail(cell, c"cannot reset during cell execution")
	cell_snapshot* snapshot = cast(cell_snapshot*, cell.snapshot_state)
	if (snapshot == 0): return cell_fail(cell, c"cell has no snapshot")
	cell_threads* retained = 0
	if (cell.retain_cpus && cell.thread_state != 0):
		retained = cast(cell_threads*, cell.thread_state)
		# Detach CPU ownership while revoking all per-lease host resources.
		cell.machine = 0
		cell.thread_state = 0
		cell.thread_cleanup = 0
	cell_runtime_free(cell)
	if (retained != 0):
		cell.thread_state = cast(void*, retained)
		cell.thread_cleanup = cast(void*, cell_threads_free)
		cell.thread_io_wait = cast(void*, cell_thread_io_wait)
		cell.machine = retained.slots[0].cpu
		retained.current = 0
		retained.rotate = 0
		retained.next_tid = 2
		for i in range(retained.capacity):
			kvm_machine* cpu = retained.slots[i].cpu
			if (cpu != 0 && kvm_cell_restore(cpu) == 0):
				cell_runtime_free(cell)
				return cell_fail(cell, c"retained vCPU reset failed")
			mem_fill[char](cast(char*, &retained.slots[i]), 0, sizeof(cell_thread))
			retained.slots[i].cpu = cpu
		retained.slots[0].tid = 1
		retained.slots[0].state = 1
		retained.slots[0].gate = CELL_TRAMPOLINE
	if (madvise(cast(int, cell.ram), CELL_RAM_SIZE, MADV_DONTNEED) < 0):
		return cell_fail(cell, c"snapshot reset failed")
	free(cell.owned_input)
	cell.owned_input = 0
	cell.input = 0
	cell.input_length = snapshot.input_length
	if (snapshot.input_length != 0):
		cell.owned_input = malloc(snapshot.input_length)
		mem_copy[char](cell.owned_input, snapshot.input, snapshot.input_length)
		cell.input = cell.owned_input
	cell.input_pos = 0
	cell.entry = snapshot.entry
	cell.stack = snapshot.stack
	cell.heap_start = snapshot.heap_start
	cell.heap_end = snapshot.heap_end
	cell.mmap_next = snapshot.mmap_next
	cell.max_threads = snapshot.max_threads
	cell.loaded = 1
	cell.started = 0
	cell.status = 125
	cell.exited = 0
	cell.fault_vector = -1
	cell.fault_rip = 0
	cell.last_exit = 0
	cell.unsupported_syscall = -1
	cell.output_bytes = 0
	cell.closed_fds = 0
	cell.deadline_ms = 0
	cell.error = 0
	mem_fill[char](cell.regs, 0, KVM_REGS_SIZE)
	mem_fill[char](cell.sregs, 0, KVM_SREGS_SIZE)
	string_free(cell.output)
	string_free(cell.errors)
	cell.output = string_new()
	cell.errors = string_new()
	if (retained != 0): return cell_cpu_setup(cell)
	return 1


vm_cell* cell_snapshot_clone(cell_snapshot* snapshot):
	if (snapshot == 0 || __word_size__ != 8): return 0
	int address = mmap_fd(0, CELL_RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE, snapshot.fd, 0)
	if (address < 0 && address > -4096): return 0
	vm_cell* cell = cell_new()
	if (cell == 0):
		munmap(address, CELL_RAM_SIZE)
		return 0
	munmap(cast(int, cell.ram), CELL_RAM_SIZE)
	cell.ram = cast(char*, address)
	snapshot.references = snapshot.references + 1
	cell.snapshot_state = cast(void*, snapshot)
	cell.snapshot_cleanup = cast(void*, cell_snapshot_detach)
	if (cell_snapshot_reset(cell) == 0):
		cell_free(cell)
		return 0
	return cell
