# Deterministic ptrace thread scheduling. Exactly one TID executes one
# checked instruction at a time; all other TIDs remain ptrace-stopped.
# Blocking guest syscalls and signal delivery are refused explicitly.
import libs.wgrind.decode_x64
import libs.wgrind.execute_images

const int WG_PTRACE_OPTIONS = 0x100049 # EXITKILL | TRACEEXIT | TRACECLONE | TRACESYSGOOD
const int WG_WAIT_ALL = 0x40000000

struct wg_execution_thread:
	wg_machine machine
	int active
	int source
	int clear_tid
	int reap_pending

struct wg_execution_mapping:
	int address
	int size
	int active

struct wg_threads:
	wg_context* context
	wg_execution_thread* slots
	wg_execution_mapping* mappings
	int mapping_count
	int limit
	int active
	int current
	int leader
	int clone_pending
	int clone_parent
	int clone_flags
	int clone_stack
	int clone_stack_low
	int clone_stack_high
	int clone_parent_tid
	int clone_child_tid
	int clone_tls


int wg_threads_init(wg_threads* threads, wg_context* c, int limit):
	threads.context = c
	threads.limit = limit
	threads.active = 0
	threads.current = 0
	threads.leader = 0
	threads.clone_pending = 0
	threads.mapping_count = 0
	if ((limit < 1) || (limit > 1024)): return wg_error(c, WG_INCOMPLETE, 0, limit, 0, 0)
	threads.mappings = cast(wg_execution_mapping*, wg_reserve(c, sizeof(wg_execution_mapping) * 4096))
	if (threads.mappings == 0): return 0
	threads.slots = cast(wg_execution_thread*, wg_reserve(c, sizeof(wg_execution_thread) * limit))
	if (threads.slots == 0): return 0
	for i in range(limit):
		wg_execution_thread fresh
		threads.slots[i] = fresh
		threads.slots[i].active = 0
		threads.slots[i].source = 0
		threads.slots[i].clear_tid = 0
		threads.slots[i].reap_pending = 0
	return 1


int wg_threads_find(wg_threads* threads, int tid):
	for i in range(threads.limit):
		if (threads.slots[i].active && (threads.slots[i].machine.pid == tid)): return i
	return -1


int wg_threads_add_initial(wg_threads* threads, wg_machine* machine):
	if (threads.context.error): return 0
	if (threads.active): return wg_native_incomplete(machine)
	threads.slots[0].machine = *machine
	threads.slots[0].active = 1
	threads.slots[0].source = 0
	threads.slots[0].clear_tid = 0
	threads.slots[0].reap_pending = 1
	threads.current = 0
	threads.active = 1
	threads.leader = machine.pid
	return 1


int wg_threads_rotate(wg_threads* threads, wg_machine* machine, int* source):
	if (threads.context.error): return 0
	int current = wg_threads_find(threads, machine.pid)
	if (current >= 0):
		threads.slots[current].machine = *machine
		threads.slots[current].source = *source
	if (threads.active == 0): return 0
	for n in range(1, threads.limit + 1):
		int next = (threads.current + n) % threads.limit
		if (threads.slots[next].active):
			*machine = threads.slots[next].machine
			*source = threads.slots[next].source
			threads.current = next
			return 1
	return wg_native_incomplete(machine)


# The single-step loop cannot leave one TID blocked in a kernel wait
# while holding all peers stopped. Refuse calls with unmodeled blocking
# semantics before execution; no unchecked PTRACE_CONT escape hatch.
int wg_threads_syscall(wg_threads* threads, wg_machine* machine, int number):
	if (threads.context.error): return 0
	if (threads.active < 2): return 1
	if ((number == 60) && (machine.pid == threads.leader)):
		int slot = wg_threads_find(threads, machine.pid)
		if ((slot >= 0) && threads.slots[slot].clear_tid): return wg_native_incomplete(machine)
	if ((number == 9) || (number == 10) || (number == 11) || (number == 12) || (number == 39) || (number == 56) || (number == 60) || (number == 102) || (number == 104) || (number == 107) || (number == 108) || (number == 158) || (number == 186) || (number == 218) || (number == 231) || (number == 435)): return 1
	return wg_error(threads.context, WG_INCOMPLETE, number, 0, machine.raw[16], 0)


