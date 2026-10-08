# Paused cell checkpoints on this host. External capabilities, shared regions,
# retained pools and pending external I/O are deliberately rejected. Runnable
# and futex-waiting threads retain their per-vCPU state and relative deadlines.
# RAM is materialized once into a sealed sparse memfd; restores are CoW clones.
# CPU identity, architectural state and syscall bookkeeping are restored. CPU
# clock progression and host deadlines are not deterministic replay services.
import lib.vmm.snapshot

struct cell_live_cpu:
	char* cpu
	char* cpuid
	char* msrs

struct cell_live_snapshot:
	cell_snapshot* memory
	cell_live_cpu** cpus
	cell_thread* threads
	int capacity
	int current
	int next_tid
	int rotate
	int input_pos
	int closed_fds
	int output_bytes
	int syscall_count
	int instruction_count
	int random_state
	int clock_ticks
	int replay_pos
	string_builder* output
	string_builder* errors
	string_builder* transcript
	string_builder* replay


void cell_live_free(cell_live_snapshot* snapshot):
	if (snapshot == 0): return
	cell_snapshot_free(snapshot.memory)
	for i in range(snapshot.capacity):
		cell_live_cpu* cpu = snapshot.cpus[i]
		if (cpu != 0):
			free(cpu.cpu)
			free(cpu.cpuid)
			free(cpu.msrs)
			free(cpu)
	free(cast(void*, snapshot.cpus))
	free(cast(void*, snapshot.threads))
	string_free(snapshot.output)
	string_free(snapshot.errors)
	string_free(snapshot.transcript)
	string_free(snapshot.replay)
	free(snapshot)


# Complete an outstanding IO/hypercall before reading registers. immediate_exit
# stops before the next guest instruction and also works at debug stops.
int cell_pause_sync(vm_cell* cell):
	if (cell.paused == 0 || cell.machine == 0 || cell_timer_run != 0): return 0
	cell.machine.run[1] = 1
	int result = kvm_run(cell.machine)
	cell.machine.run[1] = 0
	if (result != -4): return cell_fail(cell, c"cannot synchronize paused vCPU")
	cell_threads* threads = cast(cell_threads*, cell.thread_state)
	threads.slots[threads.current].hypercall_pending = 0
	return kvm_get_regs(cell.machine, cell.regs) == 0


int cell_live_cpu_capture(cell_live_cpu* snapshot, kvm_machine* vm):
	char* pristine = vm.reset_state
	vm.reset_state = 0
	int result = kvm_cell_checkpoint(vm)
	snapshot.cpu = vm.reset_state
	vm.reset_state = pristine
	if (result == 0): return 0
	snapshot.cpuid = cast(char*, malloc(10248))
	mem_fill[char](snapshot.cpuid, 0, 10248)
	save_int32(snapshot.cpuid, 256)
	if (sys_ioctl(vm.cpu_fd, kvm_request(3, 8, 145), cast(int, snapshot.cpuid)) != 0): return 0
	if (load_int32(snapshot.cpuid) < 1 || load_int32(snapshot.cpuid) > 256): return 0
	# Gate/TLS MSRs complement GET_SREGS; preserve syscall return conventions
	# including a pause inside the supervisor trampoline.
	snapshot.msrs = cast(char*, malloc(168))
	mem_fill[char](snapshot.msrs, 0, 168)
	save_int32(snapshot.msrs, 10)
	int[10] indices
	indices[0] = (49152 << 16) | 129 # STAR
	indices[1] = (49152 << 16) | 130 # LSTAR
	indices[2] = (49152 << 16) | 131 # CSTAR
	indices[3] = (49152 << 16) | 132 # FMASK
	indices[4] = (49152 << 16) | 258 # KERNEL_GS_BASE
	indices[5] = 372 # SYSENTER_CS
	indices[6] = 373 # SYSENTER_ESP
	indices[7] = 374 # SYSENTER_EIP
	indices[8] = (49152 << 16) | 259 # TSC_AUX
	indices[9] = 631 # PAT
	for i in range(10): save_int32(snapshot.msrs + 8 + i * 16, indices[i])
	return sys_ioctl(vm.cpu_fd, kvm_request(3, 8, 136), cast(int, snapshot.msrs)) == 10


