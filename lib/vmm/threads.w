# Bounded guest threads: one KVM vCPU per slot, scheduled on one host
# thread. No host clone/futex ever receives a guest address or flags.
import lib.vmm.x64
import lib.time

struct cell_thread:
	kvm_machine* cpu
	int tid
	int state # 0 unused/dead, 1 runnable, 2 futex wait
	int clear_tid
	int wait_address
	int wait_private
	int wake_ms
	int gate
	int io_fd
	int io_events
	int io_pending
	int syscall_nr
	int poll_deadline_ms

struct cell_threads:
	cell_thread* slots
	int current
	int next_tid
	int capacity
	int rotate


void cell_threads_free(vm_cell* cell);


int cell_thread_io_wait(vm_cell* cell, int fd, int events):
	cell_threads* state = cast(cell_threads*, cell.thread_state)
	cell_thread* t = &state.slots[state.current]
	t.state = 3
	t.io_fd = fd
	t.io_events = events
	t.io_pending = 1
	t.wake_ms = time_monotonic_ms() + 1
	t.syscall_nr = load_int64(cell.regs)
	state.rotate = 1
	return -4097


# Complete parked socket calls before the host descriptor can be reused.
# A ready thread still has io_pending until its syscall is retried, so it
# needs cancellation too. Keep the currently executing thread's regs intact.
int cell_thread_cancel_io(vm_cell* cell, int fd):
	if (cell.thread_state == 0): return 0
	cell_threads* state = cast(cell_threads*, cell.thread_state)
	char[144] registers # struct kvm_regs
	for i in range(state.capacity):
		cell_thread* t = &state.slots[i]
		if (t.io_pending && t.io_fd == fd):
			if (kvm_get_regs(t.cpu, &registers[0]) < 0): return -5
			save_int64(&registers[0], -9)
			if (kvm_set_regs(t.cpu, &registers[0]) < 0): return -5
			t.io_pending = 0
			t.io_fd = -1
			t.state = 1
	return 0


int cell_thread_retry(vm_cell* cell):
	cell_threads* state = cast(cell_threads*, cell.thread_state)
	cell_thread* t = &state.slots[state.current]
	if (t.io_pending == 0): return 0
	if (kvm_get_regs(t.cpu, cell.regs) < 0): return -1
	save_int64(cell.regs, t.syscall_nr)
	t.io_pending = 0
	return 1


int cell_threads_init(vm_cell* cell):
	if (cell.max_threads < 1 || cell.max_threads > 64): return cell_fail(cell, c"max threads must be 1..64")
	cell_threads* state = new cell_threads()
	mem_fill[char](cast(char*, state), 0, sizeof(cell_threads))
	state.slots = malloc(sizeof(cell_thread) * cell.max_threads)
	mem_fill[char](cast(char*, state.slots), 0, sizeof(cell_thread) * cell.max_threads)
	state.capacity = cell.max_threads
	state.next_tid = 2
	state.slots[0].cpu = cell.machine
	state.slots[0].tid = 1
	state.slots[0].state = 1
	state.slots[0].gate = CELL_TRAMPOLINE
	cell.thread_state = cast(void*, state)
	cell.thread_cleanup = cast(void*, cell_threads_free)
	cell.thread_io_wait = cast(void*, cell_thread_io_wait)
	return 1


void cell_threads_free(vm_cell* cell):
	if (cell.thread_state == 0): return
	cell_threads* state = cast(cell_threads*, cell.thread_state)
	cell.machine = state.slots[0].cpu
	for i in range(1, state.capacity):
		if (state.slots[i].cpu != 0):
			kvm_destroy(state.slots[i].cpu)
			free(state.slots[i].cpu)
	free(state.slots)
	free(state)
	cell.thread_state = 0


int cell_thread_gate(vm_cell* cell):
	cell_threads* state = cast(cell_threads*, cell.thread_state)
	return state.slots[state.current].gate