int wg_threads_unmapping(wg_threads* threads, int address, int size):
	if (threads.context.error): return 0
	if (wg_range(address, size) == 0): return wg_error(threads.context, WG_INCOMPLETE, address, size, 0, 0)
	for i in range(threads.mapping_count):
		wg_execution_mapping* mapping = &threads.mappings[i]
		if (mapping.active && size && mapping.size):
			if (wg_less(address - mapping.address, mapping.size) || wg_less(mapping.address - address, size)): mapping.active = 0
	return 1


int wg_threads_mapping(wg_threads* threads, int address, int size):
	if (wg_threads_unmapping(threads, address, size) == 0): return 0
	int slot = -1
	for i in range(threads.mapping_count):
		if ((slot < 0) && (threads.mappings[i].active == 0)): slot = i
	if (slot < 0):
		if (threads.mapping_count == 4096): return wg_error(threads.context, WG_INCOMPLETE, address, size, 0, 0)
		slot = threads.mapping_count
		threads.mapping_count = threads.mapping_count + 1
	threads.mappings[slot].address = address
	threads.mappings[slot].size = size
	threads.mappings[slot].active = 1
	return 1


int wg_threads_arch_pre(wg_threads* threads, wg_machine* machine, int* args):
	if (threads.context.error): return 0
	int operation = args[0]
	if ((operation == 0x1001) || (operation == 0x1002)): return 1
	if ((operation == 0x1003) || (operation == 0x1004)):
		return wg_access(threads.context, args[1], 8, WG_WRITE, machine.raw[16])
	return wg_native_incomplete(machine)


int wg_threads_clone_pre(wg_threads* threads, wg_machine* machine, wg_images* images, int* args, int number):
	wg_context* c = threads.context
	int site = machine.raw[16]
	if (c.error): return 0
	if (threads.clone_pending || (threads.active == threads.limit)): return wg_native_incomplete(machine)
	int flags = 0
	int stack = 0
	int low = 0
	int high = 0
	int parent_tid = 0
	int child_tid = 0
	int tls = 0
	if (number == 56):
		flags = args[0]
		stack = args[1]
		parent_tid = args[2]
		child_tid = args[3]
		tls = args[4]
		# Linux merges adjacent VMAs, so /proc/maps cannot recover stack
		# allocation bounds. Use the recorded mmap event or live malloc
		# payload containing the requested top, never the merged mapping.
		if (images.context != c): return wg_native_incomplete(machine)
		for i in range(threads.mapping_count):
			wg_execution_mapping* mapping = &threads.mappings[i]
			if (mapping.active && (mapping.address < stack) && (stack <= mapping.address + mapping.size)):
				low = mapping.address
				high = mapping.address + mapping.size
		wg_block* block = c.live_root
		while (block != 0):
			if (wg_less(stack - 1, block.address)): block = block.left
			else if (wg_less(stack - 1 - block.address, block.size)):
				low = block.address
				high = block.address + block.size
				break
			else: block = block.right
		# A leading guard mapping is not part of the usable stack.
		while ((low > 0) && (low < stack - 128)):
			wg_page* page = wg_page_find(c, low)
			if (page == 0): low = (low & ~4095) + 4096
			else if (page.permissions[low & 4095] & WG_WRITE): break
			else: low = low + 1
	else if (number == 435):
		int address = args[0]
		int size = args[1]
		if ((size != 64) && (size != 80) && (size != 88)): return wg_native_incomplete(machine)
		if (wg_kernel_read(c, address, size, site) == 0): return 0
		int[11] fields
		for i in range(11): fields[i] = 0
		for i in range(size / 8):
			if (wg_native_reader(machine.pid, address + i * 8, 8, &fields[i]) == 0): return wg_native_incomplete(machine)
		# pidfd, nonzero exit signals, set_tid and cgroup placement need
		# additional process/namespace models, so reject them explicitly.
		if (fields[1] || fields[4] || fields[8] || fields[9] || fields[10]): return wg_native_incomplete(machine)
		flags = fields[0]
		child_tid = fields[2]
		parent_tid = fields[3]
		low = fields[5]
		if ((fields[6] <= 128) || (wg_range(low, fields[6]) == 0)): return wg_native_incomplete(machine)
		high = low + fields[6]
		stack = high
		tls = fields[7]
	else: return wg_native_incomplete(machine)
	# CLONE_VM, CLONE_SIGHAND, CLONE_THREAD are mandatory. Child-settid
	# is intentionally absent: its timing relative to the initial ptrace
	# stop needs a separate model. Parent-settid and child-cleartid work.
	int required = 0x10900
	int allowed = 0x3d0f00
	if (((flags & required) != required) || (flags & ~allowed) || (low <= 0) || (stack < low + 128) || (high < stack)):
		return wg_native_incomplete(machine)
	for i in range(threads.limit):
		wg_execution_thread* thread = &threads.slots[i]
		if (thread.active):
			if ((low < thread.machine.stack_high) && (thread.machine.stack_low < high)): return wg_native_incomplete(machine)
	# Do not poison a TLS area embedded below the initial stack pointer.
	# Such legacy layouts need an explicit stack extent (clone3) first.
	if ((flags & 0x80000) && (tls >= low) && (tls < stack)): return wg_native_incomplete(machine)
	if (wg_access(c, low, high - low, WG_WRITE, site) == 0): return 0
	if ((flags & 0x100000) && (wg_access(c, parent_tid, 4, WG_WRITE, site) == 0)): return 0
	if ((flags & 0x200000) && (wg_access(c, child_tid, 4, WG_WRITE, site) == 0)): return 0
	threads.clone_pending = 1
	threads.clone_parent = machine.pid
	threads.clone_flags = flags
	threads.clone_stack = stack
	threads.clone_stack_low = low
	threads.clone_stack_high = high
	threads.clone_parent_tid = parent_tid
	threads.clone_child_tid = child_tid
	threads.clone_tls = tls
	return 1


