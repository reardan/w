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
	int syscall_abi
	int hypercall_count
	cell_hypercall_sites hypercall_sites
	int max_syscalls
	int max_instructions
	int deterministic
	int deterministic_seed
	char* input
	int input_length
	int resident_pages
	cell_snapshot* parent
	char* changed_pages
	int depth


void cell_snapshot_free(cell_snapshot* snapshot):
	if (snapshot == 0): return
	snapshot.references = snapshot.references - 1
	if (snapshot.references != 0): return
	close(snapshot.fd)
	cell_snapshot_free(snapshot.parent)
	free(snapshot.changed_pages)
	free(snapshot.input)
	free(snapshot)


void cell_snapshot_detach(vm_cell* cell):
	cell_snapshot_free(cast(cell_snapshot*, cell.snapshot_state))
	cell.snapshot_state = 0
	cell.snapshot_cleanup = 0


# Map the oldest immutable backing once, then overlay changed page runs.
# Linux cannot stack MAP_PRIVATE files; disjoint fixed page ranges retain
# the latest layer's backing while unchanged ranges keep the parent's pages.
int cell_snapshot_map(cell_snapshot* snapshot):
	if (snapshot.parent == 0): return mmap_fd(0, CELL_RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE, snapshot.fd, 0)
	int address = cell_snapshot_map(snapshot.parent)
	if (address < 0 && address > -4096): return address
	int page = 0
	while (page < CELL_RAM_SIZE / 4096):
		if (snapshot.changed_pages[page] == 0):
			page = page + 1
			continue
		int start = page
		while (page < CELL_RAM_SIZE / 4096 && snapshot.changed_pages[page] != 0): page = page + 1
		int mapped = mmap_fd(address + start * 4096, (page - start) * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | 16, snapshot.fd, start * 4096)
		if (mapped < 0 && mapped > -4096):
			munmap(address, CELL_RAM_SIZE)
			return mapped
	return address


cell_snapshot* cell_snapshot_create_impl(vm_cell* cell, cell_snapshot* parent):
	if (__word_size__ != 8): return 0
	if (cell == 0): return 0
	if (parent != 0 && parent.depth >= 16):
		cell_fail(cell, c"snapshot layer depth limit exceeded")
		return 0
	if (cell.loaded == 0 || cell.stack == 0 || cell.started || cell.machine != 0 || cell_timer_run != 0):
		cell_fail(cell, c"snapshot requires a ready, never-run cell")
		return 0
	if (cell.transcript.length != 0 || cell.clock_ticks != 0 || (cell.deterministic && cell.random_state != cell.deterministic_seed + 1)):
		cell_fail(cell, c"snapshot requires pristine deterministic services")
		return 0
	if (cell.region_state != 0 || cell.replay != 0):
		cell_fail(cell, c"snapshot cannot capture shared regions or replay verification")
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
	int baseline = 0
	char* changed = 0
	if (parent != 0):
		baseline = cell_snapshot_map(parent)
		if (baseline < 0 && baseline > -4096):
			munmap(address, CELL_RAM_SIZE)
			close(fd)
			cell_fail(cell, c"cannot map parent snapshot")
			return 0
		changed = cast(char*, malloc(CELL_RAM_SIZE / 4096))
		mem_fill[char](changed, 0, CELL_RAM_SIZE / 4096)
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
			int previous = 0
			if (parent != 0): previous = load_int64(cast(char*, baseline) + i * 4096 + offset)
			if (load_int64(page + offset) != previous): nonzero = 1
			offset = offset + 8
		if (nonzero):
			mem_copy[char](cast(char*, address) + i * 4096, page, 4096)
			copied = copied + 1
			if (changed != 0): changed[i] = 1
	munmap(address, CELL_RAM_SIZE)
	if (parent != 0): munmap(baseline, CELL_RAM_SIZE)
	int seals = F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL
	if (sys_fcntl(fd, F_ADD_SEALS, seals) < 0):
		close(fd)
		free(changed)
		cell_fail(cell, c"snapshot capture or sealing failed")
		return 0
	cell_snapshot* snapshot = new cell_snapshot()
	mem_fill[char](cast(char*, snapshot), 0, sizeof(cell_snapshot))
	snapshot.fd = fd
	snapshot.references = 1
	snapshot.parent = parent
	snapshot.changed_pages = changed
	if (parent != 0):
		parent.references = parent.references + 1
		snapshot.depth = parent.depth + 1
	snapshot.entry = cell.entry
	snapshot.stack = cell.stack
	snapshot.heap_start = cell.heap_start
	snapshot.heap_end = cell.heap_end
	snapshot.mmap_next = cell.mmap_next
	snapshot.max_threads = cell.max_threads
	snapshot.syscall_abi = cell.syscall_abi
	snapshot.hypercall_count = cell.hypercall_count
	snapshot.hypercall_sites = cell.hypercall_sites
	snapshot.max_syscalls = cell.max_syscalls
	snapshot.max_instructions = cell.max_instructions
	snapshot.deterministic = cell.deterministic
	snapshot.deterministic_seed = cell.deterministic_seed
	snapshot.input_length = cell.input_length
	if (cell.input_length != 0):
		snapshot.input = cast(char*, malloc(cell.input_length))
		mem_copy[char](snapshot.input, cell.input, cell.input_length)
	snapshot.resident_pages = copied
	return snapshot