int cell_threads_choose(vm_cell* cell):
	cell_threads* state = cast(cell_threads*, cell.thread_state)
	int now = time_monotonic_ms()
	for i in range(state.capacity):
		cell_thread* t = &state.slots[i]
		if (t.state == 3 && t.io_fd < 0 && now >= t.wake_ms): t.state = 1
		if (t.state == 3 && t.io_fd >= 0):
			char[8] descriptor
			mem_fill[char](&descriptor[0], 0, 8)
			save_int32(&descriptor[0], t.io_fd)
			save_int16(&descriptor[4], t.io_events)
			if (syscall(7, cast(int, &descriptor[0]), 1, 0) > 0): t.state = 1
		if (t.state == 2 && t.wake_ms != 0 && now >= t.wake_ms):
			if (kvm_get_regs(t.cpu, cell.regs) < 0): return -1
			save_int64(cell.regs, -110)
			if (kvm_set_regs(t.cpu, cell.regs) < 0): return -1
			t.state = 1
	int first = state.current
	if (state.rotate || state.slots[first].state != 1): first = first + 1
	state.rotate = 0
	for j in range(state.capacity):
		int index = (first + j) % state.capacity
		if (state.slots[index].state == 1):
			if (index != state.current):
				kvm_machine* next = state.slots[index].cpu
				if (kvm_get_sregs(next, cell.sregs) < 0): return -1
				int root = 4096
				if (load_int64(cell.sregs + 240) == root): root = 61440
				save_int64(cell.sregs + 240, root)
				if (kvm_set_sregs(next, cell.sregs) < 0): return -1
			state.current = index
			cell.machine = state.slots[index].cpu
			return 1
	return 0


int cell_thread_wake(vm_cell* cell, int address, int count, int private):
	cell_threads* state = cast(cell_threads*, cell.thread_state)
	int woke = 0
	for i in range(state.capacity):
		cell_thread* t = &state.slots[i]
		if (woke < count && t.state == 2 && t.wait_address == address && t.wait_private == private):
			t.state = 1
			woke = woke + 1
	return woke


int cell_thread_clone(vm_cell* cell, int flags, int stack, int parent_tid, int child_tid, int tls):
	cell_threads* state = cast(cell_threads*, cell.thread_state)
	# Shared address space, files, signal handlers, and thread group only.
	# W's builtin also requests CLONE_IO|CLONE_PARENT. No namespace,
	# process, vfork, exit signal, tracing, or arbitrary clone mode.
	int allowed = (1 << 31) | 256 | 512 | 1024 | 2048 | 32768 | 65536 | 524288 | 1048576 | 2097152 | 16777216
	# The W builtin sign-extends its 32-bit immediate on x64.
	if (flags < 0): flags = flags & ((1 << 32) - 1)
	if ((flags & ~allowed) != 0 || (flags & 69376) != 69376): return -22
	if (cell_range(cell, stack, 8, 1) == 0): return -14
	if ((flags & 1048576) && cell_range(cell, parent_tid, 4, 1) == 0): return -14
	if ((flags & (2097152 | 16777216)) && cell_range(cell, child_tid, 4, 1) == 0): return -14
	if ((flags & 524288) && tls != 0 && cell_range(cell, tls, 8, 0) == 0): return -14
	int slot = -1
	for i in range(1, state.capacity):
		if (slot < 0 && state.slots[i].state == 0): slot = i
	if (slot < 0): return -11
	cell_thread* t = &state.slots[slot]
	if (t.cpu == 0):
		t.cpu = malloc(sizeof(kvm_machine))
		if (kvm_create_cpu(t.cpu, state.slots[0].cpu, slot) == 0):
			kvm_destroy(t.cpu)
			free(t.cpu)
			t.cpu = 0
			return -11
		if (kvm_set_supported_cpuid(t.cpu) < 0): return -5
	t.gate = 1048576 + slot * 512
	cell_cpu_trampoline(cell, t.gate)
	char[312] special
	char[144] registers
	if (kvm_get_sregs(cell.machine, &special[0]) < 0): return -5
	if (flags & 524288): save_int64(&special[72], tls)
	if (kvm_set_sregs(t.cpu, &special[0]) < 0): return -5
	if (kvm_copy_xsave(t.cpu, cell.machine) < 0): return -5
	int star = (16 << 48) | (8 << 32)
	if (kvm_set_msr(t.cpu, (49152 << 16) | 129, star) < 0): return -5
	if (kvm_set_msr(t.cpu, (49152 << 16) | 130, t.gate) < 0): return -5
	if (kvm_set_msr(t.cpu, (49152 << 16) | 132, 263936) < 0): return -5
	mem_copy[char](&registers[0], cell.regs, 144)
	save_int64(&registers[0], 0)
	save_int64(&registers[48], stack)
	# The parent has a pending OUT completion. The new vCPU starts
	# directly after OUT, then returns to userspace via its own SYSRET.
	save_int64(&registers[128], t.gate + 2)
	if (kvm_set_regs(t.cpu, &registers[0]) < 0): return -5
	t.tid = state.next_tid
	state.next_tid = state.next_tid + 1
	t.clear_tid = 0
	t.io_pending = 0
	t.poll_deadline_ms = 0
	if (flags & 2097152): t.clear_tid = child_tid
	if (flags & 1048576): save_int32(cell.ram + parent_tid, t.tid)
	if (flags & 16777216): save_int32(cell.ram + child_tid, t.tid)
	t.state = 1
	state.rotate = 1
	return t.tid