int wg_threads_clone_event(wg_threads* threads, wg_machine* parent, int* status):
	wg_context* c = threads.context
	if (c.error): return 0
	if ((threads.clone_pending == 0) || (threads.clone_parent != parent.pid) || ((*status >> 16) != 3)): return wg_native_incomplete(parent)
	int tid = 0
	if (sys_ptrace(0x4201, parent.pid, 0, cast(int, &tid)) < 0): return wg_native_incomplete(parent)
	int child_status = 0
	if ((tid <= 0) || (wait4(tid, &child_status, WG_WAIT_ALL, 0) != tid)): return wg_native_incomplete(parent)
	if (((child_status & 255) != 127) || (((child_status >> 8) & 255) != 19)): return wg_native_incomplete(parent)
	int slot = -1
	for i in range(threads.limit):
		if ((slot < 0) && (threads.slots[i].active == 0)): slot = i
	if (slot < 0): return wg_native_incomplete(parent)
	wg_execution_thread* child = &threads.slots[slot]
	child.machine = *parent
	child.machine.pid = tid
	child.machine.stack_low = threads.clone_stack_low
	child.machine.stack_high = threads.clone_stack_high
	child.source = 0
	child.clear_tid = 0
	child.reap_pending = 1
	if (threads.clone_flags & 0x200000): child.clear_tid = threads.clone_child_tid
	# Register the stopped child before any operation that can fail, so
	# teardown always knows about it and never leaves an untracked TID.
	child.active = 1
	threads.active = threads.active + 1
	if (sys_ptrace(0x4200, tid, 0, WG_PTRACE_OPTIONS) < 0): return wg_native_incomplete(parent)
	if (sys_ptrace(12, tid, 0, cast(int, &child.machine.raw[0])) < 0): return wg_native_incomplete(parent)
	if (child.machine.raw[19] != threads.clone_stack): return wg_native_incomplete(parent)
	if ((threads.clone_flags & 0x80000) && (child.machine.raw[21] != threads.clone_tls)): return wg_native_incomplete(parent)
	for reg in range(16): child.machine.registers.values[reg] = child.machine.raw[wg_native_register_offset(reg)]
	wg_value value
	wg_value_set(&value, 0, 0, 0)
	if (wg_register_write(c, &child.machine.registers, 0, 0, 8, 0, parent.raw[16], &value) == 0): return 0
	wg_value_set(&value, threads.clone_stack, 0, 0)
	if (wg_register_write(c, &child.machine.registers, 4, 0, 8, 0, parent.raw[16], &value) == 0): return 0
	wg_value_set(&value, child.machine.raw[11], 0, 0)
	if (wg_register_write(c, &child.machine.registers, 1, 0, 8, 0, parent.raw[16], &value) == 0): return 0
	int flag_mask = parent.flags.cf.undefined | (parent.flags.pf.undefined << 2) | (parent.flags.af.undefined << 4) | (parent.flags.zf.undefined << 6) | (parent.flags.sf.undefined << 7) | (parent.flags.of.undefined << 11)
	int flag_origin = 0
	if (parent.flags.cf.undefined): flag_origin = parent.flags.cf.origin
	else if (parent.flags.pf.undefined): flag_origin = parent.flags.pf.origin
	else if (parent.flags.af.undefined): flag_origin = parent.flags.af.origin
	else if (parent.flags.zf.undefined): flag_origin = parent.flags.zf.origin
	else if (parent.flags.sf.undefined): flag_origin = parent.flags.sf.origin
	else if (parent.flags.of.undefined): flag_origin = parent.flags.of.origin
	wg_value_set(&value, child.machine.raw[6], flag_mask, flag_origin)
	if (wg_register_write(c, &child.machine.registers, 11, 0, 8, 0, parent.raw[16], &value) == 0): return 0
	if (wg_mark(c, threads.clone_stack_low, threads.clone_stack - threads.clone_stack_low - 128, 0, 0, 0) == 0): return 0
	if (wg_mark(c, threads.clone_stack - 128, 128, 3, 255, parent.raw[16]) == 0): return 0
	if ((threads.clone_flags & 0x100000) && (wg_kernel_write(c, threads.clone_parent_tid, 4, parent.raw[16]) == 0)): return 0
	# EVENT_CLONE is before the parent's syscall return. Stop explicitly
	# at its syscall-exit boundary rather than skipping a user instruction.
	if (sys_ptrace(24, parent.pid, 0, 0) < 0): return wg_native_incomplete(parent)
	if (wait4(parent.pid, status, WG_WAIT_ALL, 0) != parent.pid): return wg_native_incomplete(parent)
	if (((*status & 255) != 127) || (((*status >> 8) & 255) != 133)): return wg_native_incomplete(parent)
	if (sys_ptrace(12, parent.pid, 0, cast(int, &parent.raw[0])) < 0): return wg_native_incomplete(parent)
	threads.clone_pending = 0
	*status = (5 << 8) | 127
	return 1


