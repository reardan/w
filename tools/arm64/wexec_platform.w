# AArch64 Linux and Android share the generic Linux syscall ABI.
const int wexec_process_groups_supported = 1


int wexec_dirents_supported():
	return 1


int wexec_process_group_enter():
	return syscall(154, 0, 0, 0)


void wexec_process_group_assign(int pid):
	syscall(154, pid, pid, 0)


void wexec_process_group_kill(int pid):
	kill(0 - pid, 9)


# Linux enters signal handlers using AAPCS64 (signum in x0), not W's
# software stack. This nonreturning thunk adopts the kernel signal SP as
# x28, pushes signum, and keeps native SP 256 KiB below the W stack.
# The interrupted W frame may already overlap the kernel signal frame;
# never return to it. The destination must terminate using plain syscalls.
# mmap RW -> mprotect RX publishes immutable code without an RWX mapping.
int wexec_arm64_termination_thunk(int handler):
	int page_size = runtime_page_size()
	int page = mmap(0, page_size, 3, 34)
	if (page >= -4095 && page <= 0): return 0
	char* code = cast(char*, page)
	char* instructions = c"\xfc\x03\x00\x91\x80\x8f\x1f\xf8\xff\x03\x41\xd1\x70\x00\x00\x58\x00\x02\x1f\xd6\x00\x00\x20\xd4"
	for i in range(24): code[i] = instructions[i]
	# mov x28,sp; str x0,[x28,#-8]!; sub sp,sp,#64,lsl #12;
	# ldr x16,[pc,#12]; br x16; brk #0; .quad handler
	save_i(code + 24, handler, 8)
	if (mprotect(page, page_size, 5) != 0):
		munmap(page, page_size)
		return 0
	return page


# AArch64 kernel sigaction: handler, flags, restorer, 64-bit mask.
# Mask every signal during termination so the cleanup cannot reenter.
# No restorer is needed because the handler exits instead of returning.
int wexec_install_termination_handler(int handler):
	int thunk = wexec_arm64_termination_thunk(handler)
	if (thunk == 0): return 0
	int[4] act
	act[0] = thunk
	act[1] = 0
	act[2] = 0
	act[3] = -1
	if (rt_sigaction(1, &act[0], 0) != 0): return 0
	if (rt_sigaction(2, &act[0], 0) != 0): return 0
	if (rt_sigaction(15, &act[0], 0) != 0): return 0
	return 1
