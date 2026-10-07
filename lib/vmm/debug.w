# In-process debugger for cells: stop before entry, inspect paused registers and
# checked guest memory, and execute one instruction through KVM guest-debug.
# Serialized host calls; selecting and stepping one thread freezes its siblings.
# Hardware breakpoints apply to all guest threads. No host-process fallback.
import lib.vmm.live_snapshot


int cell_debug_control(vm_cell* cell, int flags):
	cell_threads* threads = cast(cell_threads*, cell.thread_state)
	int control = flags & 3
	for i in range(4):
		if (cell.debug_breakpoints[i] != 0): control = control | 131073
	for i in range(threads.capacity):
		if (threads.slots[i].cpu != 0):
			int stepping = (flags & 2) != 0 && i == threads.current
			if (cell_cpu_debug_apply(cell, threads.slots[i].cpu, stepping) == 0): return cell_fail(cell, c"KVM guest debug unavailable")
	cell.debug_control = control
	return 1


int cell_debug_start(vm_cell* cell):
	if (cell == 0): return 0
	if (cell.started || cell.loaded == 0 || cell.stack == 0 || cell_timer_run != 0): return cell_fail(cell, c"debugger requires a loaded, unstarted cell")
	if (cell_prepare(cell) == 0): return 0
	if (cell_debug_control(cell, 0) == 0): return 0
	cell.started = 1
	cell.paused = 1
	return 1


int cell_debug_step(vm_cell* cell, int timeout_ms):
	if (cell == 0): return 0
	if (cell.paused == 0 || cell.exited || cell_timer_run != 0): return cell_fail(cell, c"step requires a paused cell")
	cell_threads* threads = cast(cell_threads*, cell.thread_state)
	if (threads.slots[threads.current].state != 1): return cell_fail(cell, c"selected thread is blocked")
	if (cell_pause_sync(cell) == 0): return 0
	if (cell.debug_hit):
		save_int64(cell.regs + 136, load_int64(cell.regs + 136) | 65536) # RF
		if (kvm_set_regs(cell.machine, cell.regs) < 0): return 0
	if (cell_debug_control(cell, 3) == 0): return 0 # ENABLE | SINGLESTEP
	cell.pause_after = 0
	int result = cell_resume(cell, timeout_ms)
	if (cell_debug_control(cell, 0) == 0): return 0
	return result


int cell_debug_registers(vm_cell* cell, char* registers):
	if (cell == 0 || registers == 0): return 0
	if (cell.paused == 0 || cell_timer_run != 0): return cell_fail(cell, c"register inspection requires a paused cell")
	if (cell_pause_sync(cell) == 0): return 0
	mem_copy[char](registers, cell.regs, KVM_REGS_SIZE)
	return 1


int cell_debug_read(vm_cell* cell, int address, char* bytes, int length):
	if (cell == 0 || bytes == 0): return 0
	if (cell.paused == 0 || cell_timer_run != 0 || length < 0 || length > 1048576): return 0
	if (cell_range(cell, address, length, 0) == 0): return 0
	mem_copy[char](bytes, cell.ram + address, length)
	return 1


# Respect guest page permissions; changing code/breakpoint bytes requires a
# distinct debugger capability and is not implicit in memory inspection.
int cell_debug_write(vm_cell* cell, int address, char* bytes, int length):
	if (cell == 0 || bytes == 0): return 0
	if (cell.paused == 0 || cell_timer_run != 0 || length < 0 || length > 1048576): return 0
	if (cell_range(cell, address, length, 1) == 0): return 0
	mem_copy[char](cell.ram + address, bytes, length)
	return 1


int cell_debug_continue(vm_cell* cell, int timeout_ms):
	if (cell == 0 || cell.paused == 0): return 0
	if (cell_pause_sync(cell) == 0): return 0
	if (cell.debug_hit):
		# RF suppresses an execute breakpoint for this one instruction, so
		# continuing a breakpoint does not immediately stop at the same RIP.
		save_int64(cell.regs + 136, load_int64(cell.regs + 136) | 65536)
		if (kvm_set_regs(cell.machine, cell.regs) < 0): return 0
	if (cell_debug_control(cell, 0) == 0): return 0
	return cell_resume(cell, timeout_ms)


int cell_debug_breakpoint(vm_cell* cell, int slot, int address):
	if (cell == 0 || cell.paused == 0 || slot < 0 || slot > 3 || cell_timer_run != 0): return 0
	if (cell_range(cell, address, 1, 0) == 0): return 0
	if (load_int64(cell_pte(cell, address)) < 0): return cell_fail(cell, c"breakpoint requires executable guest memory")
	int previous = cell.debug_breakpoints[slot]
	cell.debug_breakpoints[slot] = address
	if (cell_debug_control(cell, 0)): return 1
	cell.debug_breakpoints[slot] = previous
	cell_debug_control(cell, 0)
	return 0


int cell_debug_delete(vm_cell* cell, int slot):
	if (cell == 0 || cell.paused == 0 || slot < 0 || slot > 3 || cell_timer_run != 0): return 0
	cell.debug_breakpoints[slot] = 0
	return cell_debug_control(cell, 0)


int cell_debug_breakpoint_address(vm_cell* cell, int slot):
	if (cell == 0 || slot < 0 || slot > 3): return 0
	return cell.debug_breakpoints[slot]


int cell_debug_threads(vm_cell* cell):
	if (cell == 0 || cell.thread_state == 0): return 0
	cell_threads* threads = cast(cell_threads*, cell.thread_state)
	return threads.capacity


int cell_debug_thread_tid(vm_cell* cell, int index):
	if (cell == 0 || cell.thread_state == 0): return 0
	cell_threads* threads = cast(cell_threads*, cell.thread_state)
	if (index < 0 || index >= threads.capacity || threads.slots[index].state == 0): return 0
	return threads.slots[index].tid


int cell_debug_thread_state(vm_cell* cell, int tid):
	if (cell == 0 || cell.thread_state == 0): return -1
	cell_threads* threads = cast(cell_threads*, cell.thread_state)
	for i in range(threads.capacity):
		if (threads.slots[i].tid == tid && threads.slots[i].state != 0): return threads.slots[i].state
	return -1


int cell_debug_thread_select(vm_cell* cell, int tid):
	if (cell == 0 || cell.paused == 0 || cell_timer_run != 0): return 0
	cell_threads* threads = cast(cell_threads*, cell.thread_state)
	for i in range(threads.capacity):
		if (threads.slots[i].tid == tid && threads.slots[i].state != 0):
			threads.current = i
			threads.rotate = 0
			cell.machine = threads.slots[i].cpu
			cell.debug_hit = 0
			return kvm_get_regs(cell.machine, cell.regs) == 0
	return 0