int wg_threads_post(wg_threads* threads, wg_machine* machine, int number, int result, int* args):
	if (threads.context.error): return 0
	if ((number == 56) || (number == 435)):
		if ((result < 0) && (result >= -4095)):
			threads.clone_pending = 0
			return 1
		if (threads.clone_pending): return wg_native_incomplete(machine)
	if ((number == 158) && (result == 0) && ((args[0] == 0x1003) || (args[0] == 0x1004))):
		if (wg_kernel_write(threads.context, args[1], 8, machine.raw[16]) == 0): return 0
	if ((number == 218) && (result >= 0)):
		int slot = wg_threads_find(threads, machine.pid)
		if (slot < 0): return wg_native_incomplete(machine)
		threads.slots[slot].clear_tid = args[0]
	return 1


int wg_threads_exit(wg_threads* threads, wg_machine* machine):
	int slot = wg_threads_find(threads, machine.pid)
	if (slot < 0): return wg_native_incomplete(machine)
	wg_execution_thread* thread = &threads.slots[slot]
	thread.active = 0
	thread.reap_pending = 0
	threads.active = threads.active - 1
	if (thread.clear_tid):
		if (wg_kernel_write(threads.context, thread.clear_tid, 4, machine.raw[16]) == 0): return 0
	# Only the active stack footprint is invalidated: adjacent TLS and
	# user-owned data outside the stack are not part of its lifetime.
	return wg_mark(threads.context, machine.raw[19] - 128, machine.stack_high - machine.raw[19] + 128, 0, 0, 0)


