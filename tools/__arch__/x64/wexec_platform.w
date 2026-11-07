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


int wexec_install_termination_handler(int handler):
	signal_install_handler(1, handler, 0)
	signal_install_handler(2, handler, 0)
	signal_install_handler(15, handler, 0)
	return 1