cell_snapshot* cell_snapshot_create(vm_cell* cell):
	return cell_snapshot_create_impl(cell, 0)


# O(RAM) comparison, O(changed pages) storage, bounded depth. Explicit zero
# pages override nonzero parents too. This needs no privileged userfaultfd.
cell_snapshot* cell_snapshot_create_layer(vm_cell* cell, cell_snapshot* parent):
	if (parent == 0): return 0
	return cell_snapshot_create_impl(cell, parent)


# Reset revokes per-run resources and discards private pages. Ordinary
# clones destroy CPUs; retained pools restore pristine CPU state instead.
# Page tables, heap/stack, I/O, watchdog and fault state reset together.
int cell_snapshot_reset(vm_cell* cell):
	if (cell == 0): return 0
	if (cell.live_restored): return cell_fail(cell, c"live restores require cell_live_restore, not ready reset")
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
	for i in range(4): cell.debug_breakpoints[i] = 0
	cell.debug_hit = 0
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
			if (cpu != 0 && (cell_cpu_debug_apply(cell, cpu, 0) == 0 || kvm_cell_restore(cpu) == 0)):
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
		cell.owned_input = cast(char*, malloc(snapshot.input_length))
		mem_copy[char](cell.owned_input, snapshot.input, snapshot.input_length)
		cell.input = cell.owned_input
	cell.input_pos = 0
	cell.entry = snapshot.entry
	cell.stack = snapshot.stack
	cell.heap_start = snapshot.heap_start
	cell.heap_end = snapshot.heap_end
	cell.mmap_next = snapshot.mmap_next
	cell.max_threads = snapshot.max_threads
	cell.syscall_abi = snapshot.syscall_abi
	cell.hypercall_count = snapshot.hypercall_count
	cell.hypercall_sites = snapshot.hypercall_sites
	cell.max_syscalls = snapshot.max_syscalls
	cell.max_instructions = snapshot.max_instructions
	cell.instruction_count = 0
	cell.syscall_count = 0
	cell.deterministic = snapshot.deterministic
	cell.deterministic_seed = snapshot.deterministic_seed
	cell.random_state = snapshot.deterministic_seed + 1
	cell.clock_ticks = 0
	string_clear(cell.transcript)
	free(cell.replay)
	cell.replay = 0
	cell.replay_length = 0
	cell.replay_pos = 0
	cell.loaded = 1
	cell.started = 0
	cell.paused = 0
	cell.pause_after = 0
	cell.debug_control = 0
	cell.debug_exit = 0
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
	if (retained != 0):
		if (cell.syscall_abi && cell_hypercall_patch(cell, kvm_hypercall_opcode(cell.machine)) == 0): return 0
		return cell_cpu_setup(cell)
	return 1


vm_cell* cell_snapshot_clone(cell_snapshot* snapshot):
	if (snapshot == 0 || __word_size__ != 8): return 0
	int address = cell_snapshot_map(snapshot)
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