int wg_threads_roots(wg_threads* threads, wg_machine* current, wg_leaks* leaks):
	if (threads.context.error): return 0
	for i in range(threads.limit):
		wg_execution_thread* slot = &threads.slots[i]
		if (slot.active == 0): continue
		wg_machine* machine = &slot.machine
		if (machine.pid == current.pid): machine = current
		for reg in range(16):
			if (machine.registers.undefined[reg] == 0):
				if (wg_leaks_root_value(leaks, machine.registers.values[reg]) == 0): return 0
		# The x64 ABI red zone contains live leaf-function locals too.
		int bottom = machine.raw[19] - 128
		if ((bottom < machine.stack_low) || (machine.raw[19] > machine.stack_high)): return wg_native_incomplete(machine)
		if (wg_leaks_stack_range(leaks, bottom, machine.stack_high - bottom) == 0): return 0
	return 1


int wg_threads_reap(int tid, int* status):
	while (1):
		int result = wait4(tid, status, WG_WAIT_ALL, 0)
		if (result == -4): continue
		if (result < 0): return result == -10 # already reaped (ECHILD)
		if ((*status & 255) != 127): return 1
		# A dying tracee may still stop at TRACEEXIT. Continuing from
		# that terminal event cannot execute another user instruction.
		if ((*status >> 16) != 6): return 0
		if (sys_ptrace(7, tid, 0, 0) < 0): return 0


void wg_threads_kill(wg_threads* threads):
	if (threads.leader > 0): kill(threads.leader, 9)
	# Reap nonleaders first: Linux withholds the zombie leader's final
	# wait status until its traced siblings have themselves been reaped.
	for pass_index in range(2):
		for i in range(threads.limit):
			wg_execution_thread* thread = &threads.slots[i]
			if (thread.reap_pending && ((thread.machine.pid == threads.leader) == pass_index)):
				int status = 0
				wg_threads_reap(thread.machine.pid, &status)
				thread.reap_pending = 0
				thread.active = 0
	threads.active = 0


int wg_threads_exit_event(wg_threads* threads, wg_machine* machine, int* status):
	wg_context* c = threads.context
	if (c.error): return 0
	if ((*status >> 16) != 6): return wg_native_incomplete(machine)
	int slot = wg_threads_find(threads, machine.pid)
	if (slot < 0): return wg_native_incomplete(machine)
	int exit_status = 0
	if (sys_ptrace(0x4201, machine.pid, 0, cast(int, &exit_status)) < 0): return wg_native_incomplete(machine)
	if (exit_status & 127): return wg_native_incomplete(machine)
	if ((machine.raw[10] == 231) && (threads.active > 1)):
		# exit_group already forbids future user execution in every peer.
		# Complete terminal stops/reaping in an order that cannot deadlock.
		if (sys_ptrace(7, machine.pid, 0, 0) < 0): return wg_native_incomplete(machine)
		wg_threads_kill(threads)
		*status = exit_status
		return 1
	if (sys_ptrace(7, machine.pid, 0, 0) < 0): return wg_native_incomplete(machine)
	int deferred = (machine.pid == threads.leader) && (threads.active > 1)
	if (deferred == 0):
		int waited = 0
		if (wg_threads_reap(machine.pid, &waited) == 0): return wg_native_incomplete(machine)
		if ((waited & 127) != 0): return wg_native_incomplete(machine)
	if (wg_threads_exit(threads, machine) == 0): return 0
	if (deferred): threads.slots[slot].reap_pending = 1
	if (threads.active == 0):
		for i in range(threads.limit):
			wg_execution_thread* thread = &threads.slots[i]
			if (thread.reap_pending):
				int waited = 0
				if (wg_threads_reap(thread.machine.pid, &waited) == 0): return wg_native_incomplete(machine)
				thread.reap_pending = 0
	*status = exit_status
	return 1
