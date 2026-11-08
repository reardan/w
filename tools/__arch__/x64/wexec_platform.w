# Linux x64 host executor uses the shared signal ABI thunks.
import lib.signal

const int wexec_process_groups_supported = 1


int wexec_dirents_supported():
	return 1


int wexec_process_group_enter():
	return syscall(109, 0, 0, 0)


void wexec_process_group_assign(int pid):
	syscall(109, pid, pid, 0)


void wexec_process_group_kill(int pid):
	kill(0 - pid, 9)


# The shared debugger thunk calls a TWO-argument handler; this callback
# takes only the signal number. Push one W argument while keeping the
# SysV entry stack alignment, then call the nonreturning cleanup handler.
int wexec_install_termination_handler(int handler):
	signal_thunk_init()
	signal_thunk_writable(1)
	int thunk = signal_thunk_page + signal_thunk_pos
	signal_thunk_emit(3, c"\x57\x48\xb8")
	save_i(cast(char*, signal_thunk_page + signal_thunk_pos), handler, 8)
	signal_thunk_pos = signal_thunk_pos + 8
	signal_thunk_emit(7, c"\xff\xd0\x48\x83\xc4\x08\xc3")
	signal_thunk_writable(0)
	int[4] act
	act[0] = thunk
	act[1] = 0x04000000
	act[2] = signal_restorer
	act[3] = -1
	if (rt_sigaction(1, &act[0], 0) != 0): return 0
	if (rt_sigaction(2, &act[0], 0) != 0): return 0
	if (rt_sigaction(15, &act[0], 0) != 0): return 0
	return 1