cell_live_snapshot* cell_live_capture_internal(vm_cell* cell, cell_live_snapshot* parent):
	if (cell == 0): return 0
	if (cell.paused == 0 || cell.started == 0 || cell.exited || cell.thread_state == 0 || cell_timer_run != 0):
		cell_fail(cell, c"live checkpoint requires a paused cell")
		return 0
	if (cell.fs_state != 0 || cell.net_state != 0 || cell.region_state != 0 || cell.retain_cpus || cell.debug_control != 0):
		cell_fail(cell, c"live checkpoint rejects external capabilities, retained CPUs and active debugger controls")
		return 0
	cell_threads* threads = cast(cell_threads*, cell.thread_state)
	if (threads.capacity < 1 || threads.capacity > 64 || cell.max_threads != threads.capacity):
		cell_fail(cell, c"invalid live thread capacity")
		return 0
	for i in range(threads.capacity):
		if (threads.slots[i].state == 3 || threads.slots[i].io_pending):
			cell_fail(cell, c"live checkpoint rejects pending external I/O")
			return 0
	cell_live_snapshot* snapshot = new cell_live_snapshot()
	mem_fill[char](cast(char*, snapshot), 0, sizeof(cell_live_snapshot))
	snapshot.output = string_new()
	snapshot.errors = string_new()
	snapshot.transcript = string_new()
	snapshot.replay = string_new()
	snapshot.capacity = threads.capacity
	snapshot.current = threads.current
	snapshot.next_tid = threads.next_tid
	snapshot.rotate = threads.rotate
	snapshot.cpus = cast(cell_live_cpu**, malloc(threads.capacity * sizeof(cell_live_cpu*)))
	mem_fill[char](cast(char*, snapshot.cpus), 0, threads.capacity * sizeof(cell_live_cpu*))
	snapshot.threads = cast(cell_thread*, malloc(threads.capacity * sizeof(cell_thread)))
	int ok = 1
	for i in range(threads.capacity):
		if (threads.slots[i].cpu != 0):
			threads.current = i
			cell.machine = threads.slots[i].cpu
			if (cell_pause_sync(cell) == 0):
				ok = 0
				break
			cell_live_cpu* cpu = new cell_live_cpu()
			mem_fill[char](cast(char*, cpu), 0, sizeof(cell_live_cpu))
			snapshot.cpus[i] = cpu
			if (cell_live_cpu_capture(cpu, cell.machine) == 0):
				ok = 0
				break
	threads.current = snapshot.current
	cell.machine = threads.slots[threads.current].cpu
	if (kvm_get_regs(cell.machine, cell.regs) != 0): ok = 0
	if (ok == 0):
		cell_fail(cell, c"cannot capture live vCPU state")
		cell_live_free(snapshot)
		return 0
	mem_copy[char](cast(char*, snapshot.threads), cast(char*, threads.slots), threads.capacity * sizeof(cell_thread))
	int now = time_monotonic_ms()
	for i in range(threads.capacity):
		cell_thread* t = &snapshot.threads[i]
		t.cpu = 0
		# Zero means no timeout. A negative value means already expired.
		if (t.wake_ms != 0):
			t.wake_ms = t.wake_ms - now
			if (t.wake_ms <= 0): t.wake_ms = -1
		if (t.poll_deadline_ms != 0):
			t.poll_deadline_ms = t.poll_deadline_ms - now
			if (t.poll_deadline_ms <= 0): t.poll_deadline_ms = -1
	# Reuse the proven immutable RAM writer with a non-owning ready view.
	# All live I/O and service state is copied explicitly below.
	vm_cell* view = new vm_cell()
	mem_copy[char](cast(char*, view), cast(char*, cell), sizeof(vm_cell))
	view.started = 0
	view.paused = 0
	view.machine = 0
	view.thread_state = 0
	view.thread_cleanup = 0
	view.thread_io_wait = 0
	view.input_pos = 0
	view.closed_fds = 0
	view.replay = 0
	view.clock_ticks = 0
	view.random_state = view.deterministic_seed + 1
	view.output = string_new()
	view.errors = string_new()
	view.transcript = string_new()
	if (parent == 0): snapshot.memory = cell_snapshot_create(view)
	else: snapshot.memory = cell_snapshot_create_layer(view, parent.memory)
	string_free(view.output)
	string_free(view.errors)
	string_free(view.transcript)
	free(view)
	if (snapshot.memory == 0):
		cell_fail(cell, c"cannot capture live RAM")
		cell_live_free(snapshot)
		return 0
	snapshot.input_pos = cell.input_pos
	snapshot.closed_fds = cell.closed_fds
	snapshot.output_bytes = cell.output_bytes
	snapshot.syscall_count = cell.syscall_count
	snapshot.instruction_count = cell.instruction_count
	snapshot.random_state = cell.random_state
	snapshot.clock_ticks = cell.clock_ticks
	snapshot.replay_pos = cell.replay_pos
	string_append_bytes(snapshot.output, cell.output.data, cell.output.length)
	string_append_bytes(snapshot.errors, cell.errors.data, cell.errors.length)
	string_append_bytes(snapshot.transcript, cell.transcript.data, cell.transcript.length)
	if (cell.replay != 0): string_append_bytes(snapshot.replay, cell.replay, cell.replay_length)
	return snapshot


