# One-shot cell execution. Linux x64, bounded guest threads per cell.
# Owns SIGALRM during execution: callers must serialize runs and not use
# an active ITIMER_REAL. The previous signal disposition is restored.
# A periodic timer preempts KVM_RUN; a monotonic deadline bounds the run.
import lib.vmm.syscalls
import lib.signal

int cell_timer_expired
char* cell_timer_run
int cell_alarm_thunk


void cell_alarm(int signum, int context):
	cell_timer_expired = 1
	if (cell_timer_run != 0): cell_timer_run[1] = 1 # immediate_exit


int cell_fault_has_error(int vector):
	return vector == 8 || vector == 10 || vector == 11 || vector == 12 || vector == 13 || vector == 14 || vector == 17 || vector == 21 || vector == 29 || vector == 30


void cell_record_fault(vm_cell* cell):
	cell.fault_vector = load_int64(cell.regs) & 255
	int sp = load_int64(cell.regs + 48)
	if (cell_fault_has_error(cell.fault_vector)): sp = sp + 8
	if (sp >= 589824 && sp <= 1048576 - 24): cell.fault_rip = load_int64(cell.ram + sp)
	cell.status = 139
	if (cell.fault_vector == 0): cell.status = 136
	if (cell.fault_vector == 6): cell.status = 132
	cell.exited = 1
	cell_fail(cell, c"guest exception")


# Prepare once for retained pools, or lazily for ordinary one-shot cells.
int cell_prepare(vm_cell* cell):
	if (cell.thread_state != 0): return 1
	if (cell.machine != 0): return cell_fail(cell, c"incomplete CPU setup")
	cell.machine = cast(kvm_machine*, malloc(sizeof(kvm_machine)))
	if (kvm_create(cell.machine) == 0): return cell_fail(cell, c"KVM unavailable or VM creation failed")
	if (cell.syscall_abi && kvm_enable_vmcall(cell.machine) == 0): return cell_fail(cell, c"KVM ring-3 vmcall interception unavailable")
	if (kvm_set_memory(cell.machine, 0, 0, cell.ram, CELL_RAM_SIZE) < 0): return cell_fail(cell, c"KVM memory registration failed")
	if (cell.retain_cpus && kvm_cell_checkpoint(cell.machine) == 0): return cell_fail(cell, c"vCPU checkpoint failed")
	if (cell_cpu_setup(cell) == 0): return 0
	return cell_threads_init(cell)