int cell_thread_syscall(vm_cell* cell):
	int nr = load_int64(cell.regs)
	if (cell.thread_state == 0): return -4096
	cell_threads* state = cast(cell_threads*, cell.thread_state)
	cell_thread* t = &state.slots[state.current]
	int a = load_int64(cell.regs + 40)
	int b = load_int64(cell.regs + 32)
	int c = load_int64(cell.regs + 24)
	if (nr == 186): return t.tid
	if (nr == 24):
		state.rotate = 1
		return 0
	if (nr == 56): return cell_thread_clone(cell, a, b, c, load_int64(cell.regs + 80), load_int64(cell.regs + 64))
	if (nr == 218):
		# Linux accepts this pointer and only attempts the store on exit.
		t.clear_tid = a
		return t.tid
	if (nr == 60 || nr == 231):
		t.state = 0
		if (t.clear_tid != 0 && cell_range(cell, t.clear_tid, 4, 1)):
			save_int32(cell.ram + t.clear_tid, 0)
			cell_thread_wake(cell, t.clear_tid, 1, 0)
		int live = 0
		for i in range(state.capacity):
			if (state.slots[i].state != 0): live = live + 1
		if (nr == 231 || live == 0):
			cell.exited = 1
			cell.status = a & 255
		state.rotate = 1
		return 0
	if (nr == 158):
		if (a != 4097 && a != 4098 && a != 4099 && a != 4100): return -22
		if (kvm_get_sregs(cell.machine, cell.sregs) < 0): return -5
		int field = 96
		if (a == 4098 || a == 4099): field = 72
		if (a == 4099 || a == 4100):
			if (cell_range(cell, b, 8, 1) == 0): return -14
			save_int64(cell.ram + b, load_int64(cell.sregs + field))
			return 0
		if (b != 0 && cell_range(cell, b, 8, 0) == 0): return -14
		save_int64(cell.sregs + field, b)
		return kvm_set_sregs(cell.machine, cell.sregs)
	if (nr == 202):
		if (a % 4 != 0): return -22
		if (cell_range(cell, a, 4, 0) == 0): return -14
		if (b != 0 && b != 1 && b != 128 && b != 129): return -38
		if (b == 1 || b == 129):
			if (c < 0): return -22
			return cell_thread_wake(cell, a, c, b & 128)
		if ((load_int32(cell.ram + a) & ((1 << 32) - 1)) != (c & ((1 << 32) - 1))): return -11
		int timeout = load_int64(cell.regs + 80)
		t.wake_ms = 0
		if (timeout != 0):
			if (cell_range(cell, timeout, 16, 0) == 0): return -14
			int seconds = load_int64(cell.ram + timeout)
			int nanos = load_int64(cell.ram + timeout + 8)
			if (seconds < 0 || nanos < 0 || nanos >= 1000000000): return -22
			if (seconds == 0 && nanos == 0): return -110
			# Clamp beyond the cell's deadline; avoid timespec overflow.
			t.wake_ms = cell.deadline_ms
			if (seconds < 600): t.wake_ms = time_monotonic_ms() + seconds * 1000 + (nanos + 999999) / 1000000
		t.state = 2
		t.wait_address = a
		t.wait_private = b & 128
		state.rotate = 1
		return 0
	return -4096