vm_cell* cell_live_restore(cell_live_snapshot* snapshot):
	if (snapshot == 0 || cell_timer_run != 0): return 0
	vm_cell* cell = cell_snapshot_clone(snapshot.memory)
	if (cell == 0): return 0
	cell.live_restored = 1
	int ok = cell_prepare(cell)
	cell_threads* threads = cast(cell_threads*, cell.thread_state)
	if (ok && threads.capacity != snapshot.capacity): ok = 0
	if (ok):
		for i in range(snapshot.capacity):
			cell_live_cpu* saved = snapshot.cpus[i]
			if (saved == 0): continue
			if (i != 0):
				threads.slots[i].cpu = cast(kvm_machine*, malloc(sizeof(kvm_machine)))
				if (kvm_create_cpu(threads.slots[i].cpu, threads.slots[0].cpu, i) == 0):
					ok = 0
					break
			kvm_machine* cpu = threads.slots[i].cpu
			if (sys_ioctl(cpu.cpu_fd, kvm_request(1, 8, 144), cast(int, saved.cpuid)) != 0):
				ok = 0
				break
			cpu.cpuid_set = 1
			char* pristine = cpu.reset_state
			cpu.reset_state = saved.cpu
			ok = kvm_cell_restore(cpu)
			cpu.reset_state = pristine
			if (ok): ok = sys_ioctl(cpu.cpu_fd, kvm_request(1, 8, 137), cast(int, saved.msrs)) == 10
			if (ok == 0): break
	if (ok == 0):
		cell_free(cell)
		return 0
	int now = time_monotonic_ms()
	for i in range(snapshot.capacity):
		kvm_machine* cpu = threads.slots[i].cpu
		mem_copy[char](cast(char*, &threads.slots[i]), cast(char*, &snapshot.threads[i]), sizeof(cell_thread))
		cell_thread* t = &threads.slots[i]
		t.cpu = cpu
		if (t.wake_ms < 0): t.wake_ms = now
		else if (t.wake_ms > 0): t.wake_ms = now + t.wake_ms
		if (t.poll_deadline_ms < 0): t.poll_deadline_ms = now
		else if (t.poll_deadline_ms > 0): t.poll_deadline_ms = now + t.poll_deadline_ms
	threads.current = snapshot.current
	threads.next_tid = snapshot.next_tid
	threads.rotate = snapshot.rotate
	cell.machine = threads.slots[threads.current].cpu
	if (kvm_get_regs(cell.machine, cell.regs) != 0 || kvm_get_sregs(cell.machine, cell.sregs) != 0):
		cell_free(cell)
		return 0
	cell.input_pos = snapshot.input_pos
	cell.closed_fds = snapshot.closed_fds
	cell.output_bytes = snapshot.output_bytes
	cell.syscall_count = snapshot.syscall_count
	cell.instruction_count = snapshot.instruction_count
	cell.random_state = snapshot.random_state
	cell.clock_ticks = snapshot.clock_ticks
	cell.replay_pos = snapshot.replay_pos
	string_append_bytes(cell.output, snapshot.output.data, snapshot.output.length)
	string_append_bytes(cell.errors, snapshot.errors.data, snapshot.errors.length)
	string_append_bytes(cell.transcript, snapshot.transcript.data, snapshot.transcript.length)
	if (snapshot.replay.length != 0):
		cell.replay = cast(char*, malloc(snapshot.replay.length))
		mem_copy[char](cell.replay, snapshot.replay.data, snapshot.replay.length)
		cell.replay_length = snapshot.replay.length
	cell.started = 1
	cell.paused = 1
	return cell


cell_live_snapshot* cell_live_capture(vm_cell* cell):
	return cell_live_capture_internal(cell, 0)


cell_live_snapshot* cell_live_capture_layer(vm_cell* cell, cell_live_snapshot* parent):
	if (parent == 0): return 0
	return cell_live_capture_internal(cell, parent)