int cell_run_internal(vm_cell* cell, int timeout_ms, int resuming):
	if (cell.loaded == 0 || cell.stack == 0): return cell_fail(cell, c"cell is not loaded")
	if (resuming):
		if (cell.started == 0 || cell.paused == 0 || cell.exited || cell.thread_state == 0): return cell_fail(cell, c"resume requires a paused cell")
	else if (cell.started): return cell_fail(cell, c"cell execution is one-shot")
	if (timeout_ms < 1 || timeout_ms > 600000): return cell_fail(cell, c"timeout must be 1..600000 ms")
	if (cell_timer_run != 0): return cell_fail(cell, c"concurrent cell runs are unsupported")
	if (cell.max_instructions < 0 || cell.max_instructions > 1000000000): return cell_fail(cell, c"max instructions must be 0..1000000000")
	if (cell.max_instructions > 0 && cell.max_threads != 1): return cell_fail(cell, c"instruction budget requires one guest thread")
	if (cell.max_instructions > 0 && cell.instruction_count >= cell.max_instructions):
		cell.status = 125
		cell.exited = 1
		cell.paused = 0
		return cell_fail(cell, c"guest instruction limit exceeded")
	if (cell.max_syscalls < 1 || cell.max_syscalls > 1000000000): return cell_fail(cell, c"max syscalls must be 1..1000000000")
	if (cell.deterministic && (cell.max_threads != 1 || cell.fs_state != 0 || cell.net_state != 0 || cell.region_state != 0)):
		return cell_fail(cell, c"deterministic services require one thread and no external capabilities")
	cell.started = 1
	cell.paused = 0
	cell.debug_exit = 0
	cell.debug_hit = 0
	if (cell_prepare(cell) == 0): return 0
	kvm_machine* vm = cell.machine
	if (cell.max_instructions > 0 && cell_cpu_debug_apply(cell, vm, 1) == 0): return cell_fail(cell, c"instruction budget requires KVM single-step support")
	char[32] old_timer
	mem_fill[char](&old_timer[0], 0, 32)
	if (syscall(36, 0, cast(int, &old_timer[0]), 0) < 0): return cell_fail(cell, c"getitimer failed")
	if (load_int64(&old_timer[16]) != 0 || load_int64(&old_timer[24]) != 0): return cell_fail(cell, c"ITIMER_REAL is already active")
	# An embedding caller may have SIGALRM blocked. Preserve its mask,
	# but unblock our watchdog while the guest runs. Refuse a preexisting
	# pending alarm rather than consuming a signal owned by the caller.
	int alarm_mask = 8192
	int old_mask = 0
	if (syscall7(14, 0, cast(int, &alarm_mask), cast(int, &old_mask), 8, 0, 0) < 0): return cell_fail(cell, c"cannot block SIGALRM")
	int pending = 0
	int pending_status = syscall(127, cast(int, &pending), 8, 0)
	if (pending_status < 0 || (pending & alarm_mask)):
		syscall7(14, 2, cast(int, &old_mask), 0, 8, 0, 0)
		return cell_fail(cell, c"SIGALRM is already pending")
	char[32] old_action
	if (rt_sigaction(14, 0, cast(int*, &old_action[0])) < 0):
		syscall7(14, 2, cast(int, &old_mask), 0, 8, 0, 0)
		return cell_fail(cell, c"cannot read SIGALRM disposition")
	# Reuse the thunk across cells; allocating a fresh one for every run
	# would eventually exhaust lib.signal's single executable page.
	if (cell_alarm_thunk == 0):
		signal_thunk_init()
		cell_alarm_thunk = signal_emit_handler_thunk(cast(int, cell_alarm))
	char[32] action
	mem_fill[char](&action[0], 0, 32)
	save_int64(&action[0], cell_alarm_thunk)
	save_int64(&action[8], 67108868) # SA_SIGINFO | SA_RESTORER
	save_int64(&action[16], signal_restorer)
	if (rt_sigaction(14, cast(int*, &action[0]), 0) < 0):
		syscall7(14, 2, cast(int, &old_mask), 0, 8, 0, 0)
		return cell_fail(cell, c"cannot install SIGALRM watchdog")
	char[32] timer
	mem_fill[char](&timer[0], 0, 32)
	save_int64(&timer[8], 5000) # periodic five millisecond timeslice
	save_int64(&timer[24], 5000)
	cell.deadline_ms = time_monotonic_ms() + timeout_ms
	cell_timer_expired = 0
	cell_timer_run = vm.run
	int armed = syscall(38, 0, cast(int, &timer[0]), 0)
	if (armed < 0): cell_fail(cell, c"setitimer failed")
	if (syscall7(14, 1, cast(int, &alarm_mask), 0, 8, 0, 0) < 0):
		armed = -1
		cell_fail(cell, c"cannot unblock SIGALRM")
	int timed_out = 0
	while (armed == 0 && cell.exited == 0):
		if (time_monotonic_ms() >= cell.deadline_ms):
			timed_out = 1
			break
		if (cell_timer_expired):
			cell_threads* threads = cast(cell_threads*, cell.thread_state)
			threads.rotate = 1
			cell_timer_expired = 0
		int runnable = 1
		if (cell.debug_control & 2):
			cell_threads* stepping_threads = cast(cell_threads*, cell.thread_state)
			if (stepping_threads.slots[stepping_threads.current].state != 1):
				cell.paused = 1
				break
		else: runnable = cell_threads_choose(cell)
		if (runnable < 0):
			cell_fail(cell, c"cannot resume guest thread")
			break
		if (runnable == 0):
			sleep_ms(1)
			continue
		vm = cell.machine
		cell_timer_run = vm.run
		vm.run[1] = 0
		int retry = cell_thread_retry(cell)
		if (retry < 0):
			cell_fail(cell, c"cannot retry guest I/O")
			break
		if (retry):
			int retried = cell_syscall(cell)
			save_int64(cell.regs, retried)
			cell_threads* retry_threads = cast(cell_threads*, cell.thread_state)
			if (retry_threads.slots[retry_threads.current].hypercall_pending): save_int64(vm.run + 56, retried)
			if (kvm_set_regs(vm, cell.regs) < 0):
				cell_fail(cell, c"cannot resume guest I/O")
				break
			if (retried == -4097): continue
		cell_threads* running_threads = cast(cell_threads*, cell.thread_state)
		running_threads.slots[running_threads.current].hypercall_pending = 0
		int status = kvm_run(vm)
		if (status == -4): continue # EINTR, including the wall timer
		if (status < 0):
			cell_fail(cell, c"KVM_RUN failed")
			break
		cell.last_exit = load_int32(vm.run + 8)
		if (cell.last_exit == KVM_EXIT_INTR): continue
		if (kvm_get_regs(vm, cell.regs) < 0):
			cell_fail(cell, c"KVM_GET_REGS failed")
			break
		if (cell.last_exit == 4 && (cell.debug_control != 0 || cell.max_instructions > 0)): # KVM_EXIT_DEBUG
			int dr6 = load_int64(vm.run + 48)
			if (dr6 & 16384): cell.instruction_count = cell.instruction_count + 1
			if (cell.max_instructions > 0 && cell.instruction_count >= cell.max_instructions):
				cell.status = 125
				cell.exited = 1
				cell_fail(cell, c"guest instruction limit exceeded")
				break
			for i in range(4):
				if (dr6 & (1 << i)): cell.debug_hit = i + 1
			if ((cell.debug_control & 2) || cell.debug_hit != 0):
				cell.paused = 1
				cell.debug_exit = 1
				break
			continue
		int hypercall = cell.last_exit == KVM_EXIT_XEN
		if (hypercall):
			if (cell.syscall_abi == 0 || load_int32(vm.run + 32) != 1 || load_int32(vm.run + 40) != 1 || load_int32(vm.run + 44) != 3):
				cell_fail(cell, c"invalid guest hypercall exit")
				break
		else if (cell.last_exit != KVM_EXIT_IO):
			cell_fail(cell, c"unexpected KVM exit")
			break
		if (hypercall == 0 && (vm.run[32] != 1 || vm.run[33] != 1 || load_int32(vm.run + 36) != 1)):
			cell_fail(cell, c"invalid guest I/O exit")
			break
		int port = load_int16(vm.run + 34)
		int rip = load_int64(cell.regs + 128)
		if (hypercall == 0 && port == 234 && rip >= 32773 && rip < 36864 && (rip - 32773) % 16 == 0):
			cell_record_fault(cell)
			break
		if (hypercall == 0 && (port != 233 || rip != cell_thread_gate(cell))):
			cell_fail(cell, c"I/O outside syscall gate")
			break
		if (cell.syscall_count >= cell.max_syscalls):
			cell_fail(cell, c"guest syscall limit exceeded")
			cell.status = 125
			cell.exited = 1
			break
		cell.syscall_count = cell.syscall_count + 1
		int syscall_number = load_int64(cell.regs)
		int result = cell_syscall(cell)
		save_int64(cell.regs, result)
		if (kvm_set_regs(vm, cell.regs) < 0):
			cell_fail(cell, c"KVM_SET_REGS failed")
			break
		if (hypercall):
			# KVM completes this instruction on its next run. Parked threads
			# keep their result slot live; pause/checkpoint drains explicitly.
			save_int64(vm.run + 56, result)
			running_threads.slots[running_threads.current].hypercall_pending = 1
			# The syscall trampoline flushes CR3. Direct hypercalls need the
			# equivalent only when the syscall actually edits page permissions.
			if (syscall_number == 9 || syscall_number == 10 || syscall_number == 11 || syscall_number == 12):
				if (kvm_get_sregs(vm, cell.sregs) < 0):
					cell_fail(cell, c"cannot read hypercall page-table state")
					break
				int root = 4096
				if (load_int64(cell.sregs + 240) == root): root = 61440
				save_int64(cell.sregs + 240, root)
				if (kvm_set_sregs(vm, cell.sregs) < 0):
					cell_fail(cell, c"cannot flush hypercall page-table state")
					break
		if (cell.exited == 0 && cell.pause_after > 0 && cell.syscall_count >= cell.pause_after):
			cell.pause_after = 0
			cell.paused = 1
			break
	# Block/disarm/drain before restoring the original disposition: an
	# alarm expiring at completion must not kill the host after return.
	syscall7(14, 0, cast(int, &alarm_mask), 0, 8, 0, 0)
	mem_fill[char](&timer[0], 0, 32)
	syscall(38, 0, cast(int, &timer[0]), 0)
	syscall7(128, cast(int, &alarm_mask), 0, cast(int, &timer[0]), 8, 0, 0)
	cell_timer_run = 0
	rt_sigaction(14, cast(int*, &old_action[0]), 0)
	syscall7(14, 2, cast(int, &old_mask), 0, 8, 0, 0)
	if (timed_out):
		cell.status = 124
		cell.exited = 1
		cell_fail(cell, c"guest timed out")
	if (cell.max_instructions > 0):
		if (cell_cpu_debug_apply(cell, cell.machine, (cell.debug_control & 2) != 0) == 0):
			cell_deterministic_fail(cell, c"cannot clear instruction-budget controls")
	if (cell.exited && cell.replay != 0 && cell.replay_pos != cell.replay_length):
		cell_deterministic_fail(cell, c"incomplete syscall replay")
	return cell.exited || cell.paused


int cell_run(vm_cell* cell, int timeout_ms):
	return cell_run_internal(cell, timeout_ms, 0)


# Each resume has a new wall deadline; the syscall budget is cumulative.
int cell_resume(vm_cell* cell, int timeout_ms):
	return cell_run_internal(cell, timeout_ms, 1)
